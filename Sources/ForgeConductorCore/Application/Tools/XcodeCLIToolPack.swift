import Foundation

public struct XcodeCLIToolPack: AsyncContextualToolPackHandling, Sendable {
    public static let names = ["xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator"]
    private let service: XcodeCLIService
    private let durableResultObserver: (@Sendable (ToolResult) -> Void)?

    public init(service: XcodeCLIService) {
        self.service = service
        durableResultObserver = nil
    }

    init(service: XcodeCLIService, durableResultObserver: @escaping @Sendable (ToolResult) -> Void) {
        self.service = service
        self.durableResultObserver = durableResultObserver
    }

    public var toolNames: [String] { Self.names }

    public static func description(for name: String) -> String? {
        let descriptions = [
            "xcode.discover": "Start a bounded native Xcode version, SDK, scheme, destination, settings, or test-plan discovery job.",
            "xcode.run": "Start a durable native build, test, analyze, or candidate archive job with explicit output paths. Read job.status and xcresult evidence before claiming completion or tests passed.",
            "xcode.result": "Start a bounded xcresulttool JSON inspection job for a native build or test result bundle.",
            "xcode.debug": "Start an owner-authorized native LLDB batch job for an explicit executable and command array, without loading lldbinit.",
            "xcode.simulator": "Start a bounded read-only simctl inventory job. Use xcode.run with a compatible simulator destination for builds and tests.",
        ]
        return descriptions[name]
    }

