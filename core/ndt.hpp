// Normal Distributions Transform (P2D-NDT, Magnusson 2009) scan-to-map registration.
// Independent implementation. Platform independent.
#pragma once
#include <Eigen/Dense>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace mndt {

struct NdtResult {
    Eigen::Matrix3d R = Eigen::Matrix3d::Identity();
    Eigen::Vector3d t = Eigen::Vector3d::Zero();
    int iterations = 0;
    double score = 0;   // mean NDT score per source point (higher = better)
    double match = 0;   // fraction of source points within 3 sigma of a map distribution
    bool converged = false;
};

class NdtMap {
public:
    struct Cell {
        Eigen::Vector3d mean;
        Eigen::Matrix3d icov;
    };

    void build(const std::vector<Eigen::Vector3f>& pts, double resolution, int min_points = 6);
    bool empty() const { return cells_.empty(); }
    size_t size() const { return cells_.size(); }
    double resolution() const { return res_; }

    /// Calls f(cell) for the voxel containing p and its 6 face neighbours (DIRECT7).
    template <class F>
    void neighbours(const Eigen::Vector3d& p, F&& f) const {
        const int ix = cell(p.x()), iy = cell(p.y()), iz = cell(p.z());
        static const int off[7][3] = {{0, 0, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
                                      {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
        for (const auto& o : off) {
            auto it = cells_.find(pack(ix + o[0], iy + o[1], iz + o[2]));
            if (it != cells_.end()) f(it->second);
        }
    }

private:
    int cell(double v) const { return static_cast<int>(std::floor(v * inv_)); }
    static uint64_t pack(int x, int y, int z) {
        constexpr uint64_t M = (1u << 21) - 1;
        return ((uint64_t(x) & M) << 42) | ((uint64_t(y) & M) << 21) | (uint64_t(z) & M);
    }
    double res_ = 1.0, inv_ = 1.0;
    std::unordered_map<uint64_t, Cell> cells_;
};

struct NdtParams {
    int max_iter = 30;
    double outlier_ratio = 0.55;
    double eps = 1e-4;          // convergence on |delta|
    double max_step_t = 0.5;    // m per iteration
    double max_step_r = 0.2;    // rad per iteration
};

/// Aligns body-frame source points to the map starting from (R0, t0). Returns world pose of the body.
NdtResult ndtAlign(const NdtMap& map, const std::vector<Eigen::Vector3d>& src, const Eigen::Matrix3d& R0,
                   const Eigen::Vector3d& t0, const NdtParams& prm = NdtParams());

}  // namespace mndt
