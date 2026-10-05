import Foundation
import MetalKit
import ForgeConductorCore
// MultiSeriesLoadRenderer.swift
// What: Renders synchronized CPU, RAM, and GPU histories in one Metal chart.
// How: It normalizes series into a common viewport, uploads per-series vertices,
// and issues distinct colored line passes through an MTKView delegate.
// Why: One renderer guarantees aligned time axes and predictable high-frequency cost.

import SwiftUI
import simd

/// Metal multi-series load trace: CPU / RAM / GPU (parity with old LOAD TRACE + richer).
@MainActor
public final class MultiSeriesLoadRenderer: NSObject, MTKViewDelegate {
    public struct Series: Sendable {
        public var values: [Float?]
        public var color: SIMD4<Float>
        public init(values: [Float?], color: SIMD4<Float>) {
            self.values = values
            self.color = color
        }
    }

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let vertices = MetalVertexBuffer<GaugeVertex>()
    private let surfaceLifetime: GaugeSurfaceLifetime
    private weak var view: MTKView?
    private var dirty = false
    private var series: [Series] = []
    private var currentCPU: [Float?] = []
    private var currentRAM: [Float?] = []
    private var currentGPU: [Float?] = []
    private var drawableSize = CGSize.zero

    public override convenience init() { self.init(surfaceDiagnostics: nil) }

    init(surfaceDiagnostics: RuntimeDiagnostics?) {
        surfaceLifetime = GaugeSurfaceLifetime(scope: surfaceDiagnostics)
        super.init()
    }

    public func attach(to view: MTKView) {
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

    public func update(cpu: [Float], ram: [Float], gpu: [Float?]) {
        let nextCPU = GraphiteTraceGeometry.normalizedSamples(cpu.map(Optional.some))
        let nextRAM = GraphiteTraceGeometry.normalizedSamples(ram.map(Optional.some))
        let nextGPU = GraphiteTraceGeometry.normalizedSamples(gpu)
        guard currentCPU != nextCPU || currentRAM != nextRAM || currentGPU != nextGPU else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        currentCPU = nextCPU
        currentRAM = nextRAM
        currentGPU = nextGPU
        series = [
            Series(values: nextCPU, color: GraphitePalette.metalCPU),
            Series(values: nextRAM, color: GraphitePalette.metalRAM),
            Series(values: nextGPU, color: GraphitePalette.metalGPU),
        ]
        requestDraw()
    }

    private func rebuild() {
        guard let device, let view else { return }
        let viewport = view.bounds.size
        let parts = series.enumerated().map { index, series in
            GraphiteTraceGeometry.parts(samples: series.values, color: series.color,
                                        viewport: viewport, fillAlpha: index == 0 ? 0.20 : 0.08)
        }
        var values = GraphiteTraceGeometry.material(viewport: viewport)
        values.append(contentsOf: GraphiteTraceGeometry.grid(viewport: viewport))
        // Fill every series before its luminous stroke so later fills cannot mute earlier lines.
        for part in parts { values.append(contentsOf: part.fill) }
        for part in parts { values.append(contentsOf: part.halo) }
        for part in parts { values.append(contentsOf: part.core) }
        vertices.upload(values, device: device)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard drawableSize != size else { return }
        drawableSize = size
        requestDraw()
    }

    public func draw(in view: MTKView) {
        guard dirty else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        guard MetalGaugeResources.canRender(view) else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedHidden)
            return
        }
        rebuild()
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

        if vertices.count >= 3 {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    public func detach(from view: MTKView) {
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

/// SwiftUI wrapper for multi-series Metal chart.
struct MultiSeriesLoadChart: NSViewRepresentable {
    var cpu: [Float]
    var ram: [Float]
    var gpu: [Float?]
    var surfaceDiagnostics: RuntimeDiagnostics? = nil

    func makeCoordinator() -> MultiSeriesLoadRenderer { MultiSeriesLoadRenderer(surfaceDiagnostics: surfaceDiagnostics) }

    func makeNSView(context: Context) -> MTKView {
        let view = GaugeMetalView()
        context.coordinator.attach(to: view)
        context.coordinator.update(cpu: cpu, ram: ram, gpu: gpu)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(cpu: cpu, ram: ram, gpu: gpu)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: MultiSeriesLoadRenderer) {
        coordinator.detach(from: nsView)
    }
}
