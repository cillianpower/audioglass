import AppKit
import MetalKit

/// Spectrogram columns delivered by the analysis worker (see ag_spectrogram_read).
struct SpectrogramDelta: Sendable {
    let reset: Bool
    let columns: Int
    let rows: Int
    let first: Int
    let count: Int
    /// Columns shown since the last reset; the newest is `shown - 1`.
    let shown: Int
    let values: [Float]
}

/// Display size the worker rasterizes for: time extent in points, frequency
/// extent in physical pixels.
struct SpectrogramGeometry: Sendable, Equatable {
    var columns = 512
    var rows = 192
    var rowSpan = 2
}

/// Display-only settings applied in the shader, so changes recolour history.
struct SpectrogramStyle: Equatable {
    var floor: Float = -120
    var tilt: Float = 4.5
    var scale = 1
    var orientation = 0
    var palette = 0
    var sampleRate: Float = 48000
}

enum FrequencyAxis {
    // Matches util/audio/frequency.rs and upstream's 1 Hz display minimum.
    static func scaled(_ hz: Double, scale: Int) -> Double {
        switch scale {
        case 0: hz
        case 2: 21.4 * log10(1 + hz / 228.8)
        default: asinh(hz / 20)
        }
    }
    static func frequency(_ value: Double, scale: Int) -> Double {
        switch scale {
        case 0: value
        case 2: 228.8 * (pow(10, value / 21.4) - 1)
        default: 20 * sinh(value)
        }
    }
    static func range(sampleRate: Double, scale: Int) -> (Double, Double) {
        (scaled(min(1, sampleRate / 4), scale: scale), scaled(max(1, sampleRate / 2), scale: scale))
    }
}

// A small native Metal pipeline avoids pulling the Linux-oriented Iced/wgpu
// window/render stack into the AppKit glass window. The FFT stays upstream.
@MainActor
final class SpectrogramView: MTKView {
    private struct Uniforms {
        var columns: UInt32, rows: UInt32, newest: UInt32, shown: UInt32
        var orientation: UInt32, scale: UInt32, palette: UInt32
        var floor: Float, tilt: Float, low: Float, high: Float
    }

