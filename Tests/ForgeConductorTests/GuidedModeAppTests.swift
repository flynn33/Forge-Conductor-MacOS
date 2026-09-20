import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif

@MainActor
final class GuidedModeAppTests: XCTestCase {
    func testEveryApplicationTabMapsToOneDistinctPrimaryGuide() {
        let contexts = AppModel.AppTab.allCases.map(\.guidedHelpContext)

        XCTAssertEqual(contexts.count, 14)
        XCTAssertEqual(Set(contexts).count, contexts.count)
        XCTAssertTrue(Set(contexts).isSubset(of: Set(GuidedHelpContext.allCases)))
    }

    func testBundledCatalogCoversEveryTypedContextAndValidAnchor() throws {
        let catalog = try GuidedHelpCatalog.bundled()

        XCTAssertNoThrow(try catalog.validate())
        XCTAssertEqual(Set(catalog.entries.map(\.context)), Set(GuidedHelpContext.allCases))
        for entry in catalog.entries {
            XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(entry.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(entry.forgeHandlesAutomatically.isEmpty)
            XCTAssertFalse(entry.controls.isEmpty)
            XCTAssertFalse(entry.statusMeanings.isEmpty)
            XCTAssertFalse(entry.normalWorkflow.isEmpty)
            XCTAssertFalse(entry.troubleshooting.isEmpty)
            XCTAssertFalse(entry.advancedDetails.isEmpty)
            XCTAssertTrue(entry.controlAnchors.allSatisfy(GuidedControlAnchor.isKnown))
        }
    }

    func testNestedGuideContextOverridesTabAndRestoresWithoutMutatingEnablement() {
        let suiteName = "GuidedModeAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = GuidedModeCoordinator(defaults: defaults)

        XCTAssertFalse(coordinator.isEnabled)
        coordinator.isEnabled = true
        coordinator.select(.autonomy)
        let startToken = coordinator.push(.autonomyStartTask)
        let toolsToken = coordinator.push(.autonomyToolSelection)

        XCTAssertEqual(coordinator.currentContext, .autonomyToolSelection)
        coordinator.pop(toolsToken)
        XCTAssertEqual(coordinator.currentContext, .autonomyStartTask)
        coordinator.pop(startToken)
        XCTAssertEqual(coordinator.currentContext, .autonomy)
        XCTAssertTrue(GuidedModeCoordinator(defaults: defaults).isEnabled)
    }
}
