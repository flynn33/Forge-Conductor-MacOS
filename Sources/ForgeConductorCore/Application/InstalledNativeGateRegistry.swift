import Foundation

/// Versioned operator-installed data selects only the compiled native XCTest
/// handler. There is no command, executable, shell, environment, or model tool
/// for installing definitions. A policy is bound to one run and generation.
struct InstalledNativeGatePolicy: Codable, Sendable {
    struct Gate: Codable, Sendable {
        let id: String
        let version: UInt64
        let packageID: UUID
        let packageInputs: [String]
        let packageSHA256: String
        let signedProducts: [String]
        let testRunPath: String
        let testIdentifiers: [String]
        let requiredCases: Set<String>
        let minimumCaseCount: Int
        let timeoutSeconds: TimeInterval
    }

    let schemaVersion: Int
    let policyRevision: String
    let runID: RunID
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let sourceInputs: [String]
    /// Prebuilt application qualification binds the candidate source as well as
    /// test-package bytes. Output-only tasks may capture mutable work products.
    let candidateSourceSHA256: String?
    let buildIdentity: String
    let xcodeVersion: String
    let architecture: String
    let correctionCaseBindings: [String: String]
    let gates: [Gate]

    func validate(for run: AutonomousRunRecord) throws {
        guard schemaVersion == 1,
              policyRevision == CompletionGateAcceptancePolicy.correction001Revision,
              runID == run.runID, projectID == run.projectID, projectGeneration == run.projectGeneration,
              !buildIdentity.isEmpty, buildIdentity.utf8.count <= 512,
              !xcodeVersion.isEmpty, xcodeVersion.utf8.count <= 512,
              ["arm64", "x86_64"].contains(architecture),
              !gates.isEmpty, gates.count <= 32, Set(gates.map(\.id)).count == gates.count,
              gates.allSatisfy({ gate in
                  !gate.id.isEmpty && gate.id != "." && gate.id != ".." && gate.id.utf8.count <= 128
                      && gate.id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }
                      && gate.version >= 2
              }) else {
            throw AutonomyError.invalidRequest("installed native gate policy has invalid or stale identity")
        }
        let packageGates = Set((0...14).map { String(format: "G%02d", $0) })
        if gates.contains(where: { packageGates.contains($0.id) }) || candidateSourceSHA256 != nil {
            guard let digest = candidateSourceSHA256, digest.count == 64,
                  digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw AutonomyError.invalidRequest("prebuilt qualification requires its approved candidate source digest")
            }
        }
        _ = try CompletionGateAcceptancePolicy.correction001(caseBindings: correctionCaseBindings)
    }
}

