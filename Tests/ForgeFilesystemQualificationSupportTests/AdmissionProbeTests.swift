import Foundation
import ForgeFilesystemProtocol
import XCTest
@testable import ForgeFilesystemQualificationSupport

final class AdmissionProbeTests: XCTestCase {
    private enum FakeBehavior {
        case serviceInfoReply
        case connectionError
        case interruption
        case invalidation
        case silent
    }

    private final class FakeConnection:
        ForgeFilesystemAdmissionProbeConnection,
        @unchecked Sendable
    {
        let behavior: FakeBehavior
        private(set) var invalidationCount = 0

        init(behavior: FakeBehavior) {
            self.behavior = behavior
        }

        func start(
            onServiceInfoReply: @escaping @Sendable () -> Void,
            onConnectionError: @escaping @Sendable () -> Void,
            onInterruption: @escaping @Sendable () -> Void,
            onInvalidation: @escaping @Sendable () -> Void
        ) {
            switch behavior {
            case .serviceInfoReply:
                onServiceInfoReply()
            case .connectionError:
                onConnectionError()
            case .interruption:
                onInterruption()
            case .invalidation:
                onInvalidation()
            case .silent:
                break
            }
        }

        func invalidate() {
            invalidationCount += 1
        }
    }

    private let firstHash = String(repeating: "a", count: 40)
    private let secondHash = String(repeating: "b", count: 40)

    private func context(
        runID: String = "run-001",
        hashes: [String]? = nil
    ) -> ForgeFilesystemAdmissionProbeRecorderContext {
        ForgeFilesystemAdmissionProbeRecorderContext(
            runID: runID,
            daemonCodeDirectoryHashes: hashes ?? [firstHash, secondHash]
        )
    }

    private func encoded(
        _ context: ForgeFilesystemAdmissionProbeRecorderContext
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(
            String(data: encoder.encode(context), encoding: .utf8)
        )
    }

    private func readiness() -> ForgeFilesystemQualificationReadiness {
        ForgeFilesystemQualificationReadiness(
            command: .describe,
            role: .adversary,
            processID: 501,
            parentProcessID: 500,
            effectiveUserID: 502,
            executablePath: "/private/tmp/forge-filesystem-qualification-adversary",
            bundleIdentifier: ForgeFilesystemQualificationRole.adversary.bundleIdentifier,
            signingTeamIdentifier: ForgeFilesystemQualificationContract.activeTeamIdentifier,
            signingEntitlements: ForgeFilesystemQualificationContract
                .expectedSigningEntitlements(for: .adversary),
            codeDirectoryHash: String(repeating: "c", count: 40),
            recorderContextPresent: false
        )
    }

