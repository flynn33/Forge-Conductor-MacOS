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
        try validate(runID: run.runID, projectID: run.projectID,
                     projectGeneration: run.projectGeneration)
    }

    func validate(runID: RunID, projectID: ProjectID,
                  projectGeneration: ProjectGeneration) throws {
        guard schemaVersion == 1,
              policyRevision == CompletionGateAcceptancePolicy.correction001Revision,
              self.runID == runID, self.projectID == projectID,
              self.projectGeneration == projectGeneration,
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

/// Installs a separately prepared operator policy into the protected Forge home.
/// Import checks the immutable run binding and approved package/source manifests;
/// only the manager's compiled native handler can adjudicate test results.
public actor NativeValidationPolicyInstaller {
    public struct RunBinding: Sendable {
        public let runID: RunID
        public let projectID: ProjectID
        public let projectGeneration: ProjectGeneration
        public let completionGates: [String]
        public let projectRoot: URL

        public init(runID: RunID, projectID: ProjectID,
                    projectGeneration: ProjectGeneration,
                    completionGates: [String], projectRoot: URL) {
            self.runID = runID
            self.projectID = projectID
            self.projectGeneration = projectGeneration
            self.completionGates = completionGates
            self.projectRoot = projectRoot
        }
    }

    public struct Receipt: Sendable {
        public let runID: String
        public let policySHA256: String
        public let installedPath: String
    }

    private let root: URL

    public init(paths: AppPaths = AppPaths()) {
        root = paths.nativeValidationDir
    }

    public func importPolicy(from sourceFile: URL, for binding: RunBinding) async throws -> Receipt {
        guard sourceFile.isFileURL, sourceFile.path.hasPrefix("/"),
              binding.projectRoot.isFileURL, binding.projectRoot.path.hasPrefix("/"),
              !binding.completionGates.isEmpty, binding.completionGates.count <= 32,
              Set(binding.completionGates).count == binding.completionGates.count,
              root.resolvingSymlinksInPath().path == root.standardizedFileURL.path,
              !Self.overlap(root, binding.projectRoot) else {
            throw AutonomyError.invalidRequest("native policy import requires a separate protected home and exact run gates")
        }
        let data = try OwnerOnlyAtomicFile.read(from: sourceFile, maximumBytes: 256 * 1_024)
        let policy = try JSONDecoder().decode(InstalledNativeGatePolicy.self, from: data)
        try policy.validate(runID: binding.runID, projectID: binding.projectID,
                            projectGeneration: binding.projectGeneration)
        guard Set(policy.gates.map(\.id)) == Set(binding.completionGates) else {
            throw AutonomyError.invalidRequest("native policy gates do not match the managed run")
        }

        let source = try QualificationInputSnapshotter(root: binding.projectRoot,
                                                       inputs: policy.sourceInputs)
        let sourceSnapshot = try await source.capture()
        guard !sourceSnapshot.files.isEmpty, sourceSnapshot.absentInputs.isEmpty,
              policy.candidateSourceSHA256 == nil
                || sourceSnapshot.sha256 == policy.candidateSourceSHA256 else {
            throw AutonomyError.invalidRequest("native policy source inputs are missing or stale")
        }

        var packages: [(QualificationInputSnapshotter, String)] = []
        for gate in policy.gates {
            try Task.checkCancellation()
            let packageRoot = root.appendingPathComponent("packages/\(gate.packageID.uuidString.lowercased())")
            guard packageRoot.resolvingSymlinksInPath().path == packageRoot.standardizedFileURL.path else {
                throw AutonomyError.invalidRequest("native policy package root is aliased")
            }
            let snapshotter = try QualificationInputSnapshotter(
                root: packageRoot, inputs: gate.packageInputs,
                maximumFileBytes: 128 * 1_048_576
            )
            let snapshot = try await snapshotter.capture()
            guard !snapshot.files.isEmpty, snapshot.absentInputs.isEmpty,
                  snapshot.sha256 == gate.packageSHA256 else {
                throw AutonomyError.invalidRequest("approved native test package is missing or changed")
            }
            guard gate.signedProducts.allSatisfy({ product in
                gate.packageInputs.contains(where: { input in
                    input == product || input.hasPrefix(product + "/")
                })
            }) else {
                throw AutonomyError.invalidRequest("signed native products are outside the approved package manifest")
            }
            let inputs = try NativeGateInputs(
                sourceManifestSHA256: sourceSnapshot.sha256,
                buildIdentity: policy.buildIdentity,
                policyRevision: policy.policyRevision,
                environmentIdentity: "\(policy.xcodeVersion):\(policy.architecture)"
            )
            _ = try NativeXCTestJobPolicy(
                packageRoot: packageRoot, packageInputs: gate.packageInputs,
                packageSHA256: gate.packageSHA256, signedProducts: gate.signedProducts,
                testRunPath: gate.testRunPath,
                artifactRoot: root.appendingPathComponent("results/\(binding.runID.description)/\(gate.id)"),
                developerDirectory: AppPaths.nativeValidationDeveloperDirectory,
                xcodeVersion: policy.xcodeVersion, testIdentifiers: gate.testIdentifiers,
                inputs: inputs, architecture: policy.architecture,
                timeoutSeconds: gate.timeoutSeconds
            )
            packages.append((snapshotter, snapshot.sha256))
        }

        guard try await source.capture() == sourceSnapshot,
              try OwnerOnlyAtomicFile.read(from: sourceFile, maximumBytes: 256 * 1_024) == data else {
            throw AutonomyError.invalidRequest("native policy or source changed during import")
        }
        for (snapshotter, digest) in packages {
            guard try await snapshotter.capture().sha256 == digest else {
                throw AutonomyError.invalidRequest("native test package changed during import")
            }
        }
        try Task.checkCancellation()
        let destination = root.appendingPathComponent("policies/\(binding.runID.description).json")
        guard destination.deletingLastPathComponent().resolvingSymlinksInPath().path
                == destination.deletingLastPathComponent().standardizedFileURL.path else {
            throw AutonomyError.invalidRequest("native policy directory is aliased")
        }
        try OwnerOnlyAtomicFile.write(data, to: destination)
        guard try OwnerOnlyAtomicFile.read(from: destination, maximumBytes: 256 * 1_024) == data else {
            throw AutonomyError.invalidRequest("native policy import did not persist exact bytes")
        }
        return Receipt(runID: binding.runID.description,
                       policySHA256: JSONSupport.sha256Hex(data),
                       installedPath: destination.path)
    }

    private static func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let first = lhs.standardizedFileURL.pathComponents
        let second = rhs.standardizedFileURL.pathComponents
        return first.starts(with: second) || second.starts(with: first)
    }
}

