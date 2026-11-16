// Records raw Livox packets as a ROS 2 bag (MCAP, CDR):
//   /livox/imu    sensor_msgs/msg/Imu          (gyro rad/s, acceleration m/s^2)
//   /livox/lidar  sensor_msgs/msg/PointCloud2  (10 Hz frames, per-point timestamp; livox_ros_driver2 layout)
#include <chrono>
#include <cstdio>
#include <map>
#include <mutex>

#include "Mcap.hpp"
#include "SlamBridge.h"
#include "livox_packet.hpp"

namespace {

constexpr uint16_t kImuChannel = 1;
constexpr uint16_t kLidarChannel = 2;
constexpr size_t kChunkBytes = 4u << 20;
constexpr uint64_t kFrameNs = 100'000'000;   // 10 Hz, like livox_ros_driver2
constexpr uint32_t kPointStep = 26;          // x y z intensity (f32) tag line (u8) timestamp (f64)
constexpr int kMid360Lines = 4;
const char* kFrameId = "livox_frame";

uint64_t epochNs() {
    using namespace std::chrono;
    return uint64_t(duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count());
}

void record(mcap::Buf& out, uint8_t op, const mcap::Buf& content) {
    out.u8(op);
    out.u64(content.size());
    out.raw(content.b.data(), content.size());
}

}  // namespace

struct RosbagWriter {
    FILE* f = nullptr;
    uint64_t pos = 0;
    std::mutex mtx;

    // current chunk
    mcap::Buf chunk;
    uint64_t chunk_start_t = UINT64_MAX;
    uint64_t chunk_end_t = 0;
    std::map<uint16_t, std::vector<std::pair<uint64_t, uint64_t>>> chunk_index;

    // summary
    struct ChunkInfo {
        uint64_t start_t, end_t, offset, length, index_length, size;
        std::map<uint16_t, uint64_t> index_offsets;
    };
    std::vector<ChunkInfo> chunks;
    std::map<uint16_t, uint64_t> counts;
    std::map<uint16_t, uint32_t> seq;
    uint64_t msg_count = 0;
    uint64_t first_t = UINT64_MAX;
    uint64_t last_t = 0;

    // LiDAR clock -> ROS time
    bool have_offset = false;
    int64_t offset_ns = 0;

    // PointCloud2 frame being filled
    std::vector<uint8_t> frame;
    uint64_t frame_start = 0;
    uint64_t frame_last = 0;
    uint32_t frame_n = 0;

    void write(const mcap::Buf& b) {
        fwrite(b.b.data(), 1, b.size(), f);
        pos += b.size();
    }

    mcap::Buf schemaRecord(uint16_t id, const char* name, const std::string& text) {
        mcap::Buf c;
        c.u16(id);
        c.str(name);
        c.str("ros2msg");
        c.str(text);
        mcap::Buf r;
        record(r, mcap::kSchema, c);
        return r;
    }

    mcap::Buf channelRecord(uint16_t id, uint16_t schema, const char* topic) {
        mcap::Buf meta;
        meta.str("offered_qos_profiles");
        meta.str("");
        mcap::Buf c;
        c.u16(id);
        c.u16(schema);
        c.str(topic);
        c.str("cdr");
        c.u32(uint32_t(meta.size()));
        c.raw(meta.b.data(), meta.size());
        mcap::Buf r;
        record(r, mcap::kChannel, c);
        return r;
    }

    std::vector<mcap::Buf> definitions() {
        return {
            schemaRecord(kImuChannel, "sensor_msgs/msg/Imu", mcap::imuSchema()),
            schemaRecord(kLidarChannel, "sensor_msgs/msg/PointCloud2", mcap::pointCloud2Schema()),
            channelRecord(kImuChannel, kImuChannel, "/livox/imu"),
            channelRecord(kLidarChannel, kLidarChannel, "/livox/lidar"),
        };
    }

    bool open(const char* path) {
        f = fopen(path, "wb");
        if (!f) return false;
        setvbuf(f, nullptr, _IOFBF, 1 << 20);
        mcap::Buf b;
        b.raw(mcap::kMagic, 8);
        mcap::Buf h;
        h.str("ros2");
        h.str("MobileSLAM");
        record(b, mcap::kHeader, h);
        write(b);
        for (auto& r : definitions()) write(r);
        return true;
    }

    void addMessage(uint16_t ch, uint64_t log_t, uint64_t pub_t, const mcap::Buf& data) {
        chunk_index[ch].push_back({log_t, chunk.size()});
        chunk.u8(mcap::kMessage);
        chunk.u64(2 + 4 + 8 + 8 + data.size());
        chunk.u16(ch);
        chunk.u32(seq[ch]++);
        chunk.u64(log_t);
        chunk.u64(pub_t);
        chunk.raw(data.b.data(), data.size());
        chunk_start_t = std::min(chunk_start_t, log_t);
        chunk_end_t = std::max(chunk_end_t, log_t);
        first_t = std::min(first_t, log_t);
        last_t = std::max(last_t, log_t);
        counts[ch]++;
        msg_count++;
        if (chunk.size() >= kChunkBytes) flushChunk();
    }

