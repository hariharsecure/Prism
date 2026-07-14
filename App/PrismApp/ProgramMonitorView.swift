import AppKit
import CoreVideo
import Metal
import QuartzCore
import PrismCore
import SwiftUI

/// Program monitor. Presents each program frame's IOSurface-backed pixel buffer
/// through a `CAMetalLayer` so the preview can carry **EDR** (extended dynamic
/// range) when the program is HDR (Stage O sink-parity — previously a plain
/// `CALayer` whose `contents` was the IOSurface, which cannot request EDR).
///
/// When an HDR program frame arrives (10-bit `ARGB2101010LEPacked`), the layer is
/// configured for Rec.2020 / BT.2100-HLG EDR (`wantsExtendedDynamicRangeContent`,
/// the HLG colorspace, and `CAEDRMetadata.hlg`); for an 8-bit SDR frame the flags
/// are cleared and it presents exactly as before. Detection is off the frame's
/// pixel format, so no HDR flag has to be threaded through SwiftUI.
///
/// SOFTWARE-VERIFIED: the layer's EDR configuration is asserted by unit test.
/// Whether the preview actually shows HDR headroom on a real EDR display is
/// UNVERIFIED-until-hardware.
struct ProgramMonitorView: NSViewRepresentable {
    let store: ProgramPreviewStore

    func makeNSView(context: Context) -> ProgramLayerView {
        let view = ProgramLayerView()
        view.store = store
        return view
    }

    func updateNSView(_ nsView: ProgramLayerView, context: Context) {
        nsView.store = store
    }
}

/// EDR configuration for the preview's `CAMetalLayer`, split out so it is
/// unit-testable (Stage O): given the program frame's pixel format, set (HDR) or
/// clear (SDR) the extended-dynamic-range flags. Returns whether HDR was applied.
enum PreviewEDR {
    /// True iff `pixelFormat` is the compositor's HDR program output (10-bit
    /// `ARGB2101010LEPacked`, Rec.2020 / BT.2100-HLG-tagged).
    static func isHDR(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_ARGB2101010LEPacked
    }

    @discardableResult
    static func configure(_ layer: CAMetalLayer, for pixelFormat: OSType) -> Bool {
        let hdr = isHDR(pixelFormat)
        if hdr {
            // 10-bit drawable + Rec.2020 HLG colorspace + HLG EDR metadata: the
            // system maps the HLG-encoded signal into display headroom on an EDR
            // display. `bgr10a2Unorm` matches the source's bit depth exactly.
            layer.pixelFormat = .bgr10a2Unorm
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            layer.edrMetadata = .hlg
        } else {
            // SDR: the prior 8-bit behavior — no EDR, sRGB.
            layer.pixelFormat = .bgra8Unorm
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.edrMetadata = nil
        }
        return hdr
    }
}

final class ProgramLayerView: NSView {
    var store: ProgramPreviewStore?

    private var timer: Timer?
    private var lastSequence: UInt64 = 0
    /// Keeps the displayed frame's pixel buffer alive while its IOSurface is
    /// on the layer (the compositor's pool must not recycle it under us).
    private var displayedFrame: PrismCore.VideoFrame?

