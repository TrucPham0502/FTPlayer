import UIKit
import Metal
import QuartzCore
import CoreVideo

// MARK: - Vertex
private struct Vertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct ColorParams {
    var brightness: Float
    var contrast:   Float
    var saturation: Float
    var sharpness:  Float
    var useHD:      Int32
    var applyGamma: Int32
    var _pad0:      Float = 0
    var _pad1:      Float = 0
}

final class MetalVideoRenderer: UIView {

    // MARK: - Layer
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer!

    // MARK: - Properties
    enum VideoGravity {
        case resizeAspect, resizeAspectFill, resize
    }
    var videoGravity: VideoGravity = .resizeAspect {
        didSet { needsVertexUpdate = true }
    }

    var brightness: Float = FTPlayerSDKConfiguration.Rendering.brightness
    var contrast: Float = FTPlayerSDKConfiguration.Rendering.contrast
    var saturation: Float = FTPlayerSDKConfiguration.Rendering.saturation
    var useHDColorMatrix: Bool? = nil
    var applyGammaCorrection: Bool = FTPlayerSDKConfiguration.Rendering.applyGammaCorrection

    private var currentAutoBrightness: Float = FTPlayerSDKConfiguration.Rendering.brightness
    private var currentAutoContrast: Float = FTPlayerSDKConfiguration.Rendering.contrast
    private var frameCountForAnalysis        = 0
    private let analysisQueue = DispatchQueue(label: "MetalVideoRenderer.analysis", qos: .utility)
    private var isAnalyzing = false

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var videoRangePipeline: MTLRenderPipelineState?
    private var fullRangePipeline:  MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var vertexBuffer: MTLBuffer?
    private var textureCache: CVMetalTextureCache?

    private var videoSize: CGSize = .zero
    private var needsVertexUpdate = true
    private var isFullRange = false
    private var isSetup = false

