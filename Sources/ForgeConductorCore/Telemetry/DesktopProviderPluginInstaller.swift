// DesktopProviderPluginInstaller.swift
// What: Packages and transactionally installs Forge's Claude, Codex, and Grok desktop-host plugins.
// How: Deterministic manifests are staged under Forge ownership, verified by hash, and committed with rollback.
// Why: A provider toggle must configure supported orchestration hosts without corrupting unrelated user settings.

import Darwin
import Foundation

public enum DesktopProviderPluginHost: String, Codable, CaseIterable, Sendable {
    case claudeCodeDesktop = "claude-code-desktop"
    case codexDesktop = "codex-desktop"
    case grokBuild = "grok-build"

    var providerID: String {
        switch self {
        case .claudeCodeDesktop: "claude-desktop"
        case .codexDesktop: "codex-desktop"
        case .grokBuild: "grok-build"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCodeDesktop: "claude"
        case .codexDesktop: "codex"
        case .grokBuild: "grok"
        }
    }
}

public enum DesktopProviderPluginDisposition: String, Codable, Sendable {
    case installed
    case unchanged
    case removed
    case awaitingUserAction = "awaiting_user_action"
}

public enum DesktopProviderPluginWarning: String, Codable, Sendable, Equatable {
    case hookTrustReviewRequired = "hook_trust_review_required"
}

public struct DesktopProviderPluginRequest: Sendable, Equatable {
    public var host: DesktopProviderPluginHost
    public var forgeExecutable: URL
    public var includeMCP: Bool
    public var pluginVersion: String

    public init(
        host: DesktopProviderPluginHost,
        forgeExecutable: URL,
        includeMCP: Bool = true,
        pluginVersion: String = "1.0.0"
    ) {
        self.host = host
        self.forgeExecutable = forgeExecutable
        self.includeMCP = includeMCP
        self.pluginVersion = pluginVersion
    }
}

public struct DesktopProviderPluginFileReceipt: Codable, Sendable, Equatable {
    public var relativePath: String
    public var byteCount: Int
    public var sha256: String

    private enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case byteCount = "byte_count"
        case sha256
    }
}

public struct DesktopProviderPluginCommandReceipt: Codable, Sendable, Equatable {
    public var executable: String
    public var argumentCount: Int
    public var exitCode: Int32?
    public var timedOut: Bool
    public var outputTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case executable
        case argumentCount = "argument_count"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case outputTruncated = "output_truncated"
    }
}

public struct DesktopProviderPluginReceipt: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maximumFiles = 24
    public static let maximumCommandAttempts = 8

    public var schemaVersion: Int
    public var host: DesktopProviderPluginHost
    public var pluginVersion: String
    public var mcpEnabled: Bool
    public var packageSHA256: String
    public var installedAt: String
    public var disposition: DesktopProviderPluginDisposition
    public var deploymentVerified: Bool
    public var warnings: [DesktopProviderPluginWarning]
    public var files: [DesktopProviderPluginFileReceipt]
    public var commandAttempts: [DesktopProviderPluginCommandReceipt]
    public var detail: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case host
        case pluginVersion = "plugin_version"
        case mcpEnabled = "mcp_enabled"
        case packageSHA256 = "package_sha256"
        case installedAt = "installed_at"
        case disposition
        case deploymentVerified = "deployment_verified"
        case warnings
        case files
        case commandAttempts = "command_attempts"
        case detail
    }
}

public struct DesktopProviderPluginStatus: Sendable, Equatable {
    public var host: DesktopProviderPluginHost
    public var disposition: DesktopProviderPluginDisposition
    public var packagePath: String
    public var configurationPath: String?
    public var packageVerified: Bool
    public var configurationVerified: Bool
    public var deploymentVerified: Bool
    public var commandLineHostAvailable: Bool
    public var mcpEnabled: Bool
    public var receipt: DesktopProviderPluginReceipt?
    public var warnings: [DesktopProviderPluginWarning]
    public var detail: String

    public var isReady: Bool {
        packageVerified && configurationVerified && deploymentVerified
            && disposition != .awaitingUserAction && disposition != .removed
    }
}

public struct DesktopProviderPluginCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public protocol DesktopProviderPluginCommandRunning: Sendable {
    func executable(named name: String) -> URL?
    func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> DesktopProviderPluginCommandResult
}

public struct DesktopProviderPluginNativeCommandRunner: DesktopProviderPluginCommandRunning {
    public init() {}

    public func executable(named name: String) -> URL? {
        Self.discoverExecutable(
            named: name,
            pathCandidate: ProcessRunner.which(name),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default
        )
    }

    static func discoverExecutable(
        named name: String,
        pathCandidate: String?,
        homeDirectory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard ["claude", "codex", "grok"].contains(name) else { return nil }
        var candidates: [URL] = []
        if let pathCandidate, !pathCandidate.isEmpty {
            candidates.append(URL(fileURLWithPath: pathCandidate))
        }
        switch name {
        case "codex":
            candidates.append(homeDirectory.appendingPathComponent(
                "Applications/ChatGPT.app/Contents/Resources/codex"
            ))
            candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"))
        case "grok":
            candidates.append(homeDirectory.appendingPathComponent(".grok/bin/grok"))
        default:
            break
        }
        candidates.append(homeDirectory.appendingPathComponent(".local/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))

        var visited: Set<String> = []
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard visited.insert(resolved.path).inserted,
                  resolved.path.hasPrefix("/"),
                  !resolved.path.contains("\n"),
                  !resolved.path.contains("\0"),
                  fileManager.isExecutableFile(atPath: resolved.path),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            return resolved
        }
        return nil
    }

    public func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> DesktopProviderPluginCommandResult {
        let result = try ProcessRunner().run(
            executable: executable.path,
            arguments: arguments,
            timeoutSec: timeoutSeconds,
            maximumOutputBytes: maximumOutputBytes
        )
        return DesktopProviderPluginCommandResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut,
            stdoutTruncated: result.stdoutTruncated,
            stderrTruncated: result.stderrTruncated
        )
    }
}

public struct DesktopProviderPluginFilesystemRoots: Sendable, Equatable {
    public var forgeOwnedRoot: URL
    public var forgeHome: URL
    public var userHome: URL
    public var grokHome: URL

    public init(forgeOwnedRoot: URL, userHome: URL, grokHome: URL? = nil, forgeHome: URL? = nil) {
        self.forgeOwnedRoot = forgeOwnedRoot.standardizedFileURL
        self.forgeHome = (forgeHome ?? forgeOwnedRoot.deletingLastPathComponent()).standardizedFileURL
        self.userHome = userHome.standardizedFileURL
        self.grokHome = (grokHome ?? userHome.appendingPathComponent(".grok", isDirectory: true))
            .standardizedFileURL
    }

    public static var live: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configuredGrokHome = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Self(
            forgeOwnedRoot: AppPaths().home.appendingPathComponent("desktop-provider-plugins", isDirectory: true),
            userHome: home,
            grokHome: configuredGrokHome
        )
    }
}

public enum DesktopProviderPluginCommitPoint: Sendable {
    case packageInstalledBeforeConfiguration
    case packageRemovedBeforeConfiguration
}

public enum DesktopProviderPluginInstallerError: Error, LocalizedError, Equatable, Sendable {
    case invalidExecutable(String)
    case invalidPluginVersion(String)
    case unsafePath(String)
    case symlinkRefused(String)
    case malformedJSON(String)
    case unownedConflict(String)
    case invalidStagedPackage(String)
    case invalidReceipt(String)
    case commitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable(let path): "Forge executable is missing or is not executable: \(path)"
        case .invalidPluginVersion(let version): "Plugin version is not semantic versioning: \(version)"
        case .unsafePath(let path): "Refusing unsafe plugin path: \(path)"
        case .symlinkRefused(let path): "Refusing symlink in plugin installation path: \(path)"
        case .malformedJSON(let path): "Refusing to replace malformed or incompatible JSON: \(path)"
        case .unownedConflict(let path): "A non-Forge entry already owns the requested plugin location: \(path)"
        case .invalidStagedPackage(let reason): "Staged desktop plugin failed validation: \(reason)"
        case .invalidReceipt(let path): "Desktop plugin receipt is invalid: \(path)"
        case .commitFailed(let reason): "Desktop plugin transaction failed and was rolled back: \(reason)"
        }
    }
}

