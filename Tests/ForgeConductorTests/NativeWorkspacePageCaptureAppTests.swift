import AppKit
import ApplicationServices
import SwiftUI
import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

@MainActor
final class NativeWorkspacePageCaptureAppTests: XCTestCase, @unchecked Sendable {
#if !SWIFT_PACKAGE
    private var fixture: NativeWorkspacePageCaptureFixture?
    private var originalWindows: [NSWindow] = []
    private let directEvidence = DirectNativeFixtureEvidenceWriter()
    private var traversalDiagnosticNodes: [[String: Any]]?
    private var traversalDiagnosticVisitedCount = 0
    private var readOnlyObservationPhase: String?

    func testOwnWindowPublicAXExportsIndependentSwiftUIIdentifiers() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name)
            let expected: Set<String> = ["hosting-probe-title", "hosting-probe-button"]
            let root = NSHostingView(rootView: VStack(spacing: 12) {
                Text("Independent hosting probe").accessibilityIdentifier("hosting-probe-title")
                Button("Independent probe") {}.accessibilityIdentifier("hosting-probe-button")
            }.frame(width: 420, height: 180))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 180),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Own-window AX probe \(UUID().uuidString)"
            window.contentView = root
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            window.setContentSize(NSSize(width: 420, height: 180))
            window.orderFrontRegardless()
            try await waitUntil("The own-window read-only AX probe did not become exposed") {
                root.layoutSubtreeIfNeeded()
                return window.isVisible && window.occlusionState.contains(.visible)
                    && window.contentView === root && root.window === window
                    && root.bounds.size == NSSize(width: 420, height: 180)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var errors: [String] = [], nodes: [[String: String]] = []
            func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < deadline, errors.count < 32 else { return nil }
                AXUIElementSetMessagingTimeout(element, 0.1)
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
                if status != .success && status != .attributeUnsupported && status != .noValue {
                    errors.append("\(key): AXError \(status.rawValue)")
                }
                return status == .success ? value : nil
            }
            func children(_ element: AXUIElement, _ key: String, limit: Int) -> [AXUIElement] {
                guard ProcessInfo.processInfo.systemUptime < deadline, errors.count < 32 else { return [] }
                AXUIElementSetMessagingTimeout(element, 0.1)
                var count = 0
                let status = AXUIElementGetAttributeValueCount(element, key as CFString, &count)
                if status == .attributeUnsupported || status == .noValue { return [] }
                guard status == .success, count >= 0, count <= limit else {
                    errors.append("\(key): AXError \(status.rawValue), count \(count), bound \(limit)")
                    return []
                }
                guard count > 0 else { return [] }
                var values: CFArray?
                let copied = AXUIElementCopyAttributeValues(element, key as CFString, 0, count, &values)
                guard copied == .success, let result = values as? [AXUIElement] else {
                    errors.append("\(key): AXError \(copied.rawValue), missing typed children")
                    return []
                }
                return result
            }
            // Match only this process and the exact uniquely titled owned window.
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let matches = children(application, kAXWindowsAttribute, limit: 32).filter {
                attribute($0, kAXTitleAttribute) as? String == window.title
            }
            var pending: [(AXUIElement, Int)] = matches.count == 1 ? [(matches[0], 0)] : []
            var seen: [AXUIElement] = [], identifiers = Set<String>()
            while let (element, depth) = pending.popLast() {
                guard ProcessInfo.processInfo.systemUptime < deadline, seen.count < 512, depth <= 24 else {
                    errors.append("Own-window AX traversal exceeded its deadline/node/depth bound")
                    break
                }
                guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                seen.append(element)
                let id = attribute(element, kAXIdentifierAttribute) as? String ?? ""
                identifiers.insert(id)
                nodes.append(["identifier": String(id.prefix(128)),
                    "role": String((attribute(element, kAXRoleAttribute) as? String ?? "").prefix(128)),
                    "title": String((attribute(element, kAXTitleAttribute) as? String ?? "").prefix(256)),
                    "value": String((attribute(element, kAXValueAttribute) as? String ?? "").prefix(256))])
                pending.append(contentsOf: children(element, kAXChildrenAttribute,
                    limit: 512 - seen.count - pending.count).map { ($0, depth + 1) })
            }
            let json = try JSONSerialization.data(withJSONObject: [
                "classification": "Read-only public AXUIElement observation of one own-process independent fixture; no production parity or interaction claim",
                "process_trusted": AXIsProcessTrusted(), "matched_owned_windows": matches.count,
                "expected_identifiers": expected.sorted(), "missing_identifiers": expected.subtracting(identifiers).sorted(),
                "errors": errors, "nodes": nodes,
            ], options: [.prettyPrinted, .sortedKeys])
            guard json.count <= 512 * 1_024 else { throw NativeWorkspacePageCaptureFailure("Own-window AX report exceeded its byte budget") }
            try directEvidence.save(json, name: "own-window-public-ax-probe", extension: "json")
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = "own-window-public-ax-probe"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(matches.count, 1)
            XCTAssertTrue(errors.isEmpty, "\(errors)")
            XCTAssertTrue(expected.isSubset(of: identifiers), "Missing: \(expected.subtracting(identifiers).sorted())")
        } catch { try? retainFailure(error); await restoreHost(); throw error }
        await restoreHost()
    }

    func testIndependentHostingViewAndControllerAccessibilityExposureComparison() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name)
            let expected: Set<String> = ["hosting-probe-title", "hosting-probe-button"]
            let content = AnyView(VStack(spacing: 12) {
                Text("Independent hosting probe").accessibilityIdentifier("hosting-probe-title")
                Button("Independent probe") {}.accessibilityIdentifier("hosting-probe-button")
            }.frame(width: 420, height: 180))
            var observations: [[String: Any]] = [], qualified: [String: Bool] = [:]
            for mode in ["view", "controller"] {
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 180),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let root: NSView
                if mode == "controller" {
                    let owner = NSHostingController(rootView: content)
                    window.contentViewController = owner; root = owner.view
                } else {
                    root = NSHostingView(rootView: content); window.contentView = root
                }
                defer { window.orderOut(nil); window.contentViewController = nil; window.contentView = nil; window.close() }
                window.setContentSize(NSSize(width: 420, height: 180)); NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
                try await waitUntil("The independent hosting probe did not become exposed: " + mode) {
                    NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
                }
                root.layoutSubtreeIfNeeded()
                guard window.contentView === root else { throw NativeWorkspacePageCaptureFailure("Hosting probe root ownership changed") }
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                var pending: [(NativeWorkspacePageCaptureElement, Int)] = [(try .init(window), 0)]
                var retained: [NativeWorkspacePageCaptureElement] = [], nodes: [[String: Any]] = []
                var seen = Set<ObjectIdentifier>(), identifiers = Set<String>()
                while let (element, depth) = pending.popLast() {
                    guard ProcessInfo.processInfo.systemUptime < deadline, retained.count < 512, depth <= 24 else {
                        throw NativeWorkspacePageCaptureFailure("Independent hosting probe exceeded its observer bounds")
                    }
                    guard seen.insert(element.identity).inserted else { continue }
                    retained.append(element)
                    let identifier = element.accessibilityIdentifier() ?? ""; identifiers.insert(identifier)
                    nodes.append(["identifier": String(identifier.prefix(128)), "api": element.observationAPI,
                        "object_type": String(String(describing: type(of: element.object)).prefix(256)),
                        "role": String((element.accessibilityRole() ?? "").prefix(128)),
                        "title": String((element.accessibilityTitle() ?? "").prefix(256)),
                        "label": String((element.accessibilityLabel() ?? "").prefix(256))])
                    let children = try element.accessibilityChildren()
                    guard children.count <= 512 - retained.count - pending.count else {
                        throw NativeWorkspacePageCaptureFailure("Independent hosting probe child budget exceeded")
                    }
                    for child in children.reversed() { pending.append((try .init(child), depth + 1)) }
                }
                let exported = try NativeWorkspacePageCaptureAXScope(window: window, hosting: root).observe()
                let exportedIDs = Set(exported.map(\.identifier))
                qualified[mode] = expected.isSubset(of: exportedIDs)
                observations.append(["mode": mode, "native_root_type": String(describing: type(of: root)),
                    "public_AX_missing_identifiers": expected.subtracting(exportedIDs).sorted(),
                    "public_AX_nodes": exported.map(\.dictionary),
                    "native_bounds": NSStringFromRect(root.bounds), "window": NSStringFromRect(window.frame),
                    "content_view_controller_present": window.contentViewController != nil,
                    "expected_identifiers": expected.sorted(), "missing_identifiers": expected.subtracting(identifiers).sorted(), "nodes": nodes])
            }
            let json = try JSONSerialization.data(withJSONObject: ["classification": "Independent public hosting ownership isolation; no production-page parity claim", "observations": observations], options: [.prettyPrinted, .sortedKeys])
            guard json.count <= 512 * 1_024 else { throw NativeWorkspacePageCaptureFailure("Hosting comparison JSON exceeded its byte budget") }
            try directEvidence.save(json, name: "independent-hosting-view-controller-comparison", extension: "json")
            if !directEvidence.isEnabled {
                let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
                attachment.name = "independent-hosting-view-controller-comparison"; attachment.lifetime = .keepAlways; add(attachment)
            }
            guard qualified.count == 2, qualified.values.allSatisfy({ $0 }) else {
                throw NativeWorkspacePageCaptureFailure("Both public hosting ownership modes must export both independent SwiftUI identifiers through their exact own-window AX tree")
            }
        } catch { try? retainFailure(error); await restoreHost(); throw error }
        await restoreHost()
    }

    /// Native workspace chrome reachability only; no pointer, wheel or semantic action is dispatched.
    func testNativeWorkspacesNativeScrollReachabilityAtMinimumSize() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name + "-native-scroll-minimum")
            let viewport = NSSize(width: 1_100, height: 720)
            let routes: [(NativeWorkspaceCapturePage, ManagerSettingsView.ManagementSection?)] =
                NativeWorkspaceCapturePage.allCases.map { ($0, nil) }
                + ManagerSettingsView.ManagementSection.allCases.map { (.manager, Optional($0)) }
            XCTAssertEqual(routes.count, 22)
            let namespaces = Set(routes.map { page, section in
                section.map { "manager." + $0.rawValue } ?? page.viewID
            })
            XCTAssertEqual(namespaces.count, 21)
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            for (index, item) in routes.enumerated() {
                // Reserve the inherited five-second presentation and canvas waits.
                guard deadline - ProcessInfo.processInfo.systemUptime > 10 else {
                    throw NativeWorkspacePageCaptureFailure("Native scroll admission deadline elapsed")
                }
                let (page, section) = item
                let viewID = section.map { "manager." + $0.rawValue } ?? page.viewID
                let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport,
                    initialManagerSection: section ?? .folders)
                fixture = owned
                owned.route.page = page
                try await presentPhysicalCache(owned, expectedContentSize: viewport)
                XCTAssertEqual(owned.route.page, page)
                let layout = try owned.customize(viewID)
                try await requireCanvas(layout, in: owned)
                let report = try await nativeScrollReachability(layout, in: owned,
                    expectedContentSize: viewport, deadline: deadline)
                let data = try JSONSerialization.data(withJSONObject: report,
                    options: [.prettyPrinted, .sortedKeys])
                guard data.count <= 512 * 1_024 else {
                    throw NativeWorkspacePageCaptureFailure("Native scroll receipt exceeded its JSON bound")
                }
                let receiptName = "native-scroll-\(index)-\(viewID)-minimum"
                try directEvidence.save(data, name: receiptName, extension: "json")
                if !directEvidence.isEnabled {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = receiptName; attachment.lifetime = .keepAlways; add(attachment)
                }
                let mutations = await owned.client.mutationNames()
                XCTAssertTrue(mutations.isEmpty)
                XCTAssertNil(owned.model.app)
                XCTAssertNil(owned.model.manager)
                XCTAssertNil(owned.model.remoteManager)
                XCTAssertFalse(owned.model.hasLoadedInitialSettings)
                try owned.preferences.reset(viewID)
                try await waitUntil("The scrolled native document did not dismantle after reset") {
                    owned.hosting.layoutSubtreeIfNeeded()
                    return !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
                }
                XCTAssertNil(owned.preferences.activeLayout(for: viewID))
                XCTAssertTrue(physicalCachePresentationIsReady(owned, expectedContentSize: viewport))
                await owned.close()
                fixture = nil
            }
        } catch {
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }


    /// Read-only public advertisements on exact outer scrollers; no action dispatch or scroll preparation.
    func testNativeProjectsCustomCanvasPublicScrollerAdvertisementsAtMinimumSize() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        do {
            try directEvidence.configure(testName: name + "-scroller-advertisements")
            try await prepareHost()
            guard deadline - ProcessInfo.processInfo.systemUptime > 10 else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement case lacks bounded presentation time")
            }
            let viewport = NSSize(width: 1_100, height: 720)
            let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport)
            fixture = owned; owned.route.page = .projects
            try await presentPhysicalCache(owned, expectedContentSize: viewport)
            let layout = try owned.customize("projects")
            guard deadline - ProcessInfo.processInfo.systemUptime > 5 else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement case lacks bounded canvas time")
            }
            try await requireCanvas(layout, in: owned)
            try await nativeProjectsScrollerAdvertisements(layout, in: owned,
                expectedContentSize: viewport, deadline: deadline)
            guard deadline - ProcessInfo.processInfo.systemUptime > 5 else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement case lacks bounded reset time")
            }
            try owned.preferences.reset("projects")
            try await waitUntil("Projects advertisement canvas did not dismantle after explicit reset",
                timeout: min(5, deadline - ProcessInfo.processInfo.systemUptime)) {
                owned.hosting.layoutSubtreeIfNeeded()
                return !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
            }
            guard owned.preferences.activeLayout(for: "projects") == nil,
                  self.physicalCachePresentationIsReady(owned, expectedContentSize: viewport),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement reset changed its owner or exceeded the case deadline")
            }
            await owned.close(); fixture = nil
            await restoreHost()
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement case exceeded its deadline during cleanup")
            }
        } catch {
            do { try retainFailure(error) }
            catch { XCTFail("Could not retain Projects advertisement terminal failure: \(scrollerActionBoundedString(String(reflecting: error), bytes: 2_048))") }
            await restoreHost()
            throw error
        }
    }


    /// Exact outer scroller semantic actions only; no direct scroll preparation or pointer input.
    func testNativeProjectsCustomCanvasScrollerActionsExposeOffscreenResizeCenterAtMinimumSize() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        do {
            try directEvidence.configure(testName: name + "-native-scroller-actions")
            try await prepareHost()
            guard deadline - ProcessInfo.processInfo.systemUptime > 10 else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller case lacks bounded presentation time")
            }
            let viewport = NSSize(width: 1_100, height: 720)
            let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport)
            fixture = owned; owned.route.page = .projects
            try await presentPhysicalCache(owned, expectedContentSize: viewport)
            let layout = try owned.customize("projects")
            guard deadline - ProcessInfo.processInfo.systemUptime > 5 else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller case lacks bounded canvas time")
            }
            try await requireCanvas(layout, in: owned)
            try await nativeProjectsScrollerActions(layout, in: owned,
                expectedContentSize: viewport, deadline: deadline)
            guard deadline - ProcessInfo.processInfo.systemUptime > 5 else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller case lacks bounded reset time")
            }
            try owned.preferences.reset("projects")
            try await waitUntil("Projects scroller action canvas did not dismantle after explicit reset",
                timeout: min(5, deadline - ProcessInfo.processInfo.systemUptime)) {
                owned.hosting.layoutSubtreeIfNeeded()
                return !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
            }
            guard owned.preferences.activeLayout(for: "projects") == nil,
                  self.physicalCachePresentationIsReady(owned, expectedContentSize: viewport),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller reset changed its owner or exceeded the case deadline")
            }
            await owned.close(); fixture = nil
            await restoreHost()
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller case exceeded its deadline during cleanup")
            }
        } catch {
            do { try retainFailure(error) }
            catch { XCTFail("Could not retain Projects scroller terminal failure: \(scrollerActionBoundedString(String(reflecting: error), bytes: 2_048))") }
            await restoreHost()
            throw error
        }
    }

    /// Two owned-window wheel events; conversion and measured movement must both qualify.
    func testNativeProjectsCustomCanvasQueuedScrollWheelExposesResizeCenterAtMinimumSize() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let viewport = NSSize(width: 1_100, height: 720)
        var stage = "presentation", events: [[String: Any]] = [], posted = 0
        var report: [String: Any] = ["classification": "Owned-window queued wheel input; no direct scroll or semantic action",
            "execution_completed": false, "maximum_events": 2, "maximum_case_seconds": 30,
            "maximum_phase_seconds": 3, "case_deadline_uptime": deadline]
        func retainReport(_ suffix: String) throws {
            report["last_stage"] = stage; report["events"] = events; report["posted_events"] = posted
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard events.count <= 2, data.count <= 512 * 1_024 else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel receipt exceeded its event/JSON bound")
            }
            let receiptName = "projects-queued-wheel-" + suffix
            try directEvidence.save(data, name: receiptName, extension: "json")
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = receiptName; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try directEvidence.configure(testName: name + "-queued-wheel")
            try await prepareHost()
            guard deadline - ProcessInfo.processInfo.systemUptime > 10 else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel case lacks bounded presentation time")
            }
            let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport)
            fixture = owned; owned.route.page = .projects
            try await presentPhysicalCache(owned, expectedContentSize: viewport)
            let layout = try owned.customize("projects")
            guard deadline - ProcessInfo.processInfo.systemUptime > 5 else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel case lacks bounded canvas time")
            }
            try await requireCanvas(layout, in: owned)
            let documents = nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            guard documents.count == 1, let document = documents.first,
                  let scroll = document.enclosingScrollView, scroll.documentView === document,
                  document.superview === scroll.contentView, document.isFlipped,
                  scroll.hasHorizontalScroller, scroll.hasVerticalScroller,
                  let horizontal = scroll.horizontalScroller, let vertical = scroll.verticalScroller,
                  horizontal !== vertical, let panel = document.panelHosts["projects-summary"],
                  layout.panels.count > 0, layout.panels.count <= 64, layout.panels.allSatisfy(\.isVisible) else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel exact document/panel/scrollers are absent")
            }
            let frame = document.frame, bounds = document.bounds
            let canvasSize = NSSize(width: layout.canvas.width, height: layout.canvas.height)
            let identities = document.panelHosts.mapValues { ObjectIdentifier($0) }
            let panelFrames = document.panelHosts.mapValues(\.frame)
            let hostingIdentities = document.panelHosts.mapValues { ObjectIdentifier($0.hostingView) }
            guard Set(identities.keys) == Set(layout.panels.map(\.id)), frame.size == canvasSize,
                  bounds.origin == .zero, bounds.size == canvasSize,
                  layout.panels.allSatisfy({ document.panelHosts[$0.id]?.frame == NSRect(x: $0.frame.x,
                    y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }) else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel catalog frames/canvas differ from its layout")
            }
            let controls = nativeViews(panel).filter { $0.accessibilityIdentifier() == "workspace-resize-projects-summary" }
            guard controls.count == 1, let control = controls.first, control.superview === panel,
                  !control.isHiddenOrHasHiddenAncestor, control.bounds.width >= 8, control.bounds.height >= 8 else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel exact resize control is absent")
            }
            let controlFrame = control.frame, controlBounds = control.bounds
            let targetBounds = document.convert(control.bounds, from: control)
            let target = NSRect(x: targetBounds.midX - 4, y: targetBounds.midY - 4, width: 8, height: 8)
            let baseline = owned.preferences.collection
            let beforeBytes = try XCTUnwrap(owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let initialKey = owned.window.isKeyWindow, initialActive = NSApp.isActive
            guard beforeBytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: beforeBytes) == baseline,
                  owned.preferences.activeLayout(for: "projects") == layout, document.bounds.contains(target),
                  target.minX > document.visibleRect.maxX, target.minY > document.visibleRect.maxY else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel storage or initially offscreen resize center is invalid")
            }
            func requireOwner() throws {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      self.physicalCachePresentationIsReady(owned, expectedContentSize: viewport),
                      owned.route.page == .projects, owned.window.isKeyWindow == initialKey, NSApp.isActive == initialActive,
                      document.window === owned.window, scroll.window === owned.window,
                      document.enclosingScrollView === scroll, scroll.documentView === document,
                      document.superview === scroll.contentView, document.frame == frame, document.bounds == bounds,
                      scroll.horizontalScroller === horizontal, scroll.verticalScroller === vertical,
                      horizontal.superview === scroll, vertical.superview === scroll,
                      document.panelHosts.mapValues({ ObjectIdentifier($0) }) == identities,
                      document.panelHosts.mapValues(\.frame) == panelFrames,
                      document.panelHosts.mapValues({ ObjectIdentifier($0.hostingView) }) == hostingIdentities,
                      panel.superview === document, !panel.isHiddenOrHasHiddenAncestor,
                      control.superview === panel, control.window === owned.window,
                      !control.isHiddenOrHasHiddenAncestor, control.frame == controlFrame, control.bounds == controlBounds,
                      document.convert(control.bounds, from: control) == targetBounds,
                      owned.preferences.collection == baseline,
                      owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                      owned.model.app == nil, owned.model.manager == nil, owned.model.remoteManager == nil,
                      !owned.model.hasLoadedInitialSettings else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel owner/geometry/storage/model changed or deadline elapsed")
                }
                var ancestor: NSView? = document, seen = Set<ObjectIdentifier>()
                while let view = ancestor {
                    guard seen.count < 64, seen.insert(ObjectIdentifier(view)).inserted,
                          view.window === owned.window, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw NativeWorkspacePageCaptureFailure("Projects wheel native ancestry exceeded its owner/depth/deadline bound")
                    }
                    if view === owned.hosting { return }
                    ancestor = view.superview
                }
                throw NativeWorkspacePageCaptureFailure("Projects wheel document ancestry did not reach its exact hosting owner")
            }
            try requireOwner()
            report["initial_document_visible"] = NSStringFromRect(document.visibleRect)
            report["target_center_rect"] = NSStringFromRect(target)
            report["window_key"] = initialKey; report["application_active"] = initialActive
            report["stored_bytes"] = beforeBytes.count
            try retainReport("before")
            try capturePhysicalCache(owned, expectedContentSize: viewport, name: "projects-queued-wheel-before")
            for (axis, wheel1, wheel2) in [("horizontal", Int32(0), Int32(-480)), ("vertical", Int32(-120), Int32(0))] {
                stage = axis + ".document-hit"
                try requireOwner()
                let before = scroll.contentView.bounds, visible = document.visibleRect
                let point = NSPoint(x: visible.midX, y: visible.minY + 10)
                guard [before.minX, before.minY, before.width, before.height, point.x, point.y].allSatisfy({ $0.isFinite }),
                      before.width > 0, before.height > 20, visible.contains(point),
                      owned.hosting.hitTest(document.convert(point, to: owned.hosting.superview)) === document else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel point does not physically hit the exact blank document")
                }
                let slot = events.count
                events.append(["axis": axis, "requested_wheel1": wheel1, "requested_wheel2": wheel2,
                    "posted": false, "before_clip_bounds": NSStringFromRect(before)])
                defer {
                    events[slot]["after_clip_bounds"] = NSStringFromRect(scroll.contentView.bounds)
                    events[slot]["after_document_visible"] = NSStringFromRect(document.visibleRect)
                    events[slot]["finished_uptime"] = ProcessInfo.processInfo.systemUptime
                }
                stage = axis + ".conversion"
                let local = document.convert(point, to: nil), windowNumber = owned.window.windowNumber
                let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: local,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                    context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
                events[slot]["seed_exact_window"] = seed.window === owned.window
                events[slot]["seed_window_number"] = seed.windowNumber
                guard windowNumber > 0, seed.window === owned.window, seed.windowNumber == windowNumber,
                      abs(seed.locationInWindow.x - local.x) <= 0.5, abs(seed.locationInWindow.y - local.y) <= 0.5 else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel seed lacks exact window/point association")
                }
                let seedCG = try XCTUnwrap(seed.cgEvent)
                let seedRoundTrip = NSEvent(cgEvent: seedCG)
                events[slot]["seed_cg_roundtrip_exact_window"] = seedRoundTrip?.window === owned.window
                events[slot]["seed_cg_roundtrip_window_number"] = seedRoundTrip.map { $0.windowNumber as Any } ?? NSNull()
                events[slot]["seed_cg_roundtrip_point"] = seedRoundTrip.map { NSStringFromPoint($0.locationInWindow) as Any } ?? NSNull()
                let template = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0))
                let wheel = try XCTUnwrap(seedCG.copy())
                wheel.type = .scrollWheel
                for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                    .scrollWheelEventIsContinuous] {
                    wheel.setIntegerValueField(field, value: template.getIntegerValueField(field))
                }
                for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                    .scrollWheelEventFixedPtDeltaAxis3] {
                    wheel.setDoubleValueField(field, value: template.getDoubleValueField(field))
                }
                guard seedCG.location.x.isFinite, seedCG.location.y.isFinite else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel seed global point is nonfinite")
                }
                let field91 = wheel.getIntegerValueField(.mouseEventWindowUnderMousePointer)
                let field92 = wheel.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
                events[slot]["field91"] = field91; events[slot]["field92"] = field92
                let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
                events[slot]["converted_exact_window"] = event.window === owned.window
                events[slot]["converted_window_number"] = event.windowNumber
                events[slot]["converted_type"] = event.type.rawValue
                events[slot]["local_point"] = NSStringFromPoint(local)
                events[slot]["converted_point"] = NSStringFromPoint(event.locationInWindow)
                guard event.type == .scrollWheel else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel conversion did not return a scroll-wheel event")
                }
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                events[slot]["delta_x"] = dx.isFinite ? dx as Any : String(describing: dx)
                events[slot]["delta_y"] = dy.isFinite ? dy as Any : String(describing: dy)
                events[slot]["precise_deltas"] = event.hasPreciseScrollingDeltas
                events[slot]["direction_inverted"] = event.isDirectionInvertedFromDevice
                guard event.window === owned.window, event.windowNumber == windowNumber,
                      [local.x, local.y, event.locationInWindow.x, event.locationInWindow.y, dx, dy].allSatisfy({ $0.isFinite }),
                      abs(event.locationInWindow.x - local.x) <= 0.5, abs(event.locationInWindow.y - local.y) <= 0.5,
                      axis == "horizontal" ? (dx < 0 && abs(dy) <= 0.1) : (dy < 0 && abs(dx) <= 0.1) else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel conversion lacks exact window/point/single-axis association")
                }
                try requireOwner()
                guard posted < 2, owned.hosting.hitTest(document.convert(point, to: owned.hosting.superview)) === document else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel dispatch lost its exact document/two-event bound")
                }
                stage = axis + ".movement"
                events[slot]["post_uptime"] = ProcessInfo.processInfo.systemUptime
                NSApp.postEvent(event, atStart: false); posted += 1; events[slot]["posted"] = true
                let settleDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
                var progressed = false
                while ProcessInfo.processInfo.systemUptime < settleDeadline {
                    try requireOwner(); owned.hosting.layoutSubtreeIfNeeded(); try requireOwner()
                    let after = scroll.contentView.bounds, currentVisible = document.visibleRect
                    let delta = axis == "horizontal" ? after.minX - before.minX : after.minY - before.minY
                    let other = axis == "horizontal" ? after.minY - before.minY : after.minX - before.minX
                    events[slot]["axis_delta"] = delta.isFinite ? delta as Any : String(describing: delta)
                    events[slot]["other_axis_delta"] = other.isFinite ? other as Any : String(describing: other)
                    guard [after.minX, after.minY, after.width, after.height, delta, other].allSatisfy({ $0.isFinite }),
                          abs(after.width - before.width) <= 0.1, abs(after.height - before.height) <= 0.1,
                          delta >= -0.1, abs(other) <= 0.1 else {
                        throw NativeWorkspacePageCaptureFailure("Projects wheel moved in an unexpected axis/direction or resized its clip")
                    }
                    let contains = axis == "horizontal" ? currentVisible.minX <= target.minX && currentVisible.maxX >= target.maxX
                        : currentVisible.minY <= target.minY && currentVisible.maxY >= target.maxY
                    if delta > 0.1 && contains {
                        guard ProcessInfo.processInfo.systemUptime < settleDeadline else {
                            throw NativeWorkspacePageCaptureFailure("Projects wheel progress sample crossed its phase deadline")
                        }
                        progressed = true; break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard progressed else {
                    throw NativeWorkspacePageCaptureFailure("Projects wheel did not expose its target axis within three seconds")
                }
                try requireOwner(); events[slot]["target_axis_visible"] = true
            }
            stage = "final-storage-and-hit-test"
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: owned.defaults)
            let mutations = await owned.client.mutationNames()
            try requireOwner()
            guard posted == 2, document.visibleRect.contains(target),
                  owned.hosting.hitTest(document.convert(NSPoint(x: target.midX, y: target.midY), to: owned.hosting.superview)) === control,
                  fresh.restorationError == nil, fresh.collection == baseline, mutations.isEmpty else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel final control hit/storage/isolation proof failed")
            }
            report["target_center_visible"] = true; report["exact_control_hit_test"] = true
            report["complete_preferences_and_bytes_unchanged"] = true; report["fresh_restoration_unchanged"] = true
            report["fixture_mutations"] = mutations
            try capturePhysicalCache(owned, expectedContentSize: viewport, name: "projects-queued-wheel-after")
            try requireOwner()
            guard deadline - ProcessInfo.processInfo.systemUptime > 5 else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel case lacks bounded reset time")
            }
            try owned.preferences.reset("projects")
            try await waitUntil("Projects wheel canvas did not dismantle after reset",
                timeout: min(5, deadline - ProcessInfo.processInfo.systemUptime)) {
                owned.hosting.layoutSubtreeIfNeeded()
                return !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
            }
            guard owned.preferences.activeLayout(for: "projects") == nil,
                  physicalCachePresentationIsReady(owned, expectedContentSize: viewport) else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel reset changed its exact presentation owner")
            }
            await owned.close(); fixture = nil; await restoreHost()
            try Task.checkCancellation()
            stage = "complete"; report["execution_completed"] = true
            try retainReport("after")
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeWorkspacePageCaptureFailure("Projects wheel case exceeded its cleanup/receipt deadline")
            }
        } catch let failure {
            report["execution_completed"] = false
            report["original_error"] = scrollerActionBoundedString(String(reflecting: failure), bytes: 512)
            if let owned = fixture, physicalCachePresentationIsReady(owned, expectedContentSize: viewport) {
                do { try capturePhysicalCache(owned, expectedContentSize: viewport, name: "projects-queued-wheel-failed") }
                catch { report["failure_cache_error"] = scrollerActionBoundedString(String(reflecting: error), bytes: 512) }
            }
            do { try retainReport("failed"); try retainFailure(failure) }
            catch { XCTFail("Could not retain Projects wheel failure: \(scrollerActionBoundedString(String(reflecting: error), bytes: 512))") }
            await restoreHost(); throw failure
        }
    }

    func testRealCatalogViewsQueuedMoveResizePersistsGeometry() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name + "-queued-real-views")
            let routes: [(NativeWorkspaceCapturePage, ManagerSettingsView.ManagementSection?, String)] = [
                (.rig, nil, "rig-header"), (.mcp, nil, "mcp-controls"), (.agents, nil, "agents-controls"),
                (.tools, nil, "tools-controls"), (.feed, nil, "feed-summary"),
                (.projects, nil, "projects-repository"), (.runeForge, nil, "rune-controls"),
                (.continuity, nil, "continuity-controls"), (.runtimes, nil, "runtimes-controls"),
                (.provider, nil, "provider-controls"), (.evidence, nil, "evidence-controls"),
                (.diagnostics, nil, "diagnostics-controls"),
            ] + ManagerSettingsView.ManagementSection.allCases.map { (.manager, Optional($0), "manager-header") }
            let namespaces = routes.map { page, section, _ in section.map { "manager." + $0.rawValue } ?? page.viewID }
            guard routes.count == 21, Set(namespaces).count == 21 else {
                throw NativeWorkspacePageCaptureFailure("The real queued-input route table must contain21 distinct namespaces.")
            }
            for (index, route) in routes.enumerated() {
                try Task.checkCancellation()
                // The unchanged presentation/canvas helpers can each use their existing five-second waits.
                guard deadline - ProcessInfo.processInfo.systemUptime > 15 else {
                    throw NativeWorkspacePageCaptureFailure("The real queued-input case lacks bounded presentation time.")
                }
                let (page, section, panelID) = route
                let viewID = namespaces[index]
                let owned = try NativeWorkspacePageCaptureFixture(contentSize: NSSize(width: 1_440, height: 900),
                    initialManagerSection: section ?? .folders)
                fixture = owned; owned.route.page = page
                try await present(owned)
                let otherID = viewID == "feed" ? "tools" : "feed"
                let independent = try owned.customize(otherID)
                var layout = try owned.customize(viewID)
                layout.canvas.width += 80; layout.canvas.height += 80
                try owned.preferences.save(layout)
                try await requireCanvas(layout, in: owned)
                try owned.preferences.bringToFront(panelID, in: viewID)
                try await queuedRealPanelGeometry(layout, panelID: panelID, in: owned, deadline: deadline,
                    receiptName: "queued-real-\(index)-\(viewID)")
                let mutations = await owned.client.mutationNames()
                guard owned.preferences.layouts(for: otherID) == [independent],
                      owned.preferences.activeLayout(for: otherID) == independent,
                      mutations.isEmpty, owned.model.app == nil,
                      owned.model.manager == nil, owned.model.remoteManager == nil,
                      !owned.model.hasLoadedInitialSettings else {
                    throw NativeWorkspacePageCaptureFailure("The isolated real-view gesture changed another workspace/backend or fixture bootstrap contract.")
                }
                await owned.close(); fixture = nil
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NativeWorkspacePageCaptureFailure("The real queued-input case exceeded its shared deadline during cleanup.")
                }
            }
        } catch { try? retainFailure(error); await restoreHost(); throw error }
        await restoreHost()
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw NativeWorkspacePageCaptureFailure("The real queued-input case exceeded its shared deadline.")
        }
    }

    private func queuedRealPanelGeometry(_ layout: NativeWorkspaceLayout, panelID: String,
                                         in owned: NativeWorkspacePageCaptureFixture, deadline: TimeInterval,
                                         receiptName: String) async throws {
        try await NativeWorkspaceQueuedPanelGeometryVerifier.verify(layout, panelID: panelID,
            window: owned.window, hosting: owned.hosting, preferences: owned.preferences, defaults: owned.defaults,
            deadline: deadline, receiptName: receiptName,
            presentationIsReady: {
                self.physicalCachePresentationIsReady(owned, expectedContentSize: NSSize(width: 1_440, height: 900))
            }, retainReport: { data, name in
                try? self.directEvidence.save(data, name: name, extension: "json")
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = name; attachment.lifetime = .keepAlways; self.add(attachment)
            })
    }

    /// Physical viewport/cache evidence only; the original semantic parity cases remain separate.
    func testNativeWorkspacesPhysicalCachesThirteenPagesAtNormalAndMinimumSizes() async throws {
        try await prepareHost()
        do {
            let viewports: [(label: String, size: NSSize)] = [
                ("normal", NSSize(width: 1_440, height: 900)),
                ("minimum", NSSize(width: 1_100, height: 720)),
            ]
            XCTAssertEqual(NativeWorkspaceCapturePage.allCases.count, 13)
            for viewport in viewports {
                // Each viewport retains 52 PNG/JSON pairs within the existing 128-entry cap.
                try directEvidence.configure(testName: name + "-physical-" + viewport.label)
                let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport.size)
                fixture = owned
                try await presentPhysicalCache(owned, expectedContentSize: viewport.size)
                for page in NativeWorkspaceCapturePage.allCases {
                    owned.route.page = page
                    try await Task.sleep(for: .milliseconds(100))
                    XCTAssertEqual(owned.route.page, page)
                    XCTAssertEqual(owned.hosting.bounds.width, viewport.size.width, accuracy: 0.1)
                    XCTAssertEqual(owned.hosting.bounds.height, viewport.size.height, accuracy: 0.1)
                    try await capturePhysicalStates(page.viewID, in: owned, expectedContentSize: viewport.size,
                        name: "physical-\(page.rawValue)-\(viewport.label)")
                }
                let mutations = await owned.client.mutationNames()
                XCTAssertTrue(mutations.isEmpty)
                XCTAssertNil(owned.model.app)
                XCTAssertNil(owned.model.manager)
                XCTAssertNil(owned.model.remoteManager)
                XCTAssertFalse(owned.model.hasLoadedInitialSettings)
                await owned.close()
                fixture = nil
            }
        } catch {
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    /// Fresh public initialSection fixtures avoid substituting a capture for section-action parity.
    func testNativeWorkspacesPhysicalCachesNineManagerSectionsAtMinimumSize() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name + "-physical-minimum")
            XCTAssertEqual(ManagerSettingsView.ManagementSection.allCases.count, 9)
            for section in ManagerSettingsView.ManagementSection.allCases {
                let owned = try NativeWorkspacePageCaptureFixture(contentSize: NSSize(width: 1_100, height: 720),
                    initialManagerSection: section)
                fixture = owned
                owned.route.page = .manager
                try await presentPhysicalCache(owned, expectedContentSize: NSSize(width: 1_100, height: 720))
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(owned.route.page, .manager)
                XCTAssertEqual(owned.hosting.bounds.width, 1_100, accuracy: 0.1)
                XCTAssertEqual(owned.hosting.bounds.height, 720, accuracy: 0.1)
                try await capturePhysicalStates("manager." + section.rawValue, in: owned,
                    expectedContentSize: NSSize(width: 1_100, height: 720), name: "physical-manager-\(section.rawValue)-minimum-startup")
                let mutations = await owned.client.mutationNames()
                XCTAssertTrue(mutations.isEmpty)
                XCTAssertFalse(owned.model.hasLoadedInitialSettings)
                XCTAssertNil(owned.model.app)
                XCTAssertNil(owned.model.manager)
                XCTAssertNil(owned.model.remoteManager)
                await owned.close()
                fixture = nil
            }
        } catch {
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    private func capturePhysicalStates(_ viewID: String, in owned: NativeWorkspacePageCaptureFixture,
                                       expectedContentSize: NSSize, name: String) async throws {
        XCTAssertTrue(physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize))
        XCTAssertNil(owned.preferences.activeLayout(for: viewID))
        try await waitUntil("The default physical viewport retained a custom native document") {
            owned.hosting.layoutSubtreeIfNeeded()
            return !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
        }
        try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: name + "-default")

        let custom = try owned.customize(viewID)
        try await requireCanvas(custom, in: owned)
        try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: name + "-custom")
        for placement in custom.panels {
            try owned.preferences.setShown(false, for: placement.id, in: viewID)
        }
        try await requireHiddenCanvas(custom, in: owned)
        try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: name + "-all-hidden")

        try owned.preferences.reset(viewID)
        try await waitUntil("The physical custom document did not dismantle after reset") {
            owned.hosting.layoutSubtreeIfNeeded()
            return !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
        }
        XCTAssertNil(owned.preferences.activeLayout(for: viewID))
        try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: name + "-restored")
    }

    func testObservedOpaqueGeometryStaysUnknownWithoutAcceptingIdentifiedOrInvalidFrames() throws {
        let observedPoint = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        XCTAssertTrue(CGRect(origin: observedPoint, size: .zero).isNull)
        func decode(_ identifier: String?, _ role: String?, _ point: CGPoint, _ size: CGSize,
                    pointType: AXValueType = .cgPoint, sizeType: AXValueType = .cgSize,
                    pointDecoded: Bool = true, sizeDecoded: Bool = true) throws -> (frame: NSRect?, unknown: [String: String]?) {
            try NativeWorkspacePageCaptureAXScope.interpretObservedGeometry(identifier: identifier, role: role,
                positionType: pointType, sizeType: sizeType, pointDecoded: pointDecoded,
                sizeDecoded: sizeDecoded, point: point, size: size)
        }
        let unknown = try decode(nil, "AXOpaqueProviderGroup", observedPoint, .zero)
        XCTAssertNil(unknown.frame)
        XCTAssertEqual(unknown.unknown?["raw_position"], "{inf, inf}")
        XCTAssertEqual(unknown.unknown?["raw_size"], "{0, 0}")
        let finitePoint = CGPoint(x: 15, y: 30), finiteSize = CGSize(width: 80, height: 24)
        let finite = try decode("hosting-probe-button", kAXButtonRole, finitePoint, finiteSize)
        XCTAssertEqual(finite.frame, NSRect(origin: finitePoint, size: finiteSize))
        XCTAssertNil(finite.unknown)
        XCTAssertThrowsError(try decode("identified-opaque", "AXOpaqueProviderGroup", observedPoint, .zero))
        XCTAssertThrowsError(try decode(nil, kAXButtonRole, observedPoint, .zero))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", observedPoint, CGSize(width: 1, height: 0)))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", CGPoint(x: -CGFloat.infinity, y: CGFloat.infinity), .zero))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", CGPoint(x: CGFloat.nan, y: CGFloat.infinity), .zero))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", observedPoint, .zero, pointDecoded: false))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", observedPoint, .zero, sizeDecoded: false))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", observedPoint, .zero, pointType: .cgSize))
        XCTAssertThrowsError(try decode(nil, "AXOpaqueProviderGroup", observedPoint, .zero, sizeType: .cgPoint))
        XCTAssertThrowsError(try decode("finite-invalid", kAXButtonRole, finitePoint, CGSize(width: -1, height: 24)))
    }

    func testOwnWindowCollectorPreservesIndependentIdentifiersAndFiniteLeafGeometry() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name)
            let expected: Set<String> = ["hosting-probe-title", "hosting-probe-button"]
            let root = NSHostingView(rootView: VStack(spacing: 12) {
                Text("Independent hosting probe").accessibilityIdentifier("hosting-probe-title")
                Button("Independent probe") {}.accessibilityIdentifier("hosting-probe-button")
            }.frame(width: 420, height: 180))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 180),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Own-window collector regression \(UUID().uuidString)"
            window.contentView = root
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            window.setContentSize(NSSize(width: 420, height: 180))
            window.orderFrontRegardless()
            try await waitUntil("The own-window collector regression did not become exposed") {
                root.layoutSubtreeIfNeeded()
                return window.isVisible && window.occlusionState.contains(.visible)
                    && window.contentView === root && root.window === window
                    && root.bounds.size == NSSize(width: 420, height: 180)
            }
            let observed = try NativeWorkspacePageCaptureAXScope(window: window, hosting: root).observe()
            for identifier in expected {
                let matches = observed.filter { $0.identifier == identifier }
                XCTAssertEqual(matches.count, 1)
                let leaf = try XCTUnwrap(matches.first)
                let geometry = try XCTUnwrap(leaf.frame)
                XCTAssertTrue(geometry.origin.x.isFinite && geometry.origin.y.isFinite)
                XCTAssertGreaterThan(geometry.width, 0)
                XCTAssertGreaterThan(geometry.height, 0)
                XCTAssertNil(leaf.element.unknownGeometry)
            }
            let report = try JSONSerialization.data(withJSONObject: [
                "classification": "Read-only regression of the bounded exact-own-window collector and finite independent SwiftUI leaf geometry; no opaque-node runtime, foreground, input or production-page parity claim",
                "expected_identifiers": expected.sorted(), "nodes": observed.map(\.dictionary),
                "application_active": NSApp.isActive, "window_key": window.isKeyWindow,
            ], options: [.prettyPrinted, .sortedKeys])
            guard report.count <= 512 * 1_024 else {
                throw NativeWorkspacePageCaptureFailure("Own-window collector regression exceeded its JSON byte budget")
            }
            try directEvidence.save(report, name: "own-window-collector-regression", extension: "json")
            if !directEvidence.isEnabled {
                let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
                attachment.name = "own-window-collector-regression"; attachment.lifetime = .keepAlways; add(attachment)
            }
        } catch { try? retainFailure(error); await restoreHost(); throw error }
        await restoreHost()
    }

    /// Read-only exported semantics of the exact owned window; no foreground or input qualification.
    func testNativeWorkspacesReadOnlyOwnWindowSemanticParityThirteenPagesAtNormalAndMinimumSizes() async throws {
        try await readOnlyOwnWindowSemanticParity(scope: .wholeWindow)
    }

    func testNativeWorkspacesReadOnlyValidatedApplicationContentSemanticParityThirteenPagesAtNormalAndMinimumSizes() async throws {
        try await readOnlyOwnWindowSemanticParity(scope: .applicationContent)
    }

    private func readOnlyOwnWindowSemanticParity(scope: NativeWorkspacePageCaptureObservationScope) async throws {
        defer { readOnlyObservationPhase = nil }
        let scopeSuffix = scope == .applicationContent ? "-application-content" : ""
        try await prepareHost()
        do {
            let viewports: [(label: String, size: NSSize)] = [
                ("normal", NSSize(width: 1_440, height: 900)),
                ("minimum", NSSize(width: 1_100, height: 720)),
            ]
            for viewport in viewports {
                try directEvidence.configure(testName: name + "-read-only-" + viewport.label + scopeSuffix)
                let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport.size)
                fixture = owned
                try await presentPhysicalCache(owned, expectedContentSize: viewport.size)
                XCTAssertEqual(NativeWorkspaceCapturePage.allCases.count, 13)
                var capturedPhases = 0
                for page in NativeWorkspaceCapturePage.allCases {
                    owned.route.page = page
                    readOnlyObservationPhase = viewport.label + ":default"
                    _ = try await requiredElement("workspace-controls-" + page.viewID, in: owned, scope: scope)
                    try await settle(page, in: owned, scope: scope)
                    try await captureReadOnlyOwnWindowPhase(page, in: owned, expectedContentSize: viewport.size, scope: scope,
                        expectedLayout: nil, allHidden: false, name: "\(page.rawValue)-\(viewport.label)-read-only-default\(scopeSuffix)")
                    capturedPhases += 1

                    let custom = try owned.customize(page.viewID)
                    readOnlyObservationPhase = viewport.label + ":custom"
                    try await requireCanvas(custom, in: owned)
                    try await settle(page, in: owned, scope: scope)
                    try await captureReadOnlyOwnWindowPhase(page, in: owned, expectedContentSize: viewport.size, scope: scope,
                        expectedLayout: custom, allHidden: false, name: "\(page.rawValue)-\(viewport.label)-read-only-custom\(scopeSuffix)")
                    capturedPhases += 1

                    var hiddenLayout = custom
                    for index in hiddenLayout.panels.indices {
                        try owned.preferences.setShown(false, for: hiddenLayout.panels[index].id, in: page.viewID)
                        hiddenLayout.panels[index].isVisible = false
                    }
                    readOnlyObservationPhase = viewport.label + ":all-hidden"
                    try await requireHiddenCanvas(hiddenLayout, in: owned)
                    try await captureReadOnlyOwnWindowPhase(page, in: owned, expectedContentSize: viewport.size, scope: scope,
                        expectedLayout: hiddenLayout, allHidden: true, name: "\(page.rawValue)-\(viewport.label)-read-only-all-hidden\(scopeSuffix)")
                    capturedPhases += 1

                    try owned.preferences.reset(page.viewID)
                    readOnlyObservationPhase = viewport.label + ":restored"
                    try await waitUntil("The read-only semantic custom document did not dismantle after reset") {
                        !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
                    }
                    _ = try await requiredElement("workspace-controls-" + page.viewID, in: owned, scope: scope)
                    try await settle(page, in: owned, scope: scope)
                    try await captureReadOnlyOwnWindowPhase(page, in: owned, expectedContentSize: viewport.size, scope: scope,
                        expectedLayout: nil, allHidden: false, name: "\(page.rawValue)-\(viewport.label)-read-only-restored\(scopeSuffix)")
                    capturedPhases += 1
                }
                let mutations = await owned.client.mutationNames()
                XCTAssertTrue(mutations.isEmpty, "Read-only semantic parity must not dispatch fixture mutations: \(mutations)")
                XCTAssertNil(owned.model.app)
                XCTAssertNil(owned.model.manager)
                XCTAssertNil(owned.model.remoteManager)
                XCTAssertFalse(owned.model.hasLoadedInitialSettings)
                guard capturedPhases == 52 else {
                    throw NativeWorkspacePageCaptureFailure("Read-only own-window parity omitted a route or phase")
                }
                let report = try JSONSerialization.data(withJSONObject: [
                    "classification": scope == .wholeWindow
                        ? "Read-only public AXUIElement parity of 13 direct production-page fixtures in one exact owned window; no active/key, semantic action, sidebar routing, desktop compositor or Metal qualification"
                        : "Read-only validated application-content public AX parity; only exact standard Zoom descendant expansion excluded; original whole-window gate remains separate",
                    "observation_scope": scope.rawValue, "viewport": viewport.label, "content_size": NSStringFromSize(viewport.size),
                    "captured_phases": capturedPhases, "route_count": 13, "phase_count_per_route": 4,
                    "application_active": NSApp.isActive, "window_key": owned.window.isKeyWindow,
                    "fixture_mutations": mutations.sorted(), "settings_ready": owned.model.hasLoadedInitialSettings,
                ], options: [.prettyPrinted, .sortedKeys])
                guard report.count <= 64 * 1_024 else {
                    throw NativeWorkspacePageCaptureFailure("Read-only own-window scope receipt exceeded its byte bound")
                }
                try directEvidence.save(report, name: "read-only-own-window-scope" + scopeSuffix, extension: "json")
                if !directEvidence.isEnabled {
                    let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
                    attachment.name = "read-only-own-window-scope" + scopeSuffix; attachment.lifetime = .keepAlways; add(attachment)
                }
                await owned.close()
                fixture = nil
            }
        } catch {
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    func testNativeWorkspacesCaptureThirteenProductionPagesDefaultCustomRestored() async throws {
        try await prepareHost()
        do {
            let viewports: [(label: String, size: NSSize)] = [
                ("normal", NSSize(width: 1_440, height: 900)),
                ("minimum", NSSize(width: 1_100, height: 720)),
            ]
            for viewport in viewports {
                try directEvidence.configure(testName: name + "-" + viewport.label)
                let owned = try NativeWorkspacePageCaptureFixture(contentSize: viewport.size)
                fixture = owned
                try await present(owned)
                XCTAssertEqual(NativeWorkspaceCapturePage.allCases.count, 13)
                for page in NativeWorkspaceCapturePage.allCases {
                    owned.route.page = page
                    if page == .rig { try captureForensicBoundary(owned, name: "forensic-first-mounted-" + viewport.label) }
                    _ = try await requiredElement("workspace-controls-" + page.viewID, in: owned)
                    try await settle(page, in: owned)
                    let baseline = try await semantics(in: owned)
                    try requireHeading(page.marker, title: page.title, panelID: nil, in: baseline)
                    if page == .runeForge { try requireHeading("rune-detail-heading", title: "Development Policy", panelID: nil, in: baseline) }
                    XCTAssertNil(owned.preferences.activeLayout(for: page.viewID))
                    try capture(owned, semantics: baseline, name: "\(page.rawValue)-\(viewport.label)-default")

                    let custom = try owned.customize(page.viewID)
                    try await requireCanvas(custom, in: owned)
                    let arranged = try await semantics(in: owned)
                    try requireHeading(page.marker, title: page.title, panelID: page.headingPanelID, in: arranged)
                    if page == .runeForge { try requireHeading("rune-detail-heading", title: "Development Policy", panelID: "rune-authority", in: arranged) }
                    try capture(owned, semantics: arranged, name: "\(page.rawValue)-\(viewport.label)-custom")

                    for placement in custom.panels { try owned.preferences.setShown(false, for: placement.id, in: page.viewID) }
                    try await requireHiddenCanvas(custom, in: owned)
                    let hidden = try await semantics(in: owned)
                    XCTAssertFalse(hidden.contains { $0.identifier == page.marker }, "Hidden page panels must leave the raw public native accessibility child tree")
                    try capture(owned, semantics: hidden, name: "\(page.rawValue)-\(viewport.label)-all-hidden")

                    try owned.preferences.reset(page.viewID)
                    try await waitUntil("The custom document did not dismantle after reset") {
                        !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
                    }
                    let restored = try await semantics(in: owned)
                    try requireHeading(page.marker, title: page.title, panelID: nil, in: restored)
                    if page == .runeForge { try requireHeading("rune-detail-heading", title: "Development Policy", panelID: nil, in: restored) }
                    XCTAssertNil(owned.preferences.activeLayout(for: page.viewID))
                    try capture(owned, semantics: restored, name: "\(page.rawValue)-\(viewport.label)-restored")
                }
                let mutations = await owned.client.mutationNames()
                XCTAssertTrue(mutations.isEmpty, "Presentation must not dispatch fake-manager mutations: \(mutations)")
                XCTAssertNil(owned.model.app)
                XCTAssertNil(owned.model.manager)
                XCTAssertNil(owned.model.remoteManager)
                XCTAssertFalse(owned.model.hasLoadedInitialSettings)
                await owned.close()
                fixture = nil
            }
        } catch {
            if let fixture { try? captureForensicBoundary(fixture, name: "forensic-terminal-failure") }
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    func testNativeWorkspacesCaptureNineManagerSectionsDefaultCustomRestoredAtMinimumSize() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name)
            let owned = try NativeWorkspacePageCaptureFixture(contentSize: NSSize(width: 1_100, height: 720))
            fixture = owned
            owned.route.page = .manager
            owned.model.setHost = "workspace-staged.invalid"
            owned.model.setPort = 4_321
            owned.model.setAllowedRoots = [owned.home.appendingPathComponent("project").path]
            let staged = stagedSettings(owned.model)
            try await present(owned)
            try captureForensicBoundary(owned, name: "forensic-first-mounted-manager-minimum")
            XCTAssertEqual(ManagerSettingsView.ManagementSection.allCases.count, 9)
            for section in ManagerSettingsView.ManagementSection.allCases {
                let navigation = try await requiredElement("manager-section-" + section.rawValue, in: owned)
                try performPress(navigation)
                let viewID = "manager." + section.rawValue
                _ = try await requiredElement("workspace-controls-" + viewID, in: owned)
                let baseline = try await semantics(in: owned)
                try requireHeading("detail-manager", title: section.title, panelID: nil, in: baseline)
                XCTAssertNil(owned.preferences.activeLayout(for: viewID))
                XCTAssertEqual(stagedSettings(owned.model), staged)
                try capture(owned, semantics: baseline, name: "manager-\(section.rawValue)-minimum-startup-default")

                let custom = try owned.customize(viewID)
                try await requireCanvas(custom, in: owned)
                let arranged = try await semantics(in: owned)
                try requireHeading("detail-manager", title: section.title, panelID: "manager-header", in: arranged)
                XCTAssertEqual(stagedSettings(owned.model), staged)
                try capture(owned, semantics: arranged, name: "manager-\(section.rawValue)-minimum-startup-custom")

                for placement in custom.panels { try owned.preferences.setShown(false, for: placement.id, in: viewID) }
                try await requireHiddenCanvas(custom, in: owned)
                let hidden = try await semantics(in: owned)
                XCTAssertFalse(hidden.contains { $0.identifier == "detail-manager" })
                XCTAssertEqual(stagedSettings(owned.model), staged)
                try capture(owned, semantics: hidden, name: "manager-\(section.rawValue)-minimum-startup-all-hidden")

                try owned.preferences.reset(viewID)
                try await waitUntil("The Manager custom document did not dismantle after reset") {
                    !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
                }
                let restored = try await semantics(in: owned)
                try requireHeading("detail-manager", title: section.title, panelID: nil, in: restored)
                XCTAssertEqual(stagedSettings(owned.model), staged)
                try capture(owned, semantics: restored, name: "manager-\(section.rawValue)-minimum-startup-restored")
            }
            XCTAssertFalse(owned.model.hasLoadedInitialSettings,
                           "This capture fixture must preserve startup-unavailable settings gating")
            XCTAssertNil(owned.model.app)
            XCTAssertNil(owned.model.manager)
            XCTAssertNil(owned.model.remoteManager)
            let mutations = await owned.client.mutationNames()
            XCTAssertTrue(mutations.isEmpty)
        } catch {
            if let fixture { try? captureForensicBoundary(fixture, name: "forensic-terminal-failure") }
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    func testManagerDoctorResultHeadingSurvivesDefaultCustomAndRestore() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name)
            let owned = try NativeWorkspacePageCaptureFixture(contentSize: NSSize(width: 1_440, height: 900))
            fixture = owned
            owned.route.page = .manager
            try await present(owned)
            try performPress(try await requiredElement("manager-section-doctor", in: owned))
            _ = try await requiredElement("workspace-controls-manager.doctor", in: owned)
            guard owned.model.app == nil, owned.model.manager == nil, owned.model.remoteManager == nil else {
                throw NativeWorkspacePageCaptureFailure("Doctor parity requires the isolated unavailable manager fixture")
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var doctorAction: NativeWorkspacePageCaptureElement?
            repeat {
                let actions = try await semantics(in: owned).filter {
                    $0.role == NSAccessibility.Role.button.rawValue && self.matchesProviderText($0, "Run doctor")
                }
                guard actions.count <= 1 else {
                    throw NativeWorkspacePageCaptureFailure("The Doctor page exposed duplicate Run doctor buttons")
                }
                if let action = actions.first { doctorAction = action.element; break }
                try await Task.sleep(for: .milliseconds(20))
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard let doctorAction else {
                throw NativeWorkspacePageCaptureFailure("The real Run doctor action did not mount before its deadline")
            }
            try performPress(doctorAction)
            try await requireProviderText("Doctor ISSUES", panelID: nil, in: owned)
            try await requireProviderText("doctor failed", panelID: nil, in: owned)
            let baseline = try await semantics(in: owned)
            try requireHeading("detail-manager", title: "Doctor", panelID: nil, in: baseline)
            XCTAssertNil(owned.preferences.activeLayout(for: "manager.doctor"))
            try capture(owned, semantics: baseline, name: "manager-doctor-result-default")

            let custom = try owned.customize("manager.doctor")
            try await requireCanvas(custom, in: owned)
            let reportFrame = NativeWorkspaceFrame(x: 340, y: 220, width: 920, height: 540)
            try owned.preferences.setFrame(reportFrame, for: "manager-doctor-report", in: "manager.doctor")
            for panel in custom.panels where !["manager-header", "manager-doctor-report"].contains(panel.id) {
                try owned.preferences.setShown(false, for: panel.id, in: "manager.doctor")
            }
            try await waitUntil("The visible custom Doctor report did not apply its capture frame") {
                owned.hosting.layoutSubtreeIfNeeded()
                let documents = self.nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
                guard documents.count == 1, let report = documents.first?.panelHosts["manager-doctor-report"] else { return false }
                return !report.isHidden && report.hostingView.window === owned.window
                    && report.frame == NSRect(x: reportFrame.x, y: reportFrame.y,
                                              width: reportFrame.width, height: reportFrame.height)
            }
            try await requireProviderText("Doctor ISSUES", panelID: "manager-doctor-report", in: owned)
            try await requireProviderText("doctor failed", panelID: "manager-doctor-report", in: owned)
            let arranged = try await semantics(in: owned)
            try requireHeading("detail-manager", title: "Doctor", panelID: "manager-header", in: arranged)
            XCTAssertEqual(owned.preferences.activeLayout(for: "manager.doctor")?.id, custom.id)
            try capture(owned, semantics: arranged, name: "manager-doctor-result-custom")

            try owned.preferences.reset("manager.doctor")
            try await waitUntil("The Doctor custom document did not dismantle after reset") {
                !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
            }
            try await requireProviderText("Doctor ISSUES", panelID: nil, in: owned)
            try await requireProviderText("doctor failed", panelID: nil, in: owned)
            let restored = try await semantics(in: owned)
            try requireHeading("detail-manager", title: "Doctor", panelID: nil, in: restored)
            XCTAssertNil(owned.preferences.activeLayout(for: "manager.doctor"))
            try capture(owned, semantics: restored, name: "manager-doctor-result-restored")
            let mutations = await owned.client.mutationNames()
            XCTAssertTrue(mutations.isEmpty)
            XCTAssertNil(owned.model.app)
            XCTAssertNil(owned.model.manager)
            XCTAssertNil(owned.model.remoteManager)
        } catch {
            if let fixture { try? captureForensicBoundary(fixture, name: "forensic-terminal-failure") }
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    func testPopulatedProviderAdvancedWorkflowNoteSurvivesDefaultCustomAndRestore() async throws {
        try await prepareHost()
        do {
            try directEvidence.configure(testName: name)
            let owned = try NativeWorkspacePageCaptureFixture(contentSize: NSSize(width: 1_440, height: 900),
                                                               populatedProvider: true)
            fixture = owned
            owned.route.page = .provider
            try await present(owned)
            _ = try await requiredElement("workspace-controls-provider", in: owned)
            try await waitUntilAsync("The populated Provider fixture did not finish its public reads") {
                await owned.client.providerDidLoad()
            }
            let initiallyCollapsed = try await semantics(in: owned)
            XCTAssertFalse(initiallyCollapsed.contains { self.matchesProviderText($0, self.providerWorkflowText) },
                           "The conditional workflow footer must start absent before Advanced is opened")
            let advanced = try await requiredElement("provider-advanced-toggle", in: owned)
            try performPress(advanced)
            try await requireProviderText("Provider settings", panelID: nil, in: owned)
            try await requireProviderFieldValue("provider-endpoint", value: "http://127.0.0.1:4321", in: owned)
            try await requireProviderFieldValue("provider-model-key", value: "fixture/advanced-parity-model", in: owned)
            try await requireProviderContractFacts(panelID: nil, in: owned)
            let defaultAdvanced = try await semantics(in: owned)
            try requireHeading("detail-provider", title: "Provider", panelID: nil, in: defaultAdvanced)
            XCTAssertNil(owned.preferences.activeLayout(for: "provider"))
            try capture(owned, semantics: defaultAdvanced, name: "provider-populated-advanced-default")

            let custom = try owned.customize("provider")
            try await requireCanvas(custom, in: owned)
            let contractFrame = NativeWorkspaceFrame(x: 20, y: 300, width: 1_120, height: 500)
            try owned.preferences.setFrame(contractFrame, for: "provider-contract", in: "provider")
            for placement in custom.panels where !["provider-controls", "provider-contract"].contains(placement.id) {
                try owned.preferences.setShown(false, for: placement.id, in: "provider")
            }
            try owned.preferences.bringToFront("provider-contract", in: "provider")
            try await waitUntil("The real custom contract panel did not apply its visible capture frame") {
                owned.hosting.layoutSubtreeIfNeeded()
                let documents = self.nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
                guard documents.count == 1, let document = documents.first,
                      let panel = document.panelHosts["provider-contract"] else { return false }
                panel.layoutSubtreeIfNeeded()
                return !panel.isHidden && panel.hostingView.window === owned.window
                    && panel.frame == NSRect(x: contractFrame.x, y: contractFrame.y,
                                             width: contractFrame.width, height: contractFrame.height)
            }
            try await requireProviderContractFacts(panelID: "provider-contract", in: owned)
            let customAdvanced = try await semantics(in: owned)
            try requireHeading("detail-provider", title: "Provider", panelID: "provider-controls", in: customAdvanced)
            XCTAssertEqual(owned.preferences.activeLayout(for: "provider")?.id, custom.id)
            try capture(owned, semantics: customAdvanced, name: "provider-populated-advanced-custom-contract")

            try performPress(try await requiredElement("provider-advanced-toggle", in: owned))
            try await requireProviderText("Inspect LM Studio and open LM Studio Advanced in the Provider and Actions panel to display these settings.",
                                          panelID: "provider-contract", in: owned)
            let customCollapsed = try await semantics(in: owned)
            XCTAssertFalse(customCollapsed.contains { self.matchesProviderText($0, self.providerWorkflowText) },
                           "Closing Advanced must remove the conditional workflow footer from the raw public child tree")
            try capture(owned, semantics: customCollapsed, name: "provider-populated-advanced-custom-collapsed")
            try performPress(try await requiredElement("provider-advanced-toggle", in: owned))
            try await requireProviderContractFacts(panelID: "provider-contract", in: owned)
            let reopened = try await semantics(in: owned)
            try capture(owned, semantics: reopened, name: "provider-populated-advanced-custom-reopened")

            try owned.preferences.reset("provider")
            try await waitUntil("The Provider custom document did not dismantle after reset") {
                !self.nativeViews(owned.hosting).contains { $0 is NativeWorkspaceDocumentView }
            }
            try await requireProviderContractFacts(panelID: nil, in: owned)
            let restored = try await semantics(in: owned)
            try requireHeading("detail-provider", title: "Provider", panelID: nil, in: restored)
            XCTAssertNil(owned.preferences.activeLayout(for: "provider"))
            try capture(owned, semantics: restored, name: "provider-populated-advanced-restored-default")
            let mutations = await owned.client.mutationNames()
            XCTAssertTrue(mutations.isEmpty, "Advanced presentation must not submit provider mutations: \(mutations)")
            XCTAssertNil(owned.model.app)
            XCTAssertNil(owned.model.manager)
            XCTAssertNil(owned.model.remoteManager)
        } catch {
            try? retainFailure(error)
            await restoreHost()
            throw error
        }
        await restoreHost()
    }

    private var providerWorkflowText: String {
        "Connect and Check uses one manager-owned path for model discovery, LM Studio recovery, Forge MCP registration, and contract verification."
    }

    private func matchesProviderText(_ element: NativeWorkspacePageCaptureSemantic, _ text: String) -> Bool {
        element.value == text || element.label == text || element.title == text
    }

    private func requireProviderText(_ text: String, panelID: String?,
                                     in owned: NativeWorkspacePageCaptureFixture) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let elements = try await semantics(in: owned)
            if elements.contains(where: { element in
                self.matchesProviderText(element, text)
                    && (panelID.map { element.ancestors.contains("workspace-panel-" + $0) } ?? true)
            }) { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NativeWorkspacePageCaptureFailure("Exact populated Provider text is absent from its expected panel scope: \(text)")
    }

    private func requireProviderFieldValue(_ identifier: String, value: String,
                                           in owned: NativeWorkspacePageCaptureFixture) async throws {
        let field = try await requiredElement(identifier, in: owned)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if try field.copyAccessibilityValue() as? String == value { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NativeWorkspacePageCaptureFailure("The populated Provider configuration did not reach the actual field: " + identifier)
    }

    private func requireProviderContractFacts(panelID: String?,
                                              in owned: NativeWorkspacePageCaptureFixture) async throws {
        let exactTexts = ["Lifecycle and contract", "Lifecycle management", "Yes", "Idle TTL", "73s",
            "Contract fingerprint", String(repeating: "a", count: 64), "Last probe mode", "contract",
            "Probe result storage", "In memory only (cleared on manager restart)",
            "Last probe", "2026-10-09T12:34:56Z", providerWorkflowText]
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let elements = try await semantics(in: owned)
            let scoped = elements.filter { element in
                panelID.map { element.ancestors.contains("workspace-panel-" + $0) } ?? true
            }
            if exactTexts.allSatisfy({ text in scoped.contains { self.matchesProviderText($0, text) } }) { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NativeWorkspacePageCaptureFailure("The exact populated Provider contract facts and workflow footer did not appear together in their expected panel scope")
    }

    private func settle(_ page: NativeWorkspaceCapturePage, in owned: NativeWorkspacePageCaptureFixture,
                        scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow) async throws {
        switch page {
        case .projects:
            try await waitUntilAsync("The Projects fixture did not complete snapshot and queue reads") {
                await owned.client.projectsDidLoad()
            }
            try await requiredText("Workspace Fixture Project", in: owned, scope: scope)
        case .provider:
            try await requiredText("No LM Studio settings are saved. Open LM Studio Advanced to configure it.", in: owned, scope: scope)
        case .runtimes:
            try await requiredText("settings is intentionally unavailable in the isolated native page capture fixture", in: owned, scope: scope)
        case .continuity:
            try await requiredText("Continuity packet listing is unavailable from this manager client.", in: owned, scope: scope)
        case .runeForge:
            try await requiredText("Rune Forge is unavailable from this manager client.", in: owned, scope: scope)
        case .evidence:
            try await requiredText("No Events", in: owned, scope: scope)
        default: break
        }
    }

    private func stagedSettings(_ model: AppModel) -> ManagerSettingsPatch {
        ManagerSettingsPatch(dashboardHost: model.setHost, dashboardPort: model.setPort,
            dashboardRefreshSec: model.setRefresh, autoRestart: model.setAutoRestart,
            watchdogIntervalSec: model.setWatchdog, sessionIdleTTLSec: model.setIdleTTL,
            continuityRolloverToolCalls: model.setContinuityRolloverToolCalls,
            shellEnabled: model.setShellEnabled, shellTimeoutSec: model.setShellTimeout,
            allowedRoots: model.setAllowedRoots)
    }

    private func prepareHost() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw NativeWorkspacePageCaptureFailure("Run in the native ForgeConductorAppTests application host with a display")
        }
        originalWindows = NSApp.windows.filter(\.isVisible)
        for window in originalWindows { window.orderOut(nil) }
    }

    private func restoreHost() async {
        if let fixture { await fixture.close() }
        fixture = nil
        for window in originalWindows { window.orderFront(nil) }
        originalWindows.removeAll()
    }

    // These cases observe owned NSView geometry and bitmap caches, without input or semantic actions.
    private func presentPhysicalCache(_ owned: NativeWorkspacePageCaptureFixture,
                                      expectedContentSize: NSSize) async throws {
        guard expectedContentSize == NSSize(width: 1_440, height: 900)
                || expectedContentSize == NSSize(width: 1_100, height: 720) else {
            throw NativeWorkspacePageCaptureFailure("Unexpected physical-cache viewport size")
        }
        owned.window.center()
        owned.window.orderFrontRegardless()
        try await waitUntil("The exact physical-cache owner must be visible, exposed, laid out and bootstrap-settled", timeout: 5) {
            owned.hosting.layoutSubtreeIfNeeded()
            return self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize)
        }
    }

    private func physicalCachePresentationIsReady(_ owned: NativeWorkspacePageCaptureFixture,
                                                  expectedContentSize: NSSize) -> Bool {
        let bounds = owned.hosting.bounds
        return owned.window.contentView === owned.hosting && owned.hosting.window === owned.window
            && owned.window.isVisible && owned.window.occlusionState.contains(.visible)
            && !owned.window.isMiniaturized && owned.window.screen != nil
            && !owned.hosting.isHiddenOrHasHiddenAncestor && !owned.model.isBootstrapping
            && bounds.origin == .zero && bounds.width.isFinite && bounds.height.isFinite
            && abs(bounds.width - expectedContentSize.width) <= 0.1
            && abs(bounds.height - expectedContentSize.height) <= 0.1
    }

    private func capturePhysicalCache(_ owned: NativeWorkspacePageCaptureFixture,
                                      expectedContentSize: NSSize, name: String) throws {
        owned.hosting.layoutSubtreeIfNeeded()
        guard physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize) else {
            let parent = owned.hosting.superview
            let report: [String: Any] = [
                "classification": "Diagnostic only: exact physical-cache geometry prerequisite failed",
                "route": owned.route.page.rawValue, "capture_name": String(name.prefix(256)),
                "expected_content": NSStringFromSize(expectedContentSize),
                "host_frame": NSStringFromRect(owned.hosting.frame), "host_bounds": NSStringFromRect(owned.hosting.bounds),
                "host_autoresizing_mask": owned.hosting.autoresizingMask.rawValue,
                "host_autoresizes_subviews": owned.hosting.autoresizesSubviews,
                "host_translates_autoresizing_mask": owned.hosting.translatesAutoresizingMaskIntoConstraints,
                "host_sizing_options": owned.hosting.sizingOptions.rawValue,
                "window_frame": NSStringFromRect(owned.window.frame), "window_content_layout": NSStringFromRect(owned.window.contentLayoutRect),
                "window_content_min": NSStringFromSize(owned.window.contentMinSize), "window_content_max": NSStringFromSize(owned.window.contentMaxSize),
                "exact_content_owner": owned.window.contentView === owned.hosting, "exact_host_window": owned.hosting.window === owned.window,
                "superview_type": parent.map { String(String(reflecting: type(of: $0)).prefix(256)) as Any } ?? NSNull(),
                "superview_frame": parent.map { NSStringFromRect($0.frame) as Any } ?? NSNull(),
                "superview_bounds": parent.map { NSStringFromRect($0.bounds) as Any } ?? NSNull(),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), data.count <= 64 * 1_024 {
                try? directEvidence.save(data, name: name + "-physical-geometry-failure", extension: "json")
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = name + "-physical-geometry-failure"; attachment.lifetime = .keepAlways; add(attachment)
            }
            throw NativeWorkspacePageCaptureFailure("The physical-cache owner or exact viewport changed before capture")
        }
        try capture(owned, semantics: [], name: name, diagnosticOnly: true)
    }

    private func present(_ owned: NativeWorkspacePageCaptureFixture) async throws {
        NSApp.activate(ignoringOtherApps: true)
        owned.window.center()
        owned.window.makeKeyAndOrderFront(nil)
        owned.window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        do {
            try await waitUntil("The actual fixture window must become active and exposed", timeout: 5) {
                NSApp.isActive && owned.window.isKeyWindow && owned.window.occlusionState.contains(.visible)
            }
        } catch {
            let windows = NSApp.windows
            let currentApplication = NSRunningApplication.current
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            let report: [String: Any] = [
                "classification": "Diagnostic only: failed actual fixture presentation prerequisite; no accessibility query or parity qualification",
                "route": owned.route.page.rawValue, "sample_uptime": ProcessInfo.processInfo.systemUptime,
                "original_error": String(String(reflecting: error).prefix(2_048)),
                "original_error_type": String(reflecting: type(of: error)),
                "application_active": NSApp.isActive, "application_hidden": NSApp.isHidden,
                "activation_policy": NSApp.activationPolicy().rawValue,
                "current_running_pid": currentApplication.processIdentifier,
                "current_running_bundle": currentApplication.bundleIdentifier.map { String($0.prefix(256)) as Any } ?? NSNull(),
                "current_running_active": currentApplication.isActive, "current_running_hidden": currentApplication.isHidden,
                "current_running_finished_launching": currentApplication.isFinishedLaunching, "current_running_terminated": currentApplication.isTerminated,
                "current_running_policy": currentApplication.activationPolicy.rawValue, "current_running_owns_menu_bar": currentApplication.ownsMenuBar,
                "frontmost_running_pid": frontmostApplication.map { $0.processIdentifier as Any } ?? NSNull(),
                "frontmost_running_bundle": frontmostApplication.flatMap { $0.bundleIdentifier }.map { String($0.prefix(256)) as Any } ?? NSNull(),
                "frontmost_running_active": frontmostApplication.map { $0.isActive as Any } ?? NSNull(),
                "frontmost_running_finished_launching": frontmostApplication.map { $0.isFinishedLaunching as Any } ?? NSNull(),
                "frontmost_running_policy": frontmostApplication.map { $0.activationPolicy.rawValue as Any } ?? NSNull(),
                "frontmost_running_owns_menu_bar": frontmostApplication.map { $0.ownsMenuBar as Any } ?? NSNull(),
                "frontmost_running_is_current": frontmostApplication.map { $0.isEqual(currentApplication) as Any } ?? NSNull(),
                "predicate_window_key": owned.window.isKeyWindow,
                "predicate_window_exposed": owned.window.occlusionState.contains(.visible),
                "window_visible": owned.window.isVisible, "window_main": owned.window.isMainWindow,
                "window_can_become_key": owned.window.canBecomeKey, "window_can_become_main": owned.window.canBecomeMain,
                "window_miniaturized": owned.window.isMiniaturized, "window_number": owned.window.windowNumber,
                "window_occlusion_raw": owned.window.occlusionState.rawValue, "window_frame": NSStringFromRect(owned.window.frame),
                "hosting_bounds": NSStringFromRect(owned.hosting.bounds), "hosting_hidden": owned.hosting.isHiddenOrHasHiddenAncestor,
                "exact_content_owner": owned.window.contentView === owned.hosting, "exact_host_window": owned.hosting.window === owned.window,
                "screen_frame": owned.window.screen.map { NSStringFromRect($0.frame) as Any } ?? NSNull(),
                "application_key_window_number": NSApp.keyWindow.map { $0.windowNumber as Any } ?? NSNull(),
                "model_bootstrapping": owned.model.isBootstrapping,
                "model_last_error": owned.model.lastError.map { String($0.prefix(2_048)) as Any } ?? NSNull(),
                "owned_window_count": windows.count, "owned_window_sample_truncated": windows.count > 16,
                "owned_window_sample": windows.prefix(16).map { window -> [String: Any] in
                    ["number": window.windowNumber, "fixture": window === owned.window, "visible": window.isVisible,
                     "key": window.isKeyWindow, "main": window.isMainWindow,
                     "occlusion_raw": window.occlusionState.rawValue, "frame": NSStringFromRect(window.frame)]
                },
            ]
            if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), json.count <= 64 * 1_024 {
                try? directEvidence.save(json, name: "failed-presentation-prerequisite", extension: "json")
                if !directEvidence.isEnabled { let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json"); attachment.name = "failed-presentation-prerequisite"; attachment.lifetime = .keepAlways; add(attachment) }
            }
            throw error
        }
        owned.hosting.layoutSubtreeIfNeeded()
        try await waitUntil("The isolated cancellation bootstrap did not finish", timeout: 5) {
            !owned.model.isBootstrapping
        }
    }

    private func requireCanvas(_ layout: NativeWorkspaceLayout, in owned: NativeWorkspacePageCaptureFixture) async throws {
        try await waitUntil("The real native canvas did not apply every admitted placement", timeout: 5) {
            owned.hosting.layoutSubtreeIfNeeded()
            let documents = self.nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            guard documents.count == 1, let document = documents.first else { return false }
            return Set(document.panelHosts.keys) == Set(layout.panels.map(\.id))
        }
        let document = try XCTUnwrap(nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }.first)
        let descriptors = try XCTUnwrap(NativeWorkspaceCatalog.panelsByView[layout.viewID])
        XCTAssertEqual(document.panelHosts.count, descriptors.count)
        for descriptor in descriptors {
            let panel = try XCTUnwrap(document.panelHosts[descriptor.id])
            panel.layoutSubtreeIfNeeded()
            XCTAssertFalse(panel.isHidden)
            XCTAssertEqual(panel.frame.width, descriptor.defaultFrame.width, accuracy: 0.1)
            XCTAssertEqual(panel.frame.height, descriptor.defaultFrame.height, accuracy: 0.1)
            XCTAssertGreaterThanOrEqual(panel.frame.width, descriptor.minimumSize.width)
            XCTAssertGreaterThanOrEqual(panel.frame.height, descriptor.minimumSize.height)
            XCTAssertLessThanOrEqual(panel.frame.width, descriptor.maximumSize.width)
            XCTAssertLessThanOrEqual(panel.frame.height, descriptor.maximumSize.height)
            XCTAssertEqual(panel.hostingView.frame.width, panel.bounds.width - 2, accuracy: 0.1)
            XCTAssertEqual(panel.hostingView.frame.height, panel.bounds.height - 49, accuracy: 0.1)
            XCTAssertTrue(panel.hostingView.window === owned.window)
        }
    }

    private func capture(_ owned: NativeWorkspacePageCaptureFixture,
                         semantics: [NativeWorkspacePageCaptureSemantic], name: String, diagnosticOnly: Bool = false,
                         scopeProgress: [String: Any]? = nil) throws {
        owned.hosting.layoutSubtreeIfNeeded()
        let size = owned.hosting.bounds.size
        guard size.width > 0, size.height > 0, size.width <= 1_440, size.height <= 900,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                  pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NativeWorkspacePageCaptureFailure("The bounded native-view cache could not be allocated")
        }
        bitmap.size = size
        owned.hosting.cacheDisplay(in: owned.hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        guard png.count <= 16 * 1_024 * 1_024 else { throw NativeWorkspacePageCaptureFailure("Native cache exceeded its image byte budget") }
        var observation: [String: Any] = [
            "classification": diagnosticOnly
                ? "Direct production-page native-view cache and same-process public formal and informal AppKit accessibility observation; not external AXUIElement evidence, ContentView sidebar routing, ordinary desktop compositor, or Metal drawable readback"
                : "Direct production-page native-view cache and public AXUIElement observation of the exact own-process window; not ContentView sidebar routing, ordinary desktop compositor, or Metal drawable readback",
            "diagnostic_only": diagnosticOnly, "semantic_observation_qualified": !diagnosticOnly,
            "fixture_state": "isolated cancellation bootstrap; Manager settings remain startup-disabled",
            "route": owned.route.page.rawValue, "window": NSStringFromRect(owned.window.frame),
            "content": NSStringFromRect(owned.hosting.bounds), "application_active": NSApp.isActive,
            "window_key": owned.window.isKeyWindow, "window_visible": owned.window.isVisible,
            "settings_ready": owned.model.hasLoadedInitialSettings,
            "elements": semantics.map(\.dictionary),
        ]
        if let scopeProgress {
            observation["classification"] = "Direct production-page native-view cache and complete validated application-content AX snapshot; original whole-window, sidebar routing, desktop compositor and Metal gates remain separate"
            observation["application_content_scope"] = scopeProgress
        }
        let json = try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
        guard json.count <= 512 * 1_024 else { throw NativeWorkspacePageCaptureFailure("Native semantics exceeded its byte budget") }
        try directEvidence.save(png, name: name + "-native-view-cache", extension: "png")
        try directEvidence.save(json, name: name + "-native-semantics", extension: "json")
        if !directEvidence.isEnabled {
            let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            image.name = name + "-native-view-cache"; image.lifetime = .keepAlways; add(image)
            let text = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            text.name = name + "-native-semantics"; text.lifetime = .keepAlways; add(text)
        }
    }

    private func captureReadOnlyOwnWindowPhase(_ page: NativeWorkspaceCapturePage,
        in owned: NativeWorkspacePageCaptureFixture, expectedContentSize: NSSize,
        scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow,
        expectedLayout: NativeWorkspaceLayout?, allHidden: Bool, name: String) async throws {
        func requirePhaseOwner() throws {
            owned.hosting.layoutSubtreeIfNeeded()
            guard owned.route.page == page,
                  physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize),
                  owned.preferences.activeLayout(for: page.viewID) == expectedLayout else {
                throw NativeWorkspacePageCaptureFailure("Read-only semantic route, viewport, owner or selected layout changed")
            }
            let documents = nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            if let layout = expectedLayout {
                guard layout.viewID == page.viewID, !layout.panels.isEmpty,
                      layout.panels.allSatisfy({ $0.isVisible == !allHidden }),
                      documents.count == 1, let document = documents.first,
                      Set(document.panelHosts.keys) == Set(layout.panels.map(\.id)) else {
                    throw NativeWorkspacePageCaptureFailure("Read-only semantic custom phase lost its exact panel catalog")
                }
                for placement in layout.panels {
                    guard let host = document.panelHosts[placement.id], host.window === owned.window,
                          host.hostingView.window === owned.window, host.isHidden == !placement.isVisible,
                          host.frame == NSRect(x: placement.frame.x, y: placement.frame.y,
                              width: placement.frame.width, height: placement.frame.height) else {
                        throw NativeWorkspacePageCaptureFailure("Read-only semantic custom phase retained a stale frame or visibility")
                    }
                }
            } else if allHidden || !documents.isEmpty {
                throw NativeWorkspacePageCaptureFailure("Read-only semantic default phase retained a custom document")
            }
        }
        try requirePhaseOwner()
        var scopeProgress: [String: Any]?
        var requiredIDs: Set<String> = ["workspace-controls-" + page.viewID, page.marker]
        if page == .runeForge { requiredIDs.insert("rune-detail-heading") }
        let observed = try await observeOwnedSnapshot(in: owned, scope: scope,
            requiredIdentifiers: requiredIDs, retainScopeProgress: { scopeProgress = $0 })
        try requirePhaseOwner()
        guard !observed.isEmpty,
              observed.filter({ $0.role == kAXWindowRole && $0.title == owned.window.title }).count == 1,
              observed.filter({ $0.identifier == "workspace-controls-" + page.viewID }).count == 1 else {
            throw NativeWorkspacePageCaptureFailure("Read-only semantic snapshot lost the exact exported window or current route controls")
        }
        if allHidden {
            guard !observed.contains(where: { $0.identifier == page.marker || $0.ancestors.contains(page.marker) }),
                  page != .runeForge || !observed.contains(where: {
                      $0.identifier == "rune-detail-heading" || $0.ancestors.contains("rune-detail-heading")
                  }) else {
                throw NativeWorkspacePageCaptureFailure("All-hidden panels remained in the complete own-window AX snapshot")
            }
        } else {
            try requireHeading(page.marker, title: page.title,
                panelID: expectedLayout == nil ? nil : page.headingPanelID, in: observed)
            if page == .runeForge {
                try requireHeading("rune-detail-heading", title: "Development Policy",
                    panelID: expectedLayout == nil ? nil : "rune-authority", in: observed)
            }
            let settledText: String?
            switch page {
            case .projects: settledText = "Workspace Fixture Project"
            case .provider: settledText = "No LM Studio settings are saved. Open LM Studio Advanced to configure it."
            case .runtimes: settledText = "settings is intentionally unavailable in the isolated native page capture fixture"
            case .continuity: settledText = "Continuity packet listing is unavailable from this manager client."
            case .runeForge: settledText = "Rune Forge is unavailable from this manager client."
            case .evidence: settledText = "No Events"
            default: settledText = nil
            }
            if let settledText, !observed.contains(where: {
                $0.value == settledText || $0.label == settledText || $0.title == settledText
            }) {
                throw NativeWorkspacePageCaptureFailure("The original settled route content is absent from the fresh own-window snapshot: " + settledText)
            }
        }
        try requirePhaseOwner()
        try capture(owned, semantics: observed, name: name, scopeProgress: scopeProgress)
    }

    private func captureForensicBoundary(_ owned: NativeWorkspacePageCaptureFixture, name: String) throws {
        try capture(owned, semantics: [], name: name, diagnosticOnly: true)
        owned.hosting.layoutSubtreeIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let roots: [(String, NSObject)] = [("owned-NSWindow", owned.window), ("owned-NSHostingView", owned.hosting)]
        var observations: [[String: Any]] = []
        for (label, object) in roots {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeWorkspacePageCaptureFailure("Root forensic observation exceeded its finite deadline between public calls")
            }
            let formal = object as? any NSAccessibilityProtocol
            let formalChildren = formal?.accessibilityChildren()
            let physicalSubviews = (object as? NSView)?.subviews
            let names = object.accessibilityAttributeNames()
            let readsAllowed = names.count <= 256
            let advertisedChildren: Bool? = readsAllowed ? names.contains(.children) : nil
            let informalChildren = advertisedChildren == true ? object.accessibilityAttributeValue(.children) : nil
            let advertisedNavigation: Bool? = readsAllowed ? names.contains(.childrenInNavigationOrderAttribute) : nil
            let informalNavigationChildren = advertisedNavigation == true
                ? object.accessibilityAttributeValue(.childrenInNavigationOrderAttribute) : nil
            observations.append([
                "root": label, "object_type": String(describing: type(of: object)),
                "object_identity": String(describing: ObjectIdentifier(object)),
                "formal_protocol_conformance": formal != nil,
                "formal_identifier": forensicNullableString(formal?.accessibilityIdentifier()),
                "formal_children": forensicChildren(formalChildren),
                "formal_navigation_children": NSNull(),
                "formal_navigation_query_omitted": "The native root probe trapped converting an AppKit typed array containing NSAccessibilityReparentingCellProxy; only advertised raw informal navigation children are queried",
                "informal_navigation_children_advertised": advertisedNavigation.map { $0 as Any } ?? NSNull(),
                "informal_navigation_children": forensicChildren(informalNavigationChildren),
                "informal_attribute_count": names.count,
                "informal_attribute_read_bound_exceeded": !readsAllowed,
                "informal_attribute_names_sample": names.prefix(64).map { String($0.rawValue.prefix(128)) },
                "informal_attribute_names_sample_truncated": names.count > 64,
                "informal_children_advertised": advertisedChildren.map { $0 as Any } ?? NSNull(),
                "informal_children_read": advertisedChildren == true,
                "informal_identifier": readsAllowed && names.contains(.identifier)
                    ? forensicNullableString(object.accessibilityAttributeValue(.identifier) as? String) : NSNull(),
                "informal_children": forensicChildren(informalChildren),
                "physical_subview_count": physicalSubviews.map { $0.count as Any } ?? NSNull(),
                "physical_subview_type_sample": physicalSubviews?.prefix(16)
                    .map { String(describing: type(of: $0)) } ?? [],
            ])
        }
        let report: [String: Any] = [
            "classification": "Diagnostic native root API measurement; no page parity or external AX qualification",
            "route": owned.route.page.rawValue, "sample_uptime": ProcessInfo.processInfo.systemUptime,
            "window": NSStringFromRect(owned.window.frame), "content": NSStringFromRect(owned.hosting.bounds),
            "window_visible": owned.window.isVisible, "window_key": owned.window.isKeyWindow,
            "hosting_is_hidden_or_has_hidden_ancestor": owned.hosting.isHiddenOrHasHiddenAncestor,
            "window_owns_exact_hosting_view": owned.window.contentView === owned.hosting,
            "measured_root_count": roots.count, "child_sample_limit_per_root_and_API": 16,
            "query_order": ["diagnostic native view cache", "per root: formal children", "per root: informal attribute names", "per root: advertised informal children and navigation children", "concrete owned NSHostingView children"],
            "typed_owned_hosting_children": forensicChildren(owned.hosting.accessibilityChildren()),
            "typed_owned_hosting_navigation_children": NSNull(),
            "traversal_policy": "Measure both public APIs at the two exact native roots only; do not change observer traversal or normalize/drop children",
            "roots": observations,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard json.count <= 512 * 1_024 else {
            throw NativeWorkspacePageCaptureFailure("Root forensic semantics exceeded the existing JSON byte budget")
        }
        try directEvidence.save(json, name: name + "-root-forensics", extension: "json")
        if !directEvidence.isEnabled {
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = name + "-root-forensics"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func forensicNullableString(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func forensicChildren(_ rawValue: Any?) -> [String: Any] {
        guard let rawValue else {
            return ["value_is_nil": true, "value_type": NSNull(), "child_count": NSNull(), "sample": []]
        }
        guard let children = rawValue as? [Any] else {
            return ["value_is_nil": false, "value_type": String(describing: type(of: rawValue)),
                    "child_count": NSNull(), "sample": [], "advertised_value_is_array": false]
        }
        let sample: [[String: Any]] = children.prefix(16).map { child in
            ["object_type": String(describing: type(of: child)),
             "formal_protocol_conformance": child is any NSAccessibilityProtocol,
             "NSObject_informal_bridge_type": child is NSObject]
        }
        return ["value_is_nil": false, "value_type": String(describing: type(of: rawValue)),
                "advertised_value_is_array": true, "child_count": children.count,
                "sample": sample, "sample_truncated": children.count > 16]
    }

    private func requireHiddenCanvas(_ layout: NativeWorkspaceLayout, in owned: NativeWorkspacePageCaptureFixture) async throws {
        try await waitUntil("The retained native hosts did not become hidden") {
            owned.hosting.layoutSubtreeIfNeeded()
            let documents = self.nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            guard documents.count == 1, let document = documents.first else { return false }
            return Set(document.panelHosts.keys) == Set(layout.panels.map(\.id))
                && document.panelHosts.values.allSatisfy { $0.isHidden && $0.hostingView.isHiddenOrHasHiddenAncestor }
        }
    }

    private func requireHeading(_ marker: String, title: String, panelID: String?,
                                in elements: [NativeWorkspacePageCaptureSemantic]) throws {
        let matches = elements.filter { element in
            let scope = panelID.map { element.ancestors.contains("workspace-panel-" + $0) } ?? true
            return scope && (element.identifier == marker || element.ancestors.contains(marker))
                && (element.value == title || element.label == title || element.title == title)
        }
        guard !matches.isEmpty else {
            throw NativeWorkspacePageCaptureFailure("The exact production heading \(marker)/\(title) is absent from its admitted panel scope")
        }
    }

    private func requiredElement(_ identifier: String, in owned: NativeWorkspacePageCaptureFixture,
                                 scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow) async throws -> NativeWorkspacePageCaptureElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var lastObserved: [NativeWorkspacePageCaptureSemantic] = []
        repeat {
            let elements = try await semantics(in: owned, scope: scope, requiredIdentifiers: [identifier])
            lastObserved = elements
            let matches = elements.filter { $0.identifier == identifier }
            if matches.count == 1 { return matches[0].element }
            guard matches.count <= 1 else { throw NativeWorkspacePageCaptureFailure("Duplicate native action identifier: \(identifier)") }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        do { try await retainTraversalFailure(identifier, in: owned, lastObserved: lastObserved, scope: scope) }
        catch {
            let message = "Traversal diagnostic retention failed for \(identifier): \(error)"
            let attachment = XCTAttachment(string: String(message.prefix(4_096)))
            attachment.name = "traversal-diagnostic-retention-error"; attachment.lifetime = .keepAlways; add(attachment)
        }
        throw NativeWorkspacePageCaptureFailure("Native action did not mount: \(identifier)")
    }

    private func requiredText(_ text: String, in owned: NativeWorkspacePageCaptureFixture,
                              scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            let elements = try await semantics(in: owned, scope: scope)
            if elements.contains(where: { $0.value == text || $0.label == text || $0.title == text }) { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NativeWorkspacePageCaptureFailure("The fixture request completed but the actual page text did not render: \(text)")
    }

    private func semantics(in owned: NativeWorkspacePageCaptureFixture,
                           scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow,
                           requiredIdentifiers: Set<String> = []) async throws -> [NativeWorkspacePageCaptureSemantic] {
        owned.hosting.layoutSubtreeIfNeeded()
        return try await observeOwnedSnapshot(in: owned, scope: scope, requiredIdentifiers: requiredIdentifiers)
    }


    private func observeOwnedSnapshot(in owned: NativeWorkspacePageCaptureFixture,
                                      scope observationScope: NativeWorkspacePageCaptureObservationScope = .wholeWindow,
                                      requiredIdentifiers: Set<String> = [],
                                      retainScopeProgress: (@MainActor ([String: Any]) -> Void)? = nil) async throws -> [NativeWorkspacePageCaptureSemantic] {
        let page = owned.route.page
        let selectedLayout = owned.preferences.activeLayout(for: page.viewID)
        let expectedWindowFrame = owned.window.frame
        let expectedHostBounds = owned.hosting.bounds
        let scope = NativeWorkspacePageCaptureAXScope(window: owned.window, hosting: owned.hosting)
        do {
            let complete = try scope.observe(scope: observationScope, requiredIdentifiers: requiredIdentifiers,
                frameFailure: { self.retainAXFrameFailure($0, in: owned) })
            if observationScope == .applicationContent { retainScopeProgress?(scope.diagnosticProgress) }
            return complete
        } catch {
            await retainFailedSnapshotReacquisition(error, originalScope: scope, in: owned,
                page: page, selectedLayout: selectedLayout,
                expectedWindowFrame: expectedWindowFrame, expectedHostBounds: expectedHostBounds,
                scope: observationScope, requiredIdentifiers: requiredIdentifiers)
            throw error
        }
    }

    private func retainFailedSnapshotReacquisition(_ originalError: Error,
        originalScope: NativeWorkspacePageCaptureAXScope, in owned: NativeWorkspacePageCaptureFixture,
        page: NativeWorkspaceCapturePage, selectedLayout: NativeWorkspaceLayout?,
        expectedWindowFrame: NSRect, expectedHostBounds: NSRect,
        scope observationScope: NativeWorkspacePageCaptureObservationScope = .wholeWindow,
        requiredIdentifiers: Set<String> = []) async {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 5
        var report: [String: Any] = [
            "classification": "Diagnostic reacquisition after a failed complete own-window public AX traversal; the original error is always rethrown, even if the fresh diagnostic snapshot succeeds",
            "original_error": String(String(describing: originalError).prefix(4_096)),
            "original_scope_progress": originalScope.diagnosticProgress,
            "observation_scope": observationScope.rawValue,
            "expected_route": page.rawValue, "expected_view_id": page.viewID,
            "read_only_phase": readOnlyObservationPhase.map { $0 as Any } ?? NSNull(),
            "expected_window_frame": NSStringFromRect(expectedWindowFrame),
            "expected_host_bounds": NSStringFromRect(expectedHostBounds),
            "node_limit": 4_096, "depth_limit": 64, "messaging_seconds": 0.1,
            "diagnostic_total_deadline_seconds": 5,
            "fresh_complete_attempt_limit": 1, "actions_dispatched": false,
            "partial_snapshot_used_for_assertions": false,
            "process_trusted": AXIsProcessTrusted(),
        ]
        func ownerUnchanged() -> Bool {
            owned.route.page == page && owned.preferences.activeLayout(for: page.viewID) == selectedLayout
                && owned.window.contentView === owned.hosting && owned.hosting.window === owned.window
                && owned.window.frame == expectedWindowFrame && owned.hosting.bounds == expectedHostBounds
                && owned.window.isVisible && owned.window.occlusionState.contains(.visible)
                && !owned.hosting.isHiddenOrHasHiddenAncestor && !owned.model.isBootstrapping
                && expectedHostBounds.width.isFinite && expectedHostBounds.height.isFinite
                && expectedHostBounds.width > 0 && expectedHostBounds.height > 0
        }
        report["owner_route_layout_geometry_valid_before_yield"] = ownerUnchanged()
        do {
            let encodedLayout = try JSONEncoder().encode(selectedLayout)
            guard encodedLayout.count <= NativeWorkspaceLimits.maximumStoredBytes else {
                throw NativeWorkspacePageCaptureFailure("The diagnostic selected layout exceeded the existing storage bound")
            }
            report["expected_complete_selected_layout"] = try JSONSerialization.jsonObject(with: encodedLayout, options: [.fragmentsAllowed])
            guard ownerUnchanged() else {
                throw NativeWorkspacePageCaptureFailure("The original route, complete layout, viewport or native owner was no longer valid before diagnostic reacquisition")
            }
            // Suspend once using the same public finite wait used by this fixture;
            // this permits AppKit/concurrency work without changing an observation gate.
            try await Task.sleep(for: .milliseconds(20))
            guard ProcessInfo.processInfo.systemUptime < deadline, ownerUnchanged() else {
                throw NativeWorkspacePageCaptureFailure("The diagnostic yield changed its route/layout/owner/geometry or exhausted its total deadline")
            }
            let fresh = NativeWorkspacePageCaptureAXScope(window: owned.window, hosting: owned.hosting)
            do {
                let complete = try fresh.observe(deadline: deadline, scope: observationScope,
                    requiredIdentifiers: requiredIdentifiers)
                guard ownerUnchanged(), ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NativeWorkspacePageCaptureFailure("The fresh diagnostic snapshot changed its original route/layout/owner/geometry or exceeded its total deadline")
                }
                report["fresh_snapshot_completed"] = true
                report["fresh_complete_semantic_count"] = complete.count
                report["fresh_complete_snapshot"] = complete.map(\.dictionary)
            } catch {
                report["fresh_snapshot_completed"] = false
                report["fresh_error"] = String(String(describing: error).prefix(4_096))
            }
            report["fresh_scope_progress"] = fresh.diagnosticProgress
            if observationScope == .wholeWindow {
                report["typed_zoom_post_failure_diagnostic"] = originalScope.typedZoomPostFailureRelationships(
                    comparedTo: fresh, deadline: deadline, requiredIdentifiers: requiredIdentifiers,
                    ownerUnchanged: ownerUnchanged)
                report["copied_child_reference_witnesses"] = originalScope.copiedFailureIdentityWitnesses(comparedTo: fresh)
            }
            report["owner_route_layout_geometry_valid_after_attempt"] = ownerUnchanged()
        } catch {
            report["diagnostic_prerequisite_error"] = String(String(describing: error).prefix(4_096))
        }
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        report["current_route"] = owned.route.page.rawValue
        report["current_window_frame"] = NSStringFromRect(owned.window.frame)
        report["current_host_bounds"] = NSStringFromRect(owned.hosting.bounds)
        do {
            var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if data.count > 512 * 1_024 {
                report.removeValue(forKey: "fresh_complete_snapshot")
                report["fresh_snapshot_retention_error"] = "The complete diagnostic snapshot exceeded the existing 512 KiB JSON bound; it was not truncated or used for assertions"
                data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            }
            guard data.count <= 512 * 1_024 else {
                throw NativeWorkspacePageCaptureFailure("The failed-snapshot diagnostic exceeded its byte bound")
            }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "actual-own-window-ax-failed-snapshot-reacquisition"
            attachment.lifetime = .keepAlways; add(attachment)
            try directEvidence.save(data, name: "actual-own-window-ax-failed-snapshot-reacquisition", extension: "json")
        } catch {
            let attachment = XCTAttachment(string: String("Failed-snapshot diagnostic retention failed: \(error)".prefix(4_096)))
            attachment.name = "actual-own-window-ax-reacquisition-retention-error"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func retainAXFrameFailure(_ details: [String: Any], in owned: NativeWorkspacePageCaptureFixture) {
        var report = details
        report["route"] = owned.route.page.rawValue
        report["read_only_phase"] = readOnlyObservationPhase.map { $0 as Any } ?? NSNull()
        report["selected_layout_uuid"] = owned.preferences.activeLayout(for: owned.route.page.viewID)
            .map { $0.id.uuidString as Any } ?? NSNull()
        report["window_title"] = String(owned.window.title.prefix(256))
        report["window_frame"] = NSStringFromRect(owned.window.frame)
        report["hosting_bounds"] = NSStringFromRect(owned.hosting.bounds)
        report["exact_host_owner"] = owned.window.contentView === owned.hosting && owned.hosting.window === owned.window
        report["application_active"] = NSApp.isActive
        report["window_key"] = owned.window.isKeyWindow
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 64 * 1_024 else {
                throw NativeWorkspacePageCaptureFailure("AX frame diagnostic exceeded its 64 KiB bound")
            }
            do { try directEvidence.save(data, name: "actual-own-window-ax-frame-decode-failure", extension: "json") }
            catch {
                let retentionError = XCTAttachment(string: String("AX frame diagnostic file save failed: \(error)".prefix(2_048)))
                retentionError.name = "actual-own-window-ax-frame-file-save-error"
                retentionError.lifetime = .keepAlways; add(retentionError)
            }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "actual-own-window-ax-frame-decode-failure"; attachment.lifetime = .keepAlways; add(attachment)
        } catch {
            let attachment = XCTAttachment(string: String("AX frame diagnostic retention failed: \(error)".prefix(4_096)))
            attachment.name = "actual-own-window-ax-frame-decode-retention-error"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func formalSemantics(in owned: NativeWorkspacePageCaptureFixture) async throws -> [NativeWorkspacePageCaptureSemantic] {
        owned.hosting.layoutSubtreeIfNeeded()
        guard owned.window.contentView === owned.hosting else {
            throw NativeWorkspacePageCaptureFailure("The exact fixture window no longer owns its production hosting view")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var pending: [(NativeWorkspacePageCaptureElement, [String], Int)] = [(try .init(owned.window), [], 0)]
        var retained: [NativeWorkspacePageCaptureElement] = []
        var seen = Set<ObjectIdentifier>()
        var result: [NativeWorkspacePageCaptureSemantic] = []
        while let (element, pathAncestors, depth) = pending.popLast() {
            guard ProcessInfo.processInfo.systemUptime < deadline, retained.count < 4_096, depth <= 64 else {
                throw NativeWorkspacePageCaptureFailure("Native accessibility tree exceeded its explicit deadline/node/depth bound")
            }
            guard seen.insert(element.identity).inserted else { continue }
            retained.append(element)
            if traversalDiagnosticNodes != nil { traversalDiagnosticVisitedCount += 1 }
            let identifier = element.accessibilityIdentifier() ?? ""
            let role = element.accessibilityRole() ?? ""
            let title = element.accessibilityTitle() ?? ""
            let label = element.accessibilityLabel() ?? ""
            let rawValue = element.accessibilityValue()
            let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue ?? ""
            let parentAncestors = try accessibilityAncestorIDs(of: element, deadline: deadline)
            var ancestors = pathAncestors
            for identifier in parentAncestors where !ancestors.contains(identifier) { ancestors.append(identifier) }
            guard ancestors.count <= 64 else {
                throw NativeWorkspacePageCaptureFailure("Native accessibility identifier ancestry exceeded its bound")
            }
            if !identifier.isEmpty || !title.isEmpty || !label.isEmpty || !value.isEmpty {
                let frame = element.accessibilityFrame()
                result.append(.init(element: element, identifier: String(identifier.prefix(128)),
                    role: role, title: String(title.prefix(512)), label: String(label.prefix(512)),
                    value: String(value.prefix(512)), ancestors: ancestors, frame: frame,
                    exposed: element.isAccessibilityElement(), enabled: element.isAccessibilityEnabled()))
            }
            let nextAncestors = identifier.isEmpty ? pathAncestors : pathAncestors + [identifier]
            let children = try element.accessibilityChildren()
            if let samples = traversalDiagnosticNodes, samples.count < 64 {
                traversalDiagnosticNodes?.append(traversalDiagnostic(element, depth: depth,
                    selectedIdentifier: identifier, selectedRole: role, selectedTitle: title,
                    selectedLabel: label, selectedValue: value, observedUnionCount: children.count))
            }
            guard children.count <= 4_096 - retained.count - pending.count else {
                throw NativeWorkspacePageCaptureFailure("Native accessibility children exceeded their explicit remaining node budget")
            }
            for child in children.reversed() {
                let nativeChild = try NativeWorkspacePageCaptureElement(child)
                pending.append((nativeChild, nextAncestors, depth + 1))
            }
        }
        return result
    }

    private func retainTraversalFailure(_ identifier: String, in owned: NativeWorkspacePageCaptureFixture,
                                        lastObserved: [NativeWorkspacePageCaptureSemantic],
                                        scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow) async throws {
        traversalDiagnosticNodes = []; traversalDiagnosticVisitedCount = 0
        defer { traversalDiagnosticNodes = nil; traversalDiagnosticVisitedCount = 0 }
        var measured: [NativeWorkspacePageCaptureSemantic]?
        var measurementError: String?
        var formalMeasured: [NativeWorkspacePageCaptureSemantic]?
        var formalMeasurementError: String?
        do { measured = try await semantics(in: owned, scope: scope, requiredIdentifiers: [identifier]) }
        catch { measurementError = String(String(describing: error).prefix(4_096)) }
        do { formalMeasured = try await formalSemantics(in: owned) }
        catch { formalMeasurementError = String(String(describing: error).prefix(4_096)) }
        let samples = traversalDiagnosticNodes ?? []
        let report: [String: Any] = [
            "classification": "Diagnostic actual native traversal and public API comparison; missing-identifier assertion remains failed",
            "identifier": identifier, "route": owned.route.page.rawValue, "observation_scope": scope.rawValue,
            "sample_uptime": ProcessInfo.processInfo.systemUptime,
            "window_owns_exact_hosting_view": owned.window.contentView === owned.hosting,
            "node_sample_limit": 64, "visited_node_count": traversalDiagnosticVisitedCount,
            "sampled_node_count": samples.count, "node_sample_truncated": traversalDiagnosticVisitedCount > 64,
            "child_sample_limit_per_node_and_API": 4,
            "query_order": "Retain the last failed exported AX lookup; rerun the exact own-window AX observer; separately retain the original formal/informal child-union comparison and its bounded first64-node public API diagnostics",
            "observer_policy": "Assertions traverse exact own-process window AXChildren with CFEqual identity; the separate original formal/informal observer remains diagnostic and neither navigation nor contents is joined to either tree",
            "diagnostic_walk_error": measurementError.map { $0 as Any } ?? NSNull(),
            "last_failed_lookup_semantics": lastObserved.map(\.dictionary),
            "diagnostic_walk_semantics": measured.map { $0.map(\.dictionary) as Any } ?? NSNull(),
            "formal_comparison_error": formalMeasurementError.map { $0 as Any } ?? NSNull(),
            "formal_comparison_semantics": formalMeasured.map { $0.map(\.dictionary) as Any } ?? NSNull(),
            "visited_nodes": samples,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard json.count <= 512 * 1_024 else {
            throw NativeWorkspacePageCaptureFailure("Traversal diagnostic exceeded the existing JSON byte budget; full semantics were not truncated")
        }
        let name = "required-element-" + String(identifier.prefix(128)) + "-traversal-diagnostic"
        try directEvidence.save(json, name: name, extension: "json")
        if !directEvidence.isEnabled {
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func traversalDiagnostic(_ element: NativeWorkspacePageCaptureElement, depth: Int,
                                     selectedIdentifier: String, selectedRole: String, selectedTitle: String,
                                     selectedLabel: String, selectedValue: String,
                                     observedUnionCount: Int) -> [String: Any] {
        let object = element.object
        let formal = object as? any NSAccessibilityProtocol
        let informal = object as? NSObject
        let names = informal?.accessibilityAttributeNames()
        let readsAllowed = names.map { $0.count <= 256 } ?? false
        func legacy(_ attribute: NSAccessibility.Attribute) -> Any? {
            guard readsAllowed, names?.contains(attribute) == true else { return nil }
            return informal?.accessibilityAttributeValue(attribute)
        }
        return [
            "object_type": String(String(describing: type(of: object)).prefix(256)),
            "object_identity": String(describing: element.identity), "depth": depth,
            "observer_api": element.observationAPI, "observed_child_union_count": observedUnionCount,
            "observer_scalars": ["identifier": String(selectedIdentifier.prefix(128)),
                "role": String(selectedRole.prefix(128)), "title": String(selectedTitle.prefix(128)),
                "label": String(selectedLabel.prefix(128)), "value": String(selectedValue.prefix(128))],
            "formal_protocol_conformance": formal != nil,
            "formal_identifier": traversalScalar(formal?.accessibilityIdentifier()),
            "formal_role": traversalScalar(formal?.accessibilityRole()),
            "formal_title": traversalScalar(formal?.accessibilityTitle()),
            "formal_label": traversalScalar(formal?.accessibilityLabel()),
            "formal_value": traversalScalar(formal?.accessibilityValue()),
            "formal_children": traversalChildren(formal?.accessibilityChildren()),
            "formal_navigation_children": NSNull(),
            "formal_contents": NSNull(),
            "typed_collection_queries_omitted": "Diagnostic typed navigation and contents queries are omitted after the observed native root navigation array bridge trap; advertised raw informal values remain measured separately",
            "informal_attribute_count": names.map { $0.count as Any } ?? NSNull(),
            "informal_attribute_names_sample": names?.prefix(16).map { String($0.rawValue.prefix(128)) } ?? [],
            "informal_attribute_names_sample_truncated": names.map { $0.count > 16 } ?? false,
            "informal_attribute_read_bound_exceeded": names.map { $0.count > 256 } ?? false,
            "informal_identifier_advertised": names.map { $0.contains(.identifier) as Any } ?? NSNull(),
            "informal_identifier": traversalScalar(legacy(.identifier)),
            "informal_role": traversalScalar(legacy(.role)),
            "informal_title": traversalScalar(legacy(.title)),
            "informal_label": traversalScalar(legacy(.description)),
            "informal_value": traversalScalar(legacy(.value)),
            "informal_children_advertised": names.map { $0.contains(.children) as Any } ?? NSNull(),
            "informal_children": traversalChildren(legacy(.children)),
            "informal_navigation_children_advertised": names.map { $0.contains(.childrenInNavigationOrderAttribute) as Any } ?? NSNull(),
            "informal_navigation_children": traversalChildren(legacy(.childrenInNavigationOrderAttribute)),
            "informal_contents_advertised": names.map { $0.contains(.contents) as Any } ?? NSNull(),
            "informal_contents": traversalChildren(legacy(.contents)),
        ]
    }

    private func traversalScalar(_ raw: Any?) -> [String: Any] {
        let scalar = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? (raw as? NSAccessibility.Role)?.rawValue
        return ["value_is_nil": raw == nil,
                "value_type": raw.map { String(String(describing: type(of: $0)).prefix(256)) as Any } ?? NSNull(),
                "scalar": scalar.map { String($0.prefix(128)) as Any } ?? NSNull(),
                "scalar_truncated": scalar.map { $0.count > 128 } ?? false]
    }

    private func traversalChildren(_ raw: Any?) -> [String: Any] {
        guard let raw else { return ["value_is_nil": true, "child_count": NSNull(), "sample": []] }
        guard let children = raw as? [Any] else {
            return ["value_is_nil": false, "value_type": String(String(describing: type(of: raw)).prefix(256)),
                    "value_is_array": false, "child_count": NSNull(), "sample": []]
        }
        let sample: [[String: Any]] = children.prefix(4).map { child in
            let object: AnyObject?
            if let formal = child as? any NSAccessibilityProtocol { object = formal as AnyObject }
            else { object = child as? NSObject }
            return ["object_type": String(String(describing: type(of: child)).prefix(256)),
                    "object_identity": object.map { String(describing: ObjectIdentifier($0)) as Any } ?? NSNull(),
                    "formal_protocol_conformance": child is any NSAccessibilityProtocol,
                    "NSObject_informal_bridge_type": child is NSObject]
        }
        return ["value_is_nil": false, "value_type": String(String(describing: type(of: raw)).prefix(256)),
                "value_is_array": true, "child_count": children.count,
                "sample": sample, "sample_truncated": children.count > 4]
    }

    private func accessibilityAncestorIDs(of element: NativeWorkspacePageCaptureElement,
                                         deadline: TimeInterval) throws -> [String] {
        var current = element.accessibilityParent()
        var retained: [NativeWorkspacePageCaptureElement] = []
        var seen: Set<ObjectIdentifier> = [element.identity]
        var identifiers: [String] = []
        while let parent = current {
            guard ProcessInfo.processInfo.systemUptime < deadline, retained.count < 64 else {
                throw NativeWorkspacePageCaptureFailure("Native accessibility parent chain exceeded its explicit deadline/depth bound")
            }
            let nativeParent = try NativeWorkspacePageCaptureElement(parent)
            guard seen.insert(nativeParent.identity).inserted else { break }
            retained.append(nativeParent)
            if let identifier = nativeParent.accessibilityIdentifier(), !identifier.isEmpty {
                identifiers.append(identifier)
            }
            if nativeParent.object is NSWindow { break }
            current = nativeParent.accessibilityParent()
        }
        return Array(identifiers.reversed())
    }

    private func performPress(_ element: NativeWorkspacePageCaptureElement) throws {
        guard element.accessibilityRole() == NSAccessibility.Role.button.rawValue,
              element.isAccessibilityEnabled() == true else {
            throw NativeWorkspacePageCaptureFailure("The actual native Manager section did not expose an enabled button")
        }
        try element.performPress()
        // The caller waits for the exact selected section controls and heading.
        // Legacy public actions return Void; dispatch alone is not success proof.
    }

    private func nativeProjectsScrollerAdvertisements(_ layout: NativeWorkspaceLayout,
                                                      in owned: NativeWorkspacePageCaptureFixture,
                                                      expectedContentSize: NSSize,
                                                      deadline: TimeInterval) async throws {
        var stage = "owner", rows: [[String: Any]] = []
        var observationDeadline: TimeInterval?
        var report: [String: Any] = [
            "classification": "Read-only public advertisements on exact isolated Projects outer scrollers; no scroll action or input qualification",
            "view_id": "projects", "target_identifier": "workspace-resize-projects-summary",
            "viewport": scrollerActionBoundedString(NSStringFromSize(expectedContentSize), bytes: 512),
            "execution_completed": false, "actions_invoked": 0, "value_setters_invoked": 0,
            "direct_scroll_preparation": false, "pointer_input": false, "exported_ax_traversal": false,
            "maximum_case_seconds": 45, "case_deadline_uptime": deadline,
            "maximum_observation_seconds": 0.5, "maximum_total_objects": 64, "maximum_child_depth": 4,
            "maximum_parent_chain": 64, "maximum_actions_per_object": 64, "maximum_attributes_per_object": 256,
            "maximum_json_bytes": 64 * 1_024, "maximum_retained_rows_json_bytes": 48 * 1_024,
            "maximum_observation_receipt_bytes": 56 * 1_024, "reserved_failure_receipt_bytes": 8 * 1_024,
            "application_active": NSApp.isActive, "window_key": owned.window.isKeyWindow,
        ]
        func checkObservation() throws {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline, observationDeadline.map({ now < $0 }) ?? true else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement observation exceeded its case or 0.5-second deadline")
            }
        }
        func put(_ fields: [String: Any], in slot: Int) throws {
            var candidate = rows
            if slot == candidate.count { candidate.append(fields) }
            else { candidate[slot].merge(fields) { _, value in value } }
            let data = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
            var candidateReport = report; candidateReport["objects"] = candidate
            let completeData = try JSONSerialization.data(withJSONObject: candidateReport, options: [.sortedKeys])
            guard candidate.count <= 64, data.count <= 48 * 1_024, completeData.count <= 56 * 1_024 else {
                report["row_budget_rejected_slot"] = slot
                report["row_budget_rejected_bytes"] = data.count
                report["receipt_budget_rejected_bytes"] = completeData.count
                throw NativeWorkspacePageCaptureFailure("Projects advertisement rows exceeded their reserved JSON byte bound")
            }
            rows = candidate
            try checkObservation()
        }
        func textFields(_ value: String?, key: String, bytes: Int) -> [String: Any] {
            guard let value else { return [key: NSNull(), key + "_unknown": true] }
            return [key: scrollerActionBoundedString(value, bytes: bytes),
                    key + "_utf8_bytes": value.utf8.count, key + "_truncated": value.utf8.count > bytes]
        }
        func exactNames(_ values: [String], maximum: Int) throws -> [String] {
            guard values.count <= maximum, values.allSatisfy({ $0.utf8.count <= 128 }) else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement name count or exact UTF8 identity exceeded its bound")
            }
            return values
        }
        func objectBridge(_ value: Any) throws -> NSObject {
            guard Swift.type(of: value) is AnyClass, let object = value as? NSObject else {
                report["unsupported_bridge_type"] = scrollerActionBoundedString(String(reflecting: type(of: value)), bytes: 256)
                throw NativeWorkspacePageCaptureFailure("Projects advertised child/parent did not expose an actual NSObject reference")
            }
            return object
        }
        func retainReport(_ suffix: String) throws {
            report["last_stage"] = scrollerActionBoundedString(stage, bytes: 128)
            report["objects"] = rows; report["object_count"] = rows.count
            report["within_case_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
            var data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            if data.count > 64 * 1_024, suffix == "failed-diagnostic" {
                // Keep every retained row; escaped error text can consume more JSON bytes than UTF8 bytes.
                report["diagnostic_error_text_reduced_for_json_budget"] = true
                for key in ["original_error", "original_error_type", "failure_cache_error"] {
                    if let value = report[key] as? String {
                        report[key] = scrollerActionBoundedString(value, bytes: 128)
                        report[key + "_truncated_for_json_budget"] = value.utf8.count > 128
                    }
                }
                data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            }
            guard rows.count <= 64, data.count <= 64 * 1_024 else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement receipt exceeded its object/JSON bound")
            }
            let receiptName = "projects-native-scroller-advertisements-" + suffix
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = receiptName; attachment.lifetime = .keepAlways; add(attachment)
            try directEvidence.save(data, name: receiptName, extension: "json")
        }
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline, layout.viewID == "projects",
                  owned.route.page == .projects, layout.panels.count > 0, layout.panels.count <= 64,
                  layout.panels.allSatisfy(\.isVisible) else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement layout is not the bounded all-visible Projects fixture")
            }
            owned.hosting.layoutSubtreeIfNeeded()
            let documents = nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            guard documents.count == 1, let document = documents.first,
                  let scroll = document.enclosingScrollView, scroll.documentView === document,
                  document.superview === scroll.contentView, document.isFlipped,
                  scroll.hasHorizontalScroller, scroll.hasVerticalScroller,
                  let horizontal = scroll.horizontalScroller, let vertical = scroll.verticalScroller,
                  horizontal !== vertical, let panel = document.panelHosts["projects-summary"] else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement exact document/panel/scrollers are absent")
            }
            let identities = document.panelHosts.mapValues { ObjectIdentifier($0) }
            let documentFrame = document.frame, documentBounds = document.bounds
            let canvasSize = NSSize(width: layout.canvas.width, height: layout.canvas.height)
            let panelFrames = document.panelHosts.mapValues(\.frame)
            let hostingIdentities = document.panelHosts.mapValues { ObjectIdentifier($0.hostingView) }
            guard Set(identities.keys) == Set(layout.panels.map(\.id)),
                  documentFrame.size == canvasSize, documentBounds.origin == .zero,
                  documentBounds.size == canvasSize, layout.panels.allSatisfy({ placement in
                    document.panelHosts[placement.id]?.frame == NSRect(x: placement.frame.x, y: placement.frame.y,
                        width: placement.frame.width, height: placement.frame.height)
                  }) else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement catalog membership/frames/canvas differ from its layout")
            }
            panel.layoutSubtreeIfNeeded()
            let matches = nativeViews(panel).filter { $0.accessibilityIdentifier() == "workspace-resize-projects-summary" }
            guard matches.count == 1, let control = matches.first,
                  control.superview === panel, control.window === owned.window,
                  !control.isHiddenOrHasHiddenAncestor, control.bounds.width >= 8, control.bounds.height >= 8 else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement unique resize control is absent")
            }
            let controlFrame = control.frame, controlBounds = control.bounds
            let targetBounds = document.convert(control.bounds, from: control)
            let target = NSRect(x: targetBounds.midX - 4, y: targetBounds.midY - 4, width: 8, height: 8)
            let baseline = owned.preferences.collection
            let beforeBytes = try XCTUnwrap(owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let initialClip = scroll.contentView.bounds, initialVisible = document.visibleRect
            guard beforeBytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: beforeBytes) == baseline,
                  owned.preferences.activeLayout(for: "projects") == layout,
                  [targetBounds.minX, targetBounds.minY, targetBounds.width, targetBounds.height,
                   initialClip.minX, initialClip.minY, initialClip.width, initialClip.height].allSatisfy({ $0.isFinite }),
                  initialClip.width > 0, initialClip.height > 0, document.bounds.contains(target),
                  target.minX > initialVisible.maxX, target.minY > initialVisible.maxY else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement baseline storage or initially offscreen target is invalid")
            }
            func nativeParentChain(_ view: NSView, to owner: NSView) throws -> [String] {
                var current: NSView? = view, seen = Set<ObjectIdentifier>(), types: [String] = []
                while let next = current {
                    try checkObservation()
                    guard types.count < 64, seen.insert(ObjectIdentifier(next)).inserted,
                          next.window === owned.window else {
                        throw NativeWorkspacePageCaptureFailure("Projects advertisement native ancestry exceeded its bound or exact window")
                    }
                    types.append(scrollerActionBoundedString(String(reflecting: type(of: next)), bytes: 256))
                    if next === owner { return types }
                    current = next.superview
                }
                throw NativeWorkspacePageCaptureFailure("Projects advertisement native ancestry did not reach its exact owner")
            }
            func requireOwner() throws {
                try checkObservation()
                guard self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize),
                      owned.route.page == .projects, document.window === owned.window,
                      scroll.window === owned.window, document.enclosingScrollView === scroll,
                      scroll.documentView === document, document.superview === scroll.contentView,
                      document.frame == documentFrame, document.frame.size == canvasSize,
                      document.bounds == documentBounds, document.bounds.origin == .zero,
                      document.bounds.size == canvasSize,
                      scroll.horizontalScroller === horizontal, scroll.verticalScroller === vertical,
                      document.panelHosts.mapValues({ ObjectIdentifier($0) }) == identities,
                      document.panelHosts.mapValues(\.frame) == panelFrames,
                      document.panelHosts.mapValues({ ObjectIdentifier($0.hostingView) }) == hostingIdentities,
                      panel.superview === document, !panel.isHiddenOrHasHiddenAncestor,
                      control.superview === panel, control.window === owned.window,
                      !control.isHiddenOrHasHiddenAncestor, control.frame == controlFrame, control.bounds == controlBounds,
                      document.convert(control.bounds, from: control) == targetBounds,
                      scroll.contentView.bounds == initialClip, document.visibleRect == initialVisible,
                      owned.model.app == nil, owned.model.manager == nil, owned.model.remoteManager == nil,
                      !owned.model.hasLoadedInitialSettings, owned.preferences.collection == baseline,
                      owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
                    throw NativeWorkspacePageCaptureFailure("Projects advertisement owner/geometry/preferences changed")
                }
                _ = try nativeParentChain(horizontal, to: scroll); _ = try nativeParentChain(vertical, to: scroll)
                _ = try nativeParentChain(scroll, to: owned.hosting)
                try checkObservation()
            }
            func publicParentChain(_ child: NSObject, to root: NSScroller, slot: Int) throws -> [[String: Any]] {
                var current = child, seen = Set<ObjectIdentifier>(), chain: [[String: Any]] = []
                while true {
                    try checkObservation()
                    guard chain.count < 64, seen.insert(ObjectIdentifier(current)).inserted else {
                        throw NativeWorkspacePageCaptureFailure("Projects advertisement public parent chain cycled or exceeded 64 objects")
                    }
                    if let view = current as? NSView, view.window !== owned.window {
                        throw NativeWorkspacePageCaptureFailure("Projects advertisement child/parent NSView belongs to another window")
                    }
                    chain.append(["type": scrollerActionBoundedString(String(reflecting: type(of: current)), bytes: 256),
                                  "actual_identity": scrollerActionBoundedString(String(describing: ObjectIdentifier(current)), bytes: 128)])
                    try put(["public_parent_chain": chain], in: slot)
                    if current === root { try checkObservation(); return chain }
                    let parent: Any?
                    if let formal = current as? any NSAccessibilityProtocol {
                        parent = formal.accessibilityParent()
                    } else {
                        let attributes = current.accessibilityAttributeNames()
                        try checkObservation()
                        guard attributes.count <= 256 else {
                            throw NativeWorkspacePageCaptureFailure("Projects public parent attributes exceeded 256 names")
                        }
                        _ = try exactNames(attributes.map(\.rawValue), maximum: 256)
                        guard attributes.contains(.parent) else {
                            throw NativeWorkspacePageCaptureFailure("Projects advertised child has no supported public parent attribute")
                        }
                        try checkObservation()
                        parent = current.accessibilityAttributeValue(.parent)
                    }
                    try checkObservation()
                    guard let parent else {
                        throw NativeWorkspacePageCaptureFailure("Projects advertised child's public parent is unknown before its exact scroller")
                    }
                    current = try objectBridge(parent)
                }
            }
            try requireOwner()
            report["document_frame"] = scrollerActionBoundedString(NSStringFromRect(documentFrame), bytes: 512)
            report["document_bounds"] = scrollerActionBoundedString(NSStringFromRect(documentBounds), bytes: 512)
            report["initial_clip_bounds"] = scrollerActionBoundedString(NSStringFromRect(initialClip), bytes: 512)
            report["initial_document_visible"] = scrollerActionBoundedString(NSStringFromRect(initialVisible), bytes: 512)
            report["target_center_rect"] = scrollerActionBoundedString(NSStringFromRect(target), bytes: 512)
            report["control_bounds_in_document"] = scrollerActionBoundedString(NSStringFromRect(targetBounds), bytes: 512)
            report["horizontal_native_parent_chain"] = try nativeParentChain(horizontal, to: scroll)
            report["vertical_native_parent_chain"] = try nativeParentChain(vertical, to: scroll)
            report["outer_scroll_native_parent_chain"] = try nativeParentChain(scroll, to: owned.hosting)
            report["stored_bytes"] = beforeBytes.count; report["baseline_layout_count"] = baseline.layouts.count
            stage = "before-observation"
            try retainReport("before")
            try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: "projects-native-scroller-advertisements-before")
            try requireOwner()
            let started = ProcessInfo.processInfo.systemUptime
            let boundedObservationDeadline = min(deadline, started + 0.5)
            observationDeadline = boundedObservationDeadline
            report["observation_started_uptime"] = started
            report["observation_deadline_uptime"] = boundedObservationDeadline
            var pending: [(object: NSObject, root: NSScroller, axis: String, depth: Int)] = [
                (horizontal, horizontal, "horizontal", 0), (vertical, vertical, "vertical", 0)]
            var enqueued: [ObjectIdentifier: ObjectIdentifier] = [
                ObjectIdentifier(horizontal): ObjectIdentifier(horizontal), ObjectIdentifier(vertical): ObjectIdentifier(vertical)]
            var cursor = 0
            while cursor < pending.count {
                try requireOwner()
                let node = pending[cursor], slot = rows.count
                stage = node.axis + ".object-\(slot).advertisements"
                try put(["object_index": slot, "axis": node.axis, "depth": node.depth,
                    "type": scrollerActionBoundedString(String(reflecting: type(of: node.object)), bytes: 256),
                    "actual_identity": scrollerActionBoundedString(String(describing: ObjectIdentifier(node.object)), bytes: 128),
                    "exact_root_scroller": node.object === node.root, "public_parent_chain_verified": node.object === node.root,
                    "observation_started_uptime": ProcessInfo.processInfo.systemUptime], in: slot)
                if node.object !== node.root {
                    let chain = try publicParentChain(node.object, to: node.root, slot: slot)
                    try put(["public_parent_chain": chain, "public_parent_chain_verified": true], in: slot)
                }
                let actions = node.object.accessibilityActionNames()
                try put(["informal_action_count": actions.count], in: slot)
                guard actions.count <= 64 else {
                    throw NativeWorkspacePageCaptureFailure("Projects public actions exceeded 64 names")
                }
                try put(["informal_action_names": try exactNames(actions.map(\.rawValue), maximum: 64)], in: slot)
                let attributes = node.object.accessibilityAttributeNames()
                try put(["informal_attribute_count": attributes.count], in: slot)
                guard attributes.count <= 256 else {
                    throw NativeWorkspacePageCaptureFailure("Projects public attributes exceeded 256 names")
                }
                try put(["informal_attribute_names": try exactNames(attributes.map(\.rawValue), maximum: 256)], in: slot)
                var lists: [[Any]] = []
                if let formal = node.object as? any NSAccessibilityProtocol {
                    try put(["formal_bridge": true], in: slot)
                    try put(textFields(formal.accessibilityRole()?.rawValue, key: "formal_role", bytes: 128), in: slot)
                    try put(textFields(formal.accessibilitySubrole()?.rawValue, key: "formal_subrole", bytes: 128), in: slot)
                    try put(textFields(formal.accessibilityIdentifier(), key: "formal_identifier", bytes: 128), in: slot)
                    try put(textFields(formal.accessibilityTitle(), key: "formal_title", bytes: 256), in: slot)
                    try put(textFields(formal.accessibilityLabel(), key: "formal_label", bytes: 256), in: slot)
                    let orientation = formal.accessibilityOrientation()
                    try checkObservation()
                    try put(["formal_orientation_raw": orientation.rawValue,
                             "formal_orientation_known": orientation == .horizontal || orientation == .vertical,
                             "formal_accessibility_enabled": formal.isAccessibilityEnabled()], in: slot)
                    for spelling in ["accessibilityPerformIncrement", "accessibilityPerformDecrement", "accessibilityPerformPress"] {
                        try put([spelling + "_selector_allowed": formal.isAccessibilitySelectorAllowed(NSSelectorFromString(spelling))], in: slot)
                    }
                    let children = formal.accessibilityChildren()
                    try put(["formal_children_unknown": children == nil,
                             "formal_child_count": children.map { $0.count as Any } ?? NSNull()], in: slot)
                    if let children {
                        guard children.count <= 64 else {
                            throw NativeWorkspacePageCaptureFailure("Projects formal public children exceeded 64 entries")
                        }
                        lists.append(children)
                    }
                } else {
                    try put(["formal_bridge": false, "formal_role": NSNull(), "formal_subrole": NSNull(),
                             "formal_orientation_raw": NSNull(), "formal_metadata_unknown": true], in: slot)
                }
                if let native = node.object as? NSControl {
                    try put(["native_enabled": native.isEnabled, "native_hidden_or_hidden_ancestor": native.isHiddenOrHasHiddenAncestor], in: slot)
                }
                for (attribute, key, bytes) in [(NSAccessibility.Attribute.role, "informal_role", 128),
                    (.subrole, "informal_subrole", 128), (.identifier, "informal_identifier", 128),
                    (.title, "informal_title", 256), (.description, "informal_description", 256)] {
                    guard attributes.contains(attribute) else {
                        try put([key: NSNull(), key + "_advertised": false], in: slot); continue
                    }
                    let raw = node.object.accessibilityAttributeValue(attribute)
                    try checkObservation()
                    let text: String?
                    if let raw {
                        if let string = raw as? String { text = string }
                        else if attribute == .role, let role = raw as? NSAccessibility.Role { text = role.rawValue }
                        else if attribute == .subrole, let subrole = raw as? NSAccessibility.Subrole { text = subrole.rawValue }
                        else {
                            try put([key + "_unsupported_type": scrollerActionBoundedString(String(reflecting: type(of: raw)), bytes: 256)], in: slot)
                            throw NativeWorkspacePageCaptureFailure("Projects advertised public text metadata had an unsupported type")
                        }
                    } else { text = nil }
                    var fields = textFields(text, key: key, bytes: bytes); fields[key + "_advertised"] = true
                    try put(fields, in: slot)
                }
                if attributes.contains(.children) {
                    let raw = node.object.accessibilityAttributeValue(.children)
                    try checkObservation()
                    try put(["informal_children_advertised": true, "informal_children_unknown": raw == nil], in: slot)
                    if let raw {
                        guard let children = raw as? [Any] else {
                            try put(["informal_children_unsupported_type": scrollerActionBoundedString(String(reflecting: type(of: raw)), bytes: 256)], in: slot)
                            throw NativeWorkspacePageCaptureFailure("Projects advertised public children did not expose an array")
                        }
                        try put(["informal_child_count": children.count], in: slot)
                        guard children.count <= 64 else {
                            throw NativeWorkspacePageCaptureFailure("Projects informal public children exceeded 64 entries")
                        }
                        lists.append(children)
                    }
                } else { try put(["informal_children_advertised": false, "informal_children_unknown": true], in: slot) }
                var union: [NSObject] = [], seen = Set<ObjectIdentifier>()
                for list in lists {
                    guard list.count <= 64 else {
                        throw NativeWorkspacePageCaptureFailure("Projects public child list exceeded 64 entries")
                    }
                    for raw in list {
                        try checkObservation()
                        let child = try objectBridge(raw)
                        if seen.insert(ObjectIdentifier(child)).inserted { union.append(child) }
                        guard union.count <= 64 else {
                            throw NativeWorkspacePageCaptureFailure("Projects public child union exceeded 64 objects")
                        }
                    }
                }
                try put(["union_child_count": union.count,
                         "union_children_actual_identities": union.map {
                            scrollerActionBoundedString(String(describing: ObjectIdentifier($0)), bytes: 128)
                         }], in: slot)
                guard union.isEmpty || node.depth < 4 else {
                    throw NativeWorkspacePageCaptureFailure("Projects advertised child tree exceeded depth four")
                }
                for child in union {
                    let identity = ObjectIdentifier(child), rootIdentity = ObjectIdentifier(node.root)
                    if let previousRoot = enqueued[identity] {
                        guard previousRoot == rootIdentity else {
                            throw NativeWorkspacePageCaptureFailure("Projects public child was advertised by both exact scrollers")
                        }
                        continue
                    }
                    guard pending.count < 64 else {
                        throw NativeWorkspacePageCaptureFailure("Projects advertisement exceeded its total 64-object bound")
                    }
                    enqueued[identity] = rootIdentity
                    pending.append((child, node.root, node.axis, node.depth + 1))
                }
                try put(["observation_finished_uptime": ProcessInfo.processInfo.systemUptime,
                         "metadata_complete": true], in: slot)
                try requireOwner(); cursor += 1
            }
            try requireOwner()
            let completed = ProcessInfo.processInfo.systemUptime
            guard completed < boundedObservationDeadline else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement completion sample crossed its 0.5-second deadline")
            }
            report["observation_completed_uptime"] = completed
            report["observation_within_deadline"] = true
            observationDeadline = nil
            stage = "final-storage-and-isolation"
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: owned.defaults)
            let mutations = await owned.client.mutationNames()
            guard fresh.restorationError == nil, fresh.collection == baseline,
                  owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                  mutations.isEmpty, owned.model.app == nil, owned.model.manager == nil,
                  owned.model.remoteManager == nil, !owned.model.hasLoadedInitialSettings else {
                throw NativeWorkspacePageCaptureFailure("Projects advertisement fresh storage/fixture isolation proof failed")
            }
            try requireOwner()
            report["same_panel_hosts_and_panel_frames"] = true
            report["same_target_control_frame_and_bounds"] = true
            report["same_inner_hosting_view_identities"] = true
            report["same_clip_and_document_visible_rect"] = true
            report["complete_preferences_and_bytes_unchanged"] = true
            report["fresh_preferences_restoration_unchanged"] = true; report["fixture_mutations"] = mutations
            report["target_center_visible_after"] = document.visibleRect.contains(target)
            stage = "complete"; report["execution_completed"] = true
            try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: "projects-native-scroller-advertisements-after")
            try requireOwner(); try retainReport("after")
        } catch {
            report["execution_completed"] = false
            report["original_error"] = scrollerActionBoundedString(String(reflecting: error), bytes: 2_048)
            report["original_error_type"] = scrollerActionBoundedString(String(reflecting: type(of: error)), bytes: 256)
            report["failure_uptime"] = ProcessInfo.processInfo.systemUptime
            report["failure_cache_attempted"] = self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize)
            if self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize) {
                do { try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: "projects-native-scroller-advertisements-failed-diagnostic") }
                catch { report["failure_cache_error"] = scrollerActionBoundedString(String(reflecting: error), bytes: 2_048) }
            }
            do { try retainReport("failed-diagnostic") }
            catch { XCTFail("Could not retain bounded Projects advertisement diagnostic: \(scrollerActionBoundedString(String(reflecting: error), bytes: 2_048))") }
            throw error
        }
    }


    private func scrollerActionBoundedString(_ value: String, bytes maximumBytes: Int) -> String {
        var prefix = Array(value.utf8.prefix(maximumBytes))
        // A Swift string has valid UTF8; at most three tail bytes can split one scalar.
        for _ in 0..<4 {
            if let result = String(bytes: prefix, encoding: .utf8) { return result }
            guard !prefix.isEmpty else { return "" }
            prefix.removeLast()
        }
        return ""
    }

    private func nativeProjectsScrollerActions(_ layout: NativeWorkspaceLayout,
                                               in owned: NativeWorkspacePageCaptureFixture,
                                               expectedContentSize: NSSize,
                                               deadline: TimeInterval) async throws {
        var stage = "owner", actions: [[String: Any]] = [], invoked = 0
        var report: [String: Any] = [
            "classification": "Exact isolated Projects outer NSScroller semantic action and native geometry experiment; XCTest outcome determines qualification",
            "view_id": "projects", "target_identifier": "workspace-resize-projects-summary",
            "viewport": scrollerActionBoundedString(NSStringFromSize(expectedContentSize), bytes: 512), "execution_completed": false,
            "maximum_actions": 64, "case_deadline_uptime": deadline, "maximum_case_seconds": 45,
            "maximum_action_settle_seconds": 0.5, "poll_milliseconds": 20,
            "direct_scroll_fallback": false, "pointer_input": false,
            "application_active": NSApp.isActive, "window_key": owned.window.isKeyWindow,
        ]
        func retainReport(_ suffix: String) throws {
            report["last_stage"] = scrollerActionBoundedString(stage, bytes: 128); report["action_attempts"] = actions
            report["invoked_actions"] = invoked; report["within_case_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard actions.count <= 64, data.count <= 512 * 1_024 else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller receipt exceeded its row/JSON byte bound")
            }
            let receiptName = "projects-native-scroller-actions-" + suffix
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = receiptName; attachment.lifetime = .keepAlways; add(attachment)
            try directEvidence.save(data, name: receiptName, extension: "json")
        }
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline, layout.viewID == "projects",
                  owned.route.page == .projects, layout.panels.count > 0, layout.panels.count <= 64,
                  layout.panels.allSatisfy(\.isVisible) else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller exact all-visible layout or case deadline is absent")
            }
            let documents = nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            guard documents.count == 1, let document = documents.first,
                  let scroll = document.enclosingScrollView, scroll.documentView === document,
                  document.superview === scroll.contentView, document.isFlipped,
                  scroll.hasHorizontalScroller, scroll.hasVerticalScroller,
                  let horizontal = scroll.horizontalScroller, let vertical = scroll.verticalScroller,
                  horizontal !== vertical, let panel = document.panelHosts["projects-summary"] else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller exact native document/panel/scrollers are absent")
            }
            let identities = document.panelHosts.mapValues { ObjectIdentifier($0) }
            let documentFrame = document.frame, documentBounds = document.bounds
            let canvasSize = NSSize(width: layout.canvas.width, height: layout.canvas.height)
            let panelFrames = document.panelHosts.mapValues(\.frame)
            let hostingIdentities = document.panelHosts.mapValues { ObjectIdentifier($0.hostingView) }
            guard Set(identities.keys) == Set(layout.panels.map(\.id)),
                  documentFrame.size == canvasSize, documentBounds.origin == .zero,
                  documentBounds.size == canvasSize, layout.panels.allSatisfy({ placement in
                    document.panelHosts[placement.id]?.frame == NSRect(x: placement.frame.x, y: placement.frame.y,
                        width: placement.frame.width, height: placement.frame.height)
                  }) else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller catalog membership/frames/canvas differ from its layout")
            }
            panel.layoutSubtreeIfNeeded()
            let matches = nativeViews(panel).filter { $0.accessibilityIdentifier() == "workspace-resize-projects-summary" }
            guard matches.count == 1, let control = matches.first,
                  control.superview === panel, control.window === owned.window,
                  !control.isHiddenOrHasHiddenAncestor, control.bounds.width >= 8, control.bounds.height >= 8 else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller unique resize control is absent")
            }
            let controlFrame = control.frame, controlBounds = control.bounds
            let targetBounds = document.convert(control.bounds, from: control)
            let target = NSRect(x: targetBounds.midX - 4, y: targetBounds.midY - 4, width: 8, height: 8)
            let baseline = owned.preferences.collection
            let beforeBytes = try XCTUnwrap(owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard beforeBytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: beforeBytes) == baseline,
                  owned.preferences.activeLayout(for: "projects") == layout,
                  [targetBounds.minX, targetBounds.minY, targetBounds.width, targetBounds.height].allSatisfy({ $0.isFinite }),
                  document.bounds.contains(target) else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller baseline storage/layout/control geometry is invalid")
            }
            func parentChain(_ view: NSView, to owner: NSView) throws -> [String] {
                var current: NSView? = view, seen = Set<ObjectIdentifier>(), types: [String] = []
                while let next = current {
                    guard types.count < 64, seen.insert(ObjectIdentifier(next)).inserted,
                          next.window === owned.window, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw NativeWorkspacePageCaptureFailure("Projects scroller parent chain exceeded its bound or exact window")
                    }
                    types.append(scrollerActionBoundedString(String(reflecting: type(of: next)), bytes: 256))
                    if next === owner { return types }
                    current = next.superview
                }
                throw NativeWorkspacePageCaptureFailure("Projects scroller parent chain did not reach its exact native owner")
            }
            func requireOwner() throws {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize),
                      owned.route.page == .projects, document.window === owned.window,
                      scroll.window === owned.window, document.enclosingScrollView === scroll,
                      scroll.documentView === document, document.superview === scroll.contentView,
                      document.frame == documentFrame, document.frame.size == canvasSize,
                      document.bounds == documentBounds, document.bounds.origin == .zero,
                      document.bounds.size == canvasSize,
                      scroll.horizontalScroller === horizontal, scroll.verticalScroller === vertical,
                      document.panelHosts.mapValues({ ObjectIdentifier($0) }) == identities,
                      document.panelHosts.mapValues(\.frame) == panelFrames,
                      document.panelHosts.mapValues({ ObjectIdentifier($0.hostingView) }) == hostingIdentities,
                      panel.superview === document, !panel.isHiddenOrHasHiddenAncestor,
                      control.superview === panel, control.window === owned.window,
                      !control.isHiddenOrHasHiddenAncestor, control.frame == controlFrame, control.bounds == controlBounds,
                      document.convert(control.bounds, from: control) == targetBounds,
                      owned.preferences.collection == baseline,
                      owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
                    throw NativeWorkspacePageCaptureFailure("Projects scroller owner/frame/preferences changed or its case deadline elapsed")
                }
                _ = try parentChain(horizontal, to: scroll); _ = try parentChain(vertical, to: scroll)
                _ = try parentChain(scroll, to: owned.hosting)
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NativeWorkspacePageCaptureFailure("Projects scroller case deadline elapsed during ownership validation")
                }
            }
            func scrollerMetadata(_ scroller: NSScroller) -> [String: Any] {
                ["type": scrollerActionBoundedString(String(reflecting: type(of: scroller)), bytes: 256),
                 "role": scroller.accessibilityRole().map { scrollerActionBoundedString($0.rawValue, bytes: 128) as Any } ?? NSNull(),
                 "orientation_raw": scroller.accessibilityOrientation().rawValue,
                 "enabled": scroller.isEnabled, "accessibility_enabled": scroller.isAccessibilityEnabled(),
                 "hidden_or_hidden_ancestor": scroller.isHiddenOrHasHiddenAncestor,
                 "increment_selector_allowed": scroller.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformIncrement")),
                 "decrement_selector_allowed": scroller.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformDecrement"))]
            }
            try requireOwner()
            let initialVisible = document.visibleRect
            report["initial_document_visible"] = scrollerActionBoundedString(NSStringFromRect(initialVisible), bytes: 512)
            report["document_bounds"] = scrollerActionBoundedString(NSStringFromRect(document.bounds), bytes: 512)
            report["control_bounds_in_document"] = scrollerActionBoundedString(NSStringFromRect(targetBounds), bytes: 512)
            report["target_center_rect"] = scrollerActionBoundedString(NSStringFromRect(target), bytes: 512)
            report["horizontal_scroller"] = scrollerMetadata(horizontal)
            report["vertical_scroller"] = scrollerMetadata(vertical)
            report["horizontal_parent_chain"] = try parentChain(horizontal, to: scroll)
            report["vertical_parent_chain"] = try parentChain(vertical, to: scroll)
            report["outer_scroll_parent_chain"] = try parentChain(scroll, to: owned.hosting)
            report["stored_bytes"] = beforeBytes.count; report["baseline_layout_count"] = baseline.layouts.count
            stage = "initial-offscreen-prerequisite"
            guard target.minX > initialVisible.maxX, target.minY > initialVisible.maxY else {
                throw NativeWorkspacePageCaptureFailure("Projects resize center is not initially beyond both right and lower viewport edges")
            }
            try retainReport("before")
            try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: "projects-native-scroller-actions-before")
            try requireOwner()
            for (axis, scroller) in [("horizontal", horizontal), ("vertical", vertical)] {
                func axisContainsTarget() -> Bool {
                    let visible = document.visibleRect
                    return axis == "horizontal" ? visible.minX <= target.minX && visible.maxX >= target.maxX
                        : visible.minY <= target.minY && visible.maxY >= target.maxY
                }
                while !axisContainsTarget() {
                    try requireOwner()
                    guard actions.count < 64 else {
                        throw NativeWorkspacePageCaptureFailure("Projects scroller exhausted its total 64-action budget")
                    }
                    let before = scroll.contentView.bounds
                    guard [before.minX, before.minY, before.width, before.height].allSatisfy({ $0.isFinite }),
                          before.width > 0, before.height > 0 else {
                        throw NativeWorkspacePageCaptureFailure("Projects scroller pre-action clip geometry is invalid")
                    }
                    let slot = actions.count
                    stage = axis + ".attempt-\(slot + 1)"
                    let allowed = scroller.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformIncrement"))
                    actions.append(["axis": axis, "attempt": slot + 1, "action": "accessibilityPerformIncrement",
                        "selector_allowed": allowed, "invoked": false, "actual_return": NSNull(),
                        "attempt_uptime": ProcessInfo.processInfo.systemUptime,
                        "before_clip_bounds": scrollerActionBoundedString(NSStringFromRect(before), bytes: 512), "scroller": scrollerMetadata(scroller),
                        "outcome": "selector-observed"])
                    defer {
                        actions[slot]["after_clip_bounds"] = scrollerActionBoundedString(NSStringFromRect(scroll.contentView.bounds), bytes: 512)
                        actions[slot]["after_document_visible"] = scrollerActionBoundedString(NSStringFromRect(document.visibleRect), bytes: 512)
                        actions[slot]["axis_target_visible_after"] = axisContainsTarget()
                        actions[slot]["finished_uptime"] = ProcessInfo.processInfo.systemUptime
                    }
                    guard allowed else {
                        actions[slot]["outcome"] = "selector-denied"
                        throw NativeWorkspacePageCaptureFailure("Projects \(axis) scroller does not permit the public increment selector")
                    }
                    guard scroller.accessibilityRole() == .scrollBar,
                          scroller.accessibilityOrientation() == (axis == "horizontal" ? .horizontal : .vertical),
                          scroller.isEnabled, scroller.isAccessibilityEnabled() else {
                        actions[slot]["outcome"] = "runtime-role-or-orientation-or-enabled-prerequisite-failed"
                        throw NativeWorkspacePageCaptureFailure("Projects \(axis) scroller runtime role/orientation/enabled prerequisite failed")
                    }
                    do { try requireOwner() }
                    catch {
                        actions[slot]["outcome"] = "dispatch-owner-or-deadline-failed"
                        throw error
                    }
                    actions[slot]["invoked"] = true; invoked += 1
                    actions[slot]["dispatch_uptime"] = ProcessInfo.processInfo.systemUptime
                    let returned = scroller.accessibilityPerformIncrement()
                    actions[slot]["actual_return"] = returned
                    actions[slot]["returned_uptime"] = ProcessInfo.processInfo.systemUptime
                    actions[slot]["outcome"] = returned ? "returned-true-awaiting-progress" : "returned-false"
                    guard returned else {
                        throw NativeWorkspacePageCaptureFailure("Projects \(axis) scroller public increment returned false")
                    }
                    let settleDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
                    actions[slot]["settle_deadline_uptime"] = settleDeadline
                    var progressed = false
                    while ProcessInfo.processInfo.systemUptime < settleDeadline {
                        try requireOwner(); owned.hosting.layoutSubtreeIfNeeded(); try requireOwner()
                        let after = scroll.contentView.bounds
                        guard [after.minX, after.minY, after.width, after.height].allSatisfy({ $0.isFinite }),
                              abs(after.width - before.width) <= 0.1, abs(after.height - before.height) <= 0.1 else {
                            actions[slot]["outcome"] = "invalid-or-resized-clip"
                            throw NativeWorkspacePageCaptureFailure("Projects scroller changed to invalid or resized clip geometry")
                        }
                        let delta = axis == "horizontal" ? after.minX - before.minX : after.minY - before.minY
                        let otherDelta = axis == "horizontal" ? after.minY - before.minY : after.minX - before.minX
                        guard delta.isFinite, otherDelta.isFinite else {
                            actions[slot]["outcome"] = "nonfinite-clip-delta"
                            throw NativeWorkspacePageCaptureFailure("Projects scroller clip delta is nonfinite")
                        }
                        actions[slot]["observed_axis_delta"] = delta; actions[slot]["observed_other_axis_delta"] = otherDelta
                        guard delta >= -0.1, abs(otherDelta) <= 0.1 else {
                            actions[slot]["outcome"] = "opposite-or-other-axis-movement"
                            throw NativeWorkspacePageCaptureFailure("Projects scroller moved in an unexpected axis/direction")
                        }
                        let sampleUptime = ProcessInfo.processInfo.systemUptime
                        actions[slot]["progress_sample_uptime"] = sampleUptime
                        guard sampleUptime < settleDeadline else {
                            actions[slot]["outcome"] = "settle-sample-deadline-exceeded"
                            throw NativeWorkspacePageCaptureFailure("Projects scroller progress sample crossed its 0.5-second settle deadline")
                        }
                        if delta > 0.1 { progressed = true; break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard progressed, ProcessInfo.processInfo.systemUptime < deadline else {
                        actions[slot]["outcome"] = "stationary-or-deadline"
                        throw NativeWorkspacePageCaptureFailure("Projects \(axis) scroller did not progress within its 0.5-second settle bound")
                    }
                    actions[slot]["outcome"] = "progress-observed"; try requireOwner()
                }
            }
            stage = "final-center-and-storage"
            try requireOwner()
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: owned.defaults)
            let mutations = await owned.client.mutationNames()
            guard document.visibleRect.contains(target), invoked > 0, invoked <= 64,
                  actions.contains(where: { $0["axis"] as? String == "horizontal" && $0["outcome"] as? String == "progress-observed" }),
                  actions.contains(where: { $0["axis"] as? String == "vertical" && $0["outcome"] as? String == "progress-observed" }),
                  owned.hosting.hitTest(document.convert(NSPoint(x: target.midX, y: target.midY), to: owned.hosting.superview)) === control,
                  fresh.restorationError == nil, fresh.collection == baseline,
                  owned.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                  mutations.isEmpty, owned.model.app == nil, owned.model.manager == nil,
                  owned.model.remoteManager == nil, !owned.model.hasLoadedInitialSettings else {
                throw NativeWorkspacePageCaptureFailure("Projects scroller final hit-test/fresh storage/fixture isolation proof failed")
            }
            try requireOwner()
            report["final_document_visible"] = scrollerActionBoundedString(NSStringFromRect(document.visibleRect), bytes: 512)
            report["target_center_visible"] = true; report["exact_control_hit_test"] = true
            report["same_panel_hosts_and_panel_frames"] = true
            report["same_target_control_frame_and_bounds"] = true
            report["same_inner_hosting_view_identities"] = true
            report["complete_preferences_and_bytes_unchanged"] = true
            report["fresh_preferences_restoration_unchanged"] = true; report["fixture_mutations"] = mutations
            stage = "complete"; report["execution_completed"] = true
            try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: "projects-native-scroller-actions-after")
            try requireOwner(); try retainReport("after")
        } catch {
            report["execution_completed"] = false
            report["original_error"] = scrollerActionBoundedString(String(reflecting: error), bytes: 2_048)
            report["original_error_type"] = scrollerActionBoundedString(String(reflecting: type(of: error)), bytes: 256)
            report["failure_cache_attempted"] = self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize)
            if self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize) {
                do { try capturePhysicalCache(owned, expectedContentSize: expectedContentSize, name: "projects-native-scroller-actions-failed-diagnostic") }
                catch { report["failure_cache_error"] = scrollerActionBoundedString(String(reflecting: error), bytes: 2_048) }
            }
            do { try retainReport("failed-diagnostic") }
            catch { XCTFail("Could not retain bounded Projects scroller diagnostic: \(scrollerActionBoundedString(String(reflecting: error), bytes: 2_048))") }
            throw error
        }
    }

    private func nativeScrollReachability(_ layout: NativeWorkspaceLayout,
                                          in owned: NativeWorkspacePageCaptureFixture,
                                          expectedContentSize: NSSize,
                                          deadline: TimeInterval) async throws -> [String: Any] {
        let documents = nativeViews(owned.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
        guard documents.count == 1, let document = documents.first,
              let scroll = document.enclosingScrollView,
              scroll.documentView === document, document.isFlipped,
              scroll.hasHorizontalScroller, scroll.hasVerticalScroller,
              layout.panels.count > 0, layout.panels.count <= 64,
              layout.panels.allSatisfy(\.isVisible) else {
            throw NativeWorkspacePageCaptureFailure("Exact all-visible native scroll owner/scrollers are absent")
        }
        let retainedHosts = document.panelHosts
        guard Set(retainedHosts.keys) == Set(layout.panels.map(\.id)) else {
            throw NativeWorkspacePageCaptureFailure("Native scroll panel membership changed")
        }
        let identities = retainedHosts.mapValues { ObjectIdentifier($0) }
        let initialVisible = document.visibleRect
        var rows: [[String: Any]] = []
        func requireOwner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  self.physicalCachePresentationIsReady(owned, expectedContentSize: expectedContentSize),
                  document.window === owned.window, scroll.window === owned.window,
                  document.enclosingScrollView === scroll, scroll.documentView === document,
                  document.panelHosts.mapValues({ ObjectIdentifier($0) }) == identities else {
                throw NativeWorkspacePageCaptureFailure("Native scroll deadline, viewport or same-host owner changed")
            }
        }
        for placement in layout.panels {
            let panel = try XCTUnwrap(retainedHosts[placement.id])
            for prefix in ["workspace-move-", "workspace-hide-", "workspace-resize-"] {
                try requireOwner()
                panel.layoutSubtreeIfNeeded()
                let identifier = prefix + placement.id
                let matches = nativeViews(panel).filter { $0.accessibilityIdentifier() == identifier }
                guard matches.count == 1, let control = matches.first,
                      control.window === owned.window, !control.isHiddenOrHasHiddenAncestor,
                      !panel.isHidden, control.bounds.width >= 8, control.bounds.height >= 8 else {
                    throw NativeWorkspacePageCaptureFailure("Unique real native scroll control is absent: \(identifier)")
                }
                let controlBounds = document.convert(control.bounds, from: control)
                let target = NSRect(x: controlBounds.midX - 4, y: controlBounds.midY - 4, width: 8, height: 8)
                guard [controlBounds.minX, controlBounds.minY, controlBounds.width, controlBounds.height]
                        .allSatisfy({ $0.isFinite }), document.bounds.contains(target) else {
                    throw NativeWorkspacePageCaptureFailure("Native control target is outside the finite flipped document")
                }
                let beforeVisible = document.visibleRect
                let beforeClip = scroll.contentView.bounds
                let scrolled = document.scrollToVisible(target)
                scroll.reflectScrolledClipView(scroll.contentView)
                try await waitUntil("Native scroll did not expose the actual control center: \(identifier)",
                    timeout: min(0.5, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))) {
                    owned.hosting.layoutSubtreeIfNeeded()
                    return document.visibleRect.contains(target)
                }
                try requireOwner()
                let afterBounds = document.convert(control.bounds, from: control)
                guard afterBounds == controlBounds, document.visibleRect.contains(target), rows.count < 192 else {
                    throw NativeWorkspacePageCaptureFailure("Native scrolling moved a panel/control or exceeded its row bound")
                }
                rows.append([
                    "identifier": identifier, "panel_id": placement.id,
                    "control_type": String(reflecting: type(of: control)),
                    "control_bounds_in_document": NSStringFromRect(controlBounds),
                    "target_center_rect": NSStringFromRect(target),
                    "initially_off_viewport": !initialVisible.contains(target),
                    "before_document_visible": NSStringFromRect(beforeVisible),
                    "before_clip_bounds": NSStringFromRect(beforeClip),
                    "scroll_returned": scrolled,
                    "after_document_visible": NSStringFromRect(document.visibleRect),
                    "after_clip_bounds": NSStringFromRect(scroll.contentView.bounds),
                    "target_visible_after": document.visibleRect.contains(target),
                    "same_native_hosts": document.panelHosts.mapValues({ ObjectIdentifier($0) }) == identities,
                ])
            }
        }
        try requireOwner()
        guard rows.count == layout.panels.count * 3 else {
            throw NativeWorkspacePageCaptureFailure("Native scroll receipt omitted a catalog primitive")
        }
        return [
            "classification": "Public native workspace primitive-center scroll geometry only; no mouse, wheel, semantic actions, desktop compositor or Metal proof",
            "view_id": layout.viewID, "route": owned.route.page.rawValue,
            "viewport": NSStringFromSize(expectedContentSize),
            "document_bounds": NSStringFromRect(document.bounds),
            "initial_document_visible": NSStringFromRect(initialVisible),
            "horizontal_scroller": scroll.hasHorizontalScroller, "vertical_scroller": scroll.hasVerticalScroller,
            "panel_count": layout.panels.count, "primitive_count": rows.count,
            "application_active": NSApp.isActive, "window_key": owned.window.isKeyWindow,
            "settings_ready": owned.model.hasLoadedInitialSettings,
            "semantic_observation_qualified": false, "controls": rows,
        ]
    }


    private func nativeViews(_ root: NSView) -> [NSView] {
        var pending = [root], result: [NSView] = []
        while let view = pending.popLast() {
            guard result.count + pending.count < 8_192 else { XCTFail("Native view tree exceeded its bound"); return [] }
            result.append(view); pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NativeWorkspacePageCaptureFailure(message)
    }

    private func waitUntilAsync(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw NativeWorkspacePageCaptureFailure(message)
    }

    private func retainFailure(_ error: Error) throws {
        let data = Data(String(describing: error).utf8)
        try directEvidence.save(data, name: "terminal-failure", extension: "txt")
        if !directEvidence.isEnabled {
            let attachment = XCTAttachment(string: String(describing: error))
            attachment.name = "terminal-failure"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
#endif
}

#if !SWIFT_PACKAGE
// Test-only reuse boundary. Callers retain their private fixture and receipt ownership.
@MainActor
enum NativeWorkspaceQueuedPanelGeometryVerifier {
    static func verify(_ layout: NativeWorkspaceLayout, panelID: String,
                       window: NSWindow, hosting rootHosting: NSView,
                       preferences: NativeWorkspacePreferences, defaults: UserDefaults,
                       deadline: TimeInterval, receiptName: String,
                       presentationIsReady: @MainActor () -> Bool,
                       retainReport: @MainActor (Data, String) -> Void) async throws {
        let documents = nativeViews(rootHosting).compactMap { $0 as? NativeWorkspaceDocumentView }
        let descriptors = try XCTUnwrap(NativeWorkspaceCatalog.panelsByView[layout.viewID])
        guard documents.count == 1, let document = documents.first,
              let panel = document.panelHosts[panelID], let scroll = document.enclosingScrollView,
              scroll.documentView === document, document.isFlipped,
              let descriptor = descriptors.first(where: { $0.id == panelID }),
              let placement = layout.panels.first(where: { $0.id == panelID }), placement.isVisible else {
            throw NativeWorkspacePageCaptureFailure("The exact real catalog document/panel/descriptor is absent.")
        }
        defer { panel.cancelGesture() }
        let hosting = panel.hostingView, identities = document.panelHosts.mapValues { ObjectIdentifier($0) }
        var stage = "owner", posted = 0
        var report: [String: Any] = [
            "classification": "Actual isolated production-page queued panel gestures; XCTest outcome determines qualification",
            "view_id": layout.viewID, "panel_id": panelID, "execution_completed": false,
            "original_frame": NSStringFromRect(nativeRect(placement.frame)), "maximum_events": 6,
        ]
        defer {
            report["last_stage"] = stage; report["posted_events"] = posted
            report["within_case_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               data.count <= 64 * 1_024 {
                retainReport(data, receiptName)
            }
        }
        func nativeRect(_ frame: NativeWorkspaceFrame) -> NSRect {
            NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
        @MainActor func requireOwner() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline, NSApp.isActive,
                  window.isKeyWindow, NSApp.keyWindow === window,
                  presentationIsReady(),
                  NSApp.windows.filter({ $0.title == window.title }).count == 1,
                  document.window === window, document.isDescendant(of: rootHosting),
                  document.enclosingScrollView === scroll, scroll.documentView === document,
                  document.panelHosts.mapValues({ ObjectIdentifier($0) }) == identities,
                  Set(identities.keys) == Set(layout.panels.map(\.id)),
                  panel.hostingView === hosting, hosting.superview === panel, hosting.window === window,
                  panel.superview === document, !panel.isHiddenOrHasHiddenAncestor,
                  preferences.activeLayout(for: layout.viewID)?.id == layout.id else {
                throw NativeWorkspacePageCaptureFailure("The real queued-input owner/window/panel/layout or deadline changed.")
            }
        }
        @MainActor func wait(_ message: String, _ condition: () throws -> Bool) async throws {
            let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
            while ProcessInfo.processInfo.systemUptime < end {
                try requireOwner(); rootHosting.layoutSubtreeIfNeeded()
                if try condition() {
                    try requireOwner()
                    guard ProcessInfo.processInfo.systemUptime < end else { throw NativeWorkspacePageCaptureFailure(message) }
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NativeWorkspacePageCaptureFailure(message)
        }
        @MainActor func stored() throws -> Data {
            let data = try XCTUnwrap(defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard data.count <= NativeWorkspaceLimits.maximumStoredBytes else {
                throw NativeWorkspacePageCaptureFailure("The real queued-input storage exceeded its existing byte bound.")
            }
            return data
        }
        @MainActor func post(_ type: NSEvent.EventType, at point: NSPoint) throws {
            try requireOwner()
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: document.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            guard posted < 6, event.window === window, event.windowNumber == window.windowNumber else {
                throw NativeWorkspacePageCaptureFailure("The real queued pointer escaped its exact window/six-event bound.")
            }
            NSApp.postEvent(event, atStart: false); posted += 1
        }
        try requireOwner()
        let preparedSize = NSSize(width: layout.canvas.width, height: layout.canvas.height)
        stage = "prepared-layout.ready"
        try await wait("The real prepared canvas/start frame did not finish applying.") {
            document.frame.size == preparedSize && panel.canvasSize == preparedSize
                && panel.frame == nativeRect(placement.frame)
        }
        let moved = NativeWorkspaceFrame(x: placement.frame.x + 20, y: placement.frame.y + 20,
            width: placement.frame.width, height: placement.frame.height)
        let dx = min(40, min(Double(descriptor.maximumSize.width) - moved.width, layout.canvas.width - moved.x - moved.width))
        let dy = min(30, min(Double(descriptor.maximumSize.height) - moved.height, layout.canvas.height - moved.y - moved.height))
        guard dx.isFinite, dy.isFinite, dx >= 1, dy >= 1 else {
            throw NativeWorkspacePageCaptureFailure("The real descriptor/canvas must permit a meaningful legal resize.")
        }
        let resized = NativeWorkspaceFrame(x: moved.x, y: moved.y, width: moved.width + dx, height: moved.height + dy)
        try moved.validate(in: layout.canvas); try resized.validate(in: layout.canvas)
        let bounds = try XCTUnwrap(NativeWorkspaceCatalog.sizeBoundsByView[layout.viewID]?[panelID])
        try bounds.validate(moved); try bounds.validate(resized)
        guard panel.frame == nativeRect(placement.frame) else {
            throw NativeWorkspacePageCaptureFailure("The real panel's starting frame differs from its exact prepared layout.")
        }
        for resizing in [false, true] {
            stage = resizing ? "resize.prepare-hit" : "move.prepare-hit"
            try requireOwner(); panel.layoutSubtreeIfNeeded()
            guard panel.subviews.count <= 64 else { throw NativeWorkspacePageCaptureFailure("Real native chrome exceeded64 direct children.") }
            let identifier = (resizing ? "workspace-resize-" : "workspace-move-") + panelID
            let targets = panel.subviews.filter { $0.accessibilityIdentifier() == identifier }
            guard targets.count == 1, let target = targets.first, target.superview === panel,
                  target.window === window, !target.isHiddenOrHasHiddenAncestor else {
                throw NativeWorkspacePageCaptureFailure("The unique literal real native gesture handle is absent.")
            }
            let from = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: document)
            let to = NSPoint(x: from.x + CGFloat(resizing ? dx : 20), y: from.y + CGFloat(resizing ? dy : 20))
            let path = NSRect(x: from.x - 8, y: from.y - 8, width: to.x - from.x + 16, height: to.y - from.y + 16)
            guard document.bounds.contains(path) else { throw NativeWorkspacePageCaptureFailure("The legal pointer path escaped the real document.") }
            _ = document.scrollToVisible(path.insetBy(dx: -32, dy: -32).intersection(document.bounds))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await wait("The whole real native pointer path did not enter its own viewport.") { document.visibleRect.contains(path) }
            guard rootHosting.hitTest(document.convert(from, to: rootHosting.superview)) === target else {
                throw NativeWorkspacePageCaptureFailure("The real owned window did not physically hit the literal gesture handle.")
            }
            let baseline = preferences.collection, beforeBytes = try stored()
            guard try JSONDecoder().decode(NativeWorkspaceCollection.self, from: beforeBytes) == baseline else {
                throw NativeWorkspacePageCaptureFailure("The pre-input real collection/storage differ.")
            }
            var expectedDown = baseline
            let index = try XCTUnwrap(expectedDown.layouts.firstIndex { $0.id == layout.id && $0.viewID == layout.viewID })
            let slot = try XCTUnwrap(expectedDown.layouts[index].panels.firstIndex { $0.id == panelID })
            let front = expectedDown.layouts[index].panels.remove(at: slot)
            expectedDown.layouts[index].panels.append(front)
            stage = resizing ? "resize.down" : "move.down"
            try post(.leftMouseDown, at: from)
            try await wait("The real native queue did not begin the panel gesture.") { panel.isManipulating }
            let downBytes = try stored()
            guard preferences.collection == expectedDown,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: downBytes) == expectedDown else {
                throw NativeWorkspacePageCaptureFailure("Real mouse-down changed more than exact front order.")
            }
            let frame = resizing ? resized : moved
            stage = resizing ? "resize.drag" : "move.drag"
            try post(.leftMouseDragged, at: to)
            try await wait("The real queued drag did not reach exact transient geometry.") { panel.isManipulating && panel.frame == nativeRect(frame) }
            guard preferences.collection == expectedDown, try stored() == downBytes else {
                throw NativeWorkspacePageCaptureFailure("A real drag persisted before mouse-up.")
            }
            var expectedUp = expectedDown
            let frontSlot = try XCTUnwrap(expectedUp.layouts[index].panels.firstIndex { $0.id == panelID })
            expectedUp.layouts[index].panels[frontSlot].frame = frame
            stage = resizing ? "resize.up" : "move.up"
            try post(.leftMouseUp, at: to)
            try await wait("Real mouse-up did not commit exactly one panel frame.") { !panel.isManipulating && preferences.collection == expectedUp }
            let afterBytes = try stored()
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            guard fresh.restorationError == nil, fresh.collection == expectedUp, try stored() == afterBytes else {
                throw NativeWorkspacePageCaptureFailure("Fresh preferences did not restore the complete real gesture collection unchanged.")
            }
            report[resizing ? "resized_frame" : "moved_frame"] = NSStringFromRect(nativeRect(frame))
        }
        try requireOwner()
        guard posted == 6, panel.frame == nativeRect(resized) else { throw NativeWorkspacePageCaptureFailure("Real queued motion omitted input or final geometry.") }
        stage = "complete"; report["execution_completed"] = true
    }

    private static func nativeViews(_ root: NSView) -> [NSView] {
        var pending = [root], result: [NSView] = []
        while let view = pending.popLast() {
            guard result.count + pending.count < 8_192 else { XCTFail("Native view tree exceeded its bound"); return [] }
            result.append(view); pending.append(contentsOf: view.subviews)
        }
        return result
    }
}

private struct NativeWorkspacePageCaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private struct NativeWorkspacePageCaptureAXMetadata {
    let identifier: String?
    let role: String?
    let title: String?
    let label: String?
    let value: Any?
    let frame: NSRect?
    let unknownGeometry: [String: String]?
    let enabled: Bool?
    let actions: [String]?
}

@MainActor
private final class NativeWorkspacePageCaptureAXElement {
    let reference: AXUIElement
    let metadata: NativeWorkspacePageCaptureAXMetadata
    let scope: NativeWorkspacePageCaptureAXScope
    init(_ reference: AXUIElement, metadata: NativeWorkspacePageCaptureAXMetadata,
         scope: NativeWorkspacePageCaptureAXScope) {
        self.reference = reference; self.metadata = metadata; self.scope = scope
    }
    func copyValue() throws -> Any? { try scope.copyValue(of: reference) }
    func press() throws { try scope.press(reference) }
}

private enum NativeWorkspacePageCaptureObservationScope: String { case wholeWindow, applicationContent }

/// Exact own-process exported AX tree; native/formal observations remain diagnostic comparisons.
@MainActor
private final class NativeWorkspacePageCaptureAXScope {
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    private let title: String
    private let pid = ProcessInfo.processInfo.processIdentifier
    private var exportedWindow: AXUIElement?
    private(set) var diagnosticProgress: [String: Any] = [:]

    // Records are local to one walk; only its bounded caught-node witnesses survive until reporting.
    private struct CopiedChildRecord {
        let parentRecordIndex: Int?
        let copiedChildIndex: Int?
        var completedMetadata: [String: Any]?
    }
    private struct CopiedChildFailureWitness {
        let reference: AXUIElement
        let ancestorReferences: [AXUIElement]
        let copiedChildIndices: [Int]
    }
    private var copiedChildFailureWitness: CopiedChildFailureWitness?

    init(window: NSWindow, hosting: NSView) {
        self.window = window; self.hosting = hosting; title = window.title
    }

    private func ownedWindow() throws -> NSWindow {
        guard let window, let hosting, window.title == title, !title.isEmpty,
              window.contentView === hosting, hosting.window === window,
              NSApp.windows.filter({ $0.title == title }).count == 1 else {
            throw NativeWorkspacePageCaptureFailure("The exported AX observer lost its exact native window/hosting owner")
        }
        return window
    }

    private func check(_ deadline: TimeInterval) throws {
        _ = try ownedWindow()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw NativeWorkspacePageCaptureFailure("The own-window public AX observation exceeded its five-second deadline")
        }
    }

    private func prepare(_ element: AXUIElement, deadline: TimeInterval) throws {
        try check(deadline)
        var actualPID: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &actualPID)
        guard pidStatus == .success, actualPID == pid else {
            throw NativeWorkspacePageCaptureFailure("Public AX element escaped the own-process scope: status \(pidStatus.rawValue), PID \(actualPID)")
        }
        let timeoutStatus = AXUIElementSetMessagingTimeout(element, 0.1)
        guard timeoutStatus == .success else {
            throw NativeWorkspacePageCaptureFailure("Public AX messaging timeout failed: AXError \(timeoutStatus.rawValue)")
        }
        try check(deadline)
    }

    private func attribute(_ element: AXUIElement, _ name: String,
                           deadline: TimeInterval) throws -> CFTypeRef? {
        try prepare(element, deadline: deadline)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        diagnosticProgress["last_operation"] = "attribute"
        diagnosticProgress["last_attribute"] = name
        diagnosticProgress["last_status"] = status.rawValue
        try check(deadline)
        guard status == .success || status == .attributeUnsupported || status == .noValue else {
            throw NativeWorkspacePageCaptureFailure("Public AX \(name) read failed: AXError \(status.rawValue)")
        }
        return status == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ name: String,
                        deadline: TimeInterval) throws -> String? {
        guard let value = try attribute(element, name, deadline: deadline) else { return nil }
        guard let text = value as? String else {
            throw NativeWorkspacePageCaptureFailure("Public AX \(name) was not a string")
        }
        return text
    }

    private func elements(_ element: AXUIElement, _ name: String, limit: Int,
                          deadline: TimeInterval) throws -> [AXUIElement] {
        try prepare(element, deadline: deadline)
        var count = 0
        let status = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
        diagnosticProgress["last_operation"] = "attribute-value-count"
        diagnosticProgress["last_attribute"] = name
        diagnosticProgress["last_status"] = status.rawValue
        diagnosticProgress["last_count"] = count
        try check(deadline)
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success, count >= 0, count <= limit else {
            throw NativeWorkspacePageCaptureFailure("Public AX \(name) count failed/exceeded remaining bound: AXError \(status.rawValue), \(count) > \(limit)")
        }
        guard count > 0 else { return [] }
        try prepare(element, deadline: deadline)
        var values: CFArray?
        let copied = AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &values)
        diagnosticProgress["last_operation"] = "attribute-values-copy"
        diagnosticProgress["last_status"] = copied.rawValue
        try check(deadline)
        guard copied == .success, let children = values as? [AXUIElement], children.count == count else {
            throw NativeWorkspacePageCaptureFailure("Public AX \(name) child copy failed or changed count: AXError \(copied.rawValue)")
        }
        return children
    }

    private func frame(_ element: AXUIElement, deadline: TimeInterval, identifier: String?, role: String?,
                       frameFailure: (([String: Any]) -> Void)?) throws -> (frame: NSRect?, unknown: [String: String]?) {
        let position = try attribute(element, kAXPositionAttribute, deadline: deadline)
        let dimensions = try attribute(element, kAXSizeAttribute, deadline: deadline)
        guard let position, let dimensions else { return (nil, nil) }
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else {
            throw NativeWorkspacePageCaptureFailure("Public AX frame attributes had unexpected value types")
        }
        var point = CGPoint.zero, size = CGSize.zero
        let positionType = AXValueGetType(position as! AXValue)
        let dimensionsType = AXValueGetType(dimensions as! AXValue)
        let pointDecoded = AXValueGetValue(position as! AXValue, .cgPoint, &point)
        let sizeDecoded = AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
        do {
            return try Self.interpretObservedGeometry(identifier: identifier, role: role,
                positionType: positionType, sizeType: dimensionsType,
                pointDecoded: pointDecoded, sizeDecoded: sizeDecoded, point: point, size: size)
        } catch {
            frameFailure?([
                "classification": "Diagnostic only: actual public AX frame decode failure; original error remains unchanged",
                "identifier": identifier.map { String($0.prefix(128)) as Any } ?? NSNull(),
                "role": role.map { String($0.prefix(128)) as Any } ?? NSNull(),
                "position_AXValue_type": positionType.rawValue, "size_AXValue_type": dimensionsType.rawValue,
                "requested_position_type": AXValueType.cgPoint.rawValue, "requested_size_type": AXValueType.cgSize.rawValue,
                "point_decoded": pointDecoded, "size_decoded": sizeDecoded,
                "decoded_point": NSStringFromPoint(point), "decoded_size": NSStringFromSize(size),
                "point_finite": point.x.isFinite && point.y.isFinite,
                "size_finite": size.width.isFinite && size.height.isFinite,
                "size_nonnegative": size.width >= 0 && size.height >= 0,
            ])
            throw error
        }
    }

    static func interpretObservedGeometry(identifier: String?, role: String?,
        positionType: AXValueType, sizeType: AXValueType, pointDecoded: Bool, sizeDecoded: Bool,
        point: CGPoint, size: CGSize) throws -> (frame: NSRect?, unknown: [String: String]?) {
        guard positionType == .cgPoint, sizeType == .cgSize, pointDecoded, sizeDecoded else {
            throw NativeWorkspacePageCaptureFailure("Public AX frame could not be decoded as finite point/size")
        }
        if identifier == nil, role == "AXOpaqueProviderGroup",
           point.x == .infinity, point.y == .infinity, size.width == 0, size.height == 0 {
            return (nil, [
                "classification": "Unknown optional geometry: exact observed identifier-null opaque-group infinite-origin zero-extent signature; no finite frame or visibility inferred",
                "raw_position": NSStringFromPoint(point), "raw_size": NSStringFromSize(size),
                "position_AXValue_type": String(positionType.rawValue), "size_AXValue_type": String(sizeType.rawValue),
                "point_decoded": String(pointDecoded), "size_decoded": String(sizeDecoded),
            ])
        }
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else {
            throw NativeWorkspacePageCaptureFailure("Public AX frame could not be decoded as finite point/size")
        }
        return (NSRect(origin: point, size: size), nil)
    }

    private func enabled(_ element: AXUIElement, deadline: TimeInterval) throws -> Bool? {
        guard let value = try attribute(element, kAXEnabledAttribute, deadline: deadline) else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let flag = value as? NSNumber else {
            throw NativeWorkspacePageCaptureFailure("Public AX enabled attribute was not a boolean")
        }
        return flag.boolValue
    }

    private func actions(_ element: AXUIElement, deadline: TimeInterval) throws -> [String] {
        try prepare(element, deadline: deadline)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        try check(deadline)
        guard status == .success, let values = names as? [String], values.count <= 64 else {
            throw NativeWorkspacePageCaptureFailure("Public AX action names failed/exceeded their bound: AXError \(status.rawValue)")
        }
        return values
    }

    private func metadata(_ element: AXUIElement, deadline: TimeInterval,
                          frameFailure: (([String: Any]) -> Void)?) throws -> NativeWorkspacePageCaptureAXMetadata {
        let role = try string(element, kAXRoleAttribute, deadline: deadline)
        diagnosticProgress["current_node_role"] = role.map { String($0.prefix(128)) as Any } ?? NSNull()
        let identifier = try string(element, kAXIdentifierAttribute, deadline: deadline)
        diagnosticProgress["current_node_identifier"] = identifier.map { String($0.prefix(128)) as Any } ?? NSNull()
        let title = try string(element, kAXTitleAttribute, deadline: deadline)
        let label = try string(element, kAXDescriptionAttribute, deadline: deadline)
        let value = try attribute(element, kAXValueAttribute, deadline: deadline)
        let geometry = try frame(element, deadline: deadline, identifier: identifier, role: role, frameFailure: frameFailure)
        return try .init(identifier: identifier, role: role, title: title, label: label, value: value,
            frame: geometry.frame, unknownGeometry: geometry.unknown,
            enabled: enabled(element, deadline: deadline),
            actions: role == kAXButtonRole ? actions(element, deadline: deadline) : nil)
    }

    private func ancestors(_ element: AXUIElement, deadline: TimeInterval) throws -> [String] {
        guard let exportedWindow else { throw NativeWorkspacePageCaptureFailure("Public AX window scope was not bound") }
        var current = element, seen: [AXUIElement] = [element], identifiers: [String] = []
        while !CFEqual(current, exportedWindow) {
            try check(deadline)
            guard seen.count <= 64,
                  let rawParent = try attribute(current, kAXParentAttribute, deadline: deadline),
                  CFGetTypeID(rawParent) == AXUIElementGetTypeID() else {
                throw NativeWorkspacePageCaptureFailure("Public AX parent chain did not reach the exact owned window within its bound")
            }
            let parent = rawParent as! AXUIElement
            guard !seen.contains(where: { CFEqual($0, parent) }) else {
                throw NativeWorkspacePageCaptureFailure("Public AX parent chain repeated an element before its owned window")
            }
            seen.append(parent)
            if let identifier = try string(parent, kAXIdentifierAttribute, deadline: deadline), !identifier.isEmpty {
                identifiers.append(identifier)
            }
            current = parent
        }
        return Array(identifiers.reversed())
    }

    private func validatedApplicationContentZoom(_ root: AXUIElement, deadline: TimeInterval,
                                                requiredIdentifiers: Set<String>) throws -> AXUIElement {
        guard let raw = try attribute(root, kAXZoomButtonAttribute, deadline: deadline),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw NativeWorkspacePageCaptureFailure("Application-content scope requires the exact owned window's public Zoom reference")
        }
        let zoom = raw as! AXUIElement
        try prepare(zoom, deadline: deadline)
        _ = try ancestors(zoom, deadline: deadline)
        let role = try string(zoom, kAXRoleAttribute, deadline: deadline)
        let subrole = try string(zoom, kAXSubroleAttribute, deadline: deadline)
        guard role == kAXButtonRole, let subrole,
              subrole == kAXZoomButtonSubrole || subrole == kAXFullScreenButtonSubrole else {
            throw NativeWorkspacePageCaptureFailure("Application-content scope requires an owned standard Zoom/Full Screen AXButton")
        }
        var fullScreenMatches: Bool?
        if subrole == kAXFullScreenButtonSubrole {
            guard let rawFullScreen = try attribute(root, kAXFullScreenButtonAttribute, deadline: deadline),
                  CFGetTypeID(rawFullScreen) == AXUIElementGetTypeID() else {
                throw NativeWorkspacePageCaptureFailure("The Full Screen subrole lacks its exact owned window public reference")
            }
            let fullScreen = rawFullScreen as! AXUIElement
            try prepare(fullScreen, deadline: deadline)
            _ = try ancestors(fullScreen, deadline: deadline)
            fullScreenMatches = CFEqual(fullScreen, zoom)
            guard fullScreenMatches == true else {
                throw NativeWorkspacePageCaptureFailure("The owned Full Screen reference differs from its exact Zoom reference")
            }
        }
        let identifier = try string(zoom, kAXIdentifierAttribute, deadline: deadline)
        guard identifier.map({ !requiredIdentifiers.contains($0) }) ?? true else {
            throw NativeWorkspacePageCaptureFailure("Application-content scope cannot exclude a requested Forge identifier")
        }
        diagnosticProgress["standard_zoom_reference_validated"] = true
        diagnosticProgress["standard_zoom_role"] = role
        diagnosticProgress["standard_zoom_subrole"] = subrole
        diagnosticProgress["standard_zoom_identifier"] = identifier.map { String($0.prefix(128)) as Any } ?? NSNull()
        diagnosticProgress["full_screen_reference_matches_zoom"] = fullScreenMatches.map { $0 as Any } ?? NSNull()
        return zoom
    }

    private static func cachedMetadataText(_ text: String?) -> Any {
        guard let text else { return NSNull() }
        var bytes = Array(text.utf8.prefix(128))
        while !bytes.isEmpty {
            if let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
            bytes.removeLast()
        }
        return ""
    }

    private func retainCopiedChildFailureContext(records: [CopiedChildRecord], seen: [AXUIElement],
                                                 currentRecordIndex: Int?) {
        // This describes copied AXChildren edges only; it makes no additional AX query.
        diagnosticProgress["copied_child_failure_context"] = [
            "available": false,
            "classification": "No active bounded copied-child record at the fatal traversal exit; original progress/error remain authoritative",
        ]
        guard let currentRecordIndex, records.count == seen.count, records.count <= 4_096,
              records.indices.contains(currentRecordIndex) else { return }
        var reverseLineage: [Int] = [], cursor = currentRecordIndex
        while reverseLineage.count < 65 {
            guard records.indices.contains(cursor), seen.indices.contains(cursor) else { return }
            reverseLineage.append(cursor)
            guard let parent = records[cursor].parentRecordIndex else { break }
            guard parent >= 0, parent < cursor else { return }
            cursor = parent
        }
        guard let root = reverseLineage.last, root == 0,
              records[root].parentRecordIndex == nil, records[root].copiedChildIndex == nil else { return }
        let lineage = Array(reverseLineage.reversed())
        var copiedChildIndices: [Int] = []
        for index in lineage.dropFirst() {
            guard let childIndex = records[index].copiedChildIndex, childIndex >= 0,
                  childIndex < 4_096 else { return }
            copiedChildIndices.append(childIndex)
        }
        guard copiedChildIndices.count <= 64 else { return }
        let ancestors = Array(lineage.dropLast())
        let exportedAncestors = ancestors.suffix(8).map { index -> [String: Any] in
            ["run_local_record_index": index,
             "copied_child_index": records[index].copiedChildIndex.map { $0 as Any } ?? NSNull(),
             "metadata_completed": records[index].completedMetadata != nil,
             "completed_metadata": records[index].completedMetadata.map { $0 as Any } ?? NSNull()]
        }
        diagnosticProgress["copied_child_failure_context"] = [
            "available": true,
            "classification": "Cached original AXChildren copy lineage for the node active when traversal threw; not an observed AXParent chain or a child identity/cause diagnosis",
            "current_run_local_record_index": currentRecordIndex,
            "parent_run_local_record_index": records[currentRecordIndex].parentRecordIndex.map { $0 as Any } ?? NSNull(),
            "copied_child_index_path": copiedChildIndices,
            "copied_child_index_path_complete_to_exported_root": true,
            "copied_child_indices_are_zero_based": true,
            "current_metadata_completed": records[currentRecordIndex].completedMetadata != nil,
            "current_completed_metadata": records[currentRecordIndex].completedMetadata.map { $0 as Any } ?? NSNull(),
            "metadata_source": "Only already-returned complete metadata calls; partial current metadata remains solely in original progress",
            "metadata_field_UTF8_byte_limit": 128,
            "cached_record_count": records.count, "cached_record_limit": 4_096,
            "copied_lineage_edge_limit": 64,
            "copied_ancestor_count": ancestors.count,
            "nearest_ancestor_metadata_root_ordered": exportedAncestors,
            "ancestor_metadata_export_limit": 8,
            "ancestor_metadata_export_complete": ancestors.count <= 8,
        ]
        copiedChildFailureWitness = .init(reference: seen[currentRecordIndex],
            ancestorReferences: ancestors.map { seen[$0] }, copiedChildIndices: copiedChildIndices)
    }

    func typedZoomPostFailureRelationships(comparedTo fresh: NativeWorkspacePageCaptureAXScope,
        deadline: TimeInterval, requiredIdentifiers: Set<String>, ownerUnchanged: @MainActor () -> Bool) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let savedProgress = diagnosticProgress
        defer { diagnosticProgress = savedProgress }
        diagnosticProgress = [:]
        let originalWitness = copiedChildFailureWitness, freshWitness = fresh.copiedChildFailureWitness
        var report: [String: Any] = [
            "classification": "Post-failure typed public Zoom reference diagnostic only; no query to retained caught children, traversal replacement, stable identity, provider/native class or cause inference",
            "typed_zoom_validation_completed": false,
            "original_caught_node_reference_available": originalWitness != nil,
            "fresh_caught_node_reference_available": freshWitness != nil,
            "copied_ancestor_comparison_limit_per_scope": 64,
            "parent_edge_limit_per_reference": 64,
            "uses_existing_diagnostic_deadline": true,
            "expected_own_pid": pid,
        ]
        func diagnosticCheck() throws {
            try check(deadline)
            _ = try fresh.ownedWindow()
            guard ownerUnchanged(), window === fresh.window, hosting === fresh.hosting, pid == fresh.pid else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic lost its original route/layout/geometry or exact native owners")
            }
        }
        func rejectCaughtChild(_ reference: AXUIElement) throws {
            guard !(originalWitness.map { CFEqual(reference, $0.reference) } ?? false),
                  !(freshWitness.map { CFEqual(reference, $0.reference) } ?? false) else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic refused an extra query to a retained caught child")
            }
        }
        func checkedPrepare(_ reference: AXUIElement) throws {
            try diagnosticCheck(); try rejectCaughtChild(reference)
            try prepare(reference, deadline: deadline)
            try diagnosticCheck()
        }
        func checkedAttribute(_ reference: AXUIElement, _ name: String) throws -> CFTypeRef? {
            try diagnosticCheck(); try rejectCaughtChild(reference)
            let value = try attribute(reference, name, deadline: deadline)
            try diagnosticCheck()
            return value
        }
        func checkedString(_ reference: AXUIElement, _ name: String) throws -> String? {
            guard let value = try checkedAttribute(reference, name) else { return nil }
            guard let text = value as? String else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic attribute was not a string")
            }
            return text
        }
        func parentEdgesToRoot(_ reference: AXUIElement, root: AXUIElement) throws -> Int {
            try checkedPrepare(reference)
            var current = reference, seen: [AXUIElement] = [reference], edges = 0
            while !CFEqual(current, root) {
                try diagnosticCheck()
                guard edges < 64, let raw = try checkedAttribute(current, kAXParentAttribute),
                      CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                    throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic parent chain lacked a typed reference within 64 edges")
                }
                let parent = raw as! AXUIElement
                try checkedPrepare(parent)
                guard !seen.contains(where: { CFEqual($0, parent) }) else {
                    throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic parent chain repeated before its exact owned root")
                }
                seen.append(parent); current = parent; edges += 1
            }
            try diagnosticCheck()
            return edges
        }
        func relationships(_ zoom: AXUIElement, witness: CopiedChildFailureWitness?) throws -> [String: Any] {
            guard let witness else { return ["available": false] }
            guard witness.ancestorReferences.count <= 64, witness.copiedChildIndices.count <= 64 else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic cached witness exceeded its existing bound")
            }
            return [
                "available": true, "caught_reference_CFEqual_zoom": CFEqual(witness.reference, zoom),
                "copied_child_index_path": witness.copiedChildIndices,
                "root_first_copied_ancestor_CFEqual_zoom": witness.ancestorReferences.map { CFEqual($0, zoom) },
                "comparison_count": witness.ancestorReferences.count + 1,
                "classification": "Equality to retained copied-child positions; these positions are not an observed AXParent chain of the caught child",
            ]
        }
        do {
            try diagnosticCheck()
            guard originalWitness != nil, let root = exportedWindow, let freshRoot = fresh.exportedWindow,
                  CFEqual(root, freshRoot) else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic requires retained caught context and equal exact original/fresh owned roots")
            }
            report["original_fresh_exported_roots_CFEqual"] = true
            guard let rawZoom = try checkedAttribute(root, kAXZoomButtonAttribute),
                  CFGetTypeID(rawZoom) == AXUIElementGetTypeID() else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic lacks a typed public Zoom reference")
            }
            let zoom = rawZoom as! AXUIElement
            report["zoom_parent_edges_to_exact_root"] = try parentEdgesToRoot(zoom, root: root)
            let role = try checkedString(zoom, kAXRoleAttribute)
            let subrole = try checkedString(zoom, kAXSubroleAttribute)
            report["zoom_role"] = Self.cachedMetadataText(role)
            report["zoom_subrole"] = Self.cachedMetadataText(subrole)
            guard role == kAXButtonRole, let subrole,
                  subrole == kAXZoomButtonSubrole || subrole == kAXFullScreenButtonSubrole else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic requires an owned standard Zoom/Full Screen AXButton")
            }
            if subrole == kAXFullScreenButtonSubrole {
                guard let rawFullScreen = try checkedAttribute(root, kAXFullScreenButtonAttribute),
                      CFGetTypeID(rawFullScreen) == AXUIElementGetTypeID() else {
                    throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic lacks a typed public Full Screen reference")
                }
                let fullScreen = rawFullScreen as! AXUIElement
                report["full_screen_parent_edges_to_exact_root"] = try parentEdgesToRoot(fullScreen, root: root)
                let fullScreenMatches = CFEqual(fullScreen, zoom)
                report["full_screen_reference_CFEqual_zoom"] = fullScreenMatches
                guard fullScreenMatches else {
                    throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic public Full Screen and Zoom references differ")
                }
            }
            let identifier = try checkedString(zoom, kAXIdentifierAttribute)
            report["zoom_identifier"] = Self.cachedMetadataText(identifier)
            guard identifier.map({ !requiredIdentifiers.contains($0) }) ?? true else {
                throw NativeWorkspacePageCaptureFailure("Typed Zoom diagnostic public reference matches a requested Forge identifier")
            }
            try diagnosticCheck()
            report["original_copied_reference_relationships"] = try relationships(zoom, witness: originalWitness)
            report["fresh_copied_reference_relationships"] = try relationships(zoom, witness: freshWitness)
            try diagnosticCheck()
            report["typed_zoom_validation_completed"] = true
        } catch {
            report["post_failure_diagnostic_error"] = String(String(describing: error).prefix(4_096))
        }
        report["post_failure_query_progress"] = diagnosticProgress
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        report["finished_before_existing_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
        return report
    }

    func copiedFailureIdentityWitnesses(comparedTo fresh: NativeWorkspacePageCaptureAXScope) -> [String: Any] {
        // Release both run-local reference sets after their pure comparison, before JSON retention.
        defer { copiedChildFailureWitness = nil; fresh.copiedChildFailureWitness = nil }
        var report: [String: Any] = [
            "classification": "Run-local CFEqual witnesses on retained original/fresh copied-child references; no additional AX query, stable identity, AXParent proof, Zoom classification or cause inference",
            "original_caught_node_reference_available": copiedChildFailureWitness != nil,
            "fresh_caught_node_reference_available": fresh.copiedChildFailureWitness != nil,
            "current_references_CFEqual": NSNull(),
            "ancestor_comparison_limit": 64,
            "ancestor_alignment": "Root-first copied-child positions only; matching positions are not assumed to be homologous nodes",
            "false_witness_interpretation": "Non-equivalence does not exclude logical-control recreation",
        ]
        guard let original = copiedChildFailureWitness, let renewed = fresh.copiedChildFailureWitness else {
            report["comparison_available"] = false
            return report
        }
        let count = min(64, min(original.ancestorReferences.count, renewed.ancestorReferences.count))
        report["comparison_available"] = true
        report["current_references_CFEqual"] = CFEqual(original.reference, renewed.reference)
        report["original_copied_child_index_path"] = original.copiedChildIndices
        report["fresh_copied_child_index_path"] = renewed.copiedChildIndices
        report["copied_child_index_paths_equal"] = original.copiedChildIndices == renewed.copiedChildIndices
        report["original_copied_ancestor_count"] = original.ancestorReferences.count
        report["fresh_copied_ancestor_count"] = renewed.ancestorReferences.count
        report["ancestor_comparison_count"] = count
        report["root_first_positional_ancestor_CFEqual"] = (0..<count).map {
            CFEqual(original.ancestorReferences[$0], renewed.ancestorReferences[$0])
        }
        report["total_CFEqual_comparison_count"] = count + 1
        return report
    }

    func observe(deadline requestedDeadline: TimeInterval? = nil,
                 scope: NativeWorkspacePageCaptureObservationScope = .wholeWindow,
                 requiredIdentifiers: Set<String> = [],
                 frameFailure: (([String: Any]) -> Void)? = nil) throws -> [NativeWorkspacePageCaptureSemantic] {
        let deadline = min(ProcessInfo.processInfo.systemUptime + 5, requestedDeadline ?? .infinity)
        diagnosticProgress = ["visited_node_count": 0, "completed_semantic_count": 0]
        copiedChildFailureWitness = nil
        let owned = try ownedWindow()
        let application = AXUIElementCreateApplication(pid)
        let windows = try elements(application, kAXWindowsAttribute, limit: 32, deadline: deadline)
        let matches = try windows.filter { try string($0, kAXTitleAttribute, deadline: deadline) == owned.title }
        diagnosticProgress["own_exported_window_count"] = windows.count
        diagnosticProgress["exact_owned_window_match_count"] = matches.count
        guard matches.count <= 1 else {
            throw NativeWorkspacePageCaptureFailure("Public AX exported duplicate exact owned-window titles: \(matches.count)")
        }
        guard let match = matches.first else {
            throw NativeWorkspacePageCaptureFailure("Public AX did not export the exact owned window; absence of panel elements is unqualified")
        }
        exportedWindow = match
        let excludedZoom: AXUIElement?
        if scope == .applicationContent {
            diagnosticProgress["observation_scope"] = scope.rawValue
            diagnosticProgress["standard_zoom_reference_validated"] = false
            diagnosticProgress["standard_zoom_descendant_expansion_omitted"] = false
            excludedZoom = try validatedApplicationContentZoom(match, deadline: deadline,
                requiredIdentifiers: requiredIdentifiers)
        } else { excludedZoom = nil }
        var pending: [(AXUIElement, [String], Int, Int?, Int?)] = [(match, [], 0, nil, nil)]
        var seen: [AXUIElement] = [], result: [NativeWorkspacePageCaptureSemantic] = []
        var copiedChildRecords: [CopiedChildRecord] = [], currentRecordIndex: Int? = nil
        do {
            while let (reference, pathAncestors, depth, parentRecordIndex, copiedChildIndex) = pending.popLast() {
                currentRecordIndex = nil
                try check(deadline)
                guard !seen.contains(where: { CFEqual($0, reference) }) else { continue }
                guard seen.count < 4_096, depth <= 64 else {
                    throw NativeWorkspacePageCaptureFailure("Public AX tree exceeded its explicit node/depth bound")
                }
                seen.append(reference)
                if scope == .wholeWindow {
                    currentRecordIndex = copiedChildRecords.count
                    copiedChildRecords.append(.init(parentRecordIndex: parentRecordIndex,
                        copiedChildIndex: copiedChildIndex, completedMetadata: nil))
                }
                diagnosticProgress["visited_node_count"] = seen.count
                diagnosticProgress["completed_semantic_count"] = result.count
                diagnosticProgress["pending_node_count"] = pending.count
                diagnosticProgress["current_node_depth"] = depth
                diagnosticProgress["current_node_identifier"] = NSNull()
                diagnosticProgress["current_node_role"] = NSNull()
                let observed = try metadata(reference, deadline: deadline, frameFailure: frameFailure)
                if let currentRecordIndex {
                    copiedChildRecords[currentRecordIndex].completedMetadata = [
                        "role": Self.cachedMetadataText(observed.role),
                        "identifier": Self.cachedMetadataText(observed.identifier),
                        "title": Self.cachedMetadataText(observed.title),
                    ]
                }
                let identifier = observed.identifier ?? "", title = observed.title ?? "", label = observed.label ?? ""
                let value = (observed.value as? String) ?? (observed.value as? NSNumber)?.stringValue ?? ""
                var lineage = pathAncestors
                for id in try ancestors(reference, deadline: deadline) where !lineage.contains(id) { lineage.append(id) }
                guard lineage.count <= 64 else { throw NativeWorkspacePageCaptureFailure("Public AX identifier ancestry exceeded its bound") }
                if !identifier.isEmpty || !title.isEmpty || !label.isEmpty || !value.isEmpty || observed.unknownGeometry != nil {
                    let element = NativeWorkspacePageCaptureElement.publicAX(.init(reference, metadata: observed, scope: self))
                    result.append(.init(element: element, identifier: String(identifier.prefix(128)),
                        role: observed.role ?? "", title: String(title.prefix(512)), label: String(label.prefix(512)),
                        value: String(value.prefix(512)), ancestors: lineage, frame: observed.frame,
                        exposed: nil, enabled: observed.enabled))
                }
                if let excludedZoom, CFEqual(reference, excludedZoom) {
                    guard !requiredIdentifiers.contains(identifier) else {
                        throw NativeWorkspacePageCaptureFailure("The validated standard Zoom changed into a requested Forge target")
                    }
                    diagnosticProgress["standard_zoom_descendant_expansion_omitted"] = true
                    continue
                }
                let nextAncestors = identifier.isEmpty ? pathAncestors : pathAncestors + [identifier]
                let children = try elements(reference, kAXChildrenAttribute,
                    limit: 4_096 - seen.count - pending.count, deadline: deadline)
                if scope == .wholeWindow {
                    for (childIndex, child) in children.enumerated().reversed() {
                        pending.append((child, nextAncestors, depth + 1, currentRecordIndex, childIndex))
                    }
                } else {
                    for child in children.reversed() { pending.append((child, nextAncestors, depth + 1, nil, nil)) }
                }
                currentRecordIndex = nil
            }
        } catch {
            if scope == .wholeWindow {
                retainCopiedChildFailureContext(records: copiedChildRecords, seen: seen,
                    currentRecordIndex: currentRecordIndex)
            }
            throw error
        }
        try check(deadline)
        diagnosticProgress["visited_node_count"] = seen.count
        diagnosticProgress["completed_semantic_count"] = result.count
        diagnosticProgress["pending_node_count"] = 0
        diagnosticProgress["snapshot_completed"] = true
        return result
    }

    func copyValue(of element: AXUIElement) throws -> Any? {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        _ = try ancestors(element, deadline: deadline)
        return try attribute(element, kAXValueAttribute, deadline: deadline)
    }

    func press(_ element: AXUIElement) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        _ = try ancestors(element, deadline: deadline)
        guard try string(element, kAXRoleAttribute, deadline: deadline) == kAXButtonRole,
              try enabled(element, deadline: deadline) == true,
              try actions(element, deadline: deadline).contains(kAXPressAction) else {
            throw NativeWorkspacePageCaptureFailure("The exact owned public AX element was not an enabled button advertising press")
        }
        try prepare(element, deadline: deadline)
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        try check(deadline)
        guard status == .success else {
            throw NativeWorkspacePageCaptureFailure("The actual owned public AX button press failed: AXError \(status.rawValue)")
        }
    }
}

