// Fake Livox Mid-360: streams synthetic point / IMU UDP packets of a simple room, for testing the app
// without hardware (e.g. against the iOS Simulator on this Mac).
//
//   clang++ -std=c++17 -O2 tools/mid360_sim.cpp -o /tmp/mid360_sim
//   /tmp/mid360_sim [dest_ip=127.0.0.1] [seconds=40] [points_per_s=100000]
//
// The sensor stands still for the first 3 s (IMU initialisation), then moves and turns smoothly.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <thread>
#include <vector>

namespace {

struct Box {
    double lo[3], hi[3];
    uint8_t refl;
};

// room (the sensor is at z = 0, about 1.5 m above the floor) and obstacles
const Box kRoom{{-6, -5, -1.5}, {9, 5, 2.5}, 40};
const std::vector<Box> kObstacles = {
    {{2, 2, -1.5}, {2.6, 2.6, 2.5}, 140},
    {{4, -3.5, -1.5}, {4.6, -2.6, 2.5}, 140},
    {{-3, 1, -1.5}, {-2.2, 1.6, 2.5}, 140},
    {{6.5, 0.5, -1.5}, {7.0, 1.2, 2.5}, 140},
    {{1, -2.5, -1.5}, {2.2, -1.5, -0.7}, 90},   // table
    {{-1, 3, -1.5}, {0.5, 4.99, 0.5}, 70},      // shelf against a wall
};

/// Ray / box slab test. Returns entry (tn) and exit (tf) distances.
bool slab(const double o[3], const double d[3], const Box& b, double& tn, double& tf) {
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

/// Distance to the first surface along the ray, and its reflectivity.
double cast(const double o[3], const double d[3], uint8_t& refl) {
    double tn, tf;
    slab(o, d, kRoom, tn, tf);
    double best = tf;
    refl = kRoom.refl;
    for (const auto& b : kObstacles)
        if (slab(o, d, b, tn, tf) && tn > 0.05 && tn < best) {
            best = tn;
            refl = b.refl;
        }
    return best;
}

struct Pose { double p[3], yaw, v[3], a[3], wz; };

Pose poseAt(double t) {
    Pose s{};
    const double tau = t - 3.0;   // still for 3 s
    if (tau <= 0) return s;
    const double A = 2.0, w = 0.3, B = 1.0, n = 0.45, C = 0.5, k = 0.5;
    s.p[0] = A * (1 - std::cos(w * tau));
    s.v[0] = A * w * std::sin(w * tau);
    s.a[0] = A * w * w * std::cos(w * tau);
    s.p[1] = B * (1 - std::cos(n * tau));
    s.v[1] = B * n * std::sin(n * tau);
    s.a[1] = B * n * n * std::cos(n * tau);
    s.yaw = C * (1 - std::cos(k * tau));
    s.wz = C * k * std::sin(k * tau);
    return s;
}

void put16(uint8_t* b, uint16_t v) { std::memcpy(b, &v, 2); }
void put32(uint8_t* b, int32_t v) { std::memcpy(b, &v, 4); }
void put64(uint8_t* b, uint64_t v) { std::memcpy(b, &v, 8); }
void putf(uint8_t* b, float v) { std::memcpy(b, &v, 4); }

void header(uint8_t* b, uint16_t len, uint16_t interval, uint16_t dot, uint16_t cnt, uint8_t type, uint64_t ts_ns) {
    std::memset(b, 0, 36);
    b[0] = 0;
    put16(b + 1, len);
    put16(b + 3, interval);
    put16(b + 5, dot);
    put16(b + 7, cnt);
    b[9] = 0;
    b[10] = type;
    b[11] = 0;
    put64(b + 28, ts_ns);
}

}  // namespace

int main(int argc, char** argv) {
    const char* ip = argc > 1 ? argv[1] : "127.0.0.1";
    const double duration = argc > 2 ? std::atof(argv[2]) : 40.0;
    const double rate = argc > 3 ? std::atof(argv[3]) : 100000.0;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in pt{}, im{};
    pt.sin_family = im.sin_family = AF_INET;
    inet_pton(AF_INET, ip, &pt.sin_addr);
    im.sin_addr = pt.sin_addr;
    pt.sin_port = htons(56301);
    im.sin_port = htons(56401);

    constexpr int kDot = 96;
    const double pkt_dt = kDot / rate;          // s per point packet
    const double imu_dt = 0.005;                // 200 Hz
    std::mt19937 rng(1);
    std::uniform_real_distribution<double> az(-M_PI, M_PI), el(-7 * M_PI / 180, 52 * M_PI / 180);
    std::normal_distribution<double> noise(0, 0.01), gnoise(0, 0.002);

    std::vector<uint8_t> pkt(36 + kDot * 14), ipkt(36 + 24);
    uint16_t cnt = 0, icnt = 0;
    double t_pkt = 0, t_imu = 0;
    const auto t0 = std::chrono::steady_clock::now();
    long sent = 0;
    std::printf("streaming to %s for %.0f s (%.0f pts/s)\n", ip, duration, rate);
    while (true) {
        const double t = std::min(t_pkt, t_imu);
        if (t > duration) break;
        std::this_thread::sleep_until(t0 + std::chrono::duration<double>(t));
        const uint64_t ts = uint64_t(t * 1e9) + 1'000'000'000ull;
        if (t_imu <= t_pkt) {
            Pose s = poseAt(t_imu);
            const double c = std::cos(s.yaw), sn = std::sin(s.yaw);
            // specific force in the body frame (g units): R^T (a + g_up)
            double ax = c * s.a[0] + sn * s.a[1], ay = -sn * s.a[0] + c * s.a[1];
            header(ipkt.data(), uint16_t(ipkt.size()), 0, 1, icnt++, 0, ts);
            uint8_t* d = ipkt.data() + 36;
            putf(d, float(gnoise(rng)));
            putf(d + 4, float(gnoise(rng)));
            putf(d + 8, float(s.wz + gnoise(rng)));
            putf(d + 12, float(ax / 9.81));
            putf(d + 16, float(ay / 9.81));
            putf(d + 20, 1.0f);
            sendto(fd, ipkt.data(), ipkt.size(), 0, reinterpret_cast<sockaddr*>(&im), sizeof im);
            t_imu += imu_dt;
        } else {
            header(pkt.data(), uint16_t(pkt.size()), uint16_t(pkt_dt * 1e7), kDot, cnt++, 1, ts);
            for (int i = 0; i < kDot; ++i) {
                Pose s = poseAt(t_pkt + pkt_dt * i / kDot);
                const double a = az(rng), e = el(rng);
                double dl[3] = {std::cos(e) * std::cos(a), std::cos(e) * std::sin(a), std::sin(e)};
                const double c = std::cos(s.yaw), sn = std::sin(s.yaw);
                double dw[3] = {c * dl[0] - sn * dl[1], sn * dl[0] + c * dl[1], dl[2]};
                uint8_t refl;
                double r = cast(s.p, dw, refl) + noise(rng);
                uint8_t* q = pkt.data() + 36 + i * 14;
                put32(q, int32_t(std::lround(dl[0] * r * 1000)));
                put32(q + 4, int32_t(std::lround(dl[1] * r * 1000)));
                put32(q + 8, int32_t(std::lround(dl[2] * r * 1000)));
                q[12] = refl;
                q[13] = 0;
            }
            sendto(fd, pkt.data(), pkt.size(), 0, reinterpret_cast<sockaddr*>(&pt), sizeof pt);
            t_pkt += pkt_dt;
            if (++sent % 5000 == 0) std::printf("t=%.1fs  %ld packets\n", t, sent), std::fflush(stdout);
        }
    }
    close(fd);
    std::printf("done\n");
    return 0;
}
