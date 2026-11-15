// Packet queue + processing thread around mndt::Lio.
#include "SlamBridge.h"

#include <os/log.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include "lio.hpp"
#include "livox_packet.hpp"

#define LOGI(...) os_log_info(OS_LOG_DEFAULT, "[Mid360Slam] " __VA_ARGS__)

namespace {

struct Packet {
    int type;
    std::vector<uint8_t> data;
};

class Engine {
public:
    Engine() : worker_([this] { run(); }) {}
    ~Engine() {
        {
            std::lock_guard<std::mutex> l(mtx_);
            quit_ = true;
        }
        cv_.notify_all();
        worker_.join();
    }

    void start(int mode) {
        std::lock_guard<std::mutex> l(mtx_);
        queue_.clear();
        mode_ = mode;
        reset_ = true;
        running_ = true;
        dropped_pkts_ = 0;
        cv_.notify_one();
    }
    void stop() {
        std::lock_guard<std::mutex> l(mtx_);
        running_ = false;
        queue_.clear();
    }
    bool running() const { return running_; }

    void push(int type, const uint8_t* buf, int len) {
        if (!running_) return;
        {
            std::lock_guard<std::mutex> l(mtx_);
            // If processing falls behind (~1 s backlog) drop point packets, but always keep IMU.
            if (type == 1 && queue_.size() > 2500) {
                ++dropped_pkts_;
                return;
            }
            queue_.push_back({type, std::vector<uint8_t>(buf, buf + len)});
        }
        cv_.notify_one();
    }

    mndt::Lio lio;
    std::mutex lio_mtx_;   // held while the worker mutates lio (processing / reset / prior map)
    std::atomic<int> mode_{0};
    std::atomic<long> dropped_pkts_{0};
    std::atomic<int> queue_len_{0};

private:
    void run() {
        std::vector<Packet> batch;
        while (true) {
            {
                std::unique_lock<std::mutex> l(mtx_);
                cv_.wait(l, [this] { return quit_ || !queue_.empty() || reset_; });
                if (quit_) return;
                if (reset_) {
                    std::lock_guard<std::mutex> ll(lio_mtx_);
                    lio.setMode(mode_ == 1 ? mndt::LioMode::Localization : mndt::LioMode::Mapping);
                    lio.reset();
                    reset_ = false;
                }
                batch.clear();
                while (!queue_.empty() && batch.size() < 256) {
                    batch.push_back(std::move(queue_.front()));
                    queue_.pop_front();
                }
                queue_len_ = static_cast<int>(queue_.size());
            }
            std::lock_guard<std::mutex> ll(lio_mtx_);
            for (auto& p : batch) {
                lio.addPacket(p.type, p.data.data(), static_cast<int>(p.data.size()));
                while (lio.step()) {}
            }
        }
    }

    std::mutex mtx_;
    std::condition_variable cv_;
    std::deque<Packet> queue_;
    bool quit_ = false, reset_ = false;
    std::atomic<bool> running_{false};
    std::thread worker_;
};

Engine* E(SlamHandle h) { return reinterpret_cast<Engine*>(h); }

int copyXyz(const std::vector<Eigen::Vector3f>& v, size_t start, float* out, int max_pts) {
    int n = 0;
    for (size_t i = start; i < v.size() && n < max_pts; ++i, ++n) {
        out[4 * n] = v[i].x();
        out[4 * n + 1] = v[i].y();
        out[4 * n + 2] = v[i].z();
        out[4 * n + 3] = -1.f;
    }
    return n;
}

}  // namespace

