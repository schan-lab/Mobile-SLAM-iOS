import MetalKit
import UIKit
import simd

/// Live 3D view of the SLAM map (or raw sensor points while no map exists).
final class LiveMapView: OrbitMTKView, MTKViewDelegate {

    private let engine: SlamEngine
    private let live: LiveHandle
    private var pipe: PointPipeline!
    private let inFlight = DispatchSemaphore(value: 1)

    private var follow = true
    /// Point colouring: AppSettings.colorIntensity or colorHeight.
    var colorMode: Int32 = AppSettings.colorIntensity

    // ---- initial pose picking (touch position, drag heading) ----
    /// Current initial guess to draw: x, y, yaw (nil = unknown heading).
    var guess: (x: Float, y: Float, yaw: Float?)? = nil
    /// Called with x, y, yaw (nil if the user did not drag a heading).
    var onPosePicked: ((Float, Float, Float?) -> Void)?
    var pickMode = false {
        didSet {
            pickGesture.isEnabled = pickMode
            rotateGesture.isEnabled = !pickMode
            if pickMode {
                follow = false
                pitch = 89.9
            }
        }
    }
    private let pickGesture = UILongPressGestureRecognizer()
    private var dragFrom: SIMD3<Float>?
    private var dragTo: SIMD3<Float>?

    // ---- GPU buffers ----
    private let maxMap = 800_000
    private let maxScan = 30_000
    private let maxTraj = 50_000
    private var mapBuf: MTLBuffer!, scanBuf: MTLBuffer!, trajBuf: MTLBuffer!, liveBuf: MTLBuffer!
    private var mapN = 0
    private var lastPull: CFTimeInterval = 0

    init(engine: SlamEngine, live: LiveHandle) {
        self.engine = engine
        self.live = live
        super.init()
        preferredFramesPerSecond = 60
        guard let p = PointPipeline(view: self) else { return }
        pipe = p
        mapBuf = p.makeBuffer(maxMap)
        scanBuf = p.makeBuffer(maxScan)
        trajBuf = p.makeBuffer(maxTraj)
        liveBuf = p.makeBuffer(Int(live_capacity(live)))
        delegate = self

        pickGesture.minimumPressDuration = 0
        pickGesture.numberOfTouchesRequired = 1
        pickGesture.isEnabled = false
        pickGesture.addTarget(self, action: #selector(onPick(_:)))
        pickGesture.delegate = self
        addGestureRecognizer(pickGesture)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func onUserPan() { follow = false }
    override func onDoubleTap() {
        guard !pickMode else { return }
        yaw = -90
        pitch = 50
        dist = 12
        follow = true
    }

    private func headingThreshold() -> Float { dist * 0.05 }

    @objc private func onPick(_ g: UILongPressGestureRecognizer) {
        if g.numberOfTouches > 1 {
            dragFrom = nil
            dragTo = nil
            return
        }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dragFrom = screenToGround(p)
            dragTo = nil
        case .changed:
            if dragFrom != nil { dragTo = screenToGround(p) }
        case .ended:
            if let a = dragFrom {
                let b = dragTo ?? a
                let d = SIMD2(b.x - a.x, b.y - a.y)
                // heading only if the drag is long enough on screen (~5% of the visible extent)
                let yaw: Float? = simd_length(d) > headingThreshold() ? atan2(d.y, d.x) : nil
                guess = (a.x, a.y, yaw)
                onPosePicked?(a.x, a.y, yaw)
            }
            dragFrom = nil
            dragTo = nil
        default:
            dragFrom = nil
            dragTo = nil
        }
    }

    // ------------------------------------------------------------------ MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipe, let rpd = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        inFlight.wait()
        let st = engine.status
        let pos = SIMD3<Float>(Float(st.px), Float(st.py), Float(st.pz))
        let pyaw = Float(st.yaw)
        // Live mode: SLAM not producing a map (idle, or still initialising) -> show raw sensor points.
        let liveMode = (st.isRunning && !st.isTracking) || (!st.isRunning && st.vis_size <= 0)
        if follow { target = liveMode ? .zero : pos }
        let m = mvp()

        guard let cmd = pipe.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            inFlight.signal()
            return
        }
        enc.setDepthStencilState(pipe.depthOn)

