// LiDAR-inertial odometry following the FAST-LIO formulation
// (W. Xu, F. Zhang, "FAST-LIO", RA-L 2021): IMU forward propagation,
// backward motion compensation, iterated error-state Kalman filter with
// point-to-plane residuals. Independent implementation (not derived from the
// GPL reference code). Platform independent.
#pragma once
#include <Eigen/Dense>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "livox_packet.hpp"
#include "ndt.hpp"
#include "voxel_map.hpp"

namespace mndt {

using Vec3 = Eigen::Vector3d;
using Mat3 = Eigen::Matrix3d;

struct LioConfig {
    double scan_period = 0.1;     // s, Mid-360 10 Hz
    double blind = 1.5;           // m, ignore points closer than this (LiDAR frame)
    double max_range = 60.0;      // m
    double scan_ds = 0.2;         // m, voxel size for scan downsampling
    double map_res = 0.2;         // m, voxel size of the registration map
    double vis_res = 0.05;        // m, voxel size of the display / export map
    int max_iter = 4;
    double plane_thresh = 0.1;    // m
    double knn_max_d2 = 5.0;      // m^2
    double gyr_cov = 0.1, acc_cov = 0.1, bg_cov = 1e-4, ba_cov = 1e-4;
    double laser_cov = 0.001;
    int init_imu_samples = 200;   // ~1 s at 200 Hz
    // LiDAR -> IMU extrinsic (p_I = R_LI * p_L + t_LI). Mid-360 default.
    Mat3 R_LI = Mat3::Identity();
    Vec3 t_LI = Vec3(-0.011, -0.02329, 0.04412);

    // ---- localisation (NDT against a prior map) ----
    double ndt_res = 1.0;          // m, NDT voxel size
    double ndt_src_ds = 0.4;       // m, scan downsampling for NDT
    double loc_match_ok = 0.35;    // min match ratio to accept an NDT result while tracking
    double loc_match_init = 0.45;  // min match ratio to accept the global initial search
    int loc_lost_after = 20;       // consecutive failed scans before declaring "lost"
    double loc_cov_rot = 1e-4;     // rad^2, NDT pose measurement noise
    double loc_cov_pos = 4e-4;     // m^2
    double loc_init_radius = 1.0;  // m, xy search radius around the initial guess
    int loc_init_scans = 5;        // scans accumulated before the initial search
};

enum class LioStatus { WaitingData = 0, Initializing = 1, Running = 2 };
enum class LioMode { Mapping = 0, Localization = 1 };
enum class LocState { None = 0, Searching = 1, Tracking = 2, Lost = 3 };

struct LioStats {
    double last_ms = 0, avg_ms = 0;
    int effective = 0, iterations = 0, scan_points = 0, ds_points = 0;
    long scans = 0, dropped_scans = 0, degenerate = 0;
    size_t map_size = 0, vis_size = 0;
    // localisation
    int loc_state = 0;
    double match = 0, ndt_score = 0, ndt_ms = 0;
    int ndt_iters = 0, loc_fail = 0;
};

class Lio {
public:
    explicit Lio(const LioConfig& cfg = LioConfig());

    void reset();
    /// Selects mapping (LIO + map building) or localisation (NDT against the prior map). Call before reset().
    void setMode(LioMode m) { mode_ = m; }
    LioMode mode() const { return mode_; }
    /// Points closer than this (m, LiDAR frame) are ignored. Takes effect from the next scan.
    void setBlind(double m) { cfg_.blind = m < 0 ? 0 : m; }
    double blind() const { return cfg_.blind; }
    /// Replaces the tuning parameters. Map resolutions apply from the next reset(); the NDT grid of the prior
    /// map is rebuilt when ndt_res changes.
    void setConfig(const LioConfig& c);
    const LioConfig& config() const { return cfg_; }
    /// Sets the prior map for localisation (world frame). Builds the NDT grid.
    /// intensity (optional, same length as pts) is only used for display.
    void setPriorMap(const std::vector<Eigen::Vector3f>& pts, const std::vector<float>& intensity = {});
    bool hasPriorMap() const { return !ndt_map_.empty(); }
    /// Initial guess for localisation (world xy + yaw). Default: origin, yaw searched.
    void setInitialGuess(const Vec3& p, double yaw, bool search_yaw) {
        init_guess_p_ = p;
        init_guess_yaw_ = yaw;
        init_search_yaw_ = search_yaw;
    }
    /// Forces a new initial search from the current initial guess (localisation mode).
    void requestRelocalize() {
        if (loc_state_ == LocState::Tracking || loc_state_ == LocState::Lost) loc_state_ = LocState::Searching;
        relocalize_ = true;
    }
    void addImu(double t, const Vec3& gyr, const Vec3& acc_mps2);
    void addPoint(const RawPoint& p);
    /// Feeds a raw Livox packet (type 1 = point, 2 = IMU).
    void addPacket(int type, const uint8_t* buf, int len);
    /// Processes at most one ready scan. Returns true if any work was done.
    bool step();

