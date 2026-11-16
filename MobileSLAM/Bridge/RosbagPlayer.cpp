// Plays a ROS 2 bag (MCAP; chunks uncompressed, zstd or lz4) as Livox packets, so SLAM and the live view see it
// like the sensor.
// LiDAR: sensor_msgs/msg/PointCloud2 (per-point time field optional) or livox CustomMsg.
// IMU: sensor_msgs/msg/Imu (acceleration in m/s^2 or g).
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <thread>

#include "../../third_party/lz4/lz4frame.h"
#include "../../third_party/zstd/lib/zstd.h"
#include "Mcap.hpp"
#include "SlamBridge.h"

namespace {

/// Decompresses one MCAP chunk into out (usize bytes). Returns false with err set on failure.
bool decompress(const std::string& comp, const uint8_t* src, size_t n, uint64_t usize, std::vector<uint8_t>& out,
                std::string& err) {
    if (usize > (2ull << 30)) {
        err = "chunk too large";
        return false;
    }
    out.resize(usize);
    if (comp == "zstd") {
        const size_t r = ZSTD_decompress(out.data(), usize, src, n);
        if (ZSTD_isError(r) || r != usize) {
            err = "zstd decompression failed";
            return false;
        }
        return true;
    }
    if (comp == "lz4") {
        LZ4F_dctx* ctx = nullptr;
        if (LZ4F_isError(LZ4F_createDecompressionContext(&ctx, LZ4F_VERSION))) {
            err = "lz4 init failed";
            return false;
        }
        size_t in_pos = 0;
        size_t out_pos = 0;
        bool ok = true;
        while (in_pos < n && out_pos < usize) {
            size_t in_sz = n - in_pos;
            size_t out_sz = usize - out_pos;
            const size_t r = LZ4F_decompress(ctx, out.data() + out_pos, &out_sz, src + in_pos, &in_sz, nullptr);
            if (LZ4F_isError(r)) {
                ok = false;
                break;
            }
            in_pos += in_sz;
            out_pos += out_sz;
            if (r == 0) break;
            if (in_sz == 0 && out_sz == 0) {
                ok = false;
                break;
            }
        }
        LZ4F_freeDecompressionContext(ctx);
        if (!ok || out_pos != usize) {
            err = "lz4 decompression failed";
            return false;
        }
        return true;
    }
    err = "unsupported chunk compression: " + comp;
    return false;
}

enum class LidarKind { None, PointCloud2, LivoxCustom };

struct Channel {
    std::string topic;
    std::string schema;
    std::string encoding;
};

struct Selection {
    uint16_t lidar = 0;
    uint16_t imu = 0;
    LidarKind kind = LidarKind::None;
    std::string lidar_topic, imu_topic;
};

LidarKind kindOf(const std::string& schema) {
    if (schema == "sensor_msgs/msg/PointCloud2") return LidarKind::PointCloud2;
    if (schema.size() >= 10 && schema.compare(schema.size() - 10, 10, "/CustomMsg") == 0) return LidarKind::LivoxCustom;
    return LidarKind::None;
}

bool contains(const std::string& s, const char* k) { return s.find(k) != std::string::npos; }

/// Prefers the raw sensor topic over processed clouds (registered scans, maps).
int lidarScore(const Channel& c) {
    const LidarKind k = kindOf(c.schema);
    if (k == LidarKind::None || c.encoding != "cdr") return -100;
    int s = k == LidarKind::LivoxCustom ? 10 : 0;
    if (c.topic == "/livox/lidar") s += 5;
    if (contains(c.topic, "livox")) s += 3;
    if (contains(c.topic, "lidar") || contains(c.topic, "points") || contains(c.topic, "velodyne") ||
        contains(c.topic, "ouster") || contains(c.topic, "cloud")) {
        s += 1;
    }
    if (contains(c.topic, "registered") || contains(c.topic, "map") || contains(c.topic, "deskew") ||
        contains(c.topic, "undistort") || contains(c.topic, "filtered")) {
        s -= 5;
    }
    return s;
}

int imuScore(const Channel& c) {
    if (c.schema != "sensor_msgs/msg/Imu" || c.encoding != "cdr") return -100;
    int s = 0;
    if (c.topic == "/livox/imu") s += 5;
    if (contains(c.topic, "livox")) s += 3;
    return s;
}

Selection choose(const std::map<uint16_t, Channel>& chans) {
    Selection sel;
    int best_l = -50;
    int best_i = -50;
    for (auto& [id, c] : chans) {
        const int l = lidarScore(c);
        if (l > best_l) {
            best_l = l;
            sel.lidar = id;
            sel.kind = kindOf(c.schema);
            sel.lidar_topic = c.topic;
        }
        const int i = imuScore(c);
        if (i > best_i) {
            best_i = i;
            sel.imu = id;
            sel.imu_topic = c.topic;
        }
    }
    return sel;
}

/// Sequential MCAP record reader.
class Scanner {
public:
    using Fn = std::function<bool(uint8_t op, mcap::Rd& r)>;   // return false to stop

