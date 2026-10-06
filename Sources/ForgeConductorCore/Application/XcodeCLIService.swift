import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// Adapts inspected Apple command-line interfaces to the existing durable runtime.
/// It introduces no process owner, shell parsing, credential access, or signing override.
public struct XcodeCLIService: Sendable {
    private let jobs: ExecutionJobService
    private let xcrunURL: URL

    public init(jobs: ExecutionJobService) {
        self.jobs = jobs
        xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    }

    init(jobs: ExecutionJobService, xcrunURL: URL) {
        self.jobs = jobs
        self.xcrunURL = xcrunURL
    }

    func submit(
        command: XcodeCLICommand,
        context: ToolInvocationContext,
        didPersist: @escaping @Sendable (RuntimeJobRecord) -> Void
    ) async throws -> (record: RuntimeJobRecord, reused: Bool) {
        let fingerprint = try Self.nativeCommandFingerprint(command: command, executable: xcrunURL)
        let receipt = RuntimeBlockingResult<RuntimeJobRecord>()
        let request = RuntimeJobRequest(
            kind: .process,
            profile: .directProcess,
            context: context,
            executable: xcrunURL,
            arguments: command.arguments,
            canonicalWorkingDirectory: command.workingDirectory,
            timeout: .seconds(command.timeoutSeconds),
            maximumInlineOutputBytes: command.maximumInlineOutputBytes,
            replayClass: command.replayClass,
            idempotencyKey: command.idempotencyKey,
            fileSizeProfile: .nativeXcodeSparseCAS,
            persistenceObserver: { record in
                Self.observePersistence(record, context: context, receipt: receipt, didPersist: didPersist, expectedFingerprint: fingerprint)
            }
        )
        let outcome = try await jobs.submitWithOutcome(request)
        if let observed = receipt.take() {
            return (try observed.get(), outcome.reused)
        }
        let record = try await jobs.status(jobID: outcome.jobID, context: context)
        try Self.validateStoredCommand(record, fingerprint: fingerprint)
        didPersist(record)
        return (record, outcome.reused)
    }

    static func observePersistence(
        _ record: RuntimeJobRecord,
        context: ToolInvocationContext,
        receipt: RuntimeBlockingResult<RuntimeJobRecord>,
        didPersist: @Sendable (RuntimeJobRecord) -> Void,
        expectedFingerprint: String? = nil
    ) {
        // createJob may return an existing row when another execution owner wins
        // its idempotency transaction. Apply the same ownership rule as job.status
        // before the committed-receipt bridge can expose that row as a success.
        guard record.projectID == context.projectID,
              record.projectGeneration == context.projectGeneration,
              record.runID == context.runID || context.runID == nil else {
            receipt.store(.failure(RuntimeJobError.jobScopeMismatch(record.jobID)))
            return
        }
        if let expectedFingerprint {
            do { try validateStoredCommand(record, fingerprint: expectedFingerprint) }
            catch { receipt.store(.failure(error)); return }
        }
        receipt.store(.success(record))
        didPersist(record)
    }


    static func nativeCommandFingerprint(
        command: XcodeCLICommand, executable: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) throws -> String {
        try ExecutionJobService.commandFingerprint(
            executable: executable, arguments: command.arguments, workingDirectory: command.workingDirectory,
            script: nil, kind: .process, profile: .directProcess, fileSizeProfile: .nativeXcodeSparseCAS
        )
    }

    static func storedCommandMatches(_ record: RuntimeJobRecord, fingerprint: String) -> Bool {
        guard record.commandSummary.contains(":command_fingerprint_v1=") else { return true }
        return ExecutionJobService.storedCommandFingerprint(record.commandSummary) == fingerprint
    }

    static func validateStoredCommand(_ record: RuntimeJobRecord, fingerprint: String) throws {
        guard storedCommandMatches(record, fingerprint: fingerprint) else {
            throw RuntimeJobError.invalidRequest("Xcode idempotency key belongs to a different native command")
        }
    }

