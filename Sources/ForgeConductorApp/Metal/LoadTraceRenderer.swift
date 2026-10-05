// LoadTraceRenderer.swift
// Demand-drawn native traces share the existing Metal resources and bounded history.

import Foundation
import MetalKit
import ForgeConductorCore
import simd

/// Point-space geometry keeps instrument strokes readable at every backing scale.
enum GraphiteTraceGeometry {
    static let maximumSamples = 300
    static let coreWidth: Float = 1.35
    static let haloWidth: Float = 4

    struct Parts {
        var fill: [GaugeVertex] = []
        var halo: [GaugeVertex] = []
        var core: [GaugeVertex] = []
        var meter: [GaugeVertex] = []

        var vertexCount: Int { fill.count + halo.count + core.count + meter.count }
    }

    static func normalizedSamples(_ samples: [Float?]) -> [Float?] {
        samples.suffix(maximumSamples).map { value in
            guard let value, value.isFinite else { return nil }
            return value
        }
    }

    static func segments(
        samples: [Float?], maximumValue: Float = 100,
        bottom: Float = -0.85, top: Float = 0.85
    ) -> [[SIMD2<Float>]] {
        guard maximumValue.isFinite, maximumValue > 0,
              bottom.isFinite, top.isFinite, bottom < top else { return [] }
        let values = normalizedSamples(samples)
        guard !values.isEmpty else { return [] }
        var result: [[SIMD2<Float>]] = []
        var segment: [SIMD2<Float>] = []
        for (index, value) in values.enumerated() {
            guard let value else {
                if !segment.isEmpty { result.append(segment); segment.removeAll(keepingCapacity: true) }
                continue
            }
            let x = values.count == 1 ? Float(0) : -1 + 2 * Float(index) / Float(values.count - 1)
            let fraction = min(max(value / maximumValue, 0), 1)
            segment.append(SIMD2(x, bottom + (top - bottom) * fraction))
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }

    static func parts(
        samples: [Float?], color: SIMD4<Float>, maximumValue: Float = 100,
        viewport: CGSize, fraction: Double? = nil, fillAlpha: Float = 0.24
    ) -> Parts {
        guard valid(viewport) else { return Parts() }
        let height = Float(viewport.height)
        let measuredFraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        let bottom = measuredFraction == nil ? Float(-0.85) : -1 + 2 * min(6, height * 0.5) / height
        let segments = segments(samples: samples, maximumValue: maximumValue, bottom: bottom)
        var result = Parts()
        let pointCount = segments.reduce(0) { $0 + $1.count }
        result.fill.reserveCapacity(pointCount * 6)
        result.halo.reserveCapacity(pointCount * 12)
        result.core.reserveCapacity(pointCount * 6)
        for segment in segments {
            if segment.count == 1, let point = segment.first {
                result.halo.append(contentsOf: dot(point, viewport: viewport, color: withAlpha(color, 0.10), width: haloWidth))
                result.core.append(contentsOf: dot(point, viewport: viewport, color: withAlpha(color, 1), width: coreWidth))
                continue
            }
            for index in 1..<segment.count {
                let a = segment[index - 1]
                let b = segment[index]
                let lowA = GaugeVertex(pos: SIMD2(a.x, bottom), color: withAlpha(color, 0))
                let lowB = GaugeVertex(pos: SIMD2(b.x, bottom), color: withAlpha(color, 0))
                let highA = GaugeVertex(pos: a, color: withAlpha(color, fillAlpha))
                let highB = GaugeVertex(pos: b, color: withAlpha(color, fillAlpha))
                result.fill.append(lowA)
                result.fill.append(highA)
                result.fill.append(lowB)
                result.fill.append(lowB)
                result.fill.append(highA)
                result.fill.append(highB)
                appendHalo(a, b, viewport: viewport, color: color, to: &result.halo)
                appendStroke(a, b, viewport: viewport, color: withAlpha(color, 1), width: coreWidth, to: &result.core)
            }
        }
        if let measuredFraction {
            let y0 = -1 + 2 * min(1.5, height * 0.15) / height
            let y1 = -1 + 2 * min(4, height * 0.3) / height
            result.meter = quad(-1, y0, 1, y1, bottom: GraphitePalette.rgba(0x101820), top: GraphitePalette.rgba(0x3A5060))
            let end = -1 + 2 * Float(measuredFraction)
            if end > -1 {
                result.meter.append(contentsOf: quad(-1, y0, end, y1, bottom: withAlpha(color, 0.65), top: withAlpha(color, 1)))
            }
        }
        return result
    }

    static func material(viewport: CGSize) -> [GaugeVertex] {
        guard valid(viewport) else { return [] }
        var vertices = quad(-1, -1, 1, 1, bottom: GraphitePalette.rgba(0x101820), top: GraphitePalette.rgba(0x17232C))
        let edge = 2 / Float(viewport.height)
        vertices.append(contentsOf: quad(-1, 1 - edge, 1, 1, bottom: GraphitePalette.rgba(0x3A5060, alpha: 0), top: GraphitePalette.rgba(0x3A5060, alpha: 0.30)))
        return vertices
    }

    static func grid(viewport: CGSize) -> [GaugeVertex] {
        guard valid(viewport) else { return [] }
        var vertices: [GaugeVertex] = []
        for fraction in [Float(0.25), 0.5, 0.75] {
            let y = -0.85 + 1.7 * fraction
            vertices.append(contentsOf: stroke(SIMD2(-1, y), SIMD2(1, y), viewport: viewport,
                                               color: GraphitePalette.rgba(0x40525E, alpha: 0.5), width: 0.5))
        }
        for index in 1..<6 {
            let x = -1 + 2 * Float(index) / 6
            vertices.append(contentsOf: stroke(SIMD2(x, -0.85), SIMD2(x, 0.85), viewport: viewport,
                                               color: GraphitePalette.rgba(0x40525E, alpha: 0.22), width: 0.5))
        }
        return vertices
    }

    static func stroke(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, viewport: CGSize,
        color: SIMD4<Float>, width: Float
    ) -> [GaugeVertex] {
        var vertices: [GaugeVertex] = []
        appendStroke(a, b, viewport: viewport, color: color, width: width, to: &vertices)
        return vertices
    }

    private static func appendStroke(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, viewport: CGSize,
        color: SIMD4<Float>, width: Float, to vertices: inout [GaugeVertex]
    ) {
        guard valid(viewport), width.isFinite, width > 0 else { return }
        let delta = b - a
        let inPoints = SIMD2(delta.x * Float(viewport.width) / 2, delta.y * Float(viewport.height) / 2)
        let length = simd_length(inPoints)
        guard length.isFinite, length > 0 else { return }
        let normal = SIMD2(-inPoints.y, inPoints.x) / length
        let offset = SIMD2(normal.x * width / Float(viewport.width), normal.y * width / Float(viewport.height))
        appendBand(a - offset, a + offset, b - offset, b + offset, outer: color, inner: color, to: &vertices)
    }

    private static func appendHalo(_ a: SIMD2<Float>, _ b: SIMD2<Float>, viewport: CGSize, color: SIMD4<Float>, to vertices: inout [GaugeVertex]) {
        let delta = b - a
        let inPoints = SIMD2(delta.x * Float(viewport.width) / 2, delta.y * Float(viewport.height) / 2)
        let length = simd_length(inPoints)
        guard length.isFinite, length > 0 else { return }
        let normal = SIMD2(-inPoints.y, inPoints.x) / length
        func offset(_ width: Float) -> SIMD2<Float> {
            SIMD2(normal.x * width / Float(viewport.width), normal.y * width / Float(viewport.height))
        }
        let outer = offset(haloWidth)
        let inner = offset(coreWidth)
        let faint = withAlpha(color, 0)
        let bright = withAlpha(color, 0.18)
        appendBand(a - outer, a - inner, b - outer, b - inner, outer: faint, inner: bright, to: &vertices)
        appendBand(a + outer, a + inner, b + outer, b + inner, outer: faint, inner: bright, to: &vertices)
    }

    private static func band(
        _ a0: SIMD2<Float>, _ a1: SIMD2<Float>, _ b0: SIMD2<Float>, _ b1: SIMD2<Float>,
        outer: SIMD4<Float>, inner: SIMD4<Float>
    ) -> [GaugeVertex] {
        var vertices: [GaugeVertex] = []
        appendBand(a0, a1, b0, b1, outer: outer, inner: inner, to: &vertices)
        return vertices
    }

    private static func appendBand(
        _ a0: SIMD2<Float>, _ a1: SIMD2<Float>, _ b0: SIMD2<Float>, _ b1: SIMD2<Float>,
        outer: SIMD4<Float>, inner: SIMD4<Float>, to vertices: inout [GaugeVertex]
    ) {
        let a0 = GaugeVertex(pos: a0, color: outer)
        let a1 = GaugeVertex(pos: a1, color: inner)
        let b0 = GaugeVertex(pos: b0, color: outer)
        let b1 = GaugeVertex(pos: b1, color: inner)
        vertices.append(a0)
        vertices.append(a1)
        vertices.append(b0)
        vertices.append(b0)
        vertices.append(a1)
        vertices.append(b1)
    }

    private static func dot(_ point: SIMD2<Float>, viewport: CGSize, color: SIMD4<Float>, width: Float) -> [GaugeVertex] {
        let x = width / Float(viewport.width)
        let y = width / Float(viewport.height)
        return quad(point.x - x, point.y - y, point.x + x, point.y + y, bottom: color, top: color)
    }

    private static func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, bottom: SIMD4<Float>, top: SIMD4<Float>) -> [GaugeVertex] {
        band(SIMD2(x0, y0), SIMD2(x0, y1), SIMD2(x1, y0), SIMD2(x1, y1), outer: bottom, inner: top)
    }