    void flushChunk() {
        if (chunk.size() == 0) return;
        ChunkInfo ci{};
        ci.start_t = chunk_start_t;
        ci.end_t = chunk_end_t;
        ci.offset = pos;
        ci.size = chunk.size();
        mcap::Buf c;
        c.u64(chunk_start_t);
        c.u64(chunk_end_t);
        c.u64(chunk.size());
        c.u32(0);    // crc not computed
        c.str("");   // no compression
        c.u64(chunk.size());
        mcap::Buf head;
        head.u8(mcap::kChunk);
        head.u64(c.size() + chunk.size());
        head.raw(c.b.data(), c.size());
        write(head);
        write(chunk);
        ci.length = pos - ci.offset;
        const uint64_t idx_start = pos;
        for (auto& [ch, entries] : chunk_index) {
            mcap::Buf m;
            m.u16(ch);
            m.u32(uint32_t(entries.size() * 16));
            for (auto& [t, off] : entries) {
                m.u64(t);
                m.u64(off);
            }
            mcap::Buf r;
            record(r, mcap::kMessageIndex, m);
            ci.index_offsets[ch] = pos;
            write(r);
        }
        ci.index_length = pos - idx_start;
        chunks.push_back(std::move(ci));
        chunk.b.clear();
        chunk_index.clear();
        chunk_start_t = UINT64_MAX;
        chunk_end_t = 0;
    }

    uint64_t toRos(uint64_t lidar_ns, uint8_t time_type) {
        if (!have_offset) {
            // unsynchronised LiDAR clock (time since power on): shift onto the phone's wall clock
            offset_ns = time_type == 0 ? int64_t(epochNs()) - int64_t(lidar_ns) : 0;
            have_offset = true;
        }
        return uint64_t(int64_t(lidar_ns) + offset_ns);
    }

    void pushImu(const uint8_t* buf, int len) {
        double t, g[3], a[3];
        if (!mndt::parseImuPacket(buf, len, t, g, a)) return;
        uint64_t raw;
        std::memcpy(&raw, buf + 28, 8);
        const uint64_t ns = toRos(raw, buf[11]);
        mcap::CdrW w;
        w.stamp(ns, kFrameId);
        w.f64(0);
        w.f64(0);
        w.f64(0);
        w.f64(1);
        for (int i = 0; i < 9; ++i) w.f64(i == 0 ? -1.0 : 0.0);   // no orientation estimate
        for (int i = 0; i < 3; ++i) w.f64(g[i]);
        for (int i = 0; i < 9; ++i) w.f64(0);
        for (int i = 0; i < 3; ++i) w.f64(a[i]);
        for (int i = 0; i < 9; ++i) w.f64(0);
        addMessage(kImuChannel, ns, ns, w.o);
    }

    void putPoint(float x, float y, float z, float refl, uint8_t tag, uint8_t line, uint64_t ns) {
        const size_t at = frame.size();
        frame.resize(at + kPointStep);
        uint8_t* q = frame.data() + at;
        std::memcpy(q, &x, 4);
        std::memcpy(q + 4, &y, 4);
        std::memcpy(q + 8, &z, 4);
        std::memcpy(q + 12, &refl, 4);
        q[16] = tag;
        q[17] = line;
        const double t = double(ns);
        std::memcpy(q + 18, &t, 8);
        frame_n++;
        frame_last = ns;
    }

    void pushPoints(const uint8_t* buf, int len) {
        using namespace mndt::detail;
        if (len < mndt::kLivoxHeader) return;
        const uint16_t interval = rd16(buf + 3);
        const uint16_t dot = rd16(buf + 5);
        const uint8_t type = buf[10];
        const uint64_t t0 = toRos(rd64(buf + 28), buf[11]);
        if (frame_n > 0 && t0 >= frame_start + kFrameNs) flushFrame();
        if (frame_n == 0) frame_start = t0;
        const int step = type == 1 ? 14 : type == 2 ? 8 : 0;
        if (!step) return;
        for (int i = 0; i < dot; ++i) {
            const uint8_t* q = buf + mndt::kLivoxHeader + i * step;
            if (q + step > buf + len) break;
            float x, y, z;
            if (type == 1) {
                x = rd32s(q) * 1e-3f;
                y = rd32s(q + 4) * 1e-3f;
                z = rd32s(q + 8) * 1e-3f;
            } else {
                x = rd16s(q) * 1e-2f;
                y = rd16s(q + 2) * 1e-2f;
                z = rd16s(q + 4) * 1e-2f;
            }
            if (x == 0 && y == 0 && z == 0) continue;
            const uint64_t ns = t0 + (dot ? uint64_t(i) * interval * 100 / dot : 0);
            putPoint(x, y, z, float(q[step - 2]), q[step - 1], uint8_t(i % kMid360Lines), ns);
        }
    }

