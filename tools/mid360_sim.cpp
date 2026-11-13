// Fake Livox Mid-360 over UDP: streams the same synthetic room as the app's demo mode
// (MobileSLAM/Bridge/Mid360Synth.hpp), e.g. to the app running in the iOS Simulator on this Mac.
//
//   clang++ -std=c++17 -O2 -IMobileSLAM/Bridge tools/mid360_sim.cpp -o /tmp/mid360_sim
//   /tmp/mid360_sim [dest_ip=127.0.0.1] [seconds=40] [points_per_s=100000]
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

#include "Mid360Synth.hpp"

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

    mndt::Mid360Synth synth(rate);
    uint8_t pkt[mndt::Mid360Synth::kPointPacketSize];
    const auto t0 = std::chrono::steady_clock::now();
    long sent = 0;
    std::printf("streaming to %s for %.0f s (%.0f pts/s)\n", ip, duration, rate);
    while (true) {
        const double t = std::min(synth.nextPointTime(), synth.nextImuTime());
        if (t > duration) break;
        std::this_thread::sleep_until(t0 + std::chrono::duration<double>(t));
        if (synth.nextImuTime() <= synth.nextPointTime()) {
            synth.imuPacket(pkt);
            sendto(fd, pkt, mndt::Mid360Synth::kImuPacketSize, 0, reinterpret_cast<sockaddr*>(&im), sizeof im);
        } else {
            synth.pointPacket(pkt);
            sendto(fd, pkt, mndt::Mid360Synth::kPointPacketSize, 0, reinterpret_cast<sockaddr*>(&pt), sizeof pt);
            if (++sent % 5000 == 0) std::printf("t=%.1fs  %ld packets\n", t, sent), std::fflush(stdout);
        }
    }
    close(fd);
    std::printf("done\n");
    return 0;
}