    private static func withAlpha(_ color: SIMD4<Float>, _ alpha: Float) -> SIMD4<Float> {
        SIMD4(color.x, color.y, color.z, min(max(alpha, 0), 1))
    }

    private static func valid(_ viewport: CGSize) -> Bool {
        viewport.width >= 1 && viewport.height >= 1
            && Float(viewport.width).isFinite && Float(viewport.height).isFinite
    }
}

@MainActor
final class LoadTraceRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let vertices = MetalVertexBuffer<GaugeVertex>()
    private let surfaceLifetime: GaugeSurfaceLifetime
    private weak var view: MTKView?
    private var dirty = false
    private var samples: [Float?] = []
    private var color = GraphitePalette.metalCPU
    private var maximumValue: Float = 100
    private var fraction: Double?
    private var drawableSize = CGSize.zero

    override convenience init() { self.init(surfaceDiagnostics: nil) }

    init(surfaceDiagnostics: RuntimeDiagnostics?) {
        surfaceLifetime = GaugeSurfaceLifetime(scope: surfaceDiagnostics)
        super.init()
    }

    func attach(to view: MTKView) {
        let resources = MetalGaugeResources.shared
        guard let device = resources.device,
              let pipeline = resources.configure(view, clearColor: GraphitePalette.metalClear) else { return }
        self.device = device
        self.queue = resources.commandQueue
        self.pipeline = pipeline
        self.view = view
        drawableSize = view.drawableSize
        view.delegate = self
        surfaceLifetime.attach()
        requestDraw()
    }

    func update(samples: [Float]) {
        update(optionalSamples: samples.map(Optional.some))
    }

    func update(
        optionalSamples: [Float?], color: SIMD4<Float> = GraphitePalette.metalCPU,
        maximumValue: Float = 100, fraction: Double? = nil
    ) {
        let next = GraphiteTraceGeometry.normalizedSamples(optionalSamples)
        let maximum = maximumValue.isFinite && maximumValue > 0 ? maximumValue : 0
        let fraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        guard samples != next || self.color != color || self.maximumValue != maximum || self.fraction != fraction else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        samples = next
        self.color = color
        self.maximumValue = maximum
        self.fraction = fraction
        requestDraw()
    }

    private func rebuildVertices() {
        guard let device, let view else { return }
        let viewport = view.bounds.size
        let parts = GraphiteTraceGeometry.parts(samples: samples, color: color, maximumValue: maximumValue,
                                               viewport: viewport, fraction: fraction)
        vertices.upload(GraphiteTraceGeometry.material(viewport: viewport) + parts.fill + parts.halo + parts.core + parts.meter, device: device)
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
        rebuildVertices()
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let pipeline, let queue, let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: rpd),
              let vertexBuffer = vertices.buffer, vertices.count >= 3 else { return }
        dirty = false
        RuntimeDiagnostics.shared.increment(.gaugeDraws)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
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
