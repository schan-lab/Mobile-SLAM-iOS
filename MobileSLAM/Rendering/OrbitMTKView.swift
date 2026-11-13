import MetalKit
import UIKit
import simd

/// MTKView with an orbit camera around a target point (Z up).
///  1 finger drag: rotate   pinch: zoom   2 finger drag: pan   double tap: [onDoubleTap]
class OrbitMTKView: MTKView, UIGestureRecognizerDelegate {

    var yaw: Float = -90      // deg, around world Z
    var pitch: Float = 50     // deg, elevation
    var dist: Float = 12
    var target = SIMD3<Float>(0, 0, 0)
    var minDist: Float = 0.3
    var maxDist: Float = 500
    var fovY: Float = 60
    var farPlane: Float = 1000

    let rotateGesture = UIPanGestureRecognizer()
    let panGesture = UIPanGestureRecognizer()
    let pinchGesture = UIPinchGestureRecognizer()
    let doubleTapGesture = UITapGestureRecognizer()

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.043, green: 0.051, blue: 0.071, alpha: 1)
        isMultipleTouchEnabled = true

        rotateGesture.maximumNumberOfTouches = 1
        rotateGesture.addTarget(self, action: #selector(onRotate(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.addTarget(self, action: #selector(onPan(_:)))
        pinchGesture.addTarget(self, action: #selector(onPinch(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.addTarget(self, action: #selector(onDoubleTapGesture))
        for g in [rotateGesture, panGesture, pinchGesture, doubleTapGesture] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// Called when the user pans (e.g. to stop following).
    func onUserPan() {}
    func onDoubleTap() {}
    /// Called after any camera change (views that draw on demand redraw here).
    func cameraChanged() {}

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
        (g === panGesture || g === pinchGesture) && (o === panGesture || o === pinchGesture)
    }

    @objc private func onRotate(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        yaw -= Float(t.x) * 0.5
        pitch = min(max(pitch + Float(t.y) * 0.5, -89), 89.9)
        cameraChanged()
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        guard g.state == .changed else { return }
        onUserPan()
        let k = dist * 0.0035
        let yr = yaw * .pi / 180
        let right = SIMD2<Float>(-sin(yr), cos(yr))       // camera right
        let fwd = SIMD2<Float>(-cos(yr), -sin(yr))        // camera forward (ground)
        let dx = Float(t.x), dy = Float(t.y)
        target.x -= (right.x * dx - fwd.x * dy) * k
        target.y -= (right.y * dx - fwd.y * dy) * k
        cameraChanged()
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard g.scale > 0 else { return }
        dist = min(max(dist / Float(g.scale), minDist), maxDist)
        g.scale = 1
        cameraChanged()
    }

    @objc private func onDoubleTapGesture() {
        onDoubleTap()
        cameraChanged()
    }

    // ------------------------------------------------------------------ matrices

    var aspect: Float { bounds.height > 0 ? Float(bounds.width / bounds.height) : 1 }

    func projection() -> simd_float4x4 {
        let near: Float = 0.05
        let ys = 1 / tan(fovY * .pi / 360)
        let xs = ys / aspect
        let zs = farPlane / (near - farPlane)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }

    func viewMatrix() -> simd_float4x4 {
        let yr = yaw * .pi / 180, pr = pitch * .pi / 180
        let eye = target + SIMD3(dist * cos(pr) * cos(yr), dist * cos(pr) * sin(yr), dist * sin(pr))
        // near top-down the Z up-vector degenerates; use the heading direction instead
        let up = pitch > 88 ? SIMD3<Float>(-cos(yr), -sin(yr), 0) : SIMD3<Float>(0, 0, 1)
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    func mvp() -> simd_float4x4 { projection() * viewMatrix() }

    /// Intersects the ray through view point p with the plane z = zPlane. Returns world xyz or nil.
    func screenToGround(_ p: CGPoint, z zPlane: Float = 0) -> SIMD3<Float>? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let inv = mvp().inverse
        let nx = Float(2 * p.x / bounds.width - 1), ny = Float(1 - 2 * p.y / bounds.height)
        var a = inv * SIMD4<Float>(nx, ny, 0, 1)
        var b = inv * SIMD4<Float>(nx, ny, 1, 1)
        a /= a.w
        b /= b.w
        let dz = b.z - a.z
        guard abs(dz) > 1e-6 else { return nil }
        let t = (zPlane - a.z) / dz
        guard t >= 0 else { return nil }
        return SIMD3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, zPlane)
    }

    /// Uniforms with this frame's matrix.
    func uniforms(mvp: simd_float4x4, zRange: (Float, Float), mode: Int32, size: Float = 3,
                  color: SIMD3<Float> = .one, iMax: Float = 255) -> PointUniforms {
        PointUniforms(mvp: mvp, color: SIMD4(color, 1), zRange: SIMD2(zRange.0, zRange.1), pointSize: size,
                      iMax: iMax, mode: mode)
    }
}