    static func command(
        tool: String,
        arguments: [String: Any],
        context: ToolInvocationContext
    ) throws -> XcodeCLICommand {
        guard let schema = XcodeCLIToolPack.schema(for: tool),
              let properties = schema["properties"] as? [String: Any],
              Set(arguments.keys).isSubset(of: Set(properties.keys).union(["deadline_ms"])) else {
            throw RuntimeJobError.invalidRequest("Unsupported Xcode tool or argument")
        }
        for (key, definition) in properties where arguments[key] != nil {
            guard let property = definition as? [String: Any], property["type"] as? String == "string" else { continue }
            _ = try optionalString(arguments, key, maximumBytes: property["maxLength"] as? Int ?? 4_096)
        }
        if arguments["deadline_ms"] != nil {
            _ = try integer(arguments, "deadline_ms", default: 1, range: 1...ToolRouter.maximumRequestedDeadlineMilliseconds)
        }
        let cwd: URL
        if let value = try optionalString(arguments, "cwd") {
            if value.hasPrefix("/") || value.hasPrefix("~") {
                cwd = RuntimePathCanonicalizer.canonicalURL(ToolArgHelpers.resolvePath(value))
            } else if let root = context.authorizationScope.canonicalRoots.first {
                cwd = RuntimePathCanonicalizer.canonicalURL(root.appendingPathComponent(value).standardizedFileURL)
            } else {
                throw RuntimeJobError.invalidRequest("A relative cwd requires a project root")
            }
        } else if let root = context.authorizationScope.canonicalRoots.first {
            cwd = RuntimePathCanonicalizer.canonicalURL(root)
        } else {
            throw RuntimeJobError.invalidRequest("cwd is required without a project root")
        }
        _ = try boundedPath(cwd, key: "cwd")
        let isRun = tool == "xcode.run"
        let timeout = try integer(arguments, "timeout_sec", default: isRun ? 1_800 : 60, range: 1...86_400)
        let outputLimit = try integer(
            arguments, "maximum_inline_output_bytes", default: 16_384, range: 1...65_536
        )
        var argv: [String]
        var resultBundle: String?
        var derivedData: String?
        let replay: RuntimeReplayClass
        switch tool {
        case "xcode.discover":
            let query: XcodeDiscoveryQuery = try enumeration(arguments, "query")
            replay = .readOnly
            switch query {
            case .version: argv = ["xcodebuild", "-version"]
            case .sdks: argv = ["xcodebuild", "-showsdks", "-json"]
            case .schemes:
                argv = ["xcodebuild"] + (try projectArguments(arguments, cwd: cwd)) + ["-list", "-json"]
            case .destinations, .buildSettings, .testPlans:
                let flag = query == .destinations ? "-showdestinations"
                    : query == .buildSettings ? "-showBuildSettings" : "-showTestPlans"
                argv = ["xcodebuild"] + (try projectArguments(arguments, cwd: cwd))
                    + ["-scheme", try requiredString(arguments, "scheme"), flag]
                if query == .buildSettings { argv.append("-json") }
            }
        case "xcode.run":
            let action: XcodeNativeAction = try enumeration(arguments, "action")
            replay = .nonReplayable
            resultBundle = try path(arguments, "result_bundle_path", cwd: cwd, suffix: "xcresult")
            derivedData = try path(arguments, "derived_data_path", cwd: cwd)
            argv = ["xcodebuild", action.rawValue] + (try projectArguments(arguments, cwd: cwd))
                + ["-scheme", try requiredString(arguments, "scheme"),
                   "-destination", try requiredString(arguments, "destination"),
                   "-derivedDataPath", derivedData!, "-resultBundlePath", resultBundle!,
                   "-jobs", String(try integer(arguments, "jobs", default: 2, range: 1...8)),
                   "-hideShellScriptEnvironment"]
            if let configuration = try optionalString(arguments, "configuration") {
                argv += ["-configuration", configuration]
            }
            if let sdk = try optionalString(arguments, "sdk") { argv += ["-sdk", sdk] }
            let selectedTests = try strings(arguments, "only_testing", maximumCount: 64)
            if !selectedTests.isEmpty && !action.acceptsTestSelection {
                throw RuntimeJobError.invalidRequest("only_testing requires a test or build-for-testing action")
            }
            if action.executesTests {
                argv += ["-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
                         "-maximum-test-execution-time-allowance",
                         String(try integer(arguments, "test_timeout_sec", default: 300, range: 1...3_600))]
            } else if arguments["test_timeout_sec"] != nil {
                throw RuntimeJobError.invalidRequest("test_timeout_sec requires a test action")
            }
            argv += selectedTests.map { "-only-testing:\($0)" }
            if action == .archive {
                argv += ["-archivePath", try path(arguments, "archive_path", cwd: cwd, suffix: "xcarchive")]
            } else if arguments["archive_path"] != nil {
                throw RuntimeJobError.invalidRequest("archive_path requires the archive action")
            }
        case "xcode.result":
            let query: XcodeResultQuery = try enumeration(arguments, "query")
            replay = .readOnly
            resultBundle = try path(arguments, "result_bundle_path", cwd: cwd, suffix: "xcresult")
            argv = ["xcresulttool", "get"]
            switch query {
            case .buildResults: argv += ["build-results"]
            case .testSummary: argv += ["test-results", "summary"]
            case .tests: argv += ["test-results", "tests"]
            case .insights: argv += ["test-results", "insights"]
            }
            argv += ["--path", resultBundle!, "--compact"]
        case "xcode.debug":
            replay = .nonReplayable
            let commands = try strings(arguments, "commands", maximumCount: 32)
            guard !commands.isEmpty else {
                throw RuntimeJobError.invalidRequest("commands requires at least one LLDB command")
            }
            argv = ["lldb", "--batch", "--no-lldbinit", "--no-use-colors"]
            for command in commands { argv += ["--one-line", command] }
            argv += ["--", try path(arguments, "executable", cwd: cwd)]
            argv += try strings(arguments, "arguments", maximumCount: 64)
        case "xcode.simulator":
            let query: XcodeSimulatorQuery = try enumeration(arguments, "query")
            replay = .readOnly
            argv = ["simctl", "list", "--json", query.rawValue]
            if query == .devices { argv.append("available") }
        default:
            throw RuntimeJobError.invalidRequest("Unsupported Xcode tool")
        }
        guard argv.count <= 256, argv.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1_024 else {
            throw RuntimeJobError.invalidRequest("Xcode arguments exceed their byte or count limit")
        }
        let key: String?
        if let supplied = try optionalString(arguments, "idempotency_key", maximumBytes: 384) {
            // Separate native intents sharing a caller key, including from process.run.
            // A reused receipt must never describe another command's result bundle.
            let identity = try JSONSerialization.data(
                withJSONObject: [tool, cwd.path, argv, timeout, outputLimit, RuntimeFileSizeProfile.nativeXcodeSparseCAS.rawValue], options: [.sortedKeys]
            )
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            key = "xcode:\(digest):\(supplied)"
        } else { key = nil }
        return XcodeCLICommand(
            arguments: argv, workingDirectory: cwd, timeoutSeconds: timeout,
            maximumInlineOutputBytes: outputLimit, replayClass: replay, idempotencyKey: key,
            resultBundlePath: resultBundle, derivedDataPath: derivedData
        )
    }

