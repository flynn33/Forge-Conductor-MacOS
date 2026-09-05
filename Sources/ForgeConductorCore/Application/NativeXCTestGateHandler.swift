import Foundation
import Darwin

/// Captured by installed native validation policy, never taken from model work
/// metadata. The manifest digest excludes the evidence written by the job.
public struct NativeGateInputs: Codable, Sendable, Equatable {
    public let sourceManifestSHA256: String
    public let buildIdentity: String
    public let policyRevision: String
    public let environmentIdentity: String

    public init(sourceManifestSHA256: String, buildIdentity: String, policyRevision: String, environmentIdentity: String) throws {
        guard sourceManifestSHA256.count == 64,
              sourceManifestSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              [buildIdentity, policyRevision, environmentIdentity].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else {
            throw AutonomyError.invalidRequest("native gate input identity is missing or invalid")
        }
        self.sourceManifestSHA256 = sourceManifestSHA256
        self.buildIdentity = buildIdentity
        self.policyRevision = policyRevision
        self.environmentIdentity = environmentIdentity
    }
}

/// Separately authorized, prebuilt XCTest policy. The plan and every executable
/// dependency must be covered by the approved package manifest. This is a native
/// composition value, not a decodable registration or a workspace command file.
public struct NativeXCTestJobPolicy: Sendable {
    let packageRoot: URL
    let packageInputs: [String]
    let packageSHA256: String
    let signedProducts: [String]
    let testRunPath: String
    let artifactRoot: URL
    let developerDirectory: URL
    let xcodeVersion: String
    let testIdentifiers: [String]
    let inputs: NativeGateInputs
    let architecture: String
    let timeoutSeconds: TimeInterval

    public init(
        packageRoot: URL, packageInputs: [String], packageSHA256: String, signedProducts: [String],
        testRunPath: String, artifactRoot: URL, developerDirectory: URL,
        xcodeVersion: String, testIdentifiers: [String], inputs: NativeGateInputs, architecture: String,
        timeoutSeconds: TimeInterval = 120
    ) throws {
        guard [packageRoot, artifactRoot, developerDirectory].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") }),
              packageSHA256.count == 64, packageSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              !signedProducts.isEmpty, signedProducts.count <= 32,
              testRunPath.hasSuffix(".xctestrun"), packageInputs.contains(testRunPath),
              !xcodeVersion.isEmpty, xcodeVersion.utf8.count <= 512,
              ["arm64", "x86_64"].contains(architecture),
              !testIdentifiers.isEmpty, testIdentifiers.count <= 64,
              Set(testIdentifiers).count == testIdentifiers.count,
              testIdentifiers.allSatisfy({ value in
                  !value.isEmpty && value.utf8.count <= 512
                      && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_/.()")).contains($0) }
              }), timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds) else {
            throw AutonomyError.invalidRequest("approved native XCTest job policy is invalid")
        }
        _ = try QualificationInputSnapshotter(root: packageRoot, inputs: packageInputs)
        _ = try QualificationInputSnapshotter(root: packageRoot, inputs: signedProducts)
        _ = try NativeGateInputs(sourceManifestSHA256: inputs.sourceManifestSHA256, buildIdentity: inputs.buildIdentity,
                                 policyRevision: inputs.policyRevision, environmentIdentity: inputs.environmentIdentity)
        self.packageRoot = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        self.packageInputs = packageInputs
        self.packageSHA256 = packageSHA256
        self.signedProducts = signedProducts
        self.testRunPath = testRunPath
        self.artifactRoot = artifactRoot.resolvingSymlinksInPath().standardizedFileURL
        self.developerDirectory = developerDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.xcodeVersion = xcodeVersion
        self.testIdentifiers = testIdentifiers.sorted()
        self.inputs = inputs
        self.architecture = architecture
        self.timeoutSeconds = timeoutSeconds
    }
}

