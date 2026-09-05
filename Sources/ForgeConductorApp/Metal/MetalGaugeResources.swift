// MetalGaugeResources.swift
// What: Owns the shared Metal device, command queue, pipeline cache, and reusable buffers.
// How: Every gauge borrows one queue/pipeline and grows persistent shared buffers only as needed.
// Why: Gauge updates should upload data and draw on demand, not rebuild GPU infrastructure.

import ForgeConductorCore
import MetalKit
import simd

struct GaugeVertex {
    var pos: SIMD2<Float>
    var color: SIMD4<Float>
}

@MainActor
final class MetalGaugeResources {
    static let shared = MetalGaugeResources()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        if commandQueue != nil {
            RuntimeDiagnostics.shared.increment(.gaugeCommandQueuesCreated)
        }
    }

    func pipeline(pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let cached = pipelines[pixelFormat] { return cached }
        guard let device,
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let vertex = library.makeFunction(name: "gauge_vertex"),
              let fragment = library.makeFunction(name: "gauge_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[pixelFormat] = pipeline
        RuntimeDiagnostics.shared.increment(.gaugePipelinesCreated)
        return pipeline
    }

    func configure(_ view: MTKView, clearColor: MTLClearColor) -> MTLRenderPipelineState? {
        guard let device else { return nil }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = clearColor
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        return pipeline(pixelFormat: view.colorPixelFormat)
    }

    /// AppKit may still invoke a demand-drawn MTKView after its window is
    /// ordered out. Check the native visibility boundary before scheduling or
    /// submitting work, including an unattached view and a hidden ancestor.
    static func canRender(_ view: MTKView) -> Bool {
        view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { float2 p; float4 c; };
    struct O { float4 position [[position]]; float4 c; };
    vertex O gauge_vertex(uint i [[vertex_id]], const device P *v [[buffer(0)]]) {
        O o; o.position = float4(v[i].p, 0, 1); o.c = v[i].c; return o;
    }
    fragment float4 gauge_fragment(O in [[stage_in]]) { return in.c; }
    """
}

/// Resumes one pending demand draw at actual native visibility transitions.
/// Selector observations are scoped to this view's current window and removed
/// on detach and destruction; no timer or render loop is installed.
@MainActor
final class GaugeMetalView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didExposeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didExposeNotification, object: window)
        }
        resumeDemandDraw()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        resumeDemandDraw()
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        resumeDemandDraw()
    }

    private func resumeDemandDraw() {
        guard delegate != nil, MetalGaugeResources.canRender(self) else { return }
        setNeedsDisplay(bounds)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
final class MetalVertexBuffer<Vertex> {
    private(set) var buffer: MTLBuffer?
    private(set) var count = 0
    private(set) var capacityBytes = 0

    func upload(_ vertices: [Vertex], device: MTLDevice) {
        let requiredBytes = vertices.count * MemoryLayout<Vertex>.stride
        count = vertices.count
        guard requiredBytes > 0 else { return }
        ensureCapacity(requiredBytes, device: device)
        guard let buffer else { return }
        vertices.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: source, byteCount: requiredBytes)
        }
    }

    func clear() {
        count = 0
    }

    func release() {
        buffer = nil
        count = 0
        capacityBytes = 0
    }

    private func ensureCapacity(_ requiredBytes: Int, device: MTLDevice) {
        guard buffer == nil || capacityBytes < requiredBytes else { return }
        var capacity = max(256, capacityBytes)
        while capacity < requiredBytes { capacity *= 2 }
        guard let replacement = device.makeBuffer(length: capacity, options: .storageModeShared) else { return }
        buffer = replacement
        capacityBytes = capacity
        RuntimeDiagnostics.shared.increment(.gaugeBuffersCreated)
        RuntimeDiagnostics.shared.recordMaximum(.gaugeBufferCapacityBytes, candidate: capacity)
    }
}

@MainActor
final class GaugeSurfaceLifetime {
    private var attached = false

    func attach() {
        guard !attached else { return }
        attached = true
        RuntimeDiagnostics.shared.adjust(.gaugeActiveSurfaces, by: 1)
        RuntimeDiagnostics.shared.adjust(.gaugeVisibleSurfaces, by: 1)
    }

    func detach() {
        guard attached else { return }
        attached = false
        RuntimeDiagnostics.shared.adjust(.gaugeActiveSurfaces, by: -1)
        RuntimeDiagnostics.shared.adjust(.gaugeVisibleSurfaces, by: -1)
    }

    deinit {
        if attached {
            RuntimeDiagnostics.shared.adjust(.gaugeActiveSurfaces, by: -1)
            RuntimeDiagnostics.shared.adjust(.gaugeVisibleSurfaces, by: -1)
        }
    }
}