/// The manager's production completion dependency. Instruction packages own
/// their completion identifiers, and Forge evaluates every identifier through
/// the compiled, run-bound evidence plan. Configuration never installs or
/// selects a separate gate policy.
public actor InstalledNativeGateRegistry: RunCompletionValidating {
    private let repository: ProjectControlPlaneRepository
    private let clock: any Clock
    private let runtimeJobs: ExecutionJobService?
    private var stopped = false

    public init(
        repository: ProjectControlPlaneRepository,
        paths _: AppPaths,
        clock: any Clock = SystemClock(),
        runtimeJobs: ExecutionJobService? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.runtimeJobs = runtimeJobs
    }

    public func shutdown() async {
        stopped = true
    }

    public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
        guard run.state == .validatingCompletion else { throw AutonomyError.completionValidationRequired }
        guard !run.specification.completionGates.isEmpty, run.specification.completionGates.count <= 256,
              Set(run.specification.completionGates).count == run.specification.completionGates.count else {
            throw AutonomyError.completionValidationFailed
        }
        let allGates = run.specification.completionGates
        guard !stopped else {
            return try receipt(
                for: run,
                orderedResults: blockedResults(
                    gates: allGates,
                    summary: "Completion validation is stopped"
                )
            )
        }
        let automaticResults = try await automaticResults(
            for: run,
            gates: allGates
        )
        return try receipt(for: run, orderedResults: automaticResults)
    }

    private func automaticResults(
        for run: AutonomousRunRecord,
        gates: [String]
    ) async throws -> [CompletionGateResult] {
        guard !gates.isEmpty else { return [] }
        let aggregate = try await ProjectInstructionCompletionGate.result(
            run: run,
            repository: repository,
            runtimeJobs: runtimeJobs
        )
        let validators = gates.map { gate in
            CompletionGateValidator(gate: gate, version: 1) { current in
                guard current == run else { throw AutonomyError.transitionConflict }
                return CompletionGateResult(
                    gate: gate,
                    passed: aggregate.passed,
                    summary: aggregate.summary,
                    evidenceReferences: aggregate.evidenceReferences,
                    blocker: aggregate.blocker
                )
            }
        }
        let evaluated = try await GateValidatorRegistry(
            validators: validators,
            clock: clock
        ).validate(run)
        return evaluated.results.filter { gates.contains($0.gate) }
    }

    private func blockedResults(
        gates: [String],
        summary: String,
        blocker: CompletionGateBlocker = .unavailableEnvironment
    ) -> [CompletionGateResult] {
        gates.map {
            CompletionGateResult(
                gate: $0,
                passed: false,
                summary: summary,
                blocker: blocker
            )
        }
    }

    private func receipt(
        for run: AutonomousRunRecord,
        orderedResults results: [CompletionGateResult]
    ) throws -> CompletionValidationReceipt {
        let byGate = Dictionary(uniqueKeysWithValues: results.map { ($0.gate, $0) })
        let ordered = try run.specification.completionGates.map { gate in
            guard let result = byGate[gate] else {
                throw AutonomyError.completionValidationFailed
            }
            return result
        }
        return try CompletionValidationReceipt.make(
            runID: run.runID,
            expectedRevision: run.revision,
            results: ordered,
            validatedAt: ISO8601.string(from: clock.now())
        )
    }

}

/// Fixed manager-owned validator for ordinary instruction packages. It pages
/// exact durable records and retains only the latest bounded evidence needed by
/// each typed obligation. Failed attempts remain history; a later relevant pass
/// may supersede them without allowing an unrelated success to prove the task.
enum ProjectInstructionCompletionGate {
    static let pageSize = 128
    static let maximumEvidenceRecords = 65_536

    static func result(
        run: AutonomousRunRecord,
        repository: ProjectControlPlaneRepository,
        runtimeJobs: ExecutionJobService? = nil
    ) async throws -> CompletionGateResult {
        var accumulator = EvidenceAccumulator(run: run)
        let nativeDeadline = ContinuousClock().now.advanced(by: .seconds(10))
        var cursor: ToolInvocationPageCursor?
        repeat {
            let page = try await repository.toolInvocations(
                runID: run.runID,
                after: cursor,
                limit: pageSize
            )
            try accumulator.consume(page)
            if let runtimeJobs {
                try await accumulator.consumeNativeXcode(page, repository: repository, jobs: runtimeJobs, deadline: nativeDeadline)
            }
            guard let last = page.last, page.count == pageSize else { break }
            cursor = ToolInvocationPageCursor(
                createdAt: last.createdAt,
                invocationID: last.invocationID
            )
        } while true
        if let runtimeJobs {
            try await accumulator.finishNativeXcode(repository: repository, jobs: runtimeJobs, deadline: nativeDeadline)
        }
        let delivery = run.specification.completionPlan?.obligations.contains {
            $0.kind == .instructionDeliveryComplete
        } == true ? try await repository.instructionDeliveryProgress(run: run) : nil
        return accumulator.result(instructionDelivery: delivery)
    }

    struct EvidenceAccumulator {
        private struct LatestEvidence {
            let successful: Bool
            let reference: String?
            let effectiveAt: String?
            let identity: String?
            init(successful: Bool, reference: String?, effectiveAt: String? = nil, identity: String? = nil) {
                self.successful = successful; self.reference = reference
                self.effectiveAt = effectiveAt; self.identity = identity
            }
        }

        private let run: AutonomousRunRecord
        private var recordCount = 0
        private var invalidScope = false
        private var unresolvedInvocation = false
        private var latestRelevantRead: LatestEvidence?
        private var latestBuild: LatestEvidence?
        private var latestBuildWarningFree: LatestEvidence?
        private var latestTests: LatestEvidence?
        private var latestLegacyEvidence: LatestEvidence?
        private var nativeBuild: ProjectInstructionCompletionGate.XcodeCandidate?
        private var nativeTests: ProjectInstructionCompletionGate.XcodeCandidate?
        private var nativeBuildAmbiguous = false
        private var nativeTestsAmbiguous = false
        private var nativeUnresolved = false
        private var invalidNativeEvidence = false
        private let successfulDesktopTools: Set<String>
        private let desktopToolReference: String?

        init(run: AutonomousRunRecord) {
            self.run = run
            let encoded = run.specification.work.metadata[
                DesktopProviderEvidenceMetadata.successfulToolNames
            ]
            if let encoded,
               encoded.utf8.count <= 16_384,
               let data = encoded.data(using: .utf8),
               let names = try? JSONDecoder().decode([String].self, from: data),
               names.count <= 256,
               Set(names).isSubset(of: Set(run.specification.allowedTools)) {
                successfulDesktopTools = Set(names)
                desktopToolReference = "desktop-hook:" + JSONSupport.sha256Hex(encoded)
            } else {
                successfulDesktopTools = []
                desktopToolReference = nil
            }
        }

