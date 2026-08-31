import Foundation
import XCTest
@testable import ForgeFilesystemQualificationSupport

final class QualificationReadinessTests: XCTestCase {
    private func readiness(
        command: ForgeFilesystemQualificationCommand = .describe,
        role: ForgeFilesystemQualificationRole = .harness
    ) -> ForgeFilesystemQualificationReadiness {
        ForgeFilesystemQualificationReadiness(
            command: command,
            role: role,
            processID: 501,
            parentProcessID: 500,
            effectiveUserID: 502,
            executablePath: "/private/tmp/qualification-tool",
            bundleIdentifier: role.bundleIdentifier,
            signingTeamIdentifier: ForgeFilesystemQualificationContract.activeTeamIdentifier,
            signingEntitlements: ForgeFilesystemQualificationContract.expectedSigningEntitlements(
                for: role
            ),
            codeDirectoryHash: String(repeating: "a", count: 40),
            recorderContextPresent: command == .selfCheck
        )
    }

    func testQualificationIdentitiesAreDistinctAndNonProduct() {
        let identifiers = Set(ForgeFilesystemQualificationRole.allCases.map(\.bundleIdentifier))
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertFalse(identifiers.contains("com.forge-conductor.app"))
        XCTAssertFalse(identifiers.contains("com.forge-conductor.cli"))
        XCTAssertFalse(identifiers.contains("com.forge-conductor.filesystem-daemon"))
    }

