import Darwin
import Foundation
import ForgeFilesystemProtocol
import Security
import XCTest
@testable import ForgeConductorCore

/// Pure fixtures cover policy and metadata checks. Signed CLI/app parent-child
/// qualification remains a separate native gate.
final class OwnedCurrentSelfAdmissionTests: XCTestCase {
    private let mainHash = String(repeating: "ab", count: 20)
    private let coreHash = String(repeating: "cd", count: 20)
    private let cli = URL(fileURLWithPath: "/fixture/Forge Conductor.app/Contents/Helpers/forge-conductor")

    private func identity(
        role: OwnedNativeExecutableRole = .cli,
        identifier: String? = nil,
        cdhash: String? = nil,
        executable: URL? = nil,
        coreIdentifier: String? = nil,
        coreCDHash: String? = nil,
        coreExecutable: URL? = nil
    ) -> OwnedCurrentSelfIdentity {
        OwnedCurrentSelfIdentity(
            executable: executable ?? cli,
            role: role, identifier: identifier ?? role.identifier, cdhash: cdhash ?? mainHash,
            coreArtifact: OwnedCoreArtifactIdentity(
                executable: coreExecutable ?? URL(fileURLWithPath:
                    "/fixture/Forge Conductor.app/Contents/Frameworks/ForgeConductorCore.framework/Versions/A/ForgeConductorCore"),
                identifier: coreIdentifier ?? ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
                cdhash: coreCDHash ?? coreHash
            )
        )
    }

    private func metadata() -> [CFString: Any] {
        [
            kSecCodeInfoIdentifier: ForgeFilesystemProtocolConstants.managerIdentifier,
            kSecCodeInfoTeamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
            kSecCodeInfoFlags: NSNumber(value: UInt32(0)),
            kSecCodeInfoUnique: Data(repeating: 0xab, count: 20),
            kSecCodeInfoMainExecutable: cli,
        ]
    }

