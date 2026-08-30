import Foundation
import XCTest
import ForgeFilesystemProtocol

final class ForgeFilesystemProtocolTests: XCTestCase {
    func testServiceInfoSecureCodingAndExactRuntimeMatch() throws {
        let executableSHA256 = String(repeating: "a", count: 64)
        let expected = ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 0,
            executableSHA256: executableSHA256
        )
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: expected,
            requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemServiceInfo.self,
                from: data
            )
        )

        XCTAssertTrue(decoded.matchesExpectedService(executableSHA256: executableSHA256))
        XCTAssertEqual(decoded.protocolVersion, ForgeFilesystemProtocolConstants.version)
        XCTAssertEqual(decoded.productVersion, ForgeFilesystemProtocolConstants.productVersion)
        XCTAssertEqual(decoded.serviceIdentifier, ForgeFilesystemProtocolConstants.daemonIdentifier)
        XCTAssertEqual(decoded.effectiveUserIdentifier, 0)
        XCTAssertEqual(decoded.executableSHA256, executableSHA256)

        XCTAssertFalse(ForgeFilesystemServiceInfo(
            protocolVersion: ForgeFilesystemProtocolConstants.version + 1,
            effectiveUserIdentifier: 0,
            executableSHA256: executableSHA256
        ).matchesExpectedService(executableSHA256: executableSHA256))
        XCTAssertFalse(ForgeFilesystemServiceInfo(
            productVersion: "0.8.0",
            effectiveUserIdentifier: 0,
            executableSHA256: executableSHA256
        ).matchesExpectedService(executableSHA256: executableSHA256))
        XCTAssertFalse(ForgeFilesystemServiceInfo(
            serviceIdentifier: "com.example.wrong-daemon",
            effectiveUserIdentifier: 0,
            executableSHA256: executableSHA256
        ).matchesExpectedService(executableSHA256: executableSHA256))
        XCTAssertFalse(ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 501,
            executableSHA256: executableSHA256
        ).matchesExpectedService(executableSHA256: executableSHA256))
        XCTAssertFalse(expected.matchesExpectedService(
            executableSHA256: String(repeating: "b", count: 64)
        ))
    }

    func testMutationRequestSecureCodingRoundTripPreservesBoundedEnvelope() throws {
        let request = makeRequest(components: ["folder", "leaf.txt"])
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: request,
            requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemMutationRequest.self,
                from: data
            )
        )

        XCTAssertNil(decoded.validationError())
        XCTAssertEqual(decoded.protocolVersion, ForgeFilesystemProtocolConstants.version)
        XCTAssertEqual(decoded.relativePathComponents, ["folder", "leaf.txt"])
        XCTAssertEqual(decoded.access, .deleteLeaf)
        XCTAssertEqual(decoded.expectedLeafIdentity.inode, 41)
    }

    func testMutationRequestRejectsUnknownProtocolAndUnboundedOrUnsafeComponents() {
        XCTAssertEqual(
            makeRequest(protocolVersion: 99).validationError(),
            ForgeFilesystemErrorCode.protocolMismatch
        )
        XCTAssertEqual(
            makeRequest(components: ["..", "leaf"]).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )
        XCTAssertEqual(
            makeRequest(components: [String(repeating: "x", count: 256)]).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )
        XCTAssertEqual(
            makeRequest(
                components: Array(
                    repeating: "x",
                    count: ForgeFilesystemProtocolConstants.maximumRelativeComponents + 1
                )
            ).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )
    }

    func testMutationRequestRejectsExactContentContractUntilCapabilityExists() {
        XCTAssertEqual(
            makeRequest(exactContentRequired: true).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )
    }

    func testMutationRequestRejectsSpecialExpectedLeafTypes() {
        XCTAssertEqual(
            makeRequest(expectedLeafMode: UInt32(S_IFIFO | 0o600)).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.permitsLeafType(
            mode: UInt32(S_IFREG | 0o600)
        ))
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.permitsLeafType(
            mode: UInt32(S_IFLNK | 0o777)
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.permitsLeafType(
            mode: UInt32(S_IFSOCK | 0o600)
        ))
    }

    func testMutationRequestRejectsGenerationOutsideSignedCodingRange() throws {
        let request = makeRequest(projectGeneration: UInt64.max)
        XCTAssertEqual(request.validationError(), ForgeFilesystemErrorCode.invalidRequest)

        let data = try NSKeyedArchiver.archivedData(
            withRootObject: request,
            requiringSecureCoding: true
        )
        do {
            let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemMutationRequest.self,
                from: data
            )
            XCTAssertNil(decoded, "a negative wire generation must fail secure decoding")
        } catch {
            // Throwing is also a fail-closed secure-decoding outcome.
        }
    }

    func testPeerRequirementsBindExactIdentifiersTeamsAndCertificateClass() {
        let app = ForgeFilesystemProtocolConstants.requiredAppCodeSigningRequirement
        let client = ForgeFilesystemProtocolConstants.requiredClientCodeSigningRequirement
        let daemon = ForgeFilesystemProtocolConstants.requiredDaemonCodeSigningRequirement

        XCTAssertTrue(app.contains("identifier \"com.forge-conductor.app\""))
        XCTAssertTrue(client.contains("identifier \"com.forge-conductor.app\""))
        XCTAssertTrue(client.contains("identifier \"com.forge-conductor.cli\""))
        XCTAssertTrue(client.contains(" or "))
        XCTAssertTrue(daemon.contains("identifier \"com.forge-conductor.filesystem-daemon\""))
        XCTAssertTrue(app.contains(ForgeFilesystemProtocolConstants.activeTeamIdentifier))
        XCTAssertTrue(daemon.contains(ForgeFilesystemProtocolConstants.activeTeamIdentifier))
        XCTAssertTrue(app.contains("anchor apple generic"))
        XCTAssertTrue(daemon.contains("anchor apple generic"))
        XCTAssertTrue(app.contains("1.2.840.113635.100.6.1"))
        XCTAssertTrue(daemon.contains("1.2.840.113635.100.6.1"))
    }

    func testRequesterPolicyRejectsRootAndInvalidUIDs() {
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.isValidRequesterUID(0))
        XCTAssertFalse(
            ForgeFilesystemRequesterPolicy.isValidRequesterUID(
                ForgeFilesystemRequesterPolicy.invalidRequesterUID
            )
        )
        XCTAssertFalse(
            ForgeFilesystemRequesterPolicy.isValidRequesterUID(UInt32.max - 1),
            "the unsigned representation of the nobody UID must fail closed"
        )
        XCTAssertFalse(
            ForgeFilesystemRequesterPolicy.isValidRequesterUID(
                ForgeFilesystemRequesterPolicy.maximumRequesterUID + 1
            )
        )
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.isValidRequesterUID(501))
    }

    func testRequesterPolicyRequiresRequesterOwnershipSearchAndNoACL() {
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
            requesterUID: 501,
            ownerUID: 501,
            mode: 0o040755,
            hasExtendedACL: false,
            requiresOwnerWrite: false
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
            requesterUID: 501,
            ownerUID: 0,
            mode: 0o040755,
            hasExtendedACL: false,
            requiresOwnerWrite: false
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
            requesterUID: 501,
            ownerUID: 501,
            mode: 0o040644,
            hasExtendedACL: false,
            requiresOwnerWrite: false
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
            requesterUID: 501,
            ownerUID: 501,
            mode: 0o040755,
            hasExtendedACL: true,
            requiresOwnerWrite: false
        ))
    }

    func testRequesterPolicyRequiresOwnerWriteOnFinalParent() {
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
            requesterUID: 501,
            ownerUID: 501,
            mode: 0o040555,
            hasExtendedACL: false,
            requiresOwnerWrite: true
        ))
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.permitsSourceDirectory(
            requesterUID: 501,
            ownerUID: 501,
            mode: 0o040700,
            hasExtendedACL: false,
            requiresOwnerWrite: true
        ))
    }

    func testRequesterPolicyRequiresExactPersistedUIDForRetryAndRebind() {
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            501,
            currentRequesterUID: 501
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            501,
            currentRequesterUID: 502
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            0,
            currentRequesterUID: 0
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            ForgeFilesystemRequesterPolicy.invalidRequesterUID,
            currentRequesterUID: ForgeFilesystemRequesterPolicy.invalidRequesterUID
        ))
    }

    func testRequesterPolicyRejectsLeafExtendedACLAndEveryProtectedBSDFlag() {
        XCTAssertTrue(ForgeFilesystemRequesterPolicy.permitsLeafDeletion(
            flags: 0,
            hasExtendedACL: false
        ))
        XCTAssertFalse(ForgeFilesystemRequesterPolicy.permitsLeafDeletion(
            flags: 0,
            hasExtendedACL: true
        ))

        for flag in [
            UInt32(UF_IMMUTABLE),
            UInt32(UF_APPEND),
            UInt32(SF_IMMUTABLE),
            UInt32(SF_APPEND),
            UInt32(SF_RESTRICTED),
            UInt32(SF_NOUNLINK),
        ] {
            XCTAssertFalse(
                ForgeFilesystemRequesterPolicy.permitsLeafDeletion(
                    flags: flag,
                    hasExtendedACL: false
                ),
                "flag \(String(flag, radix: 16)) must fail closed"
            )
            XCTAssertNotEqual(
                ForgeFilesystemRequesterPolicy.disallowedLeafFlags & flag,
                0
            )
        }
    }

    func testProjectBindingProbeOrderResolvesInitialHashCollisionsWithinBound() throws {
        var firstBySlot: [Int: UUID] = [:]
        var collision: (UUID, UUID)?
        for value in 0...ForgeFilesystemBindingPolicy.maximumSlots {
            let uuid = try XCTUnwrap(UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012llx",
                    UInt64(value)
                )
            ))
            let first = try XCTUnwrap(
                ForgeFilesystemBindingPolicy.probeSlots(for: uuid).first
            )
            if let prior = firstBySlot[first] {
                collision = (prior, uuid)
                break
            }
            firstBySlot[first] = uuid
        }
        let pair = try XCTUnwrap(collision)
        let first = ForgeFilesystemBindingPolicy.probeSlots(for: pair.0)
        let second = ForgeFilesystemBindingPolicy.probeSlots(for: pair.1)

        XCTAssertEqual(first.first, second.first)
        XCTAssertEqual(first.count, ForgeFilesystemBindingPolicy.maximumSlots)
        XCTAssertEqual(Set(first).count, ForgeFilesystemBindingPolicy.maximumSlots)
        XCTAssertEqual(Set(second).count, ForgeFilesystemBindingPolicy.maximumSlots)
        XCTAssertEqual(Set(first), Set(0..<ForgeFilesystemBindingPolicy.maximumSlots))
    }

    private func makeRequest(
        protocolVersion: Int = ForgeFilesystemProtocolConstants.version,
        components: [String] = ["leaf.txt"],
        projectGeneration: UInt64 = 1,
        expectedLeafMode: UInt32 = 0o100644,
        exactContentRequired: Bool = false
    ) -> ForgeFilesystemMutationRequest {
        ForgeFilesystemMutationRequest(
            protocolVersion: protocolVersion,
            requestID: UUID().uuidString.lowercased(),
            transactionID: UUID().uuidString.lowercased(),
            projectID: UUID().uuidString.lowercased(),
            projectGeneration: projectGeneration,
            rootID: "1:2",
            rootIdentity: ForgeFilesystemIdentity(
                device: 1,
                inode: 2,
                mode: 0o040755,
                owner: 501,
                group: 20,
                linkCount: 4
            ),
            relativePathComponents: components,
            access: .deleteLeaf,
            expectedLeafIdentity: ForgeFilesystemIdentity(
                device: 1,
                inode: 41,
                mode: expectedLeafMode,
                owner: 501,
                group: 20,
                linkCount: 1
            ),
            exactContentRequired: exactContentRequired
        )
    }
}