    public static func schema(for name: String) -> [String: Any]? {
        guard names.contains(name) else { return nil }
        let string: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 4_096]
        var properties: [String: Any] = [
            "cwd": string,
            "timeout_sec": ["type": "integer", "minimum": 1, "maximum": 86_400],
            "maximum_inline_output_bytes": ["type": "integer", "minimum": 1, "maximum": 65_536],
            "idempotency_key": ["type": "string", "minLength": 1, "maxLength": 384],
        ]
        let project: [String: Any] = ["project": string, "workspace": string, "scheme": string]
        let required: [String]
        switch name {
        case "xcode.discover":
            properties.merge(project) { _, new in new }
            properties["query"] = ["type": "string", "enum": XcodeDiscoveryQuery.allCases.map(\.rawValue)]
            required = ["query"]
        case "xcode.run":
            properties.merge(project) { _, new in new }
            properties.merge([
                "action": ["type": "string", "enum": XcodeNativeAction.allCases.map(\.rawValue)],
                "destination": string, "configuration": string, "sdk": string,
                "derived_data_path": string, "result_bundle_path": string, "archive_path": string,
                "jobs": ["type": "integer", "minimum": 1, "maximum": 8],
                "test_timeout_sec": ["type": "integer", "minimum": 1, "maximum": 3_600],
                "only_testing": ["type": "array", "maxItems": 64, "items": string],
            ]) { _, new in new }
            required = ["action", "scheme", "destination", "derived_data_path", "result_bundle_path"]
        case "xcode.result":
            properties["query"] = ["type": "string", "enum": XcodeResultQuery.allCases.map(\.rawValue)]
            properties["result_bundle_path"] = string
            required = ["query", "result_bundle_path"]
        case "xcode.debug":
            properties["executable"] = string
            properties["arguments"] = ["type": "array", "maxItems": 64, "items": string]
            properties["commands"] = ["type": "array", "minItems": 1, "maxItems": 32, "items": string]
            required = ["executable", "commands"]
        case "xcode.simulator":
            properties["query"] = ["type": "string", "enum": XcodeSimulatorQuery.allCases.map(\.rawValue)]
            required = ["query"]
        default: return nil
        }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    public func handle(name: String, arguments: [String: Any], context: ToolInvocationContext) async throws -> ToolResult? {
        guard Self.names.contains(name) else { return nil }
        do {
            try Task.checkCancellation()
            guard context.authorizationScope.allowedTools.contains(name)
                    || context.authorizationScope.allowedTools.contains("*") else {
                throw RuntimeJobError.unauthorizedTool(name)
            }
            let command = try XcodeCLIService.command(tool: name, arguments: arguments, context: context)
            guard try Self.maximumReceiptResultBytes(command: command, context: context) <= min(
                context.authorizationScope.maximumInlineOutputBytes,
                ToolInvocationBroker.maximumDurableResultBytes
            ) else {
                throw RuntimeJobError.invalidRequest("Xcode receipt exceeds the result budget")
            }
            let result = try await service.submit(command: command, context: context) { record in
                durableResultObserver?(.success(Self.receipt(record, command: command)))
            }
            var payload = Self.receipt(result.record, command: command)
            payload["idempotency_match"] = result.reused
            return .success(payload)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeJobError {
            return .failure(code: error.code, message: error.localizedDescription, retryable: false)
        } catch let error as ProjectContextError {
            return .failure(code: error.code, message: error.localizedDescription, retryable: error == .databaseBusy)
        } catch {
            return .failure(code: "xcode_cli_error", message: error.localizedDescription, retryable: false)
        }
    }

    static func maximumReceiptResultBytes(command: XcodeCLICommand, context: ToolInvocationContext) throws -> Int {
        let jobID = UUID()
        var maximum = 0
        for state in RuntimeJobState.allCases {
            var payload = receiptFields(
                jobID: jobID, state: state, projectID: context.projectID,
                projectGeneration: context.projectGeneration, timeoutSeconds: command.timeoutSeconds,
                exitCode: Int32.min, command: command
            )
            // A replay can already be terminal. Include every optional receipt
            // field; false and Int32.min are the longer JSON scalar variants.
            payload["idempotency_match"] = false
            let result = ToolResult.success(payload)
            let encoded = try JSONSupport.canonicalJSON([
                "ok": result.ok, "is_error": result.isError, "payload": result.payload,
            ])
            maximum = max(maximum, encoded.utf8.count)
        }
        return maximum
    }

    static func receipt(_ record: RuntimeJobRecord, command: XcodeCLICommand) -> [String: Any] {
        receiptFields(
            jobID: record.jobID, state: record.state, projectID: record.projectID,
            projectGeneration: record.projectGeneration, timeoutSeconds: record.timeoutSeconds,
            exitCode: record.exitCode, command: command
        )
    }

    private static func receiptFields(
        jobID: UUID, state: RuntimeJobState, projectID: ProjectID,
        projectGeneration: ProjectGeneration, timeoutSeconds: Int, exitCode: Int32?,
        command: XcodeCLICommand
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "job_id": jobID.uuidString.lowercased(), "state": state.rawValue,
            "project_id": projectID.description, "project_generation": projectGeneration.rawValue,
            "submission_only": true, "native_tool": command.arguments[0],
            "timeout_seconds": timeoutSeconds,
        ]
        if let bundle = command.resultBundlePath { payload["result_bundle_path"] = bundle }
        if let derivedData = command.derivedDataPath { payload["derived_data_path"] = derivedData }
        if let exit = exitCode { payload["exit_code"] = exit }
        return payload
    }
}

/// Uses the runtime's existing bounded admission wait and committed-receipt rule.
/// The native command runs on its existing actor after this adapter returns.
public struct XcodeCLISynchronousToolPack: ToolPackHandling, Sendable {
    private let service: XcodeCLIService
    public init(subsystem: RuntimeJobSubsystem) { service = XcodeCLIService(jobs: subsystem.service) }
    public var toolNames: [String] { XcodeCLIToolPack.names }

    public func handle(
        name: String, arguments: [String: Any], context: ToolInvocationContext?,
        clientID: ClientID, app: ForgeApp, cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        try cancellation?.checkCancellation()
        guard let context else {
            return .failure(code: "project_context_required", message: "Xcode tools require a durable project context", retryable: false)
        }
        let serialized = try SerializedToolArguments(arguments)
        let receipt = RuntimeBlockingResult<ToolResult>()
        let pack = XcodeCLIToolPack(service: service, durableResultObserver: { receipt.store(.success($0)) })
        return try RuntimeJobSynchronousToolPack.wait(
            timeoutSeconds: RuntimeJobSynchronousToolPack.controlTimeoutSeconds,
            cancellation: cancellation, committedResultWins: true, committedReceipt: receipt
        ) {
            try await pack.handle(name: name, arguments: try serialized.decoded(), context: context)
                ?? .failure(code: "unknown_tool", message: "Unknown Xcode tool", retryable: false)
        }
    }
}
