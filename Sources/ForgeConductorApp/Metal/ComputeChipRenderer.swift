import AppKit
import MetalKit
import ImageIO
import ForgeConductorCore

struct ComputeChipRendererObservation: Equatable, Codable, Sendable {
    var submissions = 0
    var completedCommands = 0
    var failedCommands = 0
    var lastGPUDuration: Double?
    var animationFrames = 0
    var staticFrames = 0
    var skippedBusySlots = 0
    var geometryRebuilds = 0
    var activeSurfaces = 0
    var ownedBuffers = 0
    var inFlightSlots = 0
    var maximumInFlightSlots = 0
    var inFlightReadbacks = 0
    var maximumInFlightReadbacks = 0
    var activeClocks = 0
    var vertexFunction = "compute_chip_vertex"
    var fragmentFunction = "compute_chip_fragment"
    var libraryOrigin = ""
    var sharedMaterialTextures = 0
    var sharedMaterialSamplers = 0
    var materialTextureLoads = 0
}

final class ComputeChipDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var observation = ComputeChipRendererObservation()
    func snapshot() -> ComputeChipRendererObservation { lock.withLock { observation } }
    func change(_ body: (inout ComputeChipRendererObservation) -> Void) { lock.withLock { body(&observation) } }
}

@MainActor
final class ComputeChipResources {
    static let shared = ComputeChipResources()
    nonisolated static var assetBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let devices: [ComputeGPUIdentity]
    let libraryOrigin: String
    let cpuMaterialImage: CGImage?
    let gpuMaterialImage: CGImage?
    let cpuMaterialTexture: MTLTexture?
    let gpuMaterialTexture: MTLTexture?
    let materialSampler: MTLSamplerState?
    var materialTextureCount: Int { [cpuMaterialTexture, gpuMaterialTexture].compactMap { $0 }.count }
    private let library: MTLLibrary?
    private static let materialImages = referenceMaterials()
    private var cachedPipeline: MTLRenderPipelineState?
    private(set) var failureReason: String?

    convenience init() {
        let shared = MetalGaugeResources.shared
        let device = shared.device
        let bundle = Self.assetBundle
        var library: MTLLibrary?
        var origin = ""
        if let device {
            if let url = bundle.url(forResource: "ComputeChipShaders", withExtension: "metallib"),
               let packaged = try? device.makeLibrary(URL: url) {
                library = packaged; origin = url.lastPathComponent
            } else if let compiled = try? device.makeDefaultLibrary(bundle: bundle) {
                library = compiled; origin = "default.metallib"
            }
        }
        self.init(device: device, commandQueue: shared.commandQueue, library: library, libraryOrigin: origin,
                  devices: MTLCopyAllDevices().map { .init(name: $0.name, registryID: $0.registryID) })
    }