@MainActor
private enum NativeWorkspacePageCaptureElement {
    case publicAX(NativeWorkspacePageCaptureAXElement)
    case formal(any NSAccessibilityProtocol)
    case informal(NSObject, Set<NSAccessibility.Attribute>)

    init(_ value: Any) throws {
        if let formal = value as? any NSAccessibilityProtocol {
            self = .formal(formal)
        } else if let object = value as? NSObject {
            let attributes = object.accessibilityAttributeNames()
            guard attributes.count <= 256 else {
                throw NativeWorkspacePageCaptureFailure("Public informal accessibility attribute names exceeded their finite bound")
            }
            self = .informal(object, Set(attributes))
        } else {
            throw NativeWorkspacePageCaptureFailure("A public native accessibility object (\(String(describing: type(of: value)))) supported neither the formal protocol nor the NSObject informal bridge")
        }
    }

    var object: AnyObject {
        switch self {
        case .publicAX(let element): element.reference as AnyObject
        case .formal(let element): element as AnyObject
        case .informal(let object, _): object
        }
    }
    var identity: ObjectIdentifier { ObjectIdentifier(object) }
    var observationAPI: String {
        switch self {
        case .publicAX: "AXUIElement own-process exact-owned-window exported tree"
        case .formal: "NSAccessibilityProtocol"
        case .informal: "NSObject public informal accessibility"
        }
    }
    private func informalValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard case .informal(let object, let attributes) = self, attributes.contains(attribute) else { return nil }
        return object.accessibilityAttributeValue(attribute)
    }
    func accessibilityIdentifier() -> String? {
        if case .publicAX(let element) = self { return element.metadata.identifier }
        if case .formal(let element) = self { return element.accessibilityIdentifier() }
        return informalValue(.identifier) as? String
    }
    func accessibilityRole() -> String? {
        if case .publicAX(let element) = self { return element.metadata.role }
        if case .formal(let element) = self { return element.accessibilityRole()?.rawValue }
        let role = informalValue(.role)
        return (role as? String) ?? (role as? NSAccessibility.Role)?.rawValue
    }
    func accessibilityTitle() -> String? {
        if case .publicAX(let element) = self { return element.metadata.title }
        if case .formal(let element) = self { return element.accessibilityTitle() }
        return informalValue(.title) as? String
    }
    func accessibilityLabel() -> String? {
        if case .publicAX(let element) = self { return element.metadata.label }
        if case .formal(let element) = self { return element.accessibilityLabel() }
        return informalValue(.description) as? String
    }
    func accessibilityValue() -> Any? {
        if case .publicAX(let element) = self { return element.metadata.value }
        if case .formal(let element) = self { return element.accessibilityValue() }
        return informalValue(.value)
    }
    func accessibilityParent() -> Any? {
        // Exported AX ancestry is read by its throwing, exact-window scope owner.
        if case .publicAX = self { return nil }
        if case .formal(let element) = self { return element.accessibilityParent() }
        return informalValue(.parent)
    }
    func accessibilityChildren() throws -> [Any] {
        if case .publicAX = self {
            throw NativeWorkspacePageCaptureFailure("Exported AX children must use the bounded exact-window observer")
        }
        var lists: [[Any]] = []
        var informalChildren: Any?
        if case .formal(let element) = self {
            lists.append(element.accessibilityChildren() ?? [])
            if let object = element as? NSObject {
                let attributes = object.accessibilityAttributeNames()
                guard attributes.count <= 256 else {
                    throw NativeWorkspacePageCaptureFailure("Public informal accessibility attribute names exceeded their finite bound")
                }
                if attributes.contains(.children) {
                    informalChildren = object.accessibilityAttributeValue(.children)
                }
            }
        } else {
            informalChildren = informalValue(.children)
        }
        if let informalChildren {
            guard let array = informalChildren as? [Any] else {
                throw NativeWorkspacePageCaptureFailure("Advertised public informal accessibility children (\(String(describing: type(of: informalChildren)))) were not an array")
            }
            lists.append(array)
        }
        var children: [Any] = []
        var seen = Set<ObjectIdentifier>()
        for list in lists {
            guard list.count <= 4_096 else {
                throw NativeWorkspacePageCaptureFailure("A public accessibility child list exceeded the explicit node bound")
            }
            for child in list {
                let object: AnyObject
                if let formal = child as? any NSAccessibilityProtocol { object = formal as AnyObject }
                else if let informal = child as? NSObject { object = informal }
                else {
                    throw NativeWorkspacePageCaptureFailure("A public native accessibility child (\(String(describing: type(of: child)))) supported neither the formal protocol nor the NSObject informal bridge")
                }
                guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
                guard children.count < 4_096 else {
                    throw NativeWorkspacePageCaptureFailure("The public accessibility child union exceeded the explicit node bound")
                }
                children.append(child)
            }
        }
        return children
    }
    var unknownGeometry: [String: String]? {
        if case .publicAX(let element) = self { return element.metadata.unknownGeometry }
        return nil
    }
    func accessibilityFrame() -> NSRect? {
        if case .publicAX(let element) = self { return element.metadata.frame }
        if case .formal(let element) = self { return element.accessibilityFrame() }
        guard let position = informalValue(.position) as? NSValue,
              let size = informalValue(.size) as? NSValue else { return nil }
        return NSRect(origin: position.pointValue, size: size.sizeValue)
    }
    func isAccessibilityElement() -> Bool? {
        switch self {
        case .publicAX: nil // The public exported tree does not report this formal-protocol boolean.
        case .formal(let element): element.isAccessibilityElement()
        case .informal(let object, _): !object.accessibilityIsIgnored()
        }
    }
    func isAccessibilityEnabled() -> Bool? {
        if case .publicAX(let element) = self { return element.metadata.enabled }
        if case .formal(let element) = self { return element.isAccessibilityEnabled() }
        return (informalValue(.enabled) as? NSNumber)?.boolValue
    }
    func copyAccessibilityValue() throws -> Any? {
        if case .publicAX(let element) = self { return try element.copyValue() }
        return accessibilityValue()
    }
    var advertisedPress: Bool? {
        guard case .publicAX(let element) = self, let actions = element.metadata.actions else { return nil }
        return actions.contains(kAXPressAction)
    }
    func performPress() throws {
        switch self {
        case .publicAX(let element): try element.press()
        case .formal(let element):
            guard element.accessibilityPerformPress() else {
                throw NativeWorkspacePageCaptureFailure("The actual production button refused its public formal accessibility press")
            }
        case .informal(let object, _):
            let actions = object.accessibilityActionNames()
            guard actions.count <= 64, actions.contains(.press) else {
                throw NativeWorkspacePageCaptureFailure("The actual production button did not advertise a bounded public informal press action")
            }
            object.accessibilityPerformAction(.press)
        }
    }
}

