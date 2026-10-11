import AppKit
import Foundation
import XCTest
#if !SWIFT_PACKAGE
import SwiftUI
import ApplicationServices
#endif
@testable import ForgeConductorCore
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class RuneForgeAppTests: XCTestCase {
    #if !SWIFT_PACKAGE


    func testPlainAppKitZoomSubtreeBeforeDuringAfterSheetAcrossRuneWindowStyles() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run the plain AppKit control in ForgeConductorAppTests with a native display.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        var rows: [[String: Any]] = [], firstScalarError: Error?
        func retain(_ error: Error? = nil) throws {
            let payload: [String: Any] = ["classification": "Synthetic plain AppKit standard-control/sheet lifecycle comparison; not product naming or full-UI proof",
                "shared_budget_seconds": 35, "per_phase_query_budget_seconds": 3, "expected_phase_rows": 6,
                "rows": rows, "all_six_phases_recorded": rows.count == 6,
                "error_description": error.map { String(String(describing: $0).prefix(512)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 512 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Plain AppKit control report exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "plain-appkit-zoom-sheet-control"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        do {
            for miniaturizable in [false, true] {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw RuneWorkspaceVisibilityFailure("Plain AppKit control exceeded its shared deadline.")
                }
                var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
                if miniaturizable { style.insert(.miniaturizable) }
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_280, height: 900),
                    styleMask: style, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Plain Rune window control \(UUID().uuidString)"
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 900))
                window.contentView = host
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                    styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false; sheet.title = "Plain attached sheet \(UUID().uuidString)"
                let sheetHost = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
                sheet.contentView = sheetHost
                defer {
                    if window.attachedSheet === sheet { window.endSheet(sheet) }
                    sheet.orderOut(nil); sheet.contentView = nil; sheet.close()
                    window.orderOut(nil); window.contentView = nil; window.close()
                }
                let observer = RuneWorkspaceNamingAX(window: window, hosting: host)
                func ready(_ during: Bool) -> Bool {
                    guard NSApp.isActive, window.isVisible, window.styleMask == style,
                          host.frame.size == NSSize(width: 1_280, height: 900),
                          window.contentView === host, host.window === window,
                          !host.isHiddenOrHasHiddenAncestor,
                          let nativeZoom = window.standardWindowButton(.zoomButton), nativeZoom.window === window else { return false }
                    if during {
                        return sheet.isKeyWindow && NSApp.keyWindow === sheet
                            && window.attachedSheet === sheet && window.sheets.count == 1 && window.sheets.first === sheet
                            && sheet.sheetParent === window && sheet.isVisible && sheet.contentView === sheetHost
                            && sheetHost.window === sheet && !sheetHost.isHiddenOrHasHiddenAncestor
                    }
                    return window.isKeyWindow && NSApp.keyWindow === window
                        && window.attachedSheet == nil && window.sheets.isEmpty && sheet.sheetParent == nil && !sheet.isVisible
                }
                func awaitReady(_ during: Bool) async throws {
                    let readyDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
                    while !ready(during) {
                        try Task.checkCancellation()
                        guard ProcessInfo.processInfo.systemUptime < readyDeadline else {
                            throw RuneWorkspaceVisibilityFailure("Plain AppKit control lost exact window/sheet readiness.")
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < readyDeadline else {
                        throw RuneWorkspaceVisibilityFailure("Plain AppKit readiness completed after its deadline.")
                    }
                }
                func record(_ phase: String, during: Bool) throws {
                    guard ready(during), rows.count < 6 else {
                        throw RuneWorkspaceVisibilityFailure("Plain AppKit phase lacks exact native ownership or row capacity.")
                    }
                    let nativeZoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
                    var row: [String: Any] = ["phase": phase, "miniaturizable": miniaturizable,
                        "style_mask": Int(window.styleMask.rawValue), "native_window_visible": window.isVisible, "native_application_active": NSApp.isActive,
                        "native_exact_phase_key_owner": during ? NSApp.keyWindow === sheet : NSApp.keyWindow === window,
                        "native_exact_style": window.styleMask == style, "native_content_width": host.frame.width, "native_content_height": host.frame.height,
                        "native_window_key": window.isKeyWindow, "native_window_main": window.isMainWindow,
                        "native_content_exact": window.contentView === host && host.window === window,
                        "native_standard_zoom_owned": nativeZoom.window === window,
                        "native_standard_zoom_enabled": nativeZoom.isEnabled, "native_standard_zoom_hidden": nativeZoom.isHiddenOrHasHiddenAncestor,
                        "native_sheet_count": window.sheets.count, "native_exact_sheet_attached": window.attachedSheet === sheet,
                        "native_exact_sheet_parent": sheet.sheetParent === window, "native_sheet_visible": sheet.isVisible]
                    do {
                        if let error = try observer.observePlainAppKitStandardZoom(
                            deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3), report: &row), firstScalarError == nil {
                            firstScalarError = error
                        }
                        guard ready(during) else { throw RuneWorkspaceVisibilityFailure("Plain AppKit ownership changed during the query.") }
                        row["native_phase_owner_after_query"] = true; rows.append(row)
                    } catch {
                        row["strict_phase_error"] = String(String(describing: error).prefix(512)); rows.append(row); throw error
                    }
                }
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
                try await awaitReady(false); try record("before-sheet", during: false)
                window.beginSheet(sheet, completionHandler: nil); sheet.makeKeyAndOrderFront(nil)
                try await awaitReady(true); try record("during-sheet", during: true)
                window.endSheet(sheet); sheet.orderOut(nil); window.makeKeyAndOrderFront(nil)
                try await awaitReady(false); try record("after-sheet", during: false)
            }
            guard rows.count == 6, ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuneWorkspaceVisibilityFailure("Plain AppKit comparison did not complete its six bounded lifecycle rows.")
            }
            if let firstScalarError { throw firstScalarError }
            try retain()
        } catch {
            let finalError = firstScalarError ?? error
            try? retain(finalError); throw finalError
        }
    }

    func testMountedRuneParentCloseWhileRenameDraftPreservesStateAndOwnedReturn() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run the naming Close observation in ForgeConductorAppTests with a native display.")
        }
        let priorContinuation = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = priorContinuation }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        let source = DevelopmentPolicySource(displayName: "Naming Close policy",
            selectedPath: "/tmp/rune-naming-close-policy.md", interpretationState: .cataloging)
        let runeModel = RuneForgeViewModel(client: RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source])))
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Close-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        let draft = "Held-" + UUID().uuidString
        var stage = "mount", rows: [[String: Any]] = [], menus: [[String: Any]] = []
        var before: NativeWorkspaceCollection?, beforeBytes: Data?
        var heldSheet: NSWindow?, heldContent: NSView?, heldField: NSTextField?
        var witness: [String: Any] = ["parent_performClose_attempts": 0, "actual_Return_attempted": false,
            "actual_Return_returned": false, "fixture_close_returned": false]
        func check(reserving seconds: TimeInterval = 0) throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime + seconds < deadline else {
                throw RuneWorkspaceVisibilityFailure("Naming Close exceeded its shared 45-second admission/return deadline.")
            }
        }
        func requireUnchanged() throws {
            try check()
            guard let before, let beforeBytes, fixture.preferences.collection == before,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
                throw RuneWorkspaceVisibilityFailure("Naming Close wrote saved layouts before an owned Return.")
            }
        }
        func record(_ phase: String) throws {
            try check()
            guard rows.count < 8 else { throw RuneWorkspaceVisibilityFailure("Naming Close exceeded eight phase rows.") }
            let bytes = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey)
            guard bytes.map({ $0.count <= 64 * 1_024 }) ?? true else {
                throw RuneWorkspaceVisibilityFailure("Naming Close preferences exceeded the 64 KiB fixture bound.")
            }
            rows.append(["phase": phase, "parent_visible": fixture.window.isVisible,
                "parent_key": fixture.window.isKeyWindow, "parent_is_actual_key": NSApp.keyWindow === fixture.window,
                "content_is_exact_host": fixture.window.contentView === fixture.hosting,
                "host_has_owned_window": fixture.hosting.window === fixture.window,
                "attached_sheet_present": fixture.window.attachedSheet != nil,
                "held_sheet_is_attached": heldSheet.map { fixture.window.attachedSheet === $0 } ?? false,
                "held_sheet_has_exact_parent": heldSheet.map { $0.sheetParent === fixture.window } ?? false,
                "held_sheet_visible": heldSheet?.isVisible ?? false,
                "held_sheet_is_actual_key": heldSheet.map { NSApp.keyWindow === $0 } ?? false,
                "held_content_has_sheet": heldContent.map { $0.window === heldSheet } ?? false,
                "held_field_has_sheet": heldField.map { $0.window === heldSheet } ?? false,
                "held_field_value": heldField.map { String($0.stringValue.prefix(96)) as Any } ?? NSNull(),
                "collection_unchanged_from_before": before.map { fixture.preferences.collection == $0 } ?? false,
                "stored_bytes": bytes.map { $0.count as Any } ?? NSNull(),
                "stored_sha256": bytes.map { JSONSupport.sha256Hex($0) as Any } ?? NSNull(),
                "stored_bytes_unchanged_from_before": beforeBytes.map { bytes == $0 } ?? false])
            stage = phase
        }
        func retain(_ error: Error? = nil) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let current = try encoder.encode(fixture.preferences.collection)
            guard current.count <= 64 * 1_024, rows.count <= 8, menus.count <= 2 else {
                throw RuneWorkspaceVisibilityFailure("Naming Close evidence exceeded its collection/phase/menu bounds.")
            }
            let payload: [String: Any] = ["classification": "Actual production Rename/editor with one public parent performClose, observed Close/refusal, retained-window reopening if closed and exact owned-sheet Return. No V199 Zoom-descendant traversal, forced sheet teardown before cleanup, private main-controller or desktop proof.",
                "shared_deadline_seconds": 45, "synchronous_native_calls_preemptible": false,
                "cleanup_hard_deadline_established": false, "stage": stage, "origin_layout_id": original.id.uuidString,
                "rows": rows, "native_menu_attempts": menus, "actual_submit_and_close": witness,
                "baseline_collection": try beforeBytes.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
                "current_collection": try JSONSerialization.jsonObject(with: current),
                "error": error.map { String(String(describing: $0).prefix(1_024)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 512 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Naming Close report exceeded 512 KiB.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-parent-close-naming-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        func openRename() async throws -> (NSWindow, NSView, NSTextField) {
            try check(reserving: 3)
            guard fixture.window.attachedSheet == nil, menus.count < 2 else {
                throw RuneWorkspaceVisibilityFailure("A fresh Rename requires no attached sheet and a bounded menu attempt.")
            }
            let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID, scope: .applicationContent)
            try check(reserving: 3)
            let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting, expectedName: original.name)
            defer { menus.append(capture.evidence) }
            try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture, scope: .applicationContent)
            try check(reserving: 3)
            try await runeWorkspaceWait("Production Rename did not attach its actual naming sheet.") { fixture.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
            try check(reserving: 6)
            let (field, _) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: original.name)
            try check()
            return (sheet, content, field)
        }
        do {
            try check(); try fixture.preferences.save(original)
            before = fixture.preferences.collection
            beforeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            NSApp.activate(ignoringOtherApps: true); fixture.window.makeKeyAndOrderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try check(reserving: 3)
            try await runeWorkspaceWait("The real Rune source owners did not settle for naming Close.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            try check(reserving: 3)
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description, scope: .applicationContent)
            try check(reserving: 3); try observer.pressOwned(row, role: kAXButtonRole, scope: .applicationContent)
            try check(reserving: 3)
            try await runeWorkspaceWait("The actual source row did not mount its naming workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            runeModel.pauseObservation(); try requireUnchanged(); try record("before-Rename")
            let (sheet, content, field) = try await openRename()
            heldSheet = sheet; heldContent = content; heldField = field
            try check(reserving: 3)
            try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: field, name: draft)
            try requireUnchanged(); try record("unsaved-draft-before-Close")
            try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
            try check(reserving: 3)
            witness["parent_performClose_attempts"] = 1
            fixture.window.performClose(nil)
            witness["parent_performClose_returned"] = true
            await Task.yield(); try check(); try requireUnchanged()
            let closed = !fixture.window.isVisible
            witness["parent_closed_observed"] = closed
            witness["Close_disposition"] = closed ? "parent-not-visible-after-return-and-yield" : "parent-still-visible-after-return-and-yield; refusal observation without cause"
            try record("after-parent-Close-attempt")
            if closed {
                fixture.window.makeKeyAndOrderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
                try check(reserving: 3)
                try await runeWorkspaceWait("The retained parent did not reopen with its exact hosting root.") {
                    fixture.window.isVisible && fixture.window.contentView === fixture.hosting && fixture.hosting.window === fixture.window
                }
            }
            try requireUnchanged(); try record("reopened-or-still-visible")
            let retainedOwner = fixture.window.isVisible && fixture.window.contentView === fixture.hosting
                && fixture.hosting.window === fixture.window && !fixture.hosting.isHiddenOrHasHiddenAncestor
                && fixture.window.attachedSheet === sheet && sheet.sheetParent === fixture.window
                && sheet.isVisible && sheet.contentView === content && content.window === sheet
            let submitSheet: NSWindow, submitContent: NSView, submitField: NSTextField, submittedName: String
            if retainedOwner {
                witness["submission_branch"] = "same-held-attached-sheet"
                try check(reserving: 6)
                let (currentField, _) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: draft)
                witness["submitted_field_is_held_field"] = currentField === field
                submitSheet = sheet; submitContent = content; submitField = currentField; submittedName = draft
            } else {
                witness["submission_branch"] = "fresh-Rename-after-observed-sheet-loss"
                guard fixture.window.attachedSheet == nil, sheet.sheetParent == nil else {
                    throw RuneWorkspaceVisibilityFailure("Naming Close left an unexpected attached-sheet owner; no forced teardown is allowed before cleanup.")
                }
                let fresh = try await openRename()
                submitSheet = fresh.0; submitContent = fresh.1; submitField = fresh.2
                submittedName = "Fresh-" + UUID().uuidString
                try check(reserving: 3)
                try runeReplaceOwnedNamingText(fixture, sheet: submitSheet, content: submitContent, field: submitField, name: submittedName)
            }
            submitSheet.makeKeyAndOrderFront(nil)
            try check(reserving: 3)
            try await runeWorkspaceWait("The exact submitted naming sheet did not become the actual key owner.") {
                submitSheet.isKeyWindow && NSApp.keyWindow === submitSheet
            }
            try requireUnchanged(); try record("before-owned-Return")
            try check(reserving: 6)
            try await runeSubmitOwnedNamingReturn(fixture, sheet: submitSheet, content: submitContent,
                field: submitField, expectedName: submittedName, witness: &witness)
            try check()
            var expected = try XCTUnwrap(before)
            let index = try XCTUnwrap(expected.layouts.firstIndex { $0.id == original.id })
            expected.layouts[index].name = submittedName
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let expectedBytes = try encoder.encode(expected)
            let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
            guard fixture.preferences.collection == expected, restored.restorationError == nil, restored.collection == expected,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == expectedBytes,
                  submitSheet.sheetParent == nil, fixture.window.attachedSheet == nil else {
                throw RuneWorkspaceVisibilityFailure("Owned Return did not preserve exact origin-only Rename, full collection/bytes and fresh restoration.")
            }
            witness["exact_origin_only_Rename"] = true; witness["fresh_preferences_match"] = true
            try record("owned-Return-dismissed-and-persisted")
            await runeNamingClose(fixture, runeModel: runeModel)
            witness["fixture_close_returned"] = true
            try check(); try record("cleanup-returned"); try retain()
        } catch {
            try? retain(error)
            if witness["fixture_close_returned"] as? Bool != true {
                await runeNamingClose(fixture, runeModel: runeModel); witness["fixture_close_returned"] = true
            }
            try? retain(error)
            throw error
        }
    }

    func testMountedRuneZoomSubtreeBeforeDuringAfterProductionRenameCancellation() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run the Rune Zoom lifecycle measurement in ForgeConductorAppTests with a native display.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        let source = DevelopmentPolicySource(displayName: "Zoom lifecycle policy",
            selectedPath: "/tmp/rune-zoom-lifecycle-policy.md", interpretationState: .cataloging)
        let runeModel = RuneForgeViewModel(client: RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source])))
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting, expectedName: original.name)
        let style = fixture.window.styleMask
        var rows: [[String: Any]] = [], firstScalarError: Error?, stage = "mount"
        var before: NativeWorkspaceCollection?, beforeBytes: Data?, heldSheet: NSWindow?, heldContent: NSView?
        var cancellation: [String: Any] = ["actual_Save_request_count": 0, "Escape_posted": false]
        func check(reservingPhase: Bool = false) throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  !reservingPhase || deadline - ProcessInfo.processInfo.systemUptime > 3 else {
                throw RuneWorkspaceVisibilityFailure("The Rune Zoom lifecycle measurement exceeded its shared 45-second deadline or lacks phase time.")
            }
        }
        func wait(_ message: String, _ predicate: () -> Bool) async throws {
            let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
            while !predicate() {
                try check()
                guard ProcessInfo.processInfo.systemUptime < end else { throw RuneWorkspaceVisibilityFailure(message) }
                try await Task.sleep(for: .milliseconds(10))
            }
            try check()
            guard ProcessInfo.processInfo.systemUptime < end else { throw RuneWorkspaceVisibilityFailure(message) }
        }
        func requireOwner(during: Bool) throws {
            try check()
            guard let before, let beforeBytes, NSApp.isActive, fixture.window.isVisible,
                  fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
                  !fixture.hosting.isHiddenOrHasHiddenAncestor, fixture.window.styleMask == style,
                  fixture.hosting.frame.size == NSSize(width: 1_280, height: 900),
                  fixture.preferences.collection == before,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                  Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id)),
                  let zoom = fixture.window.standardWindowButton(.zoomButton), zoom.window === fixture.window else {
                throw RuneWorkspaceVisibilityFailure("The Rune Zoom phase lost exact native owners, source panels or unchanged stored layout.")
            }
            if during {
                guard let heldSheet, let heldContent, heldSheet.isKeyWindow, NSApp.keyWindow === heldSheet,
                      fixture.window.sheets.count == 1, fixture.window.sheets.first === heldSheet else {
                    throw RuneWorkspaceVisibilityFailure("The Rune Zoom phase lost its sole exact key production sheet.")
                }
                try runeRequireNamingSheetOwner(fixture, sheet: heldSheet, content: heldContent)
            } else {
                guard fixture.window.isKeyWindow, NSApp.keyWindow === fixture.window,
                      fixture.window.attachedSheet == nil, fixture.window.sheets.isEmpty, heldSheet?.sheetParent == nil else {
                    throw RuneWorkspaceVisibilityFailure("The Rune Zoom phase lacks its exact key parent with no attached sheet.")
                }
            }
        }
        func record(_ phase: String, during: Bool) throws {
            try requireOwner(during: during)
            guard rows.count < 3 else { throw RuneWorkspaceVisibilityFailure("The Rune Zoom lifecycle exceeded three phase rows.") }
            let zoom = try XCTUnwrap(fixture.window.standardWindowButton(.zoomButton))
            var row: [String: Any] = ["phase": phase, "process_pid": ProcessInfo.processInfo.processIdentifier,
                "AXIsProcessTrusted_before_query": AXIsProcessTrusted(), "native_application_active": NSApp.isActive,
                "native_exact_phase_key_owner": during ? NSApp.keyWindow === heldSheet : NSApp.keyWindow === fixture.window,
                "native_exact_host": fixture.window.contentView === fixture.hosting && fixture.hosting.window === fixture.window,
                "native_style_mask": Int(style.rawValue), "native_content_frame": NSStringFromRect(fixture.hosting.frame),
                "native_standard_zoom_owned": zoom.window === fixture.window, "native_standard_zoom_enabled": zoom.isEnabled,
                "native_standard_zoom_hidden": zoom.isHiddenOrHasHiddenAncestor, "native_sheet_count": fixture.window.sheets.count,
                "native_exact_sheet_attached": heldSheet.map { fixture.window.attachedSheet === $0 } ?? false,
                "stored_collection_unchanged": true, "stored_bytes_unchanged": true]
            do {
                if let error = try observer.observePlainAppKitStandardZoom(
                    deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3), report: &row), firstScalarError == nil {
                    firstScalarError = error
                }
                try requireOwner(during: during)
                row["AXIsProcessTrusted_after_query"] = AXIsProcessTrusted()
                try requireOwner(during: during)
                row["native_phase_owner_after_query"] = true; rows.append(row)
            } catch {
                row["strict_phase_error"] = String(String(describing: error).prefix(512)); rows.append(row); throw error
            }
        }
        func retain(_ error: Error? = nil) throws {
            let bytes = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey)
            guard rows.count <= 3, beforeBytes.map({ $0.count <= 64 * 1_024 }) ?? true,
                  bytes.map({ $0.count <= 64 * 1_024 }) ?? true else {
                throw RuneWorkspaceVisibilityFailure("The Rune Zoom stored-layout/phase evidence exceeded its bound.")
            }
            let payload: [String: Any] = ["classification": "Actual isolated Rune source-window exact Zoom subtree before/during/after production Rename cancellation; no Save dispatch, full naming pass, desktop or permission-cause claim",
                "stage": stage, "shared_budget_seconds": 45, "per_phase_query_budget_seconds": 3,
                "expected_phase_rows": 3, "rows": rows, "all_three_phases_recorded": rows.count == 3,
                "actual_menu_transition": capture.evidence, "cancellation": cancellation,
                "persisted_bytes_before_base64": beforeBytes.map { $0.base64EncodedString() as Any } ?? NSNull(),
                "persisted_bytes_after_base64": bytes.map { $0.base64EncodedString() as Any } ?? NSNull(),
                "stored_collection_unchanged": before.map { fixture.preferences.collection == $0 } ?? false,
                "stored_bytes_unchanged": beforeBytes.map { bytes == $0 } ?? false,
                "first_scalar_error": firstScalarError.map { String(String(describing: $0).prefix(512)) as Any } ?? NSNull(),
                "error_description": error.map { String(String(describing: $0).prefix(512)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 512 * 1_024 else { throw RuneWorkspaceVisibilityFailure("The Rune Zoom lifecycle report exceeded 512 KiB.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-production-zoom-sheet-lifecycle"; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try check(); try fixture.preferences.save(original)
            before = fixture.preferences.collection
            beforeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            NSApp.activate(ignoringOtherApps: true); fixture.window.makeKeyAndOrderFront(nil)
            fixture.hosting.layoutSubtreeIfNeeded()
            try await wait("The real Rune source owners did not settle for Zoom measurement.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation(); try check(reservingPhase: true)
            let sourceRow = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description, scope: .applicationContent)
            try check(reservingPhase: true); try observer.pressOwned(sourceRow, role: kAXButtonRole, scope: .applicationContent)
            try await wait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            stage = "before-sheet"; try record(stage, during: false)
            stage = "production-Rename-menu"
            try check(reservingPhase: true)
            let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID, scope: .applicationContent)
            try check(reservingPhase: true); try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture, scope: .applicationContent)
            try await wait("Production Rename did not attach its actual naming sheet.") { fixture.window.attachedSheet != nil }
            heldSheet = try XCTUnwrap(fixture.window.attachedSheet); heldContent = try XCTUnwrap(heldSheet?.contentView)
            let sheet = try XCTUnwrap(heldSheet), content = try XCTUnwrap(heldContent)
            sheet.makeKeyAndOrderFront(nil)
            try await wait("The production naming sheet did not become the exact key owner.") { sheet.isKeyWindow && NSApp.keyWindow === sheet }
            stage = "during-sheet"; try record(stage, during: true)
            try check(reservingPhase: true)
            let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: original.name)
            try requireOwner(during: true)
            guard sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
                  sheet.firstResponder === editor, editor.window === sheet, editor.string == original.name else {
                throw RuneWorkspaceVisibilityFailure("Rename cancellation did not own the actual production sheet editor.")
            }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            try requireOwner(during: true)
            guard event.window === sheet, event.windowNumber == sheet.windowNumber, field.currentEditor() === editor,
                  sheet.firstResponder === editor, editor.window === sheet, field.stringValue == original.name else {
                throw RuneWorkspaceVisibilityFailure("Rename cancellation lost its exact event/sheet/editor before posting.")
            }
            cancellation["API"] = "NSApp.postEvent(_:atStart:false) Escape / production cancelAction shortcut"
            cancellation["identity_source"] = identity; cancellation["event_window_number"] = event.windowNumber
            cancellation["event_window_is_exact_sheet"] = true
            NSApp.postEvent(event, atStart: false); cancellation["Escape_posted"] = true; try check()
            try await wait("The owned Escape did not cancel the production Rename sheet.") {
                fixture.window.attachedSheet == nil && sheet.sheetParent == nil
            }
            cancellation["production_sheet_dismissed"] = true
            fixture.window.makeKeyAndOrderFront(nil)
            try await wait("The parent did not resume exact key ownership after cancellation.") { fixture.window.isKeyWindow && NSApp.keyWindow === fixture.window }
            stage = "after-sheet"; try record(stage, during: false)
            guard rows.count == 3 else { throw RuneWorkspaceVisibilityFailure("The Rune Zoom lifecycle did not retain all three bounded phase rows.") }
            try requireOwner(during: false)
            if let firstScalarError { throw firstScalarError }
            stage = "complete"; try retain(); try check()
        } catch {
            let finalError = firstScalarError ?? error
            try? retain(finalError); await runeNamingClose(fixture, runeModel: runeModel); throw finalError
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testAllPanelsAcrossThreeMountedRuneDetailNamespacesQueuedMoveResizePersistsGeometry() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        let modes = ["source", "violation", "feed"]
        let namespaces = Set(modes.map { "rune-forge." + $0 })
        let catalogNamespaces = Set(NativeWorkspaceCatalog.panelsByView.keys.filter {
            $0.hasPrefix("rune-forge.") && $0 != "rune-forge.overview"
        })
        let expected = Set(modes.flatMap { mode in
            NativeWorkspaceCatalog.runePanels(for: mode).map { "rune-forge." + mode + "::" + $0.id }
        })
        guard namespaces.count == 3, namespaces == catalogNamespaces,
              !expected.isEmpty, expected.count <= 192 else {
            throw RuneWorkspaceVisibilityFailure("The bounded Rune detail route table omits a namespace or placement.")
        }
        var completed = Set<String>()
        for mode in modes {
            try Task.checkCancellation()
            guard deadline - ProcessInfo.processInfo.systemUptime > 15 else {
                throw RuneWorkspaceVisibilityFailure("All Rune detail panels lack bounded route preparation time.")
            }
            let panels = try await runeAllDetailPanelsQueuedGeometry(mode: mode, deadline: deadline)
            for panelID in panels {
                let key = "rune-forge." + mode + "::" + panelID
                guard expected.contains(key), completed.insert(key).inserted else {
                    throw RuneWorkspaceVisibilityFailure("The Rune detail route duplicated or escaped a catalog placement.")
                }
            }
        }
        guard completed == expected, ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("Not every Rune detail panel completed inside its case deadline.")
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "classification": "Every panel in three selected isolated Rune detail namespaces; API-seeded layouts/front order and prepared scrolling, actual public route selection and six-event move/resize. Desktop input, naming menus and installed operation remain separate.",
            "namespace_count": namespaces.count, "placement_count": expected.count,
            "completed_placements": completed.sorted(), "total_posted_events": completed.count * 6,
            "case_deadline_seconds": 120, "placement_limit": 192,
        ], options: [.sortedKeys])
        guard data.count <= 64 * 1_024 else {
            throw RuneWorkspaceVisibilityFailure("The complete Rune detail panel receipt exceeded its byte bound.")
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "all-rune-detail-panels-complete"; attachment.lifetime = .keepAlways; add(attachment)
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("The Rune detail panel case exceeded its deadline during receipt creation.")
        }
    }

    private func runeAllDetailPanelsQueuedGeometry(mode: String, deadline: TimeInterval) async throws -> Set<String> {
        guard ["source", "violation", "feed"].contains(mode), NSApp != nil,
              Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run all Rune detail panels in the native app host.")
        }
        let descriptors = NativeWorkspaceCatalog.runePanels(for: mode)
        let panelIDs = descriptors.map(\.id)
        guard !panelIDs.isEmpty, panelIDs.count <= 64, Set(panelIDs).count == panelIDs.count else {
            throw RuneWorkspaceVisibilityFailure("The Rune detail catalog is empty, duplicated or oversized.")
        }
        let source = DevelopmentPolicySource(displayName: "Route policy",
            selectedPath: "/tmp/rune-route-policy.md", interpretationState: .cataloging)
        let event = policyEvent(sequence: 1)
        let violation = PolicyViolation(id: event.violationID, fingerprint: event.fingerprint,
            ruleID: event.candidate.rule.id, policyRevision: event.candidate.rule.source.revision, state: .open,
            firstObservedAt: event.occurredAt, lastObservedAt: event.occurredAt, occurrenceCount: 1,
            latestSummary: event.candidate.summary, latestSuggestedCorrection: event.candidate.suggestedCorrection)
        let client = RuneWorkspaceRouteClient(snapshot: policySnapshot(events: [event], sources: [source]),
            violation: .init(violation: violation, latestEventSequence: event.sequence))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "overview.mount", completed = false
        var completedPanels = Set<String>()
        var feedSelectionWitness: [String: Any] = [:]
        @MainActor func retain(_ error: Error? = nil) throws {
            let report: [String: Any] = ["classification": "Actual public Overview-to-Rune selection and every catalog panel's queued move/resize; XCTest outcome determines qualification",
                "mode": mode, "panel_ids": panelIDs, "completed_panels": completedPanels.sorted(), "stage": stage,
                "execution_completed": completed, "snapshot_reads": client.snapshotReads,
                "violation_page_reads": client.violationReads, "mutation_requests": client.mutationRequests,
                "feed_selection_capability": observer.lastRouteSelectionCapability,
                "feed_selection_action": feedSelectionWitness,
                "last_required_AX_walk": observer.lastRequiredWalkContext,
                "application_content_scope": observer.lastApplicationContentWindowScope,
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard data.count <= 128 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Rune route evidence exceeded its bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-all-detail-route-" + mode + "-" + stage
            attachment.lifetime = .keepAlways; add(attachment)
        }
        @MainActor func ready() -> Bool {
            let bounds = fixture.hosting.bounds
            return fixture.window.contentView === fixture.hosting && fixture.hosting.window === fixture.window
                && fixture.window.isVisible && fixture.window.occlusionState.contains(.visible)
                && !fixture.window.isMiniaturized && fixture.window.screen != nil
                && !fixture.hosting.isHiddenOrHasHiddenAncestor && !fixture.model.isBootstrapping
                && bounds.origin == .zero && bounds.width.isFinite && bounds.height.isFinite
                && abs(bounds.width - 1_440) <= 0.1 && abs(bounds.height - 900) <= 0.1
        }
        do {
            let layout = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge." + mode, name: "Route-" + mode,
                canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0) + 80,
                              height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0) + 80),
                panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
            try fixture.preferences.save(layout)
            fixture.window.setContentSize(NSSize(width: 1_440, height: 900))
            NSApp.activate(ignoringOtherApps: true); fixture.window.makeKeyAndOrderFront(nil)
            fixture.window.orderFrontRegardless(); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The actual Overview/data/window prerequisite did not settle.") {
                ready() && NSApp.isActive && fixture.window.isKeyWindow && NSApp.keyWindow === fixture.window
                    && !runeModel.isLoading && runeModel.errorMessage == nil && runeModel.sources.count == 1 && runeModel.violations.count == 1
                    && runeModel.events.count == 1 && client.snapshotReads >= 1 && client.violationReads >= 1
            }
            runeModel.pauseObservation()
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.overview", scope: .applicationContent)
            let before = fixture.preferences.collection
            let beforeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard beforeBytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: beforeBytes) == before else {
                throw RuneWorkspaceVisibilityFailure("The originating Overview collection/storage differ.")
            }
            stage = mode == "feed" ? "feed.row.select" : mode + ".row.press"
            if mode == "feed" {
                try observer.selectOwnedFeedRow(identifier: "rune-policy-feed-route", witness: &feedSelectionWitness)
            } else {
                let identifier = mode == "source" ? "rune-policy-source-row-" + source.id.description
                    : "rune-violation-row-" + violation.id.description
                let row = try await observer.required(identifier: identifier, scope: .applicationContent)
                try observer.pressOwned(row, role: kAXButtonRole, scope: .applicationContent)
                _ = try await observer.required(identifier: "workspace-controls-" + layout.viewID, scope: .applicationContent)
                runeModel.pauseObservation()
            }
            if mode == "feed" {
                _ = try await observer.required(identifier: "workspace-controls-" + layout.viewID, scope: .applicationContent)
                runeModel.pauseObservation()
            }
            guard ready(), fixture.preferences.collection == before,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                  client.mutationRequests == 0, ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuneWorkspaceVisibilityFailure("Actual route selection/probe changed saved state, backend or owner.")
            }
            // Preparation hint only: the unchanged verifier still requires its complete tree/unique document.
            do {
                try Task.checkCancellation()
                try await runeWorkspaceWait("The selected Rune catalog panels did not finish mounting.",
                    timeout: .seconds(min(3, max(0, deadline - ProcessInfo.processInfo.systemUptime)))) {
                    ready() && Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(layout.panels.map(\.id))
                }
                for panelID in panelIDs {
                    try Task.checkCancellation()
                    guard ready(), ProcessInfo.processInfo.systemUptime < deadline,
                          !completedPanels.contains(panelID) else {
                        throw RuneWorkspaceVisibilityFailure("The all-panel Rune route lost its owner or exact placement/deadline.")
                    }
                    try fixture.preferences.bringToFront(panelID, in: layout.viewID)
                    let current = try XCTUnwrap(fixture.preferences.activeLayout(for: layout.viewID))
                    guard current.id == layout.id, current.viewID == layout.viewID else {
                        throw RuneWorkspaceVisibilityFailure("The Rune panel lost its originating custom layout.")
                    }
                    stage = mode + ".queued-geometry." + panelID
                    try await NativeWorkspaceQueuedPanelGeometryVerifier.verify(current, panelID: panelID,
                        window: fixture.window, hosting: fixture.hosting, preferences: fixture.preferences,
                        defaults: fixture.defaults, deadline: deadline,
                        receiptName: "queued-rune-all-panels-" + mode + "-" + panelID,
                        presentationIsReady: { ready() }, retainReport: { data, name in
                            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                            attachment.name = name; attachment.lifetime = .keepAlways; self.add(attachment)
                        })
                    completedPanels.insert(panelID)
                }
                guard completedPanels == Set(panelIDs) else {
                    throw RuneWorkspaceVisibilityFailure("The Rune route omitted a catalog panel.")
                }
            }
            guard fixture.preferences.layouts(for: fixture.layout.viewID) == [fixture.layout],
                  fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  client.mutationRequests == 0, !runeModel.isLoading, runeModel.errorMessage == nil,
                  fixture.model.app == nil, fixture.model.manager == nil,
                  fixture.model.remoteManager == nil, !fixture.model.hasLoadedInitialSettings,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuneWorkspaceVisibilityFailure("Rune route/geometry changed Overview or the isolated backend contract.")
            }
            stage = "complete"; completed = true; try retain()
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("All Rune detail panels exceeded their cooperative case deadline.")
        }
        return completedPanels
    }

    func testMountedRuneActualSourceAndViolationRoutesQueuedMoveResizePersistsGeometry() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        for (mode, panelID) in [("source", "rune-source-identity"), ("violation", "rune-violation-identity")] {
            guard deadline - ProcessInfo.processInfo.systemUptime > 15 else {
                throw RuneWorkspaceVisibilityFailure("Rune route table lacks bounded preparation time.")
            }
            try await runeActualRouteQueuedGeometry(mode: mode, panelID: panelID, deadline: deadline)
        }
    }

    func testMountedRuneActualFeedSelectionQueuedMoveResizePersistsGeometry() async throws {
        try await runeActualRouteQueuedGeometry(mode: "feed", panelID: "rune-events",
            deadline: ProcessInfo.processInfo.systemUptime + 45, selectFeed: true)
    }

    func testMountedRuneFeedPublicSelectionCapabilityProbe() async throws {
        try await runeActualRouteQueuedGeometry(mode: "feed", panelID: nil,
            deadline: ProcessInfo.processInfo.systemUptime + 45)
    }

    private func runeActualRouteQueuedGeometry(mode: String, panelID: String?, deadline: TimeInterval,
                                              selectFeed: Bool = false) async throws {
        guard ["source", "violation", "feed"].contains(mode),
              (mode == "feed" && !selectFeed) == (panelID == nil),
              !selectFeed || (mode == "feed" && panelID == "rune-events"), NSApp != nil,
              Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run the explicit Rune route/probe in the native app host.")
        }
        let source = DevelopmentPolicySource(displayName: "Route policy",
            selectedPath: "/tmp/rune-route-policy.md", interpretationState: .cataloging)
        let event = policyEvent(sequence: 1)
        let violation = PolicyViolation(id: event.violationID, fingerprint: event.fingerprint,
            ruleID: event.candidate.rule.id, policyRevision: event.candidate.rule.source.revision, state: .open,
            firstObservedAt: event.occurredAt, lastObservedAt: event.occurredAt, occurrenceCount: 1,
            latestSummary: event.candidate.summary, latestSuggestedCorrection: event.candidate.suggestedCorrection)
        let client = RuneWorkspaceRouteClient(snapshot: policySnapshot(events: [event], sources: [source]),
            violation: .init(violation: violation, latestEventSequence: event.sequence))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "overview.mount", completed = false
        var feedSelectionWitness: [String: Any] = [:]
        @MainActor func retain(_ error: Error? = nil) throws {
            let report: [String: Any] = ["classification": mode == "feed" && !selectFeed
                ? "Public Feed selection capability observation only; no selection action or Feed geometry qualification"
                : selectFeed ? "Actual Overview-to-Rune public Feed row selection and queued production-panel move/resize"
                : "Actual Overview-to-Rune button route and queued production-panel move/resize",
                "mode": mode, "panel_id": panelID.map { $0 as Any } ?? NSNull(), "stage": stage,
                "execution_completed": completed, "snapshot_reads": client.snapshotReads,
                "violation_page_reads": client.violationReads, "mutation_requests": client.mutationRequests,
                "feed_selection_capability": observer.lastRouteSelectionCapability,
                "feed_selection_action": feedSelectionWitness,
                "last_required_AX_walk": observer.lastRequiredWalkContext,
                "application_content_scope": observer.lastApplicationContentWindowScope,
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard data.count <= 128 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Rune route evidence exceeded its bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-actual-route-" + mode + "-" + stage
            attachment.lifetime = .keepAlways; add(attachment)
        }
        @MainActor func ready() -> Bool {
            let bounds = fixture.hosting.bounds
            return fixture.window.contentView === fixture.hosting && fixture.hosting.window === fixture.window
                && fixture.window.isVisible && fixture.window.occlusionState.contains(.visible)
                && !fixture.window.isMiniaturized && fixture.window.screen != nil
                && !fixture.hosting.isHiddenOrHasHiddenAncestor && !fixture.model.isBootstrapping
                && bounds.origin == .zero && bounds.width.isFinite && bounds.height.isFinite
                && abs(bounds.width - 1_440) <= 0.1 && abs(bounds.height - 900) <= 0.1
        }
        do {
            let descriptors = NativeWorkspaceCatalog.runePanels(for: mode)
            let layout = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge." + mode, name: "Route-" + mode,
                canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0) + 80,
                              height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0) + 80),
                panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
            try fixture.preferences.save(layout)
            fixture.window.setContentSize(NSSize(width: 1_440, height: 900))
            NSApp.activate(ignoringOtherApps: true); fixture.window.makeKeyAndOrderFront(nil)
            fixture.window.orderFrontRegardless(); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The actual Overview/data/window prerequisite did not settle.") {
                ready() && NSApp.isActive && fixture.window.isKeyWindow && NSApp.keyWindow === fixture.window
                    && !runeModel.isLoading && runeModel.errorMessage == nil && runeModel.sources.count == 1 && runeModel.violations.count == 1
                    && runeModel.events.count == 1 && client.snapshotReads >= 1 && client.violationReads >= 1
            }
            runeModel.pauseObservation()
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.overview", scope: .applicationContent)
            let before = fixture.preferences.collection
            let beforeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard beforeBytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: beforeBytes) == before else {
                throw RuneWorkspaceVisibilityFailure("The originating Overview collection/storage differ.")
            }
            stage = mode == "feed" ? (selectFeed ? "feed.row.select" : "feed.public-capability") : mode + ".row.press"
            if mode == "feed" {
                if selectFeed {
                    try observer.selectOwnedFeedRow(identifier: "rune-policy-feed-route", witness: &feedSelectionWitness)
                } else {
                    try observer.observeOwnedFeedSelectionCapability(identifier: "rune-policy-feed-route")
                }
            } else {
                let identifier = mode == "source" ? "rune-policy-source-row-" + source.id.description
                    : "rune-violation-row-" + violation.id.description
                let row = try await observer.required(identifier: identifier, scope: .applicationContent)
                try observer.pressOwned(row, role: kAXButtonRole, scope: .applicationContent)
                _ = try await observer.required(identifier: "workspace-controls-" + layout.viewID, scope: .applicationContent)
                runeModel.pauseObservation()
            }
            if selectFeed {
                _ = try await observer.required(identifier: "workspace-controls-" + layout.viewID, scope: .applicationContent)
                runeModel.pauseObservation()
            }
            guard ready(), fixture.preferences.collection == before,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                  client.mutationRequests == 0, ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuneWorkspaceVisibilityFailure("Actual route selection/probe changed saved state, backend or owner.")
            }
            if let panelID {
                // Preparation hint only: the shared verifier subsequently requires its complete tree/unique document.
                try Task.checkCancellation()
                try await runeWorkspaceWait("The selected Rune catalog panels did not finish mounting.",
                    timeout: .seconds(min(3, max(0, deadline - ProcessInfo.processInfo.systemUptime)))) {
                    ready() && Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(layout.panels.map(\.id))
                }
                stage = mode + ".queued-geometry"
                try await NativeWorkspaceQueuedPanelGeometryVerifier.verify(layout, panelID: panelID,
                    window: fixture.window, hosting: fixture.hosting, preferences: fixture.preferences,
                    defaults: fixture.defaults, deadline: deadline, receiptName: "queued-rune-" + mode,
                    presentationIsReady: { ready() }, retainReport: { data, name in
                        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                        attachment.name = name; attachment.lifetime = .keepAlways; self.add(attachment)
                    })
            }
            guard fixture.preferences.layouts(for: fixture.layout.viewID) == [fixture.layout],
                  fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  client.mutationRequests == 0, !runeModel.isLoading, runeModel.errorMessage == nil,
                  fixture.model.app == nil, fixture.model.manager == nil,
                  fixture.model.remoteManager == nil, !fixture.model.hasLoadedInitialSettings,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuneWorkspaceVisibilityFailure("Rune route/geometry changed Overview or the isolated backend contract.")
            }
            stage = "complete"; completed = true; try retain()
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("Rune route/probe exceeded its cooperative case deadline.")
        }
    }

    func testMountedRuneNamingSheetCannotRenameAnotherNamespaceAfterSourceRefresh() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let sourcePanels = NativeWorkspaceCatalog.runePanels(for: "source")
        let sourceLayout = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source layout",
            canvas: .init(width: max(1_280, sourcePanels.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, sourcePanels.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: sourcePanels.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "mount"
        var actualSavePressed = false
        do {
            try fixture.preferences.save(sourceLayout)
            fixture.window.orderFront(nil)
            fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source/navigation owners did not settle.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            stage = "source-row.press"
            let sourceRow = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(sourceRow, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("Pressing the actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(sourceLayout.panels.map(\.id))
            }
            let before = fixture.preferences.collection
            stage = "source-menu.open"
            let opener = try await observer.required(identifier: "workspace-layout-menu-rune-forge.source")
            try await observer.openOwnedMenuAndPressRename(opener)
            try await runeWorkspaceWait("The actual Rename action did not present a production naming sheet.") {
                fixture.window.attachedSheet != nil
            }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet)
            let originalSave = try await observer.required(identifier: "workspace-save-layout", inSheet: true)
            try observer.requireOwnedSheetAncestor(originalSave)
            try runeNamingEvidence(fixture, observer: observer, stage: "source-naming-sheet-open", savePressed: false)

            // This drives the production refresh owner, without injecting private
            // selection or sheet state, and does not claim the Refresh button.
            stage = "source-refresh.remove-selected-source"
            client.replaceSnapshot(policySnapshot(events: []))
            await runeModel.refreshNow()
            guard runeModel.sources.isEmpty, !runeModel.isLoading else {
                throw RuneWorkspaceVisibilityFailure("The controlled production refresh did not remove the selected source.")
            }
            try await runeWorkspaceWait("The source lookup did not change the actual workspace to overview.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(fixture.layout.panels.map(\.id))
            }
            guard fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.activeLayout(for: sourceLayout.viewID) == sourceLayout else {
                throw RuneWorkspaceVisibilityFailure("A namespace selection changed before the held naming Save action.")
            }
            stage = "overview-held-naming-sheet"
            try runeNamingEvidence(fixture, observer: observer, stage: stage, savePressed: false)
            if let retainedSheet = fixture.window.attachedSheet {
                guard retainedSheet === sheet else {
                    throw RuneWorkspaceVisibilityFailure("A different sheet replaced the originating naming sheet; this flow is unqualified.")
                }
                let save = try await observer.required(identifier: "workspace-save-layout", inSheet: true)
                try observer.requireOwnedSheetAncestor(save)
                stage = "held-source-sheet.actual-Save.press"
                try observer.pressOwned(save, role: kAXButtonRole)
                actualSavePressed = true
                try await runeWorkspaceWait("The actual Save action did not dismiss the naming sheet.") {
                    fixture.window.attachedSheet == nil
                }
            } else {
                stage = "originating-sheet-dismissed-on-namespace-change"
            }
            try runeNamingEvidence(fixture, observer: observer, stage: stage, savePressed: actualSavePressed)
            guard fixture.preferences.layouts(for: fixture.layout.viewID) == before.layouts.filter({ $0.viewID == fixture.layout.viewID }),
                  fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.layouts(for: sourceLayout.viewID) == before.layouts.filter({ $0.viewID == sourceLayout.viewID }),
                  fixture.preferences.collection == before else {
                throw RuneWorkspaceVisibilityFailure("The source naming action changed another namespace after the selected source disappeared. Inspect the retained before/after collection and Save witness.")
            }
        } catch {
            try? runeNamingEvidence(fixture, observer: observer, stage: stage, savePressed: actualSavePressed, error: error)
            await runeNamingClose(fixture, runeModel: runeModel)
            throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testMountedRuneNativeMenuNamingSheetCannotRenameAnotherNamespaceAfterSourceRefresh() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let sourcePanels = NativeWorkspaceCatalog.runePanels(for: "source")
        let sourceLayout = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, sourcePanels.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, sourcePanels.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: sourcePanels.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        let nativeMenu = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting, expectedName: sourceLayout.name)
        var stage = "mount"
        var actualSavePressed = false
        do {
            try fixture.preferences.save(sourceLayout)
            fixture.window.orderFront(nil)
            fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source/navigation owners did not settle.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            stage = "source-row.press"
            let sourceRow = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(sourceRow, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("Pressing the actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(sourceLayout.panels.map(\.id))
            }
            let before = fixture.preferences.collection
            stage = "source-menu.open"
            let opener = try await observer.required(identifier: "workspace-layout-menu-rune-forge.source")
            try await observer.openOwnedMenuAndPressNativeRename(opener, capture: nativeMenu)
            try await runeWorkspaceWait("The actual Rename action did not present a production naming sheet.") {
                fixture.window.attachedSheet != nil
            }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet)
            let nativeSheet = RuneWorkspaceNativeNamingSheet(window: fixture.window, hosting: fixture.hosting, sheet: sheet)
            defer { nativeMenu.sheetNodes = nativeSheet.lastNodes }
            do { _ = try await nativeSheet.requiredSave() }
            catch {
                nativeMenu.sheetPhysicalButtons = runeNamingFailurePhysicalButtons(window: fixture.window, hosting: fixture.hosting, sheet: sheet)
                nativeMenu.sheetDefaultButton = runeNamingFailureDefaultButton(window: fixture.window, hosting: fixture.hosting, sheet: sheet)
                throw error
            }
            nativeMenu.sheetNodes = nativeSheet.lastNodes
            try runeNativeNamingEvidence(fixture, observer: observer, nativeMenu: nativeMenu, stage: "source-naming-sheet-open", savePressed: false)

            // This drives the production refresh owner, without injecting private
            // selection or sheet state, and does not claim the Refresh button.
            stage = "source-refresh.remove-selected-source"
            client.replaceSnapshot(policySnapshot(events: []))
            await runeModel.refreshNow()
            guard runeModel.sources.isEmpty, !runeModel.isLoading else {
                throw RuneWorkspaceVisibilityFailure("The controlled production refresh did not remove the selected source.")
            }
            try await runeWorkspaceWait("The source lookup did not change the actual workspace to overview.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(fixture.layout.panels.map(\.id))
            }
            guard fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.activeLayout(for: sourceLayout.viewID) == sourceLayout else {
                throw RuneWorkspaceVisibilityFailure("A namespace selection changed before the held naming Save action.")
            }
            stage = "overview-held-naming-sheet"
            try runeNativeNamingEvidence(fixture, observer: observer, nativeMenu: nativeMenu, stage: stage, savePressed: false)
            if let retainedSheet = fixture.window.attachedSheet {
                guard retainedSheet === sheet else {
                    throw RuneWorkspaceVisibilityFailure("A different sheet replaced the originating naming sheet; this flow is unqualified.")
                }
                stage = "held-source-sheet.actual-native-Save.press"
                nativeMenu.sheetPress = try await nativeSheet.pressSave()
                nativeMenu.sheetNodes = nativeSheet.lastNodes
                actualSavePressed = true
                try await runeWorkspaceWait("The actual Save action did not dismiss the naming sheet.") {
                    fixture.window.attachedSheet == nil
                }
            } else {
                stage = "originating-sheet-dismissed-on-namespace-change"
            }
            try runeNativeNamingEvidence(fixture, observer: observer, nativeMenu: nativeMenu, stage: stage, savePressed: actualSavePressed)
            guard fixture.preferences.layouts(for: fixture.layout.viewID) == before.layouts.filter({ $0.viewID == fixture.layout.viewID }),
                  fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.layouts(for: sourceLayout.viewID) == before.layouts.filter({ $0.viewID == sourceLayout.viewID }),
                  fixture.preferences.collection == before else {
                throw RuneWorkspaceVisibilityFailure("The source naming action changed another namespace after the selected source disappeared. Inspect the retained before/after collection and Save witness.")
            }
        } catch {
            try? runeNativeNamingEvidence(fixture, observer: observer, nativeMenu: nativeMenu, stage: stage, savePressed: actualSavePressed, error: error)
            await runeNamingClose(fixture, runeModel: runeModel)
            throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testMountedRuneNativeRenameAndSaveAsPersistNamesAndLayoutIdentity() async throws {
        try await runeAssertPositiveNativeNaming(commands: ["Rename Layout…", "Save Layout As…"])
    }

    func testMountedRuneNativeRenamePersistsNameAndLayoutIdentity() async throws {
        try await runeAssertPositiveNativeNaming(commands: ["Rename Layout…"])
    }

    func testMountedRuneNativeSaveAsPersistsNameAndCopiedLayoutIdentity() async throws {
        try await runeAssertPositiveNativeNaming(commands: ["Save Layout As…"])
    }

    private func runeAssertPositiveNativeNaming(commands: [String]) async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "mount", witnesses: [[String: Any]] = []
        var menu: RuneWorkspaceNativeNamingMenuCapture?
        func retain(_ error: Error? = nil) throws {
            let bytes = try JSONEncoder().encode(fixture.preferences.collection)
            guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes, witnesses.count <= 2 else {
                throw RuneWorkspaceVisibilityFailure("Positive naming evidence exceeded its collection/witness bound.")
            }
            let report: [String: Any] = ["classification": "Mounted native menu and actual NSTextView editing plus owned NSWindow Return; no Save-button, exported-menu or desktop-input proof.",
                "stage": stage, "normal_naming_witnesses": witnesses,
                "actual_menu_transition": menu?.evidence ?? [:],
                "collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Positive naming JSON exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-positive-native-naming-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(original)
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source owners did not settle for positive naming.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(row, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            for command in commands {
                let before = fixture.preferences.collection
                let active = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                let newName = (command == "Rename Layout…" ? "Renamed-" : "Saved-") + UUID().uuidString
                stage = command == "Rename Layout…" ? "normal-rename" : "normal-save-as"
                let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting,
                    expectedName: active.name, requestedCommand: command)
                menu = capture
                let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID)
                try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture)
                try await runeWorkspaceWait("The actual naming command did not present its production sheet.") { fixture.window.attachedSheet != nil }
                let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content,
                    expectedValue: command == "Rename Layout…" ? active.name : "Custom")
                try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: field, name: newName)
                guard fixture.preferences.collection == before else { throw RuneWorkspaceVisibilityFailure("Actual editing/endEditing changed saved layouts before the positive Return.") }
                witnesses.append(["command": command, "new_name": newName, "identity_source": identity,
                    "actual_editor_changed": true, "actual_Return_attempted": false,
                    "actual_Return_returned": false, "actual_sheet_dismissed": false])
                try await runeSubmitOwnedNamingReturn(fixture, sheet: sheet, content: content,
                    field: field, expectedName: newName, witness: &witnesses[witnesses.count - 1])
                let after = fixture.preferences.collection
                let result = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                if command == "Rename Layout…" {
                    var expected = before
                    let index = try XCTUnwrap(expected.layouts.firstIndex(where: { $0.id == active.id }))
                    expected.layouts[index].name = newName
                    guard result.id == original.id, after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Rename did not preserve exact layout identity, geometry, panels and other namespaces.") }
                } else {
                    guard result.id != active.id, result.name == newName, result.viewID == active.viewID,
                          result.canvas == active.canvas, result.panels == active.panels else { throw RuneWorkspaceVisibilityFailure("Actual Save As did not create a new named identity with copied geometry/panels.") }
                    var expected = before; expected.layouts.append(result); expected.activeLayoutIDs[original.viewID] = result.id
                    guard after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Save As changed more than its new layout and source selection.") }
                }
                let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                    panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
                guard restored.restorationError == nil, restored.collection == after else {
                    throw RuneWorkspaceVisibilityFailure("The actual naming result did not restore exactly from isolated preferences.")
                }
                try retain()
            }
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testMountedRuneNativeMenuExportedSavePersistsNamesAndLayoutIdentity() async throws {
        let commands = ["Rename Layout…", "Save Layout As…"]
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "mount", witnesses: [[String: Any]] = []
        var menu: RuneWorkspaceNativeNamingMenuCapture?
        func retain(_ error: Error? = nil) throws {
            let bytes = try JSONEncoder().encode(fixture.preferences.collection)
            guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes, witnesses.count <= 2 else {
                throw RuneWorkspaceVisibilityFailure("Positive naming evidence exceeded its collection/witness bound.")
            }
            let report: [String: Any] = ["classification": "Separate mounted native menu, actual NSTextView editor and exported exact-sheet Save accessibility activation; no Return fallback or desktop/pointer-input proof.",
                "stage": stage, "normal_naming_witnesses": witnesses,
                "actual_menu_transition": menu?.evidence ?? [:],
                "last_required_AX_walk_context": observer.lastRequiredWalkContext,
                "last_AX_scalar_read": observer.lastRead,
                "collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Positive naming JSON exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-native-menu-exported-save-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(original)
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source owners did not settle for positive naming.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(row, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            for command in commands {
                let before = fixture.preferences.collection
                let active = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                let newName = (command == "Rename Layout…" ? "Renamed-" : "Saved-") + UUID().uuidString
                stage = command == "Rename Layout…" ? "exported-save-rename" : "exported-save-as"
                let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting,
                    expectedName: active.name, requestedCommand: command)
                menu = capture
                let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID)
                try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture)
                try await runeWorkspaceWait("The actual naming command did not present its production sheet.") { fixture.window.attachedSheet != nil }
                let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content,
                    expectedValue: command == "Rename Layout…" ? active.name : "Custom")
                try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: field, name: newName)
                guard fixture.preferences.collection == before else { throw RuneWorkspaceVisibilityFailure("Actual editing/endEditing changed saved layouts before the exported Save action.") }
                witnesses.append(["command": command, "new_name": newName, "identity_source": identity,
                    "actual_editor_changed": true, "actual_Save_action_requested": false,
                    "actual_Save_action_returned": false, "actual_sheet_dismissed": false])
                let save = try await observer.required(identifier: "workspace-save-layout", inSheet: true)
                try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                guard field.window === sheet, field.stringValue == newName, fixture.preferences.collection == before else {
                    throw RuneWorkspaceVisibilityFailure("Exported Save lost its retained actual name field or unchanged collection.")
                }
                try observer.pressRetainedSheetSave(save, sheet: sheet, content: content,
                    witness: &witnesses[witnesses.count - 1])
                try await runeWorkspaceWait("The exact exported Save action did not dismiss the naming sheet.") {
                    fixture.window.attachedSheet == nil
                }
                witnesses[witnesses.count - 1]["actual_sheet_dismissed"] = true
                let after = fixture.preferences.collection
                let result = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                if command == "Rename Layout…" {
                    var expected = before
                    let index = try XCTUnwrap(expected.layouts.firstIndex(where: { $0.id == active.id }))
                    expected.layouts[index].name = newName
                    guard result.id == original.id, after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Rename did not preserve exact layout identity, geometry, panels and other namespaces.") }
                } else {
                    guard result.id != active.id, result.name == newName, result.viewID == active.viewID,
                          result.canvas == active.canvas, result.panels == active.panels else { throw RuneWorkspaceVisibilityFailure("Actual Save As did not create a new named identity with copied geometry/panels.") }
                    var expected = before; expected.layouts.append(result); expected.activeLayoutIDs[original.viewID] = result.id
                    guard after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Save As changed more than its new layout and source selection.") }
                }
                let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                    panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
                guard restored.restorationError == nil, restored.collection == after else {
                    throw RuneWorkspaceVisibilityFailure("The actual naming result did not restore exactly from isolated preferences.")
                }
                try retain()
            }
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testMountedRuneFreshActiveKeyNativeRenameExportedSavePersistsIdentity() async throws {
        try await runeExerciseFreshNativeMenuExportedSave(commands: ["Rename Layout…"], requireActiveKey: true)
    }

    func testMountedRuneFreshNativeRenameExportedSavePersistsIdentity() async throws {
        try await runeExerciseFreshNativeMenuExportedSave(commands: ["Rename Layout…"])
    }

    func testMountedRuneFreshNativeSaveAsExportedSavePersistsCopy() async throws {
        try await runeExerciseFreshNativeMenuExportedSave(commands: ["Save Layout As…"])
    }

    func testMountedRuneExactAttachedSheetNativeMenuSavePersistsNamesAndLayoutIdentity() async throws {
        let commands = ["Rename Layout…", "Save Layout As…"]
        guard !commands.isEmpty, commands.count <= 2, Set(commands).count == commands.count,
              commands.allSatisfy({ $0 == "Rename Layout…" || $0 == "Save Layout As…" }) else {
            throw RuneWorkspaceVisibilityFailure("Fresh exported Save requires one or two distinct literal naming commands.")
        }
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "mount", witnesses: [[String: Any]] = []
        var menu: RuneWorkspaceNativeNamingMenuCapture?
        func retain(_ error: Error? = nil) throws {
            let bytes = try JSONEncoder().encode(fixture.preferences.collection)
            guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes, witnesses.count <= 2 else {
                throw RuneWorkspaceVisibilityFailure("Positive naming evidence exceeded its collection/witness bound.")
            }
            let report: [String: Any] = ["classification": "Separate attached-sheet identifier scope: native menu/editor and sole first-order owned AXSheet Save activation; parent-window descendants are outside this Save lookup. Original whole-window tests/gates remain unchanged; no Return fallback or desktop-input proof.",
                "stage": stage, "requested_commands": commands, "fresh_fixture_command_count": commands.count,
                "normal_naming_witnesses": witnesses,
                "actual_menu_transition": menu?.evidence ?? [:],
                "last_required_AX_walk_context": observer.lastRequiredWalkContext,
                "last_AX_scalar_read": observer.lastRead,
                "collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Positive naming JSON exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-exact-attached-sheet-save-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(original)
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source owners did not settle for positive naming.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(row, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            for command in commands {
                let before = fixture.preferences.collection
                let active = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                let newName = (command == "Rename Layout…" ? "Renamed-" : "Saved-") + UUID().uuidString
                stage = command == "Rename Layout…" ? "attached-sheet-save-rename" : "attached-sheet-save-as"
                let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting,
                    expectedName: active.name, requestedCommand: command)
                menu = capture
                let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID)
                try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture)
                try await runeWorkspaceWait("The actual naming command did not present its production sheet.") { fixture.window.attachedSheet != nil }
                let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content,
                    expectedValue: command == "Rename Layout…" ? active.name : "Custom")
                try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: field, name: newName)
                guard fixture.preferences.collection == before else { throw RuneWorkspaceVisibilityFailure("Actual editing/endEditing changed saved layouts before the exported Save action.") }
                witnesses.append(["command": command, "new_name": newName, "identity_source": identity,
                    "actual_editor_changed": true, "actual_Save_action_requested": false,
                    "actual_Save_action_returned": false, "actual_sheet_dismissed": false])
                let save = try observer.requiredExactAttachedSheetSave(sheet: sheet, content: content, field: field, expectedName: newName)
                try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                guard field.window === sheet, field.stringValue == newName, fixture.preferences.collection == before else {
                    throw RuneWorkspaceVisibilityFailure("Exported Save lost its retained actual name field or unchanged collection.")
                }
                try observer.pressRetainedExactAttachedSheetSave(save, sheet: sheet, content: content, field: field, expectedName: newName,
                    witness: &witnesses[witnesses.count - 1])
                try await runeWorkspaceWait("The exact exported Save action did not dismiss the naming sheet.") {
                    fixture.window.attachedSheet == nil
                }
                witnesses[witnesses.count - 1]["actual_sheet_dismissed"] = true
                let after = fixture.preferences.collection
                let result = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                if command == "Rename Layout…" {
                    var expected = before
                    let index = try XCTUnwrap(expected.layouts.firstIndex(where: { $0.id == active.id }))
                    expected.layouts[index].name = newName
                    guard result.id == original.id, after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Rename did not preserve exact layout identity, geometry, panels and other namespaces.") }
                } else {
                    guard result.id != active.id, result.name == newName, result.viewID == active.viewID,
                          result.canvas == active.canvas, result.panels == active.panels else { throw RuneWorkspaceVisibilityFailure("Actual Save As did not create a new named identity with copied geometry/panels.") }
                    var expected = before; expected.layouts.append(result); expected.activeLayoutIDs[original.viewID] = result.id
                    guard after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Save As changed more than its new layout and source selection.") }
                }
                let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                    panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
                guard restored.restorationError == nil, restored.collection == after else {
                    throw RuneWorkspaceVisibilityFailure("The actual naming result did not restore exactly from isolated preferences.")
                }
                try retain()
            }
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testMountedRuneApplicationContentExactAttachedSheetNativeMenuSavePersistsNamesAndLayoutIdentity() async throws {
        let commands = ["Rename Layout…", "Save Layout As…"]
        guard !commands.isEmpty, commands.count <= 2, Set(commands).count == commands.count,
              commands.allSatisfy({ $0 == "Rename Layout…" || $0 == "Save Layout As…" }) else {
            throw RuneWorkspaceVisibilityFailure("Fresh exported Save requires one or two distinct literal naming commands.")
        }
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "mount", witnesses: [[String: Any]] = []
        var menu: RuneWorkspaceNativeNamingMenuCapture?
        func retain(_ error: Error? = nil) throws {
            let bytes = try JSONEncoder().encode(fixture.preferences.collection)
            guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes, witnesses.count <= 2 else {
                throw RuneWorkspaceVisibilityFailure("Positive naming evidence exceeded its collection/witness bound.")
            }
            let report: [String: Any] = ["classification": "Separate application-content window membership plus sole first-order attached-sheet Save scope; native menus/editor, unchanged complete sheet graph/actions. Only freshly validated standard Zoom/FullScreen descendants are excluded from window walks. Native/exported sheet correspondence is inferred from repeated sole-sheet observations under the exact parent, not a direct conversion or atomic identity guarantee. Original whole-window tests/gates remain unchanged; no end-wait experiment, Return fallback, product repair or desktop-input proof.",
                "stage": stage, "requested_commands": commands, "fresh_fixture_command_count": commands.count,
                "normal_naming_witnesses": witnesses,
                "actual_menu_transition": menu?.evidence ?? [:],
                "last_required_AX_walk_context": observer.lastRequiredWalkContext,
                "last_application_content_window_scope": observer.lastApplicationContentWindowScope,
                "last_AX_scalar_read": observer.lastRead,
                "collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Positive naming JSON exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-application-content-attached-sheet-save-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(original)
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source owners did not settle for positive naming.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description, scope: .applicationContent)
            try observer.pressOwned(row, role: kAXButtonRole, scope: .applicationContent)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source", scope: .applicationContent)
            try await runeWorkspaceWait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            for command in commands {
                let before = fixture.preferences.collection
                let active = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                let newName = (command == "Rename Layout…" ? "Renamed-" : "Saved-") + UUID().uuidString
                stage = command == "Rename Layout…" ? "attached-sheet-save-rename" : "attached-sheet-save-as"
                let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting,
                    expectedName: active.name, requestedCommand: command)
                menu = capture
                let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID, scope: .applicationContent)
                try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture, scope: .applicationContent)
                try await runeWorkspaceWait("The actual naming command did not present its production sheet.") { fixture.window.attachedSheet != nil }
                let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content,
                    expectedValue: command == "Rename Layout…" ? active.name : "Custom")
                try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: field, name: newName)
                guard fixture.preferences.collection == before else { throw RuneWorkspaceVisibilityFailure("Actual editing/endEditing changed saved layouts before the exported Save action.") }
                witnesses.append(["command": command, "new_name": newName, "identity_source": identity,
                    "actual_editor_changed": true, "actual_Save_action_requested": false,
                    "actual_Save_action_returned": false, "actual_sheet_dismissed": false])
                let save = try observer.requiredExactAttachedSheetSave(sheet: sheet, content: content, field: field, expectedName: newName)
                try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                guard field.window === sheet, field.stringValue == newName, fixture.preferences.collection == before else {
                    throw RuneWorkspaceVisibilityFailure("Exported Save lost its retained actual name field or unchanged collection.")
                }
                try observer.pressRetainedExactAttachedSheetSave(save, sheet: sheet, content: content, field: field, expectedName: newName,
                    witness: &witnesses[witnesses.count - 1])
                try await runeWorkspaceWait("The exact exported Save action did not dismiss the naming sheet.") {
                    fixture.window.attachedSheet == nil
                }
                witnesses[witnesses.count - 1]["actual_sheet_dismissed"] = true
                let after = fixture.preferences.collection
                let result = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                if command == "Rename Layout…" {
                    var expected = before
                    let index = try XCTUnwrap(expected.layouts.firstIndex(where: { $0.id == active.id }))
                    expected.layouts[index].name = newName
                    guard result.id == original.id, after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Rename did not preserve exact layout identity, geometry, panels and other namespaces.") }
                } else {
                    guard result.id != active.id, result.name == newName, result.viewID == active.viewID,
                          result.canvas == active.canvas, result.panels == active.panels else { throw RuneWorkspaceVisibilityFailure("Actual Save As did not create a new named identity with copied geometry/panels.") }
                    var expected = before; expected.layouts.append(result); expected.activeLayoutIDs[original.viewID] = result.id
                    guard after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Save As changed more than its new layout and source selection.") }
                }
                let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                    panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
                guard restored.restorationError == nil, restored.collection == after else {
                    throw RuneWorkspaceVisibilityFailure("The actual naming result did not restore exactly from isolated preferences.")
                }
                try retain()
            }
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    private func runeExerciseFreshNativeMenuExportedSave(commands: [String], requireActiveKey: Bool = false) async throws {
        guard !commands.isEmpty, commands.count <= 2, Set(commands).count == commands.count,
              commands.allSatisfy({ $0 == "Rename Layout…" || $0 == "Save Layout As…" }) else {
            throw RuneWorkspaceVisibilityFailure("Fresh exported Save requires one or two distinct literal naming commands.")
        }
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let original = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        var stage = "mount", witnesses: [[String: Any]] = []
        var menu: RuneWorkspaceNativeNamingMenuCapture?
        var activeKeyWitnesses: [[String: Any]] = []
        func retain(_ error: Error? = nil) throws {
            let bytes = try JSONEncoder().encode(fixture.preferences.collection)
            guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes, witnesses.count <= 2 else {
                throw RuneWorkspaceVisibilityFailure("Positive naming evidence exceeded its collection/witness bound.")
            }
            let report: [String: Any] = ["classification": "Separate fresh-fixture naming reachability: native menu, actual NSTextView editor and exported exact-sheet Save activation; distinct from combined sequential Rename/Save As qualification, no Return fallback or desktop/pointer-input proof.",
                "stage": stage, "requested_commands": commands, "fresh_fixture_command_count": commands.count,
                "active_key_readiness_opt_in": requireActiveKey, "active_key_readiness_witnesses": activeKeyWitnesses,
                "normal_naming_witnesses": witnesses,
                "actual_menu_transition": menu?.evidence ?? [:],
                "last_required_AX_walk_context": observer.lastRequiredWalkContext,
                "last_AX_scalar_read": observer.lastRead,
                "collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Positive naming JSON exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-fresh-native-menu-exported-save-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(original)
            if requireActiveKey {
                try Task.checkCancellation()
                NSApp.activate(ignoringOtherApps: true); fixture.window.makeKeyAndOrderFront(nil)
                try await runeWorkspaceWait("The active/key experiment did not establish the exact foreground parent.") {
                    NSApp.isActive && fixture.window.isKeyWindow && NSApp.keyWindow === fixture.window
                        && fixture.window.isVisible && fixture.window.contentView === fixture.hosting
                        && fixture.hosting.window === fixture.window && !fixture.hosting.isHiddenOrHasHiddenAncestor
                        && fixture.window.attachedSheet == nil
                }
                try Task.checkCancellation()
                activeKeyWitnesses.append(["phase": "foreground-parent-before-mount",
                    "snapshot_uptime": ProcessInfo.processInfo.systemUptime, "application_active": NSApp.isActive,
                    "exact_parent_key": fixture.window.isKeyWindow && NSApp.keyWindow === fixture.window])
            }
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source owners did not settle for positive naming.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(row, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(original.panels.map(\.id))
            }
            for command in commands {
                let before = fixture.preferences.collection
                let active = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                let newName = (command == "Rename Layout…" ? "Renamed-" : "Saved-") + UUID().uuidString
                stage = command == "Rename Layout…" ? "exported-save-rename" : "exported-save-as"
                let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting,
                    expectedName: active.name, requestedCommand: command)
                menu = capture
                let opener = try await observer.required(identifier: "workspace-layout-menu-" + original.viewID)
                try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture)
                try await runeWorkspaceWait("The actual naming command did not present its production sheet.") { fixture.window.attachedSheet != nil }
                let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                if requireActiveKey {
                    try Task.checkCancellation(); try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                    sheet.makeKeyAndOrderFront(nil)
                    try await runeWorkspaceWait("The active/key experiment did not establish the exact foreground sheet.") {
                        NSApp.isActive && sheet.isKeyWindow && NSApp.keyWindow === sheet
                            && fixture.window.attachedSheet === sheet && sheet.sheetParent === fixture.window
                            && sheet.contentView === content && content.window === sheet && sheet.isVisible
                    }
                    try Task.checkCancellation(); try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                }
                let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content,
                    expectedValue: command == "Rename Layout…" ? active.name : "Custom")
                try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: field, name: newName)
                guard fixture.preferences.collection == before else { throw RuneWorkspaceVisibilityFailure("Actual editing/endEditing changed saved layouts before the exported Save action.") }
                witnesses.append(["command": command, "new_name": newName, "identity_source": identity,
                    "actual_editor_changed": true, "actual_Save_action_requested": false,
                    "actual_Save_action_returned": false, "actual_sheet_dismissed": false])
                if requireActiveKey {
                    try Task.checkCancellation(); try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                    let active = NSApp.isActive, exactKey = sheet.isKeyWindow && NSApp.keyWindow === sheet
                    activeKeyWitnesses.append(["phase": "foreground-sheet-before-whole-window-Save-query",
                        "snapshot_uptime": ProcessInfo.processInfo.systemUptime, "application_active": active,
                        "exact_sheet_key": exactKey, "exact_attached_sheet": fixture.window.attachedSheet === sheet,
                        "exact_sheet_parent": sheet.sheetParent === fixture.window])
                    guard active, exactKey else { throw RuneWorkspaceVisibilityFailure("The active/key experiment lost the exact foreground sheet before Save discovery.") }
                }
                let save = try await observer.required(identifier: "workspace-save-layout", inSheet: true)
                try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
                guard field.window === sheet, field.stringValue == newName, fixture.preferences.collection == before else {
                    throw RuneWorkspaceVisibilityFailure("Exported Save lost its retained actual name field or unchanged collection.")
                }
                try observer.pressRetainedSheetSave(save, sheet: sheet, content: content,
                    witness: &witnesses[witnesses.count - 1])
                try await runeWorkspaceWait("The exact exported Save action did not dismiss the naming sheet.") {
                    fixture.window.attachedSheet == nil
                }
                witnesses[witnesses.count - 1]["actual_sheet_dismissed"] = true
                let after = fixture.preferences.collection
                let result = try XCTUnwrap(fixture.preferences.activeLayout(for: original.viewID))
                if command == "Rename Layout…" {
                    var expected = before
                    let index = try XCTUnwrap(expected.layouts.firstIndex(where: { $0.id == active.id }))
                    expected.layouts[index].name = newName
                    guard result.id == original.id, after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Rename did not preserve exact layout identity, geometry, panels and other namespaces.") }
                } else {
                    guard result.id != active.id, result.name == newName, result.viewID == active.viewID,
                          result.canvas == active.canvas, result.panels == active.panels else { throw RuneWorkspaceVisibilityFailure("Actual Save As did not create a new named identity with copied geometry/panels.") }
                    var expected = before; expected.layouts.append(result); expected.activeLayoutIDs[original.viewID] = result.id
                    guard after == expected else { throw RuneWorkspaceVisibilityFailure("Actual Save As changed more than its new layout and source selection.") }
                }
                let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                    panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
                guard restored.restorationError == nil, restored.collection == after else {
                    throw RuneWorkspaceVisibilityFailure("The actual naming result did not restore exactly from isolated preferences.")
                }
                try retain()
            }
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    private func runeRequireNamingSheetOwner(_ fixture: RuneWorkspaceVisibilityFixture,
        sheet: NSWindow, content: NSView) throws {
        guard fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
              fixture.window.isVisible, !fixture.hosting.isHiddenOrHasHiddenAncestor,
              fixture.window.attachedSheet === sheet, sheet.sheetParent === fixture.window,
              sheet.contentView === content, content.window === sheet, sheet.isVisible else {
            throw RuneWorkspaceVisibilityFailure("The native naming route lost its exact attached sheet/window/host.")
        }
    }

    private func runeRequiredOwnedNamingField(_ fixture: RuneWorkspaceVisibilityFixture,
        sheet: NSWindow, content: NSView, expectedValue: String) async throws -> (NSTextField, String) {
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        let semantic = RuneWorkspaceNativeNamingSheet(window: fixture.window, hosting: fixture.hosting, sheet: sheet)
        _ = try await semantic.requiredName()
        // Observe the public semantic tree before the physical field. This sequence
        // is qualified; the reason its identifier is exposed remains unknown.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var pending: [(NSView, Int)] = [(content, 0)], seen = Set<ObjectIdentifier>(), matches: [(NSTextField, String)] = []
        while let (view, depth) = pending.popLast() {
            try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
            guard ProcessInfo.processInfo.systemUptime < deadline, depth <= 48 else { throw RuneWorkspaceVisibilityFailure("Native name-field discovery exceeded its deadline/depth bound.") }
            guard seen.insert(ObjectIdentifier(view)).inserted else { continue }
            guard seen.count <= 2_048, view.window === sheet else { throw RuneWorkspaceVisibilityFailure("Native name-field discovery exceeded its node/owner bound.") }
            if let field = view as? NSTextField {
                let direct = field.accessibilityIdentifier(), cell = field.cell
                let ownedID = cell?.controlView === field ? cell?.accessibilityIdentifier() : nil
                guard [direct, ownedID].allSatisfy({ $0.map { $0.utf8.count <= 4_096 } ?? true }) else { throw RuneWorkspaceVisibilityFailure("Native name-field identifier exceeded its scalar bound.") }
                if direct == "workspace-layout-name" || ownedID == "workspace-layout-name" {
                    matches.append((field, direct == "workspace-layout-name" ? "NSTextField.accessibilityIdentifier" : "actual owned field.cell.accessibilityIdentifier"))
                }
            }
            let children = view.subviews
            guard pending.count + children.count + seen.count <= 2_048 else { throw RuneWorkspaceVisibilityFailure("Native name-field pending walk exceeded its bound.") }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        guard ProcessInfo.processInfo.systemUptime < deadline, matches.count == 1 else { throw RuneWorkspaceVisibilityFailure("Native naming did not expose exactly one actual owned name field.") }
        let (field, identity) = matches[0]
        let rect = field.convert(field.bounds, to: nil)
        guard field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, rect.width <= 2_400, rect.height <= 2_400,
              expectedValue.utf8.count <= NativeWorkspaceLimits.maximumNameBytes, field.stringValue == expectedValue,
              ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("Native naming field lost its finite owner/value/deadline gates.") }
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("Final native naming field getters exceeded their deadline.") }
        return (field, identity)
    }

    private func runeReplaceOwnedNamingText(_ fixture: RuneWorkspaceVisibilityFixture,
        sheet: NSWindow, content: NSView, field: NSTextField, name: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        guard name.utf8.count <= NativeWorkspaceLimits.maximumNameBytes, field.window === sheet,
              sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
              sheet.firstResponder === editor, editor.window === sheet, editor.string == field.stringValue else {
            throw RuneWorkspaceVisibilityFailure("Native naming did not establish the actual owned editing field.")
        }
        editor.selectAll(nil)
        guard editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count) else {
            throw RuneWorkspaceVisibilityFailure("The actual editor did not select its complete original name.")
        }
        editor.insertText(name, replacementRange: editor.selectedRange())
        guard editor.string == name else { throw RuneWorkspaceVisibilityFailure("The actual editor did not receive the new UUID name.") }
        sheet.endEditing(for: field)
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        guard field.window === sheet, field.stringValue == name, ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("The actual editor did not commit the new name inside its owner/deadline.")
        }
    }

    private func runeSubmitOwnedNamingReturn(_ fixture: RuneWorkspaceVisibilityFixture,
        sheet: NSWindow, content: NSView, field: NSTextField, expectedName: String,
        witness: inout [String: Any]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        guard field.window === sheet, field.stringValue == expectedName,
              sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
              sheet.firstResponder === editor, editor.window === sheet, editor.string == expectedName else {
            throw RuneWorkspaceVisibilityFailure("Native naming did not establish its actual owned submitted editor.")
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
        let rect = field.convert(field.bounds, to: nil)
        guard event.windowNumber == sheet.windowNumber, field.window === sheet,
              field.currentEditor() === editor, sheet.firstResponder === editor, editor.window === sheet,
              field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, rect.width <= 2_400, rect.height <= 2_400,
              expectedName.utf8.count <= NativeWorkspaceLimits.maximumNameBytes,
              field.stringValue == expectedName, editor.string == expectedName,
              ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("Native Return lost its live owned editor/event/geometry/name/deadline gates.") }
        witness["actual_editor_is_exact_sheet_first_responder"] = true
        witness["actual_Return_attempted"] = true
        sheet.sendEvent(event)
        witness["actual_Return_returned"] = true
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("Native Return returned after its deadline.") }
        try await runeWorkspaceWait("The actual native Return did not dismiss its attached naming sheet.") { fixture.window.attachedSheet == nil }
        witness["actual_sheet_dismissed"] = true
    }

    func testMountedRuneNativeRenameCannotChangeAnotherLayoutAfterControlledSameViewActivation() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let a = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-A-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let b = NativeWorkspaceLayout(id: UUID(), viewID: a.viewID, name: "Source-B-" + UUID().uuidString,
            canvas: .init(width: a.canvas.width + 64, height: a.canvas.height), panels: a.panels)
        let heldName = "Held-" + UUID().uuidString
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting, expectedName: a.name)
        var stage = "mount", witness: [String: Any] = [:]
        var expected: NativeWorkspaceCollection?
        func retain(_ error: Error? = nil) throws {
            let bytes = try JSONEncoder().encode(fixture.preferences.collection)
            let initial = try expected.map { try JSONEncoder().encode($0) }
            guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
                  initial.map({ $0.count <= NativeWorkspaceLimits.maximumStoredBytes }) ?? true else { throw RuneWorkspaceVisibilityFailure("Stale-active naming collection evidence exceeded its bound.") }
            let report: [String: Any] = ["classification": "Actual native Rename/owned editor Return with controlled public preferences activation in the same view; activation is not menu-input proof. No Save-button, exported-menu, desktop or handler-identity proof.",
                "stage": stage, "origin_layout_id": a.id.uuidString, "controlled_active_layout_id": b.id.uuidString,
                "actual_submit": witness, "actual_menu_transition": capture.evidence,
                "expected_after_controlled_activation": try initial.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
                "current_collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Stale-active naming JSON exceeded its bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-same-view-held-native-rename-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(b, activate: false); try fixture.preferences.save(a)
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune owners did not settle for stale-active naming.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(row, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-" + a.viewID)
            try await runeWorkspaceWait("The real source workspace did not mount for stale-active naming.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(a.panels.map(\.id))
            }
            stage = "origin-A-native-Rename"
            let opener = try await observer.required(identifier: "workspace-layout-menu-" + a.viewID)
            try await observer.openOwnedMenuAndPressNativeRename(opener, capture: capture)
            try await runeWorkspaceWait("Actual Rename did not attach its production naming sheet.") { fixture.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
            let (originField, _) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: a.name)
            let beforeEditing = fixture.preferences.collection
            try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: originField, name: heldName)
            guard fixture.preferences.collection == beforeEditing else { throw RuneWorkspaceVisibilityFailure("Actual held-name editing changed saved layouts before controlled activation/Return.") }
            stage = "controlled-public-preferences-activate-B-same-view"
            var selectionOnly = fixture.preferences.collection
            selectionOnly.activeLayoutIDs[a.viewID] = b.id
            expected = selectionOnly
            try fixture.preferences.activate(b.id, for: a.viewID)
            guard fixture.preferences.collection == selectionOnly, fixture.preferences.activeLayout(for: a.viewID) == b else { throw RuneWorkspaceVisibilityFailure("Controlled same-view activation did not change only its expected B selection.") }
            try await runeWorkspaceWait("The controlled same-view workspace owners did not settle.") {
                fixture.preferences.activeLayout(for: a.viewID) == b
                    && fixture.document?.frame.width == CGFloat(b.canvas.width)
                    && Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(b.panels.map(\.id))
            }
            let (field, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: heldName)
            witness = ["identity_source": identity, "held_origin_name": field.stringValue,
                "actual_Return_attempted": false, "actual_Return_returned": false, "actual_sheet_dismissed": false]
            stage = "held-A-naming-sheet-actual-native-Return"
            try retain()
            try await runeSubmitOwnedNamingReturn(fixture, sheet: sheet, content: content,
                field: field, expectedName: heldName, witness: &witness)
            stage = "actual-Return-returned-sheet-dismissed"
            try retain()
            var originRenamed = try XCTUnwrap(expected)
            let originIndex = try XCTUnwrap(originRenamed.layouts.firstIndex(where: { $0.id == a.id }))
            originRenamed.layouts[originIndex].name = heldName
            // Either cancel the stale operation or apply it to originating A;
            // controlled B and every unrelated layout/selection must remain exact.
            guard (fixture.preferences.collection == expected || fixture.preferences.collection == originRenamed),
                  fixture.preferences.activeLayout(for: a.viewID) == b else {
                throw RuneWorkspaceVisibilityFailure("The held A naming action changed another layout after controlled same-view activation. Inspect complete expected/current collections and actual Return witness.")
            }
        } catch {
            try? retain(error); await runeNamingClose(fixture, runeModel: runeModel); throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    func testMountedRuneQueuedEscapeCancelsRenameAfterSourceRefreshWithoutSaving() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Cancellation policy",
            selectedPath: "/tmp/rune-cancellation-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "source")
        let sourceLayout = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        let capture = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting, expectedName: sourceLayout.name)
        var stage = "mount", witness: [String: Any] = ["event_queued": false, "postEvent_returned": false, "sheet_dismissed": false]
        func retain(_ error: Error? = nil) throws {
            let report: [String: Any] = [
                "classification": "Actual native Rename and owned editor draft, controlled source refresh, and one own-sheet NSApp.postEvent Escape. No Cancel-button click, Save/Return submission or desktop-input proof.",
                "stage": stage, "actual_queued_Escape": witness,
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull(),
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 256 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Queued cancellation witness exceeded 256 KiB.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-queued-Escape-" + stage; attachment.lifetime = .keepAlways; add(attachment)
            try runeNativeNamingEvidence(fixture, observer: observer, nativeMenu: capture,
                stage: stage, savePressed: false, error: error)
        }
        func close() async throws {
            capture.stop(); runeModel.stop(); fixture.model.cancelBootstrap()
            await runeNamingClose(fixture, runeModel: runeModel)
            try await runeWorkspaceWait("The test-owned naming models did not settle after awaited fixture cleanup.", timeout: .seconds(5)) {
                !runeModel.isLoading && !fixture.model.isBootstrapping
            }
        }
        do {
            try fixture.preferences.save(sourceLayout)
            NSApp.activate(ignoringOtherApps: true)
            fixture.window.makeKeyAndOrderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source owners did not settle for queued cancellation.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            let row = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(row, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-" + sourceLayout.viewID)
            try await runeWorkspaceWait("The actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(sourceLayout.panels.map(\.id))
            }
            let before = fixture.preferences.collection
            let beforeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let encoded = try JSONEncoder().encode(before)
            guard beforeBytes.count <= 64 * 1_024, encoded.count <= 64 * 1_024 else {
                throw RuneWorkspaceVisibilityFailure("The cancellation baseline exceeded its 64 KiB bound.")
            }
            witness["expected_collection"] = try JSONSerialization.jsonObject(with: encoded)
            witness["persisted_bytes_before_base64"] = beforeBytes.base64EncodedString()
            stage = "actual-native-Rename"
            let opener = try await observer.required(identifier: "workspace-layout-menu-" + sourceLayout.viewID)
            try await observer.openOwnedMenuAndPressNativeRename(opener, capture: capture)
            try await runeWorkspaceWait("Actual Rename did not attach its production sheet.") { fixture.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
            let (originField, identity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: sourceLayout.name)
            let draft = "Cancelled-" + UUID().uuidString
            stage = "actual-owned-editor-draft"
            try runeReplaceOwnedNamingText(fixture, sheet: sheet, content: content, field: originField, name: draft)
            witness["identity_source"] = identity; witness["actual_editor_draft"] = draft
            guard fixture.preferences.collection == before,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
                throw RuneWorkspaceVisibilityFailure("Actual editing wrote a layout before cancellation.")
            }
            stage = "controlled-production-refresh-removes-source"
            client.replaceSnapshot(policySnapshot(events: [])); await runeModel.refreshNow()
            guard runeModel.sources.isEmpty, !runeModel.isLoading else { throw RuneWorkspaceVisibilityFailure("The controlled refresh did not remove the selected source.") }
            try await runeWorkspaceWait("The source refresh did not mount the actual overview panel set.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(fixture.layout.panels.map(\.id))
            }
            runeModel.pauseObservation()
            try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
            let (field, heldIdentity) = try await runeRequiredOwnedNamingField(fixture, sheet: sheet, content: content, expectedValue: draft)
            sheet.makeKeyAndOrderFront(nil)
            try await runeWorkspaceWait("The exact held sheet did not become the actual key window.") { sheet.isKeyWindow && NSApp.keyWindow === sheet }
            guard sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
                  sheet.firstResponder === editor, editor.window === sheet, editor.string == draft else {
                throw RuneWorkspaceVisibilityFailure("Queued Escape did not own the actual held editor.")
            }
            try runeRequireNamingSheetOwner(fixture, sheet: sheet, content: content)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            guard event.windowNumber == sheet.windowNumber, event.window === sheet,
                  sheet.isKeyWindow, NSApp.keyWindow === sheet, field.window === sheet,
                  field.currentEditor() === editor, sheet.firstResponder === editor,
                  editor.window === sheet, editor.string == draft, field.stringValue == draft,
                  fixture.preferences.collection == before,
                  fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw RuneWorkspaceVisibilityFailure("Queued Escape lost its exact event/key-sheet/editor or no-write gates.")
            }
            stage = "held-sheet-one-queued-Escape"
            witness["held_identity_source"] = heldIdentity
            witness["API"] = "NSApp.postEvent(_:atStart:false)"; witness["event_keyCode"] = Int(event.keyCode)
            witness["event_window_is_exact_sheet"] = true; witness["sheet_is_actual_key_window"] = true
            witness["actual_editor_is_sheet_first_responder"] = true
            NSApp.postEvent(event, atStart: false)
            witness["event_queued"] = true; witness["postEvent_returned"] = true
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("Posting the owned Escape exceeded its deadline.") }
            try await runeWorkspaceWait("The actual app-queued Escape did not dismiss its originating sheet.") {
                fixture.window.attachedSheet == nil && sheet.sheetParent == nil
            }
            witness["sheet_dismissed"] = true
            witness["originating_sheet_detached"] = sheet.sheetParent == nil
            stage = "queued-Escape-dismissed-no-saved-changes"
            let afterBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard afterBytes.count <= 64 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Cancellation preferences exceeded their fixture bound.") }
            witness["persisted_bytes_after_base64"] = afterBytes.base64EncodedString()
            witness["complete_collection_unchanged"] = fixture.preferences.collection == before
            witness["persisted_bytes_unchanged"] = afterBytes == beforeBytes
            guard fixture.preferences.collection == before, afterBytes == beforeBytes,
                  fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.activeLayout(for: sourceLayout.viewID) == sourceLayout,
                  runeModel.sources.isEmpty,
                  Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(fixture.layout.panels.map(\.id)) else {
                throw RuneWorkspaceVisibilityFailure("Queued cancellation changed saved layouts/bytes or left the actual overview.")
            }
            try retain()
        } catch {
            try? retain(error)
            do { try await close() } catch { XCTFail("Queued cancellation fixture cleanup failed: \(error)") }
            throw error
        }
        try await close()
    }

    func testMountedRuneNativeReturnCannotRenameAnotherNamespaceAfterSourceRefresh() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let source = DevelopmentPolicySource(displayName: "Naming policy",
            selectedPath: "/tmp/rune-naming-policy.md", interpretationState: .cataloging)
        let client = RuneWorkspaceNamingClient(snapshot: policySnapshot(events: [], sources: [source]))
        let runeModel = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: runeModel, urls: [])
        let sourcePanels = NativeWorkspaceCatalog.runePanels(for: "source")
        let sourceLayout = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.source", name: "Source-" + UUID().uuidString,
            canvas: .init(width: max(1_280, sourcePanels.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                          height: max(900, sourcePanels.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
            panels: sourcePanels.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        let observer = RuneWorkspaceNamingAX(window: fixture.window, hosting: fixture.hosting)
        let nativeMenu = RuneWorkspaceNativeNamingMenuCapture(window: fixture.window, hosting: fixture.hosting, expectedName: sourceLayout.name)
        var stage = "mount", attemptedSubmit = false, returnedSubmit = false, dismissedAfterSubmit = false
        var before: NativeWorkspaceCollection?
        var fieldRecord: [String: Any] = [:]
        func retain(_ error: Error? = nil) throws {
            let encoded = try JSONEncoder().encode(fixture.preferences.collection)
            guard encoded.count <= NativeWorkspaceLimits.maximumStoredBytes else { throw RuneWorkspaceVisibilityFailure("The native Return collection evidence exceeded its storage bound.") }
            let initial = try before.map { try JSONEncoder().encode($0) }
            guard initial.map({ $0.count <= NativeWorkspaceLimits.maximumStoredBytes }) ?? true else { throw RuneWorkspaceVisibilityFailure("The native Return initial collection exceeded its storage bound.") }
            let report: [String: Any] = [
                "classification": "Separate mounted native Return submission test route; actualSubmit is one own-sheet NSWindow.sendEvent Return. The onSubmit/defaultAction handler is not identified. No Save-button, exported-menu or desktop-input proof.",
                "stage": stage, "actualSubmit_attempted": attemptedSubmit, "actualSubmit_returned": returnedSubmit,
                "actual_sheet_dismissed_after_submit": dismissedAfterSubmit,
                "source_namespace": sourceLayout.viewID, "new_namespace": fixture.layout.viewID,
                "before_collection": try initial.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
                "current_collection": try JSONSerialization.jsonObject(with: encoded),
                "exact_main_window_host": fixture.window.contentView === fixture.hosting && fixture.hosting.window === fixture.window,
                "actual_sheet_present": fixture.window.attachedSheet != nil, "owned_native_name_field": fieldRecord,
                "actual_native_menu_transition": nativeMenu.evidence, "AX_nodes_first64": observer.lastNodes,
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull(),
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("The native Return JSON evidence exceeded its bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-native-return-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        }
        do {
            try fixture.preferences.save(sourceLayout)
            fixture.window.orderFront(nil); fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune source/navigation owners did not settle.") {
                !fixture.model.isBootstrapping && !runeModel.isLoading && runeModel.sources.count == 1
                    && fixture.document?.panelHosts.count == fixture.layout.panels.count
            }
            runeModel.pauseObservation()
            stage = "source-row.press"
            let sourceRow = try await observer.required(identifier: "rune-policy-source-row-" + source.id.description)
            try observer.pressOwned(sourceRow, role: kAXButtonRole)
            _ = try await observer.required(identifier: "workspace-controls-rune-forge.source")
            try await runeWorkspaceWait("Pressing the actual source row did not mount its source workspace.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(sourceLayout.panels.map(\.id))
            }
            before = fixture.preferences.collection
            let expected = try XCTUnwrap(before)
            stage = "source-menu.open"
            let opener = try await observer.required(identifier: "workspace-layout-menu-rune-forge.source")
            try await observer.openOwnedMenuAndPressNativeRename(opener, capture: nativeMenu)
            try await runeWorkspaceWait("The actual native Rename did not present a production naming sheet.") { fixture.window.attachedSheet != nil }
            let sheet = try XCTUnwrap(fixture.window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            let nativeSheet = RuneWorkspaceNativeNamingSheet(window: fixture.window, hosting: fixture.hosting, sheet: sheet)
            func requireSheetOwner() throws {
                guard fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
                      fixture.window.isVisible, !fixture.hosting.isHiddenOrHasHiddenAncestor,
                      fixture.window.attachedSheet === sheet, sheet.sheetParent === fixture.window,
                      sheet.contentView === content, content.window === sheet, sheet.isVisible else {
                    throw RuneWorkspaceVisibilityFailure("The Return route lost its exact originating production sheet/window/host.")
                }
            }
            func requiredNameField() async throws -> NSTextField {
                let semanticName = try await nativeSheet.requiredName()
                let semanticCell = semanticName.object as? NSCell
                let semanticField = semanticCell?.controlView as? NSTextField
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var completedWalks = 0
                var completedNodes: [[String: Any]] = []
                repeat {
                    try requireSheetOwner()
                    var pending: [(NSView, Int)] = [(content, 0)], visited = Set<ObjectIdentifier>()
                    var matches: [(NSTextField, String)] = []
                    var nativeNodes: [[String: Any]] = []
                    while let (view, depth) = pending.popLast() {
                        fieldRecord = ["completed_walks": completedWalks, "visited_nodes": visited.count,
                            "pending_nodes": pending.count, "next_depth": depth, "nodes_first64": nativeNodes,
                            "last_complete_walk_nodes_first64": completedNodes,
                            "name_semantic_object_type": String(String(describing: type(of: semanticName.object)).prefix(256)),
                            "name_semantic_is_NSCell": semanticCell != nil,
                            "name_semantic_control_view_type": semanticCell?.controlView.map { String(String(describing: type(of: $0)).prefix(256)) as Any } ?? NSNull(),
                            "first_responder_type": sheet.firstResponder.map { String(String(describing: type(of: $0)).prefix(256)) as Any } ?? NSNull(),
                            "default_button_cell_type": sheet.defaultButtonCell.map { String(String(describing: type(of: $0)).prefix(256)) as Any } ?? NSNull()]
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("The native name-field walk reached its three-second deadline.") }
                        guard depth <= 48 else { throw RuneWorkspaceVisibilityFailure("The native name-field walk exceeded depth 48.") }
                        guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
                        guard visited.count <= 2_048, view.window === sheet else { throw RuneWorkspaceVisibilityFailure("The native name-field walk exceeded its node/owned-sheet bound.") }
                        if nativeNodes.count < 64 {
                            nativeNodes.append(["type": String(String(describing: type(of: view)).prefix(256)),
                                "depth": depth, "is_NSTextField": view is NSTextField,
                                "identifier": String(view.accessibilityIdentifier().prefix(256))])
                        }
                        if let field = view as? NSTextField {
                            let direct = field.accessibilityIdentifier()
                            let cell = field.cell
                            let ownedCell = cell?.controlView === field ? cell?.accessibilityIdentifier() : nil
                            fieldRecord["physical_field_cell_type"] = cell.map { String(String(describing: type(of: $0)).prefix(256)) as Any } ?? NSNull()
                            fieldRecord["named_semantic_object_is_physical_cell"] = cell.map { semanticName.object === $0 } ?? false
                            fieldRecord["named_semantic_control_view_is_physical_field"] = semanticField === field
                            fieldRecord["physical_field_editor_is_sheet_first_responder"] = field.currentEditor().map { $0 === sheet.firstResponder } ?? false
                            guard [direct, ownedCell].allSatisfy({ $0.map { $0.utf8.count <= 4_096 } ?? true }) else { throw RuneWorkspaceVisibilityFailure("An actual native name-field identifier exceeded its scalar bound.") }
                            if direct == "workspace-layout-name" || ownedCell == "workspace-layout-name" {
                                let source = direct == "workspace-layout-name" ? "NSTextField.accessibilityIdentifier"
                                    : "actual owned field.cell.accessibilityIdentifier"
                                matches.append((field, source))
                            }
                        }
                        let children = view.subviews
                        guard pending.count + children.count + visited.count <= 2_048 else { throw RuneWorkspaceVisibilityFailure("The complete native name-field pending walk exceeded its bound.") }
                        pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
                    }
                    completedWalks += 1
                    completedNodes = nativeNodes
                    fieldRecord["completed_walks"] = completedWalks
                    fieldRecord["nodes_first64"] = nativeNodes
                    try requireSheetOwner()
                    guard ProcessInfo.processInfo.systemUptime < deadline, matches.count <= 1 else { throw RuneWorkspaceVisibilityFailure("The complete owned sheet name-field snapshot expired or exposed duplicate identifiers.") }
                    if let (field, identitySource) = matches.first {
                        let rect = field.convert(field.bounds, to: nil)
                        guard field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
                              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
                              rect.width > 0, rect.height > 0, rect.width <= 2_400, rect.height <= 2_400,
                              field.stringValue.utf8.count <= NativeWorkspaceLimits.maximumNameBytes,
                              field.stringValue == sourceLayout.name else { throw RuneWorkspaceVisibilityFailure("The exact native name field was not visible/editable/finite with the originating UUID name.") }
                        fieldRecord = ["identity_source": identitySource, "value": field.stringValue, "frame_in_sheet": NSStringFromRect(rect),
                            "field_type": String(String(describing: type(of: field)).prefix(256)), "visited_nodes": visited.count,
                            "exact_owned_sheet": field.window === sheet]
                        try requireSheetOwner()
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("The final native name-field getters completed after their deadline.") }
                        return field
                    }
                    try await Task.sleep(for: .milliseconds(10))
                } while true
            }
            stage = "source-naming-sheet-owned-native-field"
            _ = try await requiredNameField()
            try retain()
            stage = "source-refresh.remove-selected-source"
            client.replaceSnapshot(policySnapshot(events: [])); await runeModel.refreshNow()
            guard runeModel.sources.isEmpty, !runeModel.isLoading else { throw RuneWorkspaceVisibilityFailure("The controlled production refresh did not remove the selected source.") }
            try await runeWorkspaceWait("The source lookup did not change the actual workspace to overview.") {
                Set(fixture.document?.panelHosts.keys.map { $0 } ?? []) == Set(fixture.layout.panels.map(\.id))
            }
            guard fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.activeLayout(for: sourceLayout.viewID) == sourceLayout else { throw RuneWorkspaceVisibilityFailure("A namespace selection changed before the held native Return.") }
            stage = "overview-held-naming-sheet.actualSubmit"
            let field = try await requiredNameField()
            let dispatchDeadline = ProcessInfo.processInfo.systemUptime + 3
            guard sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
                  sheet.firstResponder === editor, editor.window === sheet,
                  editor.string.utf8.count <= NativeWorkspaceLimits.maximumNameBytes,
                  editor.string == sourceLayout.name else { throw RuneWorkspaceVisibilityFailure("The exact owned production name field did not establish its real native first-responder editor.") }
            try requireSheetOwner()
            guard ProcessInfo.processInfo.systemUptime < dispatchDeadline else { throw RuneWorkspaceVisibilityFailure("The native Return editor gate exceeded its deadline.") }
            fieldRecord["actual_editor_type"] = String(String(describing: type(of: editor)).prefix(256))
            fieldRecord["editor_is_exact_sheet_first_responder"] = sheet.firstResponder === editor
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            try retain()
            try requireSheetOwner()
            let dispatchRect = field.convert(field.bounds, to: nil)
            guard event.windowNumber == sheet.windowNumber, field.window === sheet,
                  field.currentEditor() === editor, sheet.firstResponder === editor, editor.window === sheet,
                  field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
                  [dispatchRect.origin.x, dispatchRect.origin.y, dispatchRect.width, dispatchRect.height].allSatisfy(\.isFinite),
                  dispatchRect.width > 0, dispatchRect.height > 0, dispatchRect.width <= 2_400, dispatchRect.height <= 2_400,
                  field.stringValue == sourceLayout.name, editor.string == sourceLayout.name,
                  ProcessInfo.processInfo.systemUptime < dispatchDeadline else {
                throw RuneWorkspaceVisibilityFailure("The actual native Return lost its live finite owner/editor/name gates before dispatch.")
            }
            attemptedSubmit = true
            sheet.sendEvent(event)
            returnedSubmit = true
            guard ProcessInfo.processInfo.systemUptime < dispatchDeadline else { throw RuneWorkspaceVisibilityFailure("The actual native Return dispatch returned after its deadline.") }
            try await runeWorkspaceWait("The actual native Return produced no attached-sheet dismissal.") { fixture.window.attachedSheet == nil }
            dismissedAfterSubmit = true
            stage = "actualSubmit-returned-sheet-dismissed"
            try retain()
            guard fixture.preferences.layouts(for: fixture.layout.viewID) == expected.layouts.filter({ $0.viewID == fixture.layout.viewID }),
                  fixture.preferences.activeLayout(for: fixture.layout.viewID) == fixture.layout,
                  fixture.preferences.layouts(for: sourceLayout.viewID) == expected.layouts.filter({ $0.viewID == sourceLayout.viewID }),
                  fixture.preferences.collection == expected else { throw RuneWorkspaceVisibilityFailure("The held source native Return changed another namespace after the selected source disappeared.") }
        } catch {
            try? retain(error)
            await runeNamingClose(fixture, runeModel: runeModel)
            throw error
        }
        await runeNamingClose(fixture, runeModel: runeModel)
    }

    private func runeNativeNamingEvidence(_ fixture: RuneWorkspaceVisibilityFixture, observer: RuneWorkspaceNamingAX, nativeMenu: RuneWorkspaceNativeNamingMenuCapture,
                                    stage: String, savePressed: Bool, error: Error? = nil) throws {
        let encoded = try JSONEncoder().encode(fixture.preferences.collection)
        guard encoded.count <= NativeWorkspaceLimits.maximumStoredBytes else {
            throw RuneWorkspaceVisibilityFailure("The naming evidence collection exceeded its existing storage bound.")
        }
        let report: [String: Any] = [
            "classification": "Separate mounted native-menu Rune naming test route. Exact marker, actual native Rename dispatch and held-sheet Save witnesses below determine which stages were exercised; exported-menu AX and desktop input remain separate. Native caches are separate from compositor claims.",
            "stage": stage, "actual_held_sheet_Save_pressed": savePressed,
            "source_namespace": "rune-forge.source", "new_namespace": "rune-forge.overview",
            "collection": try JSONSerialization.jsonObject(with: encoded),
            "window_visible": fixture.window.isVisible,
            "window_exact_host": fixture.window.contentView === fixture.hosting,
            "window_frame": NSStringFromRect(fixture.window.frame),
            "host_bounds": NSStringFromRect(fixture.hosting.bounds),
            "native_sheet_present": fixture.window.attachedSheet != nil,
            "observed_AX_nodes_first64": observer.lastNodes, "last_AX_scalar_read": observer.lastRead,
            "actual_native_menu_transition": nativeMenu.evidence,
            "AX_observation_scope": "Own PID exact unique window public AX source-row/opener only; native tracking menu identity uses exact fixture-only UUID layout entry and literal commands. Native attached-sheet traversal uses complete bounded public formal/informal children, no injected state or direct callback.",
            "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 640 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Naming evidence exceeded its JSON bound.") }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "rune-native-naming-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        for (label, view) in [("page", fixture.window.contentView), ("sheet", fixture.window.attachedSheet?.contentView)] {
            guard let view, view.bounds.width > 0, view.bounds.height > 0,
                  view.bounds.width <= 2_400, view.bounds.height <= 2_400,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 16 * 1_024 * 1_024 else { continue }
            let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            image.name = "rune-native-naming-" + stage + "-" + label + "-native-cache"
            image.lifetime = .keepAlways; add(image)
        }
    }

    private func runeNamingEvidence(_ fixture: RuneWorkspaceVisibilityFixture, observer: RuneWorkspaceNamingAX,
                                    stage: String, savePressed: Bool, error: Error? = nil) throws {
        let encoded = try JSONEncoder().encode(fixture.preferences.collection)
        guard encoded.count <= NativeWorkspaceLimits.maximumStoredBytes else {
            throw RuneWorkspaceVisibilityFailure("The naming evidence collection exceeded its existing storage bound.")
        }
        let report: [String: Any] = [
            "classification": "Actual mounted production Rune naming flow; own-window public AX actions only. Native caches are separate from compositor/input claims.",
            "stage": stage, "actual_held_sheet_Save_pressed": savePressed,
            "source_namespace": "rune-forge.source", "new_namespace": "rune-forge.overview",
            "collection": try JSONSerialization.jsonObject(with: encoded),
            "window_visible": fixture.window.isVisible,
            "window_exact_host": fixture.window.contentView === fixture.hosting,
            "window_frame": NSStringFromRect(fixture.window.frame),
            "host_bounds": NSStringFromRect(fixture.hosting.bounds),
            "native_sheet_present": fixture.window.attachedSheet != nil,
            "observed_AX_nodes_first64": observer.lastNodes, "last_AX_scalar_read": observer.lastRead,
            "actual_menu_transition": observer.lastMenuTransition,
            "AX_observation_scope": "Own PID, exact unique native window title, bounded AXChildren and the actual menu opener's AXShownMenuUIElement relationship; no AXValue or geometry query",
            "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 640 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Naming evidence exceeded its JSON bound.") }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "rune-naming-" + stage; attachment.lifetime = .keepAlways; add(attachment)
        for (label, view) in [("page", fixture.window.contentView), ("sheet", fixture.window.attachedSheet?.contentView)] {
            guard let view, view.bounds.width > 0, view.bounds.height > 0,
                  view.bounds.width <= 2_400, view.bounds.height <= 2_400,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 16 * 1_024 * 1_024 else { continue }
            let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            image.name = "rune-naming-" + stage + "-" + label + "-native-cache"
            image.lifetime = .keepAlways; add(image)
        }
    }

    private func runeNamingClose(_ fixture: RuneWorkspaceVisibilityFixture, runeModel: RuneForgeViewModel) async {
        runeModel.stop()
        if let sheet = fixture.window.attachedSheet {
            fixture.window.endSheet(sheet); sheet.orderOut(nil)
        }
        fixture.window.endEditing(for: nil); _ = fixture.window.makeFirstResponder(nil)
        fixture.hosting.rootView = AnyView(EmptyView())
        fixture.window.orderOut(nil); fixture.window.contentView = nil; fixture.window.close()
        await fixture.model.stopBootstrap()
        fixture.model.telemetryBinding.detach()
        await Task.yield()
        fixture.defaults.removePersistentDomain(forName: fixture.suite)
        try? FileManager.default.removeItem(at: fixture.home)
    }

    func testMountedRuneAllHiddenPausesObservationWithoutCancellingAcceptedBatch() async throws {
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Run in ForgeConductorAppTests with a native display.")
        }
        let urls = ["first-policy.md", "second-policy.md"].map {
            URL(fileURLWithPath: "/tmp/rune-workspace-visibility-" + $0)
        }
        let client = ControlledRuneWorkspaceAddClient(snapshot: policySnapshot(events: []))
        let model = RuneForgeViewModel(client: client)
        let fixture = try RuneWorkspaceVisibilityFixture(model: model, urls: urls)
        do {
            fixture.window.orderFront(nil)
            fixture.hosting.layoutSubtreeIfNeeded()
            try await runeWorkspaceWait("The real Rune canvas did not construct its owned panels.") {
                fixture.document?.panelHosts.count == fixture.layout.panels.count
                    && fixture.window.isVisible && fixture.hosting.window === fixture.window
                    && !fixture.model.isBootstrapping && client.snapshotRequestCount == 1
            }
            let document = try XCTUnwrap(fixture.document)
            let controls = try XCTUnwrap(document.panelHosts["rune-controls"])
            let controlsHost = controls.hostingView
            XCTAssertFalse(controls.isHidden)

            // The accepted command uses the production owner API. This does not
            // claim that the Add button or native picker was exercised.
            model.addPolicySources(urls)
            try await runeWorkspaceWait("The first accepted registration did not reach the controlled client.") {
                client.requestedPaths.count == 1 && model.sources.filter(\.isOptimistic).count == 2
            }
            XCTAssertEqual(client.requestedPaths, [urls[0].standardizedFileURL.path])
            var hidden = fixture.layout
            for index in hidden.panels.indices { hidden.panels[index].isVisible = false }
            try fixture.preferences.save(hidden)
            try await runeWorkspaceWait("The actual workspace visibility callback did not pause observation.") {
                document.panelHosts.count == hidden.panels.count
                    && document.panelHosts.values.allSatisfy(\.isHidden)
                    && client.snapshotCancellation.wasCancelled
            }
            XCTAssertTrue(fixture.document === document)
            XCTAssertTrue(controls.hostingView === controlsHost)
            XCTAssertEqual(fixture.preferences.activeLayout(for: hidden.viewID)?.id, hidden.id)
            XCTAssertTrue(fixture.preferences.activeLayout(for: hidden.viewID)?.panels.allSatisfy { !$0.isVisible } == true)

            client.completeAdd(request: 0)
            try await runeWorkspaceWait("The first held registration did not return.") { client.returnedRequests == [0] }
            XCTAssertEqual(client.cancelledAtReturn[0], false,
                           "Hiding presentation panels must not cancel an already accepted user command.")
            try await runeWorkspaceWait("The accepted second registration was omitted after hiding every panel.") {
                client.requestedPaths.count == 2
            }
            XCTAssertEqual(client.requestedPaths, urls.map { $0.standardizedFileURL.path })
            client.completeAdd(request: 1)
            try await runeWorkspaceWait("Both accepted registrations did not finish in the same owner.") {
                client.returnedRequests == [0, 1] && model.sources.count == 2
                    && model.sources.allSatisfy { !$0.isOptimistic }
            }
            XCTAssertEqual(client.cancelledAtReturn[1], false)
            XCTAssertEqual(model.sources.map(\.standardizedPath), urls.map { $0.standardizedFileURL.path })
            XCTAssertEqual(model.noticeMessage, "Cataloging 2 Development Policy sources; development is continuing.")
            XCTAssertEqual(client.pendingAddCount, 0)

            client.completeSnapshot()
            try await runeWorkspaceWait("The cancelled observation request did not drain.") { !model.isLoading }
            try fixture.preferences.setShown(true, for: "rune-controls", in: hidden.viewID)
            try await runeWorkspaceWait("Showing Rune did not resume observation with the same native panel owner.") {
                client.snapshotRequestCount == 2 && !controls.isHidden
                    && controls.hostingView === controlsHost && fixture.document === document
            }
        } catch {
            await fixture.close(client: client, runeModel: model)
            throw error
        }
        await fixture.close(client: client, runeModel: model)
    }

    private func runeWorkspaceWait(
        _ failure: String, timeout: Duration = .seconds(3),
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { throw RuneWorkspaceVisibilityFailure(failure) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    #endif

    func testNativePickerAcceptsFilesAndFoldersWithoutContentTypeAllowlist() {
        let panel = RuneForgePolicyPicker.makePanel()

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.allowsOtherFileTypes)
        XCTAssertTrue(panel.allowedContentTypes.isEmpty)
        XCTAssertEqual(panel.prompt, "Add Development Policy")
        XCTAssertEqual(
            panel.message,
            "Choose any file or folder containing development policy, governance, or guidance."
        )
    }

    func testTestSelectionHookRequiresExplicitUITestLaunch() {
        let path = "/tmp/rune-policy-selection.opaque"
        XCTAssertEqual(
            RuneForgePolicyPicker.select(
                arguments: ["Forge Conductor", "--uitesting"],
                environment: [RuneForgePolicyPicker.testSelectionEnvironmentKey: path]
            ).first?.path,
            path
        )
    }

    func testNativeExportPickerUsesExactFormatAndUITestHook() {
        let jsonl = RuneForgePolicyPicker.makeExportPanel(format: .jsonl)
        XCTAssertTrue(jsonl.canCreateDirectories)
        XCTAssertFalse(jsonl.isExtensionHidden)
        XCTAssertFalse(jsonl.allowsOtherFileTypes)
        XCTAssertEqual(jsonl.prompt, "Export Policy Log")
        XCTAssertEqual(jsonl.nameFieldStringValue, "stjornarvald-policy-log.jsonl")
        XCTAssertEqual(jsonl.allowedContentTypes.first?.preferredFilenameExtension, "jsonl")

        let path = "/tmp/stjornarvald-export.csv"
        XCTAssertEqual(
            RuneForgePolicyPicker.selectExportDestination(
                format: .csv,
                arguments: ["Forge Conductor", "--uitesting"],
                environment: [RuneForgePolicyPicker.testExportEnvironmentKey: path]
            )?.path,
            path
        )
    }

    func testSelectedSourceAppearsImmediatelyAndSurvivesDeferredManager() async throws {
        let client = DeferredRuneForgeClient()
        let viewModel = RuneForgeViewModel(client: client)
        let source = URL(fileURLWithPath: "/tmp/policy.unsupported-format")

        viewModel.addPolicySource(source)

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy.unsupported-format")
        XCTAssertEqual(viewModel.sources.first?.interpretationState, .accepted)
        XCTAssertTrue(viewModel.sources.first?.isOptimistic == true)

        try await waitUntil { viewModel.errorMessage != nil }
        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources.first?.interpretationState, .refreshPending)
        XCTAssertTrue(viewModel.sources.first?.latestObservation?.contains("remains visible") == true)
    }

    func testSuccessfulCatalogConfirmationReplacesOptimisticSource() async throws {
        let source = DevelopmentPolicySource(
            displayName: "policy-folder",
            selectedPath: "/tmp/policy-folder",
            rootKind: .directory,
            interpretationState: .cataloging,
            latestObservation: "Directory discovery is in progress."
        )
        let client = ConfirmingRuneForgeClient(source: source)
        let viewModel = RuneForgeViewModel(client: client)

        viewModel.addPolicySource(URL(fileURLWithPath: source.selectedPath, isDirectory: true))
        try await waitUntil { viewModel.sources.first?.sourceID == source.id }

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertFalse(viewModel.sources[0].isOptimistic)
        XCTAssertEqual(viewModel.sources[0].interpretationState, .cataloging)
        XCTAssertEqual(
            RuneForgeViewModel.sourceStateTitle(viewModel.sources[0].interpretationState),
            "Cataloging"
        )
    }

    func testOptimisticSourcePresentationIsBounded() {
        let viewModel = RuneForgeViewModel(client: DeferredRuneForgeClient())

        for index in 0...RuneForgeViewModel.maximumSources {
            viewModel.addPolicySource(
                URL(fileURLWithPath: "/tmp/policy-\(index).opaque")
            )
        }

        XCTAssertEqual(viewModel.sources.count, RuneForgeViewModel.maximumSources)
        XCTAssertEqual(viewModel.sources.first?.displayName, "policy-0.opaque")
        XCTAssertNil(
            viewModel.sources.first(where: { $0.displayName == "policy-100.opaque" })
        )
    }

    func testPolicyFeedEventsAreNewestFirstAndBounded() async {
        let events = (1...RuneForgeViewModel.maximumEvents + 1).map {
            policyEvent(sequence: Int64($0))
        }
        let viewModel = RuneForgeViewModel(
            client: SnapshotRuneForgeClient(snapshot: policySnapshot(events: events))
        )

        await viewModel.refreshNow()

        XCTAssertEqual(viewModel.events.count, RuneForgeViewModel.maximumEvents)
        XCTAssertEqual(viewModel.events.first?.sequence, Int64(RuneForgeViewModel.maximumEvents + 1))
        XCTAssertEqual(viewModel.events.last?.sequence, 2)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testZeroViolationsRetainsExplicitEvaluationCoverageAndUnknownFallback() async {
        let coverage = "Automatic detection covers 1 of 15 indexed Raven rules; other rules are guidance."
        let viewModel = RuneForgeViewModel(client: SnapshotRuneForgeClient(
            snapshot: policySnapshot(events: [], limitations: [coverage])))
        XCTAssertEqual(viewModel.evaluationCoverageDescription,
                       "Automatic policy evaluation coverage is unavailable.")
        await viewModel.refreshNow()
        XCTAssertTrue(viewModel.violations.isEmpty)
        XCTAssertEqual(viewModel.evaluationCoverageDescription, coverage)
    }

    func testProjectLogIDsIncludeRegisteredAndObservedProjectsExactlyOnce() {
        let observed = policyEvent(sequence: 1, projectID: "project-observed")
        XCTAssertEqual(
            RuneForgeViewModel.projectLogIDs(
                registeredProjectIDs: ["project-registered", "project-observed"],
                events: [observed]
            ),
            ["project-observed", "project-registered"]
        )
        let filters = StjornarvaldExportFilters(projectID: "project-observed")
        XCTAssertEqual(filters.projectID, "project-observed")
        XCTAssertNil(filters.projectGeneration)
    }

    func testPolicyEventStateTitlesExposeEveryStateWithoutRelyingOnColor() {
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.opened), "Policy violation")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.repeated), "Repeated")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.evidenceUpdated), "Evidence updated")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.corrected), "Corrected")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.reopened), "Reopened")
        XCTAssertEqual(RuneForgeViewModel.eventStateTitle(.disputed), "Interpretation observation")
    }

    func testNewerPolicyReorderSurvivesOlderLateSuccess() async throws {
        try await assertNewerPolicyReorderSurvivesOlderCompletion(.success)
    }

    func testNewerPolicyReorderSurvivesOlderLateCancellation() async throws {
        try await assertNewerPolicyReorderSurvivesOlderCompletion(.cancelled)
    }

    func testNewerPolicyReorderSurvivesOlderLateFailure() async throws {
        try await assertNewerPolicyReorderSurvivesOlderCompletion(.failure)
    }

    func testCurrentPolicyReorderCancellationRestoresPriorOrder() async throws {
        try await assertCurrentPolicyReorderRestoresPriorOrder(.cancelled)
    }

    func testCurrentPolicyReorderFailureRestoresPriorOrderAndError() async throws {
        try await assertCurrentPolicyReorderRestoresPriorOrder(.failure)
    }

    private func assertCurrentPolicyReorderRestoresPriorOrder(
        _ completion: ControlledRuneReorderClient.Completion
    ) async throws {
        let sources = ["A", "B", "C"].map {
            DevelopmentPolicySource(displayName: $0, selectedPath: "/tmp/rune-current-reorder-\($0)")
        }
        let client = ControlledRuneReorderClient(
            snapshot: policySnapshot(events: [], sources: sources)
        )
        let model = RuneForgeViewModel(client: client)
        defer {
            model.stop()
            client.cancelPendingRequests()
        }
        await model.refreshNow()
        model.movePolicySource(sources[0].id.description, to: sources[2].id.description)
        try await waitUntil { client.requestCount == 1 }
        XCTAssertEqual(model.sources.compactMap(\.sourceID), [sources[1].id, sources[2].id, sources[0].id])
        client.complete(request: 0, with: completion)
        try await waitUntil { client.returnedRequests == [0] }
        await Task.yield()
        XCTAssertEqual(model.sources.compactMap(\.sourceID), sources.map(\.id))
        XCTAssertEqual(client.pendingRequestCount, 0)
        XCTAssertNil(model.noticeMessage)
        switch completion {
        case .failure: XCTAssertNotNil(model.errorMessage)
        case .cancelled: XCTAssertNil(model.errorMessage)
        case .success: XCTFail("This rollback control requires cancellation or failure")
        }
    }

    private func assertNewerPolicyReorderSurvivesOlderCompletion(
        _ completion: ControlledRuneReorderClient.Completion
    ) async throws {
        let sources = ["A", "B", "C"].map {
            DevelopmentPolicySource(displayName: $0, selectedPath: "/tmp/rune-reorder-\($0)")
        }
        let client = ControlledRuneReorderClient(
            snapshot: policySnapshot(events: [], sources: sources)
        )
        let model = RuneForgeViewModel(client: client)
        defer {
            model.stop()
            client.cancelPendingRequests()
        }
        await model.refreshNow()
        XCTAssertEqual(model.sources.compactMap(\.sourceID), sources.map(\.id))

        model.movePolicySource(sources[0].id.description, to: sources[2].id.description)
        try await waitUntil { client.requestCount == 1 }
        let olderOrder = [sources[1].id, sources[2].id, sources[0].id]
        XCTAssertEqual(client.requestedOrders.first, olderOrder)
        XCTAssertEqual(model.sources.compactMap(\.sourceID), olderOrder)

        model.movePolicySource(sources[1].id.description, to: sources[0].id.description)
        try await waitUntil { client.requestCount == 2 }
        let newerOrder = [sources[2].id, sources[0].id, sources[1].id]
        XCTAssertEqual(client.requestedOrders.last, newerOrder)
        XCTAssertEqual(model.sources.compactMap(\.sourceID), newerOrder)

        client.complete(request: 1, with: .success)
        try await waitUntil { client.returnedRequests == [1] }
        await Task.yield()
        XCTAssertEqual(model.sources.compactMap(\.sourceID), newerOrder)
        XCTAssertEqual(model.noticeMessage, "Development Policy priority updated.")
        XCTAssertNil(model.errorMessage)

        // The protocol client deliberately finishes an already-cancelled request
        // after the newer response. Its same-main-actor return is the completion
        // witness; no network delay or unbounded sleep establishes this order.
        client.complete(request: 0, with: completion)
        try await waitUntil { client.returnedRequests == [1, 0] }
        await Task.yield()
        XCTAssertEqual(client.cancelledAtReturn[0], true)
        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(client.pendingRequestCount, 0)
        XCTAssertEqual(model.sources.compactMap(\.sourceID), newerOrder)
        XCTAssertEqual(model.noticeMessage, "Development Policy priority updated.")
        XCTAssertNil(model.errorMessage)
    }

    private func policySnapshot(events: [PolicyViolationEvent], limitations: [String] = [], sources: [DevelopmentPolicySource] = []) -> StjornarvaldManagerSnapshot {
        let sourceID = PolicySourceID()
        return StjornarvaldManagerSnapshot(
            schemaVersion: StjornarvaldManagerSnapshot.schemaVersion,
            health: StjornarvaldManagerHealth(
                state: .running,
                policyIdentity: "fixture-policy",
                evaluatorID: "fixture-evaluator",
                startedAt: Date(timeIntervalSince1970: 1),
                lastEvaluationAt: Date(timeIntervalSince1970: 2),
                lastCommittedCursor: events.last?.sequence ?? 0,
                processedObservationCount: events.count,
                indexedSourceBatchCount: 1,
                consecutiveFailureCount: 0,
                lastError: nil
            ),
            governingPolicy: GoverningPolicyIdentity(
                bindingID: "fixture-policy",
                authority: "Fixture",
                repositoryURL: "https://example.invalid/policy",
                version: "1",
                revision: "fixture-revision",
                sourceID: sourceID
            ),
            sources: sources,
            violationEvents: events,
            nextEventCursor: nil,
            limitations: limitations
        )
    }

    private func policyEvent(sequence: Int64, projectID: String? = nil) -> PolicyViolationEvent {
        let sourceID = PolicySourceID()
        let rule = PolicyRule(
            id: PolicyRuleID("fixture-rule-\(sequence)"),
            source: PolicySourceReference(
                sourceID: sourceID,
                revision: "fixture-revision",
                path: "/tmp/policy.md",
                locator: "line \(sequence)"
            ),
            statement: "Keep the implementation native.",
            policyArea: "runtime",
            applicability: "fixture",
            confidence: 1
        )
        let candidate = PolicyViolationCandidate(
            rule: rule,
            observationID: UUID(),
            scope: DevelopmentObservationScope(projectID: projectID),
            subjectIdentity: "fixture-subject",
            summary: "Fixture policy event \(sequence)",
            evidenceReferences: ["fixture.swift:\(sequence)"],
            explanation: "The fixture observed a policy mismatch.",
            confidence: 0.9,
            assumptions: ["The fixture is representative."],
            alternatives: ["Retain the native implementation."],
            suggestedCorrection: "Use the approved native framework."
        )
        return PolicyViolationEvent(
            schemaVersion: "1.0.0",
            sequence: sequence,
            id: UUID(),
            type: .opened,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            violationID: PolicyViolationID(),
            fingerprint: "fixture-fingerprint-\(sequence)",
            candidate: candidate,
            noticeState: "presented",
            priorEventSHA256: nil,
            eventSHA256: String(repeating: "a", count: 64),
            developmentContinues: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { return XCTFail("condition timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct SnapshotRuneForgeClient: RuneForgeManagerClientProtocol {
    let snapshot: StjornarvaldManagerSnapshot

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot { snapshot }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage {
        StjornarvaldViolationPage(violations: [], nextCursor: nil, controlsExecution: false)
    }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.unsupportedURL) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.unsupportedURL) }
}