    ~Scanner() {
        if (f_) fclose(f_);
    }

    bool open(const char* path, std::string& err) {
        f_ = fopen(path, "rb");
        if (!f_) {
            err = "cannot open file";
            return false;
        }
        fseeko(f_, 0, SEEK_END);
        size_ = uint64_t(ftello(f_));
        uint8_t m[8];
        fseeko(f_, 0, SEEK_SET);
        if (fread(m, 1, 8, f_) != 8 || std::memcmp(m, mcap::kMagic, 5) != 0) {
            err = "not an MCAP file";
            return false;
        }
        pos_ = 8;
        return true;
    }

    uint64_t size() const { return size_; }
    uint64_t pos() const { return pos_; }

    /// Reads the summary section (schemas / channels / statistics). Returns false when the file has none.
    bool summary(const Fn& fn) {
        if (size_ < 8 + 37) return false;
        uint8_t ft[37];
        fseeko(f_, off_t(size_ - 37), SEEK_SET);
        if (fread(ft, 1, 37, f_) != 37 || ft[0] != mcap::kFooter || std::memcmp(ft + 29, mcap::kMagic, 5) != 0) {
            return false;
        }
        uint64_t start;
        uint64_t offsets;
        std::memcpy(&start, ft + 9, 8);
        std::memcpy(&offsets, ft + 17, 8);
        if (start == 0 || start >= size_) return false;
        const uint64_t end = offsets ? offsets : size_ - 37;
        fseeko(f_, off_t(start), SEEK_SET);
        uint64_t p = start;
        std::vector<uint8_t> buf;
        while (p + 9 <= end) {
            uint8_t h[9];
            if (fread(h, 1, 9, f_) != 9) break;
            uint64_t len;
            std::memcpy(&len, h + 1, 8);
            if (len > end - p - 9) break;
            buf.resize(len);
            if (fread(buf.data(), 1, len, f_) != len) break;
            p += 9 + len;
            mcap::Rd r{buf.data(), len};
            if (!fn(h[0], r)) break;
        }
        return true;
    }

    /// Walks the data section from the start (chunk contents included).
    /// Stops at the footer, the end of the file, a truncated record, stop == true or after max_bytes.
    bool data(const Fn& fn, const std::atomic<bool>* stop, uint64_t max_bytes, std::string& err) {
        fseeko(f_, 8, SEEK_SET);
        pos_ = 8;
        std::vector<uint8_t> buf;
        std::vector<uint8_t> plain;
        while (pos_ + 9 <= size_ && pos_ < max_bytes) {
            if (stop && *stop) return true;
            uint8_t h[9];
            if (fread(h, 1, 9, f_) != 9) break;
            const uint8_t op = h[0];
            uint64_t len;
            std::memcpy(&len, h + 1, 8);
            if (op == mcap::kFooter || op == mcap::kDataEnd) break;
            if (len > size_ - pos_ - 9) break;   // truncated (recording not closed)
            const bool wanted = op == mcap::kSchema || op == mcap::kChannel || op == mcap::kMessage || op == mcap::kChunk;
            if (!wanted) {
                fseeko(f_, off_t(len), SEEK_CUR);
                pos_ += 9 + len;
                continue;
            }
            buf.resize(len);
            if (fread(buf.data(), 1, len, f_) != len) break;
            pos_ += 9 + len;
            mcap::Rd r{buf.data(), len};
            if (op != mcap::kChunk) {
                if (!fn(op, r)) return true;
                continue;
            }
            r.get<uint64_t>();
            r.get<uint64_t>();
            const uint64_t usize = r.get<uint64_t>();
            r.get<uint32_t>();
            const std::string comp = r.str();
            const uint64_t clen = r.get<uint64_t>();
            if (!r.ok || clen > len - r.i) break;
            const uint8_t* q = buf.data() + r.i;
            uint64_t rlen = clen;
            if (!comp.empty()) {
                if (!decompress(comp, q, clen, usize, plain, err)) return false;
                q = plain.data();
                rlen = usize;
            }
            uint64_t k = 0;
            while (k + 9 <= rlen) {
                const uint8_t iop = q[k];
                uint64_t ilen;
                std::memcpy(&ilen, q + k + 1, 8);
                if (ilen > rlen - k - 9) break;
                mcap::Rd ir{q + k + 9, ilen};
                if (!fn(iop, ir)) return true;
                k += 9 + ilen;
            }
        }
        return true;
    }

private:
    FILE* f_ = nullptr;
    uint64_t size_ = 0;
    uint64_t pos_ = 0;
};

/// Collects schemas / channels from Schema and Channel records.
struct Catalog {
    std::map<uint16_t, std::string> schemas;
    std::map<uint16_t, Channel> channels;
    uint64_t start_t = 0;
    uint64_t end_t = 0;

