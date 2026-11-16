// Minimal MCAP (https://mcap.dev/spec) + ROS 2 CDR helpers for rosbag recording / playback.
// Only uncompressed chunks are supported.
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace mcap {

constexpr uint8_t kMagic[8] = {0x89, 'M', 'C', 'A', 'P', 0x30, '\r', '\n'};

enum Op : uint8_t {
    kHeader = 0x01,
    kFooter = 0x02,
    kSchema = 0x03,
    kChannel = 0x04,
    kMessage = 0x05,
    kChunk = 0x06,
    kMessageIndex = 0x07,
    kChunkIndex = 0x08,
    kStatistics = 0x0B,
    kSummaryOffset = 0x0E,
    kDataEnd = 0x0F,
};

/// Little-endian byte buffer.
struct Buf {
    std::vector<uint8_t> b;

    size_t size() const { return b.size(); }
    void u8(uint8_t v) { b.push_back(v); }
    void u16(uint16_t v) { raw(&v, 2); }
    void u32(uint32_t v) { raw(&v, 4); }
    void u64(uint64_t v) { raw(&v, 8); }
    void raw(const void* p, size_t n) {
        const auto* c = static_cast<const uint8_t*>(p);
        b.insert(b.end(), c, c + n);
    }
    void str(const std::string& s) {
        u32(uint32_t(s.size()));
        raw(s.data(), s.size());
    }
};

/// Bounds-checked little-endian reader.
struct Rd {
    const uint8_t* p;
    size_t n;
    size_t i = 0;
    bool ok = true;

    bool need(size_t k) {
        if (!ok || i + k > n) {
            ok = false;
            return false;
        }
        return true;
    }
    template <class T>
    T get() {
        T v{};
        if (need(sizeof(T))) {
            std::memcpy(&v, p + i, sizeof(T));
            i += sizeof(T);
        }
        return v;
    }
    std::string str() {
        const uint32_t len = get<uint32_t>();
        if (!need(len)) return {};
        std::string s(reinterpret_cast<const char*>(p + i), len);
        i += len;
        return s;
    }
    void skip(size_t k) {
        if (need(k)) i += k;
    }
};

/// ROS 2 CDR (XCDR1, little endian) serializer. Alignment is relative to the end of the 4-byte encapsulation header.
struct CdrW {
    Buf o;

    CdrW() {
        o.u8(0x00);
        o.u8(0x01);
        o.u8(0x00);
        o.u8(0x00);
    }
    void align(size_t a) {
        while ((o.size() - 4) % a) o.u8(0);
    }
    void u8(uint8_t v) { o.u8(v); }
    void u32(uint32_t v) {
        align(4);
        o.u32(v);
    }
    void i32(int32_t v) { u32(uint32_t(v)); }
    void f64(double v) {
        align(8);
        o.raw(&v, 8);
    }
    void str(const std::string& s) {
        u32(uint32_t(s.size() + 1));
        o.raw(s.data(), s.size());
        o.u8(0);
    }
    void stamp(uint64_t ns, const std::string& frame) {
        i32(int32_t(ns / 1'000'000'000ull));
        u32(uint32_t(ns % 1'000'000'000ull));
        str(frame);
    }
};

/// ROS 2 CDR deserializer (little endian only).
struct CdrR {
    Rd r;

    CdrR(const uint8_t* p, size_t n) : r{p, n} {
        r.skip(4);
        if (r.ok && p[1] != 0x01) r.ok = false;   // big-endian CDR
    }
    void align(size_t a) {
        while (r.ok && (r.i - 4) % a) r.skip(1);
    }
    uint8_t u8() { return r.get<uint8_t>(); }
    uint32_t u32() {
        align(4);
        return r.get<uint32_t>();
    }
    int32_t i32() { return int32_t(u32()); }
    uint64_t u64() {
        align(8);
        return r.get<uint64_t>();
    }
    float f32() {
        align(4);
        return r.get<float>();
    }
    double f64() {
        align(8);
        return r.get<double>();
    }
    std::string str() {
        const uint32_t len = u32();
        if (!r.need(len)) return {};
        std::string s(reinterpret_cast<const char*>(r.p + r.i), len ? len - 1 : 0);
        r.i += len;
        return s;
    }
    /// std_msgs/Header -> stamp in ns.
    uint64_t header() {
        const int32_t sec = i32();
        const uint32_t nsec = u32();
        str();
        return uint64_t(int64_t(sec)) * 1'000'000'000ull + nsec;
    }
};

// ---- ROS 2 message definitions (ros2msg schema encoding) ----

constexpr const char* kSep = "================================================================================\n";

inline std::string headerDeps() {
    return std::string(kSep) + "MSG: std_msgs/Header\nbuiltin_interfaces/Time stamp\nstring frame_id\n" + kSep +
           "MSG: builtin_interfaces/Time\nint32 sec\nuint32 nanosec\n";
}

inline std::string imuSchema() {
    return std::string(
               "std_msgs/Header header\n"
               "geometry_msgs/Quaternion orientation\n"
               "float64[9] orientation_covariance\n"
               "geometry_msgs/Vector3 angular_velocity\n"
               "float64[9] angular_velocity_covariance\n"
               "geometry_msgs/Vector3 linear_acceleration\n"
               "float64[9] linear_acceleration_covariance\n") +
           headerDeps() + kSep + "MSG: geometry_msgs/Quaternion\nfloat64 x 0\nfloat64 y 0\nfloat64 z 0\nfloat64 w 1\n" +
           kSep + "MSG: geometry_msgs/Vector3\nfloat64 x\nfloat64 y\nfloat64 z\n";
}

inline std::string pointCloud2Schema() {
    return std::string(
               "std_msgs/Header header\n"
               "uint32 height\n"
               "uint32 width\n"
               "PointField[] fields\n"
               "bool is_bigendian\n"
               "uint32 point_step\n"
               "uint32 row_step\n"
               "uint8[] data\n"
               "bool is_dense\n") +
           headerDeps() + kSep +
           "MSG: sensor_msgs/PointField\n"
           "uint8 INT8 = 1\n"
           "uint8 UINT8 = 2\n"
           "uint8 INT16 = 3\n"
           "uint8 UINT16 = 4\n"
           "uint8 INT32 = 5\n"
           "uint8 UINT32 = 6\n"
           "uint8 FLOAT32 = 7\n"
           "uint8 FLOAT64 = 8\n"
           "string name\n"
           "uint32 offset\n"
           "uint8 datatype\n"
           "uint32 count\n";
}

}  // namespace mcap
