import Foundation
import Security
import XCTest
import ForgeFilesystemProtocol

final class ForgeFilesystemProtocolTests: XCTestCase {
    func testCapturedLeafRollbackPolicyNeverRestoresThroughRelocatableParent() {
        XCTAssertEqual(
            ForgeFilesystemCapturedLeafRollbackPolicy.disposition,
            .retainForRecovery
        )
    }

    func testServiceInfoSecureCodingAndExactRuntimeMatch() throws {
        let codeDirectoryHash = String(repeating: "a", count: 40)
        let expected = ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
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

        XCTAssertTrue(decoded.matchesExpectedService(
            allowedCodeDirectoryHashes: [codeDirectoryHash.uppercased()]
        ))
        XCTAssertEqual(decoded.protocolVersion, ForgeFilesystemProtocolConstants.version)
        XCTAssertEqual(decoded.productVersion, ForgeFilesystemProtocolConstants.productVersion)
        XCTAssertEqual(decoded.serviceIdentifier, ForgeFilesystemProtocolConstants.daemonIdentifier)
        XCTAssertEqual(decoded.effectiveUserIdentifier, 0)
        XCTAssertEqual(decoded.codeDirectoryHash, codeDirectoryHash)

        XCTAssertFalse(ForgeFilesystemServiceInfo(
            protocolVersion: ForgeFilesystemProtocolConstants.version + 1,
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
        ).matchesExpectedService(allowedCodeDirectoryHashes: [codeDirectoryHash]))
        XCTAssertFalse(ForgeFilesystemServiceInfo(
            productVersion: "0.8.0",
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
        ).matchesExpectedService(allowedCodeDirectoryHashes: [codeDirectoryHash]))
        XCTAssertFalse(ForgeFilesystemServiceInfo(
            serviceIdentifier: "com.example.wrong-daemon",
            effectiveUserIdentifier: 0,
            codeDirectoryHash: codeDirectoryHash
        ).matchesExpectedService(allowedCodeDirectoryHashes: [codeDirectoryHash]))
        XCTAssertFalse(ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: 501,
            codeDirectoryHash: codeDirectoryHash
        ).matchesExpectedService(allowedCodeDirectoryHashes: [codeDirectoryHash]))
        XCTAssertFalse(expected.matchesExpectedService(
            allowedCodeDirectoryHashes: [String(repeating: "b", count: 40)]
        ))
        XCTAssertFalse(expected.matchesExpectedService(allowedCodeDirectoryHashes: []))
        XCTAssertFalse(expected.matchesExpectedService(
            allowedCodeDirectoryHashes: [codeDirectoryHash, "not-a-cdhash"]
        ))
    }

    func testCodeDirectoryHashNormalizationIsStrictAndDeterministic() {
        let first = String(repeating: "A", count: 40)
        let second = String(repeating: "b", count: 40)

        XCTAssertEqual(
            ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(first),
            first.lowercased()
        )
        XCTAssertNil(ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(
            String(repeating: "a", count: 39)
        ))
        XCTAssertNil(ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(
            String(repeating: "a", count: 39) + "g"
        ))
        XCTAssertNil(ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(
            String(repeating: "a", count: 40) + " "
        ))
        XCTAssertEqual(
            ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHashes([
                second,
                first,
                first.lowercased(),
            ]),
            [first.lowercased(), second]
        )
        XCTAssertNil(ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHashes([]))
        XCTAssertNil(ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHashes([
            first,
            "not-a-cdhash",
        ]))
    }

    func testCurrentRunningCodeIdentityProducesStrictCodeDirectoryHash() throws {
        let hash = try XCTUnwrap(ForgeFilesystemCodeIdentity.currentCodeDirectoryHash())

        XCTAssertEqual(hash.count, ForgeFilesystemCodeIdentity.codeDirectoryHashCharacters)
        XCTAssertEqual(ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(hash), hash)
    }

    func testSecuredInfoDictionaryHashExtractionFailsClosed() {
        let arm64 = String(repeating: "a", count: 40)
        let x86 = String(repeating: "B", count: 40)
        let arm64Key = ForgeFilesystemCodeIdentity
            .daemonArm64CodeDirectoryHashInfoPlistKey
        let x86Key = ForgeFilesystemCodeIdentity
            .daemonX86_64CodeDirectoryHashInfoPlistKey

        XCTAssertEqual(
            ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
                inSecuredInfoDictionary: [x86Key: x86, arm64Key: arm64]
            ),
            [arm64, x86.lowercased()]
        )
        XCTAssertEqual(
            ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
                inSecuredInfoDictionary: [arm64Key: arm64]
            ),
            [arm64]
        )
        XCTAssertNil(ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
            inSecuredInfoDictionary: [:]
        ))
        XCTAssertNil(ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
            inSecuredInfoDictionary: [arm64Key: arm64, x86Key: ""]
        ))
        XCTAssertNil(ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
            inSecuredInfoDictionary: [arm64Key: arm64, x86Key: 42]
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

    func testTransactionControlRequestSecureCodingRoundTripPreservesAuthorityEnvelope() throws {
        let mutation = makeRequest(projectGeneration: 41)
        let request = makeControlRequest(from: mutation)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: request,
            requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemTransactionControlRequest.self,
                from: data
            )
        )

        XCTAssertNil(decoded.validationError())
        XCTAssertEqual(decoded.protocolVersion, ForgeFilesystemProtocolConstants.version)
        XCTAssertEqual(decoded.transactionID, mutation.transactionID)
        XCTAssertEqual(decoded.projectID, mutation.projectID)
        XCTAssertEqual(decoded.projectGeneration, mutation.projectGeneration)
        XCTAssertEqual(decoded.rootID, mutation.rootID)
        XCTAssertEqual(decoded.rootIdentity.device, mutation.rootIdentity.device)
        XCTAssertEqual(decoded.rootIdentity.inode, mutation.rootIdentity.inode)
    }

    func testTransactionControlRequestRejectsMismatchedVersionAndInvalidBounds() throws {
        let mutation = makeRequest()
        XCTAssertEqual(
            ForgeFilesystemTransactionControlRequest(
                protocolVersion: ForgeFilesystemProtocolConstants.version + 1,
                transactionID: mutation.transactionID,
                projectID: mutation.projectID,
                projectGeneration: mutation.projectGeneration,
                rootID: mutation.rootID,
                rootIdentity: mutation.rootIdentity
            ).validationError(),
            ForgeFilesystemErrorCode.protocolMismatch
        )
        XCTAssertEqual(
            ForgeFilesystemTransactionControlRequest(
                transactionID: "not-a-uuid",
                projectID: mutation.projectID,
                projectGeneration: mutation.projectGeneration,
                rootID: mutation.rootID,
                rootIdentity: mutation.rootIdentity
            ).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )
        XCTAssertEqual(
            ForgeFilesystemTransactionControlRequest(
                transactionID: mutation.transactionID,
                projectID: mutation.projectID,
                projectGeneration: UInt64.max,
                rootID: mutation.rootID,
                rootIdentity: mutation.rootIdentity
            ).validationError(),
            ForgeFilesystemErrorCode.invalidRequest
        )

        let invalidWireGeneration = ForgeFilesystemTransactionControlRequest(
            transactionID: mutation.transactionID,
            projectID: mutation.projectID,
            projectGeneration: UInt64.max,
            rootID: mutation.rootID,
            rootIdentity: mutation.rootIdentity
        )
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: invalidWireGeneration,
            requiringSecureCoding: true
        )
        do {
            let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemTransactionControlRequest.self,
                from: data
            )
            XCTAssertNil(decoded, "a negative wire generation must fail secure decoding")
        } catch {
            // Throwing is also a fail-closed secure-decoding outcome.
        }
    }

    func testTransactionAuthorityRequiresExactUIDProjectGenerationAndRootEnvelope() {
        let mutation = makeRequest(projectGeneration: 7)
        let baseline = makeControlRequest(from: mutation)
        let matches: (ForgeFilesystemTransactionControlRequest, UInt32) -> Bool = {
            request, uid in
            ForgeFilesystemTransactionAuthorityPolicy.matchesPersistedAuthority(
                request: request,
                currentRequesterUID: uid,
                persistedRequesterUID: 501,
                persistedTransactionID: mutation.transactionID.uppercased(),
                persistedProjectID: mutation.projectID.uppercased(),
                persistedProjectGeneration: mutation.projectGeneration,
                persistedRootID: mutation.rootID,
                persistedRootIdentity: mutation.rootIdentity
            )
        }

        XCTAssertTrue(matches(baseline, 501))
        XCTAssertFalse(matches(baseline, 502))
        XCTAssertFalse(matches(ForgeFilesystemTransactionControlRequest(
            transactionID: UUID().uuidString,
            projectID: baseline.projectID,
            projectGeneration: baseline.projectGeneration,
            rootID: baseline.rootID,
            rootIdentity: baseline.rootIdentity
        ), 501))
        XCTAssertFalse(matches(ForgeFilesystemTransactionControlRequest(
            transactionID: baseline.transactionID,
            projectID: UUID().uuidString,
            projectGeneration: baseline.projectGeneration,
            rootID: baseline.rootID,
            rootIdentity: baseline.rootIdentity
        ), 501))
        XCTAssertFalse(matches(ForgeFilesystemTransactionControlRequest(
            transactionID: baseline.transactionID,
            projectID: baseline.projectID,
            projectGeneration: baseline.projectGeneration + 1,
            rootID: baseline.rootID,
            rootIdentity: baseline.rootIdentity
        ), 501))
        XCTAssertFalse(matches(ForgeFilesystemTransactionControlRequest(
            transactionID: baseline.transactionID,
            projectID: baseline.projectID,
            projectGeneration: baseline.projectGeneration,
            rootID: "1:3",
            rootIdentity: baseline.rootIdentity
        ), 501))
        XCTAssertFalse(matches(ForgeFilesystemTransactionControlRequest(
            transactionID: baseline.transactionID,
            projectID: baseline.projectID,
            projectGeneration: baseline.projectGeneration,
            rootID: baseline.rootID,
            rootIdentity: ForgeFilesystemIdentity(
                device: baseline.rootIdentity.device,
                inode: baseline.rootIdentity.inode + 1,
                mode: baseline.rootIdentity.mode,
                owner: baseline.rootIdentity.owner,
                group: baseline.rootIdentity.group,
                linkCount: baseline.rootIdentity.linkCount
            )
        ), 501))
    }

    func testAcknowledgementIsIdempotentOnlyWhenTransactionIsAbsent() {
        XCTAssertEqual(
            ForgeFilesystemTransactionAuthorityPolicy.acknowledgementDecision(
                transactionExists: false,
                authorityMatches: false
            ),
            .idempotentSuccess
        )
        XCTAssertEqual(
            ForgeFilesystemTransactionAuthorityPolicy.acknowledgementDecision(
                transactionExists: true,
                authorityMatches: true
            ),
            .authorizedCleanup
        )
        XCTAssertEqual(
            ForgeFilesystemTransactionAuthorityPolicy.acknowledgementDecision(
                transactionExists: true,
                authorityMatches: false
            ),
            .reject
        )
    }

    func testPostIntentPublicationFailureRetainsOriginalTransactionIdentity() {
        let transactionID = UUID().uuidString.lowercased()

        XCTAssertNil(ForgeFilesystemTransactionRecoveryPolicy.recoveryTransactionID(
            transactionID,
            at: .beforeIntentPublication
        ))
        XCTAssertEqual(
            ForgeFilesystemTransactionRecoveryPolicy.recoveryTransactionID(
                transactionID,
                at: .intentPublicationStarted
            ),
            transactionID
        )
    }

    func testExistingNonterminalBindingFailureRetainsOriginalTransactionIdentity() {
        let transactionID = UUID().uuidString.lowercased()

        XCTAssertEqual(
            ForgeFilesystemTransactionRecoveryPolicy.recoveryTransactionID(
                transactionID,
                at: .persistedTransactionPresent
            ),
            transactionID
        )
        XCTAssertNil(ForgeFilesystemTransactionRecoveryPolicy.recoveryTransactionID(
            "not-a-transaction-id",
            at: .persistedTransactionPresent
        ))
    }

    func testTransactionStatusSecureCodingRoundTripPreservesTerminalDisposition() throws {
        let transactionID = UUID().uuidString.lowercased()
        let status = ForgeFilesystemTransactionStatus(
            transactionID: transactionID,
            disposition: .restored,
            code: ForgeFilesystemErrorCode.capabilityUnavailable,
            message: "The captured filesystem leaf was restored",
            terminal: true,
            committed: false,
            durabilityConfirmed: true,
            recoveryRequired: false,
            acknowledgementRequired: true
        )
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: status,
            requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemTransactionStatus.self,
                from: data
            )
        )

        XCTAssertNil(decoded.validationError())
        XCTAssertEqual(decoded.transactionID, transactionID)
        XCTAssertEqual(decoded.disposition, .restored)
        XCTAssertTrue(decoded.terminal)
        XCTAssertFalse(decoded.committed)
        XCTAssertTrue(decoded.durabilityConfirmed)
        XCTAssertFalse(decoded.recoveryRequired)
        XCTAssertTrue(decoded.acknowledgementRequired)
    }

    func testTransactionStatusSecureDecodingRejectsContradictoryTerminalFlags() throws {
        let invalid = ForgeFilesystemTransactionStatus(
            transactionID: UUID().uuidString.lowercased(),
            disposition: .committed,
            code: "ok",
            message: "invalid contradictory status",
            terminal: true,
            committed: true,
            durabilityConfirmed: true,
            recoveryRequired: true,
            acknowledgementRequired: true
        )
        XCTAssertEqual(invalid.validationError(), ForgeFilesystemErrorCode.invalidRequest)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: invalid,
            requiringSecureCoding: true
        )
        do {
            let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemTransactionStatus.self,
                from: data
            )
            XCTAssertNil(decoded, "contradictory terminal flags must fail secure decoding")
        } catch {
            // Throwing is also a fail-closed secure-decoding outcome.
        }
    }

    func testTerminalResponseSecureCodingPreservesAcknowledgementRequirement() throws {
        let transactionID = UUID().uuidString.lowercased()
        let response = ForgeFilesystemResponse(
            ok: true,
            code: "ok",
            message: "committed",
            committed: true,
            durabilityConfirmed: true,
            recoveryTransactionID: transactionID,
            acknowledgementRequired: true
        )
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: response,
            requiringSecureCoding: true
        )
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemResponse.self,
                from: data
            )
        )

        XCTAssertTrue(decoded.ok)
        XCTAssertTrue(decoded.committed)
        XCTAssertTrue(decoded.durabilityConfirmed)
        XCTAssertEqual(decoded.recoveryTransactionID, transactionID)
        XCTAssertTrue(decoded.acknowledgementRequired)
    }

    func testTerminalResponseSecureDecodingRejectsUndurableAcknowledgementSignal() throws {
        let response = ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.capabilityUnavailable,
            message: "invalid terminal response",
            committed: false,
            durabilityConfirmed: false,
            recoveryTransactionID: UUID().uuidString.lowercased(),
            acknowledgementRequired: true
        )
        XCTAssertEqual(response.validationError(), ForgeFilesystemErrorCode.invalidRequest)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: response,
            requiringSecureCoding: true
        )
        do {
            let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ForgeFilesystemResponse.self,
                from: data
            )
            XCTAssertNil(decoded, "an undurable terminal response must fail secure decoding")
        } catch {
            // Throwing is also a fail-closed secure-decoding outcome.
        }
    }

    func testPeerRequirementsBindExactIdentifiersTeamsAndCertificateClass() throws {
        let app = ForgeFilesystemProtocolConstants.requiredAppCodeSigningRequirement
        let client = ForgeFilesystemProtocolConstants.requiredClientCodeSigningRequirement
        let firstHash = String(repeating: "a", count: 40)
        let secondHash = String(repeating: "B", count: 40)
        let daemon = try XCTUnwrap(
            ForgeFilesystemProtocolConstants.requiredDaemonCodeSigningRequirement(
                codeDirectoryHashes: [secondHash, firstHash, firstHash]
            )
        )

        XCTAssertTrue(app.contains("identifier \"com.forge-conductor.app\""))
        XCTAssertTrue(client.contains("identifier \"com.forge-conductor.app\""))
        XCTAssertTrue(client.contains("identifier \"com.forge-conductor.cli\""))
        XCTAssertTrue(client.contains(" or "))
        XCTAssertTrue(daemon.contains(
            "identifier \"com.forge-conductor.filesystem-daemon\""
        ))
        XCTAssertTrue(app.contains(ForgeFilesystemProtocolConstants.activeTeamIdentifier))
        XCTAssertTrue(daemon.contains(
            ForgeFilesystemProtocolConstants.activeTeamIdentifier
        ))
        XCTAssertTrue(app.contains("anchor apple generic"))
        XCTAssertTrue(daemon.contains("anchor apple generic"))
        XCTAssertTrue(app.contains("1.2.840.113635.100.6.1"))
        XCTAssertTrue(daemon.contains("1.2.840.113635.100.6.1"))
        XCTAssertTrue(daemon.contains("cdhash H\"\(firstHash)\""))
        XCTAssertTrue(daemon.contains("cdhash H\"\(secondHash.lowercased())\""))
        XCTAssertEqual(daemon.components(separatedBy: "cdhash H\"").count, 3)
        var compiledRequirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                daemon as CFString,
                [],
                &compiledRequirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(compiledRequirement)
        XCTAssertNil(ForgeFilesystemProtocolConstants.requiredDaemonCodeSigningRequirement(
            codeDirectoryHashes: []
        ))
        XCTAssertNil(ForgeFilesystemProtocolConstants.requiredDaemonCodeSigningRequirement(
            codeDirectoryHashes: [firstHash, "not-a-cdhash"]
        ))
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

    private func makeControlRequest(
        from request: ForgeFilesystemMutationRequest
    ) -> ForgeFilesystemTransactionControlRequest {
        ForgeFilesystemTransactionControlRequest(
            protocolVersion: request.protocolVersion,
            transactionID: request.transactionID,
            projectID: request.projectID,
            projectGeneration: request.projectGeneration,
            rootID: request.rootID,
            rootIdentity: request.rootIdentity
        )
    }
}
