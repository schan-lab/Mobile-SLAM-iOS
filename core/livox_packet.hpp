// Livox SDK2 (Mid-360) UDP packet parsing. Platform independent.
#pragma once
#include <cstdint>
#include <cstring>

namespace mndt {

struct RawPoint {
    double t;        // seconds (LiDAR clock)
    float x, y, z;   // metres, LiDAR frame
    uint8_t refl;
    uint8_t tag;
};

namespace detail {
inline uint16_t rd16(const uint8_t* p) {
    uint16_t v;
    std::memcpy(&v, p, 2);
    return v;
}
inline uint64_t rd64(const uint8_t* p) {
    uint64_t v;
    std::memcpy(&v, p, 8);
    return v;
}
inline int32_t rd32s(const uint8_t* p) {
    int32_t v;
    std::memcpy(&v, p, 4);
    return v;
}
inline int16_t rd16s(const uint8_t* p) {
    int16_t v;
    std::memcpy(&v, p, 2);
    return v;
}
inline float rdf(const uint8_t* p) {
    float v;
    std::memcpy(&v, p, 4);
    return v;
}
}  // namespace detail

constexpr int kLivoxHeader = 36;
constexpr double kGravity = 9.81;

/// Parses a point packet; calls emit(const RawPoint&) for each non-zero point.
/// Per-point time = timestamp + i * time_interval(0.1us) / dot_num.
template <class F>
inline int parsePointPacket(const uint8_t* buf, int len, F&& emit) {
    using namespace detail;
    if (len < kLivoxHeader) return 0;
    const uint16_t interval = rd16(buf + 3);  // 0.1 us units
    const uint16_t dot = rd16(buf + 5);
    const uint8_t type = buf[10];
    const double t0 = static_cast<double>(rd64(buf + 28)) * 1e-9;
    const double dtp = dot ? interval * 1e-7 / dot : 0.0;
    int n = 0;
    if (type == 1) {  // int32 mm
        for (int i = 0; i < dot; ++i) {
            const uint8_t* q = buf + kLivoxHeader + i * 14;
            if (q + 14 > buf + len) break;
            int32_t x = rd32s(q), y = rd32s(q + 4), z = rd32s(q + 8);
            if (x == 0 && y == 0 && z == 0) continue;
            emit(RawPoint{t0 + i * dtp, x * 1e-3f, y * 1e-3f, z * 1e-3f, q[12], q[13]});
            ++n;
        }
    } else if (type == 2) {  // int16 cm
        for (int i = 0; i < dot; ++i) {
            const uint8_t* q = buf + kLivoxHeader + i * 8;
            if (q + 8 > buf + len) break;
            int16_t x = rd16s(q), y = rd16s(q + 2), z = rd16s(q + 4);
            if (x == 0 && y == 0 && z == 0) continue;
            emit(RawPoint{t0 + i * dtp, x * 1e-2f, y * 1e-2f, z * 1e-2f, q[6], q[7]});
            ++n;
        }
    }
    return n;
}

/// Parses an IMU packet. gyro in rad/s, acc converted from g to m/s^2.
inline bool parseImuPacket(const uint8_t* buf, int len, double& t, double gyr[3], double acc[3]) {
    using namespace detail;
    if (len < kLivoxHeader + 24 || buf[10] != 0) return false;
    t = static_cast<double>(rd64(buf + 28)) * 1e-9;
    const uint8_t* d = buf + kLivoxHeader;
    for (int i = 0; i < 3; ++i) gyr[i] = rdf(d + 4 * i);
    for (int i = 0; i < 3; ++i) acc[i] = rdf(d + 12 + 4 * i) * kGravity;
    return true;
}

}  // namespace mndt
