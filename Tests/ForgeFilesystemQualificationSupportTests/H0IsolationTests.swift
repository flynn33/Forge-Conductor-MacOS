import Foundation
import XCTest

final class H0IsolationTests: XCTestCase {
    private var repository: URL {
        URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testQualificationTargetsAreNotShippingProducts() throws {
        let package = try text("Package.swift")
        let productBoundary = try XCTUnwrap(package.range(of: "    targets: ["))
        let products = String(package[..<productBoundary.lowerBound])

        XCTAssertFalse(products.contains("ForgeFilesystemQualification"))
        XCTAssertFalse(products.contains("ForgeFilesystemAdversary"))
        XCTAssertTrue(package.contains("name: \"ForgeFilesystemQualificationSupport\""))
        XCTAssertTrue(package.contains("name: \"ForgeFilesystemQualificationHarness\""))
        XCTAssertTrue(package.contains("name: \"ForgeFilesystemAdversary\""))
    }

    func testQualificationTargetsAreNotEmbeddedOrDaemonAuthorized() throws {
        let project = try text("ForgeConductor.xcodeproj/project.pbxproj")
        let copyStart = try XCTUnwrap(project.range(of: "/* Begin PBXCopyFilesBuildPhase section */"))
        let copyEnd = try XCTUnwrap(project.range(of: "/* End PBXCopyFilesBuildPhase section */"))
        let copyPhases = String(project[copyStart.lowerBound ..< copyEnd.upperBound])
        XCTAssertFalse(copyPhases.contains("qualification-harness"))
        XCTAssertFalse(copyPhases.contains("qualification-adversary"))

        let appStart = try XCTUnwrap(
            project.range(of: "D574F9BCA1204936B158984B /* ForgeConductor */ = {")
        )
        let targetsEnd = try XCTUnwrap(project.range(of: "/* End PBXNativeTarget section */"))
        let appTarget = String(project[appStart.lowerBound ..< targetsEnd.lowerBound])
        XCTAssertFalse(appTarget.contains("ForgeFilesystemQualificationSupport"))
        XCTAssertFalse(appTarget.contains("ForgeFilesystemQualificationHarness"))
        XCTAssertFalse(appTarget.contains("ForgeFilesystemAdversary"))

        let admission = try text(
            "Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift"
        )
        XCTAssertFalse(admission.contains("com.forge-conductor.qualification-harness"))
        XCTAssertFalse(admission.contains("com.forge-conductor.qualification-adversary"))
    }

    func testQualificationSchemeCannotArchiveTargets() throws {
        let scheme = try text(
            "ForgeConductor.xcodeproj/xcshareddata/xcschemes/ForgeFilesystemQualification.xcscheme"
        )
        XCTAssertEqual(scheme.components(separatedBy: "buildForArchiving = \"NO\"").count - 1, 3)
        XCTAssertFalse(scheme.contains("buildForArchiving = \"YES\""))
    }

    func testQualificationSettingsPreserveVersionContract() throws {
        let project = try text("ForgeConductor.xcodeproj/project.pbxproj")
        XCTAssertEqual(
            project.components(separatedBy: "MARKETING_VERSION = 0.9.0;").count - 1,
            12
        )
        for identifier in [
            "com.forge-conductor.qualification-harness",
            "com.forge-conductor.qualification-adversary",
        ] {
            XCTAssertEqual(project.components(separatedBy: identifier).count - 1, 2)
        }
    }

    func testCanonicalQualificationTemplateRemainsFullyNonpassing() throws {
        let templateURL = repository.appendingPathComponent(
            ".forge-codex/templates/p10-privileged-filesystem-qualification-report.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: templateURL)) as? [String: Any]
        )
        XCTAssertEqual(object["status"] as? String, "partial")
        XCTAssertEqual(object["ok"] as? Bool, false)

        let matrix = try XCTUnwrap(object["matrix"] as? [String: [String: Any]])
        XCTAssertEqual(matrix.count, 57)
        XCTAssertTrue(matrix.values.allSatisfy { row in
            guard let iterations = row["iterations"] as? [String: Any] else { return false }
            return row["status"] as? String == "not_run"
                && iterations["executed"] as? Int == 0
                && iterations["conclusive"] as? Int == 0
        })

        let formal = try XCTUnwrap(object["formal_closure"] as? [String: Any])
        let predicates = formal.values.compactMap { $0 as? Bool }
        XCTAssertEqual(predicates.count, 12)
        XCTAssertTrue(predicates.allSatisfy { !$0 })
    }
}