private struct DeferredRuneForgeClient: RuneForgeManagerClientProtocol {
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        throw URLError(.cannotConnectToHost)
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await Task.sleep(for: .milliseconds(25))
        throw URLError(.cannotConnectToHost)
    }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.cannotConnectToHost) }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw URLError(.cannotConnectToHost) }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw URLError(.cannotConnectToHost) }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.cannotConnectToHost) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.cannotConnectToHost) }
}

private struct ConfirmingRuneForgeClient: RuneForgeManagerClientProtocol {
    let source: DevelopmentPolicySource

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        throw URLError(.cannotConnectToHost)
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { source }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw URLError(.cannotConnectToHost) }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw URLError(.cannotConnectToHost) }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw URLError(.cannotConnectToHost) }
}

@MainActor
private final class ControlledRuneReorderClient: RuneForgeManagerClientProtocol {
    enum Completion { case success, cancelled, failure }
    private let snapshot: StjornarvaldManagerSnapshot
    private var continuations: [Int: CheckedContinuation<[DevelopmentPolicySource], Error>] = [:]
    private(set) var requestedOrders: [[PolicySourceID]] = []
    private(set) var returnedRequests: [Int] = []
    private(set) var cancelledAtReturn: [Int: Bool] = [:]
    var requestCount: Int { requestedOrders.count }
    var pendingRequestCount: Int { continuations.count }