    /// Capability injection is also used by native tests for the genuine static failure path.
    init(device: MTLDevice?, commandQueue: MTLCommandQueue?, library: MTLLibrary?, libraryOrigin: String,
         devices: [ComputeGPUIdentity]) {
        self.device = device; self.commandQueue = commandQueue; self.library = library
        self.libraryOrigin = libraryOrigin; self.devices = devices
        cpuMaterialImage = Self.materialImages.cpu; gpuMaterialImage = Self.materialImages.gpu
        var cpu: MTLTexture?
        var gpu: MTLTexture?
        var sampler: MTLSamplerState?
        if let device {
            if let cpuMaterialImage {
                cpu = Self.materialTexture(named: "CPU reference crop", image: cpuMaterialImage, device: device)
            }
            if let gpuMaterialImage {
                gpu = Self.materialTexture(named: "GPU reference crop", image: gpuMaterialImage, device: device)
            }
            let descriptor = MTLSamplerDescriptor()
            descriptor.label = "Compute shared package material sampler"
            descriptor.minFilter = .linear; descriptor.magFilter = .linear; descriptor.mipFilter = .linear
            descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: descriptor)
        }
        cpuMaterialTexture = cpu; gpuMaterialTexture = gpu; materialSampler = sampler
        if device == nil { failureReason = "Metal device unavailable" }
        else if commandQueue == nil { failureReason = "Metal queue unavailable" }
        else if library == nil { failureReason = "Compiled chip shader library unavailable" }
        else if cpu == nil || gpu == nil || sampler == nil { failureReason = "Chip package material assets unavailable" }
    }

    /// One bounded reference decode produces two independently owned native rasters, also
    /// available without Metal. The photographed light, labels and annotation leaders are
    /// deliberately repaired masks; this is not a claim to recover a lossless unlit original.
    private static func referenceMaterials() -> (cpu: CGImage?, gpu: CGImage?) {
        guard let url = assetBundle.url(forResource: "ComputeChipReference", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2_048).contains(width), (1...2_048).contains(height),
              width == Int(ComputeChipReferenceGeometry.referenceSize.width),
              height == Int(ComputeChipReferenceGeometry.referenceSize.height),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return (nil, nil) }
        return (preparedReference(image, cpu: true), preparedReference(image, cpu: false))
    }

    private static func preparedReference(_ reference: CGImage, cpu: Bool) -> CGImage? {
        let crop = cpu ? ComputeChipReferenceGeometry.cpuCrop : ComputeChipReferenceGeometry.gpuCrop
        let outline = cpu ? ComputeChipReferenceGeometry.cpuOutline : ComputeChipReferenceGeometry.gpuOutline
        let contacts = cpu ? ComputeChipReferenceGeometry.cpuContactGroups : ComputeChipReferenceGeometry.gpuContactGroups
        let banks = cpu ? ComputeChipReferenceGeometry.cpuBanks : ComputeChipReferenceGeometry.gpuBanks
        let leaders = cpu ? ComputeChipReferenceGeometry.cpuLeaderLines : ComputeChipReferenceGeometry.gpuLeaderLines
        let plate = cpu ? ComputeChipReferenceGeometry.cpuPlateInterior : ComputeChipReferenceGeometry.gpuPlateInterior
        let auxiliary = cpu ? [] : ComputeChipReferenceGeometry.gpuAuxiliaryLightMasks
        guard let cropped = reference.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cropped.width, height = cropped.height, stride = width * 4
        var coverage = [UInt8](repeating: 0, count: width * height)
        let masked = coverage.withUnsafeMutableBytes { maskStorage -> Bool in
            guard let maskContext = CGContext(data: maskStorage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue), let first = outline.first else { return false }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: first.x - crop.minX, y: first.y - crop.minY))
            for point in outline.dropFirst() {
                path.addLine(to: CGPoint(x: point.x - crop.minX, y: point.y - crop.minY))
            }
            path.closeSubpath()
            for contact in contacts { path.addRect(contact.offsetBy(dx: -crop.minX, dy: -crop.minY)) }
            maskContext.setShouldAntialias(true)
            maskContext.translateBy(x: 0, y: CGFloat(height))
            maskContext.scaleBy(x: 1, y: -1)
            maskContext.addPath(path)
            maskContext.setFillColor(gray: 1, alpha: 1)
            maskContext.fillPath(using: .winding)
            return true
        }
        guard masked else { return nil }
        var bytes = [UInt8](repeating: 0, count: stride * height)
        return bytes.withUnsafeMutableBytes { storage -> CGImage? in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: stride, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return nil }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            let original = Array(storage.bindMemory(to: UInt8.self))
            func offset(_ point: CGPoint) -> Int {
                let x = min(max(Int(point.x - crop.minX), 0), width - 1)
                let y = min(max(Int(point.y - crop.minY), 0), height - 1)
                return y * stride + x * 4
            }
            func visit(_ rect: CGRect, _ body: (CGPoint, Int) -> Void) {
                let bounds = rect.intersection(crop)
                guard !bounds.isNull else { return }
                for y in max(0, Int(floor(bounds.minY - crop.minY)))..<min(height, Int(ceil(bounds.maxY - crop.minY))) {
                    for x in max(0, Int(floor(bounds.minX - crop.minX)))..<min(width, Int(ceil(bounds.maxX - crop.minX))) {
                        body(CGPoint(x: crop.minX + CGFloat(x) + 0.5,
                                     y: crop.minY + CGFloat(y) + 0.5), y * stride + x * 4)
                    }
                }
            }
            for line in leaders {
                for pair in zip(line, line.dropFirst()) {
                    let dx = pair.1.x - pair.0.x, dy = pair.1.y - pair.0.y
                    let length = hypot(dx, dy)
                    guard length > 0 else { continue }
                    let normal = CGPoint(x: -dy / length * 4, y: dx / length * 4)
                    let bounds = CGRect(x: min(pair.0.x, pair.1.x), y: min(pair.0.y, pair.1.y),
                                        width: abs(dx), height: abs(dy)).insetBy(dx: -2, dy: -2)
                    visit(bounds) { point, index in
                        let t = min(max(((point.x - pair.0.x) * dx + (point.y - pair.0.y) * dy) / (length * length), 0), 1)
                        let closest = CGPoint(x: pair.0.x + t * dx, y: pair.0.y + t * dy)
                        guard hypot(point.x - closest.x, point.y - closest.y) <= 1.8 else { return }
                        let a = offset(CGPoint(x: closest.x + normal.x, y: closest.y + normal.y))
                        let b = offset(CGPoint(x: closest.x - normal.x, y: closest.y - normal.y))
                        for channel in 0..<3 { storage[index + channel] = UInt8((Int(original[a + channel]) + Int(original[b + channel])) / 2) }
                    }
                }
            }
            for bank in banks + auxiliary {
                visit(bank.insetBy(dx: -2, dy: -2)) { point, index in
                    let interior = bank.insetBy(dx: 2, dy: 2)
                    let distance = max(max(interior.minX - point.x, point.x - interior.maxX),
                                       max(interior.minY - point.y, point.y - interior.maxY))
                    let weight = min(max(1 - distance / 4, 0), 1)
                    let luma = (0.2126 * Double(storage[index]) + 0.7152 * Double(storage[index + 1])
                                + 0.0722 * Double(storage[index + 2])) / 255
                    let unlit = (0.018 + pow(luma, 0.65) * 0.085) * 255
                    for channel in 0..<3 {
                        let target = unlit * [0.78, 0.91, 1.0][channel]
                        storage[index + channel] = UInt8(min(max(Double(storage[index + channel]) * (1 - weight) + target * weight, 0), 255).rounded())
                    }
                }
            }
            // Clear only the photographed plate interior. Row-wise edge samples retain
            // its native dark material gradient; the complete real model name is native text.
            visit(plate) { point, index in
                let left = offset(CGPoint(x: cpu ? plate.minX + 4 : 999, y: point.y))
                let right = offset(CGPoint(x: cpu ? plate.maxX - 4 : 1118, y: point.y))
                let fraction = min(max((point.x - plate.minX) / plate.width, 0), 1)
                for channel in 0..<3 {
                    let value = Double(original[left + channel]) * (1 - fraction) + Double(original[right + channel]) * fraction
                    storage[index + channel] = UInt8(min(max(value, 0), 255).rounded())
                }
            }
            for pixel in coverage.indices {
                let index = pixel * 4, alpha = Int(coverage[pixel])
                for channel in 0..<4 { storage[index + channel] = UInt8(Int(storage[index + channel]) * alpha / 255) }
            }
            return context.makeImage()
        }
    }

    /// Two immutable bundled materials own all mip levels; no frame performs image decoding or upload.
    private static func materialTexture(named name: String, image: CGImage, device: MTLDevice) -> MTLTexture? {
        guard image.width > 0, image.height > 0, image.width <= 2_048, image.height <= 2_048,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                                 width: image.width, height: image.height,
                                                                 mipmapped: true)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Compute immutable \(name) material"
        for level in 0..<texture.mipmapLevelCount {
            let width = max(image.width >> level, 1), height = max(image.height >> level, 1)
            let bytesPerRow = width * 4
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            let uploaded = bytes.withUnsafeMutableBytes { storage -> Bool in
                guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                // CoreGraphics explicitly produced premultiplied RGBA. The existing source-alpha
                // pipeline expects straight color, including each independently filtered mip.
                for offset in stride(from: 0, to: storage.count, by: 4) {
                    let alpha = Int(storage[offset + 3])
                    for channel in 0..<3 {
                        storage[offset + channel] = alpha == 0 ? 0
                            : UInt8(min(255, (Int(storage[offset + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level,
                                withBytes: storage.baseAddress!, bytesPerRow: bytesPerRow)
                return true
            }
            guard uploaded else { return nil }
        }
        return texture
    }

    func pipeline() -> MTLRenderPipelineState? {
        if let cachedPipeline { return cachedPipeline }
        guard let device, let library, cpuMaterialTexture != nil, gpuMaterialTexture != nil,
              materialSampler != nil,
              let vertex = library.makeFunction(name: "compute_chip_vertex"),
              let fragment = library.makeFunction(name: "compute_chip_fragment") else {
            if failureReason == nil { failureReason = "Compiled chip shader functions unavailable" }
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Compute Cores compiled chip FX"
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm_srgb
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            cachedPipeline = pipeline
            return pipeline
        } catch {
            failureReason = "Compiled chip pipeline unavailable"
            return nil
        }
    }
}

private struct ComputeChipUniforms {
    var viewport: SIMD4<Float>
    var options: SIMD4<Float>
}

/// Completion releases slots without waiting on the GPU or mutating observation state on a worker.
private final class ComputeChipFramePool: @unchecked Sendable {
    struct Slot { let activity: MTLBuffer; let pulses: MTLBuffer }
    let slots: [Slot]
    private let lock = NSLock()
    private var busy = [false, false, false]
    private let diagnostics: ComputeChipDiagnostics

    init?(device: MTLDevice, diagnostics: ComputeChipDiagnostics) {
        var slots: [Slot] = []
        for index in 0..<3 {
            guard let activity = device.makeBuffer(length: 272 * MemoryLayout<Float>.stride, options: .storageModeShared),
                  let pulses = device.makeBuffer(length: 192 * MemoryLayout<ComputeChipInstance>.stride, options: .storageModeShared)
            else { return nil }
            activity.label = "Compute activity slot \(index)"
            pulses.label = "Compute trace slot \(index)"
            slots.append(.init(activity: activity, pulses: pulses))
        }
        self.slots = slots; self.diagnostics = diagnostics
        diagnostics.change { $0.ownedBuffers += 6 }
    }

    func acquire() -> Int? {
        let index = lock.withLock { () -> Int? in
            guard let index = busy.firstIndex(of: false) else { return nil }
            busy[index] = true; return index
        }
        if index != nil {
            diagnostics.change {
                $0.inFlightSlots += 1
                $0.maximumInFlightSlots = max($0.maximumInFlightSlots, $0.inFlightSlots)
            }
        }
        return index
    }

    func release(_ index: Int) {
        let released = lock.withLock { () -> Bool in
            guard busy[index] else { return false }
            busy[index] = false; return true
        }
        if released { diagnostics.change { $0.inFlightSlots -= 1 } }
    }

    deinit { diagnostics.change { $0.ownedBuffers -= 6 } }
}

struct ComputeChipPresentation: Equatable {
    var cpuState: String
    var gpuState: String
    var rendererFailure: String?
}

struct ComputeChipPixels: Sendable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pointSize: CGSize
    /// Actual sRGB BGRA8 drawable bytes, padded to the native Metal blit stride.
    var bytes: Data
}

/// One immutable blit destination belongs to one command completion. CPU access
/// occurs only after that command reports completion; delivery stays on MainActor.
private final class ComputeChipReadback: @unchecked Sendable {
    private let buffer: MTLBuffer
    private let width: Int
    private let height: Int
    private let stride: Int
    private let pointSize: CGSize
    let deliver: @MainActor @Sendable (ComputeChipPixels) -> Void

    init(buffer: MTLBuffer, width: Int, height: Int, stride: Int, pointSize: CGSize,
         deliver: @escaping @MainActor @Sendable (ComputeChipPixels) -> Void) {
        self.buffer = buffer; self.width = width; self.height = height
        self.stride = stride; self.pointSize = pointSize; self.deliver = deliver
    }

    func pixelsAfterCompletion() -> ComputeChipPixels {
        ComputeChipPixels(width: width, height: height, bytesPerRow: stride, pointSize: pointSize,
                          bytes: Data(bytes: buffer.contents(), count: stride * height))
    }
}

@MainActor
final class ComputeChipRenderer: NSObject, MTKViewDelegate {
    let diagnostics: ComputeChipDiagnostics
    private let resources: ComputeChipResources
    private let lifetime: GaugeSurfaceLifetime
    private weak var view: ComputeChipMetalView?
    private var pipeline: MTLRenderPipelineState?
    private var pool: ComputeChipFramePool?
    private var geometryBuffer: MTLBuffer?
    private(set) var layout: ComputeChipLayout?
    private var snapshot: ComputeChipSnapshot?
    private var animation = ComputeChipAnimation()
    private var autoRefresh = true
    private var reduceMotion = false
    private var increasedContrast = false
    private var dirty = true
    private var drawableSize = CGSize.zero
    private var animationRunning = false
    private var failure: String?
    private var lastPresentation: ComputeChipPresentation?
    private var pendingPresentation: ComputeChipPresentation?
    private var presentationQueued = false
    private var presentationGeneration = 0
    private var freshnessWork: DispatchWorkItem?
    private var freshnessDeadline: TimeInterval?
    private var presentationChanged: ((ComputeChipPresentation) -> Void)?
    private var readbackRequested: (@MainActor @Sendable (ComputeChipPixels) -> Void)?
    private var readbackInFlight = false

    init(resources: ComputeChipResources? = nil, diagnostics: ComputeChipDiagnostics = ComputeChipDiagnostics(),
         surfaceDiagnostics: RuntimeDiagnostics? = nil, presentationChanged: ((ComputeChipPresentation) -> Void)? = nil) {
        self.resources = resources ?? .shared; self.diagnostics = diagnostics
        lifetime = GaugeSurfaceLifetime(scope: surfaceDiagnostics)
        self.presentationChanged = presentationChanged
        super.init()
        self.diagnostics.change {
            $0.sharedMaterialTextures = self.resources.materialTextureCount
            $0.sharedMaterialSamplers = self.resources.materialSampler == nil ? 0 : 1
            $0.materialTextureLoads = self.resources.materialTextureCount
        }
    }

    func attach(_ view: ComputeChipMetalView) {
        self.view = view; view.renderer = self
        guard let device = resources.device, let pipeline = resources.pipeline(), resources.commandQueue != nil,
              let pool = ComputeChipFramePool(device: device, diagnostics: diagnostics) else {
            failure = resources.failureReason ?? "Metal chip frame resources unavailable"
            publishPresentation(wallTime: Date().timeIntervalSince1970)
            return
        }
        self.pipeline = pipeline; self.pool = pool
        view.device = device; view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false; view.framebufferOnly = true; view.autoResizeDrawable = true
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.delegate = self; drawableSize = view.drawableSize
        lifetime.attach()
        diagnostics.change { $0.activeSurfaces += 1; $0.libraryOrigin = resources.libraryOrigin }
        visibilityChanged()
    }

    func update(snapshot: ComputeChipSnapshot, autoRefresh: Bool, reduceMotion: Bool, increasedContrast: Bool) {
        guard self.snapshot != snapshot || self.autoRefresh != autoRefresh || self.reduceMotion != reduceMotion
                || self.increasedContrast != increasedContrast else { return }
        self.snapshot = snapshot; self.autoRefresh = autoRefresh
        self.reduceMotion = reduceMotion; self.increasedContrast = increasedContrast
        dirty = true
        publishPresentation(wallTime: Date().timeIntervalSince1970)
        visibilityChanged()
    }

    func detach(from view: ComputeChipMetalView) {
        setAnimationRunning(false)
        if view.delegate === self { view.delegate = nil }
        view.renderer = nil; view.removeLifecycleObservations()
        self.view = nil; pool = nil; pipeline = nil
        if geometryBuffer != nil { diagnostics.change { $0.ownedBuffers -= 1 } }
        geometryBuffer = nil; layout = nil; snapshot = nil
        lifetime.detach()
        diagnostics.change { $0.activeSurfaces = max(0, $0.activeSurfaces - 1) }
        presentationGeneration += 1; pendingPresentation = nil; presentationQueued = false
        freshnessWork?.cancel(); freshnessWork = nil; freshnessDeadline = nil
        presentationChanged = nil; animation.resetClock()
        readbackRequested = nil
    }

    /// Bounded diagnostic readback of the same production pass; no injected measurements or alternate shader.
    func requestReadback(_ callback: @escaping @MainActor @Sendable (ComputeChipPixels) -> Void) {
        readbackRequested = callback
        view?.framebufferOnly = false
        dirty = true
        visibilityChanged()
    }

    func visibilityChanged() {
        guard let view else { return }
        guard view.isRenderingEligible, failure == nil, pipeline != nil else {
            setAnimationRunning(false); animation.resetClock(); return
        }
        let wallTime = Date().timeIntervalSince1970
        if let snapshot {
            let motion = animation.advance(snapshot: snapshot, monotonic: ProcessInfo.processInfo.systemUptime,
                                           wallTime: wallTime, motionAllowed: !reduceMotion, paused: !autoRefresh)
            setAnimationRunning(motion)
        }
        dirty = true; view.setNeedsDisplay(view.bounds)
        scheduleFreshnessBoundary(wallTime: wallTime)
        publishPresentation(wallTime: wallTime)
    }

    private func setAnimationRunning(_ running: Bool) {
        guard let view else { animationRunning = false; return }
        if animationRunning != running {
            animationRunning = running
            diagnostics.change { $0.activeClocks = running ? 1 : 0 }
        }
        view.preferredFramesPerSecond = ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30
        view.isPaused = !running
        view.enableSetNeedsDisplay = !running
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard drawableSize != size else { return }
        drawableSize = size; dirty = true
        visibilityChanged()
    }

    func draw(in view: MTKView) {
        guard let native = view as? ComputeChipMetalView, native.isRenderingEligible else {
            setAnimationRunning(false); animation.resetClock(); return
        }
        guard dirty || animationRunning, let snapshot, let pipeline, let pool,
              let device = resources.device, let queue = resources.commandQueue else { return }
        let wallTime = Date().timeIntervalSince1970
        let moving = animation.advance(snapshot: snapshot, monotonic: ProcessInfo.processInfo.systemUptime,
                                       wallTime: wallTime, motionAllowed: !reduceMotion, paused: !autoRefresh)
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        if layout?.size.width != size.width || layout?.cpuRegions.count != max(snapshot.cpu.activity.count, 1) {
            let next = ComputeChipLayout.make(width: size.width, cpuRegionCount: snapshot.cpu.activity.count)
            let bytes = next.instances.count * MemoryLayout<ComputeChipInstance>.stride
            guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
                rendererFailed("Metal chip geometry unavailable"); return
            }
            next.instances.withUnsafeBytes { source in
                if let base = source.baseAddress { buffer.contents().copyMemory(from: base, byteCount: bytes) }
            }
            buffer.label = "Compute static package geometry"
            if geometryBuffer == nil { diagnostics.change { $0.ownedBuffers += 1 } }
            geometryBuffer = buffer; layout = next
            diagnostics.change { $0.geometryRebuilds += 1 }
        }
        guard let layout, let geometryBuffer, let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }
        guard let slotIndex = pool.acquire() else {
            diagnostics.change { $0.skippedBusySlots += 1 }; return
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            pool.release(slotIndex); rendererFailed("Metal chip command unavailable"); return
        }
        let slot = pool.slots[slotIndex]
        animation.values.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { slot.activity.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
        let pulses = animation.pulseInstances(routes: layout.routes, snapshot: snapshot, wallTime: wallTime,
                                             motionAllowed: !reduceMotion, paused: !autoRefresh)
        pulses.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { slot.pulses.contents().copyMemory(from: base, byteCount: bytes.count) }
        }
        func sourceBrightness(_ channel: ComputeChipChannel) -> Float {
            if channel.quality != .measured && channel.quality != .aggregateFallback { return 0.5 }
            return !autoRefresh || channel.isFresh(at: wallTime) ? 1 : 0.35
        }
        var uniforms = ComputeChipUniforms(viewport: SIMD4(Float(size.width), Float(size.height), 0, 0),
                                           options: SIMD4(increasedContrast ? 1 : 0, sourceBrightness(snapshot.cpu),
                                                          sourceBrightness(snapshot.gpu), 0))
        command.label = "Compute Cores compiled Metal FX"
        encoder.label = "Compute package regions and simulated trace pulses"
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ComputeChipUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ComputeChipUniforms>.stride, index: 1)
        encoder.setFragmentBuffer(slot.activity, offset: 0, index: 0)
        encoder.setFragmentTexture(resources.cpuMaterialTexture, index: 0)
        encoder.setFragmentTexture(resources.gpuMaterialTexture, index: 1)
        encoder.setFragmentSamplerState(resources.materialSampler, index: 0)
        encoder.setVertexBuffer(geometryBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: layout.instances.count)
        if !pulses.isEmpty {
            encoder.setVertexBuffer(slot.pulses, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pulses.count)
        }
        encoder.endEncoding()
        var preparedReadback: ComputeChipReadback?
        if !readbackInFlight, let callback = readbackRequested {
            let texture = drawable.texture
            let stride = (texture.width * 4 + 255) & ~255
            let bytes = stride * texture.height
            if bytes <= 16 * 1_024 * 1_024,
               let buffer = device.makeBuffer(length: bytes, options: .storageModeShared),
               let blit = command.makeBlitCommandEncoder() {
                buffer.label = "Compute bounded diagnostic drawable readback"
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                          to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                          destinationBytesPerImage: bytes)
                blit.endEncoding()
                preparedReadback = ComputeChipReadback(buffer: buffer, width: texture.width, height: texture.height,
                                                       stride: stride, pointSize: size, deliver: callback)
                readbackInFlight = true
                diagnostics.change {
                    $0.inFlightReadbacks += 1
                    $0.maximumInFlightReadbacks = max($0.maximumInFlightReadbacks, $0.inFlightReadbacks)
                }
            }
            readbackRequested = nil
        }
        let diagnostics = diagnostics
        let generation = presentationGeneration
        let readback = preparedReadback
        command.addCompletedHandler { [weak self] completed in
            pool.release(slotIndex)
            let success = completed.status == .completed
            diagnostics.change {
                if success { $0.completedCommands += 1 } else { $0.failedCommands += 1 }
                if readback != nil { $0.inFlightReadbacks -= 1 }
                let duration = completed.gpuEndTime - completed.gpuStartTime
                if duration.isFinite && duration > 0 { $0.lastGPUDuration = duration }
            }
            let pixels = success ? readback?.pixelsAfterCompletion() : nil
            if !success || readback != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if readback != nil { self.readbackInFlight = false }
                    guard generation == self.presentationGeneration, self.view != nil else {
                        if self.readbackRequested != nil, self.view != nil {
                            self.dirty = true
                            self.visibilityChanged()
                        }
                        return
                    }
                    if !success { self.rendererFailed("Metal chip command failed") }
                    if let pixels, let readback { readback.deliver(pixels) }
                    self.view?.framebufferOnly = self.readbackRequested == nil
                    if self.readbackRequested != nil, success {
                        self.dirty = true
                        self.visibilityChanged()
                    }
                }
            }
        }
        command.present(drawable); command.commit()
        diagnostics.change { $0.submissions += 1; if moving { $0.animationFrames += 1 } else { $0.staticFrames += 1 } }
        RuntimeDiagnostics.shared.increment(.gaugeDraws)
        dirty = false; setAnimationRunning(moving)
        publishPresentation(wallTime: wallTime)
    }

    private func rendererFailed(_ reason: String) {
        failure = reason; setAnimationRunning(false)
        readbackRequested = nil
        freshnessWork?.cancel(); freshnessWork = nil; freshnessDeadline = nil
        publishPresentation(wallTime: Date().timeIntervalSince1970)
    }

    private func scheduleFreshnessBoundary(wallTime: TimeInterval) {
        // One outstanding boundary inspects the newest snapshot when it fires.
        // Replacing samples does not enqueue canceled callbacks at collection cadence.
        guard freshnessWork == nil, autoRefresh else { return }
        let next = autoRefresh ? [snapshot?.cpu.observedAt, snapshot?.gpu.observedAt]
            .compactMap { $0 }.filter { $0.isFinite && $0 + 3 > wallTime + 0.01 }.map { $0 + 3 }.min() : nil
        freshnessDeadline = next
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.freshnessWork = nil; self.freshnessDeadline = nil
            guard self.autoRefresh, self.view?.isRenderingEligible == true else { return }
            self.visibilityChanged()
        }
        freshnessWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(next - wallTime, 0.02), execute: work)
    }

    private func publishPresentation(wallTime: TimeInterval) {
        guard let snapshot else { return }
        let next = ComputeChipPresentation(cpuState: snapshot.cpu.label(at: wallTime, paused: !autoRefresh),
                                           gpuState: snapshot.gpu.label(at: wallTime, paused: !autoRefresh),
                                           rendererFailure: failure)
        guard next != lastPresentation else { return }
        pendingPresentation = next
        guard !presentationQueued else { return }
        presentationQueued = true
        let generation = presentationGeneration
        // One replaceable status notification, never one task or publication per animation frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.presentationQueued = false
            guard let next = self.pendingPresentation else { return }
            self.pendingPresentation = nil; self.lastPresentation = next
            self.presentationChanged?(next)
        }
    }
}

