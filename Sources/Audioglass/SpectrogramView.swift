import AppKit
import MetalKit

// A small native Metal pipeline avoids pulling the Linux-oriented Iced/wgpu
// window/render stack into the AppKit glass window. The FFT stays upstream.
@MainActor
final class SpectrogramView: MTKView {
    private var pipeline: MTLRenderPipelineState?
    private var commands: MTLCommandQueue?
    private var history: MTLTexture?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        wantsLayer = true
        layer?.isOpaque = false
        guard let device else { return }
        commands = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct Vertex { float4 position [[position]]; float2 uv; };
            vertex Vertex historyVertex(uint id [[vertex_id]]) {
                const float2 p[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
                const float2 uv[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
                return {float4(p[id],0,1),uv[id]};
            }
            fragment float4 historyFragment(Vertex in [[stage_in]], texture2d<float> history [[texture(0)]]) {
                constexpr sampler s(filter::nearest, address::clamp_to_edge);
                float intensity = history.sample(s,in.uv).r;
                float alpha = intensity * intensity;
                return float4(alpha,alpha,alpha,alpha);
            }
            """, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "historyVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "historyFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            history = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: 512, height: 192, mipmapped: false))
        } catch { NSLog("Spectrogram Metal pipeline: %@", error.localizedDescription) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ pixels: [UInt8]) {
        guard pixels.count == 512 * 192, let device,
              let texture = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: 512, height: 192, mipmapped: false)) else { return }
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 512, 192), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 512)
        }
        history = texture
        if !isHidden { draw() }
    }
    override func draw(_ dirtyRect: NSRect) { draw() }
    override func draw() {
        guard let pipeline, let commands, let history,
              let descriptor = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(history, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
