// ManagerInstaller.swift
// What: Installs and controls the per-user LaunchAgent manager integration.
// How: It stages the executable/framework/app layout, writes validated launchd metadata,
// loads or unloads the agent, and verifies runtime state through native process APIs.
// Why: Persistent service ownership needs one transactional, repeatable installation module.

import Foundation
import Darwin
import Security
import ForgeFilesystemProtocol

enum ManagerArtifactKind: Equatable {
    case executable
    case framework
    case applicationBundle
}

protocol ManagerArtifactValidating {
    func prepareAndSign(_ url: URL, kind: ManagerArtifactKind) throws
    func verify(_ url: URL, kind: ManagerArtifactKind) throws
}

protocol ManagerArtifactCopying {
    func copyItem(at source: URL, to destination: URL) throws
}

protocol ManagerArtifactReplacing {
    func applyReplacement(
        target: URL,
        staged: URL?,
        backup: URL,
        hadOriginal: Bool
    ) throws
}

enum ManagerArtifactSignatureState: Equatable {
    case valid
    case unsigned
    case invalidAdHoc
    case invalidCMS
    case indeterminate
}

struct ManagerArtifactSignatureInspection: Equatable {
    var state: ManagerArtifactSignatureState
    var identifier: String?
    var teamIdentifier: String?
    var sealedDaemonCodeDirectoryHashes: [String: String]?
    var validationStatus: OSStatus
}

protocol ManagerCodeSignatureInspecting {
    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind,
        requirement: String?
    ) throws
        -> ManagerArtifactSignatureInspection
}

extension ManagerCodeSignatureInspecting {
    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind
    ) throws -> ManagerArtifactSignatureInspection {
        try inspect(url, kind: kind, requirement: nil)
    }
}

struct SecurityManagerCodeSignatureInspector: ManagerCodeSignatureInspecting {
    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind,
        requirement requirementText: String?
    ) throws -> ManagerArtifactSignatureInspection {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw inspectionError(
                url: url,
                operation: "create static-code reference",
                status: createStatus
            )
        }

        var validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
        )
        validationFlags.formUnion(.noNetworkAccess)
        if kind != .executable {
            validationFlags.formUnion(SecCSFlags(rawValue: kSecCSCheckNestedCode))
        }

        var compiledRequirement: SecRequirement?
        if let requirementText {
            let requirementStatus = SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(rawValue: 0),
                &compiledRequirement
            )
            guard requirementStatus == errSecSuccess, compiledRequirement != nil else {
                throw inspectionError(
                    url: url,
                    operation: "compile code-signing requirement",
                    status: requirementStatus
                )
            }
        }

        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            compiledRequirement
        )
        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any] else {
            throw inspectionError(
                url: url,
                operation: "read signature metadata after validation failure",
                status: informationStatus
            )
        }

        let identifier = information[kSecCodeInfoIdentifier] as? String
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
        let sealedDaemonCodeDirectoryHashes = sealedDaemonCodeDirectoryHashes(
            in: information[kSecCodeInfoPList]
        )
        if validationStatus == errSecSuccess {
            return ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: teamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedDaemonCodeDirectoryHashes,
                validationStatus: validationStatus
            )
        }

        let flagsNumber = information[kSecCodeInfoFlags] as? NSNumber
        let certificates = information[kSecCodeInfoCertificates] as? [Any]
        let cms = information[kSecCodeInfoCMS] as? Data
        let hasCMSIdentity = !(certificates?.isEmpty ?? true) || !(cms?.isEmpty ?? true)

        let state: ManagerArtifactSignatureState
        if hasCMSIdentity {
            state = .invalidCMS
        } else if validationStatus == errSecCSUnsigned, identifier == nil {
            state = .unsigned
        } else if let flagsNumber {
            let flags = SecCodeSignatureFlags(rawValue: flagsNumber.uint32Value)
            state = flags.contains(.adhoc) ? .invalidAdHoc : .indeterminate
        } else {
            state = .indeterminate
        }

        return ManagerArtifactSignatureInspection(
            state: state,
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            sealedDaemonCodeDirectoryHashes: sealedDaemonCodeDirectoryHashes,
            validationStatus: validationStatus
        )
    }

    private func inspectionError(
        url: URL,
        operation: String,
        status: OSStatus
    ) -> Error {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Security error"
        return NSError(
            domain: "ManagerInstaller",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey:
                "Cannot \(operation) for \(url.path) (Security \(status)): \(detail)"]
        )
    }

    private func sealedDaemonCodeDirectoryHashes(
        in rawPropertyList: Any?
    ) -> [String: String]? {
        let propertyList: [String: Any]
        if let dictionary = rawPropertyList as? [String: Any] {
            propertyList = dictionary
        } else if let dictionary = rawPropertyList as? NSDictionary,
                  let bridged = dictionary as? [String: Any] {
            propertyList = bridged
        } else {
            return nil
        }

        var hashes: [String: String] = [:]
        for key in ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashInfoPlistKeys
            where propertyList[key] != nil {
            guard let rawHash = propertyList[key] as? String,
                  let hash = ForgeFilesystemCodeIdentity
                    .normalizedCodeDirectoryHash(rawHash) else {
                return nil
            }
            hashes[key] = hash
        }
        return hashes.isEmpty ? nil : hashes
    }
}

protocol ManagerPrivilegedApplicationIdentityValidating {
    func validate(applicationBundle: URL, invokedBy sourceExecutable: URL) throws
    func validateStaged(applicationBundle: URL, executable: URL) throws
}

protocol ManagerExecutableCodeDirectoryHashInspecting {
    func hashesByInfoPlistKey(at executable: URL) throws -> [String: String]
}