    init(snapshot: StjornarvaldManagerSnapshot) { self.snapshot = snapshot }

    func reorderRuneForgeSources(sourceIDs: [PolicySourceID]) async throws -> [DevelopmentPolicySource] {
        guard requestedOrders.count < 2 else { throw URLError(.badServerResponse) }
        let request = requestedOrders.count
        requestedOrders.append(sourceIDs)
        defer {
            cancelledAtReturn[request] = Task.isCancelled
            returnedRequests.append(request)
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func complete(request: Int, with completion: Completion) {
        guard let continuation = continuations.removeValue(forKey: request) else {
            XCTFail("Missing pending reorder request \(request)")
            return
        }
        switch completion {
        case .success:
            let byID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
            continuation.resume(returning: requestedOrders[request].compactMap { byID[$0] })
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .failure: continuation.resume(throwing: URLError(.cannotConnectToHost))
        }
    }

    func cancelPendingRequests() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot { snapshot }
    func addRuneForgeSource(path: String, requestID: UUID) async throws -> DevelopmentPolicySource {
        throw URLError(.unsupportedURL)
    }
    func refreshRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource {
        throw URLError(.unsupportedURL)
    }
    func removeRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource {
        throw URLError(.unsupportedURL)
    }
    func runeForgeViolations(cursor: Int64, limit: Int,
                             state: PolicyViolationProjectionState?) async throws -> StjornarvaldViolationPage {
        StjornarvaldViolationPage(violations: [], nextCursor: nil, controlsExecution: false)
    }
    func scheduleRuneForgeScan(requestID: UUID, reason: String) async throws -> StjornarvaldScanReceipt {
        throw URLError(.unsupportedURL)
    }
    func requestRuneForgeExport(format: StjornarvaldExportFormat, destination: String,
                               filters: StjornarvaldExportFilters,
                               requestID: UUID) async throws -> StjornarvaldExportReceipt {
        throw URLError(.unsupportedURL)
    }
}

#if !SWIFT_PACKAGE
private struct RuneWorkspaceVisibilityFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class RuneWorkspaceCancellationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func markCancelled() { lock.withLock { cancelled = true } }
}

@MainActor
private final class ControlledRuneWorkspaceAddClient: RuneForgeManagerClientProtocol {
    private let initialSnapshot: StjornarvaldManagerSnapshot
    private var snapshotContinuation: CheckedContinuation<StjornarvaldManagerSnapshot, Error>?
    private var addContinuations: [Int: CheckedContinuation<DevelopmentPolicySource, Error>] = [:]
    private var registeredSources: [DevelopmentPolicySource] = []
    let snapshotCancellation = RuneWorkspaceCancellationWitness()
    private(set) var snapshotRequestCount = 0
    private(set) var requestedPaths: [String] = []
    private(set) var returnedRequests: [Int] = []
    private(set) var cancelledAtReturn: [Int: Bool] = [:]
    var pendingAddCount: Int { addContinuations.count }