    static let emptyLevel: Float = -1000
    private var pipeline: MTLRenderPipelineState?
    private var commands: MTLCommandQueue?
    private var texture: MTLTexture?
    /// CPU copy of the ring, `columns` slots of `rows` dB values each.
    private var mirror: [Float] = []
    private var dirty = IndexSet()
    private var needsRedraw = true
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var shown = 0
    var style = SpectrogramStyle() { didSet { if style != oldValue { needsRedraw = true } } }

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
            struct Uniforms {
                uint columns, rows, newest, shown, orientation, scale, palette;
                float floorDb, tilt, low, high;
            };
            vertex Vertex historyVertex(uint id [[vertex_id]]) {
                const float2 p[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
                const float2 uv[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
                return {float4(p[id],0,1),uv[id]};
            }
            float frequency(uint scale, float value) {
                if (scale == 0) return value;
                if (scale == 2) return 228.8 * (pow(10.0, value / 21.4) - 1.0);
                return 20.0 * sinh(value);
            }
            // Upstream OpenMeters heat ramp, mixed in sRGB, then premultiplied.
            float4 heat(float level) {
                const float stops[] = {0.0, 0.40252383, 0.6791893, 0.86932226, 1.0};
                const float4 colors[] = {float4(0), float4(0.2196, 0, 0.6784, 1), float4(1, 0, 0, 1),
                                         float4(1, 1, 0.1294, 1), float4(1)};
                uint i = level > stops[3] ? 3 : level > stops[2] ? 2 : level > stops[1] ? 1 : 0;
                float4 c = mix(colors[i], colors[i + 1], saturate((level - stops[i]) / (stops[i + 1] - stops[i])));
                return float4(c.rgb * c.a, c.a);
            }
            fragment float4 historyFragment(Vertex in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                            texture2d<float, access::read> history [[texture(0)]]) {
                if (u.columns == 0 || u.rows == 0) return float4(0);
                // t: 0 oldest .. 1 newest; f: 0 lowest .. 1 highest frequency.
                float t = in.uv.x, f = 1.0 - in.uv.y;
                if (u.orientation == 1) { t = 1.0 - in.uv.y; f = in.uv.x; }
                if (u.orientation == 2) { t = in.uv.y; f = in.uv.x; }
                uint age = min(u.columns - 1, uint((1.0 - t) * float(u.columns)));
                if (age >= u.shown) return float4(0);
                uint slot = (u.newest + u.columns - age) % u.columns;
                uint row = min(u.rows - 1, uint(f * float(u.rows)));
                float db = history.read(uint2(row, slot)).r;
                if (db <= -139.99) return float4(0);
                if (u.tilt != 0.0) {
                    // dB/octave relative to 1 kHz, as upstream.
                    float hz = frequency(u.scale, mix(u.low, u.high, (float(row) + 0.5) / float(u.rows)));
                    if (hz > 0.0) db += u.tilt * log2(hz / 1000.0);
                }
                float level = saturate((db - u.floorDb) / max(-u.floorDb, 0.001));
                if (u.palette == 1) return heat(level);
                float alpha = level * level;
                return float4(alpha, alpha, alpha, alpha);
            }
            """, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "historyVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "historyFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { NSLog("Spectrogram Metal pipeline: %@", error.localizedDescription) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    func clear() {
        columns = 0
        rows = 0
        shown = 0
        mirror = []
        texture = nil
        dirty = []
        needsRedraw = true
    }

    /// Applied for every worker snapshot, including ones never presented.
    func apply(_ delta: SpectrogramDelta?) {
        guard let delta, delta.columns > 0, delta.rows > 0 else { return }
        if delta.reset || delta.columns != columns || delta.rows != rows {
            columns = delta.columns
            rows = delta.rows
            mirror = [Float](repeating: Self.emptyLevel, count: columns * rows)
            texture = nil
            dirty = IndexSet(integersIn: 0..<columns)
        }
        mirror.withUnsafeMutableBufferPointer { ring in
            delta.values.withUnsafeBufferPointer { values in
                for offset in 0..<delta.count {
                    let slot = (delta.first + offset) % columns
                    ring.baseAddress!.advanced(by: slot * rows)
                        .update(from: values.baseAddress!.advanced(by: offset * rows), count: rows)
                    dirty.insert(slot)
                }
            }
        }
        shown = delta.shown
        needsRedraw = true
    }

    /// Level and age at normalized time (0 oldest, 1 newest) and frequency positions.
    func sample(time: CGFloat, frequency: CGFloat) -> (hz: Double, age: Int, db: Float?) {
        let (low, high) = FrequencyAxis.range(sampleRate: Double(style.sampleRate), scale: style.scale)
        let row = min(max(rows - 1, 0), Int(frequency * CGFloat(rows)))
        let hz = FrequencyAxis.frequency(low + (high - low) * (Double(row) + 0.5) / Double(max(rows, 1)), scale: style.scale)
        guard columns > 0, rows > 0 else { return (hz, 0, nil) }
        let age = min(columns - 1, Int((1 - time) * CGFloat(columns)))
        guard age < shown else { return (hz, age, nil) }
        let slot = (shown - 1 - age) % columns
        return (hz, age, mirror[slot * rows + row])
    }

    func drawIfNeeded() {
        if needsRedraw && !isHidden { draw() }
    }

    override func draw(_ dirtyRect: NSRect) { draw() }
    override func draw() {
        guard let pipeline, let commands, let device,
              let descriptor = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer() else { return }
        if columns > 0, texture == nil {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: rows, height: columns, mipmapped: false)
            textureDescriptor.storageMode = .private
            textureDescriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: textureDescriptor)
        }
        // Copies are ordered before this frame's draw on the GPU, so the CPU
        // never writes a texture the previous frame might still be reading.
        if let texture, !dirty.isEmpty, let blit = command.makeBlitCommandEncoder() {
            let stride = rows * MemoryLayout<Float>.stride
            for range in dirty.rangeView {
                let buffer = mirror.withUnsafeBytes {
                    device.makeBuffer(bytes: $0.baseAddress!.advanced(by: range.lowerBound * stride),
                                      length: range.count * stride, options: .storageModeShared)
                }
                guard let buffer else { continue }
                blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: stride,
                          sourceBytesPerImage: range.count * stride,
                          sourceSize: MTLSize(width: rows, height: range.count, depth: 1),
                          to: texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: range.lowerBound, z: 0))
            }
            blit.endEncoding()
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        if let texture {
            let (low, high) = FrequencyAxis.range(sampleRate: Double(style.sampleRate), scale: style.scale)
            var uniforms = Uniforms(columns: UInt32(columns), rows: UInt32(rows),
                newest: UInt32(max(shown - 1, 0) % columns), shown: UInt32(shown),
                orientation: UInt32(style.orientation), scale: UInt32(style.scale), palette: UInt32(style.palette),
                floor: style.floor, tilt: style.tilt, low: Float(low), high: Float(high))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        if texture != nil { dirty = [] }
        needsRedraw = false
    }
}
