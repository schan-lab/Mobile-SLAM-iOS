#include "ndt.hpp"

#include <cmath>

namespace mndt {

namespace {
Eigen::Matrix3d skew(const Eigen::Vector3d& v) {
    Eigen::Matrix3d m;
    m << 0, -v.z(), v.y(), v.z(), 0, -v.x(), -v.y(), v.x(), 0;
    return m;
}
Eigen::Matrix3d Exp(const Eigen::Vector3d& w) {
    double th = w.norm();
    if (th < 1e-12) return Eigen::Matrix3d::Identity() + skew(w);
    return Eigen::AngleAxisd(th, w / th).toRotationMatrix();
}
}  // namespace

void NdtMap::build(const std::vector<Eigen::Vector3f>& pts, double resolution, int min_points) {
    res_ = resolution;
    inv_ = 1.0 / resolution;
    struct Acc {
        Eigen::Vector3d s = Eigen::Vector3d::Zero();
        Eigen::Matrix3d ss = Eigen::Matrix3d::Zero();
        int n = 0;
    };
    std::unordered_map<uint64_t, Acc> acc;
    acc.reserve(pts.size() / 8 + 16);
    for (const auto& pf : pts) {
        Eigen::Vector3d p = pf.cast<double>();
        auto& a = acc[pack(cell(p.x()), cell(p.y()), cell(p.z()))];
        a.s += p;
        a.ss.noalias() += p * p.transpose();
        a.n++;
    }
    cells_.clear();
    cells_.reserve(acc.size());
    for (const auto& kv : acc) {
        const Acc& a = kv.second;
        if (a.n < min_points) continue;
        Eigen::Vector3d mu = a.s / a.n;
        Eigen::Matrix3d cov = (a.ss - a.n * mu * mu.transpose()) / (a.n - 1);
        Eigen::SelfAdjointEigenSolver<Eigen::Matrix3d> es(cov);
        Eigen::Vector3d ev = es.eigenvalues();
        // Regularise near-singular covariances (planes/lines), as in Magnusson 2009.
        const double lmax = ev.maxCoeff();
        if (!(lmax > 0)) continue;
        for (int i = 0; i < 3; ++i) ev(i) = std::max(ev(i), std::max(0.01 * lmax, 1e-4));
        Cell c;
        c.mean = mu;
        c.icov = es.eigenvectors() * ev.cwiseInverse().asDiagonal() * es.eigenvectors().transpose();
        cells_.emplace(kv.first, c);
    }
}

NdtResult ndtAlign(const NdtMap& map, const std::vector<Eigen::Vector3d>& src, const Eigen::Matrix3d& R0,
                   const Eigen::Vector3d& t0, const NdtParams& prm) {
    NdtResult res;
    res.R = R0;
    res.t = t0;
    if (map.empty() || src.empty()) return res;

    // Gaussian fitting constants (Magnusson 2009, eq. 6.8)
    const double r = map.resolution();
    const double c1 = 10.0 * (1.0 - prm.outlier_ratio);
    const double c2 = prm.outlier_ratio / (r * r * r);
    const double d3 = -std::log(c2);
    const double d1 = -std::log(c1 + c2) - d3;
    const double d2 = -2.0 * std::log((-std::log(c1 * std::exp(-0.5) + c2) - d3) / d1);

    Eigen::Matrix3d R = R0;
    Eigen::Vector3d t = t0;
    using Mat6 = Eigen::Matrix<double, 6, 6>;
    using Vec6 = Eigen::Matrix<double, 6, 1>;

    for (int it = 0; it < prm.max_iter; ++it) {
        Mat6 H = Mat6::Zero();
        Vec6 g = Vec6::Zero();
        double score = 0;
        int matched = 0;
        for (const auto& p : src) {
            const Eigen::Vector3d x = R * p + t;
            bool m = false;
            // J = d x / d [dt, dtheta] for x' = Exp(dtheta) x + dt  ->  [I, -[x]x]
            Eigen::Matrix<double, 3, 6> J;
            J.leftCols<3>().setIdentity();
            J.rightCols<3>() = -skew(x);
            map.neighbours(x, [&](const NdtMap::Cell& c) {
                const Eigen::Vector3d xd = x - c.mean;
                const Eigen::Vector3d Cxd = c.icov * xd;
                const double q = xd.dot(Cxd);
                if (q > 50.0) return;
                const double e = std::exp(-0.5 * d2 * q);
                score += -d1 * e;
                if (q < 9.0) m = true;
                // IRLS / Gauss-Newton on the NDT score: weight w = -d1*d2*e > 0
                const double w = -d1 * d2 * e;
                const Eigen::Matrix<double, 3, 6> CJ = c.icov * J;
                H.noalias() += w * J.transpose() * CJ;
                g.noalias() += w * J.transpose() * Cxd;
            });
            if (m) ++matched;
        }
        res.score = score / src.size();
        res.match = double(matched) / src.size();
        res.iterations = it + 1;

        H.diagonal().array() += 1e-6;
        Vec6 delta = -H.ldlt().solve(g);
        if (!delta.allFinite()) break;
        // clamp step
        double nt = delta.head<3>().norm(), nr = delta.tail<3>().norm();
        if (nt > prm.max_step_t) delta.head<3>() *= prm.max_step_t / nt;
        if (nr > prm.max_step_r) delta.tail<3>() *= prm.max_step_r / nr;

        const Eigen::Matrix3d dR = Exp(delta.tail<3>());
        R = dR * R;
        t = dR * t + delta.head<3>();
        if (delta.norm() < prm.eps) {
            res.converged = true;
            break;
        }
    }
    Eigen::Quaterniond q(R);
    res.R = q.normalized().toRotationMatrix();
    res.t = t;
    return res;
}

}  // namespace mndt