    void flushFrame() {
        if (frame_n == 0) return;
        mcap::CdrW w;
        w.stamp(frame_start, kFrameId);
        w.u32(1);         // height
        w.u32(frame_n);   // width
        struct Field {
            const char* name;
            uint32_t offset;
            uint8_t type;
        };
        const Field fields[] = {{"x", 0, 7}, {"y", 4, 7}, {"z", 8, 7}, {"intensity", 12, 7},
                                {"tag", 16, 2}, {"line", 17, 2}, {"timestamp", 18, 8}};
        w.u32(7);
        for (auto& fd : fields) {
            w.str(fd.name);
            w.u32(fd.offset);
            w.u8(fd.type);
            w.u32(1);
        }
        w.u8(0);   // is_bigendian
        w.u32(kPointStep);
        w.u32(kPointStep * frame_n);
        w.u32(uint32_t(frame.size()));
        w.o.raw(frame.data(), frame.size());
        w.u8(1);   // is_dense
        addMessage(kLidarChannel, frame_last, frame_start, w.o);
        frame.clear();
        frame_n = 0;
    }

    void finish() {
        flushFrame();
        flushChunk();
        mcap::Buf b;
        mcap::Buf de;
        de.u32(0);
        record(b, mcap::kDataEnd, de);
        write(b);

        const uint64_t summary_start = pos;
        struct Group {
            uint8_t op;
            uint64_t start, length;
        };
        std::vector<Group> groups;
        auto group = [&](uint8_t op, const std::vector<mcap::Buf>& recs) {
            const uint64_t s = pos;
            for (auto& r : recs) write(r);
            groups.push_back({op, s, pos - s});
        };
        auto defs = definitions();
        group(mcap::kSchema, {defs[0], defs[1]});
        group(mcap::kChannel, {defs[2], defs[3]});

        mcap::Buf st;
        st.u64(msg_count);
        st.u16(2);   // schemas
        st.u32(2);   // channels
        st.u32(0);   // attachments
        st.u32(0);   // metadata
        st.u32(uint32_t(chunks.size()));
        st.u64(msg_count ? first_t : 0);
        st.u64(last_t);
        mcap::Buf cc;
        for (auto& [ch, n] : counts) {
            cc.u16(ch);
            cc.u64(n);
        }
        st.u32(uint32_t(cc.size()));
        st.raw(cc.b.data(), cc.size());
        mcap::Buf str;
        record(str, mcap::kStatistics, st);
        group(mcap::kStatistics, {str});

        std::vector<mcap::Buf> idx;
        for (auto& ci : chunks) {
            mcap::Buf c;
            c.u64(ci.start_t);
            c.u64(ci.end_t);
            c.u64(ci.offset);
            c.u64(ci.length);
            c.u32(uint32_t(ci.index_offsets.size() * 10));
            for (auto& [ch, off] : ci.index_offsets) {
                c.u16(ch);
                c.u64(off);
            }
            c.u64(ci.index_length);
            c.str("");
            c.u64(ci.size);
            c.u64(ci.size);
            mcap::Buf r;
            record(r, mcap::kChunkIndex, c);
            idx.push_back(std::move(r));
        }
        if (!idx.empty()) group(mcap::kChunkIndex, idx);

        const uint64_t offsets_start = pos;
        for (auto& g : groups) {
            mcap::Buf c;
            c.u8(g.op);
            c.u64(g.start);
            c.u64(g.length);
            mcap::Buf r;
            record(r, mcap::kSummaryOffset, c);
            write(r);
        }
        mcap::Buf ft;
        mcap::Buf fc;
        fc.u64(summary_start);
        fc.u64(offsets_start);
        fc.u32(0);
        record(ft, mcap::kFooter, fc);
        ft.raw(mcap::kMagic, 8);
        write(ft);
        fclose(f);
        f = nullptr;
    }
};

extern "C" {

RosbagWriterHandle rosbag_writer_open(const char* path) {
    auto* w = new RosbagWriter();
    if (!w->open(path)) {
        delete w;
        return nullptr;
    }
    return w;
}

void rosbag_writer_push(RosbagWriterHandle h, int32_t type, const uint8_t* buf, int32_t len) {
    std::lock_guard<std::mutex> l(h->mtx);
    if (!h->f) return;
    if (type == 1) {
        h->pushPoints(buf, len);
    } else if (type == 2) {
        h->pushImu(buf, len);
    }
}

int64_t rosbag_writer_bytes(RosbagWriterHandle h) {
    std::lock_guard<std::mutex> l(h->mtx);
    return int64_t(h->pos + h->chunk.size() + h->frame.size());
}

void rosbag_writer_close(RosbagWriterHandle h) {
    {
        std::lock_guard<std::mutex> l(h->mtx);
        if (h->f) h->finish();
    }
    delete h;
}

}  // extern "C"