    init(snapshot: StjornarvaldManagerSnapshot) { initialSnapshot = snapshot }

    private func snapshot() -> StjornarvaldManagerSnapshot {
        .init(schemaVersion: initialSnapshot.schemaVersion, health: initialSnapshot.health,
              governingPolicy: initialSnapshot.governingPolicy, sources: registeredSources,
              violationEvents: [], nextEventCursor: nil, limitations: [])
    }

    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        guard snapshotRequestCount < 3 else { throw RuneWorkspaceVisibilityFailure("Unexpected recurring snapshot request.") }
        snapshotRequestCount += 1
        guard snapshotRequestCount == 1 else { return snapshot() }
        let witness = snapshotCancellation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { snapshotContinuation = $0 }
        } onCancel: {
            witness.markCancelled()
        }
    }

    func completeSnapshot() {
        guard let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        continuation.resume(returning: snapshot())
    }

    func addRuneForgeSource(path: String, requestID: UUID) async throws -> DevelopmentPolicySource {
        guard requestedPaths.count < 2 else { throw RuneWorkspaceVisibilityFailure("Unexpected additional registration request.") }
        let request = requestedPaths.count
        requestedPaths.append(path)
        defer {
            cancelledAtReturn[request] = Task.isCancelled
            returnedRequests.append(request)
        }
        return try await withCheckedThrowingContinuation { addContinuations[request] = $0 }
    }

    func completeAdd(request: Int) {
        guard let continuation = addContinuations.removeValue(forKey: request) else {
            XCTFail("Missing pending registration request \(request)")
            return
        }
        let source = DevelopmentPolicySource(displayName: URL(fileURLWithPath: requestedPaths[request]).lastPathComponent,
            selectedPath: requestedPaths[request], interpretationState: .cataloging)
        registeredSources.append(source)
        continuation.resume(returning: source)
    }

    func cancelPendingRequests() {
        let snapshot = snapshotContinuation
        snapshotContinuation = nil
        let adds = Array(addContinuations.values)
        addContinuations.removeAll()
        snapshot?.resume(throwing: CancellationError())
        for continuation in adds { continuation.resume(throwing: CancellationError()) }
    }

    func runeForgeViolations(cursor: Int64, limit: Int, state: PolicyViolationProjectionState?) async throws -> StjornarvaldViolationPage {
        .init(violations: [], nextCursor: nil, controlsExecution: false)
    }
    func refreshRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }
    func removeRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }
    func scheduleRuneForgeScan(requestID: UUID, reason: String) async throws -> StjornarvaldScanReceipt { throw URLError(.unsupportedURL) }
    func requestRuneForgeExport(format: StjornarvaldExportFormat, destination: String,
                               filters: StjornarvaldExportFilters, requestID: UUID) async throws -> StjornarvaldExportReceipt { throw URLError(.unsupportedURL) }
}