    private static func projectArguments(_ arguments: [String: Any], cwd: URL) throws -> [String] {
        let project = try optionalString(arguments, "project")
        let workspace = try optionalString(arguments, "workspace")
        guard (project == nil) != (workspace == nil) else {
            throw RuntimeJobError.invalidRequest("Exactly one project or workspace is required")
        }
        if project != nil { return ["-project", try path(arguments, "project", cwd: cwd, suffix: "xcodeproj")] }
        return ["-workspace", try path(arguments, "workspace", cwd: cwd, suffix: "xcworkspace")]
    }

    private static func path(
        _ arguments: [String: Any], _ key: String, cwd: URL, suffix: String? = nil
    ) throws -> String {
        let value = try requiredString(arguments, key)
        let requested = value.hasPrefix("/") || value.hasPrefix("~")
            ? ToolArgHelpers.resolvePath(value) : cwd.appendingPathComponent(value).standardizedFileURL
        let url = RuntimePathCanonicalizer.canonicalURL(requested)
        if let suffix, url.pathExtension != suffix {
            throw RuntimeJobError.invalidRequest("\(key) must have the .\(suffix) extension")
        }
        return try boundedPath(url, key: key)
    }

    private static func boundedPath(_ url: URL, key: String) throws -> String {
        let value = url.path
        guard value.utf8.count <= Int(PATH_MAX), !value.contains("\0") else {
            throw RuntimeJobError.invalidRequest("\(key) exceeds the native filesystem path byte limit or contains NUL")
        }
        return value
    }

    private static func optionalString(
        _ arguments: [String: Any], _ key: String, maximumBytes: Int = 4_096
    ) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value = raw as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumBytes,
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            throw RuntimeJobError.invalidRequest("\(key) must be a nonempty bounded string without NUL or newlines")
        }
        return value
    }

    private static func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(arguments, key) else {
            throw RuntimeJobError.invalidRequest("\(key) is required")
        }
        return value
    }

    private static func integer(
        _ arguments: [String: Any], _ key: String, default defaultValue: Int, range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = arguments[key] else { return defaultValue }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound),
              number.doubleValue <= Double(range.upperBound) else {
            throw RuntimeJobError.invalidRequest("\(key) must be an integer in \(range)")
        }
        return number.intValue
    }

    private static func strings(
        _ arguments: [String: Any], _ key: String, maximumCount: Int
    ) throws -> [String] {
        guard let raw = arguments[key] else { return [] }
        guard let values = raw as? [String], values.count <= maximumCount else {
            throw RuntimeJobError.invalidRequest("\(key) must be a bounded string array")
        }
        return try values.map { try requiredString([key: $0], key) }
    }

    private static func enumeration<Value: RawRepresentable>(
        _ arguments: [String: Any], _ key: String
    ) throws -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: try requiredString(arguments, key)) else {
            throw RuntimeJobError.invalidRequest("\(key) is unsupported")
        }
        return value
    }
}
