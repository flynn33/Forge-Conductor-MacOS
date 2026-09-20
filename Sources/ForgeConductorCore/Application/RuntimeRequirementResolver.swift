import Foundation

public enum RuntimeRequirement: String, Codable, Sendable, CaseIterable {
    case required
    case optional
    case notNeeded = "not_needed"
}

public enum RuntimeRequirementIdentifier: String, Codable, Sendable, CaseIterable {
    case directProcess = "direct_process"
    case zsh
    case bash
    case python
    case powershell
}

public struct RuntimeRequirementResolution: Codable, Sendable, Equatable {
    public let runtime: RuntimeRequirementIdentifier
    public let requirement: RuntimeRequirement
    public let availability: RuntimeExecutableProbeState
    public let reason: String
    public let recoveryAction: String?

    public init(
        runtime: RuntimeRequirementIdentifier,
        requirement: RuntimeRequirement,
        availability: RuntimeExecutableProbeState,
        reason: String,
        recoveryAction: String? = nil
    ) {
        self.runtime = runtime
        self.requirement = requirement
        self.availability = availability
        self.reason = reason
        self.recoveryAction = recoveryAction
    }

    public var blocksTask: Bool {
        requirement == .required && availability != .available
    }
}

public struct RuntimeRequirementInput: Sendable, Equatable {
    public let selectedTools: Set<String>
    public let completionPlan: AutomaticCompletionPlan?
    public let projectMetadata: [String: String]
    public let instructionRequirements: Set<RuntimeRequirementIdentifier>
    public let runtimePreferences: Set<RuntimeRequirementIdentifier>
    public let shellPolicyEnabled: Bool
    public let projectAuthorized: Bool

    public init(
        selectedTools: Set<String>,
        completionPlan: AutomaticCompletionPlan? = nil,
        projectMetadata: [String: String] = [:],
        instructionRequirements: Set<RuntimeRequirementIdentifier> = [],
        runtimePreferences: Set<RuntimeRequirementIdentifier> = [],
        shellPolicyEnabled: Bool = true,
        projectAuthorized: Bool = true
    ) {
        self.selectedTools = selectedTools
        self.completionPlan = completionPlan
        self.projectMetadata = projectMetadata
        self.instructionRequirements = instructionRequirements
        self.runtimePreferences = runtimePreferences
        self.shellPolicyEnabled = shellPolicyEnabled
        self.projectAuthorized = projectAuthorized
    }
}

/// Resolves runtime necessity from explicit task evidence. It deliberately does
/// not infer a language requirement from prose or from an absent executable.
public enum RuntimeRequirementResolver {
    public static func resolve(
        input: RuntimeRequirementInput,
        capabilities: RuntimeCapabilities
    ) -> [RuntimeRequirementResolution] {
        let completionTools = Set(
            input.completionPlan?.obligations.flatMap(\.relevantToolNames) ?? []
        )
        let tools = input.selectedTools.union(completionTools)
        var required = input.instructionRequirements
        for runtime in RuntimeRequirementIdentifier.allCases
            where input.projectMetadata["runtime.\(runtime.rawValue).required"] == "true" {
            required.insert(runtime)
        }
        let toolRuntime: [String: RuntimeRequirementIdentifier] = [
            "process.run": .directProcess,
            "shell.run": .zsh,
            "bash.run": .bash,
            "shell_exec": .bash,
            "python.run": .python,
            "powershell.run": .powershell,
        ]
        for tool in tools {
            if let runtime = toolRuntime[tool] { required.insert(runtime) }
        }
        if !required.isEmpty { required.insert(.directProcess) }

        return RuntimeRequirementIdentifier.allCases.map { runtime in
            let capability = capability(runtime, from: capabilities)
            let requirement: RuntimeRequirement
            let reason: String
            if required.contains(runtime) {
                requirement = .required
                reason = requiredReason(runtime, tools: tools, input: input)
            } else if input.runtimePreferences.contains(runtime) {
                requirement = .optional
                reason = "The project prefers this runtime, but the selected task does not require it."
            } else {
                requirement = .notNeeded
                reason = "The selected tools, completion checks, project metadata, and instructions do not require this runtime."
            }

            let availability: RuntimeExecutableProbeState
            if runtime != .directProcess && !input.shellPolicyEnabled {
                availability = .disabledByPolicy
            } else if !input.projectAuthorized {
                availability = .notAuthorized
            } else {
                availability = capability.probeState
            }
            return RuntimeRequirementResolution(
                runtime: runtime,
                requirement: requirement,
                availability: availability,
                reason: reason,
                recoveryAction: recoveryAction(
                    runtime: runtime,
                    requirement: requirement,
                    availability: availability
                )
            )
        }
    }

    private static func capability(
        _ runtime: RuntimeRequirementIdentifier,
        from capabilities: RuntimeCapabilities
    ) -> RuntimeExecutableCapability {
        switch runtime {
        case .directProcess: capabilities.directProcess
        case .zsh: capabilities.zsh
        case .bash: capabilities.bash
        case .python: capabilities.python
        case .powershell: capabilities.powershell
        }
    }

    private static func requiredReason(
        _ runtime: RuntimeRequirementIdentifier,
        tools: Set<String>,
        input: RuntimeRequirementInput
    ) -> String {
        if input.instructionRequirements.contains(runtime) {
            return "The imported instructions explicitly require this runtime."
        }
        if input.projectMetadata["runtime.\(runtime.rawValue).required"] == "true" {
            return "The selected project's build or test metadata requires this runtime."
        }
        if runtime == .directProcess {
            return "Durable process isolation is required by the selected task's runtime tools."
        }
        let names = tools.filter { tool in
            switch runtime {
            case .zsh: tool == "shell.run"
            case .bash: tool == "bash.run" || tool == "shell_exec"
            case .python: tool == "python.run"
            case .powershell: tool == "powershell.run"
            case .directProcess: tool == "process.run"
            }
        }.sorted()
        return names.isEmpty
            ? "The automatic completion plan requires this runtime."
            : "The selected task uses \(names.joined(separator: ", "))."
    }

    private static func recoveryAction(
        runtime: RuntimeRequirementIdentifier,
        requirement: RuntimeRequirement,
        availability: RuntimeExecutableProbeState
    ) -> String? {
        guard requirement == .required, availability != .available else { return nil }
        switch availability {
        case .notInstalled:
            return "Install or configure \(displayName(runtime)), then refresh runtime readiness."
        case .disabledByPolicy:
            return "Enable the application-wide shell policy, then refresh runtime readiness."
        case .notAuthorized:
            return "Authorize the selected project folder, then refresh runtime readiness."
        case .probeFailed:
            return "Repair or replace the configured \(displayName(runtime)) executable, then retry its probe."
        case .unknown:
            return "Retry the \(displayName(runtime)) capability probe."
        case .available:
            return nil
        }
    }

    private static func displayName(_ runtime: RuntimeRequirementIdentifier) -> String {
        switch runtime {
        case .directProcess: "direct process runtime"
        case .zsh: "zsh"
        case .bash: "Bash"
        case .python: "Python 3"
        case .powershell: "PowerShell 7"
        }
    }
}
