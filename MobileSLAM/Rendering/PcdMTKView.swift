import MetalKit
import UIKit
import simd

/// Static 3D viewer for a loaded PCD. Double tap fits the whole cloud.
final class PcdMTKView: OrbitMTKView, MTKViewDelegate {

    private var pipe: PointPipeline!
    private var cloud: PcdCloudRef?
    private var cloudBuf: MTLBuffer?
    private var axisBuf: MTLBuffer?
    var pointSize: Float = 2.5 { didSet { setNeedsDisplay() } }
    var colorMode: Int32 = AppSettings.colorIntensity { didSet { setNeedsDisplay() } }

    override init() {
        super.init()
        fovY = 55
        farPlane = 5000
        isPaused = true
        enableSetNeedsDisplay = true
        guard let p = PointPipeline(view: self) else { return }
        pipe = p
        delegate = self
        // origin axes (1 m), drawn as thin quads: X red, Y green, Z blue
        let w: Float = 0.02
        var v: [SIMD4<Float>] = []
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ off: SIMD3<Float>) {
            for p in [a - off, b - off, a + off, b - off, b + off, a + off] { v.append(SIMD4(p, -1)) }
        }
        quad(.zero, SIMD3(1, 0, 0), SIMD3(0, w, 0))
        quad(.zero, SIMD3(0, 1, 0), SIMD3(w, 0, 0))
        quad(.zero, SIMD3(0, 0, 1), SIMD3(w, 0, 0))
        axisBuf = p.device.makeBuffer(bytes: v, length: v.count * 16, options: .storageModeShared)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func setCloud(_ c: PcdCloudRef) {
        cloud = c
        // wrap the page-aligned native allocation without copying
        let p = c.ptr.pointee
        cloudBuf = pipe?.device.makeBuffer(bytesNoCopy: p.xyzi, length: Int(p.alloc_bytes),
                                           options: .storageModeShared, deallocator: nil)
            ?? pipe?.device.makeBuffer(bytes: p.xyzi, length: max(c.count, 1) * 16, options: .storageModeShared)
        fit()
    }

    func fit() {
        guard let c = cloud else { return }
        let lo = c.minP, hi = c.maxP
        target = (lo + hi) / 2
        let r = max(0.5, simd_length(hi - lo) / 2)
        dist = r * 1.9
        maxDist = max(500, r * 10)
        yaw = -90
        pitch = 55
        setNeedsDisplay()
    }

    override func onDoubleTap() { fit() }
    override func cameraChanged() { setNeedsDisplay() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { setNeedsDisplay() }

    func draw(in view: MTKView) {
        guard let pipe, let rpd = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cmd = pipe.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setDepthStencilState(pipe.depthOn)
        if let c = cloud, let buf = cloudBuf {
            let m = mvp()
            let mode = c.hasIntensity ? colorMode : AppSettings.colorHeight
            pipe.draw(enc, buf, prim: .point, count: c.count,
                      u: uniforms(mvp: m, zRange: c.zRange, mode: mode, size: pointSize, iMax: c.intensityMax))
            if let a = axisBuf {
                let colors: [SIMD3<Float>] = [SIMD3(1, 0.3, 0.35), SIMD3(0, 0.8, 0.45), SIMD3(0.25, 0.55, 1)]
                for (i, col) in colors.enumerated() {
                    pipe.draw(enc, a, prim: .triangle, count: 6, first: i * 6,
                              u: uniforms(mvp: m, zRange: (0, 1), mode: PointPipeline.colorFlat, color: col))
                }
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