    void onRecord(uint8_t op, mcap::Rd& r) {
        if (op == mcap::kSchema) {
            const uint16_t id = r.get<uint16_t>();
            std::string name = r.str();
            if (r.ok) schemas[id] = name;
        } else if (op == mcap::kChannel) {
            const uint16_t id = r.get<uint16_t>();
            const uint16_t sid = r.get<uint16_t>();
            std::string topic = r.str();
            std::string enc = r.str();
            if (r.ok) channels[id] = Channel{topic, schemas[sid], enc};
        } else if (op == mcap::kStatistics) {
            r.get<uint64_t>();
            r.get<uint16_t>();
            r.get<uint32_t>();
            r.get<uint32_t>();
            r.get<uint32_t>();
            r.get<uint32_t>();
            start_t = r.get<uint64_t>();
            end_t = r.get<uint64_t>();
            if (!r.ok) {
                start_t = 0;
                end_t = 0;
            }
        }
    }
};

bool probe(const char* path, Selection& sel, double& duration, std::string& err) {
    Scanner sc;
    if (!sc.open(path, err)) return false;
    Catalog cat;
    sc.summary([&](uint8_t op, mcap::Rd& r) {
        cat.onRecord(op, r);
        return true;
    });
    if (cat.channels.empty()) {
        // no summary (recording was not closed): look at the beginning of the data
        int msgs = 0;
        if (!sc.data(
                [&](uint8_t op, mcap::Rd& r) {
                    cat.onRecord(op, r);
                    return op != mcap::kMessage || ++msgs < 5000;
                },
                nullptr, 256ull << 20, err)) {
            return false;
        }
    }
    duration = cat.end_t > cat.start_t ? double(cat.end_t - cat.start_t) * 1e-9 : 0;
    sel = choose(cat.channels);
    if (sel.kind == LidarKind::None) {
        err = "no sensor_msgs/PointCloud2 or livox CustomMsg topic";
        return false;
    }
    if (sel.imu_topic.empty()) {
        err = "no sensor_msgs/Imu topic";
        return false;
    }
    return true;
}

void copyStr(char* dst, size_t n, const std::string& s) {
    std::snprintf(dst, n, "%s", s.c_str());
}

// ------------------------------------------------------------------ conversion to Livox packets

struct Pt {
    uint64_t t;
    int32_t x, y, z;   // mm
    uint8_t refl, tag;
};

double readNum(const uint8_t* p, uint8_t type) {
    switch (type) {
        case 1: return double(*reinterpret_cast<const int8_t*>(p));
        case 2: return double(*p);
        case 3: {
            int16_t v;
            std::memcpy(&v, p, 2);
            return v;
        }
        case 4: {
            uint16_t v;
            std::memcpy(&v, p, 2);
            return v;
        }
        case 5: {
            int32_t v;
            std::memcpy(&v, p, 4);
            return v;
        }
        case 6: {
            uint32_t v;
            std::memcpy(&v, p, 4);
            return v;
        }
        case 7: {
            float v;
            std::memcpy(&v, p, 4);
            return v;
        }
        case 8: {
            double v;
            std::memcpy(&v, p, 8);
            return v;
        }
        default: return 0;
    }
}

int typeSize(uint8_t type) {
    static const int s[] = {0, 1, 1, 2, 2, 4, 4, 4, 8};
    return type <= 8 ? s[type] : 0;
}

/// Per-point time in ns from a PointCloud2 time field (drivers disagree on name, type and origin).
uint64_t pointTime(double v, uint8_t type, uint64_t stamp) {
    if (type == 8 || type == 7) {
        if (v > 1e17) return uint64_t(v);              // absolute ns (livox_ros_driver2)
        if (v > 1e8) return uint64_t(v * 1e9);         // absolute s (Hesai, RoboSense)
        return stamp + uint64_t(std::max(0.0, v) * 1e9);   // relative s (Velodyne)
    }
    return stamp + uint64_t(std::max(0.0, v));         // relative ns (Ouster "t")
}

class Converter {
public:
    explicit Converter(DemoPacketFn fn, void* ctx) : fn_(fn), ctx_(ctx) {}