        if liveMode {
            let n = Int(live_snapshot(live, liveBuf.contents().assumingMemoryBound(to: Float.self), live_capacity(live)))
            pipe.draw(enc, liveBuf, prim: .point, count: n, u: uniforms(mvp: m, zRange: (-1, 2.5), mode: colorMode))
        } else {
            let now = CACurrentMediaTime()
            if now - lastPull > 0.5 {
                mapN = Int(slam_map(engine.handle, mapBuf.contents().assumingMemoryBound(to: Float.self), Int32(maxMap)))
                lastPull = now
            }
            let scanN = Int(slam_scan(engine.handle, scanBuf.contents().assumingMemoryBound(to: Float.self), Int32(maxScan)))
            let trajN = Int(slam_trajectory(engine.handle, trajBuf.contents().assumingMemoryBound(to: Float.self), Int32(maxTraj)))
            let z = (pos.z - 1.5, pos.z + 2.0)
            pipe.draw(enc, mapBuf, prim: .point, count: mapN, u: uniforms(mvp: m, zRange: z, mode: colorMode))
            pipe.draw(enc, scanBuf, prim: .point, count: scanN,
                      u: uniforms(mvp: m, zRange: z, mode: PointPipeline.colorFlat, size: 4, color: .one))
            let magenta = SIMD3<Float>(1, 0.2, 1)
            pipe.draw(enc, trajBuf, prim: .lineStrip, count: trajN,
                      u: uniforms(mvp: m, zRange: z, mode: PointPipeline.colorFlat, color: magenta))
            pipe.draw(enc, trajBuf, prim: .point, count: trajN,   // Metal lines are 1 px: thicken with points
                      u: uniforms(mvp: m, zRange: z, mode: PointPipeline.colorFlat, size: 6, color: magenta))

            enc.setDepthStencilState(pipe.depthOff)
            // pose marker: small triangle in the XY plane pointing along heading
            let c = cos(pyaw), s = sin(pyaw), L: Float = 0.4
            drawBytes(enc, [
                SIMD4(pos.x + c * L, pos.y + s * L, pos.z, -1),
                SIMD4(pos.x - c * L * 0.5 - s * L * 0.5, pos.y - s * L * 0.5 + c * L * 0.5, pos.z, -1),
                SIMD4(pos.x - c * L * 0.5 + s * L * 0.5, pos.y - s * L * 0.5 - c * L * 0.5, pos.z, -1),
            ], prim: .triangle, u: uniforms(mvp: m, zRange: z, mode: PointPipeline.colorFlat, color: SIMD3(1, 0.1, 0.1)))
            drawGuess(enc, m)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        cmd.commit()
    }

    private func drawBytes(_ enc: MTLRenderCommandEncoder, _ v: [SIMD4<Float>], prim: MTLPrimitiveType, u: PointUniforms) {
        guard let buf = pipe.device.makeBuffer(bytes: v, length: v.count * 16, options: .storageModeShared) else { return }
        pipe.draw(enc, buf, prim: prim, count: v.count, u: u)
    }

    /// Initial-pose marker (orange): arrow if heading known, else a cross.
    private func drawGuess(_ enc: MTLRenderCommandEncoder, _ m: simd_float4x4) {
        var g = guess
        if let a = dragFrom {
            var yaw: Float? = nil
            if let b = dragTo, simd_length(SIMD2(b.x - a.x, b.y - a.y)) > headingThreshold() { yaw = atan2(b.y - a.y, b.x - a.x) }
            g = (a.x, a.y, yaw)
        }
        guard let g else { return }
        let x = g.x, y = g.y, L = max(0.35, dist * 0.04)
        let u = uniforms(mvp: m, zRange: (0, 1), mode: PointPipeline.colorFlat, size: 8, color: SIMD3(1, 0.6, 0.1))
        if let yaw = g.yaw {
            let c = cos(yaw), s = sin(yaw)
            drawBytes(enc, [
                SIMD4(x + c * L * 1.6, y + s * L * 1.6, 0, -1),
                SIMD4(x - c * L * 0.6 - s * L * 0.7, y - s * L * 0.6 + c * L * 0.7, 0, -1),
                SIMD4(x - c * L * 0.6 + s * L * 0.7, y - s * L * 0.6 - c * L * 0.7, 0, -1),
            ], prim: .triangle, u: u)
        } else {
            // cross drawn as two thin quads (Metal lines are 1 px)
            let w = L * 0.12
            drawBytes(enc, [
                SIMD4(x - L, y - w, 0, -1), SIMD4(x + L, y - w, 0, -1), SIMD4(x - L, y + w, 0, -1),
                SIMD4(x + L, y - w, 0, -1), SIMD4(x + L, y + w, 0, -1), SIMD4(x - L, y + w, 0, -1),
                SIMD4(x - w, y - L, 0, -1), SIMD4(x + w, y - L, 0, -1), SIMD4(x - w, y + L, 0, -1),
                SIMD4(x + w, y - L, 0, -1), SIMD4(x + w, y + L, 0, -1), SIMD4(x - w, y + L, 0, -1),
            ], prim: .triangle, u: u)
        }
    }
}
