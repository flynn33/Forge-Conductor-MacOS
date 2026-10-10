import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class NativeWorkspacePreferencesTests: XCTestCase {
    private let knownPanelsByView: [String: Set<String>] = [
        "rig": ["rig-compute-cores-panel", "rig-mcp-servers-panel"],
        "projects": ["project-workflow-actions", "project-instruction-packages"],
    ]

    private var strictBounds: [String: [String: NativeWorkspacePanelSizeBounds]] {
        let bounds = NativeWorkspacePanelSizeBounds(minimumWidth: 280, minimumHeight: 160,
                                                    maximumWidth: 960, maximumHeight: 640)
        return ["rig": Dictionary(uniqueKeysWithValues: knownPanelsByView["rig", default: []].map { ($0, bounds) })]
    }

    private func layout(viewID: String = "rig", name: String = "Focus") -> NativeWorkspaceLayout {
        let panels = knownPanelsByView[viewID, default: []].sorted()
        return NativeWorkspaceLayout(id: UUID(), viewID: viewID, name: name,
            canvas: .init(width: 1_100, height: 720), panels: panels.enumerated().map { index, id in
                .init(id: id, frame: .init(x: Double(index) * 530 + 10, y: 10, width: 500, height: 240), isVisible: true)
            })
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "forge.workspace.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testMissingPreferencesUseEachExistingDefaultWithoutWritingAKey() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            XCTAssertNil(owner.activeLayout(for: "rig"))
            XCTAssertNil(owner.activeLayout(for: "projects"))
            XCTAssertTrue(owner.collection.layouts.isEmpty)
            XCTAssertNil(owner.restorationError)
            XCTAssertNil(defaults.object(forKey: NativeWorkspacePreferences.storageKey))
        }
    }

    func testEveryCurrentViewCatalogSeedsAndRestoresWithinItsOwnBounds() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(
                knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            XCTAssertEqual(NativeWorkspaceCatalog.panelsByView.count, 24)
            for (viewID, descriptors) in NativeWorkspaceCatalog.panelsByView {
                XCTAssertFalse(descriptors.isEmpty, viewID)
                XCTAssertEqual(Set(descriptors.map(\.id)).count, descriptors.count, viewID)
                let canvas = NativeWorkspaceCanvas(
                    width: max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                    height: max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0))
                let layout = NativeWorkspaceLayout(id: UUID(), viewID: viewID, name: "Custom", canvas: canvas,
                    panels: descriptors.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
                try owner.save(layout)
                XCTAssertEqual(owner.activeLayout(for: viewID), layout)
            }
            let reopened = NativeWorkspacePreferences(
                knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            XCTAssertNil(reopened.restorationError)
            XCTAssertEqual(reopened.collection, owner.collection)
        }
    }

    func testSelectionsAndSameNamesRoundTripIndependentlyPerView() throws {
        try withDefaults { defaults in
            defaults.set("untouched", forKey: "manager.fixture")
            defaults.set(true, forKey: "forge.workbench.control.guide.v1")
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            let rig = layout()
            let projects = layout(viewID: "projects")
            try owner.save(rig)
            try owner.save(projects)
            let reopened = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            XCTAssertEqual(reopened.activeLayout(for: "rig"), rig)
            XCTAssertEqual(reopened.activeLayout(for: "projects"), projects)
            try reopened.reset("rig")
            let defaultOwner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            XCTAssertNil(defaultOwner.activeLayout(for: "rig"))
            XCTAssertEqual(defaultOwner.activeLayout(for: "projects"), projects)
            XCTAssertEqual(defaultOwner.layouts(for: "rig"), [rig])
            XCTAssertEqual(defaults.string(forKey: "manager.fixture"), "untouched")
            XCTAssertTrue(defaults.bool(forKey: "forge.workbench.control.guide.v1"))
        }
    }

    func testMoveResizeHideAndFrontOrderRetainPanelAndLayoutIdentities() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            let saved = layout()
            try owner.save(saved)
            let frame = NativeWorkspaceFrame(x: 20, y: 300, width: 700, height: 300)
            try owner.setFrame(frame, for: "rig-compute-cores-panel", in: "rig")
            try owner.setShown(false, for: "rig-compute-cores-panel", in: "rig")
            try owner.bringToFront("rig-compute-cores-panel", in: "rig")
            let updated = try XCTUnwrap(owner.activeLayout(for: "rig"))
            XCTAssertEqual(updated.id, saved.id)
            XCTAssertEqual(Set(updated.panels.map(\.id)), Set(saved.panels.map(\.id)))
            XCTAssertEqual(updated.panels.last?.id, "rig-compute-cores-panel")
            XCTAssertEqual(updated.panels.last?.frame, frame)
            XCTAssertEqual(updated.panels.last?.isVisible, false)
            XCTAssertEqual(NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults).activeLayout(for: "rig"), updated)
            // Value identity only; native control-state retention is a separate gate.
        }
    }

    func testInvalidEditsNeverReplacePublishedOrStoredState() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            try owner.save(layout())
            let before = owner.collection
            let bytes = defaults.data(forKey: NativeWorkspacePreferences.storageKey)
            for value in [Double.nan, .infinity, -1, 32_769] {
                XCTAssertThrowsError(try owner.setFrame(.init(x: value, y: 0, width: 100, height: 100), for: "rig-compute-cores-panel", in: "rig"))
                XCTAssertEqual(owner.collection, before)
                XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
            }
            XCTAssertThrowsError(try owner.activate(UUID(), for: "rig"))
            XCTAssertThrowsError(try owner.setShown(false, for: "missing", in: "rig"))
            XCTAssertEqual(owner.collection, before)
            XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
        }
    }

    func testCrossViewPanelSelectionAndIDReassignmentAreRejected() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            let rig = layout()
            let projects = layout(viewID: "projects")
            try owner.save(rig)
            try owner.save(projects)
            let before = owner.collection
            XCTAssertThrowsError(try owner.activate(projects.id, for: "rig")) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .layoutViewMismatch) }
            var wrongPanel = rig
            wrongPanel.panels[0] = projects.panels[0]
            XCTAssertThrowsError(try owner.save(wrongPanel)) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .unknownPanelID) }
            let reassigned = NativeWorkspaceLayout(id: rig.id, viewID: "projects", name: "Reassigned", canvas: projects.canvas, panels: projects.panels)
            XCTAssertThrowsError(try owner.save(reassigned)) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .layoutViewMismatch) }
            XCTAssertEqual(owner.collection, before)
        }
    }

    func testDuplicatePanelIdentitiesAndExactPanelLimit() throws {
        var duplicate = layout()
        duplicate.panels.append(duplicate.panels[0])
        XCTAssertThrowsError(try duplicate.validate(knownPanelIDsByView: knownPanelsByView)) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .duplicatePanelID) }
        let ids = Set((0..<64).map { "panel.\($0)" })
        var saved = layout()
        saved.panels = ids.sorted().map { .init(id: $0, frame: .init(x: 0, y: 0, width: 64, height: 64), isVisible: true) }
        try saved.validate(knownPanelIDsByView: ["rig": ids])
        saved.panels.append(.init(id: "panel.64", frame: .init(x: 0, y: 0, width: 64, height: 64), isVisible: true))
        XCTAssertThrowsError(try saved.validate(knownPanelIDsByView: ["rig": ids.union(["panel.64"])])) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .tooManyPanels) }
    }

    func testMissingRegisteredPanelCannotBeSaved() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            var missing = layout()
            missing.panels.removeLast()
            XCTAssertThrowsError(try owner.save(missing)) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .missingPanel) }
            XCTAssertTrue(owner.collection.layouts.isEmpty)
            XCTAssertNil(defaults.object(forKey: NativeWorkspacePreferences.storageKey))
        }
    }

    func testIDAndGeometryBoundsIncludeExactEndpoints() throws {
        let longestID = String(repeating: "a", count: 64)
        XCTAssertTrue(NativeWorkspacePanelPlacement.isValidID(longestID))
        XCTAssertFalse(NativeWorkspacePanelPlacement.isValidID(longestID + "a"))
        for id in ["", "Panel", "panel id", "panel_id", "panel\u{0}"] {
            XCTAssertFalse(NativeWorkspacePanelPlacement.isValidID(id))
        }
        let canvas = NativeWorkspaceCanvas(width: 32_768, height: 32_768)
        try NativeWorkspaceFrame(x: 32_704, y: 32_704, width: 64, height: 64).validate(in: canvas)
        try NativeWorkspaceFrame(x: 30_368, y: 30_368, width: 2_400, height: 2_400).validate(in: canvas)
        XCTAssertThrowsError(try NativeWorkspaceFrame(x: 32_705, y: 0, width: 64, height: 64).validate(in: canvas))
        XCTAssertThrowsError(try NativeWorkspaceFrame(x: 0, y: 0, width: 63, height: 64).validate(in: canvas))
        XCTAssertThrowsError(try NativeWorkspaceFrame(x: 0, y: 0, width: 2_401, height: 64).validate(in: canvas))
        XCTAssertThrowsError(try NativeWorkspaceFrame(x: 0, y: 0, width: 64, height: 2_401).validate(in: canvas))
        XCTAssertThrowsError(try NativeWorkspaceCanvas(width: 32_769, height: 64).validate())
    }

    func testOversizedPersistedPanelIsRejectedWithoutConstructingAHostOrReplacingBytes() throws {
        try withDefaults { defaults in
            var oversized = layout()
            oversized.canvas = .init(width: 32_768, height: 32_768)
            oversized.panels[0].frame = .init(x: 0, y: 0, width: 32_768, height: 32_768)
            var saved = NativeWorkspaceCollection()
            saved.layouts = [oversized]
            saved.activeLayoutIDs = ["rig": oversized.id]
            let bytes = try JSONEncoder().encode(saved)
            defaults.set(bytes, forKey: NativeWorkspacePreferences.storageKey)
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            XCTAssertEqual(owner.restorationError, .invalidGeometry)
            XCTAssertNil(owner.activeLayout(for: "rig"))
            XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
        }
    }

    func testDescriptorMinimumRejectsPersistedFrameAndRetainsOriginalBytes() throws {
        try withDefaults { defaults in
            var undersized = layout()
            undersized.panels[0].frame = .init(x: 0, y: 0, width: 64, height: 64)
            var saved = NativeWorkspaceCollection()
            saved.layouts = [undersized]
            saved.activeLayoutIDs = ["rig": undersized.id]
            let bytes = try JSONEncoder().encode(saved)
            defaults.set(bytes, forKey: NativeWorkspacePreferences.storageKey)
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView,
                                                   panelSizeBoundsByView: strictBounds, defaults: defaults)
            XCTAssertEqual(owner.restorationError, .invalidGeometry)
            XCTAssertNil(owner.activeLayout(for: "rig"))
            XCTAssertTrue(owner.layouts(for: "rig").isEmpty)
            XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
        }
    }

    func testDescriptorEndpointsAndInvalidEditsAreTransactional() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView,
                                                   panelSizeBoundsByView: strictBounds, defaults: defaults)
            try owner.save(layout())
            try owner.setFrame(.init(x: 0, y: 0, width: 280, height: 160), for: "rig-compute-cores-panel", in: "rig")
            try owner.setFrame(.init(x: 0, y: 0, width: 960, height: 640), for: "rig-compute-cores-panel", in: "rig")
            let before = owner.collection
            let bytes = defaults.data(forKey: NativeWorkspacePreferences.storageKey)
            let invalid: [NativeWorkspaceFrame] = [
                .init(x: 0, y: 0, width: 279, height: 160), .init(x: 0, y: 0, width: 280, height: 159),
                .init(x: 0, y: 0, width: 961, height: 160), .init(x: 0, y: 0, width: 280, height: 641),
            ]
            for frame in invalid {
                XCTAssertThrowsError(try owner.setFrame(frame, for: "rig-compute-cores-panel", in: "rig")) {
                    XCTAssertEqual($0 as? NativeWorkspaceValidationError, .invalidGeometry)
                }
                XCTAssertEqual(owner.collection, before)
                XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
            }
        }
    }

    func testDescriptorBoundedNamedSelectionsSurviveReloadWithinEachView() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView,
                                                   panelSizeBoundsByView: strictBounds, defaults: defaults)
            var small = layout(name: "Small")
            small.panels[0].frame = .init(x: 0, y: 0, width: 280, height: 160)
            var large = layout(name: "Large")
            large.panels[0].frame = .init(x: 0, y: 0, width: 960, height: 640)
            let projects = layout(viewID: "projects")
            try owner.save(small)
            try owner.save(large)
            try owner.save(projects)
            try owner.activate(small.id, for: "rig")
            let reopened = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView,
                                                      panelSizeBoundsByView: strictBounds, defaults: defaults)
            XCTAssertEqual(reopened.activeLayout(for: "rig"), small)
            XCTAssertEqual(reopened.activeLayout(for: "projects"), projects)
            try reopened.activate(large.id, for: "rig")
            XCTAssertEqual(reopened.activeLayout(for: "rig"), large)
            XCTAssertEqual(reopened.activeLayout(for: "projects"), projects)
        }
    }

    func testInvalidDescriptorRegistryCannotPublishStoredLayouts() throws {
        try withDefaults { defaults in
            let generic = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            try generic.save(layout())
            let bytes = defaults.data(forKey: NativeWorkspacePreferences.storageKey)
            let invalid = [
                NativeWorkspacePanelSizeBounds(minimumWidth: .nan),
                NativeWorkspacePanelSizeBounds(minimumWidth: 500, maximumWidth: 400),
                NativeWorkspacePanelSizeBounds(maximumHeight: 2_401),
            ]
            for bounds in invalid {
                let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView,
                    panelSizeBoundsByView: ["rig": ["rig-compute-cores-panel": bounds]], defaults: defaults)
                XCTAssertEqual(owner.restorationError, .invalidGeometry)
                XCTAssertNil(owner.activeLayout(for: "rig"))
                XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
            }
            let unknown = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView,
                panelSizeBoundsByView: ["rig": ["unknown": .init()]], defaults: defaults)
            XCTAssertEqual(unknown.restorationError, .unknownPanelID)
            XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
        }
    }

    func testSaveAsRenameLimitCollisionAndDeletionRemainViewScoped() throws {
        try withDefaults { defaults in
            let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            let rig = layout()
            try owner.save(rig)
            let copiedID = try owner.saveAs(rig, named: "Copy")
            XCTAssertNotEqual(copiedID, rig.id)
            try owner.rename(copiedID, to: "Renamed", for: "rig")
            XCTAssertEqual(owner.activeLayout(for: "rig")?.name, "Renamed")
            XCTAssertThrowsError(try owner.rename(copiedID, to: "FOCUS", for: "rig")) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .duplicateName) }
            let projects = layout(viewID: "projects")
            try owner.save(projects)
            XCTAssertThrowsError(try owner.delete(copiedID, for: "projects"))
            try owner.delete(copiedID, for: "rig")
            XCTAssertNil(owner.activeLayout(for: "rig"))
            XCTAssertEqual(owner.activeLayout(for: "projects"), projects)
            while owner.collection.layouts.count < 32 { try owner.save(layout(name: "Layout \(owner.collection.layouts.count)")) }
            let before = owner.collection
            XCTAssertThrowsError(try owner.save(layout(name: "Overflow"))) { XCTAssertEqual($0 as? NativeWorkspaceValidationError, .tooManyLayouts) }
            XCTAssertEqual(owner.collection, before)
            try owner.rename(try XCTUnwrap(owner.activeLayout(for: "rig")).id, to: "At capacity", for: "rig")
            XCTAssertEqual(owner.collection.layouts.count, 32)
        }
    }

    func testNamesUseExplicitUTF8AndControlCharacterBounds() throws {
        try layout(name: String(repeating: "é", count: 48)).validate(knownPanelIDsByView: knownPanelsByView)
        for name in ["", " leading", "trailing ", "line\nbreak", String(repeating: "é", count: 49)] {
            XCTAssertThrowsError(try layout(name: name).validate(knownPanelIDsByView: knownPanelsByView)) {
                XCTAssertEqual($0 as? NativeWorkspaceValidationError, .invalidName)
            }
        }
    }

    func testInvalidAndFutureStorageFallsBackWithoutDestroyingOriginalBytes() throws {
        try withDefaults { defaults in
            var future = NativeWorkspaceCollection()
            future.schemaVersion = 2
            let rig = layout()
            var crossView = NativeWorkspaceCollection()
            crossView.layouts = [rig]
            crossView.activeLayoutIDs = ["projects": rig.id]
            var unknown = NativeWorkspaceCollection()
            unknown.layouts = [NativeWorkspaceLayout(id: UUID(), viewID: "unknown", name: "Unknown", canvas: rig.canvas, panels: [])]
            var missing = NativeWorkspaceCollection()
            var incomplete = rig
            incomplete.panels.removeLast()
            missing.layouts = [incomplete]
            let cases = [Data("malformed".utf8), try JSONEncoder().encode(future),
                         Data(repeating: 0, count: NativeWorkspaceLimits.maximumStoredBytes + 1),
                         try JSONEncoder().encode(crossView), try JSONEncoder().encode(unknown),
                         try JSONEncoder().encode(missing)]
            let errors: [NativeWorkspaceValidationError] = [.invalidStoredData, .unsupportedSchema, .oversizedStorage,
                                                           .layoutViewMismatch, .unknownViewID, .missingPanel]
            for (bytes, error) in zip(cases, errors) {
                defaults.set(bytes, forKey: NativeWorkspacePreferences.storageKey)
                let owner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
                XCTAssertNil(owner.activeLayout(for: "rig"))
                XCTAssertEqual(owner.restorationError, error)
                XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
            }
            let recovery = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            XCTAssertEqual(recovery.restorationError, .missingPanel)
            try recovery.reset("rig")
            XCTAssertNil(recovery.restorationError)
            XCTAssertNotEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), cases.last)
            let reopened = NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: defaults)
            XCTAssertNil(reopened.restorationError)
            XCTAssertNil(reopened.activeLayout(for: "rig"))
        }
    }

    func testPreferencesRemainIsolatedBetweenInjectedSuites() throws {
        try withDefaults { first in
            try withDefaults { second in
                try NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: first).save(layout())
                XCTAssertNotNil(NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: first).activeLayout(for: "rig"))
                XCTAssertNil(NativeWorkspacePreferences(knownPanelIDsByView: knownPanelsByView, defaults: second).activeLayout(for: "rig"))
                XCTAssertNil(second.object(forKey: NativeWorkspacePreferences.storageKey))
            }
        }
    }
}
