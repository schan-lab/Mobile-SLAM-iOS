// In-app demo: streams synthetic Mid-360 packets in real time from a background thread.
#include <atomic>
#include <chrono>
#include <thread>

#include "Mid360Synth.hpp"
#include "SlamBridge.h"

struct DemoSource {
    DemoPacketFn fn;
    void* ctx;
    std::atomic<bool> quit{false};
    std::atomic<bool> restart{false};
    std::thread worker;

    void run() {
        mndt::Mid360Synth synth;
        uint8_t pkt[mndt::Mid360Synth::kPointPacketSize];
        const auto t0 = std::chrono::steady_clock::now();
        while (!quit) {
            const double t = std::min(synth.nextPointTime(), synth.nextImuTime());
            if (restart.exchange(false)) synth.restartMotion(t);
            std::this_thread::sleep_until(t0 + std::chrono::duration<double>(t));
            if (synth.nextImuTime() <= synth.nextPointTime()) {
                synth.imuPacket(pkt);
                fn(ctx, 2, pkt, mndt::Mid360Synth::kImuPacketSize);
            } else {
                synth.pointPacket(pkt);
                fn(ctx, 1, pkt, mndt::Mid360Synth::kPointPacketSize);
            }
        }
    }
};

extern "C" {

DemoHandle demo_start(DemoPacketFn fn, void* ctx) {
    auto* d = new DemoSource{fn, ctx};
    d->worker = std::thread([d] { d->run(); });
    return d;
}

void demo_restart_motion(DemoHandle h) { h->restart = true; }

void demo_stop(DemoHandle h) {
    h->quit = true;
    h->worker.join();
    delete h;
}

}  // extern "C"