@MainActor
private final class RuneWorkspaceVisibilityFixture {
    let suite: String
    let home: URL
    let defaults: UserDefaults
    let preferences: NativeWorkspacePreferences
    let model: AppModel
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
    let layout: NativeWorkspaceLayout

    init(model runeModel: RuneForgeViewModel, urls: [URL]) throws {
        let localSuite = "forge.rune.workspace.visibility.tests.\(UUID().uuidString)"
        let localHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/Codex Working Folders/Forge-Conductor-MacOS")
            .appendingPathComponent("native-rune-workspace-visibility-\(UUID().uuidString)")
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: localSuite))
        let descriptors = NativeWorkspaceCatalog.runePanels(for: "overview")
        let owner = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: localDefaults)
        let width = max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0)
        let height = max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)
        let initial = NativeWorkspaceLayout(id: UUID(), viewID: "rune-forge.overview", name: "Rune visibility",
            canvas: .init(width: width, height: height),
            panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        do { try owner.save(initial) }
        catch { localDefaults.removePersistentDomain(forName: localSuite); throw error }
        let bootstrap = AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil })
        let modelOwner = AppModel(bootstrapOperation: bootstrap, diagnosticPaths: AppPaths(home: localHome))
        modelOwner.autoRefresh = false
        let workbench = WorkbenchPreferences(defaults: localDefaults)
        let guided = GuidedModeCoordinator(defaults: localDefaults)
        let nativeHost = NSHostingView(rootView: AnyView(RuneForgeOperatorView(viewModel: runeModel,
            selectPolicySources: { urls }, selectExportDestination: { _ in nil })
            .environment(\.nativeWorkspacePreferences, owner)
            .environmentObject(modelOwner).environmentObject(workbench).environmentObject(guided)
            .graphiteWorkbench()))
        let nativeWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_280, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.title = "Rune workspace visibility \(UUID().uuidString)"
        nativeWindow.contentView = nativeHost
        suite = localSuite; home = localHome; defaults = localDefaults; preferences = owner
        model = modelOwner; hosting = nativeHost; window = nativeWindow; layout = initial
    }

    var document: NativeWorkspaceDocumentView? {
        var stack: [(NSView, Int)] = [(hosting, 0)]
        var visited = Set<ObjectIdentifier>()
        while let (view, depth) = stack.popLast() {
            guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
            guard visited.count <= 2_048, depth <= 32 else { return nil }
            if let document = view as? NativeWorkspaceDocumentView { return document }
            let children = view.subviews
            guard stack.count + children.count <= 2_048 else { return nil }
            stack.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    func close(client: ControlledRuneWorkspaceAddClient, runeModel: RuneForgeViewModel) async {
        runeModel.stop()
        client.cancelPendingRequests()
        window.endEditing(for: nil); _ = window.makeFirstResponder(nil)
        hosting.rootView = AnyView(EmptyView())
        window.orderOut(nil); window.contentView = nil; window.close()
        await model.stopBootstrap()
        model.telemetryBinding.detach()
        await Task.yield()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }
}


@MainActor
private final class RuneWorkspaceRouteClient: RuneForgeManagerClientProtocol {
    private let snapshot: StjornarvaldManagerSnapshot
    private let violation: StjornarvaldViolationPageItem
    private(set) var snapshotReads = 0
    private(set) var violationReads = 0
    private(set) var mutationRequests = 0
    init(snapshot: StjornarvaldManagerSnapshot, violation: StjornarvaldViolationPageItem) {
        self.snapshot = snapshot; self.violation = violation
    }
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        guard snapshotReads < 8 else { throw RuneWorkspaceVisibilityFailure("Rune route observation exceeded8 snapshot reads.") }
        snapshotReads += 1; return snapshot
    }
    func runeForgeViolations(cursor: Int64, limit: Int, state: PolicyViolationProjectionState?) async throws -> StjornarvaldViolationPage {
        guard violationReads < 8, cursor == 0, limit > 0, state == nil else {
            throw RuneWorkspaceVisibilityFailure("Rune route observation exceeded its first-page contract.")
        }
        violationReads += 1
        return .init(violations: [violation], nextCursor: nil, controlsExecution: false)
    }
    private func rejectMutation() throws -> Never {
        guard mutationRequests < 8 else { throw RuneWorkspaceVisibilityFailure("Rune route mutation counter exceeded its bound.") }
        mutationRequests += 1
        throw RuneWorkspaceVisibilityFailure("Rune route input unexpectedly requested a backend mutation.")
    }
    func addRuneForgeSource(path: String, requestID: UUID) async throws -> DevelopmentPolicySource { try rejectMutation() }
    func refreshRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource { try rejectMutation() }
    func removeRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource { try rejectMutation() }
    func reorderRuneForgeSources(sourceIDs: [PolicySourceID]) async throws -> [DevelopmentPolicySource] { try rejectMutation() }
    func scheduleRuneForgeScan(requestID: UUID, reason: String) async throws -> StjornarvaldScanReceipt { try rejectMutation() }
    func requestRuneForgeExport(format: StjornarvaldExportFormat, destination: String,
                               filters: StjornarvaldExportFilters, requestID: UUID) async throws -> StjornarvaldExportReceipt { try rejectMutation() }
}

@MainActor
private final class RuneWorkspaceNamingClient: RuneForgeManagerClientProtocol {
    private var snapshot: StjornarvaldManagerSnapshot
    private var requests = 0
    init(snapshot: StjornarvaldManagerSnapshot) { self.snapshot = snapshot }
    func replaceSnapshot(_ snapshot: StjornarvaldManagerSnapshot) { self.snapshot = snapshot }
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        guard requests < 4 else { throw RuneWorkspaceVisibilityFailure("Unexpected recurring naming-fixture observation.") }
        requests += 1; return snapshot
    }
    func runeForgeViolations(cursor: Int64, limit: Int, state: PolicyViolationProjectionState?) async throws -> StjornarvaldViolationPage {
        .init(violations: [], nextCursor: nil, controlsExecution: false)
    }
    func addRuneForgeSource(path: String, requestID: UUID) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }
    func refreshRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }
    func removeRuneForgeSource(sourceID: PolicySourceID, requestID: UUID) async throws -> DevelopmentPolicySource { throw URLError(.unsupportedURL) }
    func scheduleRuneForgeScan(requestID: UUID, reason: String) async throws -> StjornarvaldScanReceipt { throw URLError(.unsupportedURL) }
    func requestRuneForgeExport(format: StjornarvaldExportFormat, destination: String,
                               filters: StjornarvaldExportFilters, requestID: UUID) async throws -> StjornarvaldExportReceipt { throw URLError(.unsupportedURL) }
}

@MainActor
private final class RuneWorkspaceNamingMenuSelection: NSObject {
    let started = ProcessInfo.processInfo.systemUptime
    let deadline: TimeInterval
    let ownedWindow: AXUIElement
    let opener: AXUIElement
    weak var observer: RuneWorkspaceNamingAX?
    var result: Result<Void, Error>?
    var querying = false
    var ticks = 0
    var openerAction: String?
    var openerStatus: Int32?
    var renameAction: String?
    var renameStatus: Int32?
    var callbackMode: String?
    var callbackError: String?
    var relationshipDiagnostics: [[String: Any]] = []
    var diagnosticFailed = false
    var isFinished: Bool { if case .some = result { return true }; return false }

    init(window: AXUIElement, opener: AXUIElement, deadline: TimeInterval, observer: RuneWorkspaceNamingAX) {
        ownedWindow = window; self.opener = opener; self.deadline = deadline; self.observer = observer
        super.init()
    }
    @objc func fire(_ timer: Timer) {
        guard let observer else { timer.invalidate(); return }
        observer.menuTimerDidFire(self, timer: timer)
    }
}

private enum RuneWorkspaceWindowIdentifierScope: Equatable { case wholeWindow, applicationContent }

@MainActor
private final class RuneWorkspaceNamingAX {
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    private let pid = getpid()
    private(set) var lastNodes: [[String: Any]] = []
    private(set) var lastRead: [String: Any] = [:]
    private(set) var lastMenuTransition: [String: Any] = [:]
    private(set) var lastRouteSelectionCapability: [String: Any] = [:]
    private var lastWalkContext: [String: Any] = [:]
    private(set) var lastRequiredWalkContext: [String: Any] = [:]
    private(set) var lastApplicationContentWindowScope: [String: Any] = [:]
    init(window: NSWindow, hosting: NSView) { self.window = window; self.hosting = hosting }

