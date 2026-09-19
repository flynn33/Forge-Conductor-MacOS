import Foundation

/// Derives a bounded, deterministic completion contract from the prepared
/// instruction snapshot and shallow project structure. The resolver proposes
/// obligations; compiled validators remain the only completion authority.
public enum AutomaticCompletionPlanResolver {
    public static let maximumPlanningTextBytes = 512 * 1_024
    public static let maximumInstructionSnapshots = 64
    public static let maximumObligations = 64

    public struct Input: Sendable {
        public let projectID: ProjectID
        public let projectGeneration: ProjectGeneration
        public let projectRoot: URL
        public let instructionArtifactSHA256: [String]
        public let instructionText: String
        public let documentCount: Int
        public let completionGates: [String]

        public init(
            projectID: ProjectID,
            projectGeneration: ProjectGeneration,
            projectRoot: URL,
            instructionArtifactSHA256: [String],
            instructionText: String,
            documentCount: Int,
            completionGates: [String]
        ) {
            self.projectID = projectID
            self.projectGeneration = projectGeneration
            self.projectRoot = projectRoot
            self.instructionArtifactSHA256 = instructionArtifactSHA256
            self.instructionText = instructionText
            self.documentCount = documentCount
            self.completionGates = completionGates
        }
    }

    public static func resolve(_ input: Input) throws -> AutomaticCompletionPlan {
        let root = input.projectRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard root.isFileURL, root.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !input.instructionArtifactSHA256.isEmpty,
              input.instructionArtifactSHA256.count <= maximumInstructionSnapshots,
              Set(input.instructionArtifactSHA256).count == input.instructionArtifactSHA256.count,
              input.instructionArtifactSHA256.allSatisfy(validDigest),
              input.instructionText.utf8.count <= maximumPlanningTextBytes,
              (1...ProjectInstructionQueueStore.maximumSourceFiles).contains(input.documentCount),
              !input.completionGates.isEmpty,
              input.completionGates.count <= maximumObligations else {
            throw AutonomyError.invalidRequest(
                "Automatic completion planning requires a bounded project and instruction snapshot."
            )
        }

        let project = try inspectProject(root)
        let task = classify(input.instructionText)
        var obligations: [CompletionObligation] = [
            CompletionObligation(
                id: "artifact-registered",
                kind: .artifactRegistered,
                title: "Instruction artifact is registered",
                reason: "The task must remain bound to the exact prepared instruction snapshot.",
                evidenceRequirements: [.preparedSource]
            ),
        ]

        if task.isReadOnly {
            obligations.append(CompletionObligation(
                id: "read-only-report-delivered",
                kind: .readOnlyReportDelivered,
                title: "Requested report is delivered",
                reason: "The instructions ask for analysis or reporting without a project mutation.",
                evidenceRequirements: [.deliveredReport],
                relevantToolNames: ["fs_read", "fs_list", "fs_glob", "search_text", "git_diff", "git_log", "git_status"]
            ))
        } else {
            if project.hasBuildDefinition {
                obligations.append(CompletionObligation(
                    id: "project-build",
                    kind: .projectBuild,
                    title: "Relevant project target builds",
                    reason: project.buildReason,
                    evidenceRequirements: [.successfulBuild],
                    relevantToolNames: ["shell_exec"]
                ))
            }
            if project.hasTests {
                obligations.append(CompletionObligation(
                    id: "project-tests",
                    kind: .projectTests,
                    title: "Available affected tests pass",
                    reason: "The registered project contains an executable test surface.",
                    evidenceRequirements: [.successfulTests],
                    relevantToolNames: ["shell_exec"]
                ))
            }
        }

        let customGates = input.completionGates.filter {
            $0 != ProjectInstructionQueueStore.builtInCompletionGate
        }
        for gate in customGates {
            let suffix = String(JSONSupport.sha256Hex(gate).prefix(16))
            obligations.append(CompletionObligation(
                id: "custom-native-gate-\(suffix)",
                kind: .customNativeGate,
                title: "Custom completion policy passes",
                reason: "The task explicitly selected the registered completion gate \(gate).",
                evidenceRequirements: [.customNativeReceipt],
                customGateID: gate
            ))
        }

        obligations.append(CompletionObligation(
            id: "no-unresolved-side-effects",
            kind: .noRelevantUnresolvedSideEffect,
            title: "No relevant operation remains unresolved",
            reason: "Completion must reconcile in-flight, ambiguous, or interrupted task effects.",
            evidenceRequirements: [.reconciledSideEffects]
        ))

        guard !obligations.isEmpty, obligations.count <= maximumObligations,
              Set(obligations.map(\.id)).count == obligations.count else {
            throw AutonomyError.invalidRequest("Automatic completion planning produced an invalid obligation set.")
        }
        let source: CompletionPlanSource = customGates.isEmpty
            ? .automatic : .automaticWithCustomPolicy
        let planID = try stablePlanID(
            projectID: input.projectID,
            projectGeneration: input.projectGeneration,
            instructionArtifactSHA256: input.instructionArtifactSHA256,
            obligations: obligations,
            source: source
        )
        return AutomaticCompletionPlan(
            planID: planID,
            projectID: input.projectID,
            projectGeneration: input.projectGeneration,
            instructionArtifactSHA256: input.instructionArtifactSHA256,
            obligations: obligations,
            source: source
        )
    }