struct CodesignManagerExecutableCodeDirectoryHashInspector:
    ManagerExecutableCodeDirectoryHashInspecting
{
    private let runner: ProcessRunner

    init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    func hashesByInfoPlistKey(at executable: URL) throws -> [String: String] {
        let architectureResult = try runner.run(
            executable: "/usr/bin/lipo",
            arguments: ["-archs", executable.path],
            timeoutSec: 10
        )
        guard architectureResult.exitCode == 0, !architectureResult.timedOut else {
            throw inspectionError(
                "Cannot read daemon architectures at \(executable.path): "
                    + architectureResult.stderr
            )
        }

        let architectures = architectureResult.stdout
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !architectures.isEmpty else {
            throw inspectionError("Daemon has no Mach-O architectures at \(executable.path)")
        }

        var hashes: [String: String] = [:]
        for architecture in architectures {
            let key: String
            switch architecture {
            case "arm64":
                key = ForgeFilesystemCodeIdentity
                    .daemonArm64CodeDirectoryHashInfoPlistKey
            case "x86_64":
                key = ForgeFilesystemCodeIdentity
                    .daemonX86_64CodeDirectoryHashInfoPlistKey
            default:
                throw inspectionError(
                    "Daemon contains unsupported architecture \(architecture) at "
                        + executable.path
                )
            }

            let signatureResult = try runner.run(
                executable: "/usr/bin/codesign",
                arguments: [
                    "--display",
                    "--verbose=4",
                    "--arch", architecture,
                    executable.path,
                ],
                timeoutSec: 10
            )
            guard signatureResult.exitCode == 0, !signatureResult.timedOut else {
                throw inspectionError(
                    "Cannot inspect daemon CodeDirectory hash for \(architecture) at "
                        + "\(executable.path): \(signatureResult.stderr)"
                )
            }

            let signatureDetails = signatureResult.stdout + "\n" + signatureResult.stderr
            let rawHash = signatureDetails
                .split(separator: "\n")
                .map(String.init)
                .first(where: { $0.hasPrefix("CDHash=") })?
                .dropFirst("CDHash=".count)
            guard let rawHash,
                  let hash = ForgeFilesystemCodeIdentity
                    .normalizedCodeDirectoryHash(String(rawHash)) else {
                throw inspectionError(
                    "Daemon has no valid CodeDirectory hash for \(architecture) at "
                        + executable.path
                )
            }
            hashes[key] = hash
        }
        return hashes
    }

    private func inspectionError(_ message: String) -> NSError {
        NSError(
            domain: "ManagerInstaller",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct SecurityManagerPrivilegedApplicationIdentityValidator:
    ManagerPrivilegedApplicationIdentityValidating
{
    private enum ExecutableContext: Equatable {
        case invocation
        case stagedCopy
    }

    private let signatureInspector: any ManagerCodeSignatureInspecting
    private let codeDirectoryHashInspector:
        any ManagerExecutableCodeDirectoryHashInspecting

    init(
        signatureInspector: any ManagerCodeSignatureInspecting =
            SecurityManagerCodeSignatureInspector(),
        codeDirectoryHashInspector:
            any ManagerExecutableCodeDirectoryHashInspecting =
                CodesignManagerExecutableCodeDirectoryHashInspector()
    ) {
        self.signatureInspector = signatureInspector
        self.codeDirectoryHashInspector = codeDirectoryHashInspector
    }

    func validate(applicationBundle: URL, invokedBy sourceExecutable: URL) throws {
        try validate(
            applicationBundle: applicationBundle,
            executable: sourceExecutable,
            context: .invocation
        )
    }

    func validateStaged(applicationBundle: URL, executable: URL) throws {
        try validate(
            applicationBundle: applicationBundle,
            executable: executable,
            context: .stagedCopy
        )
    }

    private func validate(
        applicationBundle: URL,
        executable: URL,
        context: ExecutableContext
    ) throws {
        let expectedTeam = ForgeFilesystemProtocolConstants.activeTeamIdentifier
        let executableRole = context == .invocation
            ? "invoking executable"
            : "staged executable"
        let allowedExecutableIdentifiers: Set<String> = context == .invocation
            ? [
                ForgeFilesystemProtocolConstants.appIdentifier,
                ForgeFilesystemProtocolConstants.managerIdentifier,
            ]
            : [ForgeFilesystemProtocolConstants.managerIdentifier]
        let executableIdentity = try validateIdentity(
            at: executable,
            kind: .executable,
            role: executableRole,
            allowedIdentifiers: allowedExecutableIdentifiers,
            expectedTeam: expectedTeam
        )
        let applicationIdentity = try validateIdentity(
            at: applicationBundle,
            kind: .applicationBundle,
            role: "Forge Conductor app",
            allowedIdentifiers: [ForgeFilesystemProtocolConstants.appIdentifier],
            expectedTeam: expectedTeam
        )
        let daemon = applicationBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(
                ForgeFilesystemProtocolConstants.daemonExecutableName
            )
        _ = try validateIdentity(
            at: daemon,
            kind: .executable,
            role: "privileged filesystem daemon",
            allowedIdentifiers: [ForgeFilesystemProtocolConstants.daemonIdentifier],
            expectedTeam: expectedTeam
        )
        let daemonHashes = try codeDirectoryHashInspector
            .hashesByInfoPlistKey(at: daemon)

        if executableIdentity.identifier == ForgeFilesystemProtocolConstants.managerIdentifier {
            try validateSealedDaemonHashes(
                executableIdentity.sealedDaemonCodeDirectoryHashes,
                role: context == .invocation
                    ? "invoking manager executable"
                    : "staged manager executable",
                actualDaemonHashes: daemonHashes
            )
        } else {
            try validateApplicationInvocationPath(
                executable,
                applicationBundle: applicationBundle
            )
        }
        try validateSealedDaemonHashes(
            applicationIdentity.sealedDaemonCodeDirectoryHashes,
            role: "Forge Conductor app",
            actualDaemonHashes: daemonHashes
        )

        // This binds the staged pair to the daemon shipped in this build. It does not provide
        // monotonic whole-product rollback freshness; that remains a separate release gate.
    }

    private func validateApplicationInvocationPath(
        _ executable: URL,
        applicationBundle: URL
    ) throws {
        let expectedExecutable = applicationBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(ManagerInstaller.appDisplayName)
        guard resolvedPath(executable) == resolvedPath(expectedExecutable) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refusing to treat app-identity executable at \(executable.path) as the "
                    + "Forge Conductor app entry point. Expected the exact validated bundle "
                    + "executable at \(expectedExecutable.path)."]
            )
        }
    }

    private func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func validateIdentity(
        at url: URL,
        kind: ManagerArtifactKind,
        role: String,
        allowedIdentifiers: Set<String>,
        expectedTeam: String
    ) throws -> ManagerArtifactSignatureInspection {
        let requirements = allowedIdentifiers.sorted().compactMap { identifier in
            ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: identifier,
                teamIdentifier: expectedTeam
            )
        }
        guard requirements.count == allowedIdentifiers.count else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 18,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refusing to stage \(role) because its exact product signing policy is unavailable."]
            )
        }
        let requirement = requirements.count == 1
            ? requirements[0]
            : requirements.map { "(\($0))" }.joined(separator: " or ")
        let inspection = try signatureInspector.inspect(
            url,
            kind: kind,
            requirement: requirement
        )
        guard inspection.state == .valid,
              let identifier = inspection.identifier,
              allowedIdentifiers.contains(identifier),
              inspection.teamIdentifier == expectedTeam else {
            let expectedIdentifiers = allowedIdentifiers.sorted().joined(separator: ", ")
            throw NSError(
                domain: "ManagerInstaller",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refusing to stage \(role) with an untrusted signing identity at "
                    + "\(url.path). Expected Team ID \(expectedTeam) and identifier "
                    + "\(expectedIdentifiers); found Team ID "
                    + "\(inspection.teamIdentifier ?? "(unavailable)") and identifier "
                    + "\(inspection.identifier ?? "(unavailable)")."]
            )
        }
        return inspection
    }

    private func validateSealedDaemonHashes(
        _ sealedHashes: [String: String]?,
        role: String,
        actualDaemonHashes: [String: String]
    ) throws {
        guard let sealedHashes else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refusing to stage \(role) because its code-signature-secured Info.plist "
                    + "does not seal the privileged filesystem daemon CodeDirectory hash."]
            )
        }
        guard sealedHashes == actualDaemonHashes else {
            let expected = actualDaemonHashes
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            let found = sealedHashes
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            throw NSError(
                domain: "ManagerInstaller",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey:
                    "Refusing to stage \(role) because its sealed daemon CodeDirectory hashes "
                    + "do not match the signed daemon. Expected \(expected); found \(found)."]
            )
        }
    }
}

private struct FileManagerArtifactCopier: ManagerArtifactCopying {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private struct FileManagerArtifactReplacer: ManagerArtifactReplacing {
    func applyReplacement(
        target: URL,
        staged: URL?,
        backup: URL,
        hadOriginal: Bool
    ) throws {
        let fm = FileManager.default
        if let staged {
            if hadOriginal {
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    try fm.moveItem(at: target, to: backup)
                    try fm.moveItem(at: staged, to: target)
                } else {
                    _ = try fm.replaceItemAt(
                        target,
                        withItemAt: staged,
                        backupItemName: backup.lastPathComponent,
                        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                    )
                }
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } else if hadOriginal {
            try fm.moveItem(at: target, to: backup)
        }
    }
}

protocol ManagerLaunchctlRunning {
    func run(arguments: [String], timeoutSec: TimeInterval) throws -> ProcessResult
}

private struct ProcessManagerLaunchctlRunner: ManagerLaunchctlRunning {
    private let runner = ProcessRunner()

    func run(arguments: [String], timeoutSec: TimeInterval) throws -> ProcessResult {
        try runner.run(
            executable: "/bin/launchctl",
            arguments: arguments,
            timeoutSec: timeoutSec
        )
    }
}

struct CodesignManagerArtifactValidator: ManagerArtifactValidating {
    private let runner: ProcessRunner
    private let signatureInspector: any ManagerCodeSignatureInspecting

    init(
        runner: ProcessRunner = ProcessRunner(),
        signatureInspector: any ManagerCodeSignatureInspecting =
            SecurityManagerCodeSignatureInspector()
    ) {
        self.runner = runner
        self.signatureInspector = signatureInspector
    }

    func prepareAndSign(_ url: URL, kind: ManagerArtifactKind) throws {
        let inspection = try signatureInspector.inspect(url, kind: kind)
        switch inspection.state {
        case .valid:
            break
        case .unsigned, .invalidAdHoc:
            break
        case .invalidCMS:
            throw signatureRefusalError(
                url: url,
                inspection: inspection,
                reason: "invalid CMS/team signature"
            )
        case .indeterminate:
            throw signatureRefusalError(
                url: url,
                inspection: inspection,
                reason: "indeterminate signature metadata"
            )
        }

        try runRequired(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", url.path],
            timeoutSec: 10,
            operation: "clear quarantine"
        )

        guard inspection.state != .valid else {
            return
        }

        // Sign only the requested top-level artifact. Nested code must already carry
        // a valid identity; recursively replacing nested signatures would erase Team IDs.
        let identifier = fallbackIdentifier(
            for: url,
            kind: kind,
            inspectedIdentifier: inspection.identifier
        )
        let signArguments = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            "--options", "runtime",
            "--identifier", identifier,
            "--preserve-metadata=identifier,entitlements",
            url.path,
        ]
        try runRequired(
            executable: "/usr/bin/codesign",
            arguments: signArguments,
            timeoutSec: kind == .applicationBundle ? 60 : 30,
            operation: "sign \(kind.description)"
        )
    }

    func verify(_ url: URL, kind: ManagerArtifactKind) throws {
        var verifyArguments = ["--verify", "--strict"]
        if kind != .executable {
            verifyArguments.append("--deep")
        }
        verifyArguments.append(url.path)
        try runRequired(
            executable: "/usr/bin/codesign",
            arguments: verifyArguments,
            timeoutSec: kind == .applicationBundle ? 60 : 30,
            operation: "verify \(kind.description)"
        )
    }

