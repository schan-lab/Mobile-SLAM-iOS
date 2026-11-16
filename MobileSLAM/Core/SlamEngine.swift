import Foundation

/// Thin wrapper over the native LIO engine (core/ via Bridge/SlamBridge.h).
final class SlamEngine: @unchecked Sendable {
    let handle: SlamHandle

    init() { handle = slam_create() }
    deinit { slam_destroy(handle) }

    enum Mode: Int32 { case mapping = 0, localization = 1 }

    /// Clears state and starts processing packets.
    func start(_ mode: Mode) { slam_start(handle, mode.rawValue) }
    func stop() { slam_stop(handle) }
    /// Switches mode while stopped (resets state).
    func prepare(_ mode: Mode) { slam_prepare(handle, mode.rawValue) }
    func setParams(_ p: SlamParams) {
        var p = p
        slam_set_params(handle, &p)
    }
    /// Initial guess for localisation; yaw = nil searches all headings.
    func setInitialPose(x: Float, y: Float, yaw: Float?) {
        slam_set_initial_pose(handle, x, y, 0, yaw ?? 0, yaw == nil ? 0 : 1)
    }
    func setPriorMap(_ c: PcdCloudRef) -> Bool { slam_set_prior_map(handle, c.ptr) != 0 }
    func push(_ type: Int32, _ buf: UnsafePointer<UInt8>, _ len: Int32) { slam_push(handle, type, buf, len) }
    func savePcd(to url: URL) -> Bool { url.withUnsafeFileSystemRepresentation { slam_save_pcd(handle, $0!) != 0 } }

    var status: SlamStatus {
        var s = SlamStatus()
        slam_get_status(handle, &s)
        return s
    }
}

extension SlamStatus {
    var isRunning: Bool { running != 0 }
    var hasPrior: Bool { has_prior != 0 }
    /// SLAM produced its first registered scan (filter initialised).
    var isTracking: Bool { status == 2 }
}

/// Owns a native PcdCloud.
final class PcdCloudRef: @unchecked Sendable {
    let ptr: UnsafeMutablePointer<PcdCloud>
    /// Points beyond this are uniformly subsampled to keep memory / GPU load reasonable.
    static let maxPoints: Int32 = 6_000_000

    init(url: URL) throws {
        let p = url.withUnsafeFileSystemRepresentation { pcd_read($0!, PcdCloudRef.maxPoints) }!
        if p.pointee.error.0 != 0 {
            let msg = withUnsafePointer(to: p.pointee.error) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            pcd_free(p)
            throw NSError(domain: "PCD", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        ptr = p
    }
    deinit { pcd_free(ptr) }

    var count: Int { Int(ptr.pointee.n) }
    var total: Int { Int(ptr.pointee.total) }
    var hasIntensity: Bool { ptr.pointee.has_intensity != 0 }
    var minP: SIMD3<Float> { SIMD3(ptr.pointee.min.0, ptr.pointee.min.1, ptr.pointee.min.2) }
    var maxP: SIMD3<Float> { SIMD3(ptr.pointee.max.0, ptr.pointee.max.1, ptr.pointee.max.2) }
    var zRange: (Float, Float) { (ptr.pointee.z_lo, ptr.pointee.z_hi) }
    var intensityMax: Float { ptr.pointee.i_hi }
    var format: String {
        withUnsafePointer(to: ptr.pointee.format) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
    }
}