/// The manager's production completion dependency. Each validation loads a
/// bounded, no-follow policy from its protected namespace; workspace JSON and
/// model result hashes never register a handler. Definitions are immutable for
/// the activation and rechecked around every native job. Restart revalidates.
public actor InstalledNativeGateRegistry: RunCompletionValidating {
    private let repository: ProjectControlPlaneRepository
    private let root: URL
    private let clock: any Clock
    private var active: [UUID: [NativeXCTestJobExecutor]] = [:]
    private var stopped = false

    public init(repository: ProjectControlPlaneRepository, paths: AppPaths, clock: any Clock = SystemClock()) {
        self.repository = repository
        root = paths.nativeValidationDir
        self.clock = clock
    }

    public func shutdown() async {
        stopped = true
        for executors in active.values {
            for executor in executors { await executor.shutdown() }
        }
    }

    public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        guard run.state == .validatingCompletion else { throw AutonomyError.completionValidationRequired }
        guard !run.specification.completionGates.isEmpty, run.specification.completionGates.count <= 256,
              Set(run.specification.completionGates).count == run.specification.completionGates.count else {
            throw AutonomyError.completionValidationFailed
        }
        guard !stopped, active.count < 4 else {
            return try blocked(run, summary: "Native validation is stopped or at its concurrency limit")
        }
        let activation = UUID()
        active[activation] = []
        do {
            let registry = try await makeRegistry(for: run, activation: activation)
            let result = try await registry.validate(run)
            await finish(activation)
            return result
        } catch is CancellationError {
            await finish(activation)
            throw CancellationError()
        } catch {
            await finish(activation)
            return try blocked(run, summary: "Installed native validation is unavailable or invalid: \(error.localizedDescription.prefix(1_500))")
        }
    }

    private func finish(_ activation: UUID) async {
        let executors = active.removeValue(forKey: activation) ?? []
        for executor in executors { await executor.shutdown() }
    }

    private func blocked(_ run: AutonomousRunRecord, summary: String) throws -> CompletionValidationReceipt {
        try CompletionValidationReceipt.make(
            runID: run.runID, expectedRevision: run.revision,
            results: run.specification.completionGates.map {
                CompletionGateResult(gate: $0, passed: false, summary: summary, blocker: .unavailableEnvironment)
            }, validatedAt: ISO8601.string(from: clock.now())
        )
    }

    private func makeRegistry(for run: AutonomousRunRecord, activation: UUID) async throws -> GateValidatorRegistry {
        let relativePolicy = "policies/\(run.runID.description).json"
        let policySnapshotter = try QualificationInputSnapshotter(root: root, inputs: [relativePolicy],
                                                                 maximumBytes: 256 * 1_024, maximumFiles: 1,
                                                                 maximumFileBytes: 256 * 1_024)
        let policySnapshot = try await policySnapshotter.capture()
        guard policySnapshot.absentInputs.isEmpty, policySnapshot.files.count == 1,
              let file = policySnapshot.files.first, file.mode & 0o077 == 0 else {
            throw AutonomyError.invalidRequest("native gate policy must be an owner-only regular file")
        }
        let data = try OwnerOnlyAtomicFile.read(from: root.appendingPathComponent(relativePolicy), maximumBytes: 256 * 1_024)
        guard JSONSupport.sha256Hex(data) == file.sha256,
              try await policySnapshotter.capture() == policySnapshot else {
            throw AutonomyError.invalidRequest("native gate policy changed while loading")
        }
        let policy = try JSONDecoder().decode(InstalledNativeGatePolicy.self, from: data)
        try policy.validate(for: run)
        guard let project = try await repository.project(run.projectID),
              project.generation == run.projectGeneration,
              try await repository.autonomousRun(run.runID) == run else {
            throw AutonomyError.transitionConflict
        }
        let source = try QualificationInputSnapshotter(root: project.canonicalRoot, inputs: policy.sourceInputs)
        let policyDigest = file.sha256
        var validators: [CompletionGateValidator] = []
        for definition in policy.gates {
            try Task.checkCancellation()
            guard !stopped else { throw AutonomyError.shutdown }
            let capture: NativeXCTestGateHandler.InputCapture = { current in
                guard current.runID == policy.runID, current.projectID == policy.projectID,
                      current.projectGeneration == policy.projectGeneration,
                      try await policySnapshotter.capture() == policySnapshot else {
                    throw AutonomyError.transitionConflict
                }
                let snapshot = try await source.capture()
                guard !snapshot.files.isEmpty, snapshot.absentInputs.isEmpty else {
                    throw AutonomyError.invalidRequest("required qualification inputs are missing")
                }
                return try NativeGateInputs(
                    sourceManifestSHA256: snapshot.sha256,
                    buildIdentity: "\(policy.buildIdentity):package=\(definition.packageSHA256):policy=\(policyDigest)",
                    policyRevision: policy.policyRevision, environmentIdentity: "\(policy.xcodeVersion):\(policy.architecture):\(ProcessInfo.processInfo.operatingSystemVersionString)"
                )
            }
            let inputs = try await capture(run)
            if let expectedSource = policy.candidateSourceSHA256, inputs.sourceManifestSHA256 != expectedSource {
                throw AutonomyError.invalidRequest("prebuilt native policy belongs to a different source snapshot")
            }
            guard !stopped else { throw AutonomyError.shutdown }
            let packageRoot = root.appendingPathComponent("packages/\(definition.packageID.uuidString.lowercased())")
            // A package alias cannot escape the manager's protected namespace.
            guard packageRoot.resolvingSymlinksInPath().path == packageRoot.standardizedFileURL.path else {
                throw AutonomyError.invalidRequest("installed native package contains an aliased root")
            }
            let executor = NativeXCTestJobExecutor(repository: repository, policy: try NativeXCTestJobPolicy(
                packageRoot: packageRoot, packageInputs: definition.packageInputs, packageSHA256: definition.packageSHA256,
                signedProducts: definition.signedProducts, testRunPath: definition.testRunPath,
                artifactRoot: root.appendingPathComponent("results/\(run.runID.description)/\(definition.id)"),
                developerDirectory: AppPaths.nativeValidationDeveloperDirectory, xcodeVersion: policy.xcodeVersion,
                testIdentifiers: definition.testIdentifiers, inputs: inputs, architecture: policy.architecture,
                timeoutSeconds: definition.timeoutSeconds
            ))
            active[activation, default: []].append(executor)
            let handler = try NativeXCTestGateHandler(
                gate: definition.id, version: definition.version, handler: NativeXCTestJobExecutor.handlerIdentity,
                policyRevision: policy.policyRevision, environmentIdentity: inputs.environmentIdentity,
                requiredCases: definition.requiredCases, minimumCaseCount: definition.minimumCaseCount,
                clock: clock, captureInputs: capture,
                execute: { job, captured in try await executor.execute(job, inputs: captured) }
            )
            validators.append(handler.validator)
        }
        return try GateValidatorRegistry(validators: validators, clock: clock,
                                        acceptancePolicy: .correction001(caseBindings: policy.correctionCaseBindings))
    }
}
