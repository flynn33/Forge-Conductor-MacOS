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

    func testAdmissionProbeRemainsReadOnlyAndQualificationTargetOnly() throws {
        let source = try text(
            "Sources/ForgeFilesystemQualificationSupport/UnauthorizedAdmissionProbe.swift"
        )
        XCTAssertEqual(
            source.components(separatedBy: "proxy.serviceInfo").count - 1,
            1
        )
        XCTAssertFalse(source.contains("ForgeFilesystemServiceXPC.self"))
        for forbidden in [
            "deleteLeaf(",
            "queryTransaction(",
            "resumeTransaction(",
            "acknowledgeTransaction(",
            "authorizedRoot",
            "FileHandle",
        ] {
            XCTAssertFalse(source.contains(forbidden), "unexpected surface: \(forbidden)")
        }

        let project = try text("ForgeConductor.xcodeproj/project.pbxproj")
        let buildFileID = "E2A000000000000000000009"
        XCTAssertEqual(
            project.components(separatedBy: buildFileID).count - 1,
            2,
            "probe source must have one build-file definition and one source-phase membership"
        )
        let supportPhaseStart = try XCTUnwrap(
            project.range(of: "E2A000000000000000000050 /* Sources */ = {")
        )
        let supportPhaseTail = project[supportPhaseStart.lowerBound...]
        let supportPhaseEnd = try XCTUnwrap(
            supportPhaseTail.range(of: "\t\t};")
        )
        let supportPhase = String(supportPhaseTail[..<supportPhaseEnd.upperBound])
        XCTAssertTrue(supportPhase.contains(buildFileID))
    }

    func testAuthorizedHealthProbeExposesOnlyReadOnlyXPCSelectors() throws {
        let source = try text(
            "Sources/ForgeConductorCore/Infrastructure/SecureFilesystemQualificationHealthSession.swift"
        )
        let protocolStart = try XCTUnwrap(
            source.range(of: "@objc private protocol SecureFilesystemQualificationHealthXPC")
        )
        let protocolTail = source[protocolStart.lowerBound...]
        let protocolEnd = try XCTUnwrap(protocolTail.range(of: "\n}"))
        let protocolSource = String(protocolTail[..<protocolEnd.upperBound])

        XCTAssertEqual(
            protocolSource.components(separatedBy: "func serviceInfo").count - 1,
            1
        )
        XCTAssertEqual(
            protocolSource.components(separatedBy: "func status").count - 1,
            1
        )
        for forbidden in [
            "deleteLeaf",
            "queryTransaction",
            "resumeTransaction",
            "acknowledgeTransaction",
            "authorizedRoot",
            "FileHandle",
        ] {
            XCTAssertFalse(
                protocolSource.contains(forbidden),
                "authorized health XPC exposed mutation surface: \(forbidden)"
            )
        }

        let project = try text("ForgeConductor.xcodeproj/project.pbxproj")
        let buildFileID = "E2F500000000000000000052"
        XCTAssertEqual(
            project.components(separatedBy: buildFileID).count - 1,
            2,
            "health source must have one build-file definition and one Core source-phase membership"
        )
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
        XCTAssertEqual(
            project.components(separatedBy: "CURRENT_PROJECT_VERSION = 1;").count - 1,
            16
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