    private func expect(
        _ expected: OwnedCurrentSelfAdmissionError,
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? OwnedCurrentSelfAdmissionError, expected, file: file, line: line)
        }
    }

    func testCompiledExactRequirementsPreserveActiveRoleTeamAndCertificateClass() throws {
        for role in [OwnedNativeExecutableRole.cli, .app] {
            let compiled = try XCTUnwrap(ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: role.identifier, teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier
            ))
            XCTAssertEqual(
                try OwnedCurrentSelfAdmission.exactRequirementText(role: role, cdhash: mainHash),
                "(\(compiled)) and cdhash H\"\(mainHash)\""
            )
            XCTAssertTrue(compiled.contains("anchor apple generic"))
            XCTAssertTrue(compiled.contains("identifier \"\(role.identifier)\""))
            XCTAssertTrue(compiled.contains("certificate leaf[subject.OU] = \"\(ForgeFilesystemProtocolConstants.activeTeamIdentifier)\""))
            #if DEBUG || FORGE_DEVELOPMENT_SIGNING
            XCTAssertTrue(compiled.contains("1.2.840.113635.100.6.1.12"))
            XCTAssertFalse(compiled.contains("1.2.840.113635.100.6.1.13"))
            #else
            XCTAssertTrue(compiled.contains("1.2.840.113635.100.6.1.13"))
            XCTAssertFalse(compiled.contains("1.2.840.113635.100.6.1.12"))
            #endif
        }
    }

    func testOnlyCLIAndAppAreCurrentExecutableRoles() throws {
        XCTAssertEqual(try OwnedCurrentSelfAdmission.executableRole(identifier: OwnedNativeExecutableRole.cli.identifier), .cli)
        XCTAssertEqual(try OwnedCurrentSelfAdmission.executableRole(identifier: OwnedNativeExecutableRole.app.identifier), .app)
        for identifier in ["", "com.forge-conductor.tests", "com.apple.dt.xctest.tool",
                           ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
                           ForgeFilesystemProtocolConstants.daemonIdentifier,
                           ForgeFilesystemProtocolConstants.runtimeLauncherIdentifier] {
            expect(.roleRejected) { _ = try OwnedCurrentSelfAdmission.executableRole(identifier: identifier) }
        }
    }

    func testCLIAndAppEntryRolesCannotBeExchanged() {
        expect(.roleMismatch) { _ = try OwnedCurrentSelfAdmission.executableRole(identifier: OwnedNativeExecutableRole.cli.identifier, expectedRole: .app) }
        expect(.roleMismatch) { _ = try OwnedCurrentSelfAdmission.executableRole(identifier: OwnedNativeExecutableRole.app.identifier, expectedRole: .cli) }
    }

    func testExactRequirementRejectsMalformedAndInjectedHashes() {
        for malformed in ["", String(repeating: "a", count: 39), String(repeating: "a", count: 41),
                          String(repeating: "g", count: 40), mainHash + "\" or true", mainHash + "\u{0}"] {
            expect(.invalidIdentity) { _ = try OwnedCurrentSelfAdmission.exactRequirementText(role: .cli, cdhash: malformed) }
        }
    }

    func testSigningMetadataRequiresEveryTypedField() throws {
        let valid = metadata()
        let decoded = try OwnedCurrentSelfAdmission.signingMetadata(in: valid)
        XCTAssertEqual(decoded.identifier, OwnedNativeExecutableRole.cli.identifier)
        XCTAssertEqual(decoded.cdhash, mainHash)
        XCTAssertEqual(decoded.executable, cli)
        let keys: [CFString] = [kSecCodeInfoIdentifier, kSecCodeInfoTeamIdentifier, kSecCodeInfoFlags,
                               kSecCodeInfoUnique, kSecCodeInfoMainExecutable]
        for key in keys {
            var missing = valid
            missing.removeValue(forKey: key)
            expect(.missingMetadata) { _ = try OwnedCurrentSelfAdmission.signingMetadata(in: missing) }
            missing[key] = key == kSecCodeInfoIdentifier || key == kSecCodeInfoTeamIdentifier
                ? NSNumber(value: 7) as Any : "wrong type" as Any
            expect(.missingMetadata) { _ = try OwnedCurrentSelfAdmission.signingMetadata(in: missing) }
        }
    }

    func testSigningMetadataRejectsAdHocAndOtherTeams() {
        var information = metadata()
        information[kSecCodeInfoFlags] = NSNumber(value: SecCodeSignatureFlags.adhoc.rawValue)
        expect(.missingMetadata) { _ = try OwnedCurrentSelfAdmission.signingMetadata(in: information) }
        for team in ["", "UNAPPROVED1", ForgeFilesystemProtocolConstants.productionTeamIdentifier] {
            information = metadata()
            information[kSecCodeInfoTeamIdentifier] = team
            expect(.missingMetadata) { _ = try OwnedCurrentSelfAdmission.signingMetadata(in: information) }
        }
    }

    func testSigningMetadataRejectsBadHashLengthAndNonFileExecutable() {
        for count in [0, 19, 21, 32] {
            var information = metadata()
            information[kSecCodeInfoUnique] = Data(repeating: 1, count: count)
            expect(.missingMetadata) { _ = try OwnedCurrentSelfAdmission.signingMetadata(in: information) }
        }
        var information = metadata()
        information[kSecCodeInfoMainExecutable] = URL(string: "https://example.invalid/forge-conductor")!
        expect(.missingMetadata) { _ = try OwnedCurrentSelfAdmission.signingMetadata(in: information) }
    }

    func testInternalIdentityRequiresCanonicalRoleAndHashFields() throws {
        try OwnedCurrentSelfAdmission.validateIdentityFields(identity())
        for invalid in [identity(identifier: OwnedNativeExecutableRole.app.identifier),
                        identity(cdhash: mainHash.uppercased()), identity(cdhash: ""),
                        identity(coreIdentifier: OwnedNativeExecutableRole.cli.identifier),
                        identity(coreCDHash: String(repeating: "0", count: 39)),
                        identity(executable: URL(string: "https://example.invalid/main")!),
                        identity(coreExecutable: URL(string: "https://example.invalid/core")!)] {
            expect(.invalidIdentity) { try OwnedCurrentSelfAdmission.validateIdentityFields(invalid) }
        }
    }

    func testChildMetadataRequiresExactMainRoleAndHash() throws {
        let original = identity()
        try OwnedCurrentSelfAdmission.validateChildMetadata(.init(executable: cli, identifier: original.identifier, cdhash: mainHash), matching: original)
        for changed in [
            OwnedCurrentSelfAdmission.SigningMetadata(executable: cli, identifier: OwnedNativeExecutableRole.app.identifier, cdhash: mainHash),
            .init(executable: cli, identifier: original.identifier, cdhash: String(repeating: "00", count: 20)),
        ] {
            expect(.exactIdentityMismatch) { try OwnedCurrentSelfAdmission.validateChildMetadata(changed, matching: original) }
        }
    }

    func testInvalidChildPIDsRejectBeforeSecurityOrTaskNameLookup() {
        for pid in [Int32.min, -1, 0, getpid()] {
            expect(.invalidChildPID) { try OwnedCurrentSelfAdmission.validateOwnedChild(pid: pid, matching: identity()) }
        }
        XCTAssertNoThrow(try OwnedCurrentSelfAdmission.validateChildPID(42, currentPID: 43))
    }

    func testCoreArtifactSnapshotRequiresExactNamedExecutableRoleAndHash() throws {
        let expected = identity().coreArtifact
        try OwnedCurrentSelfAdmission.validateCoreArtifactSnapshot(observed: expected, expected: expected)
        for changed in [
            OwnedCoreArtifactIdentity(executable: URL(fileURLWithPath: "/other/ForgeConductorCore"), identifier: expected.identifier, cdhash: expected.cdhash),
            .init(executable: expected.executable, identifier: OwnedNativeExecutableRole.cli.identifier, cdhash: expected.cdhash),
            .init(executable: expected.executable, identifier: expected.identifier, cdhash: String(repeating: "00", count: 20)),
        ] {
            expect(.exactIdentityMismatch) { try OwnedCurrentSelfAdmission.validateCoreArtifactSnapshot(observed: changed, expected: expected) }
        }
    }

    func testAuditSelectionRejectsWrongOrNonpositivePID() {
        XCTAssertNoThrow(try OwnedCurrentSelfAdmission.validateAuditSelection(requestedPID: 42, tokenPID: 42))
        let pairs: [(Int32, Int32)] = [(42, 43), (0, 0), (-1, -1), (42, 0)]
        for (requested, observed) in pairs {
            expect(.auditTokenMismatch) { try OwnedCurrentSelfAdmission.validateAuditSelection(requestedPID: requested, tokenPID: observed) }
        }
    }

    func testAuditVersionMustStayEqualWithoutAssumingPositiveVersion() {
        XCTAssertNoThrow(try OwnedCurrentSelfAdmission.validateAuditVersion(initial: 0, observed: 0))
        XCTAssertNoThrow(try OwnedCurrentSelfAdmission.validateAuditVersion(initial: 123, observed: 123))
        expect(.auditTokenMismatch) { try OwnedCurrentSelfAdmission.validateAuditVersion(initial: 123, observed: 124) }
    }

    func testAssociatedFrameworkLocationsAreFixedByExecutableRole() {
        let app = URL(fileURLWithPath: "/fixture/Forge Conductor.app/Contents/MacOS/Forge Conductor")
        let framework = URL(fileURLWithPath: "/fixture/Forge Conductor.app/Contents/Frameworks/ForgeConductorCore.framework", isDirectory: true)
        XCTAssertEqual(OwnedCurrentSelfAdmission.associatedCoreLocations(executable: app, role: .app), [framework])
        XCTAssertEqual(OwnedCurrentSelfAdmission.associatedCoreLocations(executable: cli, role: .cli), [
            framework, cli.deletingLastPathComponent().appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        ])
        XCTAssertTrue(OwnedCurrentSelfAdmission.associatedCoreLocations(executable: cli, role: .app).isEmpty)
        let detached = URL(fileURLWithPath: "/fixture/bin/forge-conductor")
        XCTAssertEqual(OwnedCurrentSelfAdmission.associatedCoreLocations(executable: detached, role: .cli), [
            detached.deletingLastPathComponent().appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        ])
        XCTAssertTrue(OwnedCurrentSelfAdmission.associatedCoreLocations(executable: detached, role: .app).isEmpty)
    }

    func testFrameworkAssociationAllowsVersionedNativeBundleButRejectsResourceMasquerade() throws {
        let root = URL(fileURLWithPath: "/fixture/ForgeConductorCore.framework", isDirectory: true)
        XCTAssertEqual(try OwnedCurrentSelfAdmission.frameworkRoot(associatedBundle: root), root)
        XCTAssertEqual(try OwnedCurrentSelfAdmission.frameworkRoot(associatedBundle: root.appendingPathComponent("Versions/A", isDirectory: true)), root)
        for invalid in ["/fixture/ForgeConductor_ForgeConductorCore.bundle",
                        "/fixture/Other.framework", "/fixture/ForgeConductorCore.framework/Resources",
                        "/fixture/ForgeConductorCore.framework/A"] {
            expect(.associatedCoreUnavailable) { _ = try OwnedCurrentSelfAdmission.frameworkRoot(associatedBundle: URL(fileURLWithPath: invalid)) }
        }
    }

    func testCompiledCoreRequirementIsAnExactKnownProductRole() throws {
        let compiled = try XCTUnwrap(ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
            identifier: ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
            teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier
        ))
        XCTAssertTrue(compiled.contains("identifier \"com.forge-conductor.core\""))
        XCTAssertTrue(compiled.contains("certificate leaf[subject.OU] = \"\(ForgeFilesystemProtocolConstants.activeTeamIdentifier)\""))
        XCTAssertFalse(compiled.contains(" or "))
    }

    func testOrdinaryXCTestProcessCannotBeAdmittedAsCurrentCLI() {
        // A test host receives no shipping CLI-role signing exception.
        XCTAssertThrowsError(try OwnedCurrentSelfAdmission.current(expectedRole: .cli))
    }
}