/// One manager-owned native job at a time, using the existing bounded process
/// adapter. No shell, compiler, provider call, or model-selected argument is
/// admitted. Approval remains in the repository, never in these raw artifacts.
/// Normal project tools cannot reach the package or result store. This is not
/// protection against an unconstrained malicious process sharing the manager UID.
public actor NativeXCTestJobExecutor {
    public static let handlerIdentity = "native.xcode.test-without-building.v1"
    private let repository: ProjectControlPlaneRepository
    private let policy: NativeXCTestJobPolicy
    private let queue = DispatchQueue(label: "forge.native-gate.execution", qos: .utility)
    private var activeCancellation: ToolCallCancellation?
    private var stopped = false

    public init(repository: ProjectControlPlaneRepository, policy: NativeXCTestJobPolicy) {
        self.repository = repository
        self.policy = policy
    }

    public func shutdown() {
        stopped = true
        activeCancellation?.cancel()
    }

    public func execute(_ job: CompletionGateJob, inputs: NativeGateInputs) async throws -> ObservedNativeGateExecution {
        guard !stopped, activeCancellation == nil, inputs == policy.inputs else {
            throw AutonomyError.invalidRequest("native gate executor is busy, stopped, or bound to different build inputs")
        }
        let cancellation = ToolCallCancellation(timeoutSeconds: policy.timeoutSeconds + 90, requestID: job.jobID)
        activeCancellation = cancellation
        defer { activeCancellation = nil }
        let context = try await repository.invocationContext(for: .init(kind: .autonomousRun, id: job.run.runID.description))
        guard context.runID == job.run.runID, context.projectID == job.run.projectID,
              context.projectGeneration == job.run.projectGeneration,
              try await repository.autonomousRun(job.run.runID) == job.run else {
            throw AutonomyError.transitionConflict
        }
        let toolchain = policy.developerDirectory.lastPathComponent == "Developer"
            && policy.developerDirectory.deletingLastPathComponent().lastPathComponent == "Contents"
            ? policy.developerDirectory.deletingLastPathComponent().deletingLastPathComponent() : policy.developerDirectory
        let protectedRoots = [policy.packageRoot, policy.artifactRoot, toolchain]
        guard !Self.overlap(protectedRoots[0], protectedRoots[1]),
              context.authorizationScope.canonicalRoots.allSatisfy({ root in
                  protectedRoots.allSatisfy { !Self.overlap(root.resolvingSymlinksInPath(), $0) }
              }) else {
            throw AutonomyError.invalidRequest("native gate policy and artifacts must be outside model project roots")
        }
        let snapshotter = try QualificationInputSnapshotter(root: policy.packageRoot, inputs: policy.packageInputs,
                                                           maximumFileBytes: 128 * 1_048_576)
        let approvedPackage = try await snapshotter.capture()
        guard approvedPackage.sha256 == policy.packageSHA256, approvedPackage.absentInputs.isEmpty else {
            throw AutonomyError.invalidRequest("approved native test package changed")
        }
        let directory = try allocateDirectory(jobID: job.jobID)
        let resultBundle = directory.appendingPathComponent("result.xcresult", isDirectory: true)
        let intent = NativeJobIntent(jobID: job.jobID, nonce: job.nonce, run: job.run,
                                     inputs: inputs, packageSHA256: policy.packageSHA256,
                                     testIdentifiers: policy.testIdentifiers)
        try OwnerOnlyAtomicFile.write(try JSONEncoder().encode(intent), to: directory.appendingPathComponent("intent.json"))
        let policy = self.policy
        let raw = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NativeJobResult, Error>) in
                queue.async {
                    do { continuation.resume(returning: try Self.run(policy, directory: directory, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        guard try await snapshotter.capture().sha256 == policy.packageSHA256,
              try await repository.autonomousRun(job.run.runID) == job.run else {
            throw AutonomyError.transitionConflict
        }
        // The retained store has a finite job count. Oversized or link-bearing
        // bundles are rejected; they cannot become approving semantic evidence.
        let artifact = try await QualificationInputSnapshotter(root: directory, inputs: ["result.xcresult"],
                                                              maximumFileBytes: 128 * 1_048_576).capture()
        guard !artifact.files.isEmpty, artifact.absentInputs.isEmpty else {
            throw AutonomyError.invalidRequest("native test job produced no result artifact")
        }
        return ObservedNativeGateExecution(
            jobID: job.jobID, nonce: job.nonce, inputs: inputs, handler: Self.handlerIdentity,
            artifactPath: resultBundle.path, artifactSHA256: artifact.sha256,
            exitCode: raw.process.exitCode, terminationSignal: raw.process.terminationSignal,
            timedOut: raw.process.timedOut,
            outputTruncated: raw.process.stdoutTruncated || raw.process.stderrTruncated,
            summary: raw.summary, tests: raw.tests
        )
    }

    private func allocateDirectory(jobID: UUID) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: policy.artifactRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let stream = opendir(policy.artifactRoot.path) else { throw AutonomyError.invalidRequest("native result store is unavailable") }
        defer { closedir(stream) }
        var entries = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries < 16 else { throw AutonomyError.invalidRequest("native result retention requires authorized cleanup") }
        }
        let directory = policy.artifactRoot.appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw AutonomyError.invalidRequest("native result job identity is already present or unavailable") }
        return directory
    }

    private static func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = lhs.standardizedFileURL.path, b = rhs.standardizedFileURL.path
        return a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private struct NativeJobIntent: Encodable {
        let jobID: UUID
        let nonce: UUID
        let run: AutonomousRunRecord
        let inputs: NativeGateInputs
        let packageSHA256: String
        let testIdentifiers: [String]
    }

    private struct NativeJobResult: Sendable {
        let process: ProcessResult
        let summary: Data
        let tests: Data
    }

    private struct NativeProcessReceipt: Encodable {
        let kind = "raw_native_process_evidence"
        let gateApproval = false
        let executable: String
        let arguments: [String]
        let startedAt: String
        let finishedAt: String
        let exitCode: Int32
        let terminationSignal: Int32?
        let timedOut: Bool
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
    }

    private static func run(_ policy: NativeXCTestJobPolicy, directory: URL, cancellation: ToolCallCancellation) throws -> NativeJobResult {
        let runner = ProcessRunner(inheritEnvironment: false)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": policy.developerDirectory.path,
                           "HOME": directory.path, "TMPDIR": directory.path + "/", "LC_ALL": "C"]
        let xcodebuild = policy.developerDirectory.appendingPathComponent("usr/bin/xcodebuild").path
        func verifySignedProducts() throws {
            for relative in policy.signedProducts {
                let verification = try runner.run(
                    executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", policy.packageRoot.appendingPathComponent(relative).path],
                    environment: environment, timeoutSec: 10, maximumOutputBytes: 4_096, cancellation: cancellation
                )
                guard verification.exitCode == 0, verification.terminationSignal == nil, !verification.timedOut,
                      !verification.stdoutTruncated, !verification.stderrTruncated else {
                    throw AutonomyError.invalidRequest("approved native test product signature is invalid")
                }
            }
        }
        try verifySignedProducts()
        let version = try runner.run(executable: xcodebuild, arguments: ["-version"], environment: environment,
                                     timeoutSec: 10, maximumOutputBytes: 4_096, cancellation: cancellation)
        guard version.exitCode == 0, !version.timedOut, !version.stdoutTruncated, !version.stderrTruncated,
              version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == policy.xcodeVersion else {
            throw AutonomyError.invalidRequest("installed Xcode does not match native gate policy")
        }
        let result = directory.appendingPathComponent("result.xcresult")
        let arguments = ["-xctestrun", policy.packageRoot.appendingPathComponent(policy.testRunPath).path,
                         "-destination", "platform=macOS,arch=" + policy.architecture, "-parallel-testing-enabled", "NO",
                         "-resultBundlePath", result.path, "-test-timeouts-enabled", "YES"]
            + policy.testIdentifiers.map { "-only-testing:" + $0 } + ["test-without-building"]
        let startedAt = ISO8601.string(from: Date())
        let process = try runner.run(executable: xcodebuild, arguments: arguments, currentDirectory: directory.path,
                                     environment: environment, timeoutSec: policy.timeoutSeconds,
                                     maximumOutputBytes: 1_048_576, cancellation: cancellation)
        try OwnerOnlyAtomicFile.write(try JSONEncoder().encode(NativeProcessReceipt(
            executable: xcodebuild, arguments: arguments, startedAt: startedAt, finishedAt: ISO8601.string(from: Date()),
            exitCode: process.exitCode, terminationSignal: process.terminationSignal, timedOut: process.timedOut,
            stdoutTruncated: process.stdoutTruncated, stderrTruncated: process.stderrTruncated
        )), to: directory.appendingPathComponent("process.json"))
        try OwnerOnlyAtomicFile.write(Data(process.stdout.utf8), to: directory.appendingPathComponent("stdout.log"))
        try OwnerOnlyAtomicFile.write(Data(process.stderr.utf8), to: directory.appendingPathComponent("stderr.log"))
        try verifySignedProducts()
        let tool = policy.developerDirectory.appendingPathComponent("usr/bin/xcresulttool").path
        func extract(_ kind: String, maximumBytes: Int) throws -> Data {
            let output = try runner.run(executable: tool, arguments: ["get", "test-results", kind, "--path", result.path, "--compact"],
                                        environment: environment, timeoutSec: 30, maximumOutputBytes: maximumBytes, cancellation: cancellation)
            guard output.exitCode == 0, output.terminationSignal == nil, !output.timedOut,
                  !output.stdoutTruncated, !output.stderrTruncated else {
                throw AutonomyError.invalidRequest("native xcresult extraction failed or was incomplete")
            }
            let data = Data(output.stdout.utf8)
            try OwnerOnlyAtomicFile.write(data, to: directory.appendingPathComponent(kind + ".json"))
            return data
        }
        return NativeJobResult(process: process, summary: try extract("summary", maximumBytes: 4 * 1_048_576),
                               tests: try extract("tests", maximumBytes: 16 * 1_048_576))
    }
}