public final class DesktopProviderPluginInstaller: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Date
    public typealias CommitFaultInjector = @Sendable (DesktopProviderPluginCommitPoint) throws -> Void

    private static let pluginName = "forge-conductor"
    private static let marketplaceName = "forge-conductor"
    private static let installerID = "forge-conductor"
    private static let maximumConfigurationBytes = 512 * 1_024
    private static let maximumReceiptBytes = 64 * 1_024
    private static let commandTimeoutSeconds: TimeInterval = 15
    private static let maximumCommandOutputBytes = 32 * 1_024
    private static let maximumDetailCharacters = 512

    private let roots: DesktopProviderPluginFilesystemRoots
    private let commandRunner: any DesktopProviderPluginCommandRunning
    private let clock: Clock
    private let commitFaultInjector: CommitFaultInjector
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        roots: DesktopProviderPluginFilesystemRoots = .live,
        commandRunner: any DesktopProviderPluginCommandRunning = DesktopProviderPluginNativeCommandRunner(),
        clock: @escaping Clock = { Date() },
        commitFaultInjector: @escaping CommitFaultInjector = { _ in },
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.commandRunner = commandRunner
        self.clock = clock
        self.commitFaultInjector = commitFaultInjector
        self.fileManager = fileManager
    }

    public func install(_ request: DesktopProviderPluginRequest) throws -> DesktopProviderPluginStatus {
        lock.lock()
        defer { lock.unlock() }
        try validate(request)

        let package = try generatedPackage(for: request)
        let configuration = try configurationPlan(for: request, package: package)
        let packageSHA256 = packageDigest(host: request.host, files: package.files)
        let priorReceipt = try readReceiptIfPresent(host: request.host)
        let receiptURL = receiptURL(host: request.host)

        if try packageMatches(package), configuration.isCurrent,
           let priorReceipt,
           priorReceipt.packageSHA256 == packageSHA256,
           priorReceipt.mcpEnabled == request.includeMCP,
           priorReceipt.pluginVersion == request.pluginVersion {
            let liveActivation = inspectLiveActivation(
                for: request,
                package: package,
                configuration: configuration
            )
            if priorReceipt.deploymentVerified,
               priorReceipt.disposition != .awaitingUserAction,
               priorReceipt.disposition != .removed,
               liveActivation?.succeeded != false {
                return makeStatus(
                    request: request,
                    package: package,
                    configuration: configuration,
                    disposition: .unchanged,
                    receipt: priorReceipt,
                    detail: "Forge Conductor's plugin package and host registration are already current."
                )
            }

            // The package is already committed, but a prior activation attempt did
            // not verify the host. Repair retries only bounded host activation and
            // preserves the original installation timestamp and package contents.
            try validateWritableTarget(receiptURL, under: roots.forgeOwnedRoot, finalKind: .regularFile)
            return try finalizeActivation(
                request: request,
                package: package,
                configuration: configuration,
                packageSHA256: packageSHA256,
                receiptURL: receiptURL,
                installedAt: priorReceipt.installedAt
            )
        }

        try validateWritableTarget(package.target, under: package.allowedRoot, finalKind: .directory)
        if let url = configuration.url {
            try validateWritableTarget(url, under: configuration.allowedRoot, finalKind: .regularFile)
        }
        try validateWritableTarget(receiptURL, under: roots.forgeOwnedRoot, finalKind: .regularFile)

        let transactionRoot = roots.forgeOwnedRoot
            .appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let staged = transactionRoot.appendingPathComponent("staged", isDirectory: true)
        let backup = transactionRoot.appendingPathComponent("backup", isDirectory: true)
        try createOwnerOnlyDirectory(transactionRoot)
        defer { try? fileManager.removeItem(at: transactionRoot) }

        try writePackage(package.files, to: staged)
        try verifyPackage(package.files, at: staged)

        let targetExisted = fileManager.fileExists(atPath: package.target.path)
        let originalReceipt = try readExistingRegularFile(receiptURL, maximumBytes: Self.maximumReceiptBytes)
        var packageCommitted = false
        var configurationWriteAttempted = false
        var receiptWriteAttempted = false

        do {
            try createOwnerOnlyDirectory(package.target.deletingLastPathComponent())
            if targetExisted {
                try assertForgeOwnedPackage(at: package.target, host: request.host)
                try fileManager.moveItem(at: package.target, to: backup)
            }
            try fileManager.moveItem(at: staged, to: package.target)
            packageCommitted = true
            try commitFaultInjector(.packageInstalledBeforeConfiguration)

            if let url = configuration.url, !configuration.isCurrent {
                configurationWriteAttempted = true
                try OwnerOnlyAtomicFile.write(configuration.updatedData!, to: url)
                guard try readExistingRegularFile(url, maximumBytes: Self.maximumConfigurationBytes)
                    == configuration.updatedData else {
                    throw DesktopProviderPluginInstallerError.commitFailed("configuration verification failed")
                }
            }

            let provisional = makeReceipt(
                request: request,
                packageSHA256: packageSHA256,
                files: package.files,
                disposition: .awaitingUserAction,
                deploymentVerified: false,
                warnings: warnings(for: request.host),
                attempts: [],
                detail: "Plugin files are committed; host activation verification is pending."
            )
            receiptWriteAttempted = true
            try writeReceipt(provisional, to: receiptURL)
        } catch {
            do {
                if receiptWriteAttempted {
                    try restoreFile(originalReceipt, at: receiptURL)
                }
                if configurationWriteAttempted, let url = configuration.url {
                    try restoreFile(configuration.originalData, at: url)
                }
                if packageCommitted {
                    try removeOwnedPackageIfPresent(at: package.target, host: request.host)
                }
                if targetExisted, fileManager.fileExists(atPath: backup.path) {
                    try fileManager.moveItem(at: backup, to: package.target)
                }
            } catch let rollbackError {
                throw DesktopProviderPluginInstallerError.commitFailed(
                    "\(error.localizedDescription); rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            if let typed = error as? DesktopProviderPluginInstallerError { throw typed }
            throw DesktopProviderPluginInstallerError.commitFailed(error.localizedDescription)
        }

        return try finalizeActivation(
            request: request,
            package: package,
            configuration: configuration,
            packageSHA256: packageSHA256,
            receiptURL: receiptURL
        )
    }

    public func remove(_ request: DesktopProviderPluginRequest) throws -> DesktopProviderPluginStatus {
        lock.lock()
        defer { lock.unlock() }
        try validate(request)

        let package = try generatedPackage(for: request)
        let configuration = try removalConfigurationPlan(for: request, package: package)
        let receiptURL = receiptURL(host: request.host)
        let receipt = try readReceiptIfPresent(host: request.host)
        try validateWritableTarget(package.target, under: package.allowedRoot, finalKind: .directory)
        if let url = configuration.url {
            try validateWritableTarget(url, under: configuration.allowedRoot, finalKind: .regularFile)
        }
        try validateWritableTarget(receiptURL, under: roots.forgeOwnedRoot, finalKind: .regularFile)

        let targetExists = fileManager.fileExists(atPath: package.target.path)
        if targetExists { try assertForgeOwnedPackage(at: package.target, host: request.host) }
        let originalReceipt = try readExistingRegularFile(receiptURL, maximumBytes: Self.maximumReceiptBytes)
        if !targetExists, receipt == nil, !configuration.isCurrent {
            throw DesktopProviderPluginInstallerError.unownedConflict(
                configuration.url?.path ?? package.target.path
            )
        }
        if !targetExists, configuration.isCurrent, originalReceipt == nil {
            return removedStatus(request: request, package: package, configuration: configuration)
        }
        let hostRemoval = removeHostRegistration(
            for: request,
            package: package,
            configuration: configuration
        )
        guard hostRemoval.succeeded else {
            return awaitingRemovalStatus(
                request: request,
                package: package,
                configuration: configuration,
                receipt: receipt,
                removal: hostRemoval
            )
        }

        let transactionRoot = roots.forgeOwnedRoot
            .appendingPathComponent("transactions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let backup = transactionRoot.appendingPathComponent("backup", isDirectory: true)
        try createOwnerOnlyDirectory(transactionRoot)
        defer { try? fileManager.removeItem(at: transactionRoot) }

        var packageMoved = false
        var configurationWriteAttempted = false
        var receiptRemovalAttempted = false
        do {
            if targetExists {
                try fileManager.moveItem(at: package.target, to: backup)
                packageMoved = true
            }
            try commitFaultInjector(.packageRemovedBeforeConfiguration)
            if let url = configuration.url, !configuration.isCurrent {
                configurationWriteAttempted = true
                if let updated = configuration.updatedData {
                    try OwnerOnlyAtomicFile.write(updated, to: url)
                } else {
                    try OwnerOnlyAtomicFile.removeIfExists(at: url)
                }
                guard configurationMatches(configuration) else {
                    throw DesktopProviderPluginInstallerError.commitFailed("configuration removal verification failed")
                }
            }
            receiptRemovalAttempted = true
            try OwnerOnlyAtomicFile.removeIfExists(at: receiptURL)
        } catch {
            do {
                if receiptRemovalAttempted { try restoreFile(originalReceipt, at: receiptURL) }
                if configurationWriteAttempted, let url = configuration.url {
                    try restoreFile(configuration.originalData, at: url)
                }
                if packageMoved, fileManager.fileExists(atPath: backup.path) {
                    try fileManager.moveItem(at: backup, to: package.target)
                }
            } catch let rollbackError {
                throw DesktopProviderPluginInstallerError.commitFailed(
                    "\(error.localizedDescription); rollback also failed: \(rollbackError.localizedDescription)"
                )
            }
            if hostRemoval.hostStateChanged {
                let hostRollback = activateHost(
                    for: request,
                    package: package,
                    configuration: try configurationPlan(for: request, package: package)
                )
                guard hostRollback.succeeded else {
                    throw DesktopProviderPluginInstallerError.commitFailed(
                        "\(error.localizedDescription); local files were restored, but host activation also requires repair"
                    )
                }
            }
            if let typed = error as? DesktopProviderPluginInstallerError { throw typed }
            throw DesktopProviderPluginInstallerError.commitFailed(error.localizedDescription)
        }

        return removedStatus(request: request, package: package, configuration: configuration)
    }

    public func status(for request: DesktopProviderPluginRequest) throws -> DesktopProviderPluginStatus {
        lock.lock()
        defer { lock.unlock() }
        try validate(request)
        let package = try generatedPackage(for: request)
        let configuration = try configurationPlan(for: request, package: package)
        let receipt = try readReceiptIfPresent(host: request.host)
        let verified = try packageMatches(package) && configuration.isCurrent
        let liveActivation = verified
            ? inspectLiveActivation(for: request, package: package, configuration: configuration)
            : nil
        let liveDeploymentVerified = liveActivation?.succeeded
        let disposition: DesktopProviderPluginDisposition
        let detail: String
        if verified, let receipt,
           receipt.packageSHA256 == packageDigest(host: request.host, files: package.files),
           receipt.pluginVersion == request.pluginVersion,
           receipt.mcpEnabled == request.includeMCP,
           receipt.deploymentVerified,
           liveDeploymentVerified != false {
            disposition = receipt.disposition
            detail = receipt.detail
        } else {
            disposition = .awaitingUserAction
            if receipt == nil {
                detail = "Forge Conductor's plugin is not installed for this host."
            } else if liveDeploymentVerified == false {
                detail = "The host's live plugin inventory does not show Forge Conductor installed and enabled; run repair."
            } else {
                detail = "The installed plugin package or host registration no longer matches its receipt; run repair."
            }
        }
        return makeStatus(
            request: request,
            package: package,
            configuration: configuration,
            disposition: disposition,
            receipt: receipt,
            detail: detail,
            deploymentVerifiedOverride: liveDeploymentVerified
        )
    }
}

private extension DesktopProviderPluginInstaller {
    enum FinalPathKind { case directory, regularFile }

    struct GeneratedPackage {
        var target: URL
        var allowedRoot: URL
        var files: [String: Data]
    }

    struct ConfigurationPlan {
        var url: URL?
        var allowedRoot: URL
        var originalData: Data?
        var updatedData: Data?
        var catalogName: String?

        var isCurrent: Bool {
            guard url != nil else { return true }
            return originalData == updatedData
        }
    }

    struct HostActivation {
        var cliAvailable: Bool
        var succeeded: Bool
        var attempts: [DesktopProviderPluginCommandReceipt]
        var hostStateChanged: Bool = false
    }

    struct HostActivationCommand {
        var arguments: [String]
        var verifiesInventory: Bool
        var acceptedIdempotentPhrases: [String] = []
    }

    func validate(_ request: DesktopProviderPluginRequest) throws {
        let path = request.forgeExecutable.standardizedFileURL.path
        guard request.forgeExecutable.isFileURL,
              path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\0"),
              fileManager.isExecutableFile(atPath: path),
              isRegularFileWithoutFollowingSymlink(request.forgeExecutable) else {
            throw DesktopProviderPluginInstallerError.invalidExecutable(path)
        }
        let expression = try NSRegularExpression(
            pattern: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
        )
        let range = NSRange(request.pluginVersion.startIndex..., in: request.pluginVersion)
        guard request.pluginVersion.count <= 64,
              expression.firstMatch(in: request.pluginVersion, range: range)?.range == range else {
            throw DesktopProviderPluginInstallerError.invalidPluginVersion(request.pluginVersion)
        }
    }

    func generatedPackage(for request: DesktopProviderPluginRequest) throws -> GeneratedPackage {
        let files: [String: Data]
        let target: URL
        let allowedRoot: URL
        switch request.host {
        case .claudeCodeDesktop:
            target = roots.forgeOwnedRoot.appendingPathComponent("claude-marketplace", isDirectory: true)
            allowedRoot = roots.forgeOwnedRoot
            files = try claudeMarketplaceFiles(request: request)
        case .codexDesktop:
            let pluginsRoot = roots.userHome.appendingPathComponent("plugins", isDirectory: true)
            target = pluginsRoot.appendingPathComponent(Self.pluginName, isDirectory: true)
            allowedRoot = roots.userHome
            files = try codexPluginFiles(request: request)
        case .grokBuild:
            target = roots.grokHome
                .appendingPathComponent("plugins", isDirectory: true)
                .appendingPathComponent(Self.pluginName, isDirectory: true)
            allowedRoot = roots.grokHome
            files = try grokPluginFiles(request: request)
        }
        guard files.count <= DesktopProviderPluginReceipt.maximumFiles else {
            throw DesktopProviderPluginInstallerError.invalidStagedPackage("too many generated files")
        }
        return GeneratedPackage(target: target, allowedRoot: allowedRoot, files: files)
    }

    func claudeMarketplaceFiles(request: DesktopProviderPluginRequest) throws -> [String: Data] {
        let prefix = "plugins/\(Self.pluginName)/"
        var files: [String: Data] = [
            ".forge-conductor-owner.json": try jsonData(ownershipObject(host: request.host)),
            ".claude-plugin/marketplace.json": try jsonData([
                "name": Self.marketplaceName,
                "owner": ["name": "Forge Conductor"],
                "plugins": [[
                    "name": Self.pluginName,
                    "source": "./plugins/\(Self.pluginName)",
                    "description": pluginDescription,
                    "version": request.pluginVersion,
                ]],
            ]),
            prefix + ".claude-plugin/plugin.json": try jsonData(claudeManifest(request: request)),
            prefix + "hooks/hooks.json": try jsonData(hooksObject(request: request)),
            prefix + "skills/forge-run/SKILL.md": skillData,
        ]
        if request.includeMCP {
            files[prefix + ".mcp.json"] = try jsonData(mcpObject(request: request, portable: false))
        }
        return files
    }

    func codexPluginFiles(request: DesktopProviderPluginRequest) throws -> [String: Data] {
        var compatibility: [String: Any] = [
            "name": Self.pluginName,
            "version": request.pluginVersion,
            "description": pluginDescription,
            "author": ["name": "Forge Conductor"],
            "skills": "./skills/",
            "hooks": "./hooks/hooks.json",
            "interface": codexInterface,
        ]
        if request.includeMCP { compatibility["mcpServers"] = "./mcp.json" }
        var files: [String: Data] = [
            ".forge-conductor-owner.json": try jsonData(ownershipObject(host: request.host)),
            "plugin.json": try jsonData([
                "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
                "name": Self.pluginName,
                "version": request.pluginVersion,
                "description": pluginDescription,
                "author": ["name": "Forge Conductor"],
            ]),
            ".codex-plugin/plugin.json": try jsonData(compatibility),
            "hooks/hooks.json": try jsonData(hooksObject(request: request)),
            "skills/forge-run/SKILL.md": skillData,
        ]
        if request.includeMCP {
            files["mcp.json"] = try jsonData(mcpObject(request: request, portable: true))
        }
        return files
    }

    func grokPluginFiles(request: DesktopProviderPluginRequest) throws -> [String: Data] {
        let manifest: [String: Any] = [
            "name": Self.pluginName,
            "version": request.pluginVersion,
            "description": pluginDescription,
        ]
        var files: [String: Data] = [
            ".forge-conductor-owner.json": try jsonData(ownershipObject(host: request.host)),
            "plugin.json": try jsonData(manifest),
            "hooks/hooks.json": try jsonData(hooksObject(request: request)),
            "skills/forge-run/SKILL.md": skillData,
        ]
        if request.includeMCP {
            files[".mcp.json"] = try jsonData(mcpObject(request: request, portable: false))
        }
        return files
    }

    var pluginDescription: String {
        "Connects the desktop coding host to Forge Conductor's project-scoped orchestration runtime."
    }

    var codexInterface: [String: Any] {
        [
            "displayName": "Forge Conductor",
            "shortDescription": "Project-scoped desktop orchestration",
            "longDescription": pluginDescription,
            "developerName": "Forge Conductor",
            "category": "Developer Tools",
            "capabilities": ["Interactive", "Write"],
            "defaultPrompt": ["Check Forge Conductor for an eligible project task."],
            "brandColor": "#C87830",
        ]
    }

    func claudeManifest(request: DesktopProviderPluginRequest) -> [String: Any] {
        var manifest: [String: Any] = [
            "name": Self.pluginName,
            "description": pluginDescription,
            "version": request.pluginVersion,
            "author": ["name": "Forge Conductor"],
            "skills": "./skills/",
            "hooks": "./hooks/hooks.json",
        ]
        if request.includeMCP { manifest["mcpServers"] = "./.mcp.json" }
        return manifest
    }

    func ownershipObject(host: DesktopProviderPluginHost) -> [String: Any] {
        [
            "schema_version": 1,
            "installer": Self.installerID,
            "plugin": Self.pluginName,
            "host": host.rawValue,
        ]
    }

    func hooksObject(request: DesktopProviderPluginRequest) -> [String: Any] {
        let events: [String]
        switch request.host {
        case .claudeCodeDesktop:
            events = [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                "PostToolUse", "PostToolUseFailure", "Stop", "SessionEnd",
            ]
        case .codexDesktop:
            events = [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                "PostToolUse", "Stop", "SessionEnd",
            ]
        case .grokBuild:
            // Grok's native hook contract has no PermissionRequest event. Its
            // documented passive events keep Forge's record aligned with the
            // host without changing Grok's permission policy.
            events = [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PostToolUseFailure", "PermissionDenied", "Stop", "StopFailure",
                "Notification", "SubagentStart", "SubagentStop", "PreCompact",
                "PostCompact", "SessionEnd",
            ]
        }
        let executable = shellQuote(request.forgeExecutable.standardizedFileURL.path)
        let forgeHome = shellQuote(roots.forgeHome.path)
        let hooks = Dictionary(uniqueKeysWithValues: events.map { event in
            let command = "\(executable) provider-hook \(request.host.providerID) \(event) --home \(forgeHome)"
            return (event, [[
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 10,
                ]],
            ]])
        })
        return ["hooks": hooks]
    }

    func mcpObject(request: DesktopProviderPluginRequest, portable: Bool) -> [String: Any] {
        var server: [String: Any] = [
            "command": request.forgeExecutable.standardizedFileURL.path,
            "args": [
                "serve", "--home", roots.forgeHome.path,
                "--desktop-provider", request.host.providerID,
            ],
        ]
        if portable { server["type"] = "stdio" }
        var object: [String: Any] = ["mcpServers": [Self.pluginName: server]]
        if portable {
            object["$schema"] = "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"
        }
        return object
    }

    var skillData: Data {
        Data(
            """
            ---
            name: forge-run
            description: Check Forge Conductor for an eligible task in the current project and follow its bounded orchestration contract.
            ---

            Use Forge Conductor's lifecycle integration to check for work scoped to the current project.
            Never claim work from another project, invent a task when none is offered, bypass a permission prompt, or report completion without durable evidence.
            If the optional Forge Conductor MCP server is available, prefer its project-scoped tools for status and checkpoints.
            """.utf8
        )
    }

    func configurationPlan(
        for request: DesktopProviderPluginRequest,
        package: GeneratedPackage
    ) throws -> ConfigurationPlan {
        switch request.host {
        case .claudeCodeDesktop:
            let url = roots.userHome
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
            let original = try readExistingRegularFile(url, maximumBytes: Self.maximumConfigurationBytes)
            let updated = try mergedClaudeSettings(original: original, at: url, marketplaceRoot: package.target)
            return ConfigurationPlan(
                url: url,
                allowedRoot: roots.userHome,
                originalData: original,
                updatedData: updated,
                catalogName: Self.marketplaceName
            )
        case .codexDesktop:
            let url = roots.userHome
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
                .appendingPathComponent("marketplace.json")
            let original = try readExistingRegularFile(url, maximumBytes: Self.maximumConfigurationBytes)
            let merged = try mergedCodexMarketplace(original: original, at: url)
            return ConfigurationPlan(
                url: url,
                allowedRoot: roots.userHome,
                originalData: original,
                updatedData: merged.data,
                catalogName: merged.name
            )
        case .grokBuild:
            return ConfigurationPlan(
                url: nil,
                allowedRoot: roots.grokHome,
                originalData: nil,
                updatedData: nil,
                catalogName: nil
            )
        }
    }

    func removalConfigurationPlan(
        for request: DesktopProviderPluginRequest,
        package: GeneratedPackage
    ) throws -> ConfigurationPlan {
        switch request.host {
        case .claudeCodeDesktop:
            let url = roots.userHome
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
            let original = try readExistingRegularFile(url, maximumBytes: Self.maximumConfigurationBytes)
            return ConfigurationPlan(
                url: url,
                allowedRoot: roots.userHome,
                originalData: original,
                updatedData: try removingClaudeRegistration(
                    original: original,
                    at: url,
                    marketplaceRoot: package.target
                ),
                catalogName: Self.marketplaceName
            )
        case .codexDesktop:
            let url = roots.userHome
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
                .appendingPathComponent("marketplace.json")
            let original = try readExistingRegularFile(url, maximumBytes: Self.maximumConfigurationBytes)
            let catalogName = try original.map {
                try codexMarketplaceName(from: $0, at: url)
            }
            return ConfigurationPlan(
                url: url,
                allowedRoot: roots.userHome,
                originalData: original,
                updatedData: try removingCodexRegistration(original: original, at: url),
                catalogName: catalogName
            )
        case .grokBuild:
            return ConfigurationPlan(
                url: nil,
                allowedRoot: roots.grokHome,
                originalData: nil,
                updatedData: nil,
                catalogName: nil
            )
        }
    }

    func mergedClaudeSettings(original: Data?, at url: URL, marketplaceRoot: URL) throws -> Data {
        var root: [String: Any]
        if let original {
            root = try jsonObject(original, at: url)
        } else {
            root = [:]
        }

        var marketplaces = try dictionary(root["extraKnownMarketplaces"], key: "extraKnownMarketplaces", at: url)
        let expectedMarketplace: [String: Any] = [
            "source": [
                "source": "directory",
                "path": marketplaceRoot.standardizedFileURL.path,
            ],
            "autoUpdate": false,
        ]
        if let existing = marketplaces[Self.marketplaceName] {
            guard let existingDictionary = existing as? [String: Any],
                  NSDictionary(dictionary: existingDictionary).isEqual(to: expectedMarketplace) else {
                throw DesktopProviderPluginInstallerError.unownedConflict(
                    "\(url.path)#extraKnownMarketplaces.\(Self.marketplaceName)"
                )
            }
        }
        marketplaces[Self.marketplaceName] = expectedMarketplace
        root["extraKnownMarketplaces"] = marketplaces

        var enabled = try dictionary(root["enabledPlugins"], key: "enabledPlugins", at: url)
        let pluginKey = "\(Self.pluginName)@\(Self.marketplaceName)"
        if let value = enabled[pluginKey], !(value is Bool) {
            throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#enabledPlugins.\(pluginKey)")
        }
        enabled[pluginKey] = true
        root["enabledPlugins"] = enabled
        return try jsonData(root)
    }

    func removingClaudeRegistration(original: Data?, at url: URL, marketplaceRoot: URL) throws -> Data? {
        guard let original else { return nil }
        var root = try jsonObject(original, at: url)
        var changed = false
        if var marketplaces = root["extraKnownMarketplaces"] as? [String: Any] {
            if let existing = marketplaces[Self.marketplaceName] {
                let expected: [String: Any] = [
                    "source": [
                        "source": "directory",
                        "path": marketplaceRoot.standardizedFileURL.path,
                    ],
                    "autoUpdate": false,
                ]
                guard let dictionary = existing as? [String: Any],
                      NSDictionary(dictionary: dictionary).isEqual(to: expected) else {
                    throw DesktopProviderPluginInstallerError.unownedConflict(
                        "\(url.path)#extraKnownMarketplaces.\(Self.marketplaceName)"
                    )
                }
                marketplaces.removeValue(forKey: Self.marketplaceName)
                root["extraKnownMarketplaces"] = marketplaces
                changed = true
            }
        } else if root["extraKnownMarketplaces"] != nil {
            throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#extraKnownMarketplaces")
        }
        if var enabled = root["enabledPlugins"] as? [String: Any] {
            let key = "\(Self.pluginName)@\(Self.marketplaceName)"
            if let value = enabled[key] {
                guard value is Bool else {
                    throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#enabledPlugins.\(key)")
                }
                enabled.removeValue(forKey: key)
                root["enabledPlugins"] = enabled
                changed = true
            }
        } else if root["enabledPlugins"] != nil {
            throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#enabledPlugins")
        }
        return changed ? try jsonData(root) : original
    }

    func mergedCodexMarketplace(original: Data?, at url: URL) throws -> (data: Data, name: String) {
        var root: [String: Any]
        if let original {
            root = try jsonObject(original, at: url)
        } else {
            root = [
                "name": "personal",
                "interface": ["displayName": "Personal"],
                "plugins": [],
            ]
        }
        guard let name = root["name"] as? String,
              !name.isEmpty,
              name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let rawPlugins = root["plugins"] as? [Any] else {
            throw DesktopProviderPluginInstallerError.malformedJSON(url.path)
        }
        var plugins: [[String: Any]] = []
        var ownIndex: Int?
        for value in rawPlugins {
            guard let plugin = value as? [String: Any],
                  let pluginName = plugin["name"] as? String,
                  !pluginName.isEmpty else {
                throw DesktopProviderPluginInstallerError.malformedJSON(url.path)
            }
            if pluginName == Self.pluginName {
                guard ownIndex == nil else {
                    throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#duplicate-\(Self.pluginName)")
                }
                guard let source = plugin["source"] as? [String: Any],
                      source["source"] as? String == "local",
                      source["path"] as? String == "./plugins/\(Self.pluginName)" else {
                    throw DesktopProviderPluginInstallerError.unownedConflict("\(url.path)#\(Self.pluginName)")
                }
                ownIndex = plugins.count
            }
            plugins.append(plugin)
        }
        let entry: [String: Any] = [
            "name": Self.pluginName,
            "source": [
                "source": "local",
                "path": "./plugins/\(Self.pluginName)",
            ],
            "policy": [
                "installation": "INSTALLED_BY_DEFAULT",
                "authentication": "ON_INSTALL",
            ],
            "category": "Developer Tools",
        ]
        if let ownIndex { plugins[ownIndex] = entry } else { plugins.append(entry) }
        root["plugins"] = plugins
        return (try jsonData(root), name)
    }

    func codexMarketplaceName(from data: Data, at url: URL) throws -> String {
        let root = try jsonObject(data, at: url)
        guard let name = root["name"] as? String,
              !name.isEmpty,
              name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#name")
        }
        return name
    }

    func removingCodexRegistration(original: Data?, at url: URL) throws -> Data? {
        guard let original else { return nil }
        var root = try jsonObject(original, at: url)
        guard root["name"] is String, let rawPlugins = root["plugins"] as? [Any] else {
            throw DesktopProviderPluginInstallerError.malformedJSON(url.path)
        }
        var plugins: [[String: Any]] = []
        var removed = false
        for value in rawPlugins {
            guard let plugin = value as? [String: Any], let name = plugin["name"] as? String else {
                throw DesktopProviderPluginInstallerError.malformedJSON(url.path)
            }
            if name == Self.pluginName {
                guard !removed,
                      let source = plugin["source"] as? [String: Any],
                      source["source"] as? String == "local",
                      source["path"] as? String == "./plugins/\(Self.pluginName)" else {
                    throw DesktopProviderPluginInstallerError.unownedConflict("\(url.path)#\(Self.pluginName)")
                }
                removed = true
            } else {
                plugins.append(plugin)
            }
        }
        guard removed else { return original }
        root["plugins"] = plugins
        return try jsonData(root)
    }

    func dictionary(_ value: Any?, key: String, at url: URL) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let dictionary = value as? [String: Any] else {
            throw DesktopProviderPluginInstallerError.malformedJSON("\(url.path)#\(key)")
        }
        return dictionary
    }

    func jsonObject(_ data: Data, at url: URL) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DesktopProviderPluginInstallerError.malformedJSON(url.path)
            }
            return object
        } catch let typed as DesktopProviderPluginInstallerError {
            throw typed
        } catch {
            throw DesktopProviderPluginInstallerError.malformedJSON(url.path)
        }
    }

    func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DesktopProviderPluginInstallerError.invalidStagedPackage("invalid generated JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func packageDigest(host: DesktopProviderPluginHost, files: [String: Data]) -> String {
        var canonical = Data("forge.desktop-provider-plugin.v1\0\(host.rawValue)\0".utf8)
        for path in files.keys.sorted() {
            let data = files[path]!
            canonical.append(Data(path.utf8))
            canonical.append(0)
            canonical.append(Data(JSONSupport.sha256Hex(data).utf8))
            canonical.append(0)
        }
        return JSONSupport.sha256Hex(canonical)
    }

    func makeReceipt(
        request: DesktopProviderPluginRequest,
        packageSHA256: String,
        files: [String: Data],
        disposition: DesktopProviderPluginDisposition,
        deploymentVerified: Bool,
        warnings: [DesktopProviderPluginWarning],
        attempts: [DesktopProviderPluginCommandReceipt],
        detail: String,
        installedAt: String? = nil
    ) -> DesktopProviderPluginReceipt {
        let records = files.keys.sorted().prefix(DesktopProviderPluginReceipt.maximumFiles).map { path in
            let data = files[path]!
            return DesktopProviderPluginFileReceipt(
                relativePath: path,
                byteCount: data.count,
                sha256: JSONSupport.sha256Hex(data)
            )
        }
        return DesktopProviderPluginReceipt(
            schemaVersion: DesktopProviderPluginReceipt.schemaVersion,
            host: request.host,
            pluginVersion: request.pluginVersion,
            mcpEnabled: request.includeMCP,
            packageSHA256: packageSHA256,
            installedAt: installedAt ?? iso8601(clock()),
            disposition: disposition,
            deploymentVerified: deploymentVerified,
            warnings: Array(warnings.prefix(4)),
            files: records,
            commandAttempts: Array(attempts.prefix(DesktopProviderPluginReceipt.maximumCommandAttempts)),
            detail: boundedDetail(detail)
        )
    }

    func writeReceipt(_ receipt: DesktopProviderPluginReceipt, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(receipt)
        data.append(0x0A)
        guard data.count <= Self.maximumReceiptBytes else {
            throw DesktopProviderPluginInstallerError.invalidReceipt(url.path)
        }
        try OwnerOnlyAtomicFile.write(data, to: url)
        guard try readReceiptIfPresent(host: receipt.host) == receipt else {
            throw DesktopProviderPluginInstallerError.invalidReceipt(url.path)
        }
    }

    func readReceiptIfPresent(host: DesktopProviderPluginHost) throws -> DesktopProviderPluginReceipt? {
        let url = receiptURL(host: host)
        guard let data = try readExistingRegularFile(url, maximumBytes: Self.maximumReceiptBytes) else { return nil }
        let decoder = JSONDecoder()
        do {
            let receipt = try decoder.decode(DesktopProviderPluginReceipt.self, from: data)
            guard receipt.schemaVersion == DesktopProviderPluginReceipt.schemaVersion,
                  receipt.host == host,
                  receipt.files.count <= DesktopProviderPluginReceipt.maximumFiles,
                  receipt.commandAttempts.count <= DesktopProviderPluginReceipt.maximumCommandAttempts,
                  receipt.warnings.count <= 4,
                  receipt.detail.count <= Self.maximumDetailCharacters,
                  receipt.files.allSatisfy({
                      !$0.relativePath.hasPrefix("/") && !$0.relativePath.contains("..")
                          && $0.byteCount >= 0 && $0.sha256.count == 64
                  }) else {
                throw DesktopProviderPluginInstallerError.invalidReceipt(url.path)
            }
            return receipt
        } catch let typed as DesktopProviderPluginInstallerError {
            throw typed
        } catch {
            throw DesktopProviderPluginInstallerError.invalidReceipt(url.path)
        }
    }

    func receiptURL(host: DesktopProviderPluginHost) -> URL {
        roots.forgeOwnedRoot
            .appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent("\(host.rawValue).json")
    }

    func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func boundedDetail(_ detail: String) -> String {
        String(detail.prefix(Self.maximumDetailCharacters))
    }

    func writePackage(_ files: [String: Data], to root: URL) throws {
        for path in files.keys.sorted() {
            guard safeRelativePath(path) else {
                throw DesktopProviderPluginInstallerError.invalidStagedPackage(path)
            }
            try OwnerOnlyAtomicFile.write(files[path]!, to: root.appendingPathComponent(path))
        }
    }

    func verifyPackage(_ files: [String: Data], at root: URL) throws {
        let actualPaths = try regularRelativeFiles(at: root)
        guard actualPaths == Set(files.keys) else {
            throw DesktopProviderPluginInstallerError.invalidStagedPackage("file set differs")
        }
        for path in files.keys.sorted() {
            let expected = files[path]!
            let actual = try OwnerOnlyAtomicFile.read(
                from: root.appendingPathComponent(path),
                maximumBytes: max(1, expected.count)
            )
            guard actual == expected else {
                throw DesktopProviderPluginInstallerError.invalidStagedPackage("hash mismatch for \(path)")
            }
            if path.hasSuffix(".json") {
                do { _ = try JSONSerialization.jsonObject(with: actual) }
                catch { throw DesktopProviderPluginInstallerError.invalidStagedPackage("malformed \(path)") }
            }
        }
    }

    func packageMatches(_ package: GeneratedPackage) throws -> Bool {
        guard fileManager.fileExists(atPath: package.target.path) else { return false }
        try validateNoSymlinksRecursively(package.target)
        do {
            try verifyPackage(package.files, at: package.target)
            return true
        } catch DesktopProviderPluginInstallerError.invalidStagedPackage {
            return false
        }
    }

    func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    func regularRelativeFiles(at root: URL) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw DesktopProviderPluginInstallerError.invalidStagedPackage("cannot enumerate \(root.path)")
        }
        var paths: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw DesktopProviderPluginInstallerError.symlinkRefused(url.path)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw DesktopProviderPluginInstallerError.invalidStagedPackage("non-regular file \(url.path)")
            }
            let canonicalRoot = root.resolvingSymlinksInPath().path
            let canonicalURL = url.resolvingSymlinksInPath().path
            let prefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
            guard canonicalURL.hasPrefix(prefix) else {
                throw DesktopProviderPluginInstallerError.unsafePath(url.path)
            }
            paths.insert(String(canonicalURL.dropFirst(prefix.count)))
        }
        return paths
    }

    func validateWritableTarget(_ target: URL, under root: URL, finalKind: FinalPathKind) throws {
        let normalizedRoot = root.standardizedFileURL
        let normalizedTarget = target.standardizedFileURL
        let prefix = normalizedRoot.path.hasSuffix("/") ? normalizedRoot.path : normalizedRoot.path + "/"
        guard normalizedTarget.path == normalizedRoot.path || normalizedTarget.path.hasPrefix(prefix) else {
            throw DesktopProviderPluginInstallerError.unsafePath(normalizedTarget.path)
        }
        var current = normalizedRoot
        if fileManager.fileExists(atPath: current.path) { try rejectSymlink(current) }
        let relative = normalizedTarget.path == normalizedRoot.path
            ? ""
            : String(normalizedTarget.path.dropFirst(prefix.count))
        let components = relative.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            guard fileManager.fileExists(atPath: current.path) else { continue }
            try rejectSymlink(current)
            var status = stat()
            guard current.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
                throw DesktopProviderPluginInstallerError.unsafePath(current.path)
            }
            let isFinal = index == components.count - 1
            if !isFinal || finalKind == .directory {
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    throw DesktopProviderPluginInstallerError.unsafePath(current.path)
                }
            } else {
                guard status.st_mode & S_IFMT == S_IFREG else {
                    throw DesktopProviderPluginInstallerError.unsafePath(current.path)
                }
            }
        }
        if finalKind == .directory, fileManager.fileExists(atPath: normalizedTarget.path) {
            try validateNoSymlinksRecursively(normalizedTarget)
        }
    }

    func rejectSymlink(_ url: URL) throws {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            throw DesktopProviderPluginInstallerError.unsafePath(url.path)
        }
        if status.st_mode & S_IFMT == S_IFLNK {
            throw DesktopProviderPluginInstallerError.symlinkRefused(url.path)
        }
    }

    func validateNoSymlinksRecursively(_ root: URL) throws {
        try rejectSymlink(root)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        while let url = enumerator.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw DesktopProviderPluginInstallerError.symlinkRefused(url.path)
            }
        }
    }

    func createOwnerOnlyDirectory(_ url: URL) throws {
        try validateWritableTarget(url, under: roots.userHome.path == "/" ? url : commonAllowedRoot(for: url), finalKind: .directory)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func commonAllowedRoot(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for candidate in [roots.userHome, roots.grokHome, roots.forgeOwnedRoot] {
            let candidatePath = candidate.standardizedFileURL.path
            if path == candidatePath || path.hasPrefix(candidatePath + "/") { return candidate }
        }
        return url.deletingLastPathComponent()
    }

    func isRegularFileWithoutFollowingSymlink(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFREG
    }

    func readExistingRegularFile(_ url: URL, maximumBytes: Int) throws -> Data? {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw DesktopProviderPluginInstallerError.unsafePath(url.path)
        }
        if status.st_mode & S_IFMT == S_IFLNK {
            throw DesktopProviderPluginInstallerError.symlinkRefused(url.path)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw DesktopProviderPluginInstallerError.unsafePath(url.path)
        }
        return try OwnerOnlyAtomicFile.read(from: url, maximumBytes: maximumBytes)
    }

    func assertForgeOwnedPackage(at url: URL, host: DesktopProviderPluginHost) throws {
        try validateNoSymlinksRecursively(url)
        let marker = url.appendingPathComponent(".forge-conductor-owner.json")
        guard let data = try readExistingRegularFile(marker, maximumBytes: 4_096),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["installer"] as? String == Self.installerID,
              object["plugin"] as? String == Self.pluginName,
              object["host"] as? String == host.rawValue,
              object["schema_version"] as? Int == 1 else {
            throw DesktopProviderPluginInstallerError.unownedConflict(url.path)
        }
    }

    func removeOwnedPackageIfPresent(at url: URL, host: DesktopProviderPluginHost) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try assertForgeOwnedPackage(at: url, host: host)
        try fileManager.removeItem(at: url)
    }

    func restoreFile(_ original: Data?, at url: URL) throws {
        if let original {
            try OwnerOnlyAtomicFile.write(original, to: url)
        } else {
            try OwnerOnlyAtomicFile.removeIfExists(at: url)
        }
    }

    func activateHost(
        for request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan
    ) -> HostActivation {
        guard let executable = commandRunner.executable(named: request.host.executableName) else {
            return HostActivation(cliAvailable: false, succeeded: false, attempts: [])
        }
        let commands: [HostActivationCommand]
        switch request.host {
        case .claudeCodeDesktop:
            commands = [
                HostActivationCommand(
                    arguments: ["plugin", "validate", package.target.path],
                    verifiesInventory: false
                ),
                HostActivationCommand(
                    arguments: ["plugin", "marketplace", "add", package.target.path],
                    verifiesInventory: false,
                    acceptedIdempotentPhrases: [
                        "already added",
                        "already exists",
                    ]
                ),
                HostActivationCommand(
                    arguments: [
                        "plugin", "install",
                        "\(Self.pluginName)@\(Self.marketplaceName)", "--scope", "user",
                    ],
                    verifiesInventory: false,
                    acceptedIdempotentPhrases: ["already installed"]
                ),
                HostActivationCommand(
                    arguments: ["plugin", "list", "--json"],
                    verifiesInventory: true
                ),
            ]
        case .codexDesktop:
            let marketplace = configuration.catalogName ?? "personal"
            commands = [
                HostActivationCommand(
                    arguments: ["plugin", "add", "\(Self.pluginName)@\(marketplace)"],
                    verifiesInventory: false,
                    acceptedIdempotentPhrases: [
                        "already added",
                        "already installed",
                    ]
                ),
                HostActivationCommand(
                    arguments: ["plugin", "list", "--json"],
                    verifiesInventory: true
                ),
            ]
        case .grokBuild:
            commands = [
                HostActivationCommand(
                    arguments: ["plugin", "validate", package.target.path],
                    verifiesInventory: false
                ),
                HostActivationCommand(
                    arguments: ["plugin", "enable", Self.pluginName],
                    verifiesInventory: false,
                    acceptedIdempotentPhrases: ["already enabled"]
                ),
                HostActivationCommand(
                    arguments: ["plugin", "list", "--json"],
                    verifiesInventory: true
                ),
            ]
        }

        var attempts: [DesktopProviderPluginCommandReceipt] = []
        for command in commands.prefix(DesktopProviderPluginReceipt.maximumCommandAttempts) {
            do {
                let result = try commandRunner.run(
                    executable: executable,
                    arguments: command.arguments,
                    timeoutSeconds: Self.commandTimeoutSeconds,
                    maximumOutputBytes: Self.maximumCommandOutputBytes
                )
                let truncated = result.stdoutTruncated || result.stderrTruncated
                attempts.append(DesktopProviderPluginCommandReceipt(
                    executable: request.host.executableName,
                    argumentCount: min(command.arguments.count, 16),
                    exitCode: result.exitCode,
                    timedOut: result.timedOut,
                    outputTruncated: truncated
                ))
                guard !result.timedOut, !truncated else {
                    return HostActivation(cliAvailable: true, succeeded: false, attempts: attempts)
                }
                if result.exitCode != 0,
                   !isRecognizedIdempotentActivationOutcome(result, command: command) {
                    return HostActivation(cliAvailable: true, succeeded: false, attempts: attempts)
                }
                if command.verifiesInventory,
                   !inventoryShowsActivePlugin(
                       result.stdout,
                       host: request.host,
                       configuration: configuration
                   ) {
                    return HostActivation(cliAvailable: true, succeeded: false, attempts: attempts)
                }
            } catch {
                attempts.append(DesktopProviderPluginCommandReceipt(
                    executable: request.host.executableName,
                    argumentCount: min(command.arguments.count, 16),
                    exitCode: nil,
                    timedOut: false,
                    outputTruncated: false
                ))
                return HostActivation(cliAvailable: true, succeeded: false, attempts: attempts)
            }
        }
        return HostActivation(cliAvailable: true, succeeded: true, attempts: attempts)
    }

    /// A nonzero mutation is accepted only when the host reports one of the
    /// command-specific, already-present outcomes below and a later inventory
    /// command independently verifies the active plugin. Timeouts and truncated
    /// output never reach this path, so incomplete diagnostics cannot be treated
    /// as idempotent success.
    func isRecognizedIdempotentActivationOutcome(
        _ result: DesktopProviderPluginCommandResult,
        command: HostActivationCommand
    ) -> Bool {
        guard !command.verifiesInventory,
              !command.acceptedIdempotentPhrases.isEmpty else {
            return false
        }
        let output = (result.stdout + "\n" + result.stderr)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !output.isEmpty,
              ![
                "different source", "failed", "error", "invalid", "refusing",
                "not already", "is not already", "isn't already", "wasn't already",
              ]
                .contains(where: output.contains) else {
            return false
        }
        return command.acceptedIdempotentPhrases.contains(where: output.contains)
    }

    func inspectLiveActivation(
        for request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan
    ) -> HostActivation? {
        _ = package
        guard let executable = commandRunner.executable(named: request.host.executableName) else {
            return HostActivation(cliAvailable: false, succeeded: false, attempts: [])
        }
        let arguments = ["plugin", "list", "--json"]
        do {
            let result = try commandRunner.run(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: Self.commandTimeoutSeconds,
                maximumOutputBytes: Self.maximumCommandOutputBytes
            )
            let truncated = result.stdoutTruncated || result.stderrTruncated
            let attempt = DesktopProviderPluginCommandReceipt(
                executable: request.host.executableName,
                argumentCount: arguments.count,
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                outputTruncated: truncated
            )
            let succeeded = result.exitCode == 0 && !result.timedOut && !truncated
                && inventoryShowsActivePlugin(
                    result.stdout,
                    host: request.host,
                    configuration: configuration
                )
            return HostActivation(
                cliAvailable: true,
                succeeded: succeeded,
                attempts: [attempt]
            )
        } catch {
            return HostActivation(
                cliAvailable: true,
                succeeded: false,
                attempts: [DesktopProviderPluginCommandReceipt(
                    executable: request.host.executableName,
                    argumentCount: arguments.count,
                    exitCode: nil,
                    timedOut: false,
                    outputTruncated: false
                )]
            )
        }
    }

    func removeHostRegistration(
        for request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan
    ) -> HostActivation {
        _ = package
        guard let executable = commandRunner.executable(named: request.host.executableName) else {
            return HostActivation(cliAvailable: false, succeeded: false, attempts: [])
        }
        let removalArguments: [String]
        switch request.host {
        case .claudeCodeDesktop:
            removalArguments = [
                "plugin", "uninstall",
                "\(Self.pluginName)@\(Self.marketplaceName)",
                "--scope", "user", "--json",
            ]
        case .codexDesktop:
            let marketplace = configuration.catalogName ?? "personal"
            removalArguments = [
                "plugin", "remove",
                "\(Self.pluginName)@\(marketplace)", "--json",
            ]
        case .grokBuild:
            removalArguments = ["plugin", "disable", Self.pluginName]
        }

        var attempts: [DesktopProviderPluginCommandReceipt] = []
        func execute(_ arguments: [String]) -> DesktopProviderPluginCommandResult? {
            do {
                let result = try commandRunner.run(
                    executable: executable,
                    arguments: arguments,
                    timeoutSeconds: Self.commandTimeoutSeconds,
                    maximumOutputBytes: Self.maximumCommandOutputBytes
                )
                let truncated = result.stdoutTruncated || result.stderrTruncated
                attempts.append(DesktopProviderPluginCommandReceipt(
                    executable: request.host.executableName,
                    argumentCount: min(arguments.count, 16),
                    exitCode: result.exitCode,
                    timedOut: result.timedOut,
                    outputTruncated: truncated
                ))
                return result
            } catch {
                attempts.append(DesktopProviderPluginCommandReceipt(
                    executable: request.host.executableName,
                    argumentCount: min(arguments.count, 16),
                    exitCode: nil,
                    timedOut: false,
                    outputTruncated: false
                ))
                return nil
            }
        }

        func isSuccessful(_ result: DesktopProviderPluginCommandResult) -> Bool {
            result.exitCode == 0
                && !result.timedOut
                && !result.stdoutTruncated
                && !result.stderrTruncated
        }

        let inventoryArguments = ["plugin", "list", "--json"]
        guard let initialInventory = execute(inventoryArguments),
              isSuccessful(initialInventory) else {
            return HostActivation(cliAvailable: true, succeeded: false, attempts: attempts)
        }
        if inventoryConfirmsRemoval(
            initialInventory.stdout,
            host: request.host,
            configuration: configuration
        ) {
            return HostActivation(cliAvailable: true, succeeded: true, attempts: attempts)
        }
        guard inventoryHasMatchingPlugin(
            initialInventory.stdout,
            host: request.host,
            configuration: configuration
        ) else {
            return HostActivation(cliAvailable: true, succeeded: false, attempts: attempts)
        }

        let mutation = execute(removalArguments)
        let hostStateChanged = mutation.map(isSuccessful) ?? false
        guard let finalInventory = execute(inventoryArguments),
              isSuccessful(finalInventory),
              inventoryConfirmsRemoval(
                  finalInventory.stdout,
                  host: request.host,
                  configuration: configuration
              ) else {
            return HostActivation(
                cliAvailable: true,
                succeeded: false,
                attempts: attempts,
                hostStateChanged: hostStateChanged
            )
        }
        return HostActivation(
            cliAvailable: true,
            succeeded: true,
            attempts: attempts,
            hostStateChanged: hostStateChanged
        )
    }

    func inventoryShowsActivePlugin(
        _ stdout: String,
        host: DesktopProviderPluginHost,
        configuration: ConfigurationPlan
    ) -> Bool {
        guard let entries = pluginInventoryEntries(stdout) else { return false }
        return entries.prefix(1_024).contains { entry in
            guard inventoryEntry(
                entry,
                matches: host,
                configuration: configuration
            ), entry["enabled"] as? Bool == true,
            inventoryDiagnosticsAreClean(entry) else { return false }
            return entry["installed"] as? Bool != false
        }
    }

    func inventoryHasMatchingPlugin(
        _ stdout: String,
        host: DesktopProviderPluginHost,
        configuration: ConfigurationPlan
    ) -> Bool {
        guard let entries = pluginInventoryEntries(stdout) else { return false }
        return entries.prefix(1_024).contains {
            inventoryEntry($0, matches: host, configuration: configuration)
        }
    }

    func inventoryConfirmsRemoval(
        _ stdout: String,
        host: DesktopProviderPluginHost,
        configuration: ConfigurationPlan
    ) -> Bool {
        guard let entries = pluginInventoryEntries(stdout) else { return false }
        let matching = entries.prefix(1_024).filter {
            inventoryEntry($0, matches: host, configuration: configuration)
        }
        switch host {
        case .claudeCodeDesktop, .codexDesktop:
            return matching.isEmpty
        case .grokBuild:
            return matching.allSatisfy { entry in
                entry["installed"] as? Bool == false
                    || entry["enabled"] as? Bool == false
            }
        }
    }

    func pluginInventoryEntries(_ stdout: String) -> [[String: Any]]? {
        guard stdout.utf8.count <= Self.maximumCommandOutputBytes,
              let data = stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let array = root as? [[String: Any]] { return array }
        if let object = root as? [String: Any],
           let installed = object["installed"] as? [[String: Any]] {
            return installed
        }
        if let object = root as? [String: Any],
           let plugins = object["plugins"] as? [[String: Any]] {
            return plugins
        }
        return nil
    }

    func inventoryEntry(
        _ entry: [String: Any],
        matches host: DesktopProviderPluginHost,
        configuration: ConfigurationPlan
    ) -> Bool {
        switch host {
        case .claudeCodeDesktop:
            let expectedID = "\(Self.pluginName)@\(Self.marketplaceName)"
            return entry["pluginId"] as? String == expectedID
                || entry["id"] as? String == expectedID
                || entry["name"] as? String == expectedID
                || (entry["name"] as? String == Self.pluginName
                    && entry["marketplaceName"] as? String == Self.marketplaceName)
        case .codexDesktop:
            let marketplace = configuration.catalogName ?? "personal"
            let expectedID = "\(Self.pluginName)@\(marketplace)"
            return entry["pluginId"] as? String == expectedID
                || (entry["name"] as? String == Self.pluginName
                    && entry["marketplaceName"] as? String == marketplace)
        case .grokBuild:
            return entry["name"] as? String == Self.pluginName
                || entry["pluginId"] as? String == Self.pluginName
                || entry["id"] as? String == Self.pluginName
        }
    }

    func inventoryDiagnosticsAreClean(_ entry: [String: Any]) -> Bool {
        for key in ["errors", "notes"] {
            guard let value = entry[key] else { continue }
            guard let diagnostics = value as? [String], diagnostics.isEmpty else {
                return false
            }
        }
        return true
    }

    func finalizeActivation(
        request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan,
        packageSHA256: String,
        receiptURL: URL,
        installedAt: String? = nil
    ) throws -> DesktopProviderPluginStatus {
        let activation = activateHost(for: request, package: package, configuration: configuration)
        let disposition: DesktopProviderPluginDisposition = activation.succeeded
            ? .installed
            : .awaitingUserAction
        let detail = activationDetail(host: request.host, activation: activation)
        let finalReceipt = makeReceipt(
            request: request,
            packageSHA256: packageSHA256,
            files: package.files,
            disposition: disposition,
            deploymentVerified: activation.succeeded,
            warnings: warnings(for: request.host),
            attempts: activation.attempts,
            detail: detail,
            installedAt: installedAt
        )
        // A provisional or prior durable receipt already exists. If this refinement
        // fails, package ownership remains recoverable from that earlier receipt.
        try writeReceipt(finalReceipt, to: receiptURL)
        return makeStatus(
            request: request,
            package: package,
            configuration: configuration,
            disposition: disposition,
            receipt: finalReceipt,
            detail: detail
        )
    }

    func activationDetail(host: DesktopProviderPluginHost, activation: HostActivation) -> String {
        if !activation.cliAvailable {
            switch host {
            case .claudeCodeDesktop:
                return "Plugin files and Claude user settings are installed. Claude's CLI was not found; open Claude Desktop, reload plugins, and review the plugin permissions."
            case .codexDesktop:
                return "Plugin files and the Codex marketplace entry are installed. Codex's CLI was not found; restart the desktop app and review hook trust."
            case .grokBuild:
                return "The Grok plugin is installed but Grok's CLI was not found. Enable forge-conductor from Grok's extensions view."
            }
        }
        if !activation.succeeded {
            return "Plugin files were installed, but bounded host activation did not complete. Finish activation in the host's extensions interface."
        }
        switch host {
        case .claudeCodeDesktop:
            return "Claude accepted the plugin. Start a new desktop session or reload plugins, then review permission prompts normally."
        case .codexDesktop:
            return "Codex accepted the plugin. Restart the desktop app or start a new task, then review hook trust normally."
        case .grokBuild:
            return "Grok validated and enabled the Forge Conductor plugin."
        }
    }

    func warnings(for host: DesktopProviderPluginHost) -> [DesktopProviderPluginWarning] {
        switch host {
        case .claudeCodeDesktop, .codexDesktop: [.hookTrustReviewRequired]
        case .grokBuild: []
        }
    }

    func makeStatus(
        request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan,
        disposition: DesktopProviderPluginDisposition,
        receipt: DesktopProviderPluginReceipt?,
        detail: String,
        deploymentVerifiedOverride: Bool? = nil
    ) -> DesktopProviderPluginStatus {
        let packageVerified = (try? packageMatches(package)) == true
        let configurationVerified = configurationMatches(configuration)
        return DesktopProviderPluginStatus(
            host: request.host,
            disposition: disposition,
            packagePath: package.target.path,
            configurationPath: configuration.url?.path,
            packageVerified: packageVerified,
            configurationVerified: configurationVerified,
            deploymentVerified: packageVerified && configurationVerified
                && receipt?.deploymentVerified == true
                && deploymentVerifiedOverride != false,
            commandLineHostAvailable: commandRunner.executable(named: request.host.executableName) != nil,
            mcpEnabled: request.includeMCP,
            receipt: receipt,
            warnings: receipt?.warnings ?? warnings(for: request.host),
            detail: boundedDetail(detail)
        )
    }

    func removedStatus(
        request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan
    ) -> DesktopProviderPluginStatus {
        DesktopProviderPluginStatus(
            host: request.host,
            disposition: .removed,
            packagePath: package.target.path,
            configurationPath: configuration.url?.path,
            packageVerified: false,
            configurationVerified: configurationMatches(configuration),
            deploymentVerified: true,
            commandLineHostAvailable: commandRunner.executable(named: request.host.executableName) != nil,
            mcpEnabled: false,
            receipt: nil,
            warnings: [],
            detail: "Forge Conductor's owned plugin artifacts and host registration were removed."
        )
    }

    func awaitingRemovalStatus(
        request: DesktopProviderPluginRequest,
        package: GeneratedPackage,
        configuration: ConfigurationPlan,
        receipt: DesktopProviderPluginReceipt?,
        removal: HostActivation
    ) -> DesktopProviderPluginStatus {
        let detail = removal.cliAvailable
            ? "Forge could not verify that the host stopped loading this plugin. Remove or disable Forge Conductor in the host, then retry removal. No Forge-owned files were deleted."
            : "The host CLI used for installation is unavailable. Restore or update the host CLI, remove or disable Forge Conductor there, then retry removal so Forge can verify the live inventory. No Forge-owned files were deleted."
        return DesktopProviderPluginStatus(
            host: request.host,
            disposition: .awaitingUserAction,
            packagePath: package.target.path,
            configurationPath: configuration.url?.path,
            packageVerified: (try? packageMatches(package)) == true,
            configurationVerified: configuration.originalData == nil
                || (configuration.url.flatMap {
                    try? readExistingRegularFile($0, maximumBytes: Self.maximumConfigurationBytes)
                }) == configuration.originalData,
            deploymentVerified: false,
            commandLineHostAvailable: removal.cliAvailable,
            mcpEnabled: request.includeMCP,
            receipt: receipt,
            warnings: receipt?.warnings ?? warnings(for: request.host),
            detail: boundedDetail(detail)
        )
    }

    func configurationMatches(_ configuration: ConfigurationPlan) -> Bool {
        guard let url = configuration.url, let expected = configuration.updatedData else { return true }
        return (try? readExistingRegularFile(url, maximumBytes: Self.maximumConfigurationBytes)) == expected
    }
}
