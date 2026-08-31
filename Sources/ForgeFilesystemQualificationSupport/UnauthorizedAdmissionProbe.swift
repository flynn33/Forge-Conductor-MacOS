import CryptoKit
import Darwin
import Foundation
import ForgeFilesystemProtocol

public struct ForgeFilesystemAdmissionProbeRecorderContext: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let operation: String
    public let role: ForgeFilesystemQualificationRole
    public let caseID: String
    public let daemonCodeDirectoryHashes: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case operation
        case role
        case caseID = "case_id"
        case daemonCodeDirectoryHashes = "daemon_code_directory_hashes"
    }

    public init(
        schemaVersion: Int = 1,
        runID: String,
        operation: String = ForgeFilesystemAdmissionProbeContract.operation,
        role: ForgeFilesystemQualificationRole = .adversary,
        caseID: String = ForgeFilesystemAdmissionProbeContract.caseID,
        daemonCodeDirectoryHashes: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.operation = operation
        self.role = role
        self.caseID = caseID
        self.daemonCodeDirectoryHashes = daemonCodeDirectoryHashes
    }
}

public enum ForgeFilesystemAdmissionProbeTerminalEvent: String, Codable, Sendable {
    case serviceInfoReply = "service_info_reply"
    case connectionError = "connection_error"
    case connectionInterrupted = "connection_interrupted"
    case connectionInvalidated = "connection_invalidated"
    case deadlineExpired = "deadline_expired"
}

public enum ForgeFilesystemAdmissionProbeOutcome: String, Codable, Sendable {
    case candidateConnectionRejectedPendingAuthorizedControl =
        "candidate_connection_rejected_pending_authorized_control"
    case unexpectedAdmission = "unexpected_admission"
    case ambiguousTimeout = "ambiguous_timeout"
}

struct ForgeFilesystemAdmissionProbeTerminalTransition: Equatable, Sendable {
    let event: ForgeFilesystemAdmissionProbeTerminalEvent
    let outcome: ForgeFilesystemAdmissionProbeOutcome
    let monotonicTimestampNanoseconds: UInt64
}

final class ForgeFilesystemAdmissionProbeTerminalState: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private let deadlineMonotonicTimestampNanoseconds: UInt64
    private var storedTransition: ForgeFilesystemAdmissionProbeTerminalTransition?

    init(deadlineMonotonicTimestampNanoseconds: UInt64) {
        self.deadlineMonotonicTimestampNanoseconds =
            deadlineMonotonicTimestampNanoseconds
    }

    @discardableResult
    func transition(
        event: ForgeFilesystemAdmissionProbeTerminalEvent,
        monotonicTimestampNanoseconds: UInt64
    ) -> Bool {
        let effectiveEvent: ForgeFilesystemAdmissionProbeTerminalEvent
        let effectiveTimestamp: UInt64
        if event == .deadlineExpired
            || monotonicTimestampNanoseconds >= deadlineMonotonicTimestampNanoseconds {
            effectiveEvent = .deadlineExpired
            effectiveTimestamp = deadlineMonotonicTimestampNanoseconds
        } else {
            effectiveEvent = event
            effectiveTimestamp = monotonicTimestampNanoseconds
        }

        let outcome: ForgeFilesystemAdmissionProbeOutcome
        switch effectiveEvent {
        case .serviceInfoReply:
            outcome = .unexpectedAdmission
        case .connectionError, .connectionInterrupted, .connectionInvalidated:
            outcome = .candidateConnectionRejectedPendingAuthorizedControl
        case .deadlineExpired:
            outcome = .ambiguousTimeout
        }

        lock.lock()
        defer { lock.unlock() }
        guard storedTransition == nil else { return false }
        storedTransition = ForgeFilesystemAdmissionProbeTerminalTransition(
            event: effectiveEvent,
            outcome: outcome,
            monotonicTimestampNanoseconds: effectiveTimestamp
        )
        signal.signal()
        return true
    }

    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult {
        signal.wait(timeout: deadline)
    }

    var transition: ForgeFilesystemAdmissionProbeTerminalTransition? {
        lock.lock()
        defer { lock.unlock() }
        return storedTransition
    }
}

protocol ForgeFilesystemAdmissionProbeConnection: AnyObject {
    func start(
        onServiceInfoReply: @escaping @Sendable () -> Void,
        onConnectionError: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    )

    func invalidate()
}

@objc private protocol ForgeFilesystemAdmissionProbeXPC {
    func serviceInfo(withReply reply: @escaping (ForgeFilesystemServiceInfo) -> Void)
}

private final class ForgeFilesystemLiveAdmissionProbeConnection:
    ForgeFilesystemAdmissionProbeConnection,
    @unchecked Sendable
{
    private let connection: NSXPCConnection

    init(signingRequirement: String) {
        connection = NSXPCConnection(
            machServiceName: ForgeFilesystemProtocolConstants.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ForgeFilesystemAdmissionProbeXPC.self
        )
        connection.setCodeSigningRequirement(signingRequirement)
    }

    func start(
        onServiceInfoReply: @escaping @Sendable () -> Void,
        onConnectionError: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    ) {
        connection.interruptionHandler = onInterruption
        connection.invalidationHandler = onInvalidation
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            onConnectionError()
        }) as? ForgeFilesystemAdmissionProbeXPC else {
            onConnectionError()
            return
        }
        proxy.serviceInfo { _ in
            onServiceInfoReply()
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}

public struct ForgeFilesystemAdmissionProbeResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: String
    public let runID: String
    public let caseID: String
    public let role: ForgeFilesystemQualificationRole
    public let processID: Int32
    public let effectiveUserID: UInt32
    public let bundleIdentifier: String
    public let clientCodeDirectoryHash: String
    public let daemonCodeDirectoryHashes: [String]
    public let daemonSigningRequirementSHA256: String
    public let deadlineMilliseconds: Int
    public let elapsedMonotonicNanoseconds: UInt64
    public let terminalEvent: ForgeFilesystemAdmissionProbeTerminalEvent
    public let outcome: ForgeFilesystemAdmissionProbeOutcome
    public let authorizedSameConnectionControlObserved: Bool
    public let daemonReachabilityConfirmed: Bool
    public let unauthorizedClientRejectionConfirmed: Bool
    public let productionMutationExercised: Bool
    public let qualificationStatus: String
    public let rowsUpdated: Int
    public let formalPredicatesUpdated: Int
    public let completionClaims: ForgeFilesystemQualificationCompletionClaims

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operation
        case runID = "run_id"
        case caseID = "case_id"
        case role
        case processID = "process_id"
        case effectiveUserID = "effective_user_id"
        case bundleIdentifier = "bundle_identifier"
        case clientCodeDirectoryHash = "client_code_directory_hash"
        case daemonCodeDirectoryHashes = "daemon_code_directory_hashes"
        case daemonSigningRequirementSHA256 = "daemon_signing_requirement_sha256"
        case deadlineMilliseconds = "deadline_milliseconds"
        case elapsedMonotonicNanoseconds = "elapsed_monotonic_nanoseconds"
        case terminalEvent = "terminal_event"
        case outcome
        case authorizedSameConnectionControlObserved =
            "authorized_same_connection_control_observed"
        case daemonReachabilityConfirmed = "daemon_reachability_confirmed"
        case unauthorizedClientRejectionConfirmed =
            "unauthorized_client_rejection_confirmed"
        case productionMutationExercised = "production_mutation_exercised"
        case qualificationStatus = "qualification_status"
        case rowsUpdated = "rows_updated"
        case formalPredicatesUpdated = "formal_predicates_updated"
        case completionClaims = "completion_claims"
    }
}

public enum ForgeFilesystemAdmissionProbeContract {
    public static let operation = "admission-probe"
    public static let caseID = "unauthorized_same_uid_client"
    public static let recorderContextEnvironmentKey =
        "FORGE_FILESYSTEM_ADMISSION_PROBE_CONTEXT"
    public static let maximumRecorderContextBytes = 4 * 1024
    public static let maximumRunIDBytes = 128
    public static let maximumDaemonCodeDirectoryHashes = 2
    public static let maximumDeadlineNanoseconds: UInt64 = 2_000_000_000

    private static let recorderContextKeys: Set<String> = [
        "schema_version", "run_id", "operation", "role", "case_id",
        "daemon_code_directory_hashes",
    ]

    public static func shouldRoute(
        arguments: [String],
        role: ForgeFilesystemQualificationRole
    ) throws -> Bool {
        guard arguments.count >= 2, arguments[1] == operation else { return false }
        guard arguments.count == 2 else {
            throw ForgeFilesystemQualificationContractError.invalidArguments
        }
        guard role == .adversary else {
            throw ForgeFilesystemQualificationContractError.invalidValue("role")
        }
        return true
    }

