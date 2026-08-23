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
    private let surfaceLifetime = GaugeSurfaceLifetime()
    private weak var view: MTKView?
    private var dirty = false
    private var series: [Series] = []
    private var currentCPU: [Float] = []
    private var currentRAM: [Float] = []
    private var currentGPU: [Float?] = []

    public func attach(to view: MTKView) {
        let resources = MetalGaugeResources.shared
        guard let device = resources.device,
              let pipeline = resources.configure(
                  view,
                  clearColor: MTLClearColor(red: 0.01, green: 0.015, blue: 0.04, alpha: 1)
              )
        else { return }
        self.device = device
        self.queue = resources.commandQueue
        self.pipeline = pipeline
        self.view = view
        view.delegate = self
        surfaceLifetime.attach()
    }

    public func update(cpu: [Float], ram: [Float], gpu: [Float?]) {
        guard currentCPU != cpu || currentRAM != ram || currentGPU != gpu else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
        currentCPU = cpu
        currentRAM = ram
        currentGPU = gpu
        series = [
            Series(values: cpu.map(Optional.some), color: SIMD4(0.09, 0.94, 1.0, 1.0)),
            Series(values: ram.map(Optional.some), color: SIMD4(1.0, 0.42, 0.12, 0.95)),
            Series(values: gpu, color: SIMD4(0.18, 1.0, 0.55, 0.95)),
        ]
        rebuild()
        requestDraw()
    }

    private func rebuild() {
        guard let device else { return }
        let seriesCopy = series

        var verts: [GaugeVertex] = []
        // Grid lines (horizontal at 25/50/75).
        let gridColor = SIMD4<Float>(0.1, 0.35, 0.45, 0.35)
        var gridCount = 0
        for g in [Float(0.25), Float(0.5), Float(0.75)] {
            let y = Float(-0.85) + Float(1.7) * g
            verts.append(GaugeVertex(pos: SIMD2(Float(-1), y), color: gridColor))
            verts.append(GaugeVertex(pos: SIMD2(Float(1), y), color: gridColor))
            gridCount += 2
        }
        let fillStart = verts.count
        var fillCount = 0
        if let cpu = seriesCopy.first {
            let n = max(cpu.values.count, 2)
            let fill = SIMD4<Float>(0.09, 0.94, 1.0, 0.22)
            for i in 0..<n {
                let x = -1 + 2 * Float(i) / Float(n - 1)
                let sample = i < cpu.values.count ? cpu.values[i] : nil
                let v = min(max((sample ?? 0) / 100, 0), 1)
                let y = -0.85 + 1.7 * v
                verts.append(GaugeVertex(pos: SIMD2(x, -0.85), color: SIMD4<Float>(0.05, 0.2, 0.3, 0)))
                verts.append(GaugeVertex(pos: SIMD2(x, y), color: fill))
                fillCount += 2
            }
        }
        var lineRanges: [(Int, Int)] = []
        for s in seriesCopy {
            let n = max(s.values.count, 2)
            var segmentStart: Int?
            var segmentCount = 0

            func finishSegment() {
                if let segmentStart, segmentCount >= 2 {
                    lineRanges.append((segmentStart, segmentCount))
                }
            }

            for i in 0..<n {
                let sample = i < s.values.count ? s.values[i] : nil
                guard let sample, sample.isFinite else {
                    finishSegment()
                    segmentStart = nil
                    segmentCount = 0
                    continue
                }
                if segmentStart == nil {
                    segmentStart = verts.count
                }
                let x = -1 + 2 * Float(i) / Float(n - 1)
                let v = min(max(sample / 100, 0), 1)
                let y = -0.85 + 1.7 * v
                verts.append(GaugeVertex(pos: SIMD2(x, y), color: s.color))
                segmentCount += 1
            }
            finishSegment()
        }

        vertices.upload(verts, device: device)
        self.drawGrid = gridCount
        self.drawFillStart = fillStart
        self.drawFillCount = fillCount
        self.drawLines = lineRanges
    }

    private var drawGrid = 0
    private var drawFillStart = 0
    private var drawFillCount = 0
    private var drawLines: [(Int, Int)] = []

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard dirty else {
            RuntimeDiagnostics.shared.increment(.gaugeDrawsSkippedStatic)
            return
        }
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

        let grid = drawGrid
        let fillStart = drawFillStart
        let fillCount = drawFillCount
        let lines = drawLines

        if grid >= 2 {
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: grid)
        }
        if fillCount >= 2 {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: fillStart, vertexCount: fillCount)
        }
        for (start, count) in lines where count >= 2 {
            encoder.drawPrimitives(type: .lineStrip, vertexStart: start, vertexCount: count)
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
        guard let view, !view.isHidden else {
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

    func makeCoordinator() -> MultiSeriesLoadRenderer { MultiSeriesLoadRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
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