    bool pointCloud2(const uint8_t* p, size_t n) {
        mcap::CdrR c(p, n);
        const uint64_t stamp = c.header();
        const uint32_t height = c.u32();
        const uint32_t width = c.u32();
        const uint32_t nf = c.u32();
        struct F {
            std::string name;
            uint32_t off;
            uint8_t type;
        };
        std::vector<F> fields;
        for (uint32_t i = 0; i < nf && c.r.ok && i < 64; ++i) {
            F f;
            f.name = c.str();
            f.off = c.u32();
            f.type = c.u8();
            c.u32();
            fields.push_back(f);
        }
        const uint8_t bigendian = c.u8();
        const uint32_t step = c.u32();
        c.u32();
        const uint32_t dlen = c.u32();
        if (!c.r.ok || bigendian || !c.r.need(dlen)) return false;
        const uint8_t* data = c.r.p + c.r.i;
        auto find = [&](std::initializer_list<const char*> names) -> const F* {
            for (const char* nm : names) {
                for (auto& f : fields) {
                    if (f.name == nm && typeSize(f.type) > 0) return &f;
                }
            }
            return nullptr;
        };
        const F* fx = find({"x"});
        const F* fy = find({"y"});
        const F* fz = find({"z"});
        if (!fx || !fy || !fz) return false;
        const F* fi = find({"intensity", "reflectivity"});
        const F* ft = find({"timestamp", "time", "t", "offset_time", "time_stamp"});
        const F* ftag = find({"tag"});
        const uint64_t count = uint64_t(height) * width;
        if (step == 0 || count * step > dlen) return false;
        pts_.clear();
        pts_.reserve(count);
        for (uint64_t i = 0; i < count; ++i) {
            const uint8_t* q = data + i * step;
            const double x = readNum(q + fx->off, fx->type);
            const double y = readNum(q + fy->off, fy->type);
            const double z = readNum(q + fz->off, fz->type);
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) continue;
            Pt pt;
            pt.x = int32_t(std::lround(x * 1000));
            pt.y = int32_t(std::lround(y * 1000));
            pt.z = int32_t(std::lround(z * 1000));
            if (pt.x == 0 && pt.y == 0 && pt.z == 0) continue;
            const double in = fi ? readNum(q + fi->off, fi->type) : 0;
            pt.refl = uint8_t(std::clamp(std::isfinite(in) ? in : 0.0, 0.0, 255.0));
            pt.tag = ftag ? uint8_t(readNum(q + ftag->off, ftag->type)) : 0;
            pt.t = ft ? pointTime(readNum(q + ft->off, ft->type), ft->type, stamp) : stamp;
            pts_.push_back(pt);
        }
        emitPoints();
        return true;
    }

    bool livoxCustom(const uint8_t* p, size_t n) {
        mcap::CdrR c(p, n);
        c.header();
        const uint64_t base = c.u64();
        c.u32();
        c.u8();
        c.u8();
        c.u8();
        c.u8();
        const uint32_t np = c.u32();
        if (!c.r.ok) return false;
        pts_.clear();
        pts_.reserve(np);
        for (uint32_t i = 0; i < np && c.r.ok; ++i) {
            const uint32_t off = c.u32();
            const float x = c.f32();
            const float y = c.f32();
            const float z = c.f32();
            const uint8_t refl = c.u8();
            const uint8_t tag = c.u8();
            c.u8();
            if (!c.r.ok) break;
            Pt pt;
            pt.x = int32_t(std::lround(x * 1000));
            pt.y = int32_t(std::lround(y * 1000));
            pt.z = int32_t(std::lround(z * 1000));
            if (pt.x == 0 && pt.y == 0 && pt.z == 0) continue;
            pt.refl = refl;
            pt.tag = tag;
            pt.t = base + off;
            pts_.push_back(pt);
        }
        emitPoints();
        return true;
    }

