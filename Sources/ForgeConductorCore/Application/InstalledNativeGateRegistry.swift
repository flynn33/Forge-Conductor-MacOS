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
    private var stopped = false

    public init(
        repository: ProjectControlPlaneRepository,
        paths _: AppPaths,
        clock: any Clock = SystemClock()
    ) {
        self.repository = repository
        self.clock = clock
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
            repository: repository
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
        repository: ProjectControlPlaneRepository
    ) async throws -> CompletionGateResult {
        var accumulator = EvidenceAccumulator(run: run)
        var cursor: ToolInvocationPageCursor?
        repeat {
            let page = try await repository.toolInvocations(
                runID: run.runID,
                after: cursor,
                limit: pageSize
            )
            try accumulator.consume(page)
            guard let last = page.last, page.count == pageSize else { break }
            cursor = ToolInvocationPageCursor(
                createdAt: last.createdAt,
                invocationID: last.invocationID
            )
        } while true
        let delivery = run.specification.completionPlan?.obligations.contains {
            $0.kind == .instructionDeliveryComplete
        } == true ? try await repository.instructionDeliveryProgress(run: run) : nil
        return accumulator.result(instructionDelivery: delivery)
    }

    struct EvidenceAccumulator {
        private struct LatestEvidence {
            let successful: Bool
            let reference: String?
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
            guard !unresolvedInvocation, run.specification.work.pendingIntent == nil else {
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
                return LatestEvidence(successful: false, reference: nil)
            }
            return LatestEvidence(successful: true, reference: digest)
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
                return LatestEvidence(successful: false, reference: nil)
            }
            let output = (stdout + "\n" + stderr).lowercased()
            let hasWarning = output.split(separator: "\n").contains { line in
                line.contains("warning:")
            }
            return LatestEvidence(
                successful: !hasWarning,
                reference: hasWarning ? nil : base.reference
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
