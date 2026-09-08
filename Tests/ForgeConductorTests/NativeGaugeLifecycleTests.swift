#if !SWIFT_PACKAGE
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import Forge_Conductor
import ForgeConductorCore

/// App-hosted component evidence, using the production SwiftUI adapters,
/// coordinators, Metal pipeline, and numeric runtime observations. These tests
/// do not qualify whole-application CPU/GPU budgets or a hardware matrix.
/// Run serially in ForgeConductorAppTests with an available WindowServer.
@MainActor
final class NativeGaugeLifecycleTests: XCTestCase, @unchecked Sendable {
    private var fixture: NativeGaugeWindow?
    private var originalVisibleWindows: [NSWindow] = []

    nonisolated override func setUp() async throws {
        try await prepareApplicationHost()
    }

    private func prepareApplicationHost() async throws {
        continueAfterFailure = false
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            throw NativeGaugeTestFailure("Run NativeGaugeLifecycleTests in the native ForgeConductorAppTests application host.")
        }
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("No native display is available; gauge lifecycle runtime evidence is unexecuted.")
        }
        guard MetalGaugeResources.shared.device != nil else {
            throw XCTSkip("No Metal device is available; gauge lifecycle runtime evidence is unexecuted.")
        }
        guard MetalGaugeResources.shared.commandQueue != nil,
              MetalGaugeResources.shared.pipeline(pixelFormat: .bgra8Unorm) != nil else {
            throw NativeGaugeTestFailure("The real gauge Metal queue or pipeline could not initialize.")
        }

        retainObservation("host-before-isolation", before: nil)
        // SwiftUI owns the application delegate proxy. Isolate through the
        // public window lifecycle and leave the application's live telemetry
        // running. Global draw/resource counts must demonstrate quiescence;
        // an off-screen menu item's state is not a model observation.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        originalVisibleWindows = NSApp.windows.filter(\.isVisible)
        for window in originalVisibleWindows { window.orderOut(nil) }
        guard await waitForQuietDraws(timeout: 8, quietInterval: 1.25) else {
            retainObservation("host-draw-interference", before: nil)
            throw NativeGaugeTestFailure("The application host continues drawing while its windows are ordered out. Run this class alone and inspect the retained counters; component evidence cannot be isolated.")
        }
        retainObservation("host-after-isolation", before: nil)
    }

    nonisolated override func tearDown() async throws {
        await restoreApplicationHost()
    }

    private func restoreApplicationHost() async {
        fixture?.close()
        fixture = nil
        for window in originalVisibleWindows { window.orderFront(nil) }
        originalVisibleWindows.removeAll()
    }

    func testProductionGaugesDrawOnDemandAndReuseSharedResources() async throws {
        let baseline = RuntimeDiagnostics.shared.snapshot()
        let fixture = try await mountGauges()
        let views = try requireProductionSurfaces(in: fixture)
        try requireActualFrames(from: views, step: 1)
        await assertQuietDraws(timeout: 3, quietInterval: 0.25)
        let warmed = RuntimeDiagnostics.shared.snapshot()

        // No telemetry or animation clock is injected into these fixed values.
        // Actual GPU submission counts must remain unchanged over native turns.
        await allowNativeEvents(for: 0.75)
        XCTAssertEqual(counter(.gaugeDraws), count(.gaugeDraws, in: warmed))
        XCTAssertEqual(counter(.gaugeBuffersCreated), count(.gaugeBuffersCreated, in: warmed))

        for step in 2...13 {
            try requireActualFrames(from: views, step: step)
        }
        XCTAssertEqual(counter(.gaugeBuffersCreated), count(.gaugeBuffersCreated, in: warmed), "Fixed-size value updates must reuse warmed Metal buffers")
        XCTAssertEqual(counter(.gaugeCommandQueuesCreated), count(.gaugeCommandQueuesCreated, in: baseline))
        XCTAssertEqual(counter(.gaugePipelinesCreated), count(.gaugePipelinesCreated, in: baseline))
        for view in views {
            XCTAssertTrue(view.isPaused, "Every production gauge must use paused demand rendering")
            XCTAssertTrue(view.enableSetNeedsDisplay)
            XCTAssertTrue(view.device === MetalGaugeResources.shared.device)
        }
        retainObservation("visible-static-and-changing-values", before: baseline)
    }

    func testHiddenAndOrderedOutProductionGaugesStopDrawingAndResumeWhenVisible() async throws {
        let fixture = try await mountGauges()
        let views = try requireProductionSurfaces(in: fixture)
        try requireActualFrames(from: views, step: 1)
        await assertQuietDraws(timeout: 3, quietInterval: 0.25)

        for view in views { view.isHidden = true }
        await allowNativeEvents(for: 0.25)
        let hiddenBaseline = RuntimeDiagnostics.shared.snapshot()
        for step in 2...13 {
            // Dispatch through the real coordinator methods so a deferred
            // SwiftUI body update cannot make hidden quiescence pass vacuously.
            for view in views {
                try updateProductionRenderer(view, step: step)
                view.draw()
            }
            await allowNativeEvents(for: 0.04)
        }
        await allowNativeEvents(for: 0.35)
        XCTAssertEqual(counter(.gaugeDraws), count(.gaugeDraws, in: hiddenBaseline))
        XCTAssertEqual(counter(.gaugeBuffersCreated), count(.gaugeBuffersCreated, in: hiddenBaseline))
        XCTAssertGreaterThanOrEqual(
            counter(.gaugeDrawsSkippedHidden) - count(.gaugeDrawsSkippedHidden, in: hiddenBaseline),
            UInt64(views.count * 12)
        )
        retainObservation("hidden-value-updates", before: hiddenBaseline)

        let beforeUnhide = counter(.gaugeDraws)
        for view in views { view.isHidden = false }
        let resumedAfterUnhide = await waitUntil(timeout: 5) { self.counter(.gaugeDraws) >= beforeUnhide + 5 }
        XCTAssertTrue(resumedAfterUnhide, "Unhiding must present the retained latest values without a test-forced draw")
        try requireActualFrames(from: views, step: 14)
        await assertQuietDraws(timeout: 3, quietInterval: 0.25)
        fixture.window.orderOut(nil)
        XCTAssertFalse(fixture.window.isVisible)
        await allowNativeEvents(for: 0.25)
        let orderedOutBaseline = RuntimeDiagnostics.shared.snapshot()
        for step in 15...26 {
            for view in views {
                try updateProductionRenderer(view, step: step)
                view.draw()
            }
            await allowNativeEvents(for: 0.04)
        }
        await allowNativeEvents(for: 0.35)
        XCTAssertEqual(counter(.gaugeDraws), count(.gaugeDraws, in: orderedOutBaseline))
        XCTAssertEqual(counter(.gaugeBuffersCreated), count(.gaugeBuffersCreated, in: orderedOutBaseline))
        retainObservation("ordered-out-value-updates", before: orderedOutBaseline)

        let beforeReorder = counter(.gaugeDraws)
        await presentFixtureWindow(fixture, stage: "ordered-front")
        XCTAssertTrue(fixture.window.isVisible)
        let exposedAfterReorder = await waitUntil(timeout: 5) {
            fixture.window.occlusionState.contains(.visible)
        }
        if !exposedAfterReorder {
            retainObservation("ordered-front-exposure-failure", before: orderedOutBaseline)
        }
        XCTAssertTrue(exposedAfterReorder, "The native fixture must have exposed pixels before qualifying visible redraw behavior")
        let resumedAfterReorder = await waitUntil(timeout: 5) { self.counter(.gaugeDraws) >= beforeReorder + 5 }
        retainObservation("ordered-front-resume-result", before: orderedOutBaseline, transition: [
            "exposed": exposedAfterReorder,
            "resumed": resumedAfterReorder,
            "draws_before_order_front": beforeReorder,
            "draws_after_wait": counter(.gaugeDraws),
        ])
        XCTAssertTrue(resumedAfterReorder, "Ordering the window front must present retained values without a test-forced draw")
        try requireActualFrames(from: views, step: 27)

        fixture.hostingView.isHidden = true
        await allowNativeEvents(for: 0.25)
        let ancestorHidden = RuntimeDiagnostics.shared.snapshot()
        for view in views {
            XCTAssertFalse(view.isHidden)
            XCTAssertTrue(view.isHiddenOrHasHiddenAncestor)
            try updateProductionRenderer(view, step: 28)
            view.draw()
        }
        await allowNativeEvents(for: 0.35)
        XCTAssertEqual(counter(.gaugeDraws), count(.gaugeDraws, in: ancestorHidden))
        XCTAssertEqual(counter(.gaugeBuffersCreated), count(.gaugeBuffersCreated, in: ancestorHidden))
        let beforeAncestorUnhide = counter(.gaugeDraws)
        fixture.hostingView.isHidden = false
        let resumedAfterAncestorUnhide = await waitUntil(timeout: 5) {
            self.counter(.gaugeDraws) >= beforeAncestorUnhide + 5
        }
        XCTAssertTrue(resumedAfterAncestorUnhide, "Revealing a hidden ancestor must present retained values")
        retainObservation("ancestor-hidden-value-updates-and-resume", before: ancestorHidden)
    }

    func testSwiftUIDismantleReleasesProductionSurfacesAndCoordinatorsAcrossCycles() async throws {
        let baseline = RuntimeDiagnostics.shared.snapshot()
        let requestedCycles = ProcessInfo.processInfo.environment["FORGE_GAUGE_LIFECYCLE_CYCLES"] ?? "5"
        guard let cycles = Int(requestedCycles), [5, 100].contains(cycles) else {
            throw NativeGaugeTestFailure("FORGE_GAUGE_LIFECYCLE_CYCLES must be 5 for the fast native test or 100 for the scene-cycle qualification.")
        }
        for cycle in 0..<cycles {
            let fixture = try await mountGauges()
            var views = try requireProductionSurfaces(in: fixture)
            try requireActualFrames(from: views, step: cycle + 1)
            let weakViews = views.map { NativeGaugeWeakReference($0) }
            let weakCoordinators = views.map { NativeGaugeWeakReference($0.delegate as AnyObject?) }
            XCTAssertEqual(level(.gaugeActiveSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 5)
            XCTAssertEqual(level(.gaugeVisibleSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 5)
            retainObservation("mounted-cycle-\(cycle)", before: nil)

            // A separate production surface deliberately changes the shared
            // count. It has no window, so attachment cannot submit a frame.
            // The five fixture surfaces remain owned entirely by SwiftUI.
            let hostSurface = GaugeMetalView()
            let hostRenderer = MetalBarRenderer()
            let beforeHostAttachment = RuntimeDiagnostics.shared.snapshot()
            hostRenderer.attach(hostSurface)
            defer { hostRenderer.detach(from: hostSurface) }
            XCTAssertTrue(hostSurface.delegate === hostRenderer)
            XCTAssertEqual(gauge(.gaugeActiveSurfaces), level(.gaugeActiveSurfaces, in: beforeHostAttachment) + 1)
            XCTAssertEqual(gauge(.gaugeVisibleSurfaces), level(.gaugeVisibleSurfaces, in: beforeHostAttachment) + 1)
            XCTAssertEqual(level(.gaugeActiveSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 5)
            XCTAssertEqual(level(.gaugeVisibleSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 5)

            fixture.removeGauges()
            let detachedFromSwiftUI = await waitUntil(timeout: 5) {
                views.allSatisfy { $0.delegate == nil }
                    && self.level(.gaugeActiveSurfaces, in: fixture.surfaceDiagnostics.snapshot()) == 0
                    && self.level(.gaugeVisibleSurfaces, in: fixture.surfaceDiagnostics.snapshot()) == 0
            }
            XCTAssertTrue(detachedFromSwiftUI, "SwiftUI dismantling must detach the production delegates and release surface accounting")
            views.removeAll()
            let releasedBySwiftUI = await waitUntil(timeout: 5) {
                weakViews.allSatisfy { $0.value == nil }
                    && weakCoordinators.allSatisfy { $0.value == nil }
            }
            XCTAssertTrue(releasedBySwiftUI, "Native view/coordinator references survived the SwiftUI removal boundary")

            let detached = RuntimeDiagnostics.shared.snapshot()
            // No event turn separates these shared snapshots. This exact
            // decrement is unrelated to the released fixture's exact zero.
            hostRenderer.detach(from: hostSurface)
            XCTAssertNil(hostSurface.delegate)
            XCTAssertEqual(gauge(.gaugeActiveSurfaces), level(.gaugeActiveSurfaces, in: detached) - 1)
            XCTAssertEqual(gauge(.gaugeVisibleSurfaces), level(.gaugeVisibleSurfaces, in: detached) - 1)
            XCTAssertEqual(level(.gaugeActiveSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 0)
            XCTAssertEqual(level(.gaugeVisibleSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 0)
            retainObservation("unrelated-host-detach-cycle-\(cycle)", before: detached)
            // Native event turns continue while the hosting window still exists.
            // No direct call is made to a dismantled coordinator.
            await allowNativeEvents(for: 0.5)
            XCTAssertEqual(counter(.gaugeDraws), count(.gaugeDraws, in: detached))
            XCTAssertEqual(counter(.gaugeBuffersCreated), count(.gaugeBuffersCreated, in: detached))
            XCTAssertEqual(level(.gaugeActiveSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 0)
            XCTAssertEqual(level(.gaugeVisibleSurfaces, in: fixture.surfaceDiagnostics.snapshot()), 0)
            retainObservation("dismantled-cycle-\(cycle)", before: detached)
            fixture.close()
            self.fixture = nil
        }
        XCTAssertEqual(counter(.gaugeCommandQueuesCreated), count(.gaugeCommandQueuesCreated, in: baseline))
        XCTAssertEqual(counter(.gaugePipelinesCreated), count(.gaugePipelinesCreated, in: baseline))
    }

    func testProductionVertexBufferReusesCapacityAndReleasesItsMetalObject() async throws {
        let device = try XCTUnwrap(MetalGaugeResources.shared.device)
        let vertices = MetalVertexBuffer<GaugeVertex>()
        let initial = (0..<32).map { index in
            GaugeVertex(pos: SIMD2(Float(index), 0), color: SIMD4(0, 1, 1, 1))
        }
        vertices.upload(initial, device: device)
        let firstBuffer = try XCTUnwrap(vertices.buffer)
        let capacity = vertices.capacityBytes
        let creationCount = counter(.gaugeBuffersCreated)
        XCTAssertGreaterThanOrEqual(capacity, initial.count * MemoryLayout<GaugeVertex>.stride)
        for value in 1...100 {
            let changed = initial.map {
                GaugeVertex(pos: SIMD2($0.pos.x, Float(value)), color: $0.color)
            }
            vertices.upload(changed, device: device)
            XCTAssertTrue(vertices.buffer === firstBuffer)
            XCTAssertEqual(vertices.capacityBytes, capacity)
        }
        XCTAssertEqual(counter(.gaugeBuffersCreated), creationCount)
        let uploaded = firstBuffer.contents().bindMemory(to: GaugeVertex.self, capacity: initial.count)
        for index in initial.indices {
            XCTAssertEqual(uploaded[index].pos, SIMD2(Float(index), 100))
            XCTAssertEqual(uploaded[index].color, initial[index].color)
        }
        vertices.release()
        XCTAssertNil(vertices.buffer)
        XCTAssertEqual(vertices.count, 0)
        XCTAssertEqual(vertices.capacityBytes, 0)

        // Use a second buffer with no test-held strong reference to observe the
        // actual Metal object's ARC lifetime, independently of GPU allocator caches.
        let releasedObject: NativeGaugeWeakReference = autoreleasepool {
            vertices.upload(initial, device: device)
            return NativeGaugeWeakReference(vertices.buffer as AnyObject?)
        }
        XCTAssertNotNil(releasedObject.value)
        vertices.release()
        let releasedMetalObject = await waitUntil(timeout: 3) { releasedObject.value == nil }
        XCTAssertTrue(releasedMetalObject)
        retainObservation("vertex-buffer-reuse-and-release", before: nil)
    }

    private func mountGauges() async throws -> NativeGaugeWindow {
        guard fixture == nil else { throw NativeGaugeTestFailure("Previous test window was not released.") }
        let beforePresentation = counter(.gaugeDraws)
        let surfaceDiagnostics = RuntimeDiagnostics()
        XCTAssertEqual(level(.gaugeActiveSurfaces, in: surfaceDiagnostics.snapshot()), 0)
        XCTAssertEqual(level(.gaugeVisibleSurfaces, in: surfaceDiagnostics.snapshot()), 0)
        let fixture = NativeGaugeWindow(surfaceDiagnostics: surfaceDiagnostics)
        self.fixture = fixture
        // Ordered-in windows can remain fully obscured by another application.
        // Establish real exposure before measuring automatic visible frames.
        await presentFixtureWindow(fixture, stage: "initial")
        XCTAssertTrue(fixture.window.isVisible)
        let exposed = await waitUntil(timeout: 5) {
            fixture.window.occlusionState.contains(.visible)
        }
        if !exposed { retainObservation("initial-exposure-failure", before: nil) }
        XCTAssertTrue(exposed, "The native fixture must have exposed pixels before qualifying initial rendering")
        let mounted = await waitUntil(timeout: 5) { fixture.metalViews.count == 5 }
        XCTAssertTrue(mounted)
        fixture.hostingView.layoutSubtreeIfNeeded()
        let firstFrames = await waitUntil(timeout: 5) {
            self.counter(.gaugeDraws) >= beforePresentation + 5
        }
        XCTAssertTrue(firstFrames, "Native attachment must present every initial dirty gauge without a test-forced draw")
        return fixture
    }

    private func presentFixtureWindow(_ fixture: NativeGaugeWindow, stage: String) async {
        // App activation is asynchronous and may be refused. Request it through
        // AppKit, then prove this exact fixture became key before checking its
        // exposure. Window ordering alone does not establish either condition.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.orderFrontRegardless()
        let activated = await waitUntil(timeout: 5) {
            NSApp.isActive && fixture.window.isKeyWindow
        }
        if !activated { retainObservation("\(stage)-activation-failure", before: nil) }
        XCTAssertTrue(activated, "The native application host and exact fixture window must become active before qualifying visible rendering")
    }

    private func requireProductionSurfaces(in fixture: NativeGaugeWindow) throws -> [MTKView] {
        let views = fixture.metalViews
        XCTAssertEqual(views.count, 5)
        XCTAssertEqual(views.filter { $0.delegate is MetalBarRenderer }.count, 1)
        XCTAssertEqual(views.filter { $0.delegate is MetalRingRenderer }.count, 1)
        XCTAssertEqual(views.filter { $0.delegate is MetalCoreBarsRenderer }.count, 1)
        XCTAssertEqual(views.filter { $0.delegate is LoadTraceRenderer }.count, 1)
        XCTAssertEqual(views.filter { $0.delegate is MultiSeriesLoadRenderer }.count, 1)
        for view in views {
            XCTAssertTrue(view.window === fixture.window)
            XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
            XCTAssertGreaterThan(view.bounds.width, 0)
            XCTAssertGreaterThan(view.bounds.height, 0)
            XCTAssertTrue(view.isPaused)
            XCTAssertTrue(view.enableSetNeedsDisplay)
        }
        return views
    }

    private func requireActualFrames(from views: [MTKView], step: Int) throws {
        for view in views {
            // No native run-loop turn occurs between the counter snapshots.
            // All production gauge delegates run on the main actor, so this
            // delta proves this surface actually encoded its real draw path.
            try updateProductionRenderer(view, step: step)
            let before = counter(.gaugeDraws)
            view.draw()
            XCTAssertEqual(counter(.gaugeDraws), before + 1, "A production gauge did not submit a frame; an empty/no-draw fixture is not quiescence evidence")
        }
    }

    private func updateProductionRenderer(_ view: MTKView, step: Int) throws {
        let fraction: Float = step.isMultiple(of: 2) ? 0.9 : 0.7
        let values = (0..<32).map { Float(($0 + step) % 95 + 1) }
        switch view.delegate {
        case let renderer as MetalBarRenderer:
            renderer.set(fraction: fraction, color: MetalGaugePalette.cyan)
        case let renderer as MetalRingRenderer:
            renderer.set(fraction: fraction, color: MetalGaugePalette.cyan)
        case let renderer as MetalCoreBarsRenderer:
            renderer.set(cores: Array(values.prefix(8)))
        case let renderer as LoadTraceRenderer:
            renderer.update(samples: values)
        case let renderer as MultiSeriesLoadRenderer:
            renderer.update(cpu: values, ram: values.reversed(), gpu: values.map(Optional.some))
        default:
            throw NativeGaugeTestFailure("The mounted MTKView has no known production gauge coordinator.")
        }
    }

    private func waitForQuietDraws(timeout: TimeInterval, quietInterval: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = counter(.gaugeDraws)
        var lastBuffers = counter(.gaugeBuffersCreated)
        var unchangedSince = Date()
        while Date() < deadline {
            await allowNativeEvents(for: 0.025)
            let current = counter(.gaugeDraws)
            let buffers = counter(.gaugeBuffersCreated)
            // Live hidden host views may be added or released without drawing.
            // Surface lifetime is asserted separately within the fixture scope.
            if current != lastCount || buffers != lastBuffers {
                lastCount = current
                lastBuffers = buffers
                unchangedSince = Date()
            }
            if Date().timeIntervalSince(unchangedSince) >= quietInterval { return true }
        }
        return false
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await allowNativeEvents(for: 0.025)
        }
        return condition()
    }

    private func allowNativeEvents(for duration: TimeInterval) async {
        // A nested RunLoop cannot release a currently executing main-actor job.
        // Suspending lets SwiftUI apply commands and dismantle its native views.
        try? await Task.sleep(for: .seconds(duration))
    }

    private func assertQuietDraws(timeout: TimeInterval, quietInterval: TimeInterval,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let quiet = await waitForQuietDraws(timeout: timeout, quietInterval: quietInterval)
        XCTAssertTrue(quiet, "Production draw and resource counts must settle", file: file, line: line)
    }

    private func counter(_ counter: RuntimeCounter) -> UInt64 {
        count(counter, in: RuntimeDiagnostics.shared.snapshot())
    }

    private func count(_ counter: RuntimeCounter, in snapshot: RuntimeDiagnosticSnapshot) -> UInt64 {
        snapshot.counters[counter.rawValue] ?? 0
    }

    private func gauge(_ gauge: RuntimeGauge) -> Int64 {
        level(gauge, in: RuntimeDiagnostics.shared.snapshot())
    }

    private func level(_ gauge: RuntimeGauge, in snapshot: RuntimeDiagnosticSnapshot) -> Int64 {
        snapshot.gauges[gauge.rawValue] ?? 0
    }

    private func retainObservation(_ name: String, before: RuntimeDiagnosticSnapshot?,
                                   transition: [String: Any] = [:]) {
        var report: [String: Any] = [
            "scope": "native-production-gauge-components",
            "application_delegate_type": NSApp.delegate.map { String(reflecting: type(of: $0)) } ?? "none",
            "application_active": NSApp.isActive,
            "application_hidden": NSApp.isHidden,
            "application_activation_policy": NSApp.activationPolicy().rawValue,
            "screens": NSScreen.screens.map {
                ["display_id": $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? NSNull(),
                 "frame": NSStringFromRect($0.frame)] as [String: Any]
            },
            "host_windows": NSApp.windows.map {
                ["identifier": $0.identifier?.rawValue ?? "", "visible": $0.isVisible] as [String: Any]
            },
            "after": RuntimeDiagnostics.shared.snapshot().asDictionary(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "metal_device": MetalGaugeResources.shared.device?.name ?? "unavailable",
        ]
        if let before { report["before"] = before.asDictionary() }
        if !transition.isEmpty { report["transition"] = transition }
        if let fixture {
            report["window_visible"] = fixture.window.isVisible
            report["window_state"] = fixture.windowObservation
            report["window_notifications"] = fixture.notificationObservation
            report["fixture_surface_accounting"] = fixture.surfaceDiagnostics.snapshot().asDictionary()
            report["surfaces"] = fixture.metalViews.map { view in
                ["paused": view.isPaused, "hidden": view.isHiddenOrHasHiddenAncestor,
                 "has_delegate": view.delegate != nil,
                 "delegate_type": view.delegate.map { String(reflecting: type(of: $0)) } ?? "none",
                 "delegate_dirty": view.delegate.flatMap { delegate in
                     // Inspect at most 32 direct stored fields. This diagnostic
                     // never acquires a drawable or asks the renderer to draw.
                     Mirror(reflecting: delegate).children.prefix(32)
                         .first(where: { $0.label == "dirty" })?.value as? Bool
                 } as Any? ?? NSNull(),
                 "bounds": NSStringFromRect(view.bounds),
                 "drawable_size": NSStringFromSize(view.drawableSize),
                 "needs_display": view.needsDisplay,
                 "layer_needs_display": view.layer.map { $0.needsDisplay() } as Any? ?? NSNull(),
                 "enable_set_needs_display": view.enableSetNeedsDisplay,
                 "has_device": view.device != nil,
                 "has_window": view.window != nil] as [String: Any]
            }
        }
        do {
            let attachment = XCTAttachment(
                data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
                uniformTypeIdentifier: "public.json"
            )
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch { XCTFail("Could not retain native gauge observations") }
    }
}

@MainActor
private struct NativeGaugeFixtureView: View {
    var showsGauges = true
    let surfaceDiagnostics: RuntimeDiagnostics
    var body: some View {
        VStack(spacing: 12) {
            if showsGauges {
                MetalBarGauge(fraction: 1, tint: .cyan, surfaceDiagnostics: surfaceDiagnostics)
                    .frame(width: 320, height: 24)
                MetalRingGauge(fraction: 1, tint: .cyan, surfaceDiagnostics: surfaceDiagnostics)
                    .frame(width: 100, height: 100)
                MetalCoreBarsView(cores: Array(repeating: 50, count: 8), surfaceDiagnostics: surfaceDiagnostics)
                    .frame(width: 320, height: 100)
                MetalLoadChart(samples: Array(repeating: 50, count: 32), surfaceDiagnostics: surfaceDiagnostics)
                    .frame(width: 320, height: 100)
                MultiSeriesLoadChart(
                    cpu: Array(repeating: 50, count: 32),
                    ram: Array(repeating: 40, count: 32),
                    gpu: Array(repeating: 30, count: 32),
                    surfaceDiagnostics: surfaceDiagnostics
                ).frame(width: 320, height: 100)
            }
        }
        .frame(width: 420, height: 560)
    }
}

@MainActor
private final class NativeGaugeWindow: NSObject {
    let window: NSWindow
    let hostingView: NSHostingView<NativeGaugeFixtureView>
    let surfaceDiagnostics: RuntimeDiagnostics
    private var notificationCounts: [String: Int] = [:]
    private var lastNotificationStates: [String: [String: Any]] = [:]

    init(surfaceDiagnostics: RuntimeDiagnostics) {
        self.surfaceDiagnostics = surfaceDiagnostics
        hostingView = NSHostingView(rootView: NativeGaugeFixtureView(surfaceDiagnostics: surfaceDiagnostics))
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 420, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()
        window.title = "Gauge lifecycle validation"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // One observer, four fixed keys, and one replaceable observation per
        // key. No event history, timer, or rendering work is introduced.
        for name in [NSWindow.didExposeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didUpdateNotification] {
            notificationCounts[name.rawValue] = 0
            NotificationCenter.default.addObserver(
                self, selector: #selector(observeWindowNotification(_:)), name: name, object: window
            )
        }
    }

    var windowObservation: [String: Any] {
        ["visible": window.isVisible,
         "miniaturized": window.isMiniaturized,
         "on_active_space": window.isOnActiveSpace,
         "key_window": window.isKeyWindow,
         "main_window": window.isMainWindow,
         "can_become_key": window.canBecomeKey,
         "frame": NSStringFromRect(window.frame),
         "level": window.level.rawValue,
         "collection_behavior": window.collectionBehavior.rawValue,
         "hides_on_deactivate": window.hidesOnDeactivate,
         "content_hidden": hostingView.isHiddenOrHasHiddenAncestor,
         "occlusion_state": window.occlusionState.rawValue,
         "has_screen": window.screen != nil,
         "screen_id": window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? NSNull()]
    }

    var notificationObservation: [String: Any] {
        ["counts": notificationCounts, "last_states": lastNotificationStates]
    }

    @objc private func observeWindowNotification(_ notification: Notification) {
        let key = notification.name.rawValue
        guard let count = notificationCounts[key] else { return }
        notificationCounts[key] = count == Int.max ? Int.max : count + 1
        var state = windowObservation
        state["observed_at"] = Date().timeIntervalSince1970
        state["gauge_draws"] = RuntimeDiagnostics.shared.snapshot().counters[RuntimeCounter.gaugeDraws.rawValue] ?? 0
        lastNotificationStates[key] = state
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var metalViews: [MTKView] {
        var result: [MTKView] = []
        var pending: [(NSView, Int)] = [(hostingView, 0)]
        var visited = 0
        while let (view, depth) = pending.popLast(), visited < 512 {
            visited += 1
            if let metal = view as? MTKView { result.append(metal) }
            if depth < 32 { pending.append(contentsOf: view.subviews.map { ($0, depth + 1) }) }
        }
        return result
    }

    func removeGauges() {
        hostingView.rootView = NativeGaugeFixtureView(showsGauges: false, surfaceDiagnostics: surfaceDiagnostics)
        hostingView.layoutSubtreeIfNeeded()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        removeGauges()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

private final class NativeGaugeWeakReference {
    weak var value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
}

private struct NativeGaugeTestFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif
