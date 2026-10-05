// MetalGaugeKit.swift
// What: Supplies the reusable Metal-backed gauges used throughout the rig.
// How: Shared palettes and pipelines feed dedicated renderers, while small
// NSViewRepresentable adapters expose bars, rings, tiles, and status pills to SwiftUI.
// Why: Centralizing gauge primitives keeps visual behavior consistent and modular.

import SwiftUI
import MetalKit
import simd
import ForgeConductorCore

extension TelemetryStatusTone {
    var color: Color {
        switch self {
        case .healthy: GraphitePalette.success
        case .caution: GraphitePalette.warning
        case .failure: GraphitePalette.failure
        case .informational: GraphitePalette.info
        case .unavailable: .secondary
        }
    }
}

// MARK: - Shared shader + types

enum MetalGaugePalette {
    static let cyan = GraphitePalette.metalCPU
    static let orange = GraphitePalette.metalWarning
    static let green = GraphitePalette.metalSuccess
    static let purple = GraphitePalette.metalGPU
    static let red = GraphitePalette.metalFailure
    static let track = GraphitePalette.metalTrack
    static let trackTop = GraphitePalette.metalTrackTop
    static let trackBottom = GraphitePalette.metalTrackBottom

    static func shade(_ color: SIMD4<Float>, brightness: Float) -> SIMD4<Float> {
        SIMD4(min(color.x * brightness, 1), min(color.y * brightness, 1),
              min(color.z * brightness, 1), color.w)
    }

    static func from(swiftUI color: Color) -> SIMD4<Float> {
        let n = NSColor(color)
        guard let rgb = n.usingColorSpace(.deviceRGB) else { return cyan }
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
    }

    static func health(_ h: String) -> SIMD4<Float> {
        switch TelemetryHealth.tone(for: h) {
        case .healthy: return green
        case .caution: return GraphitePalette.metalWarning
        case .failure: return red
        case .informational: return cyan
        case .unavailable: return SIMD4(0.48, 0.54, 0.62, 1)
        }
    }
}

// MARK: - Horizontal meter

@MainActor
final class MetalBarRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let vertices = MetalVertexBuffer<GaugeVertex>()
    private let surfaceLifetime: GaugeSurfaceLifetime
    private weak var view: MTKView?
    private var dirty = false
    private var drawableSize = CGSize.zero
    private var fraction: Float = 0
    private var color = MetalGaugePalette.cyan

    override convenience init() { self.init(surfaceDiagnostics: nil) }

    init(surfaceDiagnostics: RuntimeDiagnostics?) {
        surfaceLifetime = GaugeSurfaceLifetime(scope: surfaceDiagnostics)
        super.init()
    }

    func attach(_ view: MTKView) {
        let resources = MetalGaugeResources.shared
        guard let device = resources.device,
              let pipeline = resources.configure(
                  view,
                  clearColor: GraphitePalette.metalClear
              )
        else { return }
        self.device = device
        self.queue = resources.commandQueue
        self.pipeline = pipeline
        self.view = view
        drawableSize = view.drawableSize
        view.delegate = self
        surfaceLifetime.attach()
        requestDraw()
    }

    func set(fraction: Float, color: SIMD4<Float>) {
        let nextFraction = min(max(fraction, 0), 1)
        guard self.fraction != nextFraction || self.color != color else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        self.fraction = nextFraction
        self.color = color
        requestDraw()
    }

    private func rebuild() {
        guard let device else { return }
        let x = -1 + 2 * fraction
        let values: [GaugeVertex] = [
            .init(pos: SIMD2(-1, -0.55), color: MetalGaugePalette.trackBottom),
            .init(pos: SIMD2(1, -0.55), color: MetalGaugePalette.trackBottom),
            .init(pos: SIMD2(-1, 0.55), color: MetalGaugePalette.trackTop),
            .init(pos: SIMD2(1, 0.55), color: MetalGaugePalette.trackTop),
            .init(pos: SIMD2(-1, -0.55), color: MetalGaugePalette.shade(color, brightness: 0.7)),
            .init(pos: SIMD2(x, -0.55), color: MetalGaugePalette.shade(color, brightness: 0.7)),
            .init(pos: SIMD2(-1, 0.55), color: MetalGaugePalette.shade(color, brightness: 1.1)),
            .init(pos: SIMD2(x, 0.55), color: MetalGaugePalette.shade(color, brightness: 1.1)),
        ]
        vertices.upload(values, device: device)
    }

    func detach(from view: MTKView) {
        if view.delegate === self { view.delegate = nil }
        self.view = nil
        dirty = false
        vertices.release()
        surfaceLifetime.detach()
    }

    private func requestDraw() {
        dirty = true
        guard let view, MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        view.setNeedsDisplay(view.bounds)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard drawableSize != size else { return }
        drawableSize = size
        requestDraw()
    }
    func draw(in view: MTKView) {
        guard dirty else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        guard MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        rebuild()
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer = vertices.buffer,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        dirty = false
        RuntimeDiagnostics.shared.increment(.gaugeDraws)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 4, vertexCount: 4)
        enc.endEncoding(); cmd.present(d); cmd.commit()
    }
}