    func testAdmissionProbeRoutingIsAdversaryOnlyAndDoesNotExpandH0Commands() throws {
        XCTAssertTrue(
            try ForgeFilesystemAdmissionProbeContract.shouldRoute(
                arguments: ["tool", "admission-probe"],
                role: .adversary
            )
        )
        XCTAssertFalse(
            try ForgeFilesystemAdmissionProbeContract.shouldRoute(
                arguments: ["tool", "describe"],
                role: .adversary
            )
        )
        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.shouldRoute(
                arguments: ["tool", "admission-probe"],
                role: .harness
            )
        )
        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.shouldRoute(
                arguments: ["tool", "admission-probe", "extra"],
                role: .adversary
            )
        )
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationContract.parseCommand(
                arguments: ["tool", "admission-probe"]
            )
        )
        XCTAssertEqual(
            ForgeFilesystemQualificationCommand.allCases.map(\.rawValue).sorted(),
            ["describe", "self-check"]
        )
    }

    func testAdmissionProbeStartupCannotBypassRecorderSuspension() throws {
        var suspensionCalls = 0
        let route = try ForgeFilesystemQualificationToolMain.prepareRoute(
            arguments: ["tool", "admission-probe"],
            role: .adversary,
            environment: [
                ForgeFilesystemQualificationContract.startSuspendedEnvironmentKey: "1",
            ],
            suspensionBarrier: {
                suspensionCalls += 1
                return 0
            }
        )

        XCTAssertEqual(route, .admissionProbe)
        XCTAssertEqual(suspensionCalls, 1)
    }

    func testSuspensionFailurePreventsAdmissionProbeRouting() {
        var suspensionCalls = 0
        XCTAssertThrowsError(
            try ForgeFilesystemQualificationToolMain.prepareRoute(
                arguments: ["tool", "admission-probe"],
                role: .adversary,
                environment: [
                    ForgeFilesystemQualificationContract.startSuspendedEnvironmentKey: "1",
                ],
                suspensionBarrier: {
                    suspensionCalls += 1
                    return -1
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .invalidValue("start_suspended")
            )
        }
        XCTAssertEqual(suspensionCalls, 1)
    }

    func testRecorderSuspensionBehaviorIsPreservedForH0Routes() throws {
        for command in ["describe", "self-check"] {
            var suspensionCalls = 0
            let route = try ForgeFilesystemQualificationToolMain.prepareRoute(
                arguments: ["tool", command],
                role: .harness,
                environment: [
                    ForgeFilesystemQualificationContract.startSuspendedEnvironmentKey: "1",
                ],
                suspensionBarrier: {
                    suspensionCalls += 1
                    return 0
                }
            )
            XCTAssertEqual(route, .readiness)
            XCTAssertEqual(suspensionCalls, 1)
        }

        var unsuspendedCalls = 0
        let unsuspendedRoute = try ForgeFilesystemQualificationToolMain.prepareRoute(
            arguments: ["tool", "describe"],
            role: .harness,
            environment: [:],
            suspensionBarrier: {
                unsuspendedCalls += 1
                return 0
            }
        )
        XCTAssertEqual(unsuspendedRoute, .readiness)
        XCTAssertEqual(unsuspendedCalls, 0)
    }

    func testRecorderContextRequiresStrictCanonicalExactDaemonHashes() throws {
        let value = context()
        XCTAssertEqual(
            try ForgeFilesystemAdmissionProbeContract.decodeRecorderContext(
                encoded(value)
            ),
            value
        )

        for invalid in [
            context(hashes: [secondHash, firstHash]),
            context(hashes: [firstHash, firstHash]),
            context(hashes: [firstHash.uppercased()]),
            context(hashes: [String(repeating: "g", count: 40)]),
            context(hashes: [firstHash, secondHash, String(repeating: "c", count: 40)]),
            context(runID: "../run", hashes: [firstHash]),
        ] {
            XCTAssertThrowsError(
                try ForgeFilesystemAdmissionProbeContract.decodeRecorderContext(
                    encoded(invalid)
                )
            )
        }
    }

    func testRecorderContextRejectsDuplicateMissingUnexpectedAndOversizedJSON() throws {
        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.decodeRecorderContext(
                "{\"schema_version\":1,\"schema_\\u0076ersion\":1}"
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .duplicateJSONKey
            )
        }

        let data = try XCTUnwrap(encoded(context()).data(using: .utf8))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["unexpected"] = true
        let unexpected = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.decodeRecorderContext(
                try XCTUnwrap(String(data: unexpected, encoding: .utf8))
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .unexpectedFields
            )
        }

        object.removeValue(forKey: "unexpected")
        object.removeValue(forKey: "run_id")
        let missing = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.decodeRecorderContext(
                try XCTUnwrap(String(data: missing, encoding: .utf8))
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .unexpectedFields
            )
        }

        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.decodeRecorderContext(
                String(
                    repeating: " ",
                    count: ForgeFilesystemAdmissionProbeContract
                        .maximumRecorderContextBytes + 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeFilesystemQualificationContractError,
                .oversizedJSON
            )
        }
    }

    func testTerminalStateAcceptsExactlyOneTransition() {
        let state = ForgeFilesystemAdmissionProbeTerminalState(
            deadlineMonotonicTimestampNanoseconds: 100
        )
        XCTAssertTrue(
            state.transition(
                event: .connectionError,
                monotonicTimestampNanoseconds: 10
            )
        )
        XCTAssertFalse(
            state.transition(
                event: .serviceInfoReply,
                monotonicTimestampNanoseconds: 11
            )
        )
        XCTAssertEqual(
            state.transition,
            ForgeFilesystemAdmissionProbeTerminalTransition(
                event: .connectionError,
                outcome: .candidateConnectionRejectedPendingAuthorizedControl,
                monotonicTimestampNanoseconds: 10
            )
        )
    }

    func testCallbackAtOrAfterDeadlineIsAlwaysClassifiedAsTimeout() {
        for event in [
            ForgeFilesystemAdmissionProbeTerminalEvent.serviceInfoReply,
            .connectionError,
            .connectionInterrupted,
            .connectionInvalidated,
        ] {
            for callbackTimestamp in [UInt64(100), UInt64(101)] {
                let state = ForgeFilesystemAdmissionProbeTerminalState(
                    deadlineMonotonicTimestampNanoseconds: 100
                )
                XCTAssertTrue(
                    state.transition(
                        event: event,
                        monotonicTimestampNanoseconds: callbackTimestamp
                    )
                )
                XCTAssertEqual(
                    state.transition,
                    ForgeFilesystemAdmissionProbeTerminalTransition(
                        event: .deadlineExpired,
                        outcome: .ambiguousTimeout,
                        monotonicTimestampNanoseconds: 100
                    )
                )
                XCTAssertFalse(
                    state.transition(
                        event: .serviceInfoReply,
                        monotonicTimestampNanoseconds: 99
                    )
                )
            }
        }
    }

    func testAnyServiceInfoReplyIsUnexpectedAdmission() throws {
        let fake = FakeConnection(behavior: .serviceInfoReply)
        var capturedRequirement: String?
        let result = try ForgeFilesystemAdmissionProbeContract.run(
            context: context(),
            readiness: readiness()
        ) { requirement in
            capturedRequirement = requirement
            return fake
        }

        XCTAssertEqual(result.outcome, .unexpectedAdmission)
        XCTAssertEqual(result.terminalEvent, .serviceInfoReply)
        XCTAssertEqual(result.qualificationStatus, "failed")
        XCTAssertEqual(result.deadlineMilliseconds, 2_000)
        XCTAssertEqual(
            capturedRequirement,
            ForgeFilesystemProtocolConstants.requiredDaemonCodeSigningRequirement(
                codeDirectoryHashes: [firstHash, secondHash]
            )
        )
        XCTAssertEqual(fake.invalidationCount, 1)
        XCTAssertEqual(
            ForgeFilesystemAdmissionProbeContract.exitStatus(for: result),
            EXIT_FAILURE
        )
        XCTAssertNotEqual(
            ForgeFilesystemAdmissionProbeContract.exitStatus(for: result),
            EXIT_SUCCESS
        )
    }

    func testConnectionCloseIsOnlyCandidatePendingAuthorizedControl() throws {
        for behavior in [
            FakeBehavior.connectionError,
            .interruption,
            .invalidation,
        ] {
            let result = try ForgeFilesystemAdmissionProbeContract.run(
                context: context(hashes: [firstHash]),
                readiness: readiness()
            ) { _ in
                FakeConnection(behavior: behavior)
            }
            XCTAssertEqual(
                result.outcome,
                .candidateConnectionRejectedPendingAuthorizedControl
            )
            XCTAssertEqual(result.qualificationStatus, "candidate_only")
            XCTAssertFalse(result.authorizedSameConnectionControlObserved)
            XCTAssertFalse(result.daemonReachabilityConfirmed)
            XCTAssertFalse(result.unauthorizedClientRejectionConfirmed)
            XCTAssertFalse(result.productionMutationExercised)
            XCTAssertEqual(result.rowsUpdated, 0)
            XCTAssertEqual(result.formalPredicatesUpdated, 0)
            XCTAssertTrue(result.completionClaims.isAllFalse)
            XCTAssertEqual(
                ForgeFilesystemAdmissionProbeContract.exitStatus(for: result),
                EX_TEMPFAIL
            )
            XCTAssertNotEqual(
                ForgeFilesystemAdmissionProbeContract.exitStatus(for: result),
                EXIT_SUCCESS
            )
            XCTAssertLessThanOrEqual(
                try ForgeFilesystemQualificationContract.canonicalJSON(result).count,
                ForgeFilesystemQualificationContract.maximumJSONBytes
            )
        }
    }

    func testNoEventBeforeDeadlineIsAmbiguousAndDeadlineIsBounded() throws {
        let result = try ForgeFilesystemAdmissionProbeContract.run(
            context: context(hashes: [firstHash]),
            readiness: readiness(),
            deadlineNanoseconds: 1_000_000
        ) { _ in
            FakeConnection(behavior: .silent)
        }
        XCTAssertEqual(result.outcome, .ambiguousTimeout)
        XCTAssertEqual(result.terminalEvent, .deadlineExpired)
        XCTAssertEqual(result.qualificationStatus, "ambiguous")
        XCTAssertEqual(result.deadlineMilliseconds, 1)
        XCTAssertEqual(
            ForgeFilesystemAdmissionProbeContract.exitStatus(for: result),
            EX_UNAVAILABLE
        )
        XCTAssertNotEqual(
            ForgeFilesystemAdmissionProbeContract.exitStatus(for: result),
            EXIT_SUCCESS
        )

        XCTAssertThrowsError(
            try ForgeFilesystemAdmissionProbeContract.run(
                context: context(hashes: [firstHash]),
                readiness: readiness(),
                deadlineNanoseconds: ForgeFilesystemAdmissionProbeContract
                    .maximumDeadlineNanoseconds + 1
            ) { _ in
                XCTFail("connection must not be constructed for an invalid deadline")
                return FakeConnection(behavior: .silent)
            }
        )
    }
}
