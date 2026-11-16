// C API over the platform-independent SLAM core (core/).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ------------------------------------------------------------------ SLAM engine

typedef struct SlamEngine* SlamHandle;

typedef struct {
    int32_t status;          // 0 waiting data, 1 initializing, 2 running
    int64_t scans;
    int64_t dropped_scans;
    int64_t dropped_pkts;
    int32_t queue;
    double last_ms, avg_ms;
    int32_t effective, ds_points;
    int64_t map_size, vis_size;
    double px, py, pz, yaw;
    int64_t degenerate;
    int32_t running;
    int32_t mode;            // 0 mapping, 1 localisation
    int32_t loc_state;       // 0 none, 1 searching, 2 tracking, 3 lost
    double match, ndt_ms;
    int32_t has_prior;
} SlamStatus;

SlamHandle slam_create(void);
void slam_destroy(SlamHandle h);
/// mode: 0 = mapping (SLAM), 1 = localisation (NDT against the prior map). Resets state.
void slam_start(SlamHandle h, int32_t mode);
void slam_stop(SlamHandle h);
/// Switches mode while stopped (clears state).
void slam_prepare(SlamHandle h, int32_t mode);
/// Initial guess for localisation; has_yaw = 0 searches all headings. Triggers a new search when running.
void slam_set_initial_pose(SlamHandle h, float x, float y, float z, float yaw, int32_t has_yaw);
/// Tuning parameters (see core/lio.hpp LioConfig).
typedef struct {
    float blind;             // m, points closer than this are ignored
    float max_range;         // m
    float scan_ds;           // m, scan downsampling voxel
    float map_res;           // m, registration map voxel (applies from the next start)
    float vis_res;           // m, display / PCD map voxel (applies from the next start)
    int32_t max_iter;        // IEKF iterations
    float plane_thresh;      // m, plane fit tolerance
    float knn_max_d2;        // m^2, max squared distance of the 5th neighbour
    float gyr_cov, acc_cov;  // IMU process noise
    float laser_cov;         // point-to-plane measurement noise
    float ext_t[3];          // m, LiDAR origin in the IMU frame
    float ndt_res;           // m, NDT voxel of the prior map
    float loc_match_ok;      // min match ratio while tracking
    float loc_init_radius;   // m, search radius around the initial guess
} SlamParams;

void slam_default_params(SlamParams* out);
/// Applies the parameters. Scan / filter settings take effect from the next scan, map resolutions from the next start.
void slam_set_params(SlamHandle h, const SlamParams* p);
/// Raw Livox packet. type 1 = point, 2 = IMU. Thread safe.
void slam_push(SlamHandle h, int32_t type, const uint8_t* buf, int32_t len);
void slam_get_status(SlamHandle h, SlamStatus* out);
/// Fills out with x, y, z, intensity per point (intensity < 0 = unknown). Returns the count.
int32_t slam_map(SlamHandle h, float* out_xyzi, int32_t max_pts);
/// Most recent trajectory points as x, y, z, -1. Returns the count.
int32_t slam_trajectory(SlamHandle h, float* out_xyzi, int32_t max_pts);
/// Last registered scan (world frame) as x, y, z, -1. Returns the count.
int32_t slam_scan(SlamHandle h, float* out_xyzi, int32_t max_pts);
int32_t slam_save_pcd(SlamHandle h, const char* path);

// ------------------------------------------------------------------ PCD files

typedef struct {
    float* xyzi;             // n * 4 floats (x, y, z, intensity; intensity = -1 when the file has none)
    int32_t n;               // points loaded (uniformly subsampled above max_points)
    int32_t total;           // points in the file
    int32_t has_intensity;
    float min[3], max[3];
    float z_lo, z_hi;        // 2nd / 98th percentile of z (colour range)
    float i_hi;              // intensity mapped to the top of the colour scale
    char fields[256];
    char format[32];
    char error[256];         // non-empty on failure
    uint64_t alloc_bytes;    // size of the (page aligned) xyzi allocation
} PcdCloud;

