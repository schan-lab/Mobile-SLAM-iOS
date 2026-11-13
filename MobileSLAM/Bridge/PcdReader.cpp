// Minimal PCD reader (ascii / binary / binary_compressed) extracting x, y, z and, when present, intensity.
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "SlamBridge.h"

namespace {

struct File {
    FILE* f = nullptr;
    ~File() { if (f) std::fclose(f); }
};

bool readLine(FILE* f, std::string& out) {
    out.clear();
    int c;
    while ((c = std::fgetc(f)) != EOF) {
        if (c == '\n') return true;
        if (c != '\r') out.push_back(char(c));
    }
    return !out.empty();
}

std::vector<std::string> tokens(const std::string& s) {
    std::vector<std::string> t;
    std::istringstream is(s);
    std::string w;
    while (is >> w) t.push_back(w);
    return t;
}

std::string lower(std::string s) {
    for (auto& c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

struct Field {
    std::string name;
    int size = 4;
    char type = 'F';
    int count = 1;
    int off = 0;
};

float value(const uint8_t* p, const Field& f) {
    switch (f.type) {
        case 'F':
            if (f.size == 8) {
                double v;
                std::memcpy(&v, p, 8);
                return float(v);
            }
            { float v; std::memcpy(&v, p, 4); return v; }
        case 'U':
            if (f.size == 1) return float(*p);
            if (f.size == 2) {
                uint16_t v;
                std::memcpy(&v, p, 2);
                return float(v);
            }
            if (f.size == 4) {
                uint32_t v;
                std::memcpy(&v, p, 4);
                return float(v);
            }
            { uint64_t v; std::memcpy(&v, p, 8); return float(v); }
        default:
            if (f.size == 1) return float(int8_t(*p));
            if (f.size == 2) {
                int16_t v;
                std::memcpy(&v, p, 2);
                return float(v);
            }
            if (f.size == 4) {
                int32_t v;
                std::memcpy(&v, p, 4);
                return float(v);
            }
            { int64_t v; std::memcpy(&v, p, 8); return float(v); }
    }
}

bool lzfDecompress(const uint8_t* src, size_t n, uint8_t* out, size_t out_len) {
    size_t ip = 0, op = 0;
    while (ip < n) {
        unsigned ctrl = src[ip++];
        if (ctrl < 32) {
            size_t len = ctrl + 1;
            if (ip + len > n || op + len > out_len) return false;
            std::memcpy(out + op, src + ip, len);
            ip += len;
            op += len;
        } else {
            size_t len = ctrl >> 5;
            if (ip >= n) return false;
            if (len == 7) len += src[ip++];
            if (ip >= n) return false;
            size_t back = ((ctrl & 0x1F) << 8) + src[ip++] + 1;
            len += 2;
            if (back > op || op + len > out_len) return false;
            for (size_t k = 0; k < len; ++k, ++op) out[op] = out[op - back];
        }
    }
    return op == out_len;
}

void fail(PcdCloud* c, const std::string& msg) { std::snprintf(c->error, sizeof c->error, "%s", msg.c_str()); }

/// Whole pages from mmap, so the buffer can be wrapped by Metal (newBufferWithBytesNoCopy) without copying.
float* allocPoints(PcdCloud* c, size_t n) {
    const size_t page = size_t(getpagesize());
    size_t bytes = std::max<size_t>(n * 16, 16);
    bytes = (bytes + page - 1) / page * page;
    void* p = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) return nullptr;
    c->alloc_bytes = bytes;
    return static_cast<float*>(p);
}

void computeStats(PcdCloud* c) {
    for (int k = 0; k < 3; ++k) {
        c->min[k] = INFINITY;
        c->max[k] = -INFINITY;
    }
    const int n = c->n;
    for (int i = 0; i < n; ++i)
        for (int k = 0; k < 3; ++k) {
            float v = c->xyzi[4 * i + k];
            c->min[k] = std::min(c->min[k], v);
            c->max[k] = std::max(c->max[k], v);
        }
    c->z_lo = 0;
    c->z_hi = 1;
    c->i_hi = 255;
    if (n == 0) {
        for (int k = 0; k < 3; ++k) c->min[k] = c->max[k] = 0;
        return;
    }
    const int step = std::max(1, n / 20000);
    std::vector<float> zs, is;
    for (int i = 0; i < n; i += step) {
        zs.push_back(c->xyzi[4 * i + 2]);
        is.push_back(c->xyzi[4 * i + 3]);
    }
    std::sort(zs.begin(), zs.end());
    c->z_lo = zs[size_t(zs.size() * 0.02)];
    c->z_hi = zs[std::min(zs.size() - 1, size_t(zs.size() * 0.98))];
    if (c->z_hi - c->z_lo < 0.1f) c->z_hi = c->z_lo + 0.1f;
    if (c->has_intensity) {
        // Livox reflectivity is 0..255; other files may use 0..1 or larger ranges
        std::sort(is.begin(), is.end());
        float p99 = is[std::min(is.size() - 1, size_t(is.size() * 0.99))];
        c->i_hi = (p99 > 1.5f && p99 <= 255.f) ? 255.f : std::max(p99, 1e-6f);
    }
}

}  // namespace

extern "C" {

PcdCloud* pcd_read(const char* path, int32_t max_points) {
    auto* c = static_cast<PcdCloud*>(std::calloc(1, sizeof(PcdCloud)));
    File file;
    file.f = std::fopen(path, "rb");
    if (!file.f) {
        fail(c, "ファイルを開けません");
        return c;
    }
    FILE* f = file.f;

    std::vector<Field> fields;
    std::vector<int> sizes, counts;
    std::vector<char> types;
    long points = -1, width = 0, height = 1;
    std::string data, line;
    while (true) {
        if (!readLine(f, line)) {
            fail(c, "ヘッダーが途中で終わっています");
            return c;
        }
        auto t = tokens(line);
        if (t.empty() || t[0][0] == '#') continue;
        std::string key = lower(t[0]);
        if (key == "fields") {
            for (size_t i = 1; i < t.size(); ++i) {
                Field fd;
                fd.name = lower(t[i]);
                fields.push_back(fd);
            }
        } else if (key == "size") {
            for (size_t i = 1; i < t.size(); ++i) sizes.push_back(std::atoi(t[i].c_str()));
        } else if (key == "type") {
            for (size_t i = 1; i < t.size(); ++i) types.push_back(char(std::toupper(t[i][0])));
        } else if (key == "count") {
            for (size_t i = 1; i < t.size(); ++i) counts.push_back(std::atoi(t[i].c_str()));
        } else if (key == "width" && t.size() > 1) {
            width = std::atol(t[1].c_str());
        } else if (key == "height" && t.size() > 1) {
            height = std::atol(t[1].c_str());
        } else if (key == "points" && t.size() > 1) {
            points = std::atol(t[1].c_str());
        } else if (key == "data" && t.size() > 1) {
            data = lower(t[1]);
            break;
        }
    }
    if (points < 0) points = width * height;
    if (fields.empty() || sizes.size() < fields.size() || types.size() < fields.size()) {
        fail(c, "ヘッダーが不正です");
        return c;
    }
    int ix = -1, iy = -1, iz = -1, ii = -1;
    int off = 0;
    std::string names;
    for (size_t i = 0; i < fields.size(); ++i) {
        auto& fd = fields[i];
        fd.size = sizes[i];
        fd.type = types[i];
        fd.count = i < counts.size() ? counts[i] : 1;
        fd.off = off;
        off += fd.size * fd.count;
        if (fd.name == "x") ix = int(i);
        else if (fd.name == "y") iy = int(i);
        else if (fd.name == "z") iz = int(i);
        else if (ii < 0 && (fd.name == "intensity" || fd.name == "reflectivity" || fd.name == "i")) ii = int(i);
        names += (i ? " " : "") + fd.name;
    }
    std::snprintf(c->fields, sizeof c->fields, "%s", names.c_str());
    std::snprintf(c->format, sizeof c->format, "%s", data.c_str());
    if (ix < 0 || iy < 0 || iz < 0) {
        fail(c, "x/y/z フィールドがありません (" + names + ")");
        return c;
    }
    const int step = off;
    if (points <= 0) {
        fail(c, "点がありません");
        return c;
    }

    const long stride = points > max_points ? (points + max_points - 1) / max_points : 1;
    const long outN = (points + stride - 1) / stride;
    c->xyzi = allocPoints(c, size_t(outN));
    if (!c->xyzi) {
        fail(c, "メモリが足りません");
        return c;
    }
    c->total = int32_t(points);
    c->has_intensity = ii >= 0;
    int n = 0;
    auto emit = [&](float x, float y, float z, float in) {
        if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) || n >= outN) return;
        float* d = c->xyzi + 4 * size_t(n++);
        d[0] = x;
        d[1] = y;
        d[2] = z;
        d[3] = ii >= 0 ? in : -1.f;
    };

