// MetalLoadChart.swift
// What: Adapts the single-series load renderer to SwiftUI.
// How: NSViewRepresentable creates an MTKView, assigns its coordinator, and
// forwards new sample arrays without rebuilding the native view.
// Why: The adapter isolates AppKit/Metal lifecycle details from dashboard composition.

import SwiftUI
import MetalKit
import ForgeConductorCore

/// SwiftUI wrapper around an MTKView that draws the load history with Metal.
struct MetalLoadChart: NSViewRepresentable {
    var samples: [Float]
    var surfaceDiagnostics: RuntimeDiagnostics? = nil

    func makeCoordinator() -> LoadTraceRenderer {
        LoadTraceRenderer(surfaceDiagnostics: surfaceDiagnostics)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = GaugeMetalView()
        context.coordinator.attach(to: view)
        context.coordinator.update(samples: samples)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(samples: samples)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: LoadTraceRenderer) {
        coordinator.detach(from: nsView)
    }
}