@MainActor
final class ComputeChipMetalView: MTKView {
    weak var renderer: ComputeChipRenderer?
    private weak var observedClip: NSClipView?
    private var changedClipNotificationFlag = false
    private var powerStateObservation: NSObjectProtocol?
    private(set) var powerStateNotificationCount = 0

    var hasPowerStateObservation: Bool { powerStateObservation != nil }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isRenderingEligible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0 else { return false }
        let visible = visibleRect.intersection(bounds)
        return !visible.isNull && visible.width > 1 && visible.height > 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); installLifecycleObservations(); renderer?.visibilityChanged()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview(); installLifecycleObservations(); renderer?.visibilityChanged()
    }
    override func viewDidHide() { super.viewDidHide(); renderer?.visibilityChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); renderer?.visibilityChanged() }

    private func installLifecycleObservations() {
        removeLifecycleObservations()
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged), name: name, object: window)
        }
        powerStateObservation = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.powerStateObservation != nil else { return }
                self.powerStateNotificationCount += 1
                self.renderer?.visibilityChanged()
            }
        }
        var parent = superview
        while let candidate = parent {
            if let clip = candidate as? NSClipView {
                observedClip = clip
                if !clip.postsBoundsChangedNotifications {
                    clip.postsBoundsChangedNotifications = true; changedClipNotificationFlag = true
                }
                NotificationCenter.default.addObserver(self, selector: #selector(lifecycleChanged),
                                                       name: NSView.boundsDidChangeNotification, object: clip)
                break
            }
            parent = candidate.superview
        }
    }

    func removeLifecycleObservations() {
        NotificationCenter.default.removeObserver(self)
        if let powerStateObservation { NotificationCenter.default.removeObserver(powerStateObservation) }
        powerStateObservation = nil
        if changedClipNotificationFlag { observedClip?.postsBoundsChangedNotifications = false }
        changedClipNotificationFlag = false; observedClip = nil
    }

    @objc private func lifecycleChanged(_ notification: Notification) { renderer?.visibilityChanged() }
    isolated deinit { removeLifecycleObservations() }
}