@MainActor
private struct NativeWorkspacePageCaptureSemantic {
    let element: NativeWorkspacePageCaptureElement
    let identifier: String
    let role: String
    let title: String
    let label: String
    let value: String
    let ancestors: [String]
    let frame: NSRect?
    let exposed: Bool?
    let enabled: Bool?
    var dictionary: [String: Any] {
        ["identifier": identifier, "role": role, "title": title, "label": label, "value": value,
         "ancestor_ids": ancestors, "frame": frame.map { NSStringFromRect($0) as Any } ?? NSNull(),
         "unknown_geometry": element.unknownGeometry.map { $0 as Any } ?? NSNull(),
         "exposed": exposed.map { $0 as Any } ?? NSNull(), "enabled": enabled.map { $0 as Any } ?? NSNull(),
         "advertised_press": element.advertisedPress.map { $0 as Any } ?? NSNull(),
         "observation_api": element.observationAPI, "object_type": String(describing: type(of: element.object))]
    }
}

private enum NativeWorkspaceCapturePage: String, CaseIterable {
    case rig, mcp, agents, tools, feed, projects, runeForge, continuity, runtimes, provider, evidence, diagnostics, manager
    var viewID: String { self == .runeForge ? "rune-forge.overview" : self == .manager ? "manager.folders" : rawValue }
    var title: String {
        switch self {
        case .rig: "Dashboard"
        case .mcp: "LM Studio · MCP"
        case .agents: "Agents"
        case .tools: "Tools"
        case .feed: "Live Feed"
        case .projects: "Projects"
        case .runeForge: "Rune Forge"
        case .continuity: "Continuity"
        case .runtimes: "Runtimes"
        case .provider: "Provider"
        case .evidence: "Events & Evidence"
        case .diagnostics: "Diagnostics"
        case .manager: "Authorized Folders"
        }
    }
    var marker: String { self == .runeForge ? "rune-forge-view" : "detail-" + rawValue }
    var headingPanelID: String {
        switch self {
        case .rig: "rig-header"
        case .mcp: "mcp-controls"
        case .agents: "agents-controls"
        case .tools: "tools-controls"
        case .feed: "feed-summary"
        case .projects: "projects-status"
        case .runeForge: "rune-controls"
        case .continuity: "continuity-controls"
        case .runtimes: "runtimes-controls"
        case .provider: "provider-controls"
        case .evidence: "evidence-controls"
        case .diagnostics: "diagnostics-controls"
        case .manager: "manager-header"
        }
    }
}