struct MetalBarGauge: NSViewRepresentable {
    var fraction: Double
    var tint: Color
    var surfaceDiagnostics: RuntimeDiagnostics? = nil

    func makeCoordinator() -> MetalBarRenderer { MetalBarRenderer(surfaceDiagnostics: surfaceDiagnostics) }

    func makeNSView(context: Context) -> MTKView {
        let v = GaugeMetalView(frame: NSRect(x: 0, y: 0, width: 48, height: 8))
        // MTKView has no sensible intrinsic size; without bounds it reports huge
        // preferred sizes and blows out SwiftUI headers/rows.
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoResizeDrawable = true
        v.framebufferOnly = true
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .vertical)
        context.coordinator.attach(v)
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: MetalBarRenderer) {
        coordinator.detach(from: nsView)
    }

    /// Honor the SwiftUI proposed size so Metal bars never invent their own scale.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        let width = proposal.width ?? 48
        let height = proposal.height ?? 8
        return CGSize(width: max(width, 1), height: max(height, 1))
    }
}

// MARK: - Activity ring (MCP cards)

@MainActor
final class MetalRingRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let vertices = MetalVertexBuffer<GaugeVertex>()
    private let surfaceLifetime: GaugeSurfaceLifetime
    private weak var view: MTKView?
    private var dirty = false
    private var drawableSize = CGSize.zero
    private var count = 0
    private var fraction: Float = 0
    private var color = MetalGaugePalette.cyan

    override convenience init() { self.init(surfaceDiagnostics: nil) }

    init(surfaceDiagnostics: RuntimeDiagnostics?) {
        surfaceLifetime = GaugeSurfaceLifetime(scope: surfaceDiagnostics)
        super.init()
    }

    func attach(_ view: MTKView) {
        let resources = MetalGaugeResources.shared
        guard let device = resources.device,
              let pipeline = resources.configure(
                  view,
                  clearColor: GraphitePalette.metalClear
              )
        else { return }
        self.device = device
        self.queue = resources.commandQueue
        self.pipeline = pipeline
        self.view = view
        drawableSize = view.drawableSize
        view.delegate = self
        surfaceLifetime.attach()
        requestDraw()
    }

    func set(fraction: Float, color: SIMD4<Float>) {
        let nextFraction = min(max(fraction, 0), 1)
        guard self.fraction != nextFraction || self.color != color else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        self.fraction = nextFraction
        self.color = color
        requestDraw()
    }

    private func rebuild() {
        guard let device else { return }
        var verts: [GaugeVertex] = []
        let segments = 64
        let outer: Float = 0.88
        let inner: Float = 0.62
        // Background ring full 360
        appendRing(into: &verts, from: 0, to: 1, outer: outer, inner: inner, color: MetalGaugePalette.track, segments: segments)
        // Progress arc (start at top, clockwise)
        if fraction > 0.001 {
            appendRing(
                into: &verts,
                from: 0,
                to: fraction,
                outer: outer,
                inner: inner,
                color: color,
                segments: max(4, Int(Float(segments) * fraction))
            )
        }
        count = verts.count
        vertices.upload(verts, device: device)
    }

    private func appendRing(
        into verts: inout [GaugeVertex],
        from: Float,
        to: Float,
        outer: Float,
        inner: Float,
        color: SIMD4<Float>,
        segments: Int
    ) {
        // Angle: 0 at top (-pi/2), increasing clockwise for "activity" feel
        let start = -Float.pi / 2 + from * Float.pi * 2
        let end = -Float.pi / 2 + to * Float.pi * 2
        let n = max(segments, 2)
        for i in 0..<n {
            let t0 = Float(i) / Float(n)
            let t1 = Float(i + 1) / Float(n)
            let a0 = start + (end - start) * t0
            let a1 = start + (end - start) * t1
            let o0 = SIMD2(cos(a0) * outer, sin(a0) * outer)
            let o1 = SIMD2(cos(a1) * outer, sin(a1) * outer)
            let i0 = SIMD2(cos(a0) * inner, sin(a0) * inner)
            let i1 = SIMD2(cos(a1) * inner, sin(a1) * inner)
            // two triangles
            verts.append(.init(pos: o0, color: color))
            verts.append(.init(pos: i0, color: MetalGaugePalette.shade(color, brightness: 0.7)))
            verts.append(.init(pos: o1, color: color))
            verts.append(.init(pos: o1, color: color))
            verts.append(.init(pos: i0, color: MetalGaugePalette.shade(color, brightness: 0.7)))
            verts.append(.init(pos: i1, color: MetalGaugePalette.shade(color, brightness: 0.7)))
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard drawableSize != size else { return }
        drawableSize = size
        requestDraw()
    }
    func draw(in view: MTKView) {
        guard dirty else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        guard MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        rebuild()
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer = vertices.buffer, count >= 3,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        dirty = false
        RuntimeDiagnostics.shared.increment(.gaugeDraws)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        enc.endEncoding(); cmd.present(d); cmd.commit()
    }

    func detach(from view: MTKView) {
        if view.delegate === self { view.delegate = nil }
        self.view = nil
        dirty = false
        vertices.release()
        surfaceLifetime.detach()
    }

    private func requestDraw() {
        dirty = true
        guard let view, MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        view.setNeedsDisplay(view.bounds)
    }
}

struct MetalRingGauge: NSViewRepresentable {
    var fraction: Double
    var tint: Color
    var label: String = ""
    var surfaceDiagnostics: RuntimeDiagnostics? = nil

    func makeCoordinator() -> MetalRingRenderer { MetalRingRenderer(surfaceDiagnostics: surfaceDiagnostics) }
    func makeNSView(context: Context) -> MTKView {
        let v = GaugeMetalView()
        context.coordinator.attach(v)
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.set(fraction: Float(fraction), color: MetalGaugePalette.from(swiftUI: tint))
    }
    static func dismantleNSView(_ nsView: MTKView, coordinator: MetalRingRenderer) {
        coordinator.detach(from: nsView)
    }
}

/// Ring with centered text overlay (SwiftUI text + Metal ring).
struct MetalRingGaugeLabeled: View {
    var fraction: Double
    var tint: Color
    var centerText: String

    var body: some View {
        ZStack {
            MetalRingGauge(fraction: fraction, tint: tint)
            Text(centerText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Core bars (all Metal)

@MainActor
final class MetalCoreBarsRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let vertices = MetalVertexBuffer<GaugeVertex>()
    private let surfaceLifetime: GaugeSurfaceLifetime
    private weak var view: MTKView?
    private var dirty = false
    private var drawableSize = CGSize.zero
    private var count = 0
    private var cores: [Float] = []

    override convenience init() { self.init(surfaceDiagnostics: nil) }

    init(surfaceDiagnostics: RuntimeDiagnostics?) {
        surfaceLifetime = GaugeSurfaceLifetime(scope: surfaceDiagnostics)
        super.init()
    }

    func attach(_ view: MTKView) {
        let resources = MetalGaugeResources.shared
        guard let device = resources.device,
              let pipeline = resources.configure(
                  view,
                  clearColor: GraphitePalette.metalClear
              )
        else { return }
        self.device = device
        self.queue = resources.commandQueue
        self.pipeline = pipeline
        self.view = view
        drawableSize = view.drawableSize
        view.delegate = self
        surfaceLifetime.attach()
        requestDraw()
    }

    func set(cores: [Float]) {
        guard self.cores != cores else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        self.cores = cores
        requestDraw()
    }

    private func rebuild() {
        guard let device else { return }
        guard !cores.isEmpty else {
            count = 0
            vertices.clear()
            return
        }
        var verts: [GaugeVertex] = []
        let n = cores.count
        let gap: Float = 0.015
        let totalGap = gap * Float(n + 1)
        let barW = (2.0 - totalGap) / Float(n)
        let bottom: Float = -0.9
        let top: Float = 0.9
        let height = top - bottom
        for (i, pct) in cores.enumerated() {
            let p = min(max(pct / 100, 0), 1)
            let x0 = -1 + gap + Float(i) * (barW + gap)
            let x1 = x0 + barW
            // track
            verts.append(contentsOf: quad(x0, bottom, x1, top, MetalGaugePalette.track))
            // fill
            let y1 = bottom + height * p
            let hot = p >= 0.75
            let c = hot ? MetalGaugePalette.orange : MetalGaugePalette.cyan
            verts.append(contentsOf: quad(x0, bottom, x1, y1, c))
        }
        count = verts.count
        vertices.upload(verts, device: device)
    }

    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: SIMD4<Float>) -> [GaugeVertex] {
        let lower = MetalGaugePalette.shade(c, brightness: 0.65)
        let upper = MetalGaugePalette.shade(c, brightness: 1.08)
        return [
            .init(pos: SIMD2(x0, y0), color: lower),
            .init(pos: SIMD2(x1, y0), color: lower),
            .init(pos: SIMD2(x0, y1), color: upper),
            .init(pos: SIMD2(x1, y0), color: lower),
            .init(pos: SIMD2(x1, y1), color: upper),
            .init(pos: SIMD2(x0, y1), color: upper),
        ]
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard drawableSize != size else { return }
        drawableSize = size
        requestDraw()
    }
    func draw(in view: MTKView) {
        guard dirty else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        guard MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        rebuild()
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer = vertices.buffer, count >= 3,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        dirty = false
        RuntimeDiagnostics.shared.increment(.gaugeDraws)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        enc.endEncoding(); cmd.present(d); cmd.commit()
    }

    func detach(from view: MTKView) {
        if view.delegate === self { view.delegate = nil }
        self.view = nil
        dirty = false
        vertices.release()
        surfaceLifetime.detach()
    }

    private func requestDraw() {
        dirty = true
        guard let view, MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        view.setNeedsDisplay(view.bounds)
    }
}

struct MetalCoreBarsView: NSViewRepresentable {
    var cores: [Double]
    var surfaceDiagnostics: RuntimeDiagnostics? = nil
    func makeCoordinator() -> MetalCoreBarsRenderer { MetalCoreBarsRenderer(surfaceDiagnostics: surfaceDiagnostics) }
    func makeNSView(context: Context) -> MTKView {
        let v = GaugeMetalView()
        context.coordinator.attach(v)
        context.coordinator.set(cores: cores.map { Float($0) })
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.set(cores: cores.map { Float($0) })
    }
    static func dismantleNSView(_ nsView: MTKView, coordinator: MetalCoreBarsRenderer) {
        coordinator.detach(from: nsView)
    }
}

// MARK: - Tool load tile gauge (0–3 tiers as metal fill)

struct MetalToolLoadTile: View {
    var shortLabel: String
    var activity: Double // 0-100
    var health: String
    var loadTier: Int = 0

    var body: some View {
        VStack(spacing: 4) {
            Text(shortLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cyan)
            MetalBarGauge(fraction: min(max(activity / 100, Double(loadTier) / 3.0), 1), tint: healthColor)
                .frame(height: 6)
                .clipShape(Capsule())
            // Load tier as 3 micro Metal bars
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    MetalBarGauge(fraction: loadTier > i ? 1 : 0, tint: healthColor)
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
    }

    private var healthColor: Color {
        TelemetryHealth.tone(for: health).color
    }
}

/// Header status pill with Metal activity bar underneath.
/// Fixed geometry so the upper-right cluster stays toolbar-scale, not MTKView-scale.
struct MetalStatusPill: View {
    var text: String
    var tone: TelemetryStatusTone
    var fraction: Double = 1

    /// Compact chip: fits four across a typical detail header without colliding with the title.
    private let width: CGFloat = 104
    private let barHeight: CGFloat = 3
    private var tint: Color { tone.color }

    var body: some View {
        VStack(spacing: 3) {
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(2)
                .help(text)
                .frame(maxWidth: .infinity)
            MetalBarGauge(fraction: max(fraction, 0.05), tint: tint)
                .frame(width: width - 16, height: barHeight)
                .clipShape(Capsule())
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: width, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .stroke(tint.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(tone.rawValue)
    }
}