    bool imu(const uint8_t* p, size_t n) {
        mcap::CdrR c(p, n);
        const uint64_t stamp = c.header();
        for (int i = 0; i < 13; ++i) c.f64();   // orientation + covariance
        double g[3];
        double a[3];
        for (double& v : g) v = c.f64();
        for (int i = 0; i < 9; ++i) c.f64();
        for (double& v : a) v = c.f64();
        if (!c.r.ok) return false;
        if (acc_in_g_ < 0) {
            // drivers differ: livox_ros_driver2 publishes g, the ROS convention is m/s^2
            acc_in_g_ = std::sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) < 4.9 ? 1 : 0;
        }
        const double s = acc_in_g_ ? 1.0 : 1.0 / 9.81;
        uint8_t pkt[36 + 24];
        header(pkt, sizeof(pkt), 0, 1, icnt_++, 0, stamp);
        for (int i = 0; i < 3; ++i) {
            const float gv = float(g[i]);
            const float av = float(a[i] * s);
            std::memcpy(pkt + 36 + 4 * i, &gv, 4);
            std::memcpy(pkt + 48 + 4 * i, &av, 4);
        }
        fn_(ctx_, 2, pkt, sizeof(pkt));
        return true;
    }

private:
    static constexpr int kMaxDots = 96;
    static constexpr uint64_t kMaxSpanNs = 6'000'000;   // time_interval is u16 in 0.1 us

    static void header(uint8_t* b, int len, uint16_t interval, uint16_t dot, uint16_t cnt, uint8_t type, uint64_t ts) {
        std::memset(b, 0, 36);
        const uint16_t l = uint16_t(len);
        std::memcpy(b + 1, &l, 2);
        std::memcpy(b + 3, &interval, 2);
        std::memcpy(b + 5, &dot, 2);
        std::memcpy(b + 7, &cnt, 2);
        b[10] = type;
        b[11] = 1;   // synchronised clock: the recorder keeps these stamps as they are
        std::memcpy(b + 28, &ts, 8);
    }

    /// Time-sorted points -> Livox packets of up to 96 points, each with linear per-point timing.
    void emitPoints() {
        std::stable_sort(pts_.begin(), pts_.end(), [](const Pt& a, const Pt& b) { return a.t < b.t; });
        size_t i = 0;
        while (i < pts_.size()) {
            size_t j = i + 1;
            while (j < pts_.size() && j - i < kMaxDots && pts_[j].t - pts_[i].t <= kMaxSpanNs) ++j;
            const int dot = int(j - i);
            uint16_t interval = 0;
            if (dot > 1) {
                const double per = double(pts_[j - 1].t - pts_[i].t) / (dot - 1);   // ns per point
                interval = uint16_t(std::min(65535.0, std::round(per * dot / 100.0)));
            }
            const int len = 36 + 14 * dot;
            header(pkt_, len, interval, uint16_t(dot), cnt_++, 1, pts_[i].t);
            for (int k = 0; k < dot; ++k) {
                const Pt& p = pts_[i + size_t(k)];
                uint8_t* q = pkt_ + 36 + 14 * k;
                std::memcpy(q, &p.x, 4);
                std::memcpy(q + 4, &p.y, 4);
                std::memcpy(q + 8, &p.z, 4);
                q[12] = p.refl;
                q[13] = p.tag;
            }
            fn_(ctx_, 1, pkt_, len);
            i = j;
        }
    }

    DemoPacketFn fn_;
    void* ctx_;
    std::vector<Pt> pts_;
    uint8_t pkt_[36 + 14 * kMaxDots];
    uint16_t cnt_ = 0;
    uint16_t icnt_ = 0;
    int acc_in_g_ = -1;
};

}  // namespace

struct RosbagPlayer {
    std::string path;
    double speed = 1.0;
    DemoPacketFn fn;
    void* ctx;
    std::atomic<bool> quit{false};
    std::thread worker;
    std::mutex mtx;
    RosbagStatus st{};

    void setError(const std::string& e) {
        std::lock_guard<std::mutex> l(mtx);
        st.state = 2;
        copyStr(st.error, sizeof(st.error), e);
    }