/// Reads ascii / binary / binary_compressed PCD. Always returns an object; check error[0].
PcdCloud* pcd_read(const char* path, int32_t max_points);
void pcd_free(PcdCloud* c);
/// Sets the prior map for localisation. Returns 1 if an NDT map could be built.
int32_t slam_set_prior_map(SlamHandle h, const PcdCloud* c);

// ------------------------------------------------------------------ live view / packet helpers

typedef struct LivePoints* LiveHandle;

/// Ring buffer holding the most recent raw sensor points (LiDAR frame).
LiveHandle live_create(int32_t capacity);
void live_destroy(LiveHandle h);
/// Parses a Livox point packet into the ring buffer. Returns points added.
int32_t live_add_packet(LiveHandle h, const uint8_t* buf, int32_t len);
/// Copies the current points as x, y, z, reflectivity. Returns the count.
int32_t live_snapshot(LiveHandle h, float* out_xyzi, int32_t max_pts);
int32_t live_capacity(LiveHandle h);

/// IMU packet: gyro rad/s, acc in g. Returns 1 on success.
int32_t livox_parse_imu(const uint8_t* buf, int32_t len, float out6[6]);

// ------------------------------------------------------------------ demo (synthetic Mid-360)

typedef struct DemoSource* DemoHandle;
typedef void (*DemoPacketFn)(void* ctx, int32_t type, const uint8_t* buf, int32_t len);

/// Starts streaming synthetic packets (type 1 = point, 2 = IMU) to fn on a background thread, in real time.
DemoHandle demo_start(DemoPacketFn fn, void* ctx);
/// The simulated sensor stands still for 3 s again, then moves (call when SLAM starts).
void demo_restart_motion(DemoHandle h);
/// Stops the thread (no more callbacks after this returns).
void demo_stop(DemoHandle h);

// ------------------------------------------------------------------ ROS 2 bag (MCAP)

typedef struct RosbagWriter* RosbagWriterHandle;

/// Creates an MCAP file recording /livox/imu (sensor_msgs/Imu) and /livox/lidar (sensor_msgs/PointCloud2 with
/// per-point timestamps). Returns NULL if the file cannot be created.
RosbagWriterHandle rosbag_writer_open(const char* path);
/// Raw Livox packet (type 1 = point, 2 = IMU). Thread safe.
void rosbag_writer_push(RosbagWriterHandle h, int32_t type, const uint8_t* buf, int32_t len);
int64_t rosbag_writer_bytes(RosbagWriterHandle h);
/// Writes the summary / footer, closes the file and frees h.
void rosbag_writer_close(RosbagWriterHandle h);

typedef struct {
    int32_t state;           // 0 playing, 1 finished, 2 error
    double progress;         // 0..1 (bytes read)
    double elapsed;          // s of bag time played
    double duration;         // s, 0 when the bag has no summary
    int64_t point_msgs, imu_msgs;
    char lidar_topic[128];
    char imu_topic[128];
    char error[256];
} RosbagStatus;

/// Finds the LiDAR (sensor_msgs/PointCloud2 or livox CustomMsg) and IMU topics. Returns 1 if the bag can be played.
int32_t rosbag_probe(const char* path, RosbagStatus* out);

typedef struct RosbagPlayer* RosbagPlayerHandle;

/// Plays the bag in real time (scaled by speed) on a background thread, converted to Livox packets
/// (type 1 = point, 2 = IMU) passed to fn.
RosbagPlayerHandle rosbag_play_start(const char* path, double speed, DemoPacketFn fn, void* ctx);
void rosbag_play_status(RosbagPlayerHandle h, RosbagStatus* out);
/// Stops the thread (no more callbacks after this returns) and frees h.
void rosbag_play_stop(RosbagPlayerHandle h);

#ifdef __cplusplus
}
#endif