    // Metal presentation.
    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    /// The EDR-capable presentation layer (sublayer, sized to the aspect-fit rect).
    private var metalLayer: CAMetalLayer?
    /// The pixel format the metal layer is currently configured for (avoids
    /// reconfiguring EDR every tick).
    private var configuredFormat: OSType = 0
    private var sourceSize: CGSize = .zero
    /// Fallback plain layer used only if Metal is unavailable (keeps the old
    /// `contents = IOSurface` behavior so the preview never goes fully dark).
    private var fallbackLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupMetal()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupMetal() {
        guard let device else { setupFallback(); return }
        commandQueue = device.makeCommandQueue()
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut prism_preview_vtx(uint vid [[vertex_id]]) {
            float2 p[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
            float2 t[3] = { float2(0.0, 2.0), float2(0.0, 0.0), float2(2.0, 0.0) };
            VOut o; o.pos = float4(p[vid], 0.0, 1.0); o.uv = t[vid]; return o;
        }
        fragment float4 prism_preview_frag(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return tex.sample(s, in.uv);
        }
        """
        guard let lib = try? device.makeLibrary(source: source, options: nil) else { setupFallback(); return }

        let metal = CAMetalLayer()
        metal.device = device
        metal.framebufferOnly = false
        metal.isOpaque = true
        metal.contentsGravity = .resizeAspect
        PreviewEDR.configure(metal, for: 0) // start SDR (bgra8Unorm)
        configuredFormat = 0
        makePipeline(library: lib, pixelFormat: metal.pixelFormat)
        layer?.addSublayer(metal)
        metalLayer = metal
    }

    private func makePipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) {
        guard let device else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "prism_preview_vtx")
        desc.fragmentFunction = library.makeFunction(name: "prism_preview_frag")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        pipelineLibrary = library
    }
    private var pipelineLibrary: MTLLibrary?

    private func setupFallback() {
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        layer?.addSublayer(l)
        fallbackLayer = l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func layout() {
        super.layout()
        layoutPresentationLayer()
    }

    /// Size the presentation sublayer to the aspect-fit rect of the source within
    /// the view bounds (letterbox/pillarbox shows the black container).
    private func layoutPresentationLayer() {
        let target = metalLayer ?? fallbackLayer
        guard let target else { return }
        let bounds = self.bounds
        let scale = window?.backingScaleFactor ?? 2.0
        guard sourceSize.width > 0, sourceSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            target.frame = bounds
            return
        }
        let fit = AVFit.aspectFit(source: sourceSize, into: bounds.size)
        let rect = CGRect(x: (bounds.width - fit.width) / 2,
                          y: (bounds.height - fit.height) / 2,
                          width: fit.width, height: fit.height)
        target.frame = rect
        if let metalLayer {
            metalLayer.drawableSize = CGSize(width: max(1, rect.width * scale),
                                             height: max(1, rect.height * scale))
        }
    }

    private func tick() {
        guard let store, let (frame, sequence) = store.latest(after: lastSequence) else { return }
        lastSequence = sequence
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                          height: CVPixelBufferGetHeight(frame.pixelBuffer))
        if size != sourceSize { sourceSize = size; layoutPresentationLayer() }
        displayedFrame = frame

        if let metalLayer {
            reconfigureIfNeeded(metalLayer, for: frame.pixelFormat)
            render(frame, into: metalLayer)
        } else if let fallbackLayer,
                  let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() {
            fallbackLayer.contents = surface
        }
    }

    /// Reconfigure EDR + the render pipeline when the program's pixel format
    /// changes (e.g. an HDR toggle switches 8-bit ↔ 10-bit).
    private func reconfigureIfNeeded(_ metalLayer: CAMetalLayer, for pixelFormat: OSType) {
        guard pixelFormat != configuredFormat else { return }
        PreviewEDR.configure(metalLayer, for: pixelFormat)
        configuredFormat = pixelFormat
        if let lib = pipelineLibrary { makePipeline(library: lib, pixelFormat: metalLayer.pixelFormat) }
    }

    private func render(_ frame: PrismCore.VideoFrame, into metalLayer: CAMetalLayer) {
        guard let device, let commandQueue, let pipeline, let textureCache,
              metalLayer.drawableSize.width >= 1, metalLayer.drawableSize.height >= 1 else { return }
        // Source Metal texture from the IOSurface-backed buffer (zero copy). SDR
        // (BGRA8) → bgra8Unorm; HDR (ARGB2101010) → bgr10a2Unorm — the same
        // format the compositor rendered it as.
        let sampleFormat: MTLPixelFormat = PreviewEDR.isHDR(frame.pixelFormat) ? .bgr10a2Unorm : .bgra8Unorm
        let w = CVPixelBufferGetWidth(frame.pixelBuffer)
        let h = CVPixelBufferGetHeight(frame.pixelBuffer)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame.pixelBuffer, nil,
            sampleFormat, w, h, 0, &cvTex) == kCVReturnSuccess,
            let cvTex, let srcTexture = CVMetalTextureGetTexture(cvTex) else { return }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(srcTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Minimal aspect-fit helper (kept local so the monitor has no AVFoundation dep).
private enum AVFit {
    static func aspectFit(source: CGSize, into container: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return container }
        let scale = min(container.width / source.width, container.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}
