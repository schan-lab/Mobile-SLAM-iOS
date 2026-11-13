// Synthetic Livox Mid-360: point / IMU packets of a simple room scanned by a moving sensor.
// Used by the in-app demo mode (DemoSource.cpp) and by tools/mid360_sim.cpp.
//
// The sensor stands still for the first 3 s after restartMotion() (IMU initialisation), then moves and turns smoothly.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

namespace mndt {

class Mid360Synth {
public:
    static constexpr int kDot = 96;          // points per packet
    static constexpr int kPointPacketSize = 36 + kDot * 14;
    static constexpr int kImuPacketSize = 36 + 24;
    static constexpr double kImuDt = 0.005;  // 200 Hz

    explicit Mid360Synth(double points_per_s = 100000.0) : pkt_dt_(kDot / points_per_s) {}

    /// The motion starts over (3 s still, then moving) from sensor time t.
    void restartMotion(double t) { motion_t0_ = t; }

    /// Time of the next point packet / IMU packet (s, sensor clock starting at 0).
    double nextPointTime() const { return t_pkt_; }
    double nextImuTime() const { return t_imu_; }

    /// Writes the next point packet (kPointPacketSize bytes) and advances.
    void pointPacket(uint8_t* pkt) {
        header(pkt, kPointPacketSize, uint16_t(pkt_dt_ * 1e7), kDot, cnt_++, 1, stamp(t_pkt_));
        for (int i = 0; i < kDot; ++i) {
            Pose s = poseAt(t_pkt_ + pkt_dt_ * i / kDot);
            const double a = az_(rng_), e = el_(rng_);
            const double dl[3] = {std::cos(e) * std::cos(a), std::cos(e) * std::sin(a), std::sin(e)};
            const double c = std::cos(s.yaw), sn = std::sin(s.yaw);
            const double dw[3] = {c * dl[0] - sn * dl[1], sn * dl[0] + c * dl[1], dl[2]};
            uint8_t refl;
            const double r = cast(s.p, dw, refl) + noise_(rng_);
            uint8_t* q = pkt + 36 + i * 14;
            put32(q, int32_t(std::lround(dl[0] * r * 1000)));
            put32(q + 4, int32_t(std::lround(dl[1] * r * 1000)));
            put32(q + 8, int32_t(std::lround(dl[2] * r * 1000)));
            q[12] = refl;
            q[13] = 0;
        }
        t_pkt_ += pkt_dt_;
    }

    /// Writes the next IMU packet (kImuPacketSize bytes) and advances.
    void imuPacket(uint8_t* pkt) {
        Pose s = poseAt(t_imu_);
        const double c = std::cos(s.yaw), sn = std::sin(s.yaw);
        // specific force in the body frame (g units): R^T (a + g_up)
        const double ax = c * s.a[0] + sn * s.a[1], ay = -sn * s.a[0] + c * s.a[1];
        header(pkt, kImuPacketSize, 0, 1, icnt_++, 0, stamp(t_imu_));
        uint8_t* d = pkt + 36;
        putf(d, float(gnoise_(rng_)));
        putf(d + 4, float(gnoise_(rng_)));
        putf(d + 8, float(s.wz + gnoise_(rng_)));
        putf(d + 12, float(ax / 9.81));
        putf(d + 16, float(ay / 9.81));
        putf(d + 20, 1.0f);
        t_imu_ += kImuDt;
    }

private:
    struct Box {
        double lo[3], hi[3];
        uint8_t refl;
    };
    struct Pose { double p[3], yaw, a[3], wz; };

    // room (the sensor is at z = 0, about 1.5 m above the floor) and obstacles
    static const Box& room() {
        static const Box b{{-6, -5, -1.5}, {9, 5, 2.5}, 40};
        return b;
    }
    static const std::vector<Box>& obstacles() {
        static const std::vector<Box> v = {
            {{2, 2.2, -1.5}, {2.6, 2.8, 2.5}, 140},
            {{4, -3.5, -1.5}, {4.6, -2.6, 2.5}, 140},
            {{-3, 1, -1.5}, {-2.2, 1.6, 2.5}, 140},
            {{6.5, 0.5, -1.5}, {7.0, 1.2, 2.5}, 140},
            {{1, -2.5, -1.5}, {2.2, -1.5, -0.7}, 90},   // table
            {{-1, 3, -1.5}, {0.5, 4.99, 0.5}, 70},      // shelf against a wall
        };
        return v;
    }

    static bool slab(const double o[3], const double d[3], const Box& b, double& tn, double& tf) {
        tn = -1e30;
        tf = 1e30;
        for (int k = 0; k < 3; ++k) {
            if (std::fabs(d[k]) < 1e-12) {
                if (o[k] < b.lo[k] || o[k] > b.hi[k]) return false;
                continue;
            }
            double t1 = (b.lo[k] - o[k]) / d[k], t2 = (b.hi[k] - o[k]) / d[k];
            if (t1 > t2) std::swap(t1, t2);
            tn = std::max(tn, t1);
            tf = std::min(tf, t2);
        }
        return tn <= tf;
    }

    static double cast(const double o[3], const double d[3], uint8_t& refl) {
        double tn, tf;
        slab(o, d, room(), tn, tf);
        double best = tf;
        refl = room().refl;
        for (const auto& b : obstacles())
            if (slab(o, d, b, tn, tf) && tn > 0.05 && tn < best) {
                best = tn;
                refl = b.refl;
            }
        return best;
    }

    Pose poseAt(double t) const {
        Pose s{};
        const double tau = t - motion_t0_ - 3.0;   // still for 3 s
        if (tau <= 0) return s;
        const double A = 2.0, w = 0.3, B = 0.9, n = 0.45, C = 0.5, k = 0.5;
        s.p[0] = A * (1 - std::cos(w * tau));
        s.a[0] = A * w * w * std::cos(w * tau);
        s.p[1] = B * (1 - std::cos(n * tau));
        s.a[1] = B * n * n * std::cos(n * tau);
        s.yaw = C * (1 - std::cos(k * tau));
        s.wz = C * k * std::sin(k * tau);
        return s;
    }

    static uint64_t stamp(double t) { return uint64_t(t * 1e9) + 1'000'000'000ull; }
    static void put16(uint8_t* b, uint16_t v) { std::memcpy(b, &v, 2); }
    static void put32(uint8_t* b, int32_t v) { std::memcpy(b, &v, 4); }
    static void put64(uint8_t* b, uint64_t v) { std::memcpy(b, &v, 8); }
    static void putf(uint8_t* b, float v) { std::memcpy(b, &v, 4); }

    static void header(uint8_t* b, int len, uint16_t interval, uint16_t dot, uint16_t cnt, uint8_t type, uint64_t ts) {
        std::memset(b, 0, 36);
        put16(b + 1, uint16_t(len));
        put16(b + 3, interval);
        put16(b + 5, dot);
        put16(b + 7, cnt);
        b[10] = type;
        put64(b + 28, ts);
    }

    double pkt_dt_;
    double t_pkt_ = 0, t_imu_ = 0, motion_t0_ = 0;
    uint16_t cnt_ = 0, icnt_ = 0;
    std::mt19937 rng_{1};
    std::uniform_real_distribution<double> az_{-M_PI, M_PI}, el_{-7 * M_PI / 180, 52 * M_PI / 180};
    std::normal_distribution<double> noise_{0, 0.01}, gnoise_{0, 0.002};
};

}  // namespace mndt
