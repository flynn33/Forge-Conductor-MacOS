// MetalLoadChart.swift
// One native Metal surface presents a trace and its optional current fraction.

import SwiftUI
import MetalKit
import ForgeConductorCore

struct MetalLoadChart: NSViewRepresentable {
    var optionalSamples: [Float?]
    var tint: Color
    var maximumValue: Float
    var fraction: Double?
    var surfaceDiagnostics: RuntimeDiagnostics?

    init(samples: [Float], surfaceDiagnostics: RuntimeDiagnostics? = nil) {
        self.init(optionalSamples: samples.map(Optional.some), surfaceDiagnostics: surfaceDiagnostics)
    }

    init(
        optionalSamples: [Float?], tint: Color = GraphitePalette.chartCPU,
        maximumValue: Float = 100, fraction: Double? = nil,
        surfaceDiagnostics: RuntimeDiagnostics? = nil
    ) {
        self.optionalSamples = optionalSamples
        self.tint = tint
        self.maximumValue = maximumValue
        self.fraction = fraction
        self.surfaceDiagnostics = surfaceDiagnostics
    }

    func makeCoordinator() -> LoadTraceRenderer {
        LoadTraceRenderer(surfaceDiagnostics: surfaceDiagnostics)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = GaugeMetalView()
        context.coordinator.attach(to: view)
        update(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ renderer: LoadTraceRenderer) {
        renderer.update(optionalSamples: optionalSamples, color: MetalGaugePalette.from(swiftUI: tint),
                        maximumValue: maximumValue, fraction: fraction)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: LoadTraceRenderer) {
        coordinator.detach(from: nsView)
    }
}