    private func check(_ deadline: TimeInterval) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("The own-window naming AX query exceeded its three-second deadline.")
        }
    }
    private func prepare(_ element: AXUIElement, _ deadline: TimeInterval) throws {
        try check(deadline)
        var actual: pid_t = 0
        let status = AXUIElementGetPid(element, &actual)
        guard status == .success, actual == pid else { throw RuneWorkspaceVisibilityFailure("Naming AX escaped the own PID: \(status.rawValue), \(actual).") }
        let timeout = AXUIElementSetMessagingTimeout(element, 0.1)
        guard timeout == .success else { throw RuneWorkspaceVisibilityFailure("Naming AX timeout failed: \(timeout.rawValue).") }
    }
    private func attribute(_ element: AXUIElement, _ key: String, _ deadline: TimeInterval) throws -> CFTypeRef? {
        try prepare(element, deadline)
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &result)
        lastRead = ["attribute": key, "actual_status": status.rawValue]
        try check(deadline)
        guard status == .success || status == .noValue || status == .attributeUnsupported else {
            throw RuneWorkspaceVisibilityFailure("Naming AX \(key) failed: \(status.rawValue).")
        }
        return status == .success ? result : nil
    }
    private func string(_ element: AXUIElement, _ key: String, _ deadline: TimeInterval) throws -> String? {
        guard let value = try attribute(element, key, deadline) else { return nil }
        guard let string = value as? String, string.utf8.count <= 4_096 else { throw RuneWorkspaceVisibilityFailure("Naming AX \(key) returned an invalid/unbounded string.") }
        return string
    }
    private func children(_ element: AXUIElement, _ key: String, limit: Int, _ deadline: TimeInterval) throws -> [AXUIElement] {
        try prepare(element, deadline)
        var count = 0
        let status = AXUIElementGetAttributeValueCount(element, key as CFString, &count)
        try check(deadline)
        if status == .noValue || status == .attributeUnsupported { return [] }
        guard status == .success, count >= 0, count <= limit else { throw RuneWorkspaceVisibilityFailure("Naming AX \(key) count failed/exceeded bound: \(status.rawValue), \(count).") }
        guard count > 0 else { return [] }
        var array: CFArray?
        let copied = AXUIElementCopyAttributeValues(element, key as CFString, 0, count, &array)
        try check(deadline)
        guard copied == .success, let values = array as? [AXUIElement], values.count == count else { throw RuneWorkspaceVisibilityFailure("Naming AX \(key) child copy failed: \(copied.rawValue).") }
        return values
    }
    func observePlainAppKitStandardZoom(deadline: TimeInterval, report: inout [String: Any]) throws -> Error? {
        let root = try ownedWindow(deadline)
        guard let rawZoom = try attribute(root, kAXZoomButtonAttribute, deadline),
              CFGetTypeID(rawZoom) == AXUIElementGetTypeID() else {
            throw RuneWorkspaceVisibilityFailure("Plain AppKit comparison requires a typed exact owned-window Zoom reference.")
        }
        let zoom = rawZoom as! AXUIElement
        try prepare(zoom, deadline)
        try requireOwnedWindowAncestor(zoom, root: root, deadline: deadline)
        let role = try string(zoom, kAXRoleAttribute, deadline)
        let subrole = try string(zoom, kAXSubroleAttribute, deadline)
        guard role == kAXButtonRole, let subrole,
              subrole == kAXZoomButtonSubrole || subrole == kAXFullScreenButtonSubrole else {
            throw RuneWorkspaceVisibilityFailure("Plain AppKit comparison requires an owned standard Zoom/Full Screen AXButton.")
        }
        report["standard_subrole"] = subrole
        report["full_screen_reference_matches_zoom"] = NSNull()
        if subrole == kAXFullScreenButtonSubrole {
            guard let raw = try attribute(root, kAXFullScreenButtonAttribute, deadline),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw RuneWorkspaceVisibilityFailure("Plain AppKit Full Screen subrole lacks a typed owned-window reference.")
            }
            let fullScreen = raw as! AXUIElement
            try prepare(fullScreen, deadline)
            try requireOwnedWindowAncestor(fullScreen, root: root, deadline: deadline)
            let same = CFEqual(fullScreen, zoom)
            report["full_screen_reference_matches_zoom"] = same
            guard same else { throw RuneWorkspaceVisibilityFailure("Plain AppKit Full Screen and Zoom references differ.") }
        }
        let identifier = try string(zoom, kAXIdentifierAttribute, deadline)
        report["standard_control_metadata"] = diagnosticNodeMetadata(identifier, role, nil)
        report["subtree_root_is_exact_zoom_not_window"] = true
        report["subtree_node_limit"] = 2_048; report["subtree_depth_limit"] = 48
        var scalarError: Error?
        do {
            let tree = try nodes(zoom, deadline, queryContext: ["operation": "plain-AppKit-exact-Zoom-subtree"])
            report["subtree_complete"] = true; report["subtree_completed_nodes"] = tree.count
        } catch {
            let key = lastRead["attribute"] as? String, status = lastRead["actual_status"] as? Int32
            guard lastWalkContext["phase"] as? String == "query-scalars",
                  let key, [kAXIdentifierAttribute, kAXRoleAttribute, kAXTitleAttribute].contains(key),
                  let status, status != AXError.success.rawValue, status != AXError.noValue.rawValue,
                  status != AXError.attributeUnsupported.rawValue,
                  ProcessInfo.processInfo.systemUptime < deadline else { throw error }
            report["subtree_complete"] = false; report["original_scalar_read"] = lastRead
            var context = lastWalkContext
            // The generic walker queried these references on the Zoom root, not on an AXWindow.
            context.removeValue(forKey: "failure_only_standard_window_references")
            report["original_scalar_failure_context"] = context
            report["original_scalar_error"] = String(String(describing: error).prefix(512))
            scalarError = error
        }
        report["cached_nodes_first64"] = lastNodes.map { row in
            var bounded = diagnosticNodeMetadata(row["identifier"] as? String, row["role"] as? String, row["title"] as? String)
            bounded["depth"] = row["depth"]; return bounded
        }
        let freshRoot = try ownedWindow(deadline)
        guard CFEqual(root, freshRoot) else { throw RuneWorkspaceVisibilityFailure("Plain AppKit comparison changed its exact owned exported window.") }
        try check(deadline)
        report["fresh_owned_window_reference_equal"] = true
        // Retain an observed scalar error only to sample later lifecycle phases; the test rethrows the first one.
        return scalarError
    }

    private func ownedWindow(_ deadline: TimeInterval) throws -> AXUIElement {
        guard let window, let hosting, window.contentView === hosting, hosting.window === window,
              window.isVisible, !hosting.isHiddenOrHasHiddenAncestor else { throw RuneWorkspaceVisibilityFailure("Naming fixture lost its exact visible native window/host.") }
        let application = AXUIElementCreateApplication(pid)
        let windows = try children(application, kAXWindowsAttribute, limit: 32, deadline)
        var matches: [AXUIElement] = []
        for candidate in windows where try string(candidate, kAXTitleAttribute, deadline) == window.title {
            guard try string(candidate, kAXRoleAttribute, deadline) == kAXWindowRole else { throw RuneWorkspaceVisibilityFailure("Naming export title matched a non-window.") }
            matches.append(candidate)
        }
        guard matches.count == 1 else { throw RuneWorkspaceVisibilityFailure("Naming public AX did not export exactly one owned native window: \(matches.count).") }
        return matches[0]
    }
    private func diagnosticNodeMetadata(_ identifier: String?, _ role: String?, _ title: String?) -> [String: Any] {
        func prefix(_ value: String?) -> Any {
            value.map { String(decoding: $0.utf8.prefix(256), as: UTF8.self) as Any } ?? NSNull()
        }
        return ["identifier_prefix": prefix(identifier), "role_prefix": prefix(role), "title_prefix": prefix(title),
                "identifier_prefix_capped": identifier.map { ($0.utf8.count > 256) as Any } ?? NSNull(),
                "role_prefix_capped": role.map { ($0.utf8.count > 256) as Any } ?? NSNull(),
                "title_prefix_capped": title.map { ($0.utf8.count > 256) as Any } ?? NSNull()]
    }
    private func failureOnlyRootStandardReferences(root: AXUIElement, ancestors: [AXUIElement],
                                                   path: [Int], originalScalarRead: [String: Any]) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime, diagnosticDeadline = started + 0.3
        var record: [String: Any] = ["classification": "Failure-only public root reference comparison; no traversal substitution, native-class or error-cause claim",
            "post_failure_budget_seconds": 0.3, "existing_root_timeout_seconds": 0.1,
            "original_last_scalar_read": originalScalarRead, "held_ancestor_count": ancestors.count,
            "copied_first_edge_index": path.first.map { $0 as Any } ?? NSNull(),
            "query_limit": 3, "query_count": 0, "reference_rows": [:], "budget_expired": false]
        func finishedRecord() -> [String: Any] {
            let ended = ProcessInfo.processInfo.systemUptime
            record["elapsed_seconds"] = ended - started
            record["budget_expired"] = record["budget_expired"] as? Bool == true || ended >= diagnosticDeadline
            return record
        }
        guard ancestors.count >= 2, !path.isEmpty else {
            record["unavailable"] = "No already-held first-edge ancestor of the failed node"
            return finishedRecord()
        }
        let firstEdgeAncestor = ancestors[1]
        record["held_root_CFEqual_ancestor0"] = CFEqual(root, ancestors[0])
        guard record["held_root_CFEqual_ancestor0"] as? Bool == true else {
            record["unavailable"] = "Held ancestry does not match the original queried root"
            return finishedRecord()
        }
        var rows: [String: Any] = [:], count = 0
        for attribute in [kAXZoomButtonAttribute, kAXCloseButtonAttribute, kAXMinimizeButtonAttribute] {
            guard ProcessInfo.processInfo.systemUptime < diagnosticDeadline else { record["budget_expired"] = true; break }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(root, attribute as CFString, &raw)
            count += 1
            var row: [String: Any] = ["raw_status": status.rawValue,
                "returned_type_id": raw.map { Int(CFGetTypeID($0)) as Any } ?? NSNull(),
                "returned_AXUIElement": raw.map { (CFGetTypeID($0) == AXUIElementGetTypeID()) as Any } ?? NSNull(),
                "CFEqual_to_held_first_edge_ancestor": NSNull()]
            if status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                row["CFEqual_to_held_first_edge_ancestor"] = CFEqual(raw, firstEdgeAncestor)
            }
            rows[attribute] = row
        }
        record["reference_rows"] = rows; record["query_count"] = count
        record["all_three_copies_attempted"] = count == 3
        return finishedRecord()
    }
    private func failureOnlyHeldChildRole(_ element: AXUIElement) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime, diagnosticDeadline = started + 0.1
        var record: [String: Any] = ["classification": "Post-failure Role on the same held child; not original query state, retry, native-class proof or cause",
            "post_failure_budget_seconds": 0.1, "original_query_timeout_seconds": 0.1,
            "attribute": kAXRoleAttribute, "query_limit": 1, "query_count": 0,
            "raw_status": NSNull(), "returned_type_id": NSNull(), "role_utf8_prefix": NSNull(),
            "role_utf8_input_prefix_limit": 128, "snapshot_uptime": started]
        if ProcessInfo.processInfo.systemUptime < diagnosticDeadline {
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw)
            record["query_count"] = 1; record["raw_status"] = status.rawValue
            record["returned_type_id"] = raw.map { Int(CFGetTypeID($0)) as Any } ?? NSNull()
            if let value = raw as? String {
                record["role_utf8_prefix"] = String(decoding: value.utf8.prefix(128), as: UTF8.self)
            }
        }
        let finished = ProcessInfo.processInfo.systemUptime
        record["elapsed_seconds"] = finished - started
        record["budget_expired"] = finished >= diagnosticDeadline
        return record
    }
    private func failureOnlyFreshParentMembership(_ element: AXUIElement, ancestors: [AXUIElement],
                                                   originalDeadline: TimeInterval) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = min(originalDeadline, started + 0.1)
        var record: [String: Any] = ["classification": "Failure-only exact held-parent child recopy and CFEqual membership; no fallback, original-error replacement or cause claim",
            "post_failure_budget_seconds": 0.1, "original_query_deadline": originalDeadline,
            "diagnostic_deadline": deadline, "child_limit": 16, "membership_copy_complete": false,
            "parent_pid_queries": 0, "count_queries": 0, "copy_queries": 0,
            "child_pid_queries": 0, "role_queries": 0, "matching_child_count": NSNull()]
        func finish() -> [String: Any] {
            let ended = ProcessInfo.processInfo.systemUptime
            record["elapsed_seconds"] = ended - started; record["budget_expired"] = ended >= deadline
            return record
        }
        guard let parent = ancestors.last, ProcessInfo.processInfo.systemUptime < deadline else {
            record["unavailable"] = "No held parent or remaining original query budget"; return finish()
        }
        var parentPID: pid_t = 0
        let parentStatus = AXUIElementGetPid(parent, &parentPID)
        record["parent_pid_queries"] = 1; record["parent_pid_status"] = parentStatus.rawValue
        record["parent_pid"] = parentPID
        guard parentStatus == .success, parentPID == pid, ProcessInfo.processInfo.systemUptime < deadline else {
            record["unavailable"] = "Held parent own-PID validation failed or budget expired"; return finish()
        }
        var count = 0
        let countStatus = AXUIElementGetAttributeValueCount(parent, kAXChildrenAttribute as CFString, &count)
        record["count_queries"] = 1; record["count_status"] = countStatus.rawValue
        record["returned_count"] = countStatus == .success ? count as Any : NSNull()
        guard countStatus == .success, count >= 0, count <= 16,
              ProcessInfo.processInfo.systemUptime < deadline else {
            record["unavailable"] = "Parent child count failed, exceeded16 or budget expired"; return finish()
        }
        if count == 0 {
            record["membership_copy_complete"] = true; record["matching_child_count"] = 0
            record["empty_children_without_indexed_copy"] = true; return finish()
        }
        var array: CFArray?
        let copyStatus = AXUIElementCopyAttributeValues(parent, kAXChildrenAttribute as CFString, 0, count, &array)
        record["copy_queries"] = 1; record["copy_status"] = copyStatus.rawValue
        record["copy_type_id"] = array.map { Int(CFGetTypeID($0)) as Any } ?? NSNull()
        guard copyStatus == .success, let array, CFGetTypeID(array) == CFArrayGetTypeID(),
              let values = array as? [AXUIElement], values.count == count,
              ProcessInfo.processInfo.systemUptime < deadline else {
            record["unavailable"] = "Parent child copy failed, changed type/count or budget expired"; return finish()
        }
        var rows: [[String: Any]] = [], matches: [AXUIElement] = []
        for child in values {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  CFGetTypeID(child) == AXUIElementGetTypeID() else {
                record["child_rows"] = rows; record["unavailable"] = "Child type invalid or budget expired"; return finish()
            }
            var childPID: pid_t = 0
            let status = AXUIElementGetPid(child, &childPID)
            record["child_pid_queries"] = rows.count + 1
            let same = CFEqual(child, element)
            rows.append(["pid_status": status.rawValue, "pid": childPID, "CFEqual_to_held_failed_child": same])
            guard status == .success, childPID == pid, ProcessInfo.processInfo.systemUptime < deadline else {
                record["child_rows"] = rows; record["unavailable"] = "Copied child own-PID validation failed or budget expired"; return finish()
            }
            if same { matches.append(child) }
        }
        record["child_rows"] = rows; record["membership_copy_complete"] = true
        record["matching_child_count"] = matches.count
        guard matches.count == 1, let fresh = matches.first, ProcessInfo.processInfo.systemUptime < deadline else {
            record["fresh_role_unavailable"] = "No unique exact copied match or remaining budget"; return finish()
        }
        let timeoutStatus = AXUIElementSetMessagingTimeout(fresh, 0.1)
        record["fresh_timeout_status"] = timeoutStatus.rawValue
        guard timeoutStatus == .success, ProcessInfo.processInfo.systemUptime < deadline else {
            record["fresh_role_unavailable"] = "Fresh match messaging timeout failed or budget expired"; return finish()
        }
        var raw: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(fresh, kAXRoleAttribute as CFString, &raw)
        record["role_queries"] = 1; record["fresh_role_raw_status"] = roleStatus.rawValue
        record["fresh_role_type_id"] = raw.map { Int(CFGetTypeID($0)) as Any } ?? NSNull()
        record["fresh_role_utf8_prefix"] = NSNull()
        if roleStatus == .success, let raw, CFGetTypeID(raw) == CFStringGetTypeID(), let role = raw as? String {
            record["fresh_role_utf8_prefix"] = String(decoding: role.utf8.prefix(128), as: UTF8.self)
        }
        return finish()
    }
    private func nodes(_ root: AXUIElement, _ deadline: TimeInterval,
                       queryContext: [String: Any] = [:], excludingDescendantsOf standardZoom: AXUIElement? = nil,
                       requestedIdentifier: String? = nil) throws -> [(AXUIElement, [AXUIElement], String?, String?, String?)] {
        var pending: [(AXUIElement, [AXUIElement], [Int], [[String: Any]], Int)] = [(root, [], [], [], 0)]
        var result: [(AXUIElement, [AXUIElement], String?, String?, String?)] = []
        lastNodes = []
        lastWalkContext = ["query": queryContext, "phase": "walk-start"]
        while let (element, ancestors, path, cachedAncestors, sheetAncestorCount) = pending.popLast() {
            try check(deadline)
            guard !result.contains(where: { CFEqual($0.0, element) }) else { continue }
            guard result.count < 2_048, ancestors.count <= 48 else { throw RuneWorkspaceVisibilityFailure("Naming AX exceeded its node/depth bounds.") }
            lastWalkContext = ["query": queryContext, "phase": "query-scalars",
                "node_ordinal": result.count + 1, "completed_nodes": result.count, "depth": ancestors.count,
                "copied_child_index_path": path, "pending_nodes": pending.count,
                "cached_ancestors_last4": cachedAncestors, "ancestor_prefix_omitted": ancestors.count > 4,
                "cached_parent": cachedAncestors.last.map { $0 as Any } ?? NSNull(),
                "successful_cached_AXSheet_ancestor_count": sheetAncestorCount,
                "successful_cached_AXSheet_ancestor_present": sheetAncestorCount > 0,
                "metadata_scalar_utf8_input_prefix_limit": 256, "node_limit": 2_048, "depth_limit": 48]
            let identifier: String?, role: String?, title: String?
            do {
                identifier = try string(element, kAXIdentifierAttribute, deadline)
                role = try string(element, kAXRoleAttribute, deadline)
                title = try string(element, kAXTitleAttribute, deadline)
            } catch {
                let originalScalarRead = lastRead
                defer { lastRead = originalScalarRead }
                lastWalkContext["failure_only_standard_window_references"] = failureOnlyRootStandardReferences(
                    root: root, ancestors: ancestors, path: path, originalScalarRead: originalScalarRead)
                lastWalkContext["failure_only_held_child_role"] = failureOnlyHeldChildRole(element)
                lastWalkContext["failure_only_fresh_parent_membership"] = failureOnlyFreshParentMembership(
                    element, ancestors: ancestors, originalDeadline: deadline)
                throw error
            }
            result.append((element, ancestors, identifier, role, title))
            if lastNodes.count < 64 {
                lastNodes.append(["identifier": identifier.map { $0 as Any } ?? NSNull(), "role": role.map { $0 as Any } ?? NSNull(),
                                  "title": title.map { $0 as Any } ?? NSNull(), "depth": ancestors.count])
            }
            lastWalkContext["phase"] = "query-children"
            var currentMetadata = diagnosticNodeMetadata(identifier, role, title)
            currentMetadata["cached"] = true
            lastWalkContext["current_node"] = currentMetadata
            if let standardZoom, CFEqual(element, standardZoom) {
                guard role == kAXButtonRole, requestedIdentifier == nil || identifier != requestedIdentifier else {
                    throw RuneWorkspaceVisibilityFailure("Application-content scope cannot exclude a changed-role standard control or the requested Forge identifier.")
                }
                lastWalkContext["validated_standard_zoom_descendant_expansion_omitted"] = true
                continue
            }
            let nextCachedAncestors = Array((cachedAncestors + [currentMetadata]).suffix(4))
            let nextSheetAncestorCount = sheetAncestorCount + (role == kAXSheetRole ? 1 : 0)
            let next = try children(element, kAXChildrenAttribute, limit: 2_048 - result.count - pending.count, deadline)
            pending.append(contentsOf: next.enumerated().reversed().map {
                ($0.element, ancestors + [element], path + [$0.offset], nextCachedAncestors, nextSheetAncestorCount)
            })
        }
        lastWalkContext["phase"] = "walk-complete"
        lastWalkContext["completed_nodes"] = result.count
        return result
    }
    private func requireOwnedWindowAncestor(_ element: AXUIElement, root: AXUIElement,
                                           deadline: TimeInterval) throws {
        var cursor = element, seen: [AXUIElement] = []
        for _ in 0...48 {
            try prepare(cursor, deadline)
            guard !seen.contains(where: { CFEqual($0, cursor) }) else {
                throw RuneWorkspaceVisibilityFailure("Application-content standard-control ancestry repeated an AX reference.")
            }
            seen.append(cursor)
            if CFEqual(cursor, root) { return }
            guard let raw = try attribute(cursor, kAXParentAttribute, deadline),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw RuneWorkspaceVisibilityFailure("Application-content standard control lacks a typed parent reaching its exact owned window.")
            }
            cursor = raw as! AXUIElement
        }
        throw RuneWorkspaceVisibilityFailure("Application-content standard-control ancestry exceeded 48 levels.")
    }

    private func windowNodes(_ root: AXUIElement, _ deadline: TimeInterval,
                             scope: RuneWorkspaceWindowIdentifierScope = .wholeWindow,
                             requestedIdentifier: String? = nil, requestedTarget: AXUIElement? = nil,
                             queryContext: [String: Any] = [:]) throws -> [(AXUIElement, [AXUIElement], String?, String?, String?)] {
        guard scope == .applicationContent else { return try nodes(root, deadline, queryContext: queryContext) }
        var query = queryContext
        query["window_membership_scope"] = "application-content-excluding-validated-standard-zoom-descendants"
        lastApplicationContentWindowScope = ["classification": "Fresh public owned-window standard reference validation; only its descendant expansion may be excluded",
            "scope": "application-content-excluding-validated-standard-zoom-descendants", "complete_scoped_walk": false,
            "requested_identifier_prefix": requestedIdentifier.map { String(decoding: $0.utf8.prefix(512), as: UTF8.self) as Any } ?? NSNull(),
            "target_reference_supplied": requestedTarget != nil, "standard_zoom_reference_validated": false,
            "standard_zoom_descendant_expansion_omitted": false, "full_screen_reference_matches_zoom": NSNull()]
        lastWalkContext = ["query": query, "phase": "application-content-standard-zoom-validation"]
        try prepare(root, deadline)
        guard let rawZoom = try attribute(root, kAXZoomButtonAttribute, deadline),
              CFGetTypeID(rawZoom) == AXUIElementGetTypeID() else {
            throw RuneWorkspaceVisibilityFailure("Application-content scope requires the exact owned window's public Zoom reference.")
        }
        let zoom = rawZoom as! AXUIElement
        try prepare(zoom, deadline)
        try requireOwnedWindowAncestor(zoom, root: root, deadline: deadline)
        let role = try string(zoom, kAXRoleAttribute, deadline)
        let subrole = try string(zoom, kAXSubroleAttribute, deadline)
        lastApplicationContentWindowScope["standard_zoom_role"] = role.map { String($0.prefix(256)) as Any } ?? NSNull()
        lastApplicationContentWindowScope["standard_zoom_subrole"] = subrole.map { String($0.prefix(256)) as Any } ?? NSNull()
        guard role == kAXButtonRole, let subrole,
              subrole == kAXZoomButtonSubrole || subrole == kAXFullScreenButtonSubrole else {
            throw RuneWorkspaceVisibilityFailure("Application-content scope requires an owned AXButton with a recognized standard Zoom/Full Screen subrole.")
        }
        if subrole == kAXFullScreenButtonSubrole {
            guard let rawFullScreen = try attribute(root, kAXFullScreenButtonAttribute, deadline),
                  CFGetTypeID(rawFullScreen) == AXUIElementGetTypeID() else {
                throw RuneWorkspaceVisibilityFailure("The standard Full Screen subrole lacks its exact owned window public reference.")
            }
            let fullScreen = rawFullScreen as! AXUIElement
            try prepare(fullScreen, deadline)
            try requireOwnedWindowAncestor(fullScreen, root: root, deadline: deadline)
            let sameReference = CFEqual(fullScreen, zoom)
            lastApplicationContentWindowScope["full_screen_reference_matches_zoom"] = sameReference
            guard sameReference else {
                throw RuneWorkspaceVisibilityFailure("The owned window Full Screen reference differs from its exact Zoom reference.")
            }
        }
        let identifier = try string(zoom, kAXIdentifierAttribute, deadline)
        lastApplicationContentWindowScope["standard_zoom_identifier_prefix"] = identifier.map { String(decoding: $0.utf8.prefix(256), as: UTF8.self) as Any } ?? NSNull()
        guard (requestedIdentifier == nil || identifier != requestedIdentifier),
              requestedTarget.map({ !CFEqual($0, zoom) }) ?? true else {
            throw RuneWorkspaceVisibilityFailure("Application-content scope cannot exclude the requested Forge identifier or exact target.")
        }
        lastApplicationContentWindowScope["standard_zoom_reference_validated"] = true
        let tree = try nodes(root, deadline, queryContext: query, excludingDescendantsOf: zoom,
                             requestedIdentifier: requestedIdentifier)
        lastApplicationContentWindowScope["complete_scoped_walk"] = true
        lastApplicationContentWindowScope["complete_scoped_walk_nodes"] = tree.count
        lastApplicationContentWindowScope["standard_zoom_descendant_expansion_omitted"] = tree.contains { CFEqual($0.0, zoom) }
        return tree
    }

    private func requiredNativeBoundarySnapshot(_ queryDeadline: TimeInterval) -> [String: Any] {
        let observed = ProcessInfo.processInfo.systemUptime, readDeadline = observed + 0.02
        var state: [String: Any] = ["classification": "Current-process scalars at required method boundary only; not evaluated AX failure values, query result or cause",
            "snapshot_uptime": observed, "query_deadline": queryDeadline, "cached_query_owner_pid": pid,
            "read_budget_seconds": 0.02, "process_trusted": NSNull(), "trust_read_attempted": false,
            "run_loop_mode_prefix": NSNull(), "mode_read_attempted": false]
        if ProcessInfo.processInfo.systemUptime < readDeadline {
            state["trust_read_attempted"] = true
            state["process_trusted"] = AXIsProcessTrusted()
        }
        if ProcessInfo.processInfo.systemUptime < readDeadline {
            state["mode_read_attempted"] = true
            state["run_loop_mode_prefix"] = RunLoop.current.currentMode.map { String($0.rawValue.prefix(128)) as Any } ?? NSNull()
        }
        let finished = ProcessInfo.processInfo.systemUptime
        state["snapshot_elapsed_seconds"] = finished - observed
        state["read_budget_expired"] = finished >= readDeadline
        return state
    }
    func required(identifier: String, inSheet: Bool = false,
                  scope: RuneWorkspaceWindowIdentifierScope = .wholeWindow) async throws -> AXUIElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var attempt = 0
        let nativeBeforeQuery = requiredNativeBoundarySnapshot(deadline)
        defer {
            lastRequiredWalkContext = lastWalkContext
            lastRequiredWalkContext["last_scalar_read"] = lastRead
            lastRequiredWalkContext["native_before_first_query"] = nativeBeforeQuery
            lastRequiredWalkContext["native_after_required_return_or_throw"] = requiredNativeBoundarySnapshot(deadline)
        }
        repeat {
            attempt += 1
            let query: [String: Any] = ["requested_identifier_prefix": String(decoding: identifier.utf8.prefix(512), as: UTF8.self),
                "requested_identifier_prefix_capped": identifier.utf8.count > 512, "in_sheet": inSheet, "attempt": attempt]
            lastWalkContext = ["query": query, "phase": "owned-window"]
            let main = try ownedWindow(deadline)
            let tree = try windowNodes(main, deadline, scope: scope, requestedIdentifier: identifier, queryContext: query)
            let sheets = tree.filter { $0.3 == kAXSheetRole }.map { $0.0 }
            let matches = tree.filter { node in
                node.2 == identifier && (!inSheet || node.1.contains(where: { ancestor in
                    sheets.contains(where: { CFEqual($0, ancestor) })
                }))
            }
            guard matches.count <= 1 else { throw RuneWorkspaceVisibilityFailure("Naming AX exported duplicate exact identifiers: \(identifier).") }
            if let match = matches.first { return match.0 }
            try check(deadline); try await Task.sleep(for: .milliseconds(10))
        } while true
    }


    func selectOwnedFeedRow(identifier: String, witness: inout [String: Any]) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        witness = ["classification": "Actual public AXSelected setter on the exact observed Feed row; no AXPress fallback",
            "requested_identifier": identifier, "setter_requested": false, "setter_returned": false]
        @MainActor func requireNativeOwner() throws {
            try check(deadline)
            guard let window, let hosting, window.contentView === hosting, hosting.window === window,
                  window.isVisible, window.isKeyWindow, NSApp.keyWindow === window, NSApp.isActive,
                  window.attachedSheet == nil, !hosting.isHiddenOrHasHiddenAncestor else {
                throw RuneWorkspaceVisibilityFailure("Feed selection lost its exact active native window/host.")
            }
        }
        try requireNativeOwner()
        let main = try ownedWindow(deadline)
        @MainActor func exactRow(_ tree: [(AXUIElement, [AXUIElement], String?, String?, String?)]) throws
            -> (target: AXUIElement, cell: AXUIElement, row: AXUIElement, outline: AXUIElement) {
            let matches = tree.filter { $0.2 == identifier }
            guard matches.count == 1, let target = matches.first, target.3 == kAXStaticTextRole,
                  target.1.count >= 3, target.1.contains(where: { CFEqual($0, main) }),
                  let cell = tree.first(where: { CFEqual($0.0, target.1[target.1.count - 1]) }),
                  let row = tree.first(where: { CFEqual($0.0, target.1[target.1.count - 2]) }),
                  let outline = tree.first(where: { CFEqual($0.0, target.1[target.1.count - 3]) }),
                  cell.3 == kAXCellRole, row.3 == kAXRowRole, outline.3 == kAXOutlineRole,
                  cell.1.last.map({ CFEqual($0, row.0) }) == true,
                  row.1.last.map({ CFEqual($0, outline.0) }) == true else {
                throw RuneWorkspaceVisibilityFailure("Feed selection requires its unique observed StaticText/Cell/Row/Outline owned ancestry.")
            }
            return (target.0, cell.0, row.0, outline.0)
        }
        let tree = try windowNodes(main, deadline, scope: .applicationContent, requestedIdentifier: identifier)
        let (target, cell, row, outline) = try exactRow(tree)
        witness["cached_target_identifier"] = identifier; witness["cached_target_role"] = kAXStaticTextRole
        witness["cached_row_role"] = kAXRowRole; witness["cached_outline_role"] = kAXOutlineRole
        for element in [target, cell, row, outline] { try prepare(element, deadline) }
        guard try string(target, kAXIdentifierAttribute, deadline) == identifier,
              try string(target, kAXRoleAttribute, deadline) == kAXStaticTextRole,
              try string(cell, kAXRoleAttribute, deadline) == kAXCellRole,
              try string(row, kAXRoleAttribute, deadline) == kAXRowRole,
              try string(outline, kAXRoleAttribute, deadline) == kAXOutlineRole else {
            throw RuneWorkspaceVisibilityFailure("Feed selection's observed public roles or exact identifier changed.")
        }
        try prepare(row, deadline)
        var names: CFArray?
        let advertisedStatus = AXUIElementCopyAttributeNames(row, &names)
        witness["advertised_status"] = advertisedStatus.rawValue
        try check(deadline)
        guard advertisedStatus == .success, let advertised = names as? [String], advertised.count <= 256,
              advertised.allSatisfy({ $0.utf8.count <= 512 }), advertised.contains(kAXSelectedAttribute) else {
            throw RuneWorkspaceVisibilityFailure("The exact Feed row no longer advertises bounded AXSelected.")
        }
        witness["selected_advertised"] = true
        let value = try attribute(row, kAXSelectedAttribute, deadline)
        witness["selected_before_status"] = lastRead["actual_status"]
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID(),
              let selected = value as? NSNumber, !selected.boolValue else {
            throw RuneWorkspaceVisibilityFailure("The exact Feed row must have a typed false selection before the action.")
        }
        witness["selected_before"] = false
        try prepare(row, deadline)
        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(row, kAXSelectedAttribute as CFString, &settable)
        witness["settable_status"] = settableStatus.rawValue; witness["settable"] = settableStatus == .success ? settable.boolValue as Any : NSNull()
        try check(deadline)
        guard settableStatus == .success, settable.boolValue else {
            throw RuneWorkspaceVisibilityFailure("The exact Feed row AXSelected is not successfully settable.")
        }
        try requireNativeOwner()
        guard CFEqual(try ownedWindow(deadline), main) else {
            throw RuneWorkspaceVisibilityFailure("Feed selection changed the exact exported window before its action.")
        }
        try prepare(row, deadline)
        witness["setter_requested"] = true
        let status = AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        witness["setter_status"] = status.rawValue
        try check(deadline)
        guard status == .success else { throw RuneWorkspaceVisibilityFailure("Feed AXSelected setter failed: \(status.rawValue).") }
        witness["setter_returned"] = true
        try requireNativeOwner()
        guard CFEqual(try ownedWindow(deadline), main) else {
            throw RuneWorkspaceVisibilityFailure("Feed selection changed the exact exported window after its action.")
        }
        let afterTree = try windowNodes(main, deadline, scope: .applicationContent, requestedIdentifier: identifier)
        let current = try exactRow(afterTree)
        let afterValue = try attribute(current.row, kAXSelectedAttribute, deadline)
        witness["selected_after_status"] = lastRead["actual_status"]
        guard let afterValue, CFGetTypeID(afterValue) == CFBooleanGetTypeID(),
              let afterSelected = afterValue as? NSNumber, afterSelected.boolValue else {
            throw RuneWorkspaceVisibilityFailure("The fresh exact Feed row did not expose typed true selection after its setter.")
        }
        witness["selected_after"] = true
        witness["post_read_scope"] = "Fresh complete same-root graph; no old/new row reference identity assumption"
        try requireNativeOwner()
        guard CFEqual(try ownedWindow(deadline), main) else {
            throw RuneWorkspaceVisibilityFailure("Feed selection changed its exported window during the fresh post-read.")
        }
        witness["post_window_same_reference"] = true
        try check(deadline)
    }

    func observeOwnedFeedSelectionCapability(identifier: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        lastRouteSelectionCapability = ["classification": "Own public Feed target/cached-ancestor capability probe; no selection action or geometry proof",
            "requested_identifier": identifier, "probe_complete": false, "candidate_limit": 3]
        let main = try ownedWindow(deadline)
        let tree = try windowNodes(main, deadline, scope: .applicationContent, requestedIdentifier: identifier)
        let matches = tree.filter { $0.2 == identifier }
        guard matches.count == 1, let match = matches.first else {
            throw RuneWorkspaceVisibilityFailure("Feed capability probe requires exactly one literal target.")
        }
        let lineage = [match] + match.1.reversed().compactMap { held in tree.first { CFEqual($0.0, held) } }
        let row = lineage.first { $0.3 == kAXRowRole }
        let container = lineage.first { $0.3 == kAXTableRole || $0.3 == kAXOutlineRole }
        let candidates = [Optional(match), row, container].compactMap { $0 }
        var records: [[String: Any]] = [], seen: [AXUIElement] = []
        defer {
            lastRouteSelectionCapability["candidates"] = records
            lastRouteSelectionCapability["cached_ancestor_roles_nearest8"] = Array(lineage.prefix(8)).map {
                $0.3.map { String($0.prefix(128)) as Any } ?? NSNull()
            }
            lastRouteSelectionCapability["last_scalar_read"] = lastRead
        }
        for candidate in candidates where !seen.contains(where: { CFEqual($0, candidate.0) }) {
            seen.append(candidate.0)
            guard seen.count <= 3, CFEqual(candidate.0, main) || candidate.1.contains(where: { CFEqual($0, main) }) else {
                throw RuneWorkspaceVisibilityFailure("Feed capability candidate left its cached exact owned ancestry.")
            }
            try prepare(candidate.0, deadline)
            var names: CFArray?
            let copied = AXUIElementCopyAttributeNames(candidate.0, &names)
            try check(deadline)
            guard copied == .success, let advertised = names as? [String], advertised.count <= 256,
                  advertised.allSatisfy({ $0.utf8.count <= 512 }) else {
                throw RuneWorkspaceVisibilityFailure("Feed attribute advertisement failed or exceeded its bound: \(copied.rawValue).")
            }
            var record = diagnosticNodeMetadata(candidate.2, candidate.3, candidate.4)
            record["advertised_selection_attributes"] = advertised.filter { $0 == kAXSelectedAttribute || $0 == kAXSelectedRowsAttribute }
            records.append(record)
            for attributeName in [kAXSelectedAttribute, kAXSelectedRowsAttribute] where advertised.contains(attributeName) {
                try prepare(candidate.0, deadline)
                var settable: DarwinBoolean = false
                let status = AXUIElementIsAttributeSettable(candidate.0, attributeName as CFString, &settable)
                try check(deadline)
                records[records.count - 1][attributeName + "_settable_status"] = status.rawValue
                records[records.count - 1][attributeName + "_settable"] = status == .success ? settable.boolValue as Any : NSNull()
                guard status == .success || status == .attributeUnsupported || status == .noValue else {
                    throw RuneWorkspaceVisibilityFailure("Feed selection settable query failed: \(status.rawValue).")
                }
                if attributeName == kAXSelectedAttribute {
                    let selected = try attribute(candidate.0, attributeName, deadline)
                    records[records.count - 1]["selected_raw_status"] = lastRead["actual_status"]
                    records[records.count - 1]["selected_value"] = (selected as? NSNumber).map { $0.boolValue as Any } ?? NSNull()
                } else {
                    try prepare(candidate.0, deadline)
                    var count = 0
                    let counted = AXUIElementGetAttributeValueCount(candidate.0, attributeName as CFString, &count)
                    try check(deadline)
                    records[records.count - 1]["selected_rows_count_status"] = counted.rawValue
                    records[records.count - 1]["selected_rows_count"] = counted == .success ? count as Any : NSNull()
                    guard (counted == .success && count >= 0 && count <= 2_048)
                        || counted == .attributeUnsupported || counted == .noValue else {
                        throw RuneWorkspaceVisibilityFailure("Feed selected-row count failed or exceeded its bound: \(counted.rawValue).")
                    }
                }
            }
        }
        guard CFEqual(try ownedWindow(deadline), main) else {
            throw RuneWorkspaceVisibilityFailure("Feed probe changed its exact exported window reference.")
        }
        lastRouteSelectionCapability["probe_complete"] = true
    }

    func requireOwnedSheetAncestor(_ element: AXUIElement) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard window?.attachedSheet != nil else { throw RuneWorkspaceVisibilityFailure("The production naming sheet is not attached.") }
        let main = try ownedWindow(deadline)
        let tree = try nodes(main, deadline)
        guard let node = tree.first(where: { CFEqual($0.0, element) }),
              let sheet = tree.first(where: { candidate in candidate.3 == kAXSheetRole && node.1.contains(where: { CFEqual($0, candidate.0) }) }) else {
            throw RuneWorkspaceVisibilityFailure("The exact Save element does not belong to the owned sheet graph.")
        }
        guard let relationship = try attribute(sheet.0, kAXWindowAttribute, deadline), CFGetTypeID(relationship) == AXUIElementGetTypeID(),
              CFEqual(relationship, main) else { throw RuneWorkspaceVisibilityFailure("The public sheet AXWindow relationship is not the exact originating native window.") }
    }
    private func perform(_ element: AXUIElement, action: String, roles: [String], _ deadline: TimeInterval,
                         recordStatus: ((String, Int32) -> Void)? = nil) throws {
        guard let role = try string(element, kAXRoleAttribute, deadline), roles.contains(role),
              let enabled = try attribute(element, kAXEnabledAttribute, deadline) as? NSNumber, enabled.boolValue else { throw RuneWorkspaceVisibilityFailure("The actual naming action is not enabled with the expected public role.") }
        try prepare(element, deadline)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        guard status == .success, let actions = names as? [String], actions.count <= 64, actions.contains(action) else { throw RuneWorkspaceVisibilityFailure("The actual naming action was not advertised: \(status.rawValue), \(action).") }
        let pressed = AXUIElementPerformAction(element, action as CFString)
        recordStatus?(action, pressed.rawValue)
        try check(deadline)
        guard pressed == .success else { throw RuneWorkspaceVisibilityFailure("The actual naming action failed: \(pressed.rawValue), \(action).") }
    }
    func pressOwned(_ element: AXUIElement, role: String, scope: RuneWorkspaceWindowIdentifierScope = .wholeWindow) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let main = try ownedWindow(deadline)
        guard try windowNodes(main, deadline, scope: scope, requestedTarget: element).contains(where: { CFEqual($0.0, element) }) else { throw RuneWorkspaceVisibilityFailure("The exact naming control left the owned window graph.") }
        try perform(element, action: kAXPressAction, roles: [role], deadline)
    }

    func pressRetainedSheetSave(_ element: AXUIElement, sheet: NSWindow, content: NSView,
                               witness: inout [String: Any]) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        func requireNativeOwner() throws {
            try check(deadline)
            guard let window, let hosting, window.contentView === hosting, hosting.window === window,
                  window.isVisible, !hosting.isHiddenOrHasHiddenAncestor,
                  window.attachedSheet === sheet, sheet.sheetParent === window,
                  window.sheets.count == 1, window.sheets.first === sheet, sheet.sheets.isEmpty,
                  sheet.contentView === content, content.window === sheet, sheet.isVisible,
                  !content.isHiddenOrHasHiddenAncestor else {
                throw RuneWorkspaceVisibilityFailure("Exported Save lost its exact sole native attached sheet/content/window.")
            }
        }
        try requireNativeOwner()
        let main = try ownedWindow(deadline)
        let tree = try nodes(main, deadline)
        let sheets = tree.filter { $0.3 == kAXSheetRole }
        let saves = tree.filter { $0.2 == "workspace-save-layout" }
        guard sheets.count == 1, saves.count == 1, let save = saves.first, let exportedSheet = sheets.first,
              CFEqual(save.0, element), save.3 == kAXButtonRole,
              save.1.contains(where: { CFEqual($0, exportedSheet.0) }) else {
            throw RuneWorkspaceVisibilityFailure("Exported Save requires one exact identifier inside one owned AXSheet.")
        }
        guard let parent = try attribute(exportedSheet.0, kAXWindowAttribute, deadline),
              CFGetTypeID(parent) == AXUIElementGetTypeID(), CFEqual(parent, main) else {
            throw RuneWorkspaceVisibilityFailure("The sole exported sheet does not belong to its exact native parent window.")
        }
        try requireNativeOwner()
        guard CFEqual(try ownedWindow(deadline), main) else {
            throw RuneWorkspaceVisibilityFailure("Exported Save changed its exact parent window before dispatch.")
        }
        try requireNativeOwner()
        witness["exact_retained_native_sheet_and_content"] = true
        witness["unique_owned_AXSheet_and_Save_identifier"] = true
        witness["Save_CFEqual_held_target"] = true
        witness["Save_AXWindow_is_exact_parent"] = true
        witness["complete_owned_identifier_walk_nodes"] = tree.count
        witness["Save_action"] = kAXPressAction
        var returnedStatus: Int32?
        defer {
            witness["actual_Save_action_returned"] = returnedStatus != nil
            witness["actual_Save_action_status"] = returnedStatus.map { $0 as Any } ?? NSNull()
        }
        witness["actual_Save_action_requested"] = true
        try perform(element, action: kAXPressAction, roles: [kAXButtonRole], deadline,
                    recordStatus: { _, status in returnedStatus = status })
    }

    // Separate explicit sheet scope; original whole-window discovery and action routes remain unchanged.
    private func exactAttachedSheetSaveGraph(sheet: NSWindow, content: NSView, field: NSTextField,
        expectedName: String, deadline: TimeInterval)
        throws -> (window: AXUIElement, sheet: AXUIElement, save: AXUIElement, nodes: Int, firstOrderChildren: Int) {
        func requireNativeOwner() throws {
            try check(deadline)
            guard let window, let hosting, window.contentView === hosting, hosting.window === window,
                  window.isVisible, !hosting.isHiddenOrHasHiddenAncestor,
                  window.attachedSheet === sheet, sheet.sheetParent === window,
                  window.sheets.count == 1, window.sheets.first === sheet, sheet.sheets.isEmpty,
                  sheet.contentView === content, content.window === sheet, sheet.isVisible,
                  !content.isHiddenOrHasHiddenAncestor, field.window === sheet, field.isDescendant(of: content),
                  field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
                  expectedName.utf8.count <= NativeWorkspaceLimits.maximumNameBytes, field.stringValue == expectedName else {
                throw RuneWorkspaceVisibilityFailure("Sheet-scoped Save lost its exact sole native sheet/content/field/window or edited value.")
            }
        }
        let query: [String: Any] = ["requested_identifier_prefix": "workspace-save-layout", "in_sheet": true,
            "scope": "sole-first-order-owned-AXSheet-subtree", "parent_window_descendants_expanded": false]
        lastWalkContext = ["query": query, "phase": "sheet-native-owner"]
        try requireNativeOwner()
        let main = try ownedWindow(deadline)
        lastWalkContext["phase"] = "first-order-sheet-discovery"
        let firstOrder = try children(main, kAXChildrenAttribute, limit: 32, deadline)
        var held: [AXUIElement] = [], sheets: [AXUIElement] = []
        for candidate in firstOrder {
            try requireNativeOwner()
            guard !held.contains(where: { CFEqual($0, candidate) }),
                  let role = try string(candidate, kAXRoleAttribute, deadline) else {
                throw RuneWorkspaceVisibilityFailure("Sheet scope requires unique first-order child references with readable public roles.")
            }
            held.append(candidate)
            if role == kAXSheetRole { sheets.append(candidate) }
        }
        guard sheets.count == 1, let exportedSheet = sheets.first else {
            throw RuneWorkspaceVisibilityFailure("Sheet scope requires exactly one first-order AXSheet of the owned window.")
        }
        for relationship in [kAXParentAttribute, kAXWindowAttribute] {
            guard let raw = try attribute(exportedSheet, relationship, deadline),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw RuneWorkspaceVisibilityFailure("The sole exported sheet lacks its typed public parent/window relationship.")
            }
            let parent = raw as! AXUIElement
            try prepare(parent, deadline)
            guard CFEqual(parent, main) else {
                throw RuneWorkspaceVisibilityFailure("The sole exported sheet's parent/window is not the exact owned root.")
            }
        }
        try requireNativeOwner()
        let tree = try nodes(exportedSheet, deadline, queryContext: query)
        let nestedSheets = tree.filter { $0.3 == kAXSheetRole }
        let saves = tree.filter { $0.2 == "workspace-save-layout" }
        guard nestedSheets.count == 1, let onlySheet = nestedSheets.first, CFEqual(onlySheet.0, exportedSheet),
              saves.count == 1, let save = saves.first, save.3 == kAXButtonRole,
              save.1.contains(where: { CFEqual($0, exportedSheet) }) else {
            throw RuneWorkspaceVisibilityFailure("The complete sole-sheet identifier walk requires one exact Save button and no nested sheet.")
        }
        guard let rawWindow = try attribute(save.0, kAXWindowAttribute, deadline),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            throw RuneWorkspaceVisibilityFailure("The scoped Save lacks its typed public owning-window relationship.")
        }
        let saveWindow = rawWindow as! AXUIElement
        try prepare(saveWindow, deadline)
        guard CFEqual(saveWindow, main), CFEqual(try ownedWindow(deadline), main) else {
            throw RuneWorkspaceVisibilityFailure("The scoped Save left its exact parent-window identity.")
        }
        try requireNativeOwner()
        return (main, exportedSheet, save.0, tree.count, firstOrder.count)
    }

    func requiredExactAttachedSheetSave(sheet: NSWindow, content: NSView, field: NSTextField,
        expectedName: String) throws -> AXUIElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        defer { lastRequiredWalkContext = lastWalkContext; lastRequiredWalkContext["last_scalar_read"] = lastRead }
        return try exactAttachedSheetSaveGraph(sheet: sheet, content: content, field: field,
            expectedName: expectedName, deadline: deadline).save
    }

    func pressRetainedExactAttachedSheetSave(_ element: AXUIElement, sheet: NSWindow, content: NSView,
        field: NSTextField, expectedName: String, witness: inout [String: Any]) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        defer {
            lastRequiredWalkContext = lastWalkContext
            lastRequiredWalkContext["operation"] = "fresh-retained-exact-attached-sheet-Save-action-revalidation"
            lastRequiredWalkContext["last_scalar_read"] = lastRead
        }
        let graph = try exactAttachedSheetSaveGraph(sheet: sheet, content: content, field: field,
            expectedName: expectedName, deadline: deadline)
        guard CFEqual(graph.save, element), try string(element, kAXIdentifierAttribute, deadline) == "workspace-save-layout" else {
            throw RuneWorkspaceVisibilityFailure("The freshly scoped Save differs from its exact retained target/identifier.")
        }
        guard let window, let hosting, window.contentView === hosting, hosting.window === window,
              window.isVisible, !hosting.isHiddenOrHasHiddenAncestor,
              window.attachedSheet === sheet, sheet.sheetParent === window,
              window.sheets.count == 1, window.sheets.first === sheet, sheet.sheets.isEmpty,
              sheet.contentView === content, content.window === sheet, sheet.isVisible,
              !content.isHiddenOrHasHiddenAncestor, field.window === sheet, field.isDescendant(of: content),
              field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
              field.stringValue == expectedName, ProcessInfo.processInfo.systemUptime < deadline else {
            throw RuneWorkspaceVisibilityFailure("Sheet-scoped Save lost its retained native owner immediately before dispatch.")
        }
        witness["identifier_scope"] = "sole-first-order-owned-AXSheet-subtree"
        witness["parent_window_descendants_expanded_for_Save"] = false
        witness["exact_retained_native_sheet_content_and_field"] = true
        witness["sole_first_order_exported_sheet_parent_and_window_match_owned_root"] = true
        witness["native_to_exported_sheet_correspondence"] = "Inferred from simultaneous sole native/exported sheets under the same exact parent; no public direct object conversion claimed"
        witness["unique_owned_AXSheet_and_Save_identifier"] = true
        witness["Save_CFEqual_held_target"] = true
        witness["Save_AXWindow_is_exact_parent"] = true
        witness["complete_sheet_identifier_walk_nodes"] = graph.nodes
        witness["first_order_owned_window_child_count"] = graph.firstOrderChildren
        witness["Save_action"] = kAXPressAction
        var returnedStatus: Int32?
        defer {
            witness["actual_Save_action_returned"] = returnedStatus != nil
            witness["actual_Save_action_status"] = returnedStatus.map { $0 as Any } ?? NSNull()
        }
        witness["actual_Save_action_requested"] = true
        try perform(element, action: kAXPressAction, roles: [kAXButtonRole], deadline,
                    recordStatus: { _, status in returnedStatus = status })
    }

    func openOwnedMenuAndPressNativeRename(_ opener: AXUIElement, capture: RuneWorkspaceNativeNamingMenuCapture) async throws {
        guard capture.requestedCommand == "Rename Layout…" else { throw RuneWorkspaceVisibilityFailure("The original native Rename route requires its literal Rename command.") }
        try await openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture)
    }

    func openOwnedMenuAndPressNativeNamingCommand(_ opener: AXUIElement, capture: RuneWorkspaceNativeNamingMenuCapture,
                                                 scope: RuneWorkspaceWindowIdentifierScope = .wholeWindow) async throws {
        try capture.startAttempt()
        let deadline = capture.deadline
        let expectedWindow = try ownedWindow(deadline)
        guard try windowNodes(expectedWindow, deadline, scope: scope, requestedTarget: opener).contains(where: { CFEqual($0.0, opener) }) else {
            throw RuneWorkspaceVisibilityFailure("The independent native menu route lost its exact owned opener before arming.")
        }
        NotificationCenter.default.addObserver(capture, selector: #selector(RuneWorkspaceNativeNamingMenuCapture.didBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.02, target: capture, selector: #selector(RuneWorkspaceNativeNamingMenuCapture.fire(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate(); capture.stop() }
        capture.armed = true
        try openOwnedMenu(opener, deadline: deadline, scope: scope) { action, status in capture.noteOpener(action: action, status: status) }
        while !capture.isFinished {
            try check(deadline); try await Task.sleep(for: .milliseconds(10))
        }
        guard let result = capture.result else { throw RuneWorkspaceVisibilityFailure("The independent native menu route produced no actual dispatch result.") }
        try result.get()
        guard CFEqual(try ownedWindow(deadline), expectedWindow) else { throw RuneWorkspaceVisibilityFailure("The independent native menu route changed its exact originating window.") }
    }

    func openOwnedMenuAndPressRename(_ opener: AXUIElement) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let selection = RuneWorkspaceNamingMenuSelection(window: try ownedWindow(deadline),
            opener: opener, deadline: deadline, observer: self)
        let timer = Timer(timeInterval: 0.02, target: selection,
            selector: #selector(RuneWorkspaceNamingMenuSelection.fire(_:)), userInfo: nil, repeats: true)
        // Register before opening: the sampled native menu runs eventTracking
        // while the async test's ordinary continuation is suspended.
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate(); recordMenuTransition(selection, timer: timer) }
        try openOwnedMenu(opener, deadline: deadline) { action, status in
            selection.openerAction = action; selection.openerStatus = status
        }
        while !selection.isFinished {
            try check(deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let result = selection.result else {
            throw RuneWorkspaceVisibilityFailure("The actual naming menu did not produce a completed selection result.")
        }
        try result.get()
        guard CFEqual(try ownedWindow(deadline), selection.ownedWindow) else {
            throw RuneWorkspaceVisibilityFailure("The menu transition changed the exact exported native window.")
        }
    }

    fileprivate func menuTimerDidFire(_ selection: RuneWorkspaceNamingMenuSelection, timer: Timer) {
        guard !selection.isFinished else { timer.invalidate(); return }
        guard !selection.querying else { return }
        selection.querying = true
        selection.ticks += 1
        selection.callbackMode = RunLoop.main.currentMode?.rawValue
        defer { selection.querying = false }
        do {
            try check(selection.deadline)
            guard selection.ticks <= 160 else {
                throw RuneWorkspaceVisibilityFailure("The naming menu exceeded its finite timer callback bound.")
            }
            if try pressRenameItemIfPresent(inMenuOf: selection.opener, ownedWindow: selection.ownedWindow,
                deadline: selection.deadline, recordStatus: { action, status in
                    selection.renameAction = action; selection.renameStatus = status
                }) {
                selection.result = .success(())
                timer.invalidate()
            } else if !selection.diagnosticFailed, [1, 25].contains(selection.ticks) {
                captureMenuRelationshipDiagnostic(selection)
            }
        } catch {
            selection.callbackError = String(String(describing: error).prefix(4_096))
            selection.result = .failure(error)
            timer.invalidate()
        }
        recordMenuTransition(selection, timer: timer)
    }

    private func recordMenuTransition(_ selection: RuneWorkspaceNamingMenuSelection, timer: Timer) {
        lastMenuTransition = [
            "mechanism": "Public main RunLoop Timer registered in eventTracking/default modes before actual opener action",
            "interval_seconds": 0.02, "absolute_deadline_seconds": 3,
            "callback_count": selection.ticks, "callback_limit": 160,
            "last_callback_mode": selection.callbackMode.map { $0 as Any } ?? NSNull(),
            "actual_opener_action": selection.openerAction.map { $0 as Any } ?? NSNull(),
            "actual_opener_status": selection.openerStatus.map { $0 as Any } ?? NSNull(),
            "actual_rename_action": selection.renameAction.map { $0 as Any } ?? NSNull(),
            "actual_rename_status": selection.renameStatus.map { $0 as Any } ?? NSNull(),
            "callback_error": selection.callbackError.map { $0 as Any } ?? NSNull(),
            "relationship_diagnostics": selection.relationshipDiagnostics,
            "timer_valid": timer.isValid, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - selection.started,
        ]
    }

    // These finite measurements do not qualify another menu as the opener's menu.
    // The original shown-menu selector and error remain the assertion boundary.
    private func captureMenuRelationshipDiagnostic(_ selection: RuneWorkspaceNamingMenuSelection) {
        let originalRead = lastRead, originalNodes = lastNodes
        defer { lastRead = originalRead; lastNodes = originalNodes }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = min(selection.deadline, started + 0.3)
        var report: [String: Any] = [
            "classification": "Diagnostic only; no action, ownership substitution, API retry, or assertion result",
            "timer_tick": selection.ticks, "runloop_mode": selection.callbackMode.map { $0 as Any } ?? NSNull(),
            "relative_started_seconds": started - selection.started, "query_deadline_seconds": 0.3,
            "node_limit_per_root": 64, "depth_limit": 8, "copied_child_prefix_limit": 64,
            "native_fixture_window_is_key": window.map { $0.isKeyWindow as Any } ?? NSNull(),
            "native_fixture_window_is_main": window.map { $0.isMainWindow as Any } ?? NSNull(),
            "native_key_window_is_fixture": window.map { (NSApp.keyWindow === $0) as Any } ?? NSNull(),
            "native_main_window_is_fixture": window.map { (NSApp.mainWindow === $0) as Any } ?? NSNull(),
        ]
        var openerRecords: [[String: Any]] = [], applicationRecords: [[String: Any]] = []
        let application = AXUIElementCreateApplication(pid)
        do {
            guard CFEqual(try ownedWindow(deadline), selection.ownedWindow) else {
                throw RuneWorkspaceVisibilityFailure("The diagnostic lost the exact exported naming window before observation.")
            }
            report["exact_window_unchanged_before"] = true
            try diagnosticMenuGraph(selection.opener, selection: selection, application: application,
                deadline: deadline, records: &openerRecords)
            try diagnosticMenuGraph(application, selection: selection, application: application,
                deadline: deadline, records: &applicationRecords)
            guard CFEqual(try ownedWindow(deadline), selection.ownedWindow) else {
                throw RuneWorkspaceVisibilityFailure("The diagnostic lost the exact exported naming window after observation.")
            }
            report["exact_window_unchanged_after"] = true
        } catch {
            // A diagnostic error is retained and prevents another diagnostic attempt;
            // it never substitutes a successful assertion or a new menu action.
            report["diagnostic_error"] = String(String(describing: error).prefix(4_096))
            selection.diagnosticFailed = true
        }
        report["opener_nodes"] = openerRecords; report["application_nodes"] = applicationRecords
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        if let bytes = try? JSONSerialization.data(withJSONObject: report), bytes.count > 128 * 1_024 {
            report["opener_nodes"] = Array(openerRecords.prefix(8))
            report["application_nodes"] = Array(applicationRecords.prefix(8))
            report["payload_capped_to_first8_per_root"] = true
            report["observed_opener_record_count"] = openerRecords.count
            report["observed_application_record_count"] = applicationRecords.count
            if let capped = try? JSONSerialization.data(withJSONObject: report), capped.count > 128 * 1_024 {
                report["opener_nodes"] = Array(openerRecords.prefix(1))
                report["application_nodes"] = Array(applicationRecords.prefix(1))
                report["payload_capped_to_first1_per_root"] = true
            }
        }
        if let bounded = try? JSONSerialization.data(withJSONObject: report), bounded.count > 128 * 1_024 {
            report["opener_nodes"] = []; report["application_nodes"] = []
            report["diagnostic_payload_error"] = "Raw nodes exceeded the final 128 KiB diagnostic ceiling; only counts/context are retained."
            report["observed_opener_record_count"] = openerRecords.count
            report["observed_application_record_count"] = applicationRecords.count
            selection.diagnosticFailed = true
        }
        selection.relationshipDiagnostics.append(report)
    }

    private func diagnosticMenuGraph(_ root: AXUIElement, selection: RuneWorkspaceNamingMenuSelection,
        application: AXUIElement, deadline: TimeInterval, records: inout [[String: Any]]) throws {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [AXUIElement] = []
        var index = 0
        while index < pending.count, visited.count < 64 {
            let (element, depth) = pending[index]; index += 1
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            var record: [String: Any] = ["depth": depth, "index": visited.count - 1]
            do {
                try prepare(element, deadline)
                let role = try diagnosticMenuScalar(element, key: kAXRoleAttribute, deadline: deadline, record: &record)
                _ = try diagnosticMenuScalar(element, key: kAXIdentifierAttribute, deadline: deadline, record: &record)
                _ = try diagnosticMenuScalar(element, key: kAXTitleAttribute, deadline: deadline, record: &record)
                record["same_as_opener"] = CFEqual(element, selection.opener)
                record["same_as_owned_window"] = CFEqual(element, selection.ownedWindow)
                record["same_as_application"] = CFEqual(element, application)
                for key in [kAXParentAttribute, kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
                    var raw: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
                    var relation: [String: Any] = ["actual_status": status.rawValue]
                    record[key] = relation
                    try check(deadline)
                    if status == .success, let raw {
                        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                            throw RuneWorkspaceVisibilityFailure("The diagnostic relationship \(key) was not an AX element.")
                        }
                        let related = raw as! AXUIElement
                        try prepare(related, deadline)
                        relation["same_as_opener"] = CFEqual(related, selection.opener)
                        relation["same_as_owned_window"] = CFEqual(related, selection.ownedWindow)
                        relation["same_as_application"] = CFEqual(related, application)
                        relation["same_as_graph_root"] = CFEqual(related, root)
                        if key == kAXParentAttribute {
                            _ = try diagnosticMenuScalar(related, key: kAXRoleAttribute, deadline: deadline, record: &relation)
                            _ = try diagnosticMenuScalar(related, key: kAXTitleAttribute, deadline: deadline, record: &relation)
                        }
                    } else if status != .noValue, status != .attributeUnsupported {
                        record[key] = relation
                        throw RuneWorkspaceVisibilityFailure("The diagnostic relationship \(key) failed: \(status.rawValue).")
                    }
                    record[key] = relation
                }
                if depth == 0 || role == kAXMenuRole || role == kAXMenuItemRole {
                    var attributes: CFArray?, actions: CFArray?
                    let attributeStatus = AXUIElementCopyAttributeNames(element, &attributes)
                    let actionStatus = AXUIElementCopyActionNames(element, &actions)
                    record["attribute_names_status"] = attributeStatus.rawValue
                    record["action_names_status"] = actionStatus.rawValue
                    try check(deadline)
                    guard attributeStatus == .success, let names = attributes as? [String], names.count <= 128,
                          names.allSatisfy({ $0.utf8.count <= 256 }), actionStatus == .success,
                          let actualActions = actions as? [String], actualActions.count <= 64,
                          actualActions.allSatisfy({ $0.utf8.count <= 256 }) else {
                        throw RuneWorkspaceVisibilityFailure("The menu diagnostic attribute/action names failed or exceeded their bounds.")
                    }
                    record["advertised_attributes"] = names; record["advertised_actions"] = actualActions
                    if CFEqual(element, application) {
                        for key in [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute] where names.contains(key) {
                            try diagnosticFocusedRelationship(application, key: key, selection: selection,
                                deadline: deadline, record: &record)
                        }
                    }
                }
                var count = 0
                let countStatus = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                record["children_count_status"] = countStatus.rawValue; record["children_actual_count"] = count
                try check(deadline)
                if countStatus == .success {
                    guard count >= 0, count <= 2_048 else {
                        throw RuneWorkspaceVisibilityFailure("The menu diagnostic child count exceeded its finite bound.")
                    }
                    let prefix = min(count, 64)
                    if prefix > 0 {
                        var rawChildren: CFArray?
                        let status = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, prefix, &rawChildren)
                        record["children_copy_status"] = status.rawValue
                        try check(deadline)
                        guard status == .success, let children = rawChildren as? [AXUIElement], children.count == prefix else {
                            throw RuneWorkspaceVisibilityFailure("The menu diagnostic child prefix failed or had an invalid type/count.")
                        }
                        record["children_copied_count"] = prefix; record["children_prefix_omitted_count"] = count - prefix
                        if depth < 8 {
                            let capacity = 64 - pending.count
                            pending.append(contentsOf: children.prefix(max(0, capacity)).map { ($0, depth + 1) })
                            record["children_not_enqueued_count"] = children.count - max(0, min(capacity, children.count))
                        } else { record["children_not_enqueued_count"] = children.count }
                    }
                } else if countStatus != .noValue, countStatus != .attributeUnsupported {
                    throw RuneWorkspaceVisibilityFailure("The menu diagnostic child count failed: \(countStatus.rawValue).")
                }
            } catch {
                record["node_error"] = String(String(describing: error).prefix(4_096))
                records.append(record); throw error
            }
            records.append(record)
        }
    }

    private func diagnosticFocusedRelationship(_ application: AXUIElement, key: String,
        selection: RuneWorkspaceNamingMenuSelection, deadline: TimeInterval,
        record: inout [String: Any]) throws {
        var observation: [String: Any] = [
            "classification": "Diagnostic only: advertised own-application focused reference; no menu ownership or action inferred",
            "advertised": true, "parent_node_limit": 16,
        ]
        defer { record[key] = observation }
        func ownReference(_ element: AXUIElement, _ attribute: String,
            into metadata: inout [String: Any]) throws -> AXUIElement? {
            try prepare(element, deadline)
            var relation: [String: Any] = [:]
            defer { metadata[attribute] = relation }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
            relation["actual_status"] = status.rawValue
            relation["returned_CF_type_id"] = raw.map { CFGetTypeID($0) as Any } ?? NSNull()
            relation["returned_type"] = raw.map { String(String(reflecting: type(of: $0)).prefix(256)) as Any } ?? NSNull()
            try check(deadline)
            if status == .noValue || status == .attributeUnsupported { return nil }
            guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
                throw RuneWorkspaceVisibilityFailure("The focused diagnostic relationship \(attribute) failed or returned a non-AX reference: \(status.rawValue).")
            }
            let related = raw as! AXUIElement
            var actualPID: pid_t = 0
            let pidStatus = AXUIElementGetPid(related, &actualPID)
            relation["PID_status"] = pidStatus.rawValue; relation["actual_PID"] = actualPID
            relation["same_as_own_PID"] = pidStatus == .success && actualPID == pid
            relation["same_as_opener"] = CFEqual(related, selection.opener)
            relation["same_as_owned_window"] = CFEqual(related, selection.ownedWindow)
            relation["same_as_application"] = CFEqual(related, application)
            try check(deadline)
            guard pidStatus == .success, actualPID == pid else {
                throw RuneWorkspaceVisibilityFailure("The focused diagnostic reference is not the own PID: \(pidStatus.rawValue), \(actualPID).")
            }
            return related
        }
        guard let focused = try ownReference(application, key, into: &observation) else { return }
        var cursor = focused
        var seen: [AXUIElement] = []
        var chain: [[String: Any]] = []
        defer { observation["actual_parent_chain"] = chain }
        for depth in 0..<16 {
            guard !seen.contains(where: { CFEqual($0, cursor) }) else {
                observation["parent_chain_cycle"] = true
                throw RuneWorkspaceVisibilityFailure("The focused diagnostic parent chain repeated an actual AX reference.")
            }
            seen.append(cursor)
            var node: [String: Any] = [
                "depth": depth, "same_as_opener": CFEqual(cursor, selection.opener),
                "same_as_owned_window": CFEqual(cursor, selection.ownedWindow),
                "same_as_application": CFEqual(cursor, application),
            ]
            do {
                try prepare(cursor, deadline)
                _ = try diagnosticMenuScalar(cursor, key: kAXRoleAttribute, deadline: deadline, record: &node)
                _ = try diagnosticMenuScalar(cursor, key: kAXIdentifierAttribute, deadline: deadline, record: &node)
                _ = try diagnosticMenuScalar(cursor, key: kAXTitleAttribute, deadline: deadline, record: &node)
                _ = try ownReference(cursor, kAXWindowAttribute, into: &node)
                _ = try ownReference(cursor, kAXTopLevelUIElementAttribute, into: &node)
                if CFEqual(cursor, application) {
                    chain.append(node); observation["parent_chain_reached_own_application"] = true
                    return
                }
                guard let parent = try ownReference(cursor, kAXParentAttribute, into: &node) else {
                    chain.append(node); observation["parent_chain_ended_without_parent"] = true
                    return
                }
                chain.append(node); cursor = parent
            } catch {
                node["node_error"] = String(String(describing: error).prefix(4_096))
                chain.append(node); throw error
            }
        }
        observation["parent_chain_stopped_at_limit"] = true
    }

    private func diagnosticMenuScalar(_ element: AXUIElement, key: String, deadline: TimeInterval,
        record: inout [String: Any]) throws -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        record[key + "_status"] = status.rawValue
        try check(deadline)
        if status == .noValue || status == .attributeUnsupported { record[key] = NSNull(); return nil }
        guard status == .success, let value = raw as? String, value.utf8.count <= 4_096 else {
            throw RuneWorkspaceVisibilityFailure("The menu diagnostic scalar \(key) failed or exceeded its bound: \(status.rawValue).")
        }
        record[key] = String(value.prefix(256)); record[key + "_text_prefix_capped"] = value.count > 256
        return value
    }

    private func openOwnedMenu(_ opener: AXUIElement, deadline: TimeInterval,
                               scope: RuneWorkspaceWindowIdentifierScope = .wholeWindow,
                               recordStatus: @escaping (String, Int32) -> Void) throws {
        let main = try ownedWindow(deadline)
        guard try windowNodes(main, deadline, scope: scope, requestedTarget: opener).contains(where: { CFEqual($0.0, opener) }) else { throw RuneWorkspaceVisibilityFailure("The actual layout menu left the owned window graph.") }
        try prepare(opener, deadline)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(opener, &names)
        guard status == .success, let actions = names as? [String], actions.count <= 64 else { throw RuneWorkspaceVisibilityFailure("The actual layout-menu action names failed: \(status.rawValue).") }
        let action = actions.contains(kAXPressAction) ? kAXPressAction : kAXShowMenuAction
        try perform(opener, action: action, roles: [kAXMenuButtonRole, kAXPopUpButtonRole, kAXButtonRole], deadline,
                    recordStatus: recordStatus)
    }

    private func pressRenameItemIfPresent(inMenuOf opener: AXUIElement, ownedWindow expectedWindow: AXUIElement,
        deadline: TimeInterval, recordStatus: @escaping (String, Int32) -> Void) throws -> Bool {
        guard CFEqual(try ownedWindow(deadline), expectedWindow) else {
            throw RuneWorkspaceVisibilityFailure("The tracking menu left its exact exported native window.")
        }
        if let value = try attribute(opener, kAXShownMenuUIElementAttribute, deadline) {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw RuneWorkspaceVisibilityFailure("The actual shown-menu relationship was not an AX element.") }
            let menu = value as! AXUIElement
            guard try string(menu, kAXRoleAttribute, deadline) == kAXMenuRole else { throw RuneWorkspaceVisibilityFailure("The actual shown-menu relationship was not a menu.") }
            let matches = try nodes(menu, deadline).filter { $0.3 == kAXMenuItemRole && $0.4 == "Rename Layout…" }
            guard matches.count <= 1 else { throw RuneWorkspaceVisibilityFailure("The actual layout menu exported duplicate Rename items.") }
            if let item = matches.first {
                try perform(item.0, action: kAXPressAction, roles: [kAXMenuItemRole], deadline, recordStatus: recordStatus)
                return true
            }
        }
        return false
    }
}

