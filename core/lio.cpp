#include "lio.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <unordered_map>

namespace mndt {

namespace {

Mat3 skew(const Vec3& v) {
    Mat3 m;
    m << 0, -v.z(), v.y(), v.z(), 0, -v.x(), -v.y(), v.x(), 0;
    return m;
}

Mat3 Exp(const Vec3& w) {
    double th = w.norm();
    if (th < 1e-10) return Mat3::Identity() + skew(w);
    return Eigen::AngleAxisd(th, w / th).toRotationMatrix();
}

Vec3 Log(const Mat3& R) {
    Eigen::AngleAxisd aa(R);
    return aa.angle() * aa.axis();
}

/// Least-squares plane n.x + d = 0 through pts (FAST-LIO style: solve A*w = -1).
bool fitPlane(const Eigen::Vector3f* q, int n, double thresh, Vec3& nrm, double& d) {
    Eigen::Matrix<double, Eigen::Dynamic, 3> A(n, 3);
    Eigen::VectorXd b = -Eigen::VectorXd::Ones(n);
    for (int i = 0; i < n; ++i) A.row(i) = q[i].cast<double>().transpose();
    Vec3 w = A.colPivHouseholderQr().solve(b);
    double nn = w.norm();
    if (!std::isfinite(nn) || nn < 1e-9) return false;
    nrm = w / nn;
    d = 1.0 / nn;
    for (int i = 0; i < n; ++i)
        if (std::fabs(nrm.dot(q[i].cast<double>()) + d) > thresh) return false;
    return true;
}

/// Voxel-grid downsampling (centroid per voxel).
std::vector<Vec3> voxelDownsample(const std::vector<Vec3>& pts, double res) {
    std::unordered_map<uint64_t, std::pair<Vec3, int>> grid;
    grid.reserve(pts.size() / 4 + 16);
    const double inv = 1.0 / res;
    constexpr uint64_t M = (1u << 21) - 1;
    for (const auto& p : pts) {
        uint64_t key = ((uint64_t(int(std::floor(p.x() * inv))) & M) << 42) |
                       ((uint64_t(int(std::floor(p.y() * inv))) & M) << 21) |
                       (uint64_t(int(std::floor(p.z() * inv))) & M);
        auto it = grid.find(key);
        if (it == grid.end()) it = grid.emplace(key, std::make_pair(Vec3::Zero().eval(), 0)).first;
        it->second.first += p;
        it->second.second++;
    }
    std::vector<Vec3> out;
    out.reserve(grid.size());
    for (auto& kv : grid) out.push_back(kv.second.first / kv.second.second);
    return out;
}

Mat3 Rz(double yaw) { return Eigen::AngleAxisd(yaw, Vec3::UnitZ()).toRotationMatrix(); }
double yawOf(const Mat3& R) { return std::atan2(R(1, 0), R(0, 0)); }

}  // namespace

Lio::Lio(const LioConfig& cfg) : cfg_(cfg), map_(cfg.map_res), vis_(cfg.vis_res) { reset(); }

void Lio::reset() {
    imu_.clear();
    init_buf_.clear();
    init_fail_ = 0;
    cur_ = Scan{};
    have_cur_ = false;
    ready_.clear();
    inited_ = false;
    t_state_ = 0;
    R_.setIdentity();
    p_.setZero();
    v_.setZero();
    bg_.setZero();
    ba_.setZero();
    acc_scale_ = 1.0;
    P_.setZero();
    P_.diagonal() << Vec3::Constant(1e-4), Vec3::Constant(1e-4), Vec3::Constant(1e-2),
        Vec3::Constant(1e-4), Vec3::Constant(1e-3);
    map_.clear();
    stats_ = LioStats{};
    std::lock_guard<std::mutex> l(out_mtx_);
    vis_.clear();
    loc_state_ = LocState::None;
    loc_fail_ = 0;
    relocalize_ = false;
    loc_accum_.clear();
    loc_accum_scans_ = 0;
    if (mode_ == LioMode::Localization)
        for (size_t i = 0; i < prior_pts_.size(); ++i)
            vis_.add(prior_pts_[i], prior_int_.empty() ? -1.f : prior_int_[i]);
    stats_.vis_size = vis_.points().size();
    out_status_ = LioStatus::WaitingData;
    out_stats_ = stats_;   // fresh stats, but keeps vis_size of the prior map
    out_R_.setIdentity();
    out_p_.setZero();
    out_traj_.clear();
    out_scan_.clear();
}

void Lio::addPacket(int type, const uint8_t* buf, int len) {
    if (type == 1) {
        parsePointPacket(buf, len, [this](const RawPoint& p) { addPoint(p); });
    } else if (type == 2) {
        double t, g[3], a[3];
        if (parseImuPacket(buf, len, t, g, a)) addImu(t, Vec3(g[0], g[1], g[2]), Vec3(a[0], a[1], a[2]));
    }
}

void Lio::addImu(double t, const Vec3& gyr, const Vec3& acc) {
    if (!inited_) {
        if (!init_buf_.empty() && t <= init_buf_.back().t) return;
        init_buf_.push_back({t, gyr, acc});
        {
            std::lock_guard<std::mutex> l(out_mtx_);
            out_status_ = LioStatus::Initializing;
        }
        tryInit();
        return;
    }
    if (!imu_.empty() && t <= imu_.back().t) return;
    if (t <= t_state_) return;
    imu_.push_back({t, gyr, acc});
}

void Lio::tryInit() {
    const int N = cfg_.init_imu_samples;
    if (static_cast<int>(init_buf_.size()) < N) return;
    Vec3 ma = Vec3::Zero(), mg = Vec3::Zero();
    for (auto& s : init_buf_) {
        ma += s.acc;
        mg += s.gyr;
    }
    ma /= N;
    mg /= N;
    double var_a = 0, var_g = 0;
    for (auto& s : init_buf_) {
        var_a += (s.acc - ma).squaredNorm();
        var_g += (s.gyr - mg).squaredNorm();
    }
    var_a /= N;
    var_g /= N;
    // Require the device to be roughly static. Gyro is the reliable cue; accelerometer
    // vibration (Mid-360 motor, mounting) can be large even when the device does not move.
    // After a few failed windows (~2.5 s) initialise anyway rather than block forever.
    const bool still = var_g < 0.01 && mg.norm() < 0.15 && var_a < 1.0;
    if (!still && init_fail_ < 4) {
        ++init_fail_;
        init_buf_.erase(init_buf_.begin(), init_buf_.begin() + N / 2);
        return;
    }
    init_fail_ = 0;
    bg_ = mg;
    acc_scale_ = kGravity / ma.norm();
    R_ = Eigen::Quaterniond::FromTwoVectors(ma.normalized(), Vec3::UnitZ()).toRotationMatrix();
    p_.setZero();
    v_.setZero();
    ba_.setZero();
    last_imu_ = init_buf_.back();
    t_state_ = last_imu_.t;
    init_buf_.clear();
    inited_ = true;
    // Discard scans that started before initialisation completed.
    ready_.clear();
    have_cur_ = false;
    std::lock_guard<std::mutex> l(out_mtx_);
    out_status_ = LioStatus::Running;
    out_R_ = R_;
    out_p_ = p_;
}

void Lio::addPoint(const RawPoint& p) {
    if (!inited_) return;
    if (!have_cur_) {
        if (p.t < t_state_) return;
        cur_ = Scan{p.t, p.t + cfg_.scan_period, {}};
        cur_.pts.reserve(25000);
        have_cur_ = true;
    }
    if (p.t >= cur_.end) {
        double start = cur_.end;
        while (p.t >= start + cfg_.scan_period) start += cfg_.scan_period;  // gap
        ready_.push_back(std::move(cur_));
        cur_ = Scan{start, start + cfg_.scan_period, {}};
        cur_.pts.reserve(25000);
        // Bound the backlog: drop the oldest scans if processing falls behind.
        while (ready_.size() > 5) {
            ready_.pop_front();
            ++stats_.dropped_scans;
        }
    }
    cur_.pts.push_back(p);
}

bool Lio::step() {
    if (!inited_ || ready_.empty()) return false;
    const Scan& s = ready_.front();
    if (s.end <= t_state_) {
        ready_.pop_front();
        return true;
    }
    if (imu_.empty() || imu_.back().t < s.end) return false;  // wait for IMU to cover the scan
    processScan(s);
    ready_.pop_front();
    return true;
}

void Lio::integrate(double t1, const Vec3& gyr, const Vec3& acc, std::vector<Seg>* segs) {
    double dt = t1 - t_state_;
    if (dt <= 0) return;
    if (dt > 0.1) dt = 0.1;  // guard against gaps
    const Vec3 w = gyr - bg_;
    const Vec3 a = acc * acc_scale_ - ba_;
    const Mat3 R0 = R_;
    const Vec3 aw = R0 * a + g_;
    if (segs) segs->push_back({t_state_, R0, p_, v_, w, aw});

    p_ += v_ * dt + 0.5 * aw * dt * dt;
    v_ += aw * dt;
    R_ = R0 * Exp(w * dt);

    Mat15 F = Mat15::Identity();
    F.block<3, 3>(0, 0) = Exp(-w * dt);
    F.block<3, 3>(0, 9) = -Mat3::Identity() * dt;
    F.block<3, 3>(3, 6) = Mat3::Identity() * dt;
    F.block<3, 3>(6, 0) = -R0 * skew(a) * dt;
    F.block<3, 3>(6, 12) = -R0 * dt;
    P_ = F * P_ * F.transpose();
    const double dt2 = dt * dt;
    P_.diagonal().segment<3>(0).array() += cfg_.gyr_cov * dt2;
    P_.diagonal().segment<3>(6).array() += cfg_.acc_cov * dt2;
    P_.diagonal().segment<3>(9).array() += cfg_.bg_cov * dt2;
    P_.diagonal().segment<3>(12).array() += cfg_.ba_cov * dt2;
    t_state_ = t1;
}

void Lio::propagateTo(double t_end, std::vector<Seg>& segs) {
    while (!imu_.empty() && imu_.front().t <= t_end) {
        const Imu s = imu_.front();
        imu_.pop_front();
        integrate(s.t, 0.5 * (last_imu_.gyr + s.gyr), 0.5 * (last_imu_.acc + s.acc), &segs);
        last_imu_ = s;
    }
    integrate(t_end, last_imu_.gyr, last_imu_.acc, &segs);
    // re-orthonormalise
    Eigen::Quaterniond q(R_);
    R_ = q.normalized().toRotationMatrix();
}

void Lio::processScan(const Scan& s) {
    auto t0 = std::chrono::steady_clock::now();
    std::vector<Seg> segs;
    segs.reserve(32);
    propagateTo(s.end, segs);

    // ---- motion compensation into the IMU frame at scan end ----
    const Mat3 Re_T = R_.transpose();
    const Vec3 pe = p_;
    std::vector<Vec3> body;
    std::vector<float> inten;
    body.reserve(s.pts.size());
    inten.reserve(s.pts.size());
    const double b2 = cfg_.blind * cfg_.blind, r2 = cfg_.max_range * cfg_.max_range;
    size_t k = 0;
    for (const auto& rp : s.pts) {
        Vec3 pl(rp.x, rp.y, rp.z);
        double n2 = pl.squaredNorm();
        if (n2 < b2 || n2 > r2) continue;
        Vec3 pi = cfg_.R_LI * pl + cfg_.t_LI;
        if (!segs.empty()) {
            // points are time-ordered; advance segment pointer
            while (k + 1 < segs.size() && segs[k + 1].t0 <= rp.t) ++k;
            while (k > 0 && segs[k].t0 > rp.t) --k;
            const Seg& g = segs[k];
            double dt = rp.t - g.t0;
            Mat3 Ri = g.R * Exp(g.w * dt);
            Vec3 Pi = g.p + g.v * dt + 0.5 * g.aw * dt * dt;
            pi = Re_T * (Ri * pi + Pi - pe);
        }
        body.push_back(pi);
        inten.push_back(rp.refl);
    }
    stats_.scan_points = static_cast<int>(body.size());

    // ---- voxel downsample (centroid) ----
    std::vector<Vec3> ds = voxelDownsample(body, cfg_.scan_ds);
    stats_.ds_points = static_cast<int>(ds.size());

    if (mode_ == LioMode::Localization) {
        localize(body);
    } else {
        if (!map_.empty() && ds.size() >= 10) iekfUpdate(ds);
        // ---- map update ----
        for (const auto& p : ds) map_.add((R_ * p + p_).cast<float>());
    }

    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    stats_.last_ms = ms;
    stats_.avg_ms = stats_.scans == 0 ? ms : 0.95 * stats_.avg_ms + 0.05 * ms;
    stats_.scans++;
    stats_.map_size = map_.size();
    publish(body, inten);
}

void Lio::iekfUpdate(const std::vector<Vec3>& body) {
    const Mat3 R0 = R_;
    const Vec3 p0 = p_, v0 = v_, bg0 = bg_, ba0 = ba_;
    const Mat15 Pinv = P_.inverse();
    const double inv_rm = 1.0 / cfg_.laser_cov;

    Mat15 KH = Mat15::Zero();
    int it = 0, eff = 0;
    Eigen::Vector3f nb[5];
    float d2[5];
    for (; it < cfg_.max_iter; ++it) {
        Eigen::Matrix<double, 6, 6> HtH = Eigen::Matrix<double, 6, 6>::Zero();
        Eigen::Matrix<double, 6, 1> Htr = Eigen::Matrix<double, 6, 1>::Zero();
        eff = 0;
        double r2sum = 0;
        for (const auto& pb : body) {
            Vec3 pw = R_ * pb + p_;
            int n = map_.knn(pw.cast<float>(), 5, nb, d2);
            if (n < 5 || d2[4] > cfg_.knn_max_d2) continue;
            Vec3 nrm;
            double d;
            if (!fitPlane(nb, 5, cfg_.plane_thresh, nrm, d)) continue;
            double r = nrm.dot(pw) + d;
            if (!std::isfinite(r) || !pb.allFinite()) {
#ifdef LIO_DEBUG
                std::printf("bad r: pb %f %f %f nrm %f %f %f d %f nb0 %f %f %f\n", pb.x(), pb.y(), pb.z(), nrm.x(),
                            nrm.y(), nrm.z(), d, nb[0].x(), nb[0].y(), nb[0].z());
#endif
                continue;
            }
            double s = 1.0 - 0.9 * std::fabs(r) / std::sqrt(pb.norm());
            if (s <= 0.9) continue;
            Eigen::Matrix<double, 1, 6> h;
            h.head<3>() = -nrm.transpose() * R_ * skew(pb);  // dr/dtheta
            h.tail<3>() = nrm.transpose();                    // dr/dp
            HtH.noalias() += h.transpose() * h;
            Htr.noalias() += h.transpose() * r;
            r2sum += r * r;
            ++eff;
        }
        if (eff < 20) {
            stats_.degenerate++;
            break;
        }

        Vec15 dx;
        dx.segment<3>(0) = Log(R0.transpose() * R_);
        dx.segment<3>(3) = p_ - p0;
        dx.segment<3>(6) = v_ - v0;
        dx.segment<3>(9) = bg_ - bg0;
        dx.segment<3>(12) = ba_ - ba0;

        Mat15 A = Pinv;
        A.block<6, 6>(0, 0) += HtH * inv_rm;
        Mat15 Ainv = A.inverse();
#ifdef LIO_DEBUG
        if (!Ainv.allFinite() || !Htr.allFinite() || !Pinv.allFinite())
            std::printf("NONFINITE scan %ld it %d Ainv %d Htr %d Pinv %d P %d\n", stats_.scans, it, Ainv.allFinite(),
                        Htr.allFinite(), Pinv.allFinite(), P_.allFinite());
#endif
        KH.setZero();
        KH.block<15, 6>(0, 0) = Ainv.block<15, 6>(0, 0) * HtH * inv_rm;
        Vec15 delta = -Ainv.block<15, 6>(0, 0) * Htr * inv_rm + (KH - Mat15::Identity()) * dx;

        R_ = R_ * Exp(delta.segment<3>(0));
        p_ += delta.segment<3>(3);
        v_ += delta.segment<3>(6);
        bg_ += delta.segment<3>(9);
        ba_ += delta.segment<3>(12);

#ifdef LIO_DEBUG
        if (stats_.scans < 8 || stats_.scans % 40 == 0)
            std::printf("  scan %ld it %d eff %d |r|rms %.4f dth %.5f dp %.5f dv %.5f\n", stats_.scans, it, eff,
                        std::sqrt(r2sum / eff), delta.segment<3>(0).norm(), delta.segment<3>(3).norm(),
                        delta.segment<3>(6).norm());
#endif
        if (delta.segment<3>(0).norm() < 1e-4 && delta.segment<3>(3).norm() < 1e-3) {
            ++it;
            break;
        }
    }
    if (eff >= 20) P_ = (Mat15::Identity() - KH) * P_;
    P_ = 0.5 * (P_ + P_.transpose());
    stats_.iterations = it;
    stats_.effective = eff;
}

void Lio::publish(const std::vector<Vec3>& body, const std::vector<float>& inten) {
    std::vector<Eigen::Vector3f> scan;
    scan.reserve(body.size() / 4 + 1);
    for (size_t i = 0; i < body.size(); i += 4) scan.push_back((R_ * body[i] + p_).cast<float>());
    std::lock_guard<std::mutex> l(out_mtx_);
    const bool mapping = mode_ == LioMode::Mapping;
    if (mapping) {
        for (size_t i = 0; i < body.size(); ++i) vis_.add((R_ * body[i] + p_).cast<float>(), inten[i]);
    }
    stats_.vis_size = vis_.points().size();
    stats_.loc_state = static_cast<int>(loc_state_);
    stats_.loc_fail = loc_fail_;
    out_stats_ = stats_;
    out_R_ = R_;
    out_p_ = p_;
    if (mapping || loc_state_ == LocState::Tracking) out_traj_.push_back(p_.cast<float>());
    out_scan_.swap(scan);
}

void Lio::setPriorMap(const std::vector<Eigen::Vector3f>& pts, const std::vector<float>& intensity) {
    prior_pts_ = pts;
    prior_int_ = intensity.size() == pts.size() ? intensity : std::vector<float>();
    ndt_map_.build(prior_pts_, cfg_.ndt_res);
    std::lock_guard<std::mutex> l(out_mtx_);
    if (mode_ == LioMode::Localization) {
        vis_.clear();
        for (size_t i = 0; i < prior_pts_.size(); ++i)
            vis_.add(prior_pts_[i], prior_int_.empty() ? -1.f : prior_int_[i]);
    }
    // publish the display-map size now: the UI decides map vs live view from it before any scan arrives
    stats_.vis_size = out_stats_.vis_size = vis_.points().size();
}

void Lio::poseUpdate(const Mat3& Rm, const Vec3& pm) {
    using Mat6 = Eigen::Matrix<double, 6, 6>;
    Eigen::Matrix<double, 6, 1> r;
    r.head<3>() = Log(R_.transpose() * Rm);
    r.tail<3>() = pm - p_;
    // H selects [dtheta, dp] (first six error-state components)
    Mat6 S = P_.block<6, 6>(0, 0);
    S.diagonal().head<3>().array() += cfg_.loc_cov_rot;
    S.diagonal().tail<3>().array() += cfg_.loc_cov_pos;
    Eigen::Matrix<double, 15, 6> K = P_.block<15, 6>(0, 0) * S.inverse();
    Vec15 dx = K * r;
    R_ = R_ * Exp(dx.segment<3>(0));
    p_ += dx.segment<3>(3);
    v_ += dx.segment<3>(6);
    bg_ += dx.segment<3>(9);
    ba_ += dx.segment<3>(12);
    Mat15 KH = Mat15::Zero();
    KH.block<15, 6>(0, 0) = K;
    P_ = (Mat15::Identity() - KH) * P_;
    P_ = 0.5 * (P_ + P_.transpose());
}

bool Lio::globalSearch(const std::vector<Vec3>& src, const Vec3& center, double yaw0, bool search_yaw) {
    // keep roll/pitch from the gravity-aligned filter, search yaw and xy
    const Mat3 Rlevel = Rz(-yawOf(R_)) * R_;
    NdtParams coarse;
    coarse.max_iter = 12;
    // full 360 deg sweep, or +-30 deg around a user-given heading
    std::vector<double> yaws;
    if (search_yaw) {
        for (int k = 0; k < 12; ++k) yaws.push_back(yaw0 + 2 * M_PI * k / 12);
    } else {
        for (int k = -2; k <= 2; ++k) yaws.push_back(yaw0 + k * M_PI / 12);
    }
    const double rr = cfg_.loc_init_radius;
    const Vec3 offs[5] = {Vec3(0, 0, 0), Vec3(rr, 0, 0), Vec3(-rr, 0, 0), Vec3(0, rr, 0), Vec3(0, -rr, 0)};
    NdtResult best;
    best.score = -1;
    for (double yw : yaws) {
        const Mat3 R0 = Rz(yw) * Rlevel;
        for (const auto& o : offs) {
            NdtResult r = ndtAlign(ndt_map_, src, R0, center + o, coarse);
            if (r.score > best.score) best = r;
        }
    }
    NdtParams fine;
    fine.max_iter = 60;
    NdtResult r = ndtAlign(ndt_map_, src, best.R, best.t, fine);
    stats_.match = r.match;
    stats_.ndt_score = r.score;
    stats_.ndt_iters = r.iterations;
    if (r.match < cfg_.loc_match_init) return false;
    R_ = r.R;
    p_ = r.t;
    v_.setZero();
    P_.block<6, 15>(0, 0).setZero();
    P_.block<15, 6>(0, 0).setZero();
    P_.diagonal().head<3>().setConstant(1e-4);
    P_.diagonal().segment<3>(3).setConstant(1e-3);
    P_.diagonal().segment<3>(6).setConstant(1e-2);
    return true;
}

void Lio::localize(const std::vector<Vec3>& body) {
    if (ndt_map_.empty()) return;
    auto t0 = std::chrono::steady_clock::now();
    std::vector<Vec3> src = voxelDownsample(body, cfg_.ndt_src_ds);
    if (src.size() < 50) return;

    if (loc_state_ != LocState::Tracking) {
        const bool lost = loc_state_ == LocState::Lost && !relocalize_;
        if (relocalize_) {
            loc_accum_.clear();
            loc_accum_scans_ = 0;
        }
        relocalize_ = false;
        const Vec3 center = lost ? p_ : init_guess_p_;
        const double yaw0 = lost ? yawOf(R_) : init_guess_yaw_;
        const bool search = lost ? true : init_search_yaw_;
        // Accumulate a few scans (device roughly still) for a denser cloud: Mid-360 scans are sparse.
        for (const auto& b : src) loc_accum_.push_back(R_ * b + p_);
        if (++loc_accum_scans_ < cfg_.loc_init_scans) {
            if (!lost) loc_state_ = LocState::Searching;
            return;
        }
        std::vector<Vec3> acc;
        acc.reserve(loc_accum_.size());
        const Mat3 RT = R_.transpose();
        for (const auto& w : loc_accum_) acc.push_back(RT * (w - p_));
        acc = voxelDownsample(acc, cfg_.ndt_src_ds);
        loc_accum_.clear();
        loc_accum_scans_ = 0;
        if (globalSearch(acc, center, yaw0, search)) {
            loc_state_ = LocState::Tracking;
            loc_fail_ = 0;
        } else {
            if (!lost) loc_state_ = LocState::Searching;
            // keep the dead-reckoned pose from running away while not localised
            p_ = center;
            v_.setZero();
        }
    } else {
        NdtResult r = ndtAlign(ndt_map_, src, R_, p_);
        stats_.match = r.match;
        stats_.ndt_score = r.score;
        stats_.ndt_iters = r.iterations;
        if (r.match >= cfg_.loc_match_ok) {
            poseUpdate(r.R, r.t);
            loc_fail_ = 0;
        } else if (++loc_fail_ >= cfg_.loc_lost_after) {
            loc_state_ = LocState::Lost;
        }
    }
    stats_.ndt_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

int Lio::mapSnapshot(float* out, int maxPts) const {
    std::lock_guard<std::mutex> l(out_mtx_);
    const auto& pts = vis_.points();
    const auto& in = vis_.intensities();
    const size_t n = pts.size();
    if (n == 0 || maxPts <= 0) return 0;
    const double stride = n > size_t(maxPts) ? double(n) / maxPts : 1.0;
    int c = 0;
    for (double i = 0; i < n && c < maxPts; i += stride, ++c) {
        const auto& p = pts[size_t(i)];
        out[4 * c] = p.x();
        out[4 * c + 1] = p.y();
        out[4 * c + 2] = p.z();
        out[4 * c + 3] = in[size_t(i)];
    }
    return c;
}

bool Lio::savePcd(const std::string& path) const {
    std::lock_guard<std::mutex> l(out_mtx_);
    const auto& pts = vis_.points();
    const auto& in = vis_.intensities();
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    std::fprintf(f,
                 "# .PCD v0.7 - Point Cloud Data file format\nVERSION 0.7\nFIELDS x y z intensity\nSIZE 4 4 4 4\n"
                 "TYPE F F F F\nCOUNT 1 1 1 1\nWIDTH %zu\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS %zu\n"
                 "DATA binary\n",
                 pts.size(), pts.size());
    for (size_t i = 0; i < pts.size(); ++i) {
        const float rec[4] = {pts[i].x(), pts[i].y(), pts[i].z(), in[i] < 0 ? 0.f : in[i]};
        std::fwrite(rec, sizeof(float), 4, f);
    }
    std::fclose(f);
    return true;
}

}  // namespace mndt