    private func fallbackIdentifier(
        for url: URL,
        kind: ManagerArtifactKind,
        inspectedIdentifier: String?
    ) -> String {
        if let inspectedIdentifier,
           !inspectedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inspectedIdentifier
        }

        switch kind {
        case .executable:
            return "com.forge-conductor.cli"
        case .framework:
            return bundleIdentifier(at: url) ?? "com.forge-conductor.core"
        case .applicationBundle:
            return bundleIdentifier(at: url) ?? ManagerInstaller.bundleIdentifier
        }
    }

    private func bundleIdentifier(at url: URL) -> String? {
        guard let value = Bundle(url: url)?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func signatureRefusalError(
        url: URL,
        inspection: ManagerArtifactSignatureInspection,
        reason: String
    ) -> Error {
        let detail = SecCopyErrorMessageString(inspection.validationStatus, nil) as String?
            ?? "unknown Security error"
        let identifier = inspection.identifier ?? "(unavailable)"
        return NSError(
            domain: "ManagerInstaller",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey:
                "Refusing to replace \(reason) for \(url.path). "
                + "identifier=\(identifier), Security \(inspection.validationStatus): \(detail)"]
        )
    }

    private func runRequired(
        executable: String,
        arguments: [String],
        timeoutSec: TimeInterval,
        operation: String
    ) throws {
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            timeoutSec: timeoutSec
        )
        guard result.exitCode == 0, !result.timedOut else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ManagerInstaller",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(operation) failed for \(arguments.last ?? "artifact") "
                    + "(exit \(result.exitCode)): \(detail)"]
            )
        }
    }
}

private extension ManagerArtifactKind {
    var description: String {
        switch self {
        case .executable: "manager executable"
        case .framework: "manager framework"
        case .applicationBundle: "manager app bundle"
        }
    }
}

/// Installs the manager binary, a proper macOS app bundle (for Login Items naming),
/// LaunchAgent, cleanup of stale legacy agents, and endpoint-protection guidance.
public final class ManagerInstaller: @unchecked Sendable {
    public static let launchAgentLabel = "com.forge-conductor.manager"
    public static let bundleIdentifier = "com.forge-conductor.app"
    public static let appDisplayName = "Forge Conductor"
    public static let preferredBinaryName = "forge-conductor"
    public static let runtimeLauncherName = RuntimeLaunchGate.executableName
    public static let embeddedManagerRelativePath = "Contents/Helpers/forge-conductor"

    /// Legacy Python/bash LaunchAgents that show as "bash" / "python3" in Login Items.
    public static let staleLaunchAgentLabels = [
        "com.forge.orchestrator",
        "com.forge.telemetry",
        "com.forge.watchdog",
    ]

    public let paths: AppPaths
    public let config: ConfigStore
    private let artifactValidator: any ManagerArtifactValidating
    private let artifactCopier: any ManagerArtifactCopying
    private let artifactReplacer: any ManagerArtifactReplacing
    private let privilegedApplicationIdentityValidator:
        any ManagerPrivilegedApplicationIdentityValidating
    private let launchctlRunner: any ManagerLaunchctlRunning

    public init(paths: AppPaths, config: ConfigStore) {
        self.paths = paths
        self.config = config
        self.artifactValidator = CodesignManagerArtifactValidator()
        self.artifactCopier = FileManagerArtifactCopier()
        self.artifactReplacer = FileManagerArtifactReplacer()
        self.privilegedApplicationIdentityValidator =
            SecurityManagerPrivilegedApplicationIdentityValidator()
        self.launchctlRunner = ProcessManagerLaunchctlRunner()
    }

    init(
        paths: AppPaths,
        config: ConfigStore,
        artifactValidator: any ManagerArtifactValidating,
        artifactCopier: any ManagerArtifactCopying = FileManagerArtifactCopier(),
        artifactReplacer: any ManagerArtifactReplacing = FileManagerArtifactReplacer(),
        privilegedApplicationIdentityValidator:
            any ManagerPrivilegedApplicationIdentityValidating =
                SecurityManagerPrivilegedApplicationIdentityValidator(),
        launchctlRunner: (any ManagerLaunchctlRunning)? = nil
    ) {
        self.paths = paths
        self.config = config
        self.artifactValidator = artifactValidator
        self.artifactCopier = artifactCopier
        self.artifactReplacer = artifactReplacer
        self.privilegedApplicationIdentityValidator =
            privilegedApplicationIdentityValidator
        self.launchctlRunner = launchctlRunner ?? ProcessManagerLaunchctlRunner()
    }

    public convenience init(app: ForgeApp) {
        self.init(paths: app.paths, config: app.config)
    }

    // MARK: - Paths

    public var installedBinaryURL: URL {
        paths.home.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(Self.preferredBinaryName)
    }

    public var installedRuntimeLauncherURL: URL {
        paths.home.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(Self.runtimeLauncherName)
    }

    /// App bundle so Login Items shows "Forge Conductor" instead of "bash".
    public var appBundleURL: URL {
        paths.home.appendingPathComponent("\(Self.appDisplayName).app", isDirectory: true)
    }