public struct NativeGateEvidence: Codable, Sendable, Equatable {
    public let inputs: NativeGateInputs
    public let handler: String
    public let artifactPath: String
    public let artifactSHA256: String
    public let summarySHA256: String
    public let testsSHA256: String
    public let exitCode: Int32
    public let terminationSignal: Int32?
    public let timedOut: Bool
    public let outputTruncated: Bool
    public let testReport: XCTestResultAdjudicator.Report
}

/// A native executor must observe the launched process and xcresulttool directly.
/// This type has no decoder and cannot be supplied through a completion request.
public struct ObservedNativeGateExecution: Sendable {
    public let jobID: UUID
    public let nonce: UUID
    public let inputs: NativeGateInputs
    public let handler: String
    public let artifactPath: String
    public let artifactSHA256: String
    public let exitCode: Int32
    public let terminationSignal: Int32?
    public let timedOut: Bool
    public let outputTruncated: Bool
    public let summary: Data
    public let tests: Data

    public init(
        jobID: UUID, nonce: UUID, inputs: NativeGateInputs, handler: String,
        artifactPath: String, artifactSHA256: String, exitCode: Int32,
        terminationSignal: Int32? = nil, timedOut: Bool = false, outputTruncated: Bool = false,
        summary: Data, tests: Data
    ) {
        self.jobID = jobID
        self.nonce = nonce
        self.inputs = inputs
        self.handler = handler
        self.artifactPath = artifactPath
        self.artifactSHA256 = artifactSHA256
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.timedOut = timedOut
        self.outputTruncated = outputTruncated
        self.summary = summary
        self.tests = tests
    }
}