extern "C" {

SlamHandle slam_create(void) { return reinterpret_cast<SlamHandle>(new Engine()); }

void slam_destroy(SlamHandle h) { delete E(h); }

void slam_start(SlamHandle h, int32_t mode) {
    LOGI("start mode=%d", mode);
    E(h)->start(mode);
}

void slam_stop(SlamHandle h) {
    LOGI("stop");
    E(h)->stop();
}

void slam_prepare(SlamHandle h, int32_t mode) {
    Engine* e = E(h);
    e->mode_ = mode;
    std::lock_guard<std::mutex> ll(e->lio_mtx_);
    e->lio.setMode(mode == 1 ? mndt::LioMode::Localization : mndt::LioMode::Mapping);
    e->lio.reset();
}

void slam_set_initial_pose(SlamHandle h, float x, float y, float z, float yaw, int32_t has_yaw) {
    Engine* e = E(h);
    std::lock_guard<std::mutex> ll(e->lio_mtx_);
    e->lio.setInitialGuess(mndt::Vec3(x, y, z), yaw, !has_yaw);
    e->lio.requestRelocalize();
    LOGI("initial pose %.2f %.2f %.2f yaw %.1f deg (search %d)", x, y, z, yaw * 57.2958, !has_yaw);
}

void slam_set_blind(SlamHandle h, float m) {
    Engine* e = E(h);
    std::lock_guard<std::mutex> ll(e->lio_mtx_);
    e->lio.setBlind(m);
}

void slam_push(SlamHandle h, int32_t type, const uint8_t* buf, int32_t len) {
    Engine* e = E(h);
    if (!e->running()) return;
    e->push(type, buf, len);
}

void slam_get_status(SlamHandle h, SlamStatus* o) {
    Engine* e = E(h);
    auto st = e->lio.stats();
    mndt::Mat3 R;
    mndt::Vec3 p;
    e->lio.pose(R, p);
    o->status = static_cast<int32_t>(e->lio.status());
    o->scans = st.scans;
    o->dropped_scans = st.dropped_scans;
    o->dropped_pkts = e->dropped_pkts_.load();
    o->queue = e->queue_len_.load();
    o->last_ms = st.last_ms;
    o->avg_ms = st.avg_ms;
    o->effective = st.effective;
    o->ds_points = st.ds_points;
    o->map_size = static_cast<int64_t>(st.map_size);
    o->vis_size = static_cast<int64_t>(st.vis_size);
    o->px = p.x();
    o->py = p.y();
    o->pz = p.z();
    o->yaw = std::atan2(R(1, 0), R(0, 0));
    o->degenerate = st.degenerate;
    o->running = e->running() ? 1 : 0;
    o->mode = e->mode_.load();
    o->loc_state = st.loc_state;
    o->match = st.match;
    o->ndt_ms = st.ndt_ms;
    o->has_prior = e->lio.hasPriorMap() ? 1 : 0;
}

int32_t slam_map(SlamHandle h, float* out, int32_t max_pts) { return E(h)->lio.mapSnapshot(out, max_pts); }

int32_t slam_trajectory(SlamHandle h, float* out, int32_t max_pts) {
    return copyXyz(E(h)->lio.trajectory(size_t(std::max(max_pts, 0))), 0, out, max_pts);
}

int32_t slam_scan(SlamHandle h, float* out, int32_t max_pts) { return copyXyz(E(h)->lio.lastScan(), 0, out, max_pts); }

int32_t slam_save_pcd(SlamHandle h, const char* path) { return E(h)->lio.savePcd(path) ? 1 : 0; }

int32_t slam_set_prior_map(SlamHandle h, const PcdCloud* c) {
    if (!c || c->n <= 0) return 0;
    std::vector<Eigen::Vector3f> pts(c->n);
    std::vector<float> in;
    if (c->has_intensity) in.resize(c->n);
    for (int i = 0; i < c->n; ++i) {
        pts[i] = Eigen::Vector3f(c->xyzi[4 * i], c->xyzi[4 * i + 1], c->xyzi[4 * i + 2]);
        if (c->has_intensity) in[i] = c->xyzi[4 * i + 3];
    }
    Engine* e = E(h);
    {
        std::lock_guard<std::mutex> ll(e->lio_mtx_);
        e->lio.setPriorMap(pts, in);
    }
    LOGI("prior map: %d points", c->n);
    return e->lio.hasPriorMap() ? 1 : 0;
}

// ------------------------------------------------------------------ live points

}  // extern "C"

struct LivePoints {
    explicit LivePoints(int cap) : capacity(cap), xyzi(size_t(cap) * 4) {}
    std::mutex mtx;
    int capacity;
    std::vector<float> xyzi;
    int head = 0, size = 0;
};

extern "C" {

LiveHandle live_create(int32_t capacity) { return new LivePoints(std::max(1, capacity)); }
void live_destroy(LiveHandle h) { delete h; }
int32_t live_capacity(LiveHandle h) { return h->capacity; }

int32_t live_add_packet(LiveHandle h, const uint8_t* buf, int32_t len) {
    std::lock_guard<std::mutex> l(h->mtx);
    return mndt::parsePointPacket(buf, len, [h](const mndt::RawPoint& p) {
        float* d = &h->xyzi[size_t(h->head) * 4];
        d[0] = p.x;
        d[1] = p.y;
        d[2] = p.z;
        d[3] = float(p.refl);
        h->head = (h->head + 1) % h->capacity;
        if (h->size < h->capacity) h->size++;
    });
}

int32_t live_snapshot(LiveHandle h, float* out, int32_t max_pts) {
    std::lock_guard<std::mutex> l(h->mtx);
    int n = std::min(h->size, max_pts);
    std::copy(h->xyzi.begin(), h->xyzi.begin() + size_t(n) * 4, out);
    return n;
}

int32_t livox_parse_imu(const uint8_t* buf, int32_t len, float out6[6]) {
    double t, g[3], a[3];
    if (!mndt::parseImuPacket(buf, len, t, g, a)) return 0;
    for (int i = 0; i < 3; ++i) {
        out6[i] = float(g[i]);
        out6[3 + i] = float(a[i] / mndt::kGravity);
    }
    return 1;
}

}  // extern "C"