    // MARK: - Fix Leak State
    private let renderQueue = DispatchQueue(label: "MetalVideoRenderer.render", qos: .userInteractive)
    private var pendingPixelBuffer: CVPixelBuffer?
    private var isRendering = false // Cờ kiểm soát để tránh tràn hàng đợi
    private let lock = NSLock()

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupMetalLayer()
        setupMetal()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetalLayer()
        setupMetal()
    }

    private func setupMetalLayer() {
        metalLayer = layer as? CAMetalLayer
        metalLayer.pixelFormat      = .bgra8Unorm
        metalLayer.framebufferOnly  = true
        metalLayer.contentsScale    = UIScreen.main.scale
        metalLayer.backgroundColor  = UIColor.black.cgColor
    }

    private func setupMetal() {
        guard let gpu = MTLCreateSystemDefaultDevice() else { Console.log(type: .ERROR, "Metal device unavailable"); return }
        device = gpu
        metalLayer.device = gpu
        commandQueue = gpu.makeCommandQueue()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, gpu, nil, &textureCache)
        buildPipelines(gpu)
        buildSamplerState(gpu)
        isSetup = videoRangePipeline != nil && fullRangePipeline != nil
        Console.log("Metal setup success=\(isSetup) gpu=\(gpu.name)")
    }

    private func buildPipelines(_ gpu: MTLDevice) {
        let frameworkBundle = Bundle(for: MetalVideoRenderer.self)
        guard let library = try? gpu.makeDefaultLibrary(bundle: frameworkBundle) else { Console.log(type: .ERROR, "Metal default.metallib missing in \(frameworkBundle.bundlePath)"); return }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride

        func makePipeline(fragmentName: String) -> MTLRenderPipelineState? {
            guard let frag = library.makeFunction(name: fragmentName) else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "videoVertexShader")
            desc.fragmentFunction = frag
            desc.vertexDescriptor = vd
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            do { return try gpu.makeRenderPipelineState(descriptor: desc) }
            catch { Console.log(type: .ERROR, "Metal pipeline \(fragmentName) error=\(error)"); return nil }
        }

        videoRangePipeline = makePipeline(fragmentName: "nv12ToRGBFragment")
        fullRangePipeline  = makePipeline(fragmentName: "nv12FullRangeToRGBFragment")
    }

    private func buildSamplerState(_ gpu: MTLDevice) {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        samplerState = gpu.makeSamplerState(descriptor: desc)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = UIScreen.main.scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        needsVertexUpdate = true
    }

    // MARK: - Throttled Rendering
    func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard isSetup else { return }

        lock.lock()
        // Chỉ lưu giữ frame mới nhất (Frame Dropping)
        pendingPixelBuffer = pixelBuffer
        
        // Nếu đang render rồi thì không đẩy thêm task vào queue nữa
        if isRendering {
            lock.unlock()
            return
        }
        isRendering = true
        lock.unlock()

        renderQueue.async { [weak self] in
            self?.consumeBuffer()
        }
    }

    private func consumeBuffer() {
        // Vòng lặp lấy buffer mới nhất để render, giải quyết việc tăng tốc độ video
        while true {
            var pixelBuffer: CVPixelBuffer?
            
            lock.lock()
            pixelBuffer = pendingPixelBuffer
            pendingPixelBuffer = nil // Clear sau khi lấy
            
            if pixelBuffer == nil {
                isRendering = false // Hết frame để render
                lock.unlock()
                break
            }
            lock.unlock()

            // Cực kỳ quan trọng: Giải phóng bộ nhớ tạm ngay lập tức sau mỗi frame
            autoreleasepool {
                if let buffer = pixelBuffer {
                    performRender(buffer)
                }
            }
        }
    }

    private func performRender(_ pixelBuffer: CVPixelBuffer) {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        isFullRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        guard let commandQueue, let pipeline = isFullRange ? fullRangePipeline : videoRangePipeline else { return }

        let bw = CVPixelBufferGetWidth(pixelBuffer)
        let bh = CVPixelBufferGetHeight(pixelBuffer)
        if CGSize(width: bw, height: bh) != videoSize {
            videoSize = CGSize(width: bw, height: bh)
            needsVertexUpdate = true
        }

        if needsVertexUpdate {
            let drawableSize = metalLayer.drawableSize
            if drawableSize.width > 0 {
                buildVertexBuffer(videoSize: videoSize, viewSize: drawableSize)
            } else { return }
        }

        guard let vertexBuffer, let drawable = metalLayer.nextDrawable() else { return }
        guard let (yTex, uvTex) = makeTextures(from: pixelBuffer) else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        if let sampler = samplerState { encoder.setFragmentSamplerState(sampler, index: 0) }

        analyzeBrightness(from: pixelBuffer)

        let isHD = useHDColorMatrix ?? (videoSize.width >= FTPlayerSDKConfiguration.Rendering.hdColorMatrixMinimumWidth)
        lock.lock()
        let autoBrightAdj = currentAutoBrightness
        let autoContAdj   = currentAutoContrast
        lock.unlock()

        var params = ColorParams(
            brightness: brightness + autoBrightAdj,
            contrast:   contrast * autoContAdj,
            saturation: saturation,
            sharpness:  0,
            useHD:      isHD ? 1 : 0,
            applyGamma: applyGammaCorrection ? 1 : 0
        )
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.addCompletedHandler { buffer in
            if let error = buffer.error { Console.log(type: .ERROR, "Metal command failed: \(error)") }
        }
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - Helpers
    private func buildVertexBuffer(videoSize: CGSize, viewSize: CGSize) {
        guard let gpu = device else { return }
        let va = videoSize.width / videoSize.height
        let wa = viewSize.width / viewSize.height
        var sx: Float = 1, sy: Float = 1

        switch videoGravity {
        case .resizeAspect:
            if va > wa { sy = Float(wa / va) } else { sx = Float(va / wa) }
        case .resizeAspectFill:
            if va > wa { sx = Float(va / wa) } else { sy = Float(wa / va) }
        case .resize: break
        }

        let verts: [Vertex] = [
            Vertex(position: SIMD2(-sx,  sy), texCoord: SIMD2(0, 0)),
            Vertex(position: SIMD2(-sx, -sy), texCoord: SIMD2(0, 1)),
            Vertex(position: SIMD2( sx,  sy), texCoord: SIMD2(1, 0)),
            Vertex(position: SIMD2( sx, -sy), texCoord: SIMD2(1, 1)),
        ]
        vertexBuffer = gpu.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared)
        needsVertexUpdate = false
    }

    private func makeTextures(from pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var cvY: CVMetalTexture?
        var cvUV: CVMetalTexture?

        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, w, h, 0, &cvY)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &cvUV)

        if let cvY = cvY, let cvUV = cvUV,
           let yTex = CVMetalTextureGetTexture(cvY),
           let uvTex = CVMetalTextureGetTexture(cvUV) {
            return (yTex, uvTex)
        }
        return nil
    }

    private func analyzeBrightness(from pixelBuffer: CVPixelBuffer) {
        frameCountForAnalysis += 1
        guard frameCountForAnalysis % FTPlayerSDKConfiguration.Rendering.brightnessAnalysisFrameInterval == 0 else { return } // Giảm tần suất phân tích xuống 1 lần/s (30fps)

        lock.lock()
        if isAnalyzing { lock.unlock(); return }
        isAnalyzing = true
        lock.unlock()

        analysisQueue.async { [weak self, pixelBuffer] in
            guard let self = self else { return }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            
            var mean: Float = 128
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let step = FTPlayerSDKConfiguration.Rendering.brightnessAnalysisPixelStep // Tăng step để giảm tải CPU
                var sum = 0, count = 0
                for r in stride(from: 0, to: height, by: step) {
                    let rowPtr = yBase.advanced(by: r * rowBytes).bindMemory(to: UInt8.self, capacity: width)
                    for c in stride(from: 0, to: width, by: step) {
                        sum += Int(rowPtr[c]); count += 1
                    }
                }
                if count > 0 { mean = Float(sum) / Float(count) }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

            let luma = max(FTPlayerSDKConfiguration.Rendering.minimumAnalyzedLuma, min(1.0, (mean - 16.0) / 219.0))
            var tB: Float = 0.0
            var tC: Float = 1.0

            if luma < FTPlayerSDKConfiguration.Rendering.darkLumaThreshold { tB = (FTPlayerSDKConfiguration.Rendering.darkLumaTarget - luma) * FTPlayerSDKConfiguration.Rendering.brightnessAdjustmentGain; tC = FTPlayerSDKConfiguration.Rendering.darkContrast }
            else if luma > FTPlayerSDKConfiguration.Rendering.brightLumaThreshold { tB = (FTPlayerSDKConfiguration.Rendering.brightLumaTarget - luma) * FTPlayerSDKConfiguration.Rendering.brightnessAdjustmentGain; tC = FTPlayerSDKConfiguration.Rendering.brightContrast }

            self.lock.lock()
            self.currentAutoBrightness = self.currentAutoBrightness * FTPlayerSDKConfiguration.Rendering.previousAnalysisWeight + tB * FTPlayerSDKConfiguration.Rendering.newAnalysisWeight
            self.currentAutoContrast = self.currentAutoContrast * FTPlayerSDKConfiguration.Rendering.previousAnalysisWeight + tC * FTPlayerSDKConfiguration.Rendering.newAnalysisWeight
            self.isAnalyzing = false
            self.lock.unlock()
        }
    }

    func flush() {
        lock.lock()
        pendingPixelBuffer = nil
        lock.unlock()
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }
}
