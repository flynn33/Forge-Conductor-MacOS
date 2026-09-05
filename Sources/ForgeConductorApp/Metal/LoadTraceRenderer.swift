// LoadTraceRenderer.swift
// What: Draws the historical load trace into an MTKView.
// How: The delegate converts normalized samples into GPU vertex buffers and
// encodes Metal draw calls whenever SwiftUI supplies updated history.
// Why: GPU rendering keeps a rapidly refreshing chart off the main UI drawing path.

import Foundation
import MetalKit
import ForgeConductorCore
import simd

/// Metal renderer for CPU load history (glowing cyan line + fill).
@MainActor
final class LoadTraceRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let vertices = MetalVertexBuffer<GaugeVertex>()
    private let surfaceLifetime = GaugeSurfaceLifetime()
    private weak var view: MTKView?
    private var dirty = false
    private var sampleCount = 0
    private var samples: [Float] = []

    func attach(to view: MTKView) {
        let resources = MetalGaugeResources.shared
        guard let device = resources.device,
              let pipeline = resources.configure(
                  view,
                  clearColor: MTLClearColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 1)
              )
        else { return }
        self.device = device
        self.queue = resources.commandQueue
        self.pipeline = pipeline
        self.view = view
        view.delegate = self
        surfaceLifetime.attach()
    }

    func update(samples: [Float]) {
        guard self.samples != samples else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        self.samples = samples
        requestDraw()
    }

    private func rebuildVertices() {
        guard let device else { return }
        let src = samples
        let n = max(src.count, 2)
        // Triangle strip fill under the curve + line on top: store fill verts then line verts.
        // Layout: for each sample i, position xy in NDC-ish [-1,1], color as attribute.
        var verts: [GaugeVertex] = []
        verts.reserveCapacity(n * 2 + n)

        let cyan = SIMD4<Float>(0.09, 0.94, 1.0, 0.55)
        let cyanLine = SIMD4<Float>(0.2, 0.96, 1.0, 1.0)
        let base = SIMD4<Float>(0.05, 0.2, 0.3, 0.0)

        func x(_ i: Int) -> Float {
            guard n > 1 else { return 0 }
            return -1 + 2 * Float(i) / Float(n - 1)
        }
        func y(_ v: Float) -> Float {
            let t = min(max(v / 100.0, 0), 1)
            return -0.85 + 1.7 * t
        }

        // Fill strip
        for i in 0..<n {
            let val = i < src.count ? src[i] : 0
            verts.append(GaugeVertex(pos: SIMD2(x(i), -0.85), color: base))
            verts.append(GaugeVertex(pos: SIMD2(x(i), y(val)), color: cyan))
        }
        let fillCount = verts.count

        // Line
        for i in 0..<n {
            let val = i < src.count ? src[i] : 0
            verts.append(GaugeVertex(pos: SIMD2(x(i), y(val)), color: cyanLine))
        }

        vertices.upload(verts, device: device)
        sampleCount = fillCount // first draw fill; line uses rest
        // Store line offset in high bits via sampleCount encoding: fillCount | (lineCount << 16) — simpler: store both
        self.fillVertexCount = fillCount
        self.lineVertexCount = n
    }

    private var fillVertexCount = 0
    private var lineVertexCount = 0

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let pipeline,
              let queue,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: rpd),
              let vertexBuffer = vertices.buffer else { return }
        dirty = false
        RuntimeDiagnostics.shared.increment(.gaugeDraws)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let fill = fillVertexCount
        let line = lineVertexCount

        if fill >= 2 {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: fill)
        }
        if line >= 2 {
            encoder.drawPrimitives(type: .lineStrip, vertexStart: fill, vertexCount: line)
        }
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