@MainActor
private final class RuneWorkspaceNativeNamingMenuCapture: NSObject {
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    let expectedName: String
    let requestedCommand: String
    private(set) var started = 0.0
    private(set) var deadline = 0.0
    var armed = false
    private var actualMenu: NSMenu?
    private var notification: Notification?
    private var capturedRoots = 0
    private var ticks = 0
    private var querying = false
    private enum TrackingEndStage: String {
        case observerRegistered = "observer_registered_return"
        case nativeActionReturned = "native_action_return"
        case cancelReturned = "cancel_tracking_return"
        case resultAssigned = "result_assignment_return"
        case firstExactEnd = "first_exact_end_notification_receipt"
        case stopEntry = "stop_entry"
        case stopAfterClear = "stop_after_reference_clear"
    }
    private var exactEndMatchesFirstTwo = 0
    private var trackingEndOrder: [String: [String: Any]] = [:]
    private(set) var result: Result<Void, Error>?
    private(set) var record: [String: Any] = [:]
    var sheetNodes: [[String: Any]] = []
    var sheetPress: [String: Any] = [:]
    var sheetPhysicalButtons: [String: Any] = [:]
    var sheetDefaultButton: [String: Any] = [:]

    init(window: NSWindow, hosting: NSView, expectedName: String, requestedCommand: String = "Rename Layout…") {
        self.window = window; self.hosting = hosting; self.expectedName = expectedName
        self.requestedCommand = requestedCommand
        super.init()
    }
    func startAttempt() throws {
        guard started == 0 else { throw RuneWorkspaceVisibilityFailure("The native menu capture cannot be reused for another opener.") }
        guard ["Rename Layout…", "Save Layout As…"].contains(requestedCommand) else { throw RuneWorkspaceVisibilityFailure("The native capture requested an unsupported literal naming command.") }
        started = ProcessInfo.processInfo.systemUptime; deadline = started + 3
        recordNativeState("start_attempt")
    }
    var isFinished: Bool { if case .some = result { return true }; return false }
    var evidence: [String: Any] {
        var value = record
        value["mechanism"] = "Actual single NSMenu.didBeginTrackingNotification plus fixture UUID layout marker; NSMenu.performActionForItem(at:) native action route"
        value["captured_root_count"] = capturedRoots; value["captured_root_limit"] = 1
        value["callback_count"] = ticks; value["callback_limit"] = 160
        value["elapsed_seconds"] = started > 0 ? (ProcessInfo.processInfo.systemUptime - started) as Any : NSNull()
        value["sheet_nodes_first64"] = sheetNodes; value["actual_native_sheet_press"] = sheetPress
        value["failure_only_physical_buttons"] = sheetPhysicalButtons
        value["failure_only_default_button_relationship"] = sheetDefaultButton
        value["first_captured_menu_tracking_end_order"] = [
            "classification": "Exact first captured menu notification and cached scalar order only; not enclosing run-loop unwind, menu release, or original failure cause",
            "first_write_stage_limit": 7, "exact_end_match_counter_limit": 2,
            "exact_end_matches_first_two": exactEndMatchesFirstTwo,
            "stages": trackingEndOrder] as [String: Any]
        return value
    }
    func noteOpener(action: String, status: Int32) {
        record["actual_opener_action"] = action; record["actual_opener_status"] = status
        recordNativeState("opener_return")
    }
    private func recordNativeState(_ stage: String, includeFailedOwnerClauses: Bool = false) {
        let observed = ProcessInfo.processInfo.systemUptime, readDeadline = observed + 0.02
        let window = self.window, hosting = self.hosting
        var state: [String: Any] = ["classification": includeFailedOwnerClauses
            ? "Post-failed-guard snapshot; not the original evaluated guard time or failed clause"
            : "Native scalar context only; no ownership substitution or action result",
            "snapshot_uptime": observed, "attempt_deadline": deadline, "read_budget_seconds": 0.02,
            "fixture_window_present": window != nil, "fixture_host_present": hosting != nil,
            "read_budget_expired": false]
        func read(_ body: () -> Void) {
            guard ProcessInfo.processInfo.systemUptime < readDeadline else { state["read_budget_expired"] = true; return }
            body()
        }
        if includeFailedOwnerClauses {
            var clauses: [String: Any] = ["snapshot_uptime_less_than_deadline": observed < deadline,
                "window_present": window != nil, "hosting_present": hosting != nil,
                "window_content_is_host": NSNull(), "host_window_is_fixture": NSNull(),
                "window_is_visible": NSNull(), "host_has_no_hidden_ancestor": NSNull()]
            if let window, let hosting {
                read { clauses["window_content_is_host"] = window.contentView === hosting }
                read { clauses["host_window_is_fixture"] = hosting.window === window }
                read { clauses["window_is_visible"] = window.isVisible }
                read { clauses["host_has_no_hidden_ancestor"] = !hosting.isHiddenOrHasHiddenAncestor }
            }
            state["existing_owner_clauses_resampled_after_failed_guard"] = clauses
        }
        read { state["run_loop_mode_prefix"] = RunLoop.current.currentMode.map { String($0.rawValue.prefix(128)) as Any } ?? NSNull() }
        var sheet: NSWindow?
        if let window {
            read {
                state["fixture_window_number"] = window.windowNumber
                state["fixture_window_is_key"] = window.isKeyWindow
                state["fixture_window_is_main"] = window.isMainWindow
            }
            read { sheet = window.attachedSheet; state["fixture_attached_sheet_present"] = sheet != nil }
            read {
                state["fixture_attached_sheet_is_visible"] = sheet.map { $0.isVisible as Any } ?? NSNull()
                state["fixture_attached_sheet_has_fixture_parent"] = sheet.map { ($0.sheetParent === window) as Any } ?? NSNull()
            }
            read {
                let responder = window.firstResponder
                state["fixture_first_responder_type_prefix"] = responder.map { String(String(describing: type(of: $0)).prefix(128)) as Any } ?? NSNull()
                state["fixture_first_responder_view_is_in_fixture"] = (responder as? NSView).map { ($0.window === window) as Any } ?? NSNull()
            }
        }
        read {
            if let application = NSApp {
                let key = application.keyWindow, main = application.mainWindow, modal = application.modalWindow
                state["native_application_is_active"] = application.isActive
                state["native_key_window_number"] = key.map { $0.windowNumber as Any } ?? NSNull()
                state["native_main_window_number"] = main.map { $0.windowNumber as Any } ?? NSNull()
                state["native_modal_window_number"] = modal.map { $0.windowNumber as Any } ?? NSNull()
                state["native_key_window_is_fixture"] = window.map { (key === $0) as Any } ?? NSNull()
                state["native_main_window_is_fixture"] = window.map { (main === $0) as Any } ?? NSNull()
                state["native_modal_window_is_fixture"] = window.map { (modal === $0) as Any } ?? NSNull()
                state["native_modal_window_is_attached_sheet"] = sheet.map { (modal === $0) as Any } ?? NSNull()
            }
        }
        state["snapshot_elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - observed
        state["read_budget_expired"] = state["read_budget_expired"] as? Bool == true || ProcessInfo.processInfo.systemUptime >= readDeadline
        record["native_state_" + stage] = state
    }
    private func recordTrackingEndStage(_ stage: TrackingEndStage) {
        guard trackingEndOrder[stage.rawValue] == nil else { return }
        let observed = ProcessInfo.processInfo.systemUptime
        let outcome: String
        switch result {
        case .some(.success(_)): outcome = "success"
        case .some(.failure(_)): outcome = "failure"
        case .none: outcome = "none"
        }
        var state: [String: Any] = ["snapshot_uptime": observed, "attempt_deadline": deadline,
            "armed": armed, "held_first_menu_present": actualMenu != nil,
            "result_outcome": outcome, "exact_end_matches_first_two": exactEndMatchesFirstTwo,
            "cached_fixture_marker_proven": record["scope_marker_exact"] != nil,
            "cached_native_dispatch_returned": record["native_command_dispatch_returned"] as? Bool == true,
            "cached_cancel_tracking_returned": record["qualified_native_menu_cancel_tracking_returned"] as? Bool == true]
        if stage == .firstExactEnd {
            let readDeadline = observed + 0.02
            state["notification_object_is_exact_held_first_menu"] = true
            state["mode_read_budget_seconds"] = 0.02
            state["run_loop_mode_prefix"] = NSNull()
            if ProcessInfo.processInfo.systemUptime < readDeadline {
                state["run_loop_mode_prefix"] = RunLoop.current.currentMode.map { String($0.rawValue.prefix(128)) as Any } ?? NSNull()
            }
            let finished = ProcessInfo.processInfo.systemUptime
            state["mode_snapshot_elapsed_seconds"] = finished - observed
            state["mode_read_budget_expired"] = finished >= readDeadline
        }
        trackingEndOrder[stage.rawValue] = state
    }
    @objc func didEndTracking(_ value: Notification) {
        guard armed, let heldMenu = actualMenu, let menu = value.object as? NSMenu,
              menu === heldMenu, exactEndMatchesFirstTwo < 2 else { return }
        exactEndMatchesFirstTwo += 1
        guard exactEndMatchesFirstTwo == 1 else { return }
        recordTrackingEndStage(.firstExactEnd)
    }
    private func requireOwner() throws -> (NSWindow, NSView) {
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let window, let hosting, window.contentView === hosting, hosting.window === window,
              window.isVisible, !hosting.isHiddenOrHasHiddenAncestor else {
            recordNativeState("post_failed_owner_guard", includeFailedOwnerClauses: true)
            throw RuneWorkspaceVisibilityFailure("The native menu lost its finite exact fixture owner.")
        }
        return (window, hosting)
    }
    @objc func didBeginTracking(_ value: Notification) {
        guard armed, !isFinished else { return }
        capturedRoots += 1
        guard capturedRoots == 1, let menu = value.object as? NSMenu else {
            result = .failure(RuneWorkspaceVisibilityFailure("The armed native opener did not produce exactly one actual NSMenu tracking root.")); return
        }
        actualMenu = menu; notification = value
        NotificationCenter.default.addObserver(self, selector: #selector(didEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification, object: menu)
        recordTrackingEndStage(.observerRegistered)
    }
    @objc func fire(_ timer: Timer) {
        guard !isFinished else { timer.invalidate(); return }
        guard !querying else { return }
        querying = true; ticks += 1
        defer { querying = false }
        do {
            let (window, hosting) = try requireOwner()
            guard ticks <= 160 else { throw RuneWorkspaceVisibilityFailure("The native naming timer exceeded its callback bound.") }
            guard let menu = actualMenu, let notification else { return }
            let count = menu.numberOfItems
            guard count > 0, count <= 64 else { throw RuneWorkspaceVisibilityFailure("The actual captured menu exceeded its 64-item bound.") }
            let items = menu.items
            guard items.count == count, items.allSatisfy({ $0.menu === menu && $0.title.utf8.count <= 4_096 }) else {
                throw RuneWorkspaceVisibilityFailure("The actual captured menu item ownership or scalar bound changed.")
            }
            let titles = items.map(\.title)
            let commands = ["Default", "Save Layout As…", "Rename Layout…", "Delete Layout"]
            guard items.filter({ $0.title == "Layout: " + expectedName }).count == 1,
                  commands.allSatisfy({ title in items.filter({ $0.title == title }).count == 1 }),
                  let index = items.firstIndex(where: { $0.title == requestedCommand }),
                  items[index].isEnabled, !items[index].isHidden, !items[index].isSeparatorItem,
                  items[index].submenu == nil, items[index].action != nil else {
                throw RuneWorkspaceVisibilityFailure("The single captured menu did not prove the exact fixture layout marker and enabled literal workspace naming command.")
            }
            record["scope_marker_exact"] = "Layout: " + expectedName
            record["literal_commands_exact"] = commands
            if requestedCommand == "Rename Layout…" { record["actual_rename_index"] = index }
            record["actual_command_title"] = requestedCommand; record["actual_command_index"] = index
            record["actual_root_item_count"] = count
            record["fixture_scope_provenance"] = "Single tracking root captured only during the exact owned opener; UUID name exists only in this fixture's source preferences; each literal workspace command is unique"
            record["native_relationship_measurement"] = runeNativeTrackingMeasurement(menu: menu, notification: notification,
                fixtureWindow: window, fixtureHosting: hosting, deadline: deadline, started: started)
            guard let measurement = record["native_relationship_measurement"] as? [String: Any],
                  measurement["diagnostic_error"] == nil, measurement["root_items_omitted_for_payload_limit"] == nil,
                  measurement["notification_exact_menu_object"] as? Bool == true,
                  (measurement["actual_root_items"] as? [[String: Any]])?.count == count else {
                throw RuneWorkspaceVisibilityFailure("The captured native menu relationship measurement was incomplete or exceeded its bound.")
            }
            _ = try requireOwner()
            let currentItems = menu.items
            guard capturedRoots == 1, menu.numberOfItems == count, currentItems.count == count,
                  currentItems.map(\.title) == titles, zip(currentItems, items).allSatisfy({ $0.0 === $0.1 }),
                  menu.item(at: index) === items[index],
                  items[index].menu === menu, items[index].title == requestedCommand, items[index].isEnabled else {
                throw RuneWorkspaceVisibilityFailure("The actual captured naming command changed before native dispatch.")
            }
            if requestedCommand == "Rename Layout…" { record["actual_native_rename_dispatch"] = "NSMenu.performActionForItem(at:)" }
            record["actual_native_command_dispatch"] = "NSMenu.performActionForItem(at:)"
            menu.performActionForItem(at: index)
            if requestedCommand == "Rename Layout…" { record["native_rename_dispatch_returned"] = true }
            record["native_command_dispatch_returned"] = true
            recordTrackingEndStage(.nativeActionReturned)
            record["native_menu_dismissal_API"] = "NSMenu.cancelTrackingWithoutAnimation()"
            menu.cancelTrackingWithoutAnimation()
            record["qualified_native_menu_cancel_tracking_returned"] = true
            recordTrackingEndStage(.cancelReturned)
            result = .success(()); timer.invalidate()
            recordTrackingEndStage(.resultAssigned)
        } catch {
            record["callback_error"] = String(String(describing: error).prefix(4_096))
            result = .failure(error); timer.invalidate()
            recordTrackingEndStage(.resultAssigned)
        }
    }
    func stop() {
        recordTrackingEndStage(.stopEntry)
        armed = false
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        actualMenu = nil; notification = nil
        recordTrackingEndStage(.stopAfterClear)
    }
}

@MainActor
private enum RuneWorkspaceNativeSheetElement {
    case formal(any NSAccessibilityProtocol)
    case informal(NSObject, Set<NSAccessibility.Attribute>)
    init(_ value: Any) throws {
        if let formal = value as? any NSAccessibilityProtocol { self = .formal(formal) }
        else if let object = value as? NSObject {
            let names = object.accessibilityAttributeNames()
            guard names.count <= 256 else { throw RuneWorkspaceVisibilityFailure("Native sheet attribute advertisement exceeded its bound.") }
            self = .informal(object, Set(names))
        } else { throw RuneWorkspaceVisibilityFailure("An actual native sheet child did not support the public formal or NSObject informal accessibility API.") }
    }
    var object: AnyObject {
        switch self { case .formal(let value): value as AnyObject; case .informal(let value, _): value }
    }
    private func value(_ key: NSAccessibility.Attribute) -> Any? {
        guard case .informal(let object, let names) = self, names.contains(key) else { return nil }
        return object.accessibilityAttributeValue(key)
    }
    func identifier() throws -> String? {
        let raw: Any?
        switch self {
        case .formal(let value):
            if let identifier = value.accessibilityIdentifier() { raw = identifier }
            else if let object = value as? NSObject {
                let names = object.accessibilityAttributeNames()
                guard names.count <= 256 else { throw RuneWorkspaceVisibilityFailure("Native sheet identifier advertisement exceeded its bound.") }
                raw = names.contains(.identifier) ? object.accessibilityAttributeValue(.identifier) : nil
            } else { raw = nil }
        case .informal:
            raw = value(.identifier)
        }
        guard let raw else { return nil }
        guard let identifier = raw as? String else { throw RuneWorkspaceVisibilityFailure("An actual advertised native sheet identifier was not a string.") }
        guard identifier.utf8.count <= 4_096 else { throw RuneWorkspaceVisibilityFailure("A native sheet identifier exceeded its scalar bound.") }
        return identifier
    }
    var role: String? {
        if case .formal(let value) = self { return value.accessibilityRole()?.rawValue }
        let raw = value(.role)
        return (raw as? String) ?? (raw as? NSAccessibility.Role)?.rawValue
    }
    var enabled: Bool? {
        if case .formal(let value) = self { return value.isAccessibilityEnabled() }
        return (value(.enabled) as? NSNumber)?.boolValue
    }
    func children() throws -> [RuneWorkspaceNativeSheetElement] {
        var lists: [[Any]] = []
        if case .formal(let value) = self {
            lists.append(value.accessibilityChildren() ?? [])
            if let object = value as? NSObject {
                let names = object.accessibilityAttributeNames()
                guard names.count <= 256 else { throw RuneWorkspaceVisibilityFailure("Native sheet child advertisement exceeded its bound.") }
                if names.contains(.children), let raw = object.accessibilityAttributeValue(.children) {
                    guard let list = raw as? [Any] else { throw RuneWorkspaceVisibilityFailure("Actual advertised native sheet children were not an array.") }
                    lists.append(list)
                }
            }
        } else if let raw = value(.children) {
            guard let list = raw as? [Any] else { throw RuneWorkspaceVisibilityFailure("Actual advertised native sheet children were not an array.") }
            lists.append(list)
        }
        var result: [RuneWorkspaceNativeSheetElement] = [], seen = Set<ObjectIdentifier>()
        for list in lists {
            guard list.count <= 2_048 else { throw RuneWorkspaceVisibilityFailure("The native sheet child list exceeded its bound.") }
            for child in list {
                let node = try RuneWorkspaceNativeSheetElement(child)
                if seen.insert(ObjectIdentifier(node.object)).inserted {
                    guard result.count < 2_048 else { throw RuneWorkspaceVisibilityFailure("The native sheet child union exceeded its bound.") }
                    result.append(node)
                }
            }
        }
        return result
    }
    func press() throws -> [String: Any] {
        guard role == NSAccessibility.Role.button.rawValue, enabled == true else {
            throw RuneWorkspaceVisibilityFailure("The actual attached-sheet Save control was not an enabled public button.")
        }
        switch self {
        case .formal(let value):
            guard value.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")) else {
                throw RuneWorkspaceVisibilityFailure("The actual native sheet button did not allow its public press selector.")
            }
            let pressed = value.accessibilityPerformPress()
            guard pressed else { throw RuneWorkspaceVisibilityFailure("The actual native sheet button refused its public formal press.") }
            return ["API": "NSAccessibilityProtocol.accessibilityPerformPress", "actual_return": pressed]
        case .informal(let value, _):
            let actions = value.accessibilityActionNames()
            guard actions.count <= 64, actions.contains(.press) else { throw RuneWorkspaceVisibilityFailure("The native sheet button did not advertise a bounded public informal press.") }
            value.accessibilityPerformAction(.press)
            return ["API": "NSObject.accessibilityPerformAction(.press)", "actual_return": NSNull(), "invocation_returned": true]
        }
    }
}

@MainActor
private func runeNamingFailurePhysicalButtons(window: NSWindow, hosting: NSView, sheet: NSWindow) -> [String: Any] {
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = started + 0.3
    var report: [String: Any] = ["classification": "Failure-only physical metadata; no matching, press, fallback or assertion result",
        "node_limit": 2_048, "depth_limit": 48, "button_limit": 64, "deadline_seconds": 0.3, "complete_physical_walk": false]
    var buttons: [[String: Any]] = [], types: [[String: Any]] = []
    var visited = Set<ObjectIdentifier>()
    do {
        guard let content = sheet.contentView else { throw RuneWorkspaceVisibilityFailure("Physical button measurement has no sheet content.") }
        func owner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  window.contentView === hosting, hosting.window === window, window.isVisible,
                  window.attachedSheet === sheet, sheet.sheetParent === window,
                  sheet.contentView === content, content.window === sheet else {
                throw RuneWorkspaceVisibilityFailure("Physical button measurement lost its exact owned sheet or deadline.")
            }
        }
        func text(_ value: String?) throws -> Any {
            guard let value else { return NSNull() }
            guard value.utf8.count <= 4_096 else { throw RuneWorkspaceVisibilityFailure("Physical button metadata scalar exceeded its bound.") }
            return String(value.prefix(256))
        }
        func actions(_ object: NSObject) throws -> [String] {
            let names = object.accessibilityActionNames()
            guard names.count <= 64 else { throw RuneWorkspaceVisibilityFailure("Physical button actions exceeded their bound.") }
            return try names.map { name in
                guard name.rawValue.utf8.count <= 4_096 else { throw RuneWorkspaceVisibilityFailure("Physical button action scalar exceeded its bound.") }
                return String(name.rawValue.prefix(256))
            }
        }
        var pending: [(NSView, Int)] = [(content, 0)]
        while let (view, depth) = pending.popLast() {
            try owner()
            guard depth <= 48 else { throw RuneWorkspaceVisibilityFailure("Physical button measurement exceeded depth 48.") }
            guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
            guard visited.count <= 2_048, view.window === sheet else { throw RuneWorkspaceVisibilityFailure("Physical button measurement exceeded its node/window bound.") }
            if types.count < 64 { types.append(["depth": depth, "actual_type": String(String(describing: type(of: view)).prefix(128)), "is_NSButton": view is NSButton]) }
            if let button = view as? NSButton {
                guard buttons.count < 64 else { throw RuneWorkspaceVisibilityFailure("Physical button measurement exceeded 64 actual buttons.") }
                let cell = button.cell, actual = try RuneWorkspaceNativeSheetElement(button)
                let cellElement = try cell.map { try RuneWorkspaceNativeSheetElement($0) }
                let buttonID = button.accessibilityIdentifier(), cellID = cell?.accessibilityIdentifier()
                let rect = button.convert(button.bounds, to: nil)
                buttons.append(["button_identity": String(describing: ObjectIdentifier(button)),
                    "cell_identity": cell.map { String(describing: ObjectIdentifier($0)) as Any } ?? NSNull(),
                    "cell_controlView_is_button": cell?.controlView === button,
                    "button_window_is_sheet": button.window === sheet, "button_hidden_or_ancestor_hidden": button.isHiddenOrHasHiddenAncestor,
                    "window_rect": NSStringFromRect(rect),
                    "window_rect_finite": [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
                    "window_rect_positive": rect.width > 0 && rect.height > 0,
                    "cell_controlView_window_is_sheet": cell?.controlView?.window === sheet,
                    "button_identifier": try text(buttonID), "cell_identifier": try text(cellID),
                    "button_literal_save_ID": buttonID == "workspace-save-layout",
                    "owned_cell_literal_save_ID": cell?.controlView === button && cellID == "workspace-save-layout",
                    "button_role": try text(actual.role), "cell_role": try text(cellElement?.role),
                    "button_enabled": button.isEnabled, "button_AX_enabled": actual.enabled.map { $0 as Any } ?? NSNull(),
                    "cell_enabled": cell.map { $0.isEnabled as Any } ?? NSNull(), "cell_AX_enabled": cellElement?.enabled.map { $0 as Any } ?? NSNull(),
                    "button_actions": try actions(button), "cell_actions": try cell.map { try actions($0) } ?? [],
                    "target_present": button.target != nil, "action_selector": try text(button.action.map(NSStringFromSelector)),
                    "formal_press_allowed": button.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress"))])
            }
            let children = view.subviews
            guard pending.count + children.count + visited.count <= 2_048 else { throw RuneWorkspaceVisibilityFailure("Physical button pending walk exceeded its bound.") }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        try owner(); report["complete_physical_walk"] = true
    } catch { report["diagnostic_error"] = String(String(describing: error).prefix(512)) }
    report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
    report["within_diagnostic_deadline"] = ProcessInfo.processInfo.systemUptime <= deadline
    report["visited_nodes"] = visited.count; report["physical_types_first64"] = types; report["actual_buttons"] = buttons
    if let data = try? JSONSerialization.data(withJSONObject: report), data.count <= 128 * 1_024 { return report }
    return ["diagnostic_error": "Physical button metadata exceeded 128 KiB or was not valid JSON.", "visited_nodes": visited.count, "actual_button_count": buttons.count]
}

@MainActor
private func runeNamingFailureDefaultButton(window: NSWindow, hosting: NSView, sheet: NSWindow) -> [String: Any] {
    let started = ProcessInfo.processInfo.systemUptime, deadline = ProcessInfo.processInfo.systemUptime + 0.3
    var report: [String: Any] = ["classification": "Failure-only public default-button relationships; no press, matching, fallback or assertion result",
        "deadline_seconds": 0.3, "node_limit": 16, "scalar_limit_bytes": 4_096, "action_limit": 64, "complete_measurement": false]
    var records: [[String: Any]] = [], visited = Set<ObjectIdentifier>()
    do {
        guard let content = sheet.contentView else { throw RuneWorkspaceVisibilityFailure("Default-button measurement has no sheet content.") }
        func owner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline, window.contentView === hosting, hosting.window === window,
                  window.isVisible, window.attachedSheet === sheet, sheet.sheetParent === window,
                  sheet.contentView === content, content.window === sheet else {
                throw RuneWorkspaceVisibilityFailure("Default-button measurement lost its exact sheet/host or deadline.")
            }
        }
        func text(_ value: String?) throws -> Any {
            guard let value else { return NSNull() }
            guard value.utf8.count <= 4_096 else { throw RuneWorkspaceVisibilityFailure("Default-button scalar exceeded 4,096 bytes.") }
            return String(value.prefix(256))
        }
        func reference(_ raw: Any?) throws -> [String: Any] {
            guard let raw else { return ["present": false] }
            let element = try RuneWorkspaceNativeSheetElement(raw), object = element.object
            visited.insert(ObjectIdentifier(object))
            guard visited.count <= 16 else { throw RuneWorkspaceVisibilityFailure("Default-button relationships exceeded 16 actual nodes.") }
            return ["present": true, "identity": String(describing: ObjectIdentifier(object)),
                "actual_type": String(String(describing: type(of: object)).prefix(128)), "is_exact_sheet": object === sheet,
                "is_exact_origin_window": object === window, "is_exact_sheet_content": object === content,
                "physical_view_window_is_sheet": (object as? NSView).map { ($0.window === sheet) as Any } ?? NSNull()]
        }
        try owner()
        let allowed = sheet.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityDefaultButton"))
        report["formal_defaultButton_selector_allowed"] = allowed
        let formal = allowed ? sheet.accessibilityDefaultButton() : nil
        try owner()
        let names = sheet.accessibilityAttributeNames()
        guard names.count <= 256 else { throw RuneWorkspaceVisibilityFailure("Default-button sheet advertisements exceeded 256 attributes.") }
        let advertised = names.contains(.defaultButton)
        report["informal_defaultButton_advertised"] = advertised
        let informal = advertised ? sheet.accessibilityAttributeValue(.defaultButton) : nil
        try owner()
        report["both_returned_same_object"] = formal.flatMap { first in informal.map { second in (first as AnyObject) === (second as AnyObject) } }.map { $0 as Any } ?? NSNull()
        for (api, attempted, raw) in [("NSAccessibilityProtocol.accessibilityDefaultButton", allowed, formal),
                                      ("advertised NSObject.accessibilityAttributeValue(.defaultButton)", advertised, informal)] {
            var row: [String: Any] = ["API": api, "queried": attempted, "returned_relationship": try reference(raw)]
            defer { records.append(row) }
            try owner()
            guard let raw else { continue }
            let element = try RuneWorkspaceNativeSheetElement(raw), identifier = try element.identifier()
            row["identifier"] = try text(identifier); row["literal_save_ID"] = identifier == "workspace-save-layout"
            row["role"] = try text(element.role); row["enabled"] = element.enabled.map { $0 as Any } ?? NSNull()
            let object = element.object as? NSObject
            let actions = object?.accessibilityActionNames() ?? []; row["actions_queried"] = object != nil
            guard actions.count <= 64 else { throw RuneWorkspaceVisibilityFailure("Default-button advertised actions exceeded 64.") }
            row["actions"] = try actions.map { try text($0.rawValue) }
            switch element {
            case .formal(let value):
                row["formal_press_selector_allowed"] = value.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress"))
                row["formal_window"] = try reference(value.accessibilityWindow())
                row["formal_top_level"] = try reference(value.accessibilityTopLevelUIElement())
            case .informal(let value, let attributes):
                row["informal_window_advertised"] = attributes.contains(.window)
                row["informal_top_level_advertised"] = attributes.contains(.topLevelUIElement)
                row["informal_window"] = try reference(attributes.contains(.window) ? value.accessibilityAttributeValue(.window) : nil)
                row["informal_top_level"] = try reference(attributes.contains(.topLevelUIElement) ? value.accessibilityAttributeValue(.topLevelUIElement) : nil)
            }
            try owner()
        }
        try owner(); report["complete_measurement"] = true
    } catch { report["diagnostic_error"] = String(String(describing: error).prefix(512)) }
    report["actual_relationships"] = records; report["unique_relationship_nodes"] = visited.count
    report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
    report["within_diagnostic_deadline"] = ProcessInfo.processInfo.systemUptime <= deadline
    if let data = try? JSONSerialization.data(withJSONObject: report), data.count <= 64 * 1_024 { return report }
    return ["diagnostic_error": "Default-button metadata exceeded 64 KiB or was not valid JSON."]
}

@MainActor
private final class RuneWorkspaceNativeNamingSheet {
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    private weak var sheet: NSWindow?
    private weak var sheetContent: NSView?
    private(set) var lastNodes: [[String: Any]] = []
    init(window: NSWindow, hosting: NSView, sheet: NSWindow) {
        self.window = window; self.hosting = hosting; self.sheet = sheet; sheetContent = sheet.contentView
    }
    private func requireOwner() throws -> NSWindow {
        guard let window, let hosting, let sheet, let sheetContent,
              window.contentView === hosting, hosting.window === window, window.isVisible,
              window.attachedSheet === sheet, sheet.sheetParent === window,
              sheet.contentView === sheetContent, sheetContent.window === sheet else {
            throw RuneWorkspaceVisibilityFailure("The native Save traversal lost its exact originating attached sheet/window/host.")
        }
        return sheet
    }
    private func identifierSnapshot(_ expectedIdentifier: String, _ deadline: TimeInterval) throws -> RuneWorkspaceNativeSheetElement? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("The native sheet snapshot began after its deadline.") }
        let actualSheet = try requireOwner()
        var pending: [(RuneWorkspaceNativeSheetElement, Int)] = [(try .init(actualSheet), 0)]
        var visited = Set<ObjectIdentifier>(), matches: [RuneWorkspaceNativeSheetElement] = []
        lastNodes = []
        while let (node, depth) = pending.popLast() {
            _ = try requireOwner()
            guard ProcessInfo.processInfo.systemUptime < deadline, depth <= 48 else { throw RuneWorkspaceVisibilityFailure("The complete native sheet traversal exceeded its deadline/depth bound.") }
            guard visited.insert(ObjectIdentifier(node.object)).inserted else { continue }
            guard visited.count <= 2_048 else { throw RuneWorkspaceVisibilityFailure("The complete native sheet traversal exceeded its node bound.") }
            if let physical = node.object as? NSView, physical.window !== actualSheet {
                throw RuneWorkspaceVisibilityFailure("An actual native sheet view belonged to another window.")
            }
            let identifier = try node.identifier()
            if let identifier, identifier.utf8.count > 4_096 { throw RuneWorkspaceVisibilityFailure("A native sheet identifier exceeded its scalar bound.") }
            if lastNodes.count < 64 { lastNodes.append(["identifier": identifier.map { String($0.prefix(256)) as Any } ?? NSNull(), "depth": depth, "type": String(String(describing: type(of: node.object)).prefix(128))]) }
            if identifier == expectedIdentifier { matches.append(node) }
            let children = try node.children()
            guard pending.count + children.count + visited.count <= 2_048 else { throw RuneWorkspaceVisibilityFailure("The complete native sheet pending traversal exceeded its bound.") }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        _ = try requireOwner()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("The complete native sheet snapshot finished after its deadline.") }
        guard matches.count <= 1 else { throw RuneWorkspaceVisibilityFailure("The complete native attached-sheet tree exposed duplicate actual \(expectedIdentifier) identifiers: \(matches.count).") }
        return matches.first
    }
    func requiredSave() async throws -> RuneWorkspaceNativeSheetElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if let save = try identifierSnapshot("workspace-save-layout", deadline) { return save }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("The complete native attached-sheet tree did not expose an actual Save identifier before its deadline.") }
            try await Task.sleep(for: .milliseconds(10))
        } while true
    }
    func requiredName() async throws -> RuneWorkspaceNativeSheetElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if let name = try identifierSnapshot("workspace-layout-name", deadline) { return name }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuneWorkspaceVisibilityFailure("The complete native attached-sheet tree did not expose the actual name identifier before its deadline.") }
            try await Task.sleep(for: .milliseconds(10))
        } while true
    }
    func pressSave() async throws -> [String: Any] {
        let save = try await requiredSave()
        _ = try requireOwner()
        return try save.press()
    }
}