    void run() {
        Selection sel;
        double duration = 0;
        std::string err;
        if (!probe(path.c_str(), sel, duration, err)) {
            setError(err);
            return;
        }
        {
            std::lock_guard<std::mutex> l(mtx);
            st.duration = duration;
            copyStr(st.lidar_topic, sizeof(st.lidar_topic), sel.lidar_topic);
            copyStr(st.imu_topic, sizeof(st.imu_topic), sel.imu_topic);
        }
        Scanner sc;
        if (!sc.open(path.c_str(), err)) {
            setError(err);
            return;
        }
        Converter conv(fn, ctx);
        Catalog cat;
        using clock = std::chrono::steady_clock;
        clock::time_point wall0;
        uint64_t bag0 = 0;
        bool started = false;
        const bool ok = sc.data(
            [&](uint8_t op, mcap::Rd& r) {
                if (op != mcap::kMessage) {
                    cat.onRecord(op, r);
                    return true;
                }
                const uint16_t ch = r.get<uint16_t>();
                r.get<uint32_t>();
                const uint64_t log_t = r.get<uint64_t>();
                r.get<uint64_t>();
                if (!r.ok) return true;
                const auto it = cat.channels.find(ch);
                if (it == cat.channels.end()) return true;
                const bool is_lidar = it->second.topic == sel.lidar_topic;
                const bool is_imu = it->second.topic == sel.imu_topic;
                if (!is_lidar && !is_imu) return true;
                if (!started) {
                    started = true;
                    bag0 = log_t;
                    wall0 = clock::now();
                }
                const double target = log_t > bag0 ? double(log_t - bag0) * 1e-9 / speed : 0;
                // skip long silent gaps in the bag
                const double ahead = target - std::chrono::duration<double>(clock::now() - wall0).count();
                if (ahead > 1.0) wall0 -= std::chrono::duration_cast<clock::duration>(std::chrono::duration<double>(ahead - 0.1));
                const auto when = wall0 + std::chrono::duration_cast<clock::duration>(std::chrono::duration<double>(target));
                while (!quit && clock::now() < when) {
                    std::this_thread::sleep_until(std::min(when, clock::now() + std::chrono::milliseconds(50)));
                }
                if (quit) return false;
                const uint8_t* body = r.p + r.i;
                const size_t blen = r.n - r.i;
                if (is_lidar) {
                    if (sel.kind == LidarKind::LivoxCustom) {
                        conv.livoxCustom(body, blen);
                    } else {
                        conv.pointCloud2(body, blen);
                    }
                } else {
                    conv.imu(body, blen);
                }
                std::lock_guard<std::mutex> l(mtx);
                if (is_lidar) {
                    st.point_msgs++;
                } else {
                    st.imu_msgs++;
                }
                st.elapsed = double(log_t > bag0 ? log_t - bag0 : 0) * 1e-9;
                st.progress = sc.size() ? double(sc.pos()) / double(sc.size()) : 0;
                return true;
            },
            &quit, UINT64_MAX, err);
        if (!ok) {
            setError(err);
            return;
        }
        std::lock_guard<std::mutex> l(mtx);
        st.state = 1;
        st.progress = 1;
    }
};

extern "C" {

int32_t rosbag_probe(const char* path, RosbagStatus* out) {
    *out = RosbagStatus{};
    Selection sel;
    double duration = 0;
    std::string err;
    const bool ok = probe(path, sel, duration, err);
    out->duration = duration;
    copyStr(out->lidar_topic, sizeof(out->lidar_topic), sel.lidar_topic);
    copyStr(out->imu_topic, sizeof(out->imu_topic), sel.imu_topic);
    if (!ok) {
        out->state = 2;
        copyStr(out->error, sizeof(out->error), err);
    }
    return ok ? 1 : 0;
}

RosbagPlayerHandle rosbag_play_start(const char* path, double speed, DemoPacketFn fn, void* ctx) {
    auto* p = new RosbagPlayer();
    p->path = path;
    p->speed = speed > 0 ? speed : 1.0;
    p->fn = fn;
    p->ctx = ctx;
    p->worker = std::thread([p] { p->run(); });
    return p;
}

void rosbag_play_status(RosbagPlayerHandle h, RosbagStatus* out) {
    std::lock_guard<std::mutex> l(h->mtx);
    *out = h->st;
}

void rosbag_play_stop(RosbagPlayerHandle h) {
    h->quit = true;
    h->worker.join();
    delete h;
}

}  // extern "C"