    public static func decodeRecorderContext(
        _ raw: String
    ) throws -> ForgeFilesystemAdmissionProbeRecorderContext {
        guard let data = raw.data(using: .utf8),
              data.count <= maximumRecorderContextBytes else {
            throw ForgeFilesystemQualificationContractError.oversizedJSON
        }
        var scanner = ForgeFilesystemStrictJSONKeyScanner(data: data)
        try scanner.validate()
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
            object = value
        } catch let error as ForgeFilesystemQualificationContractError {
            throw error
        } catch {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        guard Set(object.keys) == recorderContextKeys else {
            throw ForgeFilesystemQualificationContractError.unexpectedFields
        }

        let context: ForgeFilesystemAdmissionProbeRecorderContext
        do {
            context = try JSONDecoder().decode(
                ForgeFilesystemAdmissionProbeRecorderContext.self,
                from: data
            )
        } catch {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        guard context.schemaVersion == 1,
              context.operation == operation,
              context.role == .adversary,
              context.caseID == caseID,
              isBoundedIdentifier(context.runID, maximumBytes: maximumRunIDBytes),
              (1 ... maximumDaemonCodeDirectoryHashes).contains(
                  context.daemonCodeDirectoryHashes.count
              ),
              let normalizedHashes = ForgeFilesystemCodeIdentity
                  .normalizedCodeDirectoryHashes(context.daemonCodeDirectoryHashes),
              normalizedHashes == context.daemonCodeDirectoryHashes else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "admission_probe_recorder_context"
            )
        }
        return context
    }

    static func run(
        context: ForgeFilesystemAdmissionProbeRecorderContext,
        readiness: ForgeFilesystemQualificationReadiness,
        deadlineNanoseconds: UInt64 = maximumDeadlineNanoseconds,
        makeConnection: (String) -> ForgeFilesystemAdmissionProbeConnection
    ) throws -> ForgeFilesystemAdmissionProbeResult {
        guard context.role == .adversary,
              readiness.role == .adversary,
              readiness.bundleIdentifier == ForgeFilesystemQualificationRole
                  .adversary.bundleIdentifier,
              !readiness.daemonClientRequirementSatisfied,
              readiness.teamOnlyAdmissionProbeSatisfied,
              !readiness.productionMutationExercised,
              readiness.rowsUpdated == 0,
              readiness.formalPredicatesUpdated == 0,
              readiness.completionClaims.isAllFalse else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "adversary_readiness"
            )
        }
        guard deadlineNanoseconds > 0,
              deadlineNanoseconds <= maximumDeadlineNanoseconds else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "deadline_nanoseconds"
            )
        }
        guard let signingRequirement = ForgeFilesystemProtocolConstants
            .requiredDaemonCodeSigningRequirement(
                codeDirectoryHashes: context.daemonCodeDirectoryHashes
            ) else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "daemon_code_directory_hashes"
            )
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadlineValue = startedAt.addingReportingOverflow(deadlineNanoseconds)
        guard !deadlineValue.overflow else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "deadline_nanoseconds"
            )
        }
        let terminalState = ForgeFilesystemAdmissionProbeTerminalState(
            deadlineMonotonicTimestampNanoseconds: deadlineValue.partialValue
        )
        let connection = makeConnection(signingRequirement)
        connection.start(
            onServiceInfoReply: {
                terminalState.transition(
                    event: .serviceInfoReply,
                    monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            },
            onConnectionError: {
                terminalState.transition(
                    event: .connectionError,
                    monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            },
            onInterruption: {
                terminalState.transition(
                    event: .connectionInterrupted,
                    monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            },
            onInvalidation: {
                terminalState.transition(
                    event: .connectionInvalidated,
                    monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            }
        )
        if terminalState.wait(
            until: DispatchTime(uptimeNanoseconds: deadlineValue.partialValue)
        ) == .timedOut {
            terminalState.transition(
                event: .deadlineExpired,
                monotonicTimestampNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
        connection.invalidate()
        guard let transition = terminalState.transition else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "terminal_transition"
            )
        }
        let elapsed = transition.monotonicTimestampNanoseconds >= startedAt
            ? transition.monotonicTimestampNanoseconds - startedAt
            : 0
        let status: String
        switch transition.outcome {
        case .candidateConnectionRejectedPendingAuthorizedControl:
            status = "candidate_only"
        case .unexpectedAdmission:
            status = "failed"
        case .ambiguousTimeout:
            status = "ambiguous"
        }
        return ForgeFilesystemAdmissionProbeResult(
            schemaVersion: 1,
            operation: operation,
            runID: context.runID,
            caseID: context.caseID,
            role: .adversary,
            processID: readiness.processID,
            effectiveUserID: readiness.effectiveUserID,
            bundleIdentifier: readiness.bundleIdentifier,
            clientCodeDirectoryHash: readiness.codeDirectoryHash,
            daemonCodeDirectoryHashes: context.daemonCodeDirectoryHashes,
            daemonSigningRequirementSHA256: sha256(signingRequirement),
            deadlineMilliseconds: Int(deadlineNanoseconds / 1_000_000),
            elapsedMonotonicNanoseconds: elapsed,
            terminalEvent: transition.event,
            outcome: transition.outcome,
            authorizedSameConnectionControlObserved: false,
            daemonReachabilityConfirmed: false,
            unauthorizedClientRejectionConfirmed: false,
            productionMutationExercised: false,
            qualificationStatus: status,
            rowsUpdated: 0,
            formalPredicatesUpdated: 0,
            completionClaims: .init()
        )
    }

    public static func runLive(
        context: ForgeFilesystemAdmissionProbeRecorderContext,
        readiness: ForgeFilesystemQualificationReadiness
    ) throws -> ForgeFilesystemAdmissionProbeResult {
        try run(context: context, readiness: readiness) { signingRequirement in
            ForgeFilesystemLiveAdmissionProbeConnection(
                signingRequirement: signingRequirement
            )
        }
    }

    public static func exitStatus(
        for result: ForgeFilesystemAdmissionProbeResult
    ) -> Int32 {
        switch result.outcome {
        case .candidateConnectionRejectedPendingAuthorizedControl:
            EX_TEMPFAIL
        case .unexpectedAdmission:
            EXIT_FAILURE
        case .ambiguousTimeout:
            EX_UNAVAILABLE
        }
    }

    private static func isBoundedIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