        mutating func consume(_ records: [ToolInvocationRecord]) throws {
            guard records.count <= ProjectInstructionCompletionGate.pageSize else {
                throw AutonomyError.invalidRequest("completion evidence page exceeded its bound")
            }
            guard recordCount <= ProjectInstructionCompletionGate.maximumEvidenceRecords - records.count else {
                throw AutonomyError.completionValidationFailed
            }
            recordCount += records.count
            for invocation in records {
                guard invocation.runID == run.runID,
                      invocation.projectID == run.projectID,
                      invocation.projectGeneration == run.projectGeneration else {
                    invalidScope = true
                    continue
                }
                if [.intent, .executing, .ambiguous].contains(invocation.state) {
                    unresolvedInvocation = true
                }
                let evidence = Self.evidence(invocation)
                latestLegacyEvidence = evidence
                if Self.isRelevantRead(invocation.toolName, plan: run.specification.completionPlan) {
                    latestRelevantRead = evidence
                }
                guard invocation.toolName == "shell_exec",
                      let command = Self.shellCommand(invocation) else { continue }
                let categories = Self.shellCategories(command)
                if categories.contains(.build) {
                    latestBuild = evidence
                    latestBuildWarningFree = Self.warningFreeEvidence(invocation, base: evidence)
                }
                if categories.contains(.tests) { latestTests = evidence }
            }
        }

        func result(
            instructionDelivery: InstructionDeliveryProgress? = nil
        ) -> CompletionGateResult {
            let gate = ProjectInstructionQueueStore.builtInCompletionGate
            guard !invalidScope else {
                return CompletionGateResult(
                    gate: gate,
                    passed: false,
                    summary: "Completion evidence included a different project, generation, or run"
                )
            }
            guard !invalidNativeEvidence else {
                return CompletionGateResult(gate: gate, passed: false,
                    summary: "Typed Xcode completion evidence is unavailable, changed, or exceeded its validation bound")
            }
            guard !unresolvedInvocation, !nativeUnresolved, run.specification.work.pendingIntent == nil else {
                return CompletionGateResult(
                    gate: gate,
                    passed: false,
                    summary: "A relevant operation remains in flight or ambiguous"
                )
            }
            guard let plan = run.specification.completionPlan else {
                guard latestLegacyEvidence?.successful == true else {
                    return CompletionGateResult(
                        gate: gate,
                        passed: false,
                        summary: "The legacy task has no successful committed project tool result"
                    )
                }
                return CompletionGateResult(
                    gate: gate,
                    passed: true,
                    summary: "The legacy task has resolved history and a successful durable tool result",
                    evidenceReferences: Self.references([latestLegacyEvidence])
                )
            }
            guard Self.plan(plan, matches: run) else {
                return CompletionGateResult(
                    gate: gate,
                    passed: false,
                    summary: "The completion plan does not match the final project, source, or plan revision"
                )
            }

            var unsatisfied: [String] = []
            var references: [String] = []
            for obligation in plan.obligations where obligation.kind != .customNativeGate {
                let evidence: LatestEvidence?
                let satisfied: Bool
                switch obligation.kind {
                case .artifactRegistered:
                    evidence = nil
                    satisfied = Self.artifactRegistrationMatches(plan, run: run)
                case .projectBuild:
                    evidence = latestBuild
                    satisfied = latestBuild?.successful == true
                case .projectBuildNoWarnings:
                    evidence = latestBuildWarningFree
                    satisfied = latestBuildWarningFree?.successful == true
                case .projectTests:
                    evidence = latestTests
                    satisfied = latestTests?.successful == true
                case .instructionDeliveryComplete:
                    evidence = nil
                    satisfied = Self.deliveryIsComplete(instructionDelivery)
                case .readOnlyReportDelivered:
                    let desktopRead = obligation.relevantToolNames.contains {
                        successfulDesktopTools.contains($0)
                    }
                    evidence = latestRelevantRead ?? (desktopRead
                        ? LatestEvidence(successful: true, reference: desktopToolReference)
                        : nil)
                    satisfied = run.completionRequestJSON != nil
                        && evidence?.successful == true
                case .noRelevantUnresolvedSideEffect:
                    evidence = nil
                    satisfied = true
                case .requestedFileExists, .requestedContentAssertion,
                     .structuredDocumentValid, .runtimeJobSucceeded:
                    evidence = nil
                    satisfied = false
                case .customNativeGate:
                    evidence = nil
                    satisfied = true
                }
                if let reference = evidence?.reference, satisfied, !references.contains(reference),
                   references.count < 256 {
                    references.append(reference)
                }
                if !satisfied || obligation.humanReviewRequired {
                    unsatisfied.append(obligation.id)
                }
            }
            guard unsatisfied.isEmpty else {
                return CompletionGateResult(
                    gate: gate,
                    passed: false,
                    summary: "Unsatisfied automatic completion obligations: "
                        + unsatisfied.prefix(16).joined(separator: ", "),
                    evidenceReferences: references
                )
            }
            return CompletionGateResult(
                gate: gate,
                passed: true,
                summary: "All \(plan.obligations.filter { $0.kind != .customNativeGate }.count) automatic completion obligations passed using \(recordCount) paged evidence records",
                evidenceReferences: references
            )
        }

        private enum ShellCategory: Hashable { case build, tests }

        private static func evidence(_ invocation: ToolInvocationRecord) -> LatestEvidence {
            guard invocation.state == .completed,
                  invocation.lastErrorCode == nil,
                  invocation.lastErrorSummary == nil,
                  let summary = invocation.resultSummary,
                  let digest = invocation.resultSHA256,
                  JSONSupport.sha256Hex(summary) == digest,
                  let data = summary.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["ok"] as? Bool == true,
                  object["is_error"] as? Bool == false else {
                return LatestEvidence(successful: false, reference: nil, effectiveAt: invocation.updatedAt, identity: invocation.invocationID.uuidString.lowercased())
            }
            return LatestEvidence(successful: true, reference: digest, effectiveAt: invocation.updatedAt, identity: invocation.invocationID.uuidString.lowercased())
        }

        private static func isRelevantRead(
            _ toolName: String,
            plan: AutomaticCompletionPlan?
        ) -> Bool {
            let names = plan?.obligations
                .filter { $0.kind == .readOnlyReportDelivered }
                .flatMap(\.relevantToolNames) ?? []
            return names.contains(toolName)
        }

