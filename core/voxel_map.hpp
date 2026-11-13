// Hash-voxel incremental map with approximate k-NN (search in the 3x3x3 neighbourhood).
#pragma once
#include <Eigen/Core>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace mndt {

class VoxelMap {
public:
    explicit VoxelMap(double res = 0.5) : res_(res), inv_(1.0 / res) {}

    void clear() { cells_.clear(); }
    size_t size() const { return cells_.size(); }
    bool empty() const { return cells_.empty(); }
    double resolution() const { return res_; }

    /// Keeps at most one point per voxel (the first one inserted).
    bool add(const Eigen::Vector3f& p) {
        return cells_.emplace(key(p), p).second;
    }

    /// Finds up to k nearest points within the 27 neighbouring voxels.
    /// Returns number found, results sorted by distance.
    int knn(const Eigen::Vector3f& q, int k, Eigen::Vector3f* out, float* d2out) const {
        int ix = cell(q.x()), iy = cell(q.y()), iz = cell(q.z());
        std::pair<float, Eigen::Vector3f> cand[27];
        int n = 0;
        for (int dx = -1; dx <= 1; ++dx)
            for (int dy = -1; dy <= 1; ++dy)
                for (int dz = -1; dz <= 1; ++dz) {
                    auto it = cells_.find(pack(ix + dx, iy + dy, iz + dz));
                    if (it == cells_.end()) continue;
                    cand[n++] = {(it->second - q).squaredNorm(), it->second};
                }
        int m = std::min(k, n);
        std::partial_sort(cand, cand + m, cand + n,
                          [](const auto& a, const auto& b) { return a.first < b.first; });
        for (int i = 0; i < m; ++i) {
            out[i] = cand[i].second;
            d2out[i] = cand[i].first;
        }
        return m;
    }

    template <class F>
    void forEach(F&& f) const { for (auto& kv : cells_) f(kv.second); }

private:
    int cell(float v) const { return static_cast<int>(std::floor(v * inv_)); }
    static uint64_t pack(int x, int y, int z) {
        constexpr uint64_t M = (1u << 21) - 1;
        return ((uint64_t(x) & M) << 42) | ((uint64_t(y) & M) << 21) | (uint64_t(z) & M);
    }
    uint64_t key(const Eigen::Vector3f& p) const { return pack(cell(p.x()), cell(p.y()), cell(p.z())); }

    double res_, inv_;
    std::unordered_map<uint64_t, Eigen::Vector3f> cells_;
};

/// Append-only deduplicated point store for display / export.
class PointStore {
public:
    explicit PointStore(double res) : inv_(1.0 / res) {}
    void clear() {
        keys_.clear();
        pts_.clear();
        inten_.clear();
    }
    /// intensity: reflectivity 0..255, or negative when unknown.
    void add(const Eigen::Vector3f& p, float intensity = -1.f) {
        uint64_t k = pack(c(p.x()), c(p.y()), c(p.z()));
        if (keys_.emplace(k, 0).second) {
            pts_.push_back(p);
            inten_.push_back(intensity);
        }
    }
    const std::vector<Eigen::Vector3f>& points() const { return pts_; }
    const std::vector<float>& intensities() const { return inten_; }

private:
    int c(float v) const { return static_cast<int>(std::floor(v * inv_)); }
    static uint64_t pack(int x, int y, int z) {
        constexpr uint64_t M = (1u << 21) - 1;
        return ((uint64_t(x) & M) << 42) | ((uint64_t(y) & M) << 21) | (uint64_t(z) & M);
    }
    double inv_;
    std::unordered_map<uint64_t, char> keys_;
    std::vector<Eigen::Vector3f> pts_;
    std::vector<float> inten_;
};

}  // namespace mndt
