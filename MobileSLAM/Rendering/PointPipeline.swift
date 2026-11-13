import Metal
import MetalKit
import simd

/// Must match `Uniforms` in Shaders.metal.
struct PointUniforms {
    var mvp: simd_float4x4
    var color: SIMD4<Float>
    var zRange: SIMD2<Float>
    var pointSize: Float
    var iMax: Float
    var mode: Int32
}

/// Shared pipelines for drawing float4 (x, y, z, intensity) vertex buffers as points, lines or triangles.
final class PointPipeline {
    static let colorHeight: Int32 = 0
    static let colorFlat: Int32 = 1
    static let colorIntensity: Int32 = 2

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let points: MTLRenderPipelineState
    private let lines: MTLRenderPipelineState
    let depthOn: MTLDepthStencilState
    let depthOff: MTLDepthStencilState

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary() else { return nil }
        device = dev
        queue = q
        func make(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            return try? dev.makeRenderPipelineState(descriptor: d)
        }
        guard let p = make("pointsVertex", "pointsFragment"), let l = make("linesVertex", "linesFragment") else { return nil }
        points = p
        lines = l
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthOn = dev.makeDepthStencilState(descriptor: ds)!
        let ds2 = MTLDepthStencilDescriptor()
        ds2.depthCompareFunction = .always
        ds2.isDepthWriteEnabled = false
        depthOff = dev.makeDepthStencilState(descriptor: ds2)!
    }

    /// Buffer for up to n float4 vertices (shared storage, CPU writable).
    func makeBuffer(_ n: Int) -> MTLBuffer {
        device.makeBuffer(length: max(n, 1) * 16, options: .storageModeShared)!
    }

    func draw(_ enc: MTLRenderCommandEncoder, _ buf: MTLBuffer, prim: MTLPrimitiveType, count: Int, first: Int = 0,
              u: PointUniforms) {
        guard count > 0 else { return }
        var u = u
        enc.setRenderPipelineState(prim == .point ? points : lines)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<PointUniforms>.stride, index: 1)
        enc.drawPrimitives(type: prim, vertexStart: first, vertexCount: count)
    }
}