/// Native policy supplies both operations; there is no shell-command, artifact-
/// path, or registration field in the model-facing completion request. Register
/// only installed handlers or separately authorized immutable validation packages.
public struct NativeXCTestGateHandler: Sendable {
    public typealias InputCapture = @Sendable (AutonomousRunRecord) async throws -> NativeGateInputs
    public typealias JobExecution = @Sendable (CompletionGateJob, NativeGateInputs) async throws -> ObservedNativeGateExecution

    private let gate: String
    private let version: UInt64
    private let handler: String
    private let policyRevision: String
    private let environmentIdentity: String
    private let requiredCases: Set<String>
    private let minimumCaseCount: Int
    private let captureInputs: InputCapture
    private let execute: JobExecution
    private let clock: any Clock

    public init(
        gate: String, version: UInt64, handler: String, policyRevision: String,
        environmentIdentity: String, requiredCases: Set<String>, minimumCaseCount: Int,
        clock: any Clock = SystemClock(), captureInputs: @escaping InputCapture,
        execute: @escaping JobExecution
    ) throws {
        guard version > 0, !requiredCases.isEmpty, requiredCases.count <= 10_000,
              (requiredCases.count...10_000).contains(minimumCaseCount),
              [gate, handler, policyRevision, environmentIdentity].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw AutonomyError.invalidRequest("installed native gate policy is invalid")
        }
        self.gate = gate
        self.version = version
        self.handler = handler
        self.policyRevision = policyRevision
        self.environmentIdentity = environmentIdentity
        self.requiredCases = requiredCases
        self.minimumCaseCount = minimumCaseCount
        self.clock = clock
        self.captureInputs = captureInputs
        self.execute = execute
    }

    public var validator: CompletionGateValidator {
        CompletionGateValidator(gate: gate, version: version, jobOperation: { job in try await evaluate(job) })
    }

    private func evaluate(_ job: CompletionGateJob) async throws -> CompletionGateResult {
        let before = try await captureInputs(job.run)
        guard before.policyRevision == policyRevision, before.environmentIdentity == environmentIdentity else {
            return CompletionGateResult(
                gate: gate, passed: false,
                summary: "Required installed policy or native environment is unavailable",
                blocker: .unavailableEnvironment
            )
        }
        try Task.checkCancellation()
        let observed = try await execute(job, before)
        try Task.checkCancellation()
        let after = try await captureInputs(job.run)
        guard before == after, observed.inputs == before else {
            return rejected("Qualification inputs changed during validation; evidence is stale")
        }
        guard observed.jobID == job.jobID, observed.nonce == job.nonce,
              observed.handler == handler else {
            return rejected("Native result belongs to a different job or installed handler")
        }
        guard observed.exitCode == 0, observed.terminationSignal == nil,
              !observed.timedOut, !observed.outputTruncated else {
            return rejected("Native validation did not finish successfully with complete output")
        }
        guard observed.artifactPath.hasPrefix("/"), observed.artifactPath.utf8.count <= 2_048,
              observed.artifactSHA256.count == 64,
              observed.artifactSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return rejected("Native result artifact identity is missing")
        }
        let report = try XCTestResultAdjudicator.adjudicate(
            summary: observed.summary, tests: observed.tests,
            requiredCases: requiredCases, minimumCaseCount: minimumCaseCount
        )
        guard let started = ISO8601.date(from: job.startedAt),
              report.startedAt >= started.addingTimeInterval(-1),
              report.finishedAt <= clock.now().addingTimeInterval(1) else {
            return rejected("Native test result timing does not match the current job")
        }
        return CompletionGateResult(
            gate: gate, passed: report.passed,
            summary: report.passed ? "Required native assertions passed" : "Required native assertions did not all pass",
            evidenceReferences: [observed.artifactSHA256],
            nativeEvidence: NativeGateEvidence(
                inputs: before, handler: handler, artifactPath: observed.artifactPath,
                artifactSHA256: observed.artifactSHA256,
                summarySHA256: JSONSupport.sha256Hex(observed.summary),
                testsSHA256: JSONSupport.sha256Hex(observed.tests),
                exitCode: observed.exitCode, terminationSignal: observed.terminationSignal,
                timedOut: observed.timedOut, outputTruncated: observed.outputTruncated,
                testReport: report
            )
        )
    }

    private func rejected(_ summary: String) -> CompletionGateResult {
        CompletionGateResult(gate: gate, passed: false, summary: summary)
    }
}