// The caller supplies the actual notification object from its finite native observer.
// This snapshot performs no menu action and does not establish opener ownership.
@MainActor
private func runeNativeTrackingMeasurement(menu: NSMenu, notification: Notification,
    fixtureWindow: NSWindow, fixtureHosting: NSView, deadline: TimeInterval,
    started: TimeInterval) -> [String: Any] {
    let began = ProcessInfo.processInfo.systemUptime
    let queryDeadline = min(deadline, began + 0.3)
    var report: [String: Any] = [
        "classification": "Native notification measurement only; no ownership substitution, action, API retry, exported AX, desktop input, or assertion result",
        "query_deadline_seconds": 0.3, "root_item_limit": 64, "payload_limit_bytes": 16 * 1_024,
        "relative_started_seconds": began - started,
        "native_fixture_window_is_key": fixtureWindow.isKeyWindow,
        "native_fixture_window_is_main": fixtureWindow.isMainWindow,
        "native_key_window_is_fixture": NSApp.keyWindow === fixtureWindow,
        "native_main_window_is_fixture": NSApp.mainWindow === fixtureWindow,
        "native_fixture_exact_host": fixtureWindow.contentView === fixtureHosting && fixtureHosting.window === fixtureWindow,
    ]
    func checkMeasurement() throws {
        guard ProcessInfo.processInfo.systemUptime < queryDeadline else {
            throw RuneWorkspaceVisibilityFailure("The native menu measurement exceeded its finite query deadline.")
        }
    }
    func boundedText(_ value: String) throws -> String {
        guard value.utf8.count <= 4_096 else {
            throw RuneWorkspaceVisibilityFailure("The native menu measurement scalar exceeded 4,096 bytes.")
        }
        return String(value.prefix(256))
    }
    func relationship(_ value: Any?) throws -> [String: Any] {
        try checkMeasurement()
        var row: [String: Any] = [
            "present": value != nil,
            "actual_type": value.map { String(String(describing: type(of: $0)).prefix(128)) as Any } ?? NSNull(),
        ]
        if let nativeWindow = value as? NSWindow {
            row["native_window_is_exact_fixture"] = nativeWindow === fixtureWindow
        } else { row["native_window_is_exact_fixture"] = NSNull() }
        if let nativeView = value as? NSView {
            let nativeViewWindow = nativeView.window
            row["native_view_window_present"] = nativeViewWindow != nil
            row["native_view_window_is_exact_fixture"] = nativeViewWindow.map { ($0 === fixtureWindow) as Any } ?? NSNull()
            let identifier = nativeView.accessibilityIdentifier()
            row["native_view_identifier_prefix"] = try boundedText(identifier)
            row["native_view_identifier_prefix_capped"] = identifier.count > 256
        } else {
            row["native_view_window_present"] = NSNull()
            row["native_view_window_is_exact_fixture"] = NSNull()
            row["native_view_identifier_prefix"] = NSNull()
            row["native_view_identifier_prefix_capped"] = NSNull()
        }
        try checkMeasurement()
        return row
    }
    do {
        try checkMeasurement()
        guard let actualMenu = notification.object as? NSMenu, actualMenu === menu else {
            throw RuneWorkspaceVisibilityFailure("The native measurement did not receive the exact notification NSMenu object.")
        }
        report["notification_exact_menu_object"] = true
        report["notification_user_info_present"] = notification.userInfo != nil
        report["actual_menu_is_main_menu"] = NSApp.mainMenu.map { (menu === $0) as Any } ?? NSNull()
        report["actual_menu_supermenu_present"] = menu.supermenu != nil
        report["actual_menu_title_prefix"] = try boundedText(menu.title)
        report["actual_menu_title_prefix_capped"] = menu.title.count > 256
        try checkMeasurement()
        report["actual_native_accessibility_window"] = try relationship(menu.accessibilityWindow())
        try checkMeasurement()
        report["actual_native_accessibility_top_level"] = try relationship(menu.accessibilityTopLevelUIElement())
        try checkMeasurement()
        report["actual_native_accessibility_parent"] = try relationship(menu.accessibilityParent())
        let count = menu.numberOfItems
        report["actual_root_item_count"] = count
        guard count >= 0, count <= 64 else {
            throw RuneWorkspaceVisibilityFailure("The native notification root menu exceeded its 64-item measurement bound.")
        }
        var items: [[String: Any]] = []
        for index in 0..<count {
            try checkMeasurement()
            guard let item = menu.item(at: index) else {
                throw RuneWorkspaceVisibilityFailure("The native notification root menu lost a measured item.")
            }
            items.append(["actual_index": index, "title_prefix": try boundedText(item.title),
                          "title_prefix_capped": item.title.count > 256, "enabled": item.isEnabled,
                          "separator": item.isSeparatorItem, "submenu_present": item.submenu != nil,
                          "action_present": item.action != nil])
            try checkMeasurement()
        }
        report["actual_root_items"] = items
    } catch {
        report["diagnostic_error"] = String(String(describing: error).prefix(256))
    }
    report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - began
    var data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    if data == nil || (data?.count ?? 0) > 16 * 1_024 {
        report["actual_root_items"] = []
        report["root_items_omitted_for_payload_limit"] = true
        data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }
    guard let data, data.count <= 16 * 1_024 else {
        return ["classification": "Native notification measurement only", "diagnostic_error": "The diagnostic payload could not be retained within 16 KiB."]
    }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "rune-native-notification-menu-measurement"
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Rune native notification menu measurement") { activity in
        activity.add(attachment)
    }
    return report
}


#endif
#if !SWIFT_PACKAGE
@MainActor
func nativeWorkspaceVerifyNaming(window: NSWindow, hosting: NSView,
    preferences: NativeWorkspacePreferences, defaults: UserDefaults,
    viewID: String, deadline: TimeInterval, retain: ([String: Any]) -> Void) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty,
          deadline.isFinite, deadline > started, deadline - started <= 120,
          NativeWorkspaceCatalog.panelsByView[viewID] != nil else {
        throw RuneWorkspaceVisibilityFailure("Shared naming requires a catalog view, native host and finite deadline of at most 120 seconds.")
    }
    let commands = ["Rename Layout…", "Save Layout As…"]
    let observer = RuneWorkspaceNamingAX(window: window, hosting: hosting)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let initial = preferences.collection
    let original = try XCTUnwrap(preferences.activeLayout(for: viewID))
    let independentLayouts = initial.layouts.filter { $0.viewID != viewID }
    let independentSelections = initial.activeLayoutIDs.filter { $0.key != viewID }
    guard original.viewID == viewID, !independentLayouts.isEmpty, preferences.restorationError == nil else {
        throw RuneWorkspaceVisibilityFailure("Shared naming requires an active same-view layout and an independent saved namespace.")
    }
    var stage = "baseline", menus: [[String: Any]] = [], witnesses: [[String: Any]] = []
    var states: [[String: Any]] = [], activeMenu: RuneWorkspaceNativeNamingMenuCapture?

    func requireOwner() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline,
              window.contentView === hosting, hosting.window === window,
              window.isVisible, !hosting.isHiddenOrHasHiddenAncestor else {
            throw RuneWorkspaceVisibilityFailure("Shared naming lost its exact window/hosting owner or deadline.")
        }
    }
    func admitThreeSecondCall() throws {
        try requireOwner()
        guard deadline - ProcessInfo.processInfo.systemUptime > 3 else {
            throw RuneWorkspaceVisibilityFailure("Shared naming lacks three seconds for its existing bounded native operation.")
        }
    }
    func wait(_ message: String, _ condition: () throws -> Bool) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        while ProcessInfo.processInfo.systemUptime < end {
            try requireOwner()
            if try condition() {
                try requireOwner()
                guard ProcessInfo.processInfo.systemUptime < end else {
                    throw RuneWorkspaceVisibilityFailure("Shared naming condition returned after its bounded wait.")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RuneWorkspaceVisibilityFailure(message)
    }
    func requireSheetOwner(_ sheet: NSWindow, _ content: NSView) throws {
        try requireOwner()
        guard window.attachedSheet === sheet, sheet.sheetParent === window,
              window.sheets.count == 1, window.sheets.first === sheet, sheet.sheets.isEmpty,
              sheet.contentView === content, content.window === sheet, sheet.isVisible,
              !content.isHiddenOrHasHiddenAncestor else {
            throw RuneWorkspaceVisibilityFailure("Shared naming lost its exact sole attached sheet/content/parent.")
        }
    }
    func checkStored(_ expected: NativeWorkspaceCollection, label: String) throws {
        try requireOwner()
        let bytes = try encoder.encode(expected)
        let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
        guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
              preferences.collection == expected, defaults.data(forKey: NativeWorkspacePreferences.storageKey) == bytes,
              restored.restorationError == nil, restored.collection == expected,
              preferences.collection.layouts.filter({ $0.viewID != viewID }) == independentLayouts,
              preferences.collection.activeLayoutIDs.filter({ $0.key != viewID }) == independentSelections,
              states.count < 3 else {
            throw RuneWorkspaceVisibilityFailure("Shared naming changed unexpected collection bytes, identity or another namespace.")
        }
        try requireOwner()
        states.append(["stage": label, "complete_collection_and_sorted_bytes_exact": true,
            "fresh_preferences_restoration_exact": true, "independent_namespaces_unchanged": true,
            "stored_bytes": bytes.count, "saved_layout_count": expected.layouts.count])
    }
    func expectedUnusedName() -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let names = Set(preferences.layouts(for: viewID).map { $0.name.folding(options: .caseInsensitive, locale: locale) })
        for index in 1...NativeWorkspaceLimits.maximumSavedLayouts + 1 {
            let name = index == 1 ? "Custom" : "Custom \(index)"
            if !names.contains(name.folding(options: .caseInsensitive, locale: locale)) { return name }
        }
        return "Custom"
    }
    func requiredField(sheet: NSWindow, content: NSView, expectedValue: String) async throws -> (NSTextField, String) {
        try requireSheetOwner(sheet, content)
        let semantic = RuneWorkspaceNativeNamingSheet(window: window, hosting: hosting, sheet: sheet)
        try admitThreeSecondCall()
        _ = try await semantic.requiredName()
        try requireSheetOwner(sheet, content)
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        var pending: [(NSView, Int)] = [(content, 0)], seen = Set<ObjectIdentifier>(), matches: [(NSTextField, String)] = []
        while let (view, depth) = pending.popLast() {
            try requireSheetOwner(sheet, content)
            guard ProcessInfo.processInfo.systemUptime < end, depth <= 48 else {
                throw RuneWorkspaceVisibilityFailure("Shared name-field discovery exceeded its deadline/depth bound.")
            }
            guard seen.insert(ObjectIdentifier(view)).inserted else { continue }
            guard seen.count <= 2_048, view.window === sheet else {
                throw RuneWorkspaceVisibilityFailure("Shared name-field discovery exceeded its node/owner bound.")
            }
            if let field = view as? NSTextField {
                let direct = field.accessibilityIdentifier(), cell = field.cell
                let ownedID = cell?.controlView === field ? cell?.accessibilityIdentifier() : nil
                guard [direct, ownedID].allSatisfy({ $0.map { $0.utf8.count <= 4_096 } ?? true }) else {
                    throw RuneWorkspaceVisibilityFailure("Shared name-field identifier exceeded its scalar bound.")
                }
                if direct == "workspace-layout-name" || ownedID == "workspace-layout-name" {
                    matches.append((field, direct == "workspace-layout-name" ? "NSTextField.accessibilityIdentifier" : "actual owned field.cell.accessibilityIdentifier"))
                }
            }
            let children = view.subviews
            guard pending.count + children.count + seen.count <= 2_048 else {
                throw RuneWorkspaceVisibilityFailure("Shared name-field pending walk exceeded its bound.")
            }
            pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        try requireSheetOwner(sheet, content)
        guard ProcessInfo.processInfo.systemUptime < end, matches.count == 1 else {
            throw RuneWorkspaceVisibilityFailure("Shared naming did not expose exactly one actual owned name field.")
        }
        let (field, identity) = matches[0], rect = field.convert(field.bounds, to: nil)
        guard field.isEnabled, field.isEditable, !field.isHiddenOrHasHiddenAncestor,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, rect.width <= 2_400, rect.height <= 2_400,
              expectedValue.utf8.count <= NativeWorkspaceLimits.maximumNameBytes, field.stringValue == expectedValue,
              ProcessInfo.processInfo.systemUptime < end else {
            throw RuneWorkspaceVisibilityFailure("Shared name field lost its finite owner/value/deadline gates.")
        }
        try requireSheetOwner(sheet, content)
        guard ProcessInfo.processInfo.systemUptime < end else {
            throw RuneWorkspaceVisibilityFailure("Shared name-field getters returned after their deadline.")
        }
        return (field, identity)
    }
    func replaceText(sheet: NSWindow, content: NSView, field: NSTextField, name: String) throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        try requireSheetOwner(sheet, content)
        guard name.utf8.count <= NativeWorkspaceLimits.maximumNameBytes, field.window === sheet,
              sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
              sheet.firstResponder === editor, editor.window === sheet, editor.string == field.stringValue else {
            throw RuneWorkspaceVisibilityFailure("Shared naming did not establish its exact actual editor.")
        }
        editor.selectAll(nil)
        guard editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count) else {
            throw RuneWorkspaceVisibilityFailure("Shared editor did not select its complete original name.")
        }
        editor.insertText(name, replacementRange: editor.selectedRange())
        guard editor.string == name else { throw RuneWorkspaceVisibilityFailure("Shared editor did not receive the new name.") }
        sheet.endEditing(for: field)
        try requireSheetOwner(sheet, content)
        guard field.window === sheet, field.stringValue == name, ProcessInfo.processInfo.systemUptime < end else {
            throw RuneWorkspaceVisibilityFailure("Shared editor did not commit its name within the owned deadline.")
        }
    }
    func retainReport(_ error: Error? = nil) throws {
        let bytes = try encoder.encode(preferences.collection)
        guard bytes.count <= NativeWorkspaceLimits.maximumStoredBytes,
              witnesses.count <= 2, menus.count + (activeMenu == nil ? 0 : 1) <= 2, states.count <= 3 else {
            throw RuneWorkspaceVisibilityFailure("Shared naming evidence exceeded its collection/witness/menu/state bound.")
        }
        let report: [String: Any] = [
            "classification": "Actual native naming on one isolated production root; validated application-content opener and sole first-order exact attached-sheet Save. Native/exported sheet correspondence is inferred from sole sheets under the same exact parent, not direct conversion. Original whole-window gates remain separate; no Return fallback, sidebar, desktop or live-backend proof.",
            "view_id": viewID, "stage": stage, "requested_commands": commands,
            "execution_completed": stage == "completed" && error == nil, "within_shared_deadline": ProcessInfo.processInfo.systemUptime < deadline,
            "shared_deadline_maximum_seconds": 120, "local_wait_maximum_seconds": 3,
            "original_layout_id": original.id.uuidString, "menu_reports": menus,
            "incomplete_menu_attempt": activeMenu.map { $0.evidence as Any } ?? NSNull(),
            "normal_naming_witnesses": witnesses, "stored_state_checks": states,
            "last_required_AX_walk_context": observer.lastRequiredWalkContext,
            "last_application_content_window_scope": observer.lastApplicationContentWindowScope,
            "last_AX_scalar_read": observer.lastRead,
            "collection": try JSONSerialization.jsonObject(with: bytes),
            "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 256 * 1_024 else {
            throw RuneWorkspaceVisibilityFailure("Shared naming JSON exceeded the caller's existing 256 KiB payload bound.")
        }
        if error == nil { try requireOwner() }
        retain(report)
    }
    do {
        try requireOwner()
        guard window.attachedSheet == nil, window.sheets.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Shared naming fixture already has an attached sheet.")
        }
        try checkStored(initial, label: "baseline")
        for command in commands {
            try requireOwner()
            let before = preferences.collection, beforeBytes = try encoder.encode(preferences.collection)
            let active = try XCTUnwrap(preferences.activeLayout(for: viewID))
            let newName = (command == "Rename Layout…" ? "Renamed-" : "Saved-") + UUID().uuidString
            let fieldValue = command == "Rename Layout…" ? active.name : expectedUnusedName()
            guard active.viewID == viewID, !preferences.layouts(for: viewID).contains(where: { $0.name == newName }),
                  window.attachedSheet == nil, window.sheets.isEmpty, witnesses.count < 2, menus.count < 2 else {
                throw RuneWorkspaceVisibilityFailure("Shared naming lost its originating layout, unused name or sheet/menu bound.")
            }
            stage = command == "Rename Layout…" ? "rename" : "save-as"
            let index = witnesses.count
            witnesses.append(["command": command, "new_name": newName, "actual_editor_changed": false,
                "actual_Save_action_requested": false, "actual_Save_action_returned": false, "actual_sheet_dismissed": false])
            let capture = RuneWorkspaceNativeNamingMenuCapture(window: window, hosting: hosting,
                expectedName: active.name, requestedCommand: command)
            activeMenu = capture
            try admitThreeSecondCall()
            let opener = try await observer.required(identifier: "workspace-layout-menu-" + viewID, scope: .applicationContent)
            try admitThreeSecondCall()
            try await observer.openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture, scope: .applicationContent)
            menus.append(capture.evidence); activeMenu = nil
            try requireOwner()
            try await wait("Shared native command did not present its production naming sheet.") { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
            let (field, identity) = try await requiredField(sheet: sheet, content: content, expectedValue: fieldValue)
            witnesses[index]["identity_source"] = identity
            try replaceText(sheet: sheet, content: content, field: field, name: newName)
            witnesses[index]["actual_editor_changed"] = true
            try requireSheetOwner(sheet, content)
            guard preferences.collection == before,
                  defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
                throw RuneWorkspaceVisibilityFailure("Shared editor changed saved layouts or stored bytes before Save.")
            }
            witnesses[index]["collection_and_bytes_unchanged_before_Save"] = true
            try admitThreeSecondCall()
            let save = try observer.requiredExactAttachedSheetSave(sheet: sheet, content: content, field: field, expectedName: newName)
            try requireSheetOwner(sheet, content)
            guard field.window === sheet, field.stringValue == newName, preferences.collection == before,
                  defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
                throw RuneWorkspaceVisibilityFailure("Shared exported Save lost its retained name field or unchanged stored collection.")
            }
            try admitThreeSecondCall()
            try observer.pressRetainedExactAttachedSheetSave(save, sheet: sheet, content: content, field: field,
                expectedName: newName, witness: &witnesses[index])
            try requireOwner()
            try await wait("Shared exact exported Save did not dismiss its naming sheet.") { window.attachedSheet == nil }
            witnesses[index]["actual_sheet_dismissed"] = true
            let after = preferences.collection, result = try XCTUnwrap(preferences.activeLayout(for: viewID))
            if command == "Rename Layout…" {
                var expected = before
                let layoutIndex = try XCTUnwrap(expected.layouts.firstIndex { $0.id == active.id && $0.viewID == viewID })
                expected.layouts[layoutIndex].name = newName
                guard result.id == original.id, result.name == newName, after == expected else {
                    throw RuneWorkspaceVisibilityFailure("Shared Rename did not preserve exact identity, geometry, panels and other namespaces.")
                }
            } else {
                guard result.id != active.id, result.name == newName, result.viewID == active.viewID,
                      result.canvas == active.canvas, result.panels == active.panels else {
                    throw RuneWorkspaceVisibilityFailure("Shared Save As did not create one named copy with a new identity and unchanged geometry/panels.")
                }
                var expected = before; expected.layouts.append(result); expected.activeLayoutIDs[viewID] = result.id
                guard after == expected else { throw RuneWorkspaceVisibilityFailure("Shared Save As changed more than its new layout and selection.") }
            }
            try checkStored(after, label: stage)
        }
        guard menus.count == 2, witnesses.count == 2, states.count == 3,
              witnesses.allSatisfy({ $0["actual_editor_changed"] as? Bool == true
                && $0["actual_Save_action_requested"] as? Bool == true
                && $0["actual_Save_action_returned"] as? Bool == true
                && $0["actual_Save_action_status"] as? Int32 == 0
                && $0["actual_sheet_dismissed"] as? Bool == true }),
              window.attachedSheet == nil, window.sheets.isEmpty else {
            throw RuneWorkspaceVisibilityFailure("Shared naming omitted one actual menu/editor/Save/dismissal/state witness.")
        }
        try requireOwner(); stage = "completed"
        try retainReport()
        try requireOwner()
    } catch {
        let originalError = error
        do { try retainReport(originalError) }
        catch {
            retain(["classification": "Shared naming evidence retention failure; original operation error preserved",
                "view_id": viewID, "stage": stage,
                "original_error": String(String(describing: originalError).prefix(4_096)),
                "retention_error": String(String(describing: error).prefix(4_096))])
        }
        throw originalError
    }
}
#endif