        private static func shellCommand(_ invocation: ToolInvocationRecord) -> String? {
            guard let summary = invocation.resultSummary,
                  let data = summary.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let command = payload["command"] as? String,
                  !command.isEmpty, command.utf8.count <= 16_384 else { return nil }
            return command
        }

        private static func warningFreeEvidence(
            _ invocation: ToolInvocationRecord,
            base: LatestEvidence
        ) -> LatestEvidence {
            guard base.successful,
                  let summary = invocation.resultSummary,
                  let data = summary.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["stdout_truncated"] as? Bool == false,
                  payload["stderr_truncated"] as? Bool == false,
                  let stdout = payload["stdout"] as? String,
                  let stderr = payload["stderr"] as? String else {
                return LatestEvidence(successful: false, reference: nil, effectiveAt: base.effectiveAt, identity: base.identity)
            }
            let output = (stdout + "\n" + stderr).lowercased()
            let hasWarning = output.split(separator: "\n").contains { line in
                line.contains("warning:")
            }
            return LatestEvidence(
                successful: !hasWarning,
                reference: hasWarning ? nil : base.reference, effectiveAt: base.effectiveAt, identity: base.identity
            )
        }

        private static func deliveryIsComplete(_ progress: InstructionDeliveryProgress?) -> Bool {
            guard let progress, !progress.artifacts.isEmpty else { return false }
            return progress.artifacts.allSatisfy { artifact in
                guard let total = artifact.totalDocuments, total > 0 else { return false }
                let completed = artifact.completedDocumentBitmap.reduce(0) {
                    $0 + $1.nonzeroBitCount
                }
                return completed >= total
            }
        }

        private static func shellCategories(_ command: String) -> Set<ShellCategory> {
            let words = command.lowercased().split { character in
                !character.isLetter && !character.isNumber && character != "-"
            }.map(String.init)
            let pairs = zip(words, words.dropFirst())
            var categories: Set<ShellCategory> = []
            if pairs.contains(where: { $0 == "swift" && $1 == "build" }) {
                categories.insert(.build)
            }
            if pairs.contains(where: { $0 == "swift" && $1 == "test" }) {
                categories.insert(.tests)
            }
            if words.contains("xcodebuild") {
                if words.contains("build") || words.contains("archive")
                    || words.contains("build-for-testing") {
                    categories.insert(.build)
                }
                if words.contains("test") || words.contains("test-without-building") {
                    categories.insert(.tests)
                }
            }
            return categories
        }

        private static func plan(
            _ plan: AutomaticCompletionPlan,
            matches run: AutonomousRunRecord
        ) -> Bool {
            let metadata = run.specification.work.metadata
            return AutomaticCompletionPlanResolver.hasValidIdentity(plan)
                && plan.projectID == run.projectID
                && plan.projectGeneration == run.projectGeneration
                && !plan.instructionArtifactSHA256.isEmpty
                && !plan.obligations.isEmpty
                && metadata["completion_plan_id"] == plan.planID.uuidString.lowercased()
                && metadata["completion_plan_revision"] == String(plan.revision)
        }

        private static func artifactRegistrationMatches(
            _ plan: AutomaticCompletionPlan,
            run: AutonomousRunRecord
        ) -> Bool {
            let metadata = run.specification.work.metadata
            let registered = Set([
                metadata["source_snapshot_sha256"],
                metadata["instruction_package_sha256"],
            ].compactMap { $0 })
            return !registered.isEmpty
                && Set(plan.instructionArtifactSHA256).isSubset(of: registered)
        }

        private static func references(_ evidence: [LatestEvidence?]) -> [String] {
            Array(Set(evidence.compactMap { $0?.reference })).sorted()
        }
    }
}

extension ProjectInstructionCompletionGate {
    struct XcodeCompletionDescriptor: Codable, Sendable {
        let descriptor_version: Int
        let typed_xcode_completion_version: Int
        let tool: String
        let arguments_sha256: String
        let canonical_cwd_sha256: String
        let native_command_sha256: String
        let result_bundle_path_sha256: String
        let native_argument_count: Int
        let timeout_seconds: Int
        let only_testing_count: Int
        let only_testing_sha256: String
        let runtime_idempotency_key: String?
        let action: String?
        let query: String?
        var test_job_id: UUID?
        var test_stdout_sha256: String?
        var test_stderr_sha256: String?
    }

    struct XcodeSubmission: Decodable {
        struct Payload: Decodable {
            let job_id: UUID
            let project_id: String
            let project_generation: UInt64
            let submission_only: Bool
            let native_tool: String
            let result_bundle_path: String
            let idempotency_match: Bool?
        }
        let ok: Bool
        let is_error: Bool
        let payload: Payload
    }

    struct XcodeCandidate: Sendable {
        let invocationID: UUID
        let invocationUpdatedAt: String
        let descriptor: XcodeCompletionDescriptor?
        let record: RuntimeJobRecord?
        let context: ToolInvocationContext?
        var reusedReceipt: Bool = false
        var isSuccessful: Bool {
            guard let record, let completed = record.completedAt, ISO8601.date(from: completed) != nil else { return false }
            return record.state == .completed && record.exitCode == 0
                && record.errorCode == nil && record.errorSummary == nil
        }
        var effectiveAt: String { record?.completedAt ?? invocationUpdatedAt }
        var identity: String { record?.jobID.uuidString.lowercased() ?? invocationID.uuidString.lowercased() }
        static func consider(_ candidate: Self, selected: inout Self?, ambiguous: inout Bool) {
            guard let prior = selected else { selected = candidate; ambiguous = false; return }
            if candidate.effectiveAt > prior.effectiveAt { selected = candidate; ambiguous = false; return }
            guard candidate.effectiveAt == prior.effectiveAt else { return }
            guard candidate.identity != prior.identity else { return }
            if candidate.isSuccessful != prior.isSuccessful {
                if !candidate.isSuccessful { selected = candidate }
                ambiguous = false
                return
            }
            // Distinct successful attempts have no recorded sub-second completion order.
            // A replay of the same durable job remains unambiguous.
            if candidate.isSuccessful { ambiguous = true }
        }
    }