    public var appExecutableURL: URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(Self.appDisplayName)
    }

    public var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist")
    }

    public var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    var launchAgentStandardOutputURL: URL {
        paths.logsDir.appendingPathComponent("launchd-manager.out.log")
    }

    var launchAgentStandardErrorURL: URL {
        paths.logsDir.appendingPathComponent("launchd-manager.err.log")
    }

    // MARK: - Binary install

    @discardableResult
    public func installBinary(from source: URL? = nil) throws -> URL {
        try installBinary(from: source, requiringPrivilegedApplication: false)
    }

    @discardableResult
    private func installBinary(
        from source: URL?,
        requiringPrivilegedApplication: Bool
    ) throws -> URL {
        let src = try (source ?? Self.currentExecutableURL()).resolvingSymlinksInPath()
        let commandLink = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("forge-conductor-swift")
        let dest = try stageInstalledArtifacts(
            from: src,
            commandLink: commandLink,
            requiringPrivilegedApplication: requiringPrivilegedApplication
        )

        // LM Studio registration is explicit only (install-lmstudio-plugin / GUI Install Plugin).
        // Never mutate ~/.lmstudio as a side effect of copying the binary.
        return dest
    }

    /// Refreshes only Forge-home artifacts. This is the isolated staging seam used before
    /// launchd changes and by tests that must not touch the user's LaunchAgents or command links.
    @discardableResult
    func stageInstalledArtifacts(
        from sourceExecutable: URL,
        commandLink: URL? = nil,
        requiringPrivilegedApplication: Bool = false
    ) throws -> URL {
        try paths.ensureLayout()
        let fm = FileManager.default
        let binDir = paths.home.appendingPathComponent("bin", isDirectory: true)
        let libDir = paths.home.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)

        let src = sourceExecutable.resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: src.path) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Source executable is missing or not executable: \(src.path)"]
            )
        }

        let sourceApplication = try sourceApplicationBundle(
            for: src,
            requiringPrivilegedApplication: requiringPrivilegedApplication
        )
        let binarySource = try managerBinarySource(
            invokedBy: src,
            sourceApplication: sourceApplication
        )
        let runtimeLauncherSource = try runtimeLauncherSource(
            managerBinary: binarySource,
            sourceApplication: sourceApplication
        )
        if requiringPrivilegedApplication, let sourceApplication {
            if isInstalledExecutable(src),
               sameResolvedPath(sourceApplication, appBundleURL) {
                try privilegedApplicationIdentityValidator.validateStaged(
                    applicationBundle: sourceApplication,
                    executable: src
                )
            } else {
                try privilegedApplicationIdentityValidator.validate(
                    applicationBundle: sourceApplication,
                    invokedBy: src
                )
            }
            if !sameResolvedPath(binarySource, src) {
                try privilegedApplicationIdentityValidator.validate(
                    applicationBundle: sourceApplication,
                    invokedBy: binarySource
                )
            }
        }

        let transactionID = UUID().uuidString
        let binaryTarget = installedBinaryURL.standardizedFileURL
        let binaryStage = temporarySibling(
            of: binaryTarget,
            marker: "stage",
            transactionID: transactionID
        )
        let runtimeLauncherTarget = installedRuntimeLauncherURL.standardizedFileURL
        let runtimeLauncherStage = temporarySibling(
            of: runtimeLauncherTarget,
            marker: "stage",
            transactionID: transactionID
        )
        let frameworkTarget = binDir.appendingPathComponent("ForgeConductorCore.framework")
        let mirroredFrameworkTarget = libDir.appendingPathComponent("ForgeConductorCore.framework")
        let appTarget = appBundleURL.standardizedFileURL
        let commandLinkTarget = commandLink?.standardizedFileURL
        let appStage = temporarySibling(
            of: appTarget,
            marker: "stage",
            transactionID: transactionID
        )
        let sourceFramework = sourceFramework(
            for: src,
            sourceApplication: sourceApplication
        )
        if requiringPrivilegedApplication, sourceFramework == nil {
            throw privilegedPayloadError(
                "Required manager framework is unavailable for privileged staging"
            )
        }
        let frameworkStage = sourceFramework.map { _ in
            temporarySibling(
                of: frameworkTarget,
                marker: "stage",
                transactionID: transactionID
            )
        }
        let mirroredFrameworkStage = sourceFramework.map { _ in
            temporarySibling(
                of: mirroredFrameworkTarget,
                marker: "stage",
                transactionID: transactionID
            )
        }
        let commandLinkStage = commandLinkTarget.map {
            temporarySibling(
                of: $0,
                marker: "stage",
                transactionID: transactionID
            )
        }

        let temporaryURLs = [
            binaryStage,
            runtimeLauncherStage,
            frameworkStage,
            mirroredFrameworkStage,
            appStage,
            commandLinkStage,
        ].compactMap { $0 }
        defer {
            for url in temporaryURLs where itemExists(at: url) {
                try? fm.removeItem(at: url)
            }
        }

        try artifactCopier.copyItem(at: binarySource, to: binaryStage)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryStage.path)
        try artifactValidator.prepareAndSign(binaryStage, kind: .executable)
        try artifactValidator.verify(binaryStage, kind: .executable)

        try artifactCopier.copyItem(at: runtimeLauncherSource, to: runtimeLauncherStage)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtimeLauncherStage.path
        )
        try artifactValidator.prepareAndSign(runtimeLauncherStage, kind: .executable)
        try artifactValidator.verify(runtimeLauncherStage, kind: .executable)

        if let sourceFramework, let frameworkStage, let mirroredFrameworkStage {
            try artifactCopier.copyItem(at: sourceFramework, to: frameworkStage)
            try artifactValidator.prepareAndSign(frameworkStage, kind: .framework)
            try artifactValidator.verify(frameworkStage, kind: .framework)
            try artifactCopier.copyItem(at: frameworkStage, to: mirroredFrameworkStage)
            try artifactValidator.prepareAndSign(mirroredFrameworkStage, kind: .framework)
            try artifactValidator.verify(mirroredFrameworkStage, kind: .framework)
        }

        try stageApplicationBundle(
            sourceApplication: sourceApplication,
            invokedBy: src,
            executable: binaryStage,
            runtimeLauncher: runtimeLauncherStage,
            framework: frameworkStage,
            at: appStage,
            requiringPrivilegedApplication: requiringPrivilegedApplication
        )

        if let commandLinkTarget, let commandLinkStage {
            try fm.createDirectory(
                at: commandLinkTarget.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.createSymbolicLink(
                at: commandLinkStage,
                withDestinationURL: binaryTarget
            )
        }

        var replacements = [
            ArtifactReplacement(target: frameworkTarget, staged: frameworkStage),
            ArtifactReplacement(target: mirroredFrameworkTarget, staged: mirroredFrameworkStage),
            ArtifactReplacement(target: runtimeLauncherTarget, staged: runtimeLauncherStage),
            ArtifactReplacement(target: binaryTarget, staged: binaryStage),
            ArtifactReplacement(target: appTarget, staged: appStage),
        ]
        if let commandLinkTarget {
            replacements.append(
                ArtifactReplacement(target: commandLinkTarget, staged: commandLinkStage)
            )
        }
        try commitArtifactReplacements(replacements, transactionID: transactionID)
        return binaryTarget
    }

    /// Refresh the source application bundle when available, or build a minimal bundle for
    /// standalone CLI executables so Background Items can still show a real product name.
    @discardableResult
    public func installAppBundle(from sourceExecutable: URL? = nil) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: installedBinaryURL.path) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Binary not installed at \(installedBinaryURL.path)"]
            )
        }

        try paths.ensureLayout()
        if sourceExecutable == nil, itemExists(at: appBundleURL) {
            do {
                try validatePrivilegedApplicationPayload(at: appBundleURL)
                try privilegedApplicationIdentityValidator.validateStaged(
                    applicationBundle: appBundleURL,
                    executable: installedBinaryURL
                )
                return appBundleURL
            } catch {
                guard !privilegedApplicationPayloadIsPresent(at: appBundleURL) else {
                    throw error
                }
            }
        }

        let source = (sourceExecutable ?? installedBinaryURL).resolvingSymlinksInPath()
        let sourceApplication = try sourceApplicationBundle(
            for: source,
            requiringPrivilegedApplication: false
        )
        let runtimeLauncher = try runtimeLauncherSource(
            managerBinary: source,
            sourceApplication: sourceApplication
        )
        let framework = sourceFramework(
            for: source,
            sourceApplication: sourceApplication
        )
            ?? {
                let installed = installedBinaryURL.deletingLastPathComponent()
                    .appendingPathComponent("ForgeConductorCore.framework")
                return fm.fileExists(atPath: installed.path) ? installed : nil
            }()
        let transactionID = UUID().uuidString
        let stagedApp = temporarySibling(
            of: appBundleURL,
            marker: "stage",
            transactionID: transactionID
        )
        defer {
            if itemExists(at: stagedApp) {
                try? fm.removeItem(at: stagedApp)
            }
        }

        try stageApplicationBundle(
            sourceApplication: sourceApplication,
            invokedBy: source,
            executable: installedBinaryURL,
            runtimeLauncher: runtimeLauncher,
            framework: framework,
            at: stagedApp,
            requiringPrivilegedApplication: false
        )
        try commitArtifactReplacements([
            ArtifactReplacement(target: appBundleURL, staged: stagedApp),
        ], transactionID: transactionID)
        return appBundleURL
    }

    private func stageApplicationBundle(
        sourceApplication: URL?,
        invokedBy sourceExecutable: URL,
        executable: URL,
        runtimeLauncher: URL,
        framework: URL?,
        at stagedBundle: URL,
        requiringPrivilegedApplication: Bool
    ) throws {
        let fm = FileManager.default
        if let sourceBundle = sourceApplication {
            try artifactCopier.copyItem(at: sourceBundle, to: stagedBundle)
        } else {
            guard !requiringPrivilegedApplication else {
                throw privilegedApplicationUnavailableError(
                    invokedBy: sourceExecutable,
                    rejectedCandidates: []
                )
            }
            try createMinimalAppBundle(
                at: stagedBundle,
                executable: executable,
                runtimeLauncher: runtimeLauncher,
                framework: framework
            )
        }

        let runtimeLauncherURL = embeddedRuntimeLauncher(in: stagedBundle)
        try requirePayloadItem(runtimeLauncherURL, type: S_IFREG, executable: true)

        let executableURL = applicationExecutable(in: stagedBundle)
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "Staged app bundle is missing executable \(executableURL.path)"]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try artifactValidator.prepareAndSign(stagedBundle, kind: .applicationBundle)
        try artifactValidator.verify(stagedBundle, kind: .applicationBundle)
        if requiringPrivilegedApplication {
            try validatePrivilegedApplicationPayload(at: stagedBundle)
            try privilegedApplicationIdentityValidator.validateStaged(
                applicationBundle: stagedBundle,
                executable: executable
            )
        }
    }

    private func createMinimalAppBundle(
        at bundleURL: URL,
        executable: URL,
        runtimeLauncher: URL,
        framework: URL?
    ) throws {
        let fm = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)

        let version = ForgeApp.version
        let buildVersion = ForgeApp.buildVersion
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleDevelopmentRegion</key>
          <string>en</string>
          <key>CFBundleDisplayName</key>
          <string>\(Self.appDisplayName)</string>
          <key>CFBundleExecutable</key>
          <string>\(Self.appDisplayName)</string>
          <key>CFBundleIdentifier</key>
          <string>\(Self.bundleIdentifier)</string>
          <key>CFBundleInfoDictionaryVersion</key>
          <string>6.0</string>
          <key>CFBundleName</key>
          <string>\(Self.appDisplayName)</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>\(escapeXML(version))</string>
          <key>CFBundleVersion</key>
          <string>\(escapeXML(buildVersion))</string>
          <key>LSMinimumSystemVersion</key>
          <string>26.0</string>
          <key>LSUIElement</key>
          <true/>
          <key>NSHighResolutionCapable</key>
          <true/>
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        try "APPL????".write(
            to: contents.appendingPathComponent("PkgInfo"),
            atomically: true,
            encoding: .utf8
        )

        // Copy binary as the app executable (BTM keys off this path).
        let exe = applicationExecutable(in: bundleURL)
        try artifactCopier.copyItem(at: executable, to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let bundledRuntimeLauncher = embeddedRuntimeLauncher(in: bundleURL)
        try artifactCopier.copyItem(at: runtimeLauncher, to: bundledRuntimeLauncher)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledRuntimeLauncher.path
        )

        if let framework {
            let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
            try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
            try artifactCopier.copyItem(
                at: framework,
                to: frameworks.appendingPathComponent(framework.lastPathComponent)
            )
        }
    }

    private func sourceFramework(
        for sourceExecutable: URL,
        sourceApplication: URL?
    ) -> URL? {
        let name = "ForgeConductorCore.framework"
        var candidates: [URL] = []
        if let sourceBundle = sourceApplication {
            candidates.append(
                sourceBundle
                    .appendingPathComponent("Contents/Frameworks", isDirectory: true)
                    .appendingPathComponent(name)
            )
        }
        candidates.append(sourceExecutable.deletingLastPathComponent().appendingPathComponent(name))
        candidates.append(
            sourceExecutable.deletingLastPathComponent()
                .appendingPathComponent("PackageFrameworks", isDirectory: true)
                .appendingPathComponent(name)
        )
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func managerBinarySource(
        invokedBy sourceExecutable: URL,
        sourceApplication: URL?
    ) throws -> URL {
        guard let sourceApplication,
              sameResolvedPath(
                sourceExecutable,
                applicationExecutable(in: sourceApplication)
              ) else {
            return sourceExecutable
        }

        let embeddedManager = embeddedManagerExecutable(in: sourceApplication)
        try requirePayloadItem(embeddedManager, type: S_IFREG, executable: true)
        return embeddedManager
    }

    private func runtimeLauncherSource(
        managerBinary: URL,
        sourceApplication: URL?
    ) throws -> URL {
        let source = sourceApplication.map { embeddedRuntimeLauncher(in: $0) }
            ?? managerBinary.deletingLastPathComponent()
                .appendingPathComponent(Self.runtimeLauncherName)
        try requirePayloadItem(source, type: S_IFREG, executable: true)
        return source
    }

    private func applicationExecutable(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(Self.appDisplayName)
    }

    private func embeddedManagerExecutable(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(Self.embeddedManagerRelativePath)
    }

    private func embeddedRuntimeLauncher(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Self.runtimeLauncherName)
    }

    private func temporarySibling(
        of target: URL,
        marker: String,
        transactionID: String
    ) -> URL {
        let parent = target.deletingLastPathComponent()
        let pathExtension = target.pathExtension
        let baseName = pathExtension.isEmpty
            ? target.lastPathComponent
            : target.deletingPathExtension().lastPathComponent
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return parent.appendingPathComponent(
            ".\(baseName).\(marker)-\(transactionID)\(suffix)"
        )
    }

    private struct ArtifactReplacement {
        let target: URL
        let staged: URL?
    }

    private struct CommitRecord {
        let target: URL
        let staged: URL?
        let backup: URL
        let hadOriginal: Bool
    }

    private func commitArtifactReplacements(
        _ replacements: [ArtifactReplacement],
        transactionID: String
    ) throws {
        let fm = FileManager.default
        var records: [CommitRecord] = []

        do {
            for replacement in replacements {
                let backup = temporarySibling(
                    of: replacement.target,
                    marker: "backup",
                    transactionID: transactionID
                )
                let record = CommitRecord(
                    target: replacement.target,
                    staged: replacement.staged,
                    backup: backup,
                    hadOriginal: itemExists(at: replacement.target)
                )
                records.append(record)
                try artifactReplacer.applyReplacement(
                    target: replacement.target,
                    staged: replacement.staged,
                    backup: backup,
                    hadOriginal: record.hadOriginal
                )
            }
        } catch {
            let rollbackFailures = rollbackArtifactReplacements(records.reversed())
            guard rollbackFailures.isEmpty else {
                throw NSError(
                    domain: "ManagerInstaller",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Artifact commit failed: \(error.localizedDescription). "
                        + "Rollback failures: \(rollbackFailures.joined(separator: "; "))"]
                )
            }
            throw error
        }

        for record in records where itemExists(at: record.backup) {
            try? fm.removeItem(at: record.backup)
        }
    }

    private func rollbackArtifactReplacements<S: Sequence>(
        _ records: S
    ) -> [String] where S.Element == CommitRecord {
        let fm = FileManager.default
        var failures: [String] = []
        for record in records {
            do {
                if itemExists(at: record.backup) {
                    if itemExists(at: record.target) {
                        try fm.removeItem(at: record.target)
                    }
                    try fm.moveItem(at: record.backup, to: record.target)
                } else if !record.hadOriginal,
                          itemExists(at: record.target),
                          record.staged.map({ !itemExists(at: $0) }) ?? false {
                    try fm.removeItem(at: record.target)
                }
            } catch {
                failures.append("\(record.target.path): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func isInstalledExecutable(_ executable: URL) -> Bool {
        sameResolvedPath(executable, installedBinaryURL)
    }

    private func privilegedApplicationPayloadIsPresent(at bundle: URL) -> Bool {
        let daemon = bundle.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let launchDaemon = bundle.appendingPathComponent(
            "Contents/Library/LaunchDaemons/"
                + ForgeFilesystemProtocolConstants.daemonPlistName
        )
        return itemExists(at: daemon) || itemExists(at: launchDaemon)
    }

    private func sourceApplicationBundle(
        for executable: URL,
        requiringPrivilegedApplication: Bool
    ) throws -> URL? {
        let containingBundle = sourceAppBundle(containing: executable)
        let isInstalledPrivilegedInvocation = requiringPrivilegedApplication
            && isInstalledExecutable(executable)
        let siblingBundle = isInstalledPrivilegedInvocation
            ? nil
            : executable.deletingLastPathComponent()
                .appendingPathComponent("\(Self.appDisplayName).app", isDirectory: true)
        let installedBundle = isInstalledPrivilegedInvocation
            ? appBundleURL
            : nil
        var candidates: [URL] = []
        var candidatePaths = Set<String>()
        for candidate in [containingBundle, siblingBundle, installedBundle].compactMap({ $0 }) {
            let standardized = candidate.standardizedFileURL
            if candidatePaths.insert(standardized.path).inserted {
                candidates.append(standardized)
            }
        }

        if !requiringPrivilegedApplication, let containingBundle {
            return containingBundle
        }

        var rejectedCandidates: [String] = []
        for candidate in candidates where itemExists(at: candidate) {
            do {
                try validatePrivilegedApplicationPayload(at: candidate)
                return candidate
            } catch {
                rejectedCandidates.append("\(candidate.path): \(error.localizedDescription)")
            }
        }

        guard requiringPrivilegedApplication else { return nil }
        throw privilegedApplicationUnavailableError(
            invokedBy: executable,
            rejectedCandidates: rejectedCandidates
        )
    }

    private func validatePrivilegedApplicationPayload(at bundle: URL) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let managerFramework = frameworks.appendingPathComponent(
            "ForgeConductorCore.framework",
            isDirectory: true
        )
        let library = contents.appendingPathComponent("Library", isDirectory: true)
        let launchDaemons = library.appendingPathComponent(
            "LaunchDaemons",
            isDirectory: true
        )
        let infoPlist = contents.appendingPathComponent("Info.plist")
        let appExecutable = applicationExecutable(in: bundle)
        let managerExecutable = embeddedManagerExecutable(in: bundle)
        let runtimeLauncher = embeddedRuntimeLauncher(in: bundle)
        let daemonExecutable = macOS.appendingPathComponent(
            ForgeFilesystemProtocolConstants.daemonExecutableName
        )
        let daemonPlist = launchDaemons.appendingPathComponent(
            ForgeFilesystemProtocolConstants.daemonPlistName
        )

        for directory in [
            bundle,
            contents,
            macOS,
            helpers,
            frameworks,
            managerFramework,
            library,
            launchDaemons,
        ] {
            try requirePayloadItem(directory, type: S_IFDIR, executable: false)
        }
        try requirePayloadItem(infoPlist, type: S_IFREG, executable: false)
        try requirePayloadItem(appExecutable, type: S_IFREG, executable: true)
        try requirePayloadItem(managerExecutable, type: S_IFREG, executable: true)
        try requirePayloadItem(runtimeLauncher, type: S_IFREG, executable: true)
        try requirePayloadItem(daemonExecutable, type: S_IFREG, executable: true)
        try requirePayloadItem(daemonPlist, type: S_IFREG, executable: false)

        let appInformation = try readPropertyList(at: infoPlist)
        guard appInformation["CFBundleIdentifier"] as? String
                == ForgeFilesystemProtocolConstants.appIdentifier,
              appInformation["CFBundleExecutable"] as? String == Self.appDisplayName else {
            throw privilegedPayloadError(
                "App Info.plist must identify \(ForgeFilesystemProtocolConstants.appIdentifier) "
                + "with executable \(Self.appDisplayName)"
            )
        }

        let daemonInformation = try readPropertyList(at: daemonPlist)
        let machServices = daemonInformation["MachServices"] as? [String: Any]
        guard daemonInformation["Label"] as? String
                == ForgeFilesystemProtocolConstants.serviceName,
              daemonInformation["BundleProgram"] as? String
                == "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)",
              daemonInformation["UserName"] as? String == "root",
              machServices?[ForgeFilesystemProtocolConstants.serviceName] as? Bool == true else {
            throw privilegedPayloadError(
                "LaunchDaemon plist does not declare the required root service "
                + ForgeFilesystemProtocolConstants.serviceName
            )
        }
    }

    private func requirePayloadItem(
        _ url: URL,
        type: mode_t,
        executable: Bool
    ) throws {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        let hasExecutableBit = information.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
        guard status == 0,
              information.st_mode & S_IFMT == type,
              !executable || hasExecutableBit else {
            let expected = type == S_IFDIR
                ? "directory"
                : (executable ? "regular executable" : "regular file")
            throw privilegedPayloadError(
                "Required \(expected) is missing or unsafe: \(url.path)"
            )
        }
    }

    private func readPropertyList(at url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let value = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let dictionary = value as? [String: Any] else {
                throw privilegedPayloadError("Property list is not a dictionary: \(url.path)")
            }
            return dictionary
        } catch {
            if (error as NSError).domain == "ManagerInstaller" {
                throw error
            }
            throw privilegedPayloadError(
                "Cannot read required property list \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private func privilegedPayloadError(_ message: String) -> NSError {
        NSError(
            domain: "ManagerInstaller",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func privilegedApplicationUnavailableError(
        invokedBy executable: URL,
        rejectedCandidates: [String]
    ) -> NSError {
        let detail = rejectedCandidates.isEmpty
            ? "No enclosing or sibling \(Self.appDisplayName).app was found."
            : rejectedCandidates.joined(separator: "; ")
        return NSError(
            domain: "ManagerInstaller",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey:
                "Cannot install the manager Login Item from \(executable.path) because a "
                + "complete signed \(Self.appDisplayName).app with its embedded manager CLI, "
                + "manager framework, privileged filesystem daemon, and LaunchDaemon plist "
                + "is unavailable. \(detail)"]
        )
    }

    private func sourceAppBundle(containing executable: URL) -> URL? {
        let executableDirectory = executable.deletingLastPathComponent()
        guard executableDirectory.lastPathComponent == "MacOS"
                || executableDirectory.lastPathComponent == "Helpers" else {
            return nil
        }
        let contents = executableDirectory.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let bundle = contents.deletingLastPathComponent()
        guard bundle.lastPathComponent == "\(Self.appDisplayName).app" else { return nil }
        let expectedExecutable = executableDirectory.lastPathComponent == "MacOS"
            ? applicationExecutable(in: bundle)
            : embeddedManagerExecutable(in: bundle)
        guard expectedExecutable.standardizedFileURL.path == executable.standardizedFileURL.path,
              FileManager.default.isExecutableFile(atPath: expectedExecutable.path) else {
            return nil
        }
        return bundle
    }

    // MARK: - Stale agent cleanup

    /// Unload and remove legacy com.forge.* LaunchAgents (appear as bash/python3 in Login Items).
    @discardableResult
    public func cleanupStaleLaunchAgents() throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        let uid = getuid()

        for label in Self.staleLaunchAgentLabels {
            let plist = launchAgentsDir.appendingPathComponent("\(label).plist")
            var entry: [String: Any] = ["label": label, "plist": plist.path]

            let bootout = try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["bootout", "gui/\(uid)/\(label)"],
                timeoutSec: 10
            )
            _ = try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["unload", "-w", plist.path],
                timeoutSec: 10
            )
            // disable so it does not come back via enablement
            _ = try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["disable", "gui/\(uid)/\(label)"],
                timeoutSec: 5
            )

            var removed = false
            if FileManager.default.fileExists(atPath: plist.path) {
                // Archive instead of hard-delete for rollback
                let archiveDir = paths.home.appendingPathComponent("legacy-launchagents", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                let dest = archiveDir.appendingPathComponent("\(label).plist")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: plist, to: dest)
                removed = true
                entry["archived_to"] = dest.path
            }

            entry["bootout_exit"] = bootout?.exitCode as Any
            entry["removed"] = removed
            entry["ok"] = true
            results.append(entry)
        }

        // Do not run `sfltool resetbtm` — it wipes all Background Items for the user.
        // macOS refreshes Login Items after bootout + log out/in.
        return results
    }

    public func listForgeLaunchAgents() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let labels = Self.staleLaunchAgentLabels + [Self.launchAgentLabel]
        for label in labels {
            let plist = launchAgentsDir.appendingPathComponent("\(label).plist")
            let loaded = (try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["print", "gui/\(getuid())/\(label)"],
                timeoutSec: 3
            ))?.exitCode == 0
            out.append([
                "label": label,
                "plist_exists": FileManager.default.fileExists(atPath: plist.path),
                "plist": plist.path,
                "loaded": loaded,
                "stale": Self.staleLaunchAgentLabels.contains(label),
            ])
        }
        return out
    }

    // MARK: - Login LaunchAgent

    @discardableResult
    public func installLoginAgent(openBrowser: Bool = false) throws -> URL {
        // Always stage from this process before launchd starts the manager. Reusing an existing
        // executable here can silently keep an older manager and framework running after upgrade.
        // The Login Item must retain the complete signed app payload because that app owns the
        // privileged SMAppService daemon. A synthesized display-only bundle is insufficient.
        _ = try installBinary(from: nil, requiringPrivilegedApplication: true)

        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let exe = appExecutableURL.path

        var programArgs = [
            exe,
            "manager",
            "run",
            "--home",
            paths.home.path,
        ]
        if openBrowser {
            programArgs.append("--open")
        }

        // AssociatedBundleIdentifiers ties the agent to the .app for Login Items naming.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(Self.launchAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
        \(programArgs.map { "    <string>\(escapeXML($0))</string>" }.joined(separator: "\n"))
          </array>
          <key>AssociatedBundleIdentifiers</key>
          <array>
            <string>\(Self.bundleIdentifier)</string>
          </array>
          <key>WorkingDirectory</key>
          <string>\(escapeXML(paths.home.path))</string>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>FORGE_CONDUCTOR_HOME</key>
            <string>\(escapeXML(paths.home.path))</string>
            <key>PATH</key>
            <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(escapeXML(paths.home.appendingPathComponent("bin").path))</string>
          </dict>
          <key>StandardOutPath</key>
          <string>\(escapeXML(launchAgentStandardOutputURL.path))</string>
          <key>StandardErrorPath</key>
          <string>\(escapeXML(launchAgentStandardErrorURL.path))</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
        </dict>
        </plist>
        """
        // Note: ProcessType Interactive helps some Login Items UIs treat it as a user agent.
        let uid = getuid()
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 10
        )
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["unload", launchAgentURL.path],
            timeoutSec: 10
        )

        // launchd owns these descriptors while the agent is loaded. Rotate only after bootout so
        // the replacement process starts with fresh logs and retained failures stay size-bounded.
        try rotateLaunchAgentLogs()
        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)

        // Ensure domain enablement
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["enable", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 5
        )

        try loadLoginAgent(plistURL: launchAgentURL, uid: uid)

        return launchAgentURL
    }

    /// Loads the LaunchAgent through the modern bootstrap path with the established
    /// legacy fallback, then proves launchd owns a live process for the exact job label.
    /// A successful legacy `load` exit alone is not readiness evidence.
    func loadLoginAgent(
        plistURL: URL,
        uid: uid_t,
        readinessAttempts: Int = 5,
        readinessDelaySec: TimeInterval = 0.2
    ) throws {
        let userDomain = "gui/\(uid)"
        let jobTarget = "\(userDomain)/\(Self.launchAgentLabel)"
        func cleanupDetail() -> String {
            cleanupFailedLoginAgent(
                jobTarget: jobTarget,
                plistURL: plistURL,
                verificationAttempts: readinessAttempts,
                verificationDelaySec: readinessDelaySec
            )
        }
        let beforeLoad: ProcessResult
        do {
            beforeLoad = try launchctlRunner.run(
                arguments: ["print", jobTarget],
                timeoutSec: 5
            )
        } catch {
            let cleanup = cleanupDetail()
            throw launchAgentReadinessError(
                jobTarget: jobTarget,
                bootstrap: nil,
                legacyLoad: nil,
                detail: "could not prove the exact job absent before load: "
                    + error.localizedDescription + "; " + cleanup
            )
        }
        guard launchAgentIsProvenAbsent(beforeLoad) else {
            let cleanup = cleanupDetail()
            throw launchAgentReadinessError(
                jobTarget: jobTarget,
                bootstrap: nil,
                legacyLoad: nil,
                detail: "exact job was still present or absence was ambiguous before load "
                    + "(exit \(beforeLoad.exitCode), timed_out=\(beforeLoad.timedOut)); "
                    + cleanup
            )
        }

        let bootstrap: ProcessResult
        do {
            bootstrap = try launchctlRunner.run(
                arguments: ["bootstrap", userDomain, plistURL.path],
                timeoutSec: 15
            )
        } catch {
            let cleanup = cleanupDetail()
            throw launchAgentReadinessError(
                jobTarget: jobTarget,
                bootstrap: nil,
                legacyLoad: nil,
                detail: "launchctl bootstrap failed: \(error.localizedDescription); \(cleanup)"
            )
        }

        var legacyLoad: ProcessResult?
        if bootstrap.exitCode != 0 || bootstrap.timedOut {
            let fallback: ProcessResult
            do {
                fallback = try launchctlRunner.run(
                    arguments: ["load", "-w", plistURL.path],
                    timeoutSec: 15
                )
            } catch {
                let cleanup = cleanupDetail()
                throw launchAgentReadinessError(
                    jobTarget: jobTarget,
                    bootstrap: bootstrap,
                    legacyLoad: nil,
                    detail: "legacy launchctl load failed: "
                        + error.localizedDescription + "; " + cleanup
                )
            }
            legacyLoad = fallback
            if fallback.exitCode != 0 || fallback.timedOut {
                let cleanup = cleanupDetail()
                throw launchAgentReadinessError(
                    jobTarget: jobTarget,
                    bootstrap: bootstrap,
                    legacyLoad: fallback,
                    detail: "legacy launchctl load returned an unsuccessful result; " + cleanup
                )
            }
        }

        _ = try? launchctlRunner.run(
            arguments: ["kickstart", "-k", jobTarget],
            timeoutSec: 10
        )

        let attemptLimit = max(1, min(readinessAttempts, 10))
        let retryDelay = max(0, min(readinessDelaySec, 1))
        let expectedProgramPath = canonicalExecutablePath(appExecutableURL.path)
            ?? appExecutableURL.standardizedFileURL.path
        var lastReadinessDetail = "launchctl print was not attempted"
        for attempt in 1...attemptLimit {
            do {
                let readiness = try launchctlRunner.run(
                    arguments: ["print", jobTarget],
                    timeoutSec: 5
                )
                let identity = launchAgentIdentity(from: readiness.stdout)
                let programMatches = identity.programPath
                    .flatMap(canonicalExecutablePath)
                    .map { $0 == expectedProgramPath }
                    ?? false
                if readiness.exitCode == 0,
                   !readiness.timedOut,
                   identity.pid != nil,
                   programMatches {
                    return
                }
                lastReadinessDetail = "launchctl print did not report both a positive pid "
                    + "and expected program \(appExecutableURL.path) "
                    + "on attempt \(attempt)/\(attemptLimit) "
                    + "(exit \(readiness.exitCode), timed_out=\(readiness.timedOut), "
                    + "observed_pid=\(identity.pid.map(String.init) ?? "none"), "
                    + "observed_program=\(identity.programPath ?? "none"))"
            } catch {
                lastReadinessDetail = "launchctl print failed on attempt "
                    + "\(attempt)/\(attemptLimit): \(error.localizedDescription)"
            }

            if attempt < attemptLimit, retryDelay > 0 {
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }

        let cleanup = cleanupDetail()
        throw launchAgentReadinessError(
            jobTarget: jobTarget,
            bootstrap: bootstrap,
            legacyLoad: legacyLoad,
            detail: lastReadinessDetail + "; " + cleanup
        )
    }

    private func launchAgentIsProvenAbsent(_ result: ProcessResult) -> Bool {
        let missingService = "Could not find service \"\(Self.launchAgentLabel)\""
        return result.exitCode == 113
            && !result.timedOut
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && result.stderr.contains(missingService)
    }

    private func launchAgentIdentity(from output: String) -> (
        pid: Int32?,
        programPath: String?
    ) {
        var pid: Int32?
        var programPath: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let key = fields[0].trimmingCharacters(in: .whitespaces)
            let value = launchctlScalarValue(fields[1])
            switch key {
            case "pid":
                if let parsedPID = Int32(value), parsedPID > 0 {
                    pid = parsedPID
                }
            case "program":
                if value.hasPrefix("/") {
                    programPath = value
                }
            default:
                break
            }
        }
        return (pid, programPath)
    }

    private func launchctlScalarValue(_ rawValue: Substring) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private func canonicalExecutablePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func cleanupFailedLoginAgent(
        jobTarget: String,
        plistURL: URL,
        verificationAttempts: Int,
        verificationDelaySec: TimeInterval
    ) -> String {
        var commandSummaries: [String] = []
        for (arguments, timeoutSec) in [
            (["bootout", jobTarget], TimeInterval(10)),
            (["disable", jobTarget], TimeInterval(5)),
            (["unload", "-w", plistURL.path], TimeInterval(10)),
        ] {
            do {
                let result = try launchctlRunner.run(
                    arguments: arguments,
                    timeoutSec: timeoutSec
                )
                commandSummaries.append(
                    "\(arguments[0])_exit=\(result.exitCode) "
                        + "\(arguments[0])_timed_out=\(result.timedOut)"
                )
            } catch {
                commandSummaries.append(
                    "\(arguments[0])_error="
                        + String(error.localizedDescription.prefix(256))
                )
            }
        }

        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? FileManager.default.removeItem(at: plistURL)
        }
        let plistAbsent = !FileManager.default.fileExists(atPath: plistURL.path)

        let attemptLimit = max(1, min(verificationAttempts, 10))
        let retryDelay = max(0, min(verificationDelaySec, 1))
        var exactJobAbsent = false
        var verificationSummary = "cleanup print was not attempted"
        for attempt in 1...attemptLimit {
            do {
                let result = try launchctlRunner.run(
                    arguments: ["print", jobTarget],
                    timeoutSec: 5
                )
                if launchAgentIsProvenAbsent(result) {
                    exactJobAbsent = true
                    verificationSummary = "cleanup print proved exact job absent "
                        + "on attempt \(attempt)/\(attemptLimit)"
                    break
                }
                let identity = launchAgentIdentity(from: result.stdout)
                verificationSummary = "cleanup print retained or ambiguously reported job "
                    + "on attempt \(attempt)/\(attemptLimit) "
                    + "(exit \(result.exitCode), timed_out=\(result.timedOut), "
                    + "pid=\(identity.pid.map(String.init) ?? "none"), "
                    + "program=\(identity.programPath ?? "none"))"
            } catch {
                verificationSummary = "cleanup print failed on attempt "
                    + "\(attempt)/\(attemptLimit): "
                    + String(error.localizedDescription.prefix(256))
            }

            if attempt < attemptLimit, retryDelay > 0 {
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }

        return "cleanup_exact_job_absent=\(exactJobAbsent) "
            + "cleanup_plist_absent=\(plistAbsent) "
            + commandSummaries.joined(separator: " ") + "; "
            + verificationSummary
    }

    private func launchAgentReadinessError(
        jobTarget: String,
        bootstrap: ProcessResult?,
        legacyLoad: ProcessResult?,
        detail: String
    ) -> NSError {
        let bootstrapSummary = bootstrap.map {
            "bootstrap_exit=\($0.exitCode) bootstrap_timed_out=\($0.timedOut)"
        } ?? "bootstrap_not_attempted=true"
        let fallback = legacyLoad.map {
            " legacy_load_exit=\($0.exitCode) legacy_load_timed_out=\($0.timedOut)"
        } ?? ""
        return NSError(
            domain: "ManagerInstaller",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "launchctl load failed: expected live job \(jobTarget); \(detail); "
                + "\(bootstrapSummary)\(fallback)"]
        )
    }

    /// Retains a small, fixed number of bounded launchd log tails during reinstall.
    /// This helper only touches files under the configured Forge home. The active launchd
    /// files remain append-only until the next reinstall because launchd owns their descriptors.
    func rotateLaunchAgentLogs(
        maxBytesPerFile: Int = 1_048_576,
        retainedGenerations: Int = 2
    ) throws {
        guard maxBytesPerFile > 0, retainedGenerations > 0 else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "Log rotation requires positive size and retention limits"]
            )
        }
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        for logURL in [launchAgentStandardOutputURL, launchAgentStandardErrorURL] {
            try rotateLog(
                at: logURL,
                maxBytesPerFile: maxBytesPerFile,
                retainedGenerations: retainedGenerations
            )
        }
    }

    private func rotateLog(
        at logURL: URL,
        maxBytesPerFile: Int,
        retainedGenerations: Int
    ) throws {
        let fm = FileManager.default
        try pruneExcessLogArchives(
            for: logURL,
            retainedGenerations: retainedGenerations
        )
        guard fm.fileExists(atPath: logURL.path) else {
            try boundRetainedLogArchives(
                for: logURL,
                maxBytesPerFile: maxBytesPerFile,
                retainedGenerations: retainedGenerations
            )
            return
        }

        let currentSize = try fileSize(at: logURL)
        guard currentSize > 0 else {
            try fm.removeItem(at: logURL)
            try boundRetainedLogArchives(
                for: logURL,
                maxBytesPerFile: maxBytesPerFile,
                retainedGenerations: retainedGenerations
            )
            return
        }

        if retainedGenerations > 1 {
            for generation in stride(from: retainedGenerations, through: 2, by: -1) {
                let destination = rotatedLogURL(logURL, generation: generation)
                let source = rotatedLogURL(logURL, generation: generation - 1)
                if fm.fileExists(atPath: source.path) {
                    try writeBoundedTail(
                        from: source,
                        to: destination,
                        maxBytes: maxBytesPerFile
                    )
                    try fm.removeItem(at: source)
                } else if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
            }
        }

        let newestArchive = rotatedLogURL(logURL, generation: 1)
        try writeBoundedTail(from: logURL, to: newestArchive, maxBytes: maxBytesPerFile)
        try fm.removeItem(at: logURL)
    }

    private func pruneExcessLogArchives(
        for logURL: URL,
        retainedGenerations: Int
    ) throws {
        let fm = FileManager.default
        let directory = logURL.deletingLastPathComponent()
        let prefix = "\(logURL.lastPathComponent)."
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix),
                  let generation = Int(name.dropFirst(prefix.count)) else {
                continue
            }
            if generation < 1 || generation > retainedGenerations {
                try fm.removeItem(at: entry)
            }
        }
    }

    private func boundRetainedLogArchives(
        for logURL: URL,
        maxBytesPerFile: Int,
        retainedGenerations: Int
    ) throws {
        for generation in 1...retainedGenerations {
            let archive = rotatedLogURL(logURL, generation: generation)
            guard FileManager.default.fileExists(atPath: archive.path),
                  try fileSize(at: archive) > UInt64(maxBytesPerFile) else {
                continue
            }
            let data = try boundedTailData(from: archive, maxBytes: maxBytesPerFile)
            try data.write(to: archive, options: .atomic)
        }
    }

    private func rotatedLogURL(_ logURL: URL, generation: Int) -> URL {
        URL(fileURLWithPath: "\(logURL.path).\(generation)")
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func writeBoundedTail(from source: URL, to destination: URL, maxBytes: Int) throws {
        let data = try boundedTailData(from: source, maxBytes: maxBytes)
        try data.write(to: destination, options: .atomic)
    }

    private func boundedTailData(from source: URL, maxBytes: Int) throws -> Data {
        let size = try fileSize(at: source)
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    @discardableResult
    public func uninstallLoginAgent() throws -> Bool {
        let uid = getuid()
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 10
        )
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["disable", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 5
        )
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["unload", "-w", launchAgentURL.path],
            timeoutSec: 10
        )
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
            return true
        }
        return false
    }

    public func isLoginAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public func isLoginAgentLoaded() -> Bool {
        let r = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(Self.launchAgentLabel)"],
            timeoutSec: 5
        )
        return (r?.exitCode == 0) && !(r?.stdout.isEmpty ?? true)
    }

    // MARK: - Firewall

    public func tryAllowFirewall() -> [String: Any] {
        var pathsToAllow = [
            installedBinaryURL.path,
            installedRuntimeLauncherURL.path,
            appExecutableURL.path,
        ]
        pathsToAllow = pathsToAllow.filter { FileManager.default.fileExists(atPath: $0) }
        guard !pathsToAllow.isEmpty else {
            return ["ok": false, "message": "binary not installed"]
        }
        var details: [[String: Any]] = []
        var anyOK = false
        for path in pathsToAllow {
            let blocked = try? ProcessRunner().run(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getappblocked", path],
                timeoutSec: 5
            )
            let add = try? ProcessRunner().run(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--add", path],
                timeoutSec: 5
            )
            _ = try? ProcessRunner().run(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--unblockapp", path],
                timeoutSec: 5
            )
            let ok = (add?.exitCode == 0) || (blocked?.stdout.contains("permitted") == true)
            if ok { anyOK = true }
            details.append([
                "path": path,
                "ok": ok,
                "getappblocked": blocked?.stdout ?? "",
            ])
        }
        return [
            "ok": anyOK,
            "items": details,
            "note": "On Jamf-managed Macs, firewall changes may require admin or a config profile.",
        ]
    }

    // MARK: - Endpoint protection report

    public func endpointProtectionReport() -> [String: Any] {
        var extensions: [[String: Any]] = []
        // systemextensionsctl can hang indefinitely on managed Macs — hard-cap and skip on failure.
        if let r = try? ProcessRunner().run(
            executable: "/usr/bin/systemextensionsctl",
            arguments: ["list"],
            timeoutSec: 2
        ), r.exitCode == 0 {
            for line in r.stdout.split(separator: "\n").map(String.init) {
                let lower = line.lowercased()
                if lower.contains("endpoint_security") || lower.contains("network_extension")
                    || lower.contains("falcon") || lower.contains("jamf.protect")
                    || lower.contains("traps") || lower.contains("globalprotect")
                    || lower.contains("cortex") {
                    extensions.append(["line": line.trimmingCharacters(in: .whitespaces)])
                }
            }
        }

        let binary = installedBinaryURL.path
        let binaryExists = FileManager.default.isExecutableFile(atPath: binary)
        let legacyLink = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/forge-conductor").path
        var legacyTarget = ""
        if let t = try? FileManager.default.destinationOfSymbolicLink(atPath: legacyLink) {
            legacyTarget = t
        }

        let port = config.int("dashboard", "port", default: 7788)
        let agents = listForgeLaunchAgents()
        let staleStillPresent = agents.contains {
            ($0["stale"] as? Bool == true) && ($0["plist_exists"] as? Bool == true || $0["loaded"] as? Bool == true)
        }

        return [
            "ok": true,
            "system_extensions_sample": extensions,
            "binary": [
                "recommended_path": binary,
                "installed": binaryExists,
                "app_bundle": appBundleURL.path,
                "app_executable": appExecutableURL.path,
                "bundle_id": Self.bundleIdentifier,
                "display_name": Self.appDisplayName,
                "legacy_local_bin": legacyLink,
                "legacy_symlink_target": legacyTarget,
                "legacy_warning": legacyTarget.contains("Application Support/ForgeConductor")
                    || legacyTarget.contains(".venv")
                    ? "WARNING: ~/.local/bin/forge-conductor points at the old Python venv."
                    : "",
            ] as [String: Any],
            "login_agent": [
                "label": Self.launchAgentLabel,
                "plist": launchAgentURL.path,
                "installed": isLoginAgentInstalled(),
                "loaded": isLoginAgentLoaded(),
                "shows_in_login_items_as": Self.appDisplayName,
            ] as [String: Any],
            "launch_agents": agents,
            "stale_agents_present": staleStillPresent,
            "stale_hint": staleStillPresent
                ? "Legacy agents still present (show as bash/python3). Run: forge-conductor manager cleanup-stale"
                : "No stale com.forge.* agents",
            "dashboard_port": port,
            "port_in_use": isPortListening(port),
            "allowlist": allowlistInstructions(binaryPath: binary, port: port),
        ]
    }

    public func allowlistInstructions(binaryPath: String, port: Int) -> [String: Any] {
        [
            "macos_login_items": [
                "System Settings → General → Login Items & Extensions → Allow in the Background",
                "Look for \"\(Self.appDisplayName)\" (not bash/python3)",
                "If missing: run manager cleanup-stale then manager install-login, then log out/in once",
                "Endpoint Security Extensions (Falcon/Jamf Protect/Cortex) are IT-managed — leave enabled",
            ],
            "macos_firewall": [
                "Allow incoming for: \(binaryPath)",
                "And: \(appExecutableURL.path)",
            ],
            "crowdstrike_falcon": [
                "Allow process: \(binaryPath)",
                "Allow app bundle: \(appBundleURL.path)",
                "Allow listen 127.0.0.1:\(port)",
            ],
            "jamf_protect": [
                "Exception for \(binaryPath) and \(Self.bundleIdentifier)",
            ],
            "commands": [
                "forge-conductor manager cleanup-stale",
                "forge-conductor manager install-login",
                "forge-conductor manager status",
            ],
        ]
    }

    // MARK: - Helpers

    public static func currentExecutableURL() throws -> URL {
        try SelfExecutable.pathURL()
    }

    private func isPortListening(_ port: Int) -> Bool {
        let r = try? ProcessRunner().run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
            timeoutSec: 5
        )
        return (r?.exitCode == 0) && !(r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum SelfExecutable {
    public static func path() throws -> String {
        try pathURL().path
    }

    public static func pathURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: max(Int(size), Int(PATH_MAX)))
        let result = buf.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        if result == 0 {
            let path = String(
                decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(arg0)
            .resolvingSymlinksInPath()
    }
}
