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

    func testMountedRuneFreshNativeRenameExportedSavePersistsIdentity() async throws {
        try await runeExerciseFreshNativeMenuExportedSave(commands: ["Rename Layout…"])
    }

    func testMountedRuneFreshNativeSaveAsExportedSavePersistsCopy() async throws {
        try await runeExerciseFreshNativeMenuExportedSave(commands: ["Save Layout As…"])
    }

    private func runeExerciseFreshNativeMenuExportedSave(commands: [String]) async throws {
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
            let report: [String: Any] = ["classification": "Separate fresh-fixture naming reachability: native menu, actual NSTextView editor and exported exact-sheet Save activation; distinct from combined sequential Rename/Save As qualification, no Return fallback or desktop/pointer-input proof.",
                "stage": stage, "requested_commands": commands, "fresh_fixture_command_count": commands.count,
                "normal_naming_witnesses": witnesses,
                "actual_menu_transition": menu?.evidence ?? [:],
                "collection": try JSONSerialization.jsonObject(with: bytes),
                "error": error.map { String(String(describing: $0).prefix(4_096)) as Any } ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 1_152 * 1_024 else { throw RuneWorkspaceVisibilityFailure("Positive naming JSON exceeded its payload bound.") }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "rune-fresh-native-menu-exported-save-" + stage; attachment.lifetime = .keepAlways; add(attachment)
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

@MainActor
private final class RuneWorkspaceNamingAX {
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    private let pid = getpid()
    private(set) var lastNodes: [[String: Any]] = []
    private(set) var lastRead: [String: Any] = [:]
    private(set) var lastMenuTransition: [String: Any] = [:]
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
    private func nodes(_ root: AXUIElement, _ deadline: TimeInterval) throws -> [(AXUIElement, [AXUIElement], String?, String?, String?)] {
        var pending: [(AXUIElement, [AXUIElement])] = [(root, [])]
        var result: [(AXUIElement, [AXUIElement], String?, String?, String?)] = []
        lastNodes = []
        while let (element, ancestors) = pending.popLast() {
            try check(deadline)
            guard !result.contains(where: { CFEqual($0.0, element) }) else { continue }
            guard result.count < 2_048, ancestors.count <= 48 else { throw RuneWorkspaceVisibilityFailure("Naming AX exceeded its node/depth bounds.") }
            let identifier = try string(element, kAXIdentifierAttribute, deadline)
            let role = try string(element, kAXRoleAttribute, deadline)
            let title = try string(element, kAXTitleAttribute, deadline)
            result.append((element, ancestors, identifier, role, title))
            if lastNodes.count < 64 {
                lastNodes.append(["identifier": identifier.map { $0 as Any } ?? NSNull(), "role": role.map { $0 as Any } ?? NSNull(),
                                  "title": title.map { $0 as Any } ?? NSNull(), "depth": ancestors.count])
            }
            let next = try children(element, kAXChildrenAttribute, limit: 2_048 - result.count - pending.count, deadline)
            pending.append(contentsOf: next.reversed().map { ($0, ancestors + [element]) })
        }
        return result
    }
    func required(identifier: String, inSheet: Bool = false) async throws -> AXUIElement {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            let main = try ownedWindow(deadline)
            let tree = try nodes(main, deadline)
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
    func pressOwned(_ element: AXUIElement, role: String) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let main = try ownedWindow(deadline)
        guard try nodes(main, deadline).contains(where: { CFEqual($0.0, element) }) else { throw RuneWorkspaceVisibilityFailure("The exact naming control left the owned window graph.") }
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

    func openOwnedMenuAndPressNativeRename(_ opener: AXUIElement, capture: RuneWorkspaceNativeNamingMenuCapture) async throws {
        guard capture.requestedCommand == "Rename Layout…" else { throw RuneWorkspaceVisibilityFailure("The original native Rename route requires its literal Rename command.") }
        try await openOwnedMenuAndPressNativeNamingCommand(opener, capture: capture)
    }

    func openOwnedMenuAndPressNativeNamingCommand(_ opener: AXUIElement, capture: RuneWorkspaceNativeNamingMenuCapture) async throws {
        try capture.startAttempt()
        let deadline = capture.deadline
        let expectedWindow = try ownedWindow(deadline)
        guard try nodes(expectedWindow, deadline).contains(where: { CFEqual($0.0, opener) }) else {
            throw RuneWorkspaceVisibilityFailure("The independent native menu route lost its exact owned opener before arming.")
        }
        NotificationCenter.default.addObserver(capture, selector: #selector(RuneWorkspaceNativeNamingMenuCapture.didBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        let timer = Timer(timeInterval: 0.02, target: capture, selector: #selector(RuneWorkspaceNativeNamingMenuCapture.fire(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate(); capture.stop() }
        capture.armed = true
        try openOwnedMenu(opener, deadline: deadline) { action, status in capture.noteOpener(action: action, status: status) }
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
                               recordStatus: @escaping (String, Int32) -> Void) throws {
        let main = try ownedWindow(deadline)
        guard try nodes(main, deadline).contains(where: { CFEqual($0.0, opener) }) else { throw RuneWorkspaceVisibilityFailure("The actual layout menu left the owned window graph.") }
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
        return value
    }
    func noteOpener(action: String, status: Int32) {
        record["actual_opener_action"] = action; record["actual_opener_status"] = status
    }
    private func requireOwner() throws -> (NSWindow, NSView) {
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let window, let hosting, window.contentView === hosting, hosting.window === window,
              window.isVisible, !hosting.isHiddenOrHasHiddenAncestor else {
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
            guard items.filter({ $0.title == expectedName }).count == 1,
                  commands.allSatisfy({ title in items.filter({ $0.title == title }).count == 1 }),
                  let index = items.firstIndex(where: { $0.title == requestedCommand }),
                  items[index].isEnabled, !items[index].isHidden, !items[index].isSeparatorItem,
                  items[index].submenu == nil, items[index].action != nil else {
                throw RuneWorkspaceVisibilityFailure("The single captured menu did not prove the exact fixture layout marker and enabled literal workspace naming command.")
            }
            record["scope_marker_exact"] = expectedName
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
            menu.cancelTracking()
            record["qualified_native_menu_cancel_tracking_returned"] = true
            result = .success(()); timer.invalidate()
        } catch {
            record["callback_error"] = String(String(describing: error).prefix(4_096))
            result = .failure(error); timer.invalidate()
        }
    }
    func stop() {
        armed = false
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        actualMenu = nil; notification = nil
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