    if (data == "ascii") {
        std::vector<int> col(fields.size());
        for (size_t i = 1; i < fields.size(); ++i) col[i] = col[i - 1] + fields[i - 1].count;
        long i = 0;
        std::vector<float> vals;
        while (i < points && readLine(f, line)) {
            if (line.find_first_not_of(" \t") == std::string::npos) continue;
            if (i % stride == 0) {
                vals.clear();
                const char* s = line.c_str();
                char* end;
                while (true) {
                    float v = std::strtof(s, &end);
                    if (end == s) break;
                    vals.push_back(v);
                    s = end;
                }
                auto at = [&](int fi) { return size_t(col[fi]) < vals.size() ? vals[col[fi]] : NAN; };
                emit(at(ix), at(iy), at(iz), ii >= 0 ? (std::isfinite(at(ii)) ? at(ii) : 0.f) : -1.f);
            }
            ++i;
        }
    } else if (data == "binary") {
        const long chunk = 65536;
        std::vector<uint8_t> buf(size_t(chunk) * step);
        long read = 0;
        while (read < points) {
            long m = std::min(chunk, points - read);
            size_t got = std::fread(buf.data(), size_t(step), size_t(m), f);
            for (size_t j = 0; j < got; ++j) {
                if ((read + long(j)) % stride != 0) continue;
                const uint8_t* b = buf.data() + j * step;
                emit(value(b + fields[ix].off, fields[ix]), value(b + fields[iy].off, fields[iy]),
                     value(b + fields[iz].off, fields[iz]), ii >= 0 ? value(b + fields[ii].off, fields[ii]) : -1.f);
            }
            read += long(got);
            if (long(got) < m) break;   // truncated file: keep what we have
        }
    } else if (data == "binary_compressed") {
        uint32_t hdr[2];
        if (std::fread(hdr, 4, 2, f) != 2) {
            fail(c, "圧縮データが不正です");
            return c;
        }
        std::vector<uint8_t> comp(hdr[0]), raw(hdr[1]);
        if (std::fread(comp.data(), 1, comp.size(), f) != comp.size() ||
            !lzfDecompress(comp.data(), comp.size(), raw.data(), raw.size()) ||
            raw.size() < size_t(points) * step) {
            fail(c, "圧縮データを展開できません");
            return c;
        }
        // structure of arrays: field k starts at points * offset_k
        auto at = [&](int fi, long gi) {
            const Field& fd = fields[fi];
            return value(raw.data() + size_t(points) * fd.off + size_t(gi) * fd.size * fd.count, fd);
        };
        for (long gi = 0; gi < points; gi += stride)
            emit(at(ix, gi), at(iy, gi), at(iz, gi), ii >= 0 ? at(ii, gi) : -1.f);
    } else {
        fail(c, "未対応の DATA 形式: " + data);
        return c;
    }
    c->n = n;
    computeStats(c);
    return c;
}

void pcd_free(PcdCloud* c) {
    if (!c) return;
    if (c->xyzi) munmap(c->xyzi, c->alloc_bytes);
    std::free(c);
}

}  // extern "C"