    func testOnlyReadOnlyH0CommandsAreSupported() throws {
        XCTAssertEqual(
            ForgeFilesystemQualificationCommand.allCases.map(\.rawValue).sorted(),
            ["describe", "self-check"]
        )
        XCTAssertEqual(
            try ForgeFilesystemQualificationContract.parseCommand(
                arguments: ["tool", "describe"]
            ),
            .describe
        )
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.parseCommand(
                arguments: ["tool", "run-case"]
            )
        )
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.parseCommand(
                arguments: ["tool", "describe", "extra"]
            )
        )
    }

    func testReadinessRoundTripPreservesAllNonclaims() throws {
        let value = readiness(command: .selfCheck, role: .adversary)
        let data = try ForgeFilesystemQualificationContract.canonicalJSON(value)
        let decoded = try ForgeFilesystemQualificationContract.decodeReadiness(data)

        XCTAssertEqual(decoded, value)
        XCTAssertFalse(decoded.productionMutationExercised)
        XCTAssertEqual(decoded.qualificationStatus, "not_run")
        XCTAssertEqual(decoded.rowsUpdated, 0)
        XCTAssertEqual(decoded.formalPredicatesUpdated, 0)
        XCTAssertTrue(decoded.completionClaims.isAllFalse)
        XCTAssertLessThanOrEqual(
            data.count,
            ForgeFilesystemQualificationContract.maximumJSONBytes
        )
    }

    func testReadinessRejectsUnknownFields() throws {
        let data = try ForgeFilesystemQualificationContract.canonicalJSON(readiness())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["mutation"] = "unlink"
        let modified = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.decodeReadiness(modified)
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .unexpectedFields
            )
        }
    }

    func testStrictDecoderRejectsDuplicateAndEscapedEquivalentKeys() {
        for raw in [
            "{\"schema_version\":1,\"schema_version\":1}",
            "{\"schema_version\":1,\"schema_\\u0076ersion\":1}",
            "{\"outer\":{\"role\":\"harness\",\"role\":\"adversary\"}}",
        ] {
            XCTAssertThrowsError(
                try ForgeFilesystemQualificationContract.decodeReadiness(Data(raw.utf8))
            ) { error in
                XCTAssertEqual(
                    error as? ForgeFilesystemQualificationContractError,
                    .duplicateJSONKey
                )
            }
        }
    }

    func testReadinessRejectsCompletionAdvancement() throws {
        let advanced = ForgeFilesystemQualificationReadiness(
            command: .describe,
            role: .harness,
            processID: 501,
            parentProcessID: 500,
            effectiveUserID: 502,
            executablePath: "/private/tmp/qualification-tool",
            bundleIdentifier: ForgeFilesystemQualificationRole.harness.bundleIdentifier,
            signingTeamIdentifier: ForgeFilesystemQualificationContract.activeTeamIdentifier,
            signingEntitlements: ForgeFilesystemQualificationContract.expectedSigningEntitlements(
                for: .harness
            ),
            codeDirectoryHash: String(repeating: "b", count: 40),
            recorderContextPresent: false,
            rowsUpdated: 1
        )
        let data = try ForgeFilesystemQualificationContract.canonicalJSON(advanced)
        XCTAssertThrowsError(try ForgeFilesystemQualificationContract.decodeReadiness(data))
    }

    func testReadinessRejectsLiveSigningFactMismatch() throws {
        let data = try ForgeFilesystemQualificationContract.canonicalJSON(readiness())
        let mutations: [(String, Any)] = [
            ("signing_team_identifier", "WRONGTEAM0"),
            ("signing_entitlements", [:]),
            ("hardened_runtime", false),
            ("self_identity_requirement_satisfied", false),
        ]
        for (field, invalidValue) in mutations {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            object[field] = invalidValue
            let modified = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try ForgeFilesystemQualificationContract.decodeReadiness(modified),
                "unexpectedly accepted invalid \(field)"
            )
        }
    }

    func testSelfCheckRequiresRecorderContextClaim() throws {
        let missing = ForgeFilesystemQualificationReadiness(
            command: .selfCheck,
            role: .harness,
            processID: 501,
            parentProcessID: 500,
            effectiveUserID: 502,
            executablePath: "/private/tmp/qualification-tool",
            bundleIdentifier: ForgeFilesystemQualificationRole.harness.bundleIdentifier,
            signingTeamIdentifier: ForgeFilesystemQualificationContract.activeTeamIdentifier,
            signingEntitlements: ForgeFilesystemQualificationContract.expectedSigningEntitlements(
                for: .harness
            ),
            codeDirectoryHash: String(repeating: "c", count: 40),
            recorderContextPresent: false
        )
        let data = try ForgeFilesystemQualificationContract.canonicalJSON(missing)
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.decodeReadiness(data)
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .recorderContextRequired
            )
        }
    }

    func testDecoderRejectsOversizedJSON() {
        let data = Data(
            repeating: 0x20,
            count: ForgeFilesystemQualificationContract.maximumJSONBytes + 1
        )
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.decodeReadiness(data)
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .oversizedJSON
            )
        }
    }

    func testControlFrameIsStrictAndBounded() throws {
        let frame = ForgeFilesystemQualificationControlFrame(
            role: .adversary,
            sequence: 1,
            caseID: "T1.same-uid.swap",
            iteration: 0,
            event: .ready,
            monotonicTimestampNanoseconds: 1
        )
        let data = try ForgeFilesystemQualificationContract.canonicalJSON(frame)
        XCTAssertEqual(
            try ForgeFilesystemQualificationContract.decodeControlFrame(data),
            frame
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["path"] = "/tmp/forbidden"
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.decodeControlFrame(
                JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testControlFrameRejectsInvalidOrderingFields() throws {
        for frame in [
            ForgeFilesystemQualificationControlFrame(
                role: .harness,
                sequence: 0,
                caseID: "T1",
                iteration: 0,
                event: .ready,
                monotonicTimestampNanoseconds: 1
            ),
            ForgeFilesystemQualificationControlFrame(
                role: .harness,
                sequence: 1,
                caseID: "../T1",
                iteration: 0,
                event: .ready,
                monotonicTimestampNanoseconds: 1
            ),
            ForgeFilesystemQualificationControlFrame(
                role: .harness,
                sequence: 1,
                caseID: "T1",
                iteration: -1,
                event: .ready,
                monotonicTimestampNanoseconds: 1
            ),
        ] {
            let data = try ForgeFilesystemQualificationContract.canonicalJSON(frame)
            XCTAssertThrowsError(
                try ForgeFilesystemQualificationContract.decodeControlFrame(data)
            )
        }
    }

    func testSingleComponentValidationRejectsTraversalAndPaths() throws {
        for valid in ["leaf", "fixture-01", ".hidden"] {
            XCTAssertNoThrow(
                try ForgeFilesystemQualificationContract.validateSingleComponent(valid)
            )
        }
        for invalid in ["", ".", "..", "parent/leaf", "leaf\0suffix"] {
            XCTAssertThrowsError(
                try ForgeFilesystemQualificationContract.validateSingleComponent(invalid)
            )
        }
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.validateSingleComponent(
                String(repeating: "a", count: 256)
            )
        )
    }
}