    private struct ProjectInspection {
        let hasBuildDefinition: Bool
        let hasTests: Bool
        let buildReason: String
    }

    private struct TaskClassification {
        let isReadOnly: Bool
    }

    private static func inspectProject(_ root: URL) throws -> ProjectInspection {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let names = Set(entries.map { $0.lastPathComponent.lowercased() })
        let hasSwiftPackage = names.contains("package.swift")
        let hasXcodeProject = names.contains { name in
            name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
        }
        let hasTests = names.contains("tests") || names.contains { $0.hasSuffix("tests") }
        let buildReason: String
        if hasSwiftPackage && hasXcodeProject {
            buildReason = "The registered project contains SwiftPM and Xcode build definitions."
        } else if hasSwiftPackage {
            buildReason = "The registered project contains a SwiftPM build definition."
        } else if hasXcodeProject {
            buildReason = "The registered project contains an Xcode build definition."
        } else {
            buildReason = "No supported native build definition was detected at the project root."
        }
        return ProjectInspection(
            hasBuildDefinition: hasSwiftPackage || hasXcodeProject,
            hasTests: hasTests,
            buildReason: buildReason
        )
    }

    private static func classify(_ text: String) -> TaskClassification {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let words = Set(normalized.split { scalar in
            !scalar.isLetter && !scalar.isNumber
        }.map(String.init))
        let readOnlyWords: Set<String> = [
            "analyze", "analysis", "audit", "explain", "inspect", "investigate",
            "report", "review",
        ]
        let mutationWords: Set<String> = [
            "add", "build", "change", "create", "delete", "edit", "fix", "implement",
            "modify", "remove", "repair", "replace", "update", "write",
        ]
        let hasReadOnlyPhrase = normalized.contains("read-only")
            || normalized.contains("read only")
        return TaskClassification(
            isReadOnly: (hasReadOnlyPhrase || !words.isDisjoint(with: readOnlyWords))
                && words.isDisjoint(with: mutationWords)
        )
    }

    private static func stablePlanID(
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        instructionArtifactSHA256: [String],
        obligations: [CompletionObligation],
        source: CompletionPlanSource
    ) throws -> UUID {
        struct Authority: Encodable {
            let projectID: ProjectID
            let projectGeneration: ProjectGeneration
            let instructionArtifactSHA256: [String]
            let obligations: [CompletionObligation]
            let source: CompletionPlanSource

            enum CodingKeys: String, CodingKey {
                case projectID = "project_id"
                case projectGeneration = "project_generation"
                case instructionArtifactSHA256 = "instruction_artifact_sha256"
                case obligations, source
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hex = Array(JSONSupport.sha256Hex(try encoder.encode(Authority(
            projectID: projectID,
            projectGeneration: projectGeneration,
            instructionArtifactSHA256: instructionArtifactSHA256,
            obligations: obligations,
            source: source
        ))).prefix(32))
        hex[12] = "5"
        hex[16] = "a"
        let value = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-"
            + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-"
            + String(hex[20..<32])
        guard let identifier = UUID(uuidString: value) else {
            throw AutonomyError.invalidRequest("Automatic completion plan identity could not be derived.")
        }
        return identifier
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