@MainActor
private final class NativeWorkspacePageCaptureRoute: ObservableObject {
    @Published var page: NativeWorkspaceCapturePage = .rig
}

@MainActor
private struct NativeWorkspacePageCaptureContent: View {
    @ObservedObject var route: NativeWorkspacePageCaptureRoute
    let client: OperatorManagerClientRouter
    let initialManagerSection: ManagerSettingsView.ManagementSection
    var body: some View {
        Group {
            switch route.page {
            case .rig: RigDashboardView()
            case .mcp: MCPServersView()
            case .agents: AgentsView()
            case .tools: ToolsView()
            case .feed: LiveFeedView()
            case .projects: ProjectsOperatorView(client: client)
            case .runeForge: RuneForgeOperatorView(client: client)
            case .continuity: ContinuityOperatorView(client: client)
            case .runtimes: RuntimesOperatorView(client: client)
            case .provider: ProviderOperatorView(client: client)
            case .evidence: EvidenceOperatorView(client: client)
            case .diagnostics: DiagnosticsView()
            case .manager: ManagerSettingsView(initialSection: initialManagerSection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
private final class NativeWorkspacePageCaptureFixture {
    let suite: String
    let home: URL
    let defaults: UserDefaults
    let preferences: NativeWorkspacePreferences
    let workbench: WorkbenchPreferences
    let guided: GuidedModeCoordinator
    let model: AppModel
    let client: NativeWorkspacePageCaptureClient
    let route: NativeWorkspacePageCaptureRoute
    let hosting: NSHostingView<AnyView>
    let window: NSWindow

    init(contentSize: NSSize, populatedProvider: Bool = false,
         initialManagerSection: ManagerSettingsView.ManagementSection = .folders) throws {
        let localSuite = "forge.workspace.pages.tests.\(UUID().uuidString)"
        let localHome = FileManager.default.temporaryDirectory.appendingPathComponent("forge-workspace-pages-\(UUID().uuidString)")
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: localSuite))
        let preferencesOwner = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: localDefaults)
        let workbenchOwner = WorkbenchPreferences(defaults: localDefaults)
        let guidedOwner = GuidedModeCoordinator(defaults: localDefaults)
        let fake = try NativeWorkspacePageCaptureClient(root: localHome.appendingPathComponent("project").path,
                                                        populatedProvider: populatedProvider)
        let bootstrap = AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil })
        let modelOwner = AppModel(bootstrapOperation: bootstrap, diagnosticPaths: AppPaths(home: localHome))
        modelOwner.autoRefresh = false
        modelOwner.operatorManagerClient.replace(with: fake)
        let routeOwner = NativeWorkspacePageCaptureRoute()
        let nativeHost = NSHostingView(rootView: AnyView(NativeWorkspacePageCaptureContent(route: routeOwner,
            client: modelOwner.operatorManagerClient, initialManagerSection: initialManagerSection)
            .environmentObject(modelOwner).environmentObject(workbenchOwner).environmentObject(guidedOwner)
            .environment(\.nativeWorkspacePreferences, preferencesOwner).graphiteWorkbench()))
        nativeHost.sizingOptions = []
        let nativeWindow = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: contentSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.title = "Production workspace pages \(UUID().uuidString)"
        nativeWindow.contentView = nativeHost
        nativeWindow.setContentSize(contentSize)
        suite = localSuite; home = localHome; defaults = localDefaults; preferences = preferencesOwner
        workbench = workbenchOwner; guided = guidedOwner; model = modelOwner; client = fake; route = routeOwner
        hosting = nativeHost; window = nativeWindow
    }