    // ---- thread-safe output accessors ----
    LioStatus status() const {
        std::lock_guard<std::mutex> l(out_mtx_);
        return out_status_;
    }
    LioStats stats() const {
        std::lock_guard<std::mutex> l(out_mtx_);
        return out_stats_;
    }
    void pose(Mat3& R, Vec3& p) const {
        std::lock_guard<std::mutex> l(out_mtx_);
        R = out_R_;
        p = out_p_;
    }
    /// The most recent max_pts trajectory points (oldest first).
    std::vector<Eigen::Vector3f> trajectory(size_t max_pts) const {
        std::lock_guard<std::mutex> l(out_mtx_);
        const size_t start = out_traj_.size() > max_pts ? out_traj_.size() - max_pts : 0;
        return std::vector<Eigen::Vector3f>(out_traj_.begin() + start, out_traj_.end());
    }
    std::vector<Eigen::Vector3f> lastScan() const {
        std::lock_guard<std::mutex> l(out_mtx_);
        return out_scan_;
    }
    /// Copies up to maxPts display-map points (x, y, z, intensity interleaved; intensity < 0 = unknown)
    /// with uniform stride; returns count.
    int mapSnapshot(float* out, int maxPts) const;
    bool savePcd(const std::string& path) const;
    double currentTime() const { return t_state_; }
    Vec3 velocity() const { return v_; }
    Vec3 gyroBias() const { return bg_; }
    Vec3 accBias() const { return ba_; }

private:
    struct Imu {
        double t;
        Vec3 gyr, acc;
    };
    struct Scan {
        double start, end;
        std::vector<RawPoint> pts;
    };
    struct Seg {
        double t0;
        Mat3 R;
        Vec3 p, v, w, aw;
    };
    using Mat15 = Eigen::Matrix<double, 15, 15>;
    using Vec15 = Eigen::Matrix<double, 15, 1>;

    void tryInit();
    void integrate(double t1, const Vec3& gyr, const Vec3& acc, std::vector<Seg>* segs);
    void propagateTo(double t_end, std::vector<Seg>& segs);
    void processScan(const Scan& s);
    void iekfUpdate(const std::vector<Vec3>& body);
    void publish(const std::vector<Vec3>& body, const std::vector<float>& inten);
    void localize(const std::vector<Vec3>& body);
    bool globalSearch(const std::vector<Vec3>& src, const Vec3& center, double yaw0, bool search_yaw);
    void poseUpdate(const Mat3& Rm, const Vec3& pm);

    LioConfig cfg_;

    // inputs
    std::deque<Imu> imu_;
    std::vector<Imu> init_buf_;
    int init_fail_ = 0;
    Scan cur_;
    bool have_cur_ = false;
    std::deque<Scan> ready_;

    // filter state (IMU frame in world): error order [dtheta, dp, dv, dbg, dba]
    bool inited_ = false;
    double t_state_ = 0;
    Mat3 R_ = Mat3::Identity();
    Vec3 p_ = Vec3::Zero(), v_ = Vec3::Zero(), bg_ = Vec3::Zero(), ba_ = Vec3::Zero();
    Vec3 g_ = Vec3(0, 0, -kGravity);
    double acc_scale_ = 1.0;
    Imu last_imu_{};
    Mat15 P_ = Mat15::Identity();

    VoxelMap map_;
    PointStore vis_;

    // localisation
    LioMode mode_ = LioMode::Mapping;
    NdtMap ndt_map_;
    std::vector<Eigen::Vector3f> prior_pts_;
    std::vector<float> prior_int_;   // empty, or one intensity per prior point
    LocState loc_state_ = LocState::None;
    int loc_fail_ = 0;
    Vec3 init_guess_p_ = Vec3::Zero();
    double init_guess_yaw_ = 0;
    bool init_search_yaw_ = true;
    bool relocalize_ = false;
    std::vector<Vec3> loc_accum_;   // world-frame (dead-reckoned) points gathered for the initial search
    int loc_accum_scans_ = 0;
    LioStats stats_;

    // outputs
    mutable std::mutex out_mtx_;
    LioStatus out_status_ = LioStatus::WaitingData;
    LioStats out_stats_;
    Mat3 out_R_ = Mat3::Identity();
    Vec3 out_p_ = Vec3::Zero();
    std::vector<Eigen::Vector3f> out_traj_, out_scan_;
};

}  // namespace mndt