    static func xcodeCompletionDescriptor(
        call: BrokeredToolCall, context: ToolInvocationContext,
        repository: ProjectControlPlaneRepository, runtimeJobs: RuntimeJobRepository,
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) async throws -> String? {
        guard call.toolName == "xcode.run" || call.toolName == "xcode.result" else { return nil }
        let command = try XcodeCLIService.command(tool: call.toolName, arguments: call.arguments, context: context)
        guard let bundle = command.resultBundlePath else { return nil }
        let selected = call.arguments["only_testing"] as? [String] ?? []
        var descriptor = XcodeCompletionDescriptor(
            descriptor_version: 1, typed_xcode_completion_version: 1, tool: call.toolName,
            arguments_sha256: JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(call.arguments)),
            canonical_cwd_sha256: JSONSupport.sha256Hex(command.workingDirectory.path),
            native_command_sha256: try XcodeCLIService.nativeCommandFingerprint(command: command, executable: xcrunURL),
            result_bundle_path_sha256: JSONSupport.sha256Hex(bundle),
            native_argument_count: command.arguments.count, timeout_seconds: command.timeoutSeconds,
            only_testing_count: selected.count,
            only_testing_sha256: JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(["selectors": selected])),
            runtime_idempotency_key: command.idempotencyKey,
            action: call.toolName == "xcode.run" ? command.arguments[1] : nil,
            query: call.toolName == "xcode.result" ? call.arguments["query"] as? String : nil
        )
        if descriptor.query == XcodeResultQuery.testSummary.rawValue, let runID = context.runID,
           let writer = try await latestXcodeWriter(
                runID: runID, projectID: context.projectID, generation: context.projectGeneration,
                bundleSHA256: descriptor.result_bundle_path_sha256,
                repository: repository, runtimeJobs: runtimeJobs
           ), writer.isSuccessful,
           writer.descriptor?.action.flatMap(XcodeNativeAction.init(rawValue:))?.executesTests == true,
           let record = writer.record, let storedContext = writer.context {
            do {
                let stdout = try await runtimeJobs.output(jobID: record.jobID, stream: .stdout, context: storedContext)
                let stderr = try await runtimeJobs.output(jobID: record.jobID, stream: .stderr, context: storedContext)
                for output in [stdout, stderr] {
                    guard !output.artifactTruncated, !output.artifactEvicted,
                          output.producerEndReason == .eof, output.producerReadErrno == nil,
                          output.byteCount == output.retainedByteCount else {
                        return try encodedXcodeDescriptor(descriptor)
                    }
                }
                descriptor.test_job_id = record.jobID
                descriptor.test_stdout_sha256 = stdout.sha256
                descriptor.test_stderr_sha256 = stderr.sha256
                if let key = command.idempotencyKey,
                   let existing = try await runtimeJobs.existingJob(
                        projectID: context.projectID, generation: context.projectGeneration, idempotencyKey: key
                   ) {
                    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
                    guard existing.runID == runID,
                          try await xcodeSummaryProducerMatches(
                            jobID: existing.jobID, producer: descriptor, runID: runID,
                            projectID: context.projectID, generation: context.projectGeneration,
                            repository: repository, runtimeJobs: runtimeJobs, deadline: deadline
                          ) else {
                        descriptor.test_job_id = nil; descriptor.test_stdout_sha256 = nil; descriptor.test_stderr_sha256 = nil
                        return try encodedXcodeDescriptor(descriptor)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Native inspection still runs; unavailable proof cannot qualify completion. */ }
        }
        return try encodedXcodeDescriptor(descriptor)
    }

    private static func encodedXcodeDescriptor(_ descriptor: XcodeCompletionDescriptor) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(descriptor)
        guard data.count <= 8_192 else { throw AutonomyError.invalidRequest("typed Xcode completion descriptor exceeds its bound") }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodedXcodeDescriptor(_ invocation: ToolInvocationRecord) -> XcodeCompletionDescriptor? {
        guard let raw = invocation.reconciliationDescriptor, raw.utf8.count <= 8_192,
              let value = decodeXcodeJSON(XcodeCompletionDescriptor.self, data: Data(raw.utf8), maximumBytes: 8_192, integerPaths: Set(["descriptor_version", "typed_xcode_completion_version", "native_argument_count", "timeout_seconds", "only_testing_count"].map { [$0] })),
              value.descriptor_version == 1, value.typed_xcode_completion_version == 1,
              value.tool == invocation.toolName, value.arguments_sha256 == invocation.argumentsSHA256,
              (1...256).contains(value.native_argument_count), (1...86_400).contains(value.timeout_seconds),
              (0...64).contains(value.only_testing_count),
              [value.arguments_sha256, value.native_command_sha256, value.canonical_cwd_sha256, value.result_bundle_path_sha256, value.only_testing_sha256]
                .allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }),
              value.tool == "xcode.run" ? value.action.flatMap(XcodeNativeAction.init(rawValue:)) != nil
                  : value.query.flatMap(XcodeResultQuery.init(rawValue:)) != nil else { return nil }
        return value
    }

    static func nativeFileSizeAdmissionMatches(_ summary: String) -> Bool {
        let fields = summary.split(separator: ":")
        let profile = fields.filter { $0.hasPrefix("file_size_profile=") }
        let bytes = fields.filter { $0.hasPrefix("file_size_bytes=") }
        guard profile.count == 1, profile[0] == "file_size_profile=native_xcode_sparse_cas_v1",
              bytes.count == 1, let count = UInt64(bytes[0].dropFirst("file_size_bytes=".count)),
              count > 0, count <= 34_359_738_368 else { return false }
        return true
    }

    static func xcodeCandidate(
        invocation: ToolInvocationRecord, projectID: ProjectID, generation: ProjectGeneration, runID: RunID,
        repository: ProjectControlPlaneRepository, runtimeJobs: RuntimeJobRepository
    ) async throws -> XcodeCandidate? {
        guard invocation.runID == runID, invocation.projectID == projectID,
              invocation.projectGeneration == generation else { throw ProjectContextError.projectScopeMismatch }
        let descriptor = decodedXcodeDescriptor(invocation)
        let unsuccessful = XcodeCandidate(invocationID: invocation.invocationID, invocationUpdatedAt: invocation.updatedAt,
                                         descriptor: descriptor, record: nil, context: nil)
        guard invocation.state == .completed, invocation.lastErrorCode == nil, invocation.lastErrorSummary == nil,
              let raw = invocation.resultSummary, raw.utf8.count <= ToolInvocationBroker.maximumDurableResultBytes,
              let digest = invocation.resultSHA256, JSONSupport.sha256Hex(raw) == digest,
              let receipt = decodeXcodeJSON(XcodeSubmission.self, data: Data(raw.utf8), maximumBytes: ToolInvocationBroker.maximumDurableResultBytes, integerPaths: [["payload", "project_generation"]]),
              receipt.ok, !receipt.is_error, receipt.payload.submission_only,
              receipt.payload.project_id == projectID.description, receipt.payload.project_generation == generation.rawValue,
              receipt.payload.native_tool == (invocation.toolName == "xcode.run" ? "xcodebuild" : "xcresulttool")
            else { return descriptor == nil ? nil : unsuccessful }
        guard let record = try await runtimeJobs.job(receipt.payload.job_id) else { return unsuccessful }
        guard record.runID == runID, record.projectID == projectID, record.projectGeneration == generation else {
            throw RuntimeJobError.jobScopeMismatch(record.jobID)
        }
        let owner = ProjectBindingOwner(kind: .runtimeJob, id: record.jobID.uuidString.lowercased())
        let context = try await repository.invocationContext(for: owner, clientID: ClientID("manager-runtime-job"))
        guard context.runID == runID, context.projectID == projectID, context.projectGeneration == generation,
              context.runtimeJobID == record.jobID else { throw RuntimeJobError.jobScopeMismatch(record.jobID) }
        if let descriptor {
            guard let key = descriptor.runtime_idempotency_key, record.idempotencyKey == key,
                  record.runtimeKind == .process, record.executionProfile == .directProcess,
                  ExecutionJobService.storedCommandFingerprint(record.commandSummary) == descriptor.native_command_sha256,
                  nativeFileSizeAdmissionMatches(record.commandSummary),
                  JSONSupport.sha256Hex(RuntimePathCanonicalizer.canonicalURL(record.canonicalWorkingDirectory).path) == descriptor.canonical_cwd_sha256,
                  JSONSupport.sha256Hex(receipt.payload.result_bundle_path) == descriptor.result_bundle_path_sha256,
                  record.commandSummary.contains(":argv=\(descriptor.native_argument_count):script_bytes=0"),
                  record.timeoutSeconds > 0, record.timeoutSeconds <= descriptor.timeout_seconds else { return unsuccessful }
        }
        return XcodeCandidate(invocationID: invocation.invocationID, invocationUpdatedAt: invocation.updatedAt,
                              descriptor: descriptor, record: record, context: context, reusedReceipt: receipt.payload.idempotency_match ?? true)
    }

    // One exact owned run, at most its existing evidence bound; one latest writer retained.
    // Deadline failure leaves the native tool available but provides no completion authority.
    static func latestXcodeWriter(
        runID: RunID, projectID: ProjectID, generation: ProjectGeneration, bundleSHA256: String,
        repository: ProjectControlPlaneRepository, runtimeJobs: RuntimeJobRepository,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> XcodeCandidate? {
        let clock = ContinuousClock(); let limit = deadline ?? clock.now.advanced(by: .seconds(5))
        var cursor: ToolInvocationPageCursor?; var count = 0; var latest: XcodeCandidate?; var ambiguous = false
        repeat {
            try Task.checkCancellation()
            guard clock.now < limit else { return nil }
            let page = try await repository.toolInvocations(runID: runID, after: cursor, limit: pageSize)
            guard count <= maximumEvidenceRecords - page.count else { return nil }; count += page.count
            for invocation in page where invocation.toolName == "xcode.run" {
                try Task.checkCancellation(); guard clock.now < limit else { return nil }
                let descriptor = decodedXcodeDescriptor(invocation)
                let legacyBundle: String? = invocation.resultSummary.flatMap { raw in
                    guard raw.utf8.count <= ToolInvocationBroker.maximumDurableResultBytes,
                          let digest = invocation.resultSHA256, JSONSupport.sha256Hex(raw) == digest,
                          let value = decodeXcodeJSON(XcodeSubmission.self, data: Data(raw.utf8), maximumBytes: ToolInvocationBroker.maximumDurableResultBytes, integerPaths: [["payload", "project_generation"]]),
                          value.ok, !value.is_error else { return nil }
                    return JSONSupport.sha256Hex(value.payload.result_bundle_path)
                }
                guard (descriptor?.result_bundle_path_sha256 ?? legacyBundle) == bundleSHA256 else { continue }
                do {
                    if let candidate = try await xcodeCandidate(invocation: invocation, projectID: projectID,
                            generation: generation, runID: runID, repository: repository, runtimeJobs: runtimeJobs) {
                        if let state = candidate.record?.state, [.queued, .running, .cancelling].contains(state) { return nil }
                        XcodeCandidate.consider(candidate, selected: &latest, ambiguous: &ambiguous)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { return nil }
            }
            guard let last = page.last, page.count == pageSize else { break }
            cursor = ToolInvocationPageCursor(createdAt: last.createdAt, invocationID: last.invocationID)
        } while true
        return clock.now < limit && !ambiguous ? latest : nil
    }



    static func xcodeSummaryProducerMatches(
        jobID: UUID, producer: XcodeCompletionDescriptor, runID: RunID,
        projectID: ProjectID, generation: ProjectGeneration,
        repository: ProjectControlPlaneRepository, runtimeJobs: RuntimeJobRepository,
        excludingInvocationID: UUID? = nil, deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let clock = ContinuousClock(); var cursor: ToolInvocationPageCursor?; var count = 0; var found = false
        repeat {
            try Task.checkCancellation(); guard clock.now < deadline else { return false }
            let page = try await repository.toolInvocations(runID: runID, after: cursor, limit: pageSize)
            guard count <= maximumEvidenceRecords - page.count else { return false }; count += page.count
            for invocation in page where invocation.toolName == "xcode.result" {
                try Task.checkCancellation(); guard clock.now < deadline else { return false }
                do {
                    guard let candidate = try await xcodeCandidate(
                        invocation: invocation, projectID: projectID, generation: generation,
                        runID: runID, repository: repository, runtimeJobs: runtimeJobs
                    ), candidate.record?.jobID == jobID else { continue }
                    guard let original = candidate.descriptor,
                          original.query == XcodeResultQuery.testSummary.rawValue,
                          original.result_bundle_path_sha256 == producer.result_bundle_path_sha256,
                          original.test_job_id == producer.test_job_id,
                          original.test_stdout_sha256 == producer.test_stdout_sha256,
                          original.test_stderr_sha256 == producer.test_stderr_sha256 else { return false }
                    if invocation.invocationID != excludingInvocationID { found = true }
                } catch is CancellationError { throw CancellationError() }
                catch { return false }
            }
            guard let last = page.last, page.count == pageSize else { break }
            cursor = ToolInvocationPageCursor(createdAt: last.createdAt, invocationID: last.invocationID)
        } while true
        return clock.now < deadline && found
    }

    static func latestXcodeSummary(
        for test: XcodeCandidate, runID: RunID, projectID: ProjectID, generation: ProjectGeneration,
        repository: ProjectControlPlaneRepository, runtimeJobs: RuntimeJobRepository,
        deadline: ContinuousClock.Instant
    ) async throws -> XcodeCandidate? {
        guard let testJobID = test.record?.jobID, let bundle = test.descriptor?.result_bundle_path_sha256 else { return nil }
        let clock = ContinuousClock(); var cursor: ToolInvocationPageCursor?; var count = 0
        var latest: XcodeCandidate?; var ambiguous = false
        repeat {
            try Task.checkCancellation(); guard clock.now < deadline else { return nil }
            let page = try await repository.toolInvocations(runID: runID, after: cursor, limit: pageSize)
            guard count <= maximumEvidenceRecords - page.count else { return nil }; count += page.count
            for invocation in page where invocation.toolName == "xcode.result" {
                try Task.checkCancellation(); guard clock.now < deadline else { return nil }
                guard let descriptor = decodedXcodeDescriptor(invocation),
                      descriptor.query == XcodeResultQuery.testSummary.rawValue,
                      descriptor.test_job_id == testJobID, descriptor.result_bundle_path_sha256 == bundle else { continue }
                do {
                    if let candidate = try await xcodeCandidate(
                        invocation: invocation, projectID: projectID, generation: generation,
                        runID: runID, repository: repository, runtimeJobs: runtimeJobs
                    ) { XcodeCandidate.consider(candidate, selected: &latest, ambiguous: &ambiguous) }
                } catch is CancellationError { throw CancellationError() }
                catch { return nil }
            }
            guard let last = page.last, page.count == pageSize else { break }
            cursor = ToolInvocationPageCursor(createdAt: last.createdAt, invocationID: last.invocationID)
        } while true
        return clock.now < deadline && !ambiguous ? latest : nil
    }

    struct XcodeOutput: Sendable {
        let stdout: Data
        let stderr: Data
        let stdoutSHA256: String
        let stderrSHA256: String
        var bytes: Int { stdout.count + stderr.count }
    }

    static func xcodeOutput(_ candidate: XcodeCandidate, jobs: ExecutionJobService, remainingBytes: Int,
                            deadline: ContinuousClock.Instant) async throws -> XcodeOutput? {
        let clock = ContinuousClock()
        guard remainingBytes >= 0, clock.now < deadline, candidate.isSuccessful, let record = candidate.record, let context = candidate.context,
              record.outputBytes <= UInt64(remainingBytes) else { return nil }
        var values: [RuntimeOutputStream: Data] = [:]; var digests: [RuntimeOutputStream: String] = [:]
        var available = remainingBytes
        for stream in [RuntimeOutputStream.stdout, .stderr] {
            try Task.checkCancellation(); guard clock.now < deadline else { return nil }
            let metadata = try await jobs.repository.output(jobID: record.jobID, stream: stream, context: context)
            guard clock.now < deadline, !metadata.artifactTruncated, !metadata.artifactEvicted,
                  metadata.producerEndReason == .eof, metadata.producerReadErrno == nil,
                  metadata.byteCount == metadata.retainedByteCount,
                  metadata.retainedByteCount <= UInt64(available) else { return nil }
            var data = Data(); var offset: UInt64 = 0
            repeat {
                try Task.checkCancellation(); guard clock.now < deadline else { return nil }
                let slice = try await jobs.readOutput(jobID: record.jobID, stream: stream, offset: offset, limit: 64 * 1_024, context: context)
                guard clock.now < deadline, slice.offset == offset, slice.nextOffset == offset + UInt64(slice.data.count),
                      slice.totalRetainedBytes == metadata.retainedByteCount, slice.totalObservedBytes == metadata.byteCount,
                      !slice.artifactTruncated, slice.sha256 == metadata.sha256,
                      slice.nextOffset <= metadata.retainedByteCount,
                      slice.eof == (slice.nextOffset == metadata.retainedByteCount),
                      !slice.data.isEmpty || slice.eof else { return nil }
                data.append(slice.data); offset = slice.nextOffset
                if slice.eof { break }
            } while true
            guard UInt64(data.count) == metadata.retainedByteCount, JSONSupport.sha256Hex(data) == metadata.sha256 else { return nil }
            available -= data.count; values[stream] = data; digests[stream] = metadata.sha256
        }
        guard clock.now < deadline, let stdout = values[.stdout], let stderr = values[.stderr],
              UInt64(stdout.count + stderr.count) == record.outputBytes else { return nil }
        guard let stdoutSHA = digests[.stdout], let stderrSHA = digests[.stderr] else { return nil }
        return XcodeOutput(stdout: stdout, stderr: stderr, stdoutSHA256: stdoutSHA, stderrSHA256: stderrSHA)
    }


    private static func decodeXcodeJSON<Value: Decodable>(
        _ type: Value.Type, data: Data, maximumBytes: Int, integerPaths: Set<[String]>
    ) -> Value? {
        guard let checked = try? JSONSupport.validatingIntegerFields(in: data, maximumBytes: maximumBytes,
            requirement: { integerPaths.contains($0) ? .required : nil }) else { return nil }
        return try? JSONDecoder().decode(type, from: checked)
    }

    struct XcodeTestSummary: Decodable {
        let result: String
        let totalTestCount: Int
        let passedTests: Int
        let failedTests: Int
        let skippedTests: Int
        let expectedFailures: Int
    }

    static func xcodeTestsPassed(_ output: XcodeOutput) -> Bool {
        guard output.stdout.count <= 64 * 1_024,
              let value = decodeXcodeJSON(XcodeTestSummary.self, data: output.stdout, maximumBytes: 64 * 1_024, integerPaths: Set(["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"].map { [$0] })),
              value.result == "Passed", value.totalTestCount > 0,
              value.passedTests == value.totalTestCount, value.failedTests == 0,
              value.skippedTests == 0, value.expectedFailures == 0 else { return false }
        return true
    }
}


extension ProjectInstructionCompletionGate.EvidenceAccumulator {
    mutating func consumeNativeXcode(
        _ records: [ToolInvocationRecord], repository: ProjectControlPlaneRepository,
        jobs: ExecutionJobService, deadline: ContinuousClock.Instant
    ) async throws {
        for invocation in records where invocation.toolName == "xcode.run" || invocation.toolName == "xcode.result" {
            try Task.checkCancellation()
            guard ContinuousClock().now < deadline else { invalidNativeEvidence = true; return }
            guard invocation.runID == run.runID, invocation.projectID == run.projectID,
                  invocation.projectGeneration == run.projectGeneration else { invalidScope = true; continue }
            let descriptor = ProjectInstructionCompletionGate.decodedXcodeDescriptor(invocation)
            if invocation.reconciliationDescriptor != nil && descriptor == nil { invalidNativeEvidence = true; continue }
            do {
                guard let candidate = try await ProjectInstructionCompletionGate.xcodeCandidate(
                    invocation: invocation, projectID: run.projectID, generation: run.projectGeneration,
                    runID: run.runID, repository: repository, runtimeJobs: jobs.repository
                ) else { continue }
                if let state = candidate.record?.state, [.queued, .running, .cancelling].contains(state) { nativeUnresolved = true }
                // Metadata-less historical receipts never become typed completion authority.
                guard let descriptor else { continue }
                if invocation.toolName == "xcode.run", let action = descriptor.action.flatMap(XcodeNativeAction.init(rawValue:)) {
                    if [.build, .buildForTesting, .archive].contains(action) {
                        ProjectInstructionCompletionGate.XcodeCandidate.consider(candidate, selected: &nativeBuild, ambiguous: &nativeBuildAmbiguous)
                    }
                    if action.executesTests {
                        ProjectInstructionCompletionGate.XcodeCandidate.consider(candidate, selected: &nativeTests, ambiguous: &nativeTestsAmbiguous)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as RuntimeJobError {
                if case .jobScopeMismatch = error { invalidScope = true }
                else { invalidNativeEvidence = true }
            } catch { invalidNativeEvidence = true }
        }
    }

    mutating func finishNativeXcode(
        repository: ProjectControlPlaneRepository, jobs: ExecutionJobService, deadline: ContinuousClock.Instant
    ) async throws {
        guard !nativeBuildAmbiguous, !nativeTestsAmbiguous else { invalidNativeEvidence = true; return }
        var remainingBytes = 2 * 1_024 * 1_024
        if let build = nativeBuild {
            var passed = false; var warningFree = false; var reference: String?
            do {
                try Task.checkCancellation()
                guard ContinuousClock().now < deadline else { invalidNativeEvidence = true; return }
                if let output = try await ProjectInstructionCompletionGate.xcodeOutput(build, jobs: jobs, remainingBytes: remainingBytes, deadline: deadline) {
                    remainingBytes -= output.bytes; passed = true
                    reference = JSONSupport.sha256Hex(build.identity + ":" + output.stdoutSHA256 + ":" + output.stderrSHA256)
                    if let stdout = String(data: output.stdout, encoding: .utf8), let stderr = String(data: output.stderr, encoding: .utf8) {
                        warningFree = !(stdout + "\n" + stderr).lowercased().split(separator: "\n").contains { $0.contains("warning:") }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Missing, changed or truncated native output cannot prove a build. */ }
            let evidence = LatestEvidence(successful: passed, reference: reference, effectiveAt: build.effectiveAt, identity: build.identity)
            latestBuild = Self.newerEvidence(evidence, than: latestBuild)
            let clean = LatestEvidence(successful: passed && warningFree, reference: warningFree ? reference : nil,
                                       effectiveAt: build.effectiveAt, identity: build.identity)
            latestBuildWarningFree = Self.newerEvidence(clean, than: latestBuildWarningFree)
        }
        if let test = nativeTests {
            var passed = false; var reference: String?
            do {
                try Task.checkCancellation()
                guard ContinuousClock().now < deadline else { invalidNativeEvidence = true; return }
                if let descriptor = test.descriptor, test.isSuccessful,
                   let summary = try await ProjectInstructionCompletionGate.latestXcodeSummary(
                        for: test, runID: run.runID, projectID: run.projectID, generation: run.projectGeneration,
                        repository: repository, runtimeJobs: jobs.repository, deadline: deadline
                   ), summary.isSuccessful,
                   let summaryDescriptor = summary.descriptor,
                   summaryDescriptor.test_job_id == test.record?.jobID,
                   let summaryRecord = summary.record,
                   try await ProjectInstructionCompletionGate.xcodeSummaryProducerMatches(
                        jobID: summaryRecord.jobID, producer: summaryDescriptor, runID: run.runID,
                        projectID: run.projectID, generation: run.projectGeneration,
                        repository: repository, runtimeJobs: jobs.repository,
                        excludingInvocationID: summary.reusedReceipt ? summary.invocationID : nil, deadline: deadline
                   ),
                   summaryDescriptor.result_bundle_path_sha256 == descriptor.result_bundle_path_sha256,
                   let latest = try await ProjectInstructionCompletionGate.latestXcodeWriter(
                        runID: run.runID, projectID: run.projectID, generation: run.projectGeneration,
                        bundleSHA256: descriptor.result_bundle_path_sha256, repository: repository, runtimeJobs: jobs.repository, deadline: deadline
                   ), latest.record?.jobID == test.record?.jobID, latest.isSuccessful,
                   let testOutput = try await ProjectInstructionCompletionGate.xcodeOutput(test, jobs: jobs, remainingBytes: remainingBytes, deadline: deadline) {
                    remainingBytes -= testOutput.bytes
                    if summaryDescriptor.test_stdout_sha256 == testOutput.stdoutSHA256,
                       summaryDescriptor.test_stderr_sha256 == testOutput.stderrSHA256,
                       let summaryOutput = try await ProjectInstructionCompletionGate.xcodeOutput(summary, jobs: jobs, remainingBytes: remainingBytes, deadline: deadline) {
                        remainingBytes -= summaryOutput.bytes
                        passed = ProjectInstructionCompletionGate.xcodeTestsPassed(summaryOutput)
                        if passed {
                            reference = JSONSupport.sha256Hex(test.identity + ":" + summary.identity + ":"
                                + testOutput.stdoutSHA256 + ":" + testOutput.stderrSHA256 + ":"
                                + summaryOutput.stdoutSHA256 + ":" + summaryOutput.stderrSHA256)
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* No correlated, complete native result is a nonpassing test proof. */ }
            latestTests = Self.newerEvidence(
                LatestEvidence(successful: passed, reference: reference, effectiveAt: test.effectiveAt, identity: test.identity),
                than: latestTests
            )
        }
        if ContinuousClock().now >= deadline { invalidNativeEvidence = true }
    }

    private static func newerEvidence(_ candidate: LatestEvidence, than prior: LatestEvidence?) -> LatestEvidence {
        guard let prior else { return candidate }
        let candidateTime = candidate.effectiveAt ?? "", priorTime = prior.effectiveAt ?? ""
        if candidateTime != priorTime { return candidateTime > priorTime ? candidate : prior }
        if candidate.successful != prior.successful { return candidate.successful ? prior : candidate }
        return (candidate.identity ?? "") > (prior.identity ?? "") ? candidate : prior
    }
}