    func customize(_ viewID: String) throws -> NativeWorkspaceLayout {
        let descriptors = try XCTUnwrap(NativeWorkspaceCatalog.panelsByView[viewID])
        let width = max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0)
        let height = max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)
        let layout = NativeWorkspaceLayout(id: UUID(), viewID: viewID, name: "Native page capture",
            canvas: .init(width: width, height: height),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        try preferences.save(layout)
        return layout
    }

    func close() async {
        window.endEditing(for: nil); _ = window.makeFirstResponder(nil)
        hosting.rootView = AnyView(EmptyView())
        window.orderOut(nil); window.contentView = nil; window.close()
        model.stopRigOperationalMonitoring()
        await model.stopBootstrap()
        model.telemetryBinding.detach()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }
}

private actor NativeWorkspacePageCaptureClient: OperatorManagerClientProtocol {
    private let project: OperatorProject
    private let snapshotValue: OperatorSnapshot
    private var snapshotReads = 0
    private var queueReads = 0
    private var providerConfigurationReads = 0
    private var providerIntegrationReads = 0
    private var mutations = Set<String>()
    private let populatedProvider: Bool

    init(root: String, populatedProvider: Bool = false) throws {
        self.populatedProvider = populatedProvider
        let object: [String: Any] = ["project_id": "11111111-1111-4111-8111-111111111111",
            "display_name": "Workspace Fixture Project", "canonical_root": root,
            "project_generation": 4, "lifecycle_state": "active", "bindings": [],
            "memory": ["state": "healthy", "database_bytes": 0, "record_count": 0],
            "continuity": ["state": "ready", "migration_state": "not_required"], "migration_warnings": []]
        project = try Self.decode(OperatorProject.self, object)
        var snapshotObject: [String: Any] = ["projects": [object]]
        if populatedProvider {
            let providerObject: [String: Any] = ["adapter_id": "fixture-advanced-adapter", "provider_id": "lmstudio",
                "health": "contract_valid", "endpoint": "http://127.0.0.1:4321", "loopback": true,
                "tls": false, "authentication_enabled": false, "credential_configured": false,
                "api_mode": "managed_provider", "model_key": "fixture/advanced-parity-model",
                "instance_id": "fixture-advanced-instance", "active_context_length": 8_192,
                "maximum_context_length": 32_768, "tool_use_capable": true,
                "lifecycle_management_enabled": true, "idle_ttl_seconds": 73,
                "contract_fingerprint": String(repeating: "a", count: 64), "last_probe_mode": "contract",
                "probe_result_storage": "memory_only", "last_probe_at": "2026-10-09T12:34:56Z"]
            snapshotObject["provider"] = providerObject
        }
        snapshotValue = try Self.decode(OperatorSnapshot.self, snapshotObject)
    }

    func projectsDidLoad() -> Bool { snapshotReads > 0 && queueReads > 0 }
    func providerDidLoad() -> Bool { snapshotReads > 0 && providerConfigurationReads > 0 && providerIntegrationReads > 0 }
    func mutationNames() -> Set<String> { mutations }
    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot {
        guard snapshotReads < 4_096 else { throw NativeWorkspacePageCaptureFailure("Fixture snapshot request bound exceeded") }
        snapshotReads += 1; return snapshotValue
    }
    func projectStatus(projectID: String) async throws -> OperatorProject { project }
    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        guard projectID == project.projectID, generation == project.projectGeneration, queueReads < 4_096 else {
            throw NativeWorkspacePageCaptureFailure("Fixture queue identity/request bound failed")
        }
        queueReads += 1
        return try Self.decode(OperatorInstructionQueue.self, ["project_id": projectID, "project_generation": generation,
            "revision": 1, "running": false, "packages": []])
    }
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
        guard providerConfigurationReads < 4_096 else { throw NativeWorkspacePageCaptureFailure("Fixture Provider configuration request bound exceeded") }
        providerConfigurationReads += 1
        return .init(revision: "workspace-fixture-1",
            endpoint: populatedProvider ? "http://127.0.0.1:4321" : "http://127.0.0.1:1234",
            modelKey: populatedProvider ? "fixture/advanced-parity-model" : nil,
            credentialConfigured: false, saved: populatedProvider)
    }
    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot {
        guard providerIntegrationReads < 4_096 else { throw NativeWorkspacePageCaptureFailure("Fixture Provider registry request bound exceeded") }
        providerIntegrationReads += 1
        return .init(selectionRevision: "workspace-fixture-1", selectedProviderID: populatedProvider ? .lmStudio : nil,
            providers: populatedProvider ? ProviderIntegrationDescriptor.supported.map {
                ProviderIntegrationProviderSnapshot(descriptor: $0, receipt: nil)
            } : [], currentOperation: nil, recentOperations: [])
    }
    func autonomyStatus() async throws -> OperatorAutonomySummary { throw unavailable("autonomyStatus") }
    func settings() async throws -> ManagerSettings { throw unavailable("settings") }
    func providerModels() async throws -> ProviderModelInventory { throw unavailable("providerModels") }
    func runStatus(runID: String) async throws -> OperatorRun { throw unavailable("runStatus") }
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings { throw mutation("updateSettings") }
    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProjectRegistrationOutcome { throw mutation("registerProject") }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt { throw mutation("resetProject") }
    func relinkProject(projectID: String, generation: UInt64, path: String) async throws -> OperatorRelinkReceipt { throw mutation("relinkProject") }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { throw mutation("startRun") }
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun { throw mutation("controlRun") }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob { throw mutation("cancelRuntimeJob") }
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot { throw mutation("updateProviderConfiguration") }
    func probeProvider(adapterID: String, mode: OperatorProviderProbeMode) async throws -> OperatorProvider { throw mutation("probeProvider") }
    private func unavailable(_ method: String) -> OperatorManagerClientError {
        .capabilityUnavailable("\(method) is intentionally unavailable in the isolated native page capture fixture")
    }
    private func mutation(_ method: String) -> NativeWorkspacePageCaptureFailure {
        mutations.insert(method)
        return .init("Unexpected mutation in native page capture: \(method)")
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}
#endif
