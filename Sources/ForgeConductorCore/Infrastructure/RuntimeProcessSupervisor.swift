// RuntimeProcessSupervisor.swift
// POSIX process-group launch, concurrent pipe draining, and bounded artifact spill.

import CryptoKit
import Darwin
import Foundation
import ForgeFilesystemProtocol
import MachO
import Security

struct RuntimeProcessPlan: Sendable {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]
    let writableRoots: [URL]

    init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        writableRoots: [URL] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.writableRoots = writableRoots
    }
}

/// Canonicalizes native paths for durable identity, audit, and replay checks.
/// It deliberately grants no authority: model subprocesses inherit the host
/// process's native macOS access, including the exact Full Disk Access state.
enum RuntimePathCanonicalizer {
    /// Foundation intentionally preserves macOS convenience aliases such as
    /// `/var`, while durable identity checks must use the physical
    /// `/private/var` vnode path. `realpath(3)` keeps execution and audit records
    /// in the same namespace.
    static func canonicalExistingURL(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if Darwin.realpath(url.path, &buffer) != nil {
            // Do not call standardizedFileURL here: Foundation rewrites the
            // physical `/private/var` path back to the `/var` convenience alias.
            return URL(fileURLWithPath: String(
                decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            ))
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func canonicalURL(_ url: URL) -> URL {
        var existing = url
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = canonicalExistingURL(existing)
        for component in suffix {
            result.appendPathComponent(component)
        }
        return result
    }

}

/// Installs the small native launcher into service-owned storage before any job
/// is accepted. Request-controlled roots are never used as an executable source,
/// and every launch rechecks that the installed copy is outside all job-writable
/// paths before it runs native request-controlled code.
enum RuntimeLaunchGate {
    static let executableName = "forge-runtime-launcher"
    static let productIdentifier = ForgeFilesystemProtocolConstants.runtimeLauncherIdentifier
    static let developmentTestBundleIdentifier = "com.forge-conductor.tests"
    static let developmentTeamIdentifier =
        ForgeFilesystemProtocolConstants.developmentTeamIdentifier
    static let distributionTeamIdentifier =
        ForgeFilesystemProtocolConstants.productionTeamIdentifier
    static let approvedProductTeamIdentifiers: Set<String> = [
        developmentTeamIdentifier,
        distributionTeamIdentifier,
    ]
    static let inheritedDescriptor: Int32 = 3
    static let releaseByte: UInt8 = 0xA5
    static let maximumExecutableBytes = 8 * 1_024 * 1_024

    static func requiredProductCodeSigningRequirement(
        identifier: String,
        teamIdentifier: String
    ) -> String? {
        ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }

    /// The Xcode unit-test bundle is not a shipping product role. It receives
    /// one narrow local-development exception so a development-signed test host
    /// can exercise the adjacent, production-identified runtime launcher.
    static func requiredDevelopmentTestCodeSigningRequirement(
        identifier: String,
        teamIdentifier: String
    ) -> String? {
        guard identifier == developmentTestBundleIdentifier,
              teamIdentifier == developmentTeamIdentifier else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
    }

    private static func requiredCodeSigningRequirement(
        identifier: String,
        teamIdentifier: String
    ) -> String? {
        requiredProductCodeSigningRequirement(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        ) ?? requiredDevelopmentTestCodeSigningRequirement(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }

    static var isAvailable: Bool {
        (try? sourceExecutableURL()) != nil
    }

    static func install(
        serviceRoot: URL,
        sourceExecutable: URL? = nil
    ) throws -> URL {
        let source = try sourceExecutable ?? sourceExecutableURL()
        let validatedSourceIdentity: CodeIdentity?
        if sourceExecutable == nil {
            validatedSourceIdentity = try validateProductIdentity(source)
        } else {
            validatedSourceIdentity = nil
        }
        let data = try readTrustedExecutable(source)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let canonicalServiceRoot = RuntimePathCanonicalizer.canonicalExistingURL(serviceRoot)
        let support = canonicalServiceRoot.appendingPathComponent(
            ".runtime-support",
            isDirectory: true
        )
        try ensurePrivateDirectory(support)
        let destination = support.appendingPathComponent("\(executableName)-\(digest)")
        try installAtomically(data, at: destination)
        guard try readTrustedExecutable(destination) == data else {
            throw RuntimeJobError.storageFailure("installed runtime launch gate failed verification")
        }
        if let validatedSourceIdentity {
            try validateInstalledIdentity(
                destination,
                matching: validatedSourceIdentity
            )
        }
        return RuntimePathCanonicalizer.canonicalExistingURL(destination)
    }

    static func validate(_ launcher: URL, outside writableRoots: [URL]) throws {
        let canonicalLauncher = RuntimePathCanonicalizer.canonicalExistingURL(launcher)
        let data = try readTrustedExecutable(canonicalLauncher)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard canonicalLauncher.lastPathComponent == "\(executableName)-\(digest)" else {
            throw RuntimeJobError.storageFailure("installed runtime launch gate digest does not match")
        }
        for root in writableRoots.map(RuntimePathCanonicalizer.canonicalExistingURL) {
            if contains(canonicalLauncher, root: root) {
                throw RuntimeJobError.invalidRequest(
                    "runtime launch gate overlaps a job-writable authorization root"
                )
            }
        }
    }

    private static func sourceExecutableURL() throws -> URL {
        let isApplication = Bundle.main.bundleURL.pathExtension == "app"
        var candidates: [URL] = []
        if isApplication, let appExecutable = Bundle.main.executableURL {
            let contents = appExecutable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(
                contents.appendingPathComponent("Helpers", isDirectory: true)
                    .appendingPathComponent(executableName)
            )
        } else {
            if let executable = Bundle.main.executableURL {
                candidates.append(
                    executable.deletingLastPathComponent()
                        .appendingPathComponent(executableName)
                )
            }
            if Bundle.main.bundleURL.pathExtension == "xctest" {
                candidates.append(
                    Bundle.main.bundleURL.deletingLastPathComponent()
                        .appendingPathComponent(executableName)
                )
            }
            for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
                candidates.append(
                    bundle.bundleURL.deletingLastPathComponent()
                        .appendingPathComponent(executableName)
                )
            }
            if let command = CommandLine.arguments.first, !command.isEmpty {
                appendDevelopmentCandidates(
                    executable: URL(fileURLWithPath: command),
                    to: &candidates
                )
            }
            if let executable = currentProcessExecutableURL() {
                appendDevelopmentCandidates(executable: executable, to: &candidates)
            }
        }

        var visited: Set<String> = []
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard visited.insert(standardized.path).inserted else { continue }
            if (try? readTrustedExecutable(standardized)) != nil {
                return RuntimePathCanonicalizer.canonicalExistingURL(standardized)
            }
        }
        throw RuntimeJobError.executableUnavailable(executableName)
    }

    private static func appendDevelopmentCandidates(
        executable: URL,
        to candidates: inout [URL]
    ) {
        candidates.append(
            executable.deletingLastPathComponent()
                .appendingPathComponent(executableName)
        )
        let possibleBundle = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if possibleBundle.pathExtension == "xctest" {
            candidates.append(
                possibleBundle.deletingLastPathComponent()
                    .appendingPathComponent(executableName)
            )
        }
    }

    private static func currentProcessExecutableURL() -> URL? {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        guard capacity > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &capacity)
        }
        guard result == 0 else { return nil }
        return URL(fileURLWithPath: String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        ))
    }

    struct CodeIdentity: Equatable {
        let identifier: String
        let teamIdentifier: String?
        let flags: SecCodeSignatureFlags
        let uniqueHash: Data
    }

    @discardableResult
    static func validateProductIdentity(_ source: URL) throws -> CodeIdentity {
        let sourceIdentity = try codeIdentity(at: source, checkNestedCode: false)
        let currentExecutable = currentProductExecutableURL()
        guard let currentExecutable else {
            throw RuntimeJobError.storageFailure(
                "runtime launch gate could not bind to the current product identity"
            )
        }
        let currentIdentity: CodeIdentity
        do {
            currentIdentity = try codeIdentity(
                at: currentExecutable,
                checkNestedCode: false
            )
        } catch {
            guard isLoadedTestExecutable(currentExecutable) else { throw error }
            let packageTestIdentity = try codeIdentity(
                at: currentExecutable,
                checkNestedCode: false,
                requireValidity: false
            )
            guard isSwiftPackageTestIdentity(packageTestIdentity.identifier),
                  packageTestIdentity.flags.contains(.adhoc),
                  packageTestIdentity.teamIdentifier == nil else { throw error }
            currentIdentity = packageTestIdentity
        }

        if Bundle.main.bundleURL.pathExtension == "app" {
            let appBundle = Bundle.main.bundleURL
            let appIdentity = try codeIdentity(
                at: appBundle,
                checkNestedCode: true
            )
            try validateApplicationProductIdentity(
                source: source,
                sourceIdentity: sourceIdentity,
                currentExecutable: currentExecutable,
                currentIdentity: currentIdentity,
                appBundle: appBundle,
                appIdentity: appIdentity
            )
            return sourceIdentity
        }

        if sourceIdentity.identifier == productIdentifier {
            try validateCommandLineProductIdentity(
                source: source,
                sourceIdentity: sourceIdentity,
                currentExecutable: currentExecutable,
                currentIdentity: currentIdentity
            )
            return sourceIdentity
        }

        let helperIsSwiftPackageProduct = sourceIdentity.identifier == executableName
            || sourceIdentity.identifier.hasPrefix(executableName + "-")
        let currentIsSwiftPackageProduct = ["forge-conductor", "forge-conductor-app"]
            .contains { name in
                currentIdentity.identifier == name
                    || currentIdentity.identifier.hasPrefix(name + "-")
            }
        let currentIsPackageTest = isSwiftPackageTestIdentity(currentIdentity.identifier)
        guard sourceIdentity.flags.contains(.adhoc),
              sourceIdentity.teamIdentifier == nil,
              helperIsSwiftPackageProduct,
              currentIdentity.flags.contains(.adhoc),
              currentIdentity.teamIdentifier == nil,
              currentIsSwiftPackageProduct || currentIsPackageTest,
              isExpectedDevelopmentPair(
                source: source,
                currentExecutable: currentExecutable
              ) else {
            throw RuntimeJobError.storageFailure(
                "runtime launch gate has an unexpected development signature identity"
            )
        }
        return sourceIdentity
    }

    /// SwiftPM has used both the legacy aggregate-test identifier and the
    /// package-and-target identifier for the same ad-hoc XCTest product.
    static func isSwiftPackageTestIdentity(_ identifier: String) -> Bool {
        identifier == "ForgeConductorPackageTests"
            || identifier == "forge-conductor.ForgeConductorTests"
    }

    /// Binds the runtime launcher to the exact adjacent CLI product. Development
    /// and distribution signing are both valid product modes, but the launcher
    /// and CLI must carry the same approved team identifier. This cannot depend
    /// on `DEBUG`: a Release binary may be development-signed for local testing.
    static func validateCommandLineProductIdentity(
        source: URL,
        sourceIdentity: CodeIdentity,
        currentExecutable: URL,
        currentIdentity: CodeIdentity
    ) throws {
        let currentIsCommandLineProduct = currentIdentity.identifier
            == "com.forge-conductor.cli"
        let currentIsDevelopmentTest = currentIdentity.identifier
            == developmentTestBundleIdentifier
        guard sourceIdentity.identifier == productIdentifier,
              currentIsCommandLineProduct || currentIsDevelopmentTest,
              isExpectedDevelopmentPair(
                source: source,
                currentExecutable: currentExecutable
              ) else {
            throw RuntimeJobError.storageFailure(
                "runtime launch gate does not match the command-line product"
            )
        }
        if currentIsDevelopmentTest {
            guard sourceIdentity.teamIdentifier == developmentTeamIdentifier,
                  currentIdentity.teamIdentifier == developmentTeamIdentifier else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate does not match the development test product"
                )
            }
            return
        }
        if let sourceTeam = sourceIdentity.teamIdentifier,
           approvedProductTeamIdentifiers.contains(sourceTeam),
           currentIdentity.teamIdentifier == sourceTeam {
            return
        }
        let sourceIsExpectedDevelopmentSignature = sourceIdentity.teamIdentifier
            .map(approvedProductTeamIdentifiers.contains) ?? sourceIdentity.flags.contains(.adhoc)
        guard sourceIsExpectedDevelopmentSignature,
              currentIdentity.teamIdentifier == nil,
              currentIdentity.flags.contains(.adhoc) else {
            throw RuntimeJobError.storageFailure(
                "runtime launch gate does not match the command-line product"
            )
        }
    }

    /// Binds an application helper to the exact enclosing product. Team-signed
    /// products retain the production policy; the only development exception
    /// is the project-local, ad-hoc SwiftPM bundle assembled by the run script.
    static func validateApplicationProductIdentity(
        source: URL,
        sourceIdentity: CodeIdentity,
        currentExecutable: URL,
        currentIdentity: CodeIdentity,
        appBundle: URL,
        appIdentity: CodeIdentity
    ) throws {
        let expectedSource = appBundle
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(executableName)
        let expectedExecutable = appBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(ManagerInstaller.appDisplayName)
        guard RuntimePathCanonicalizer.canonicalExistingURL(source)
                == RuntimePathCanonicalizer.canonicalExistingURL(expectedSource),
              RuntimePathCanonicalizer.canonicalExistingURL(currentExecutable)
                == RuntimePathCanonicalizer.canonicalExistingURL(expectedExecutable),
              appIdentity.identifier == ManagerInstaller.bundleIdentifier,
              currentIdentity.identifier == ManagerInstaller.bundleIdentifier,
              sourceIdentity.identifier == productIdentifier else {
            throw RuntimeJobError.storageFailure(
                "bundled runtime launch gate does not match the enclosing signed product"
            )
        }

        if let appTeam = appIdentity.teamIdentifier,
           approvedProductTeamIdentifiers.contains(appTeam),
           sourceIdentity.teamIdentifier == appTeam,
           currentIdentity.teamIdentifier == appTeam {
            return
        }

        let isProjectLocalDevelopmentPair =
            appIdentity.teamIdentifier == nil
            && currentIdentity.teamIdentifier == nil
            && sourceIdentity.teamIdentifier == nil
            && appIdentity.flags.contains(.adhoc)
            && currentIdentity.flags.contains(.adhoc)
            && sourceIdentity.flags.contains(.adhoc)
            && appIdentity.uniqueHash == currentIdentity.uniqueHash
        guard isProjectLocalDevelopmentPair else {
            throw RuntimeJobError.storageFailure(
                "bundled runtime launch gate does not match the enclosing signed product"
            )
        }
    }

    private static func currentProductExecutableURL() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.executableURL
        }
        let testBundles = [Bundle.main] + Bundle.allBundles
        if let testExecutable = testBundles.first(where: {
            $0.bundleURL.pathExtension == "xctest"
        })?.executableURL {
            return testExecutable
        }
        return currentProcessExecutableURL() ?? Bundle.main.executableURL
    }

    private static func isLoadedTestExecutable(_ executable: URL) -> Bool {
        let canonicalExecutable = RuntimePathCanonicalizer.canonicalExistingURL(executable)
        return ([Bundle.main] + Bundle.allBundles).contains { bundle in
            guard bundle.bundleURL.pathExtension == "xctest",
                  let testExecutable = bundle.executableURL else { return false }
            return RuntimePathCanonicalizer.canonicalExistingURL(testExecutable)
                == canonicalExecutable
        }
    }

    private static func isExpectedDevelopmentPair(
        source: URL,
        currentExecutable: URL
    ) -> Bool {
        let canonicalSource = RuntimePathCanonicalizer.canonicalExistingURL(source)
        let canonicalExecutable = RuntimePathCanonicalizer.canonicalExistingURL(
            currentExecutable
        )
        let loadedTestBundles = [Bundle.main] + Bundle.allBundles
        if let testBundle = loadedTestBundles.first(where: { bundle in
            guard bundle.bundleURL.pathExtension == "xctest",
                  let executable = bundle.executableURL else { return false }
            return RuntimePathCanonicalizer.canonicalExistingURL(executable)
                == canonicalExecutable
        }) {
            let expected = testBundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(executableName)
            return RuntimePathCanonicalizer.canonicalExistingURL(expected) == canonicalSource
        }
        let expected = canonicalExecutable.deletingLastPathComponent()
            .appendingPathComponent(executableName)
        return RuntimePathCanonicalizer.canonicalExistingURL(expected) == canonicalSource
    }

    private static func validateInstalledIdentity(
        _ installed: URL,
        matching expectedIdentity: CodeIdentity
    ) throws {
        guard try codeIdentity(at: installed, checkNestedCode: false)
                == expectedIdentity else {
            throw RuntimeJobError.storageFailure(
                "installed runtime launch gate signature identity changed during staging"
            )
        }
    }

    private static func codeIdentity(
        at url: URL,
        checkNestedCode: Bool,
        requireValidity: Bool = true
    ) throws -> CodeIdentity {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw RuntimeJobError.storageFailure(
                "runtime launch gate signature reference failed with status \(createStatus)"
            )
        }
        var flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
        )
        flags.formUnion(.noNetworkAccess)
        if checkNestedCode {
            flags.formUnion(SecCSFlags(rawValue: kSecCSCheckNestedCode))
        }
        if requireValidity {
            let validationStatus = SecStaticCodeCheckValidity(staticCode, flags, nil)
            guard validationStatus == errSecSuccess else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate signature validation failed with status \(validationStatus)"
                )
            }
        }
        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any],
              let identifier = information[kSecCodeInfoIdentifier] as? String,
              !identifier.isEmpty,
              let flagsNumber = information[kSecCodeInfoFlags] as? NSNumber,
              let uniqueHash = information[kSecCodeInfoUnique] as? Data,
              !uniqueHash.isEmpty else {
            throw RuntimeJobError.storageFailure(
                "runtime launch gate signature metadata failed with status \(informationStatus)"
            )
        }
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
        if let teamIdentifier {
            guard let requirementText = requiredCodeSigningRequirement(
                identifier: identifier,
                teamIdentifier: teamIdentifier
            ) else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate has an unsupported product signing identity"
                )
            }
            var requirement: SecRequirement?
            let requirementStatus = SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(rawValue: 0),
                &requirement
            )
            guard requirementStatus == errSecSuccess, let requirement else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate signing requirement failed to compile with status "
                        + "\(requirementStatus)"
                )
            }
            let validationStatus = SecStaticCodeCheckValidity(
                staticCode,
                flags,
                requirement
            )
            guard validationStatus == errSecSuccess else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate product signing requirement failed with status "
                        + "\(validationStatus)"
                )
            }
        }
        return CodeIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            flags: SecCodeSignatureFlags(rawValue: flagsNumber.uint32Value),
            uniqueHash: uniqueHash
        )
    }

    private static func readTrustedExecutable(_ candidate: URL) throws -> Data {
        let descriptor = Darwin.open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RuntimeJobError.executableUnavailable(executableName)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0 || metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              metadata.st_size > 0,
              metadata.st_size <= off_t(maximumExecutableBytes) else {
            throw RuntimeJobError.storageFailure("runtime launch gate metadata is not trusted")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < Int(metadata.st_size) {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            guard count == 0 else {
                throw RuntimeJobError.storageFailure("runtime launch gate could not be read")
            }
            break
        }
        guard data.count == Int(metadata.st_size) else {
            throw RuntimeJobError.storageFailure("runtime launch gate changed while being read")
        }
        return data
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        if Darwin.mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
            throw RuntimeJobError.storageFailure("runtime support directory could not be created")
        }
        var metadata = stat()
        guard Darwin.lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw RuntimeJobError.storageFailure("runtime support directory is not private")
        }
        _ = Darwin.chmod(directory.path, S_IRWXU)
    }

    private static func installAtomically(_ data: Data, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".launcher-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RuntimeJobError.storageFailure("runtime launch gate staging file could not be created")
        }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { _ = Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw RuntimeJobError.storageFailure("runtime launch gate staging write failed")
            }
        }
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, S_IRUSR | S_IXUSR) == 0 else {
            throw RuntimeJobError.storageFailure("runtime launch gate staging sync failed")
        }
        if Darwin.link(temporary.path, destination.path) != 0, errno != EEXIST {
            throw RuntimeJobError.storageFailure("runtime launch gate could not be installed atomically")
        }
        _ = Darwin.unlink(temporary.path)
        shouldRemove = false
    }

    private static func contains(_ child: URL, root: URL) -> Bool {
        let childPath = child.path
        let rootPath = root.path
        return childPath == rootPath
            || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

struct RuntimeProcessExit: Sendable, Equatable {
    let rawWaitStatus: Int32
    let exitCode: Int32
    let terminatingSignal: Int32?
}

struct RuntimeProcessStartIdentity: Sendable, Equatable, Hashable {
    let seconds: Int64
    let microseconds: Int64

    init?(seconds: Int64, microseconds: Int64) {
        guard seconds > 0, (0..<1_000_000).contains(microseconds) else { return nil }
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

struct RuntimePersistedProcessIdentity: Sendable, Equatable {
    let processIdentifier: Int32
    let processGroupIdentifier: Int32
    let startIdentity: RuntimeProcessStartIdentity

    var isValidProcessGroupLeader: Bool {
        processIdentifier > 1
            && processGroupIdentifier == processIdentifier
    }
}

struct RuntimeObservedProcessIdentity: Sendable, Equatable, Hashable {
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let processGroupIdentifier: Int32
    let startIdentity: RuntimeProcessStartIdentity
}

struct RuntimeChildProcessList: Sendable, Equatable {
    let processIdentifiers: [Int32]
    let complete: Bool
}

protocol RuntimeProcessTreeReading: Sendable {
    func identity(processIdentifier: Int32) -> RuntimeObservedProcessIdentity?
    func children(
        of processIdentifier: Int32,
        maximumCount: Int
    ) -> RuntimeChildProcessList
}

protocol RuntimeProcessSignaling: Sendable {
    /// Returns zero on success, `ESRCH` when the process is already absent, or
    /// the captured errno value for any other failure.
    func signal(processIdentifier: Int32, signal: Int32) -> Int32
}

struct DarwinRuntimeProcessSignaler: RuntimeProcessSignaling, Sendable {
    func signal(processIdentifier: Int32, signal: Int32) -> Int32 {
        guard Darwin.kill(processIdentifier, signal) != 0 else { return 0 }
        return errno
    }
}

struct DarwinRuntimeProcessTreeReader: RuntimeProcessTreeReading, Sendable {
    func identity(processIdentifier: Int32) -> RuntimeObservedProcessIdentity? {
        RuntimeProcessIdentityReader.observedIdentity(processIdentifier: processIdentifier)
    }

    func children(
        of processIdentifier: Int32,
        maximumCount: Int
    ) -> RuntimeChildProcessList {
        guard processIdentifier > 1, maximumCount > 0 else {
            return RuntimeChildProcessList(processIdentifiers: [], complete: maximumCount > 0)
        }
        var identifiers = [pid_t](repeating: 0, count: maximumCount)
        errno = 0
        let returned = identifiers.withUnsafeMutableBytes { buffer in
            proc_listchildpids(
                processIdentifier,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard returned >= 0 else {
            return RuntimeChildProcessList(
                processIdentifiers: [],
                complete: errno == ESRCH
            )
        }
        let count = min(Int(returned), identifiers.count)
        return RuntimeChildProcessList(
            processIdentifiers: identifiers.prefix(count).filter { $0 > 1 },
            // A completely filled buffer is conservatively treated as truncated.
            // Callers request one entry beyond their remaining bounded capacity.
            complete: count < identifiers.count
        )
    }
}

enum RuntimeDescendantObservation: Sendable, Equatable {
    case withinLimit(observed: Int)
    case limitExceeded(observed: Int, trackingCapacityExceeded: Bool)

    var exceededLimit: Bool {
        if case .limitExceeded = self { return true }
        return false
    }
}

/// Best-effort ownership extension for native descendants that leave the launch
/// process group with `setsid(2)` or `setpgid(2)`. Before each signal, the PID's
/// libproc start identity is checked against the captured identity, and storage
/// is hard-bounded. macOS has no pidfd-style atomic identity-and-signal primitive,
/// so PID reuse between that check and `kill(2)` remains a narrow native-host risk.
///
/// macOS exposes no public cgroup/job-object/subreaper primitive. An unrestricted
/// child can fork, reparent, and exit between two libproc snapshots; such a child
/// is outside what an ordinary same-user app can prove it owns without Endpoint
/// Security or a sandbox. This tracker closes the observable/background-process
/// gap without changing the product's full-native-shell trust boundary.
final class RuntimeDescendantTracker: @unchecked Sendable {
    static let maximumTrackedDescendants = 1_024

    private let rootIdentity: RuntimeObservedProcessIdentity
    private let maximumDescendants: Int
    private let reader: any RuntimeProcessTreeReading
    private let signaler: any RuntimeProcessSignaling
    private let lock = NSLock()
    private var tracked: [Int32: RuntimeObservedProcessIdentity] = [:]
    private var trackingCapacityExceeded = false

    init(
        rootIdentity: RuntimeObservedProcessIdentity,
        maximumDescendants: Int,
        reader: any RuntimeProcessTreeReading = DarwinRuntimeProcessTreeReader(),
        signaler: any RuntimeProcessSignaling = DarwinRuntimeProcessSignaler()
    ) {
        self.rootIdentity = rootIdentity
        self.maximumDescendants = max(1, maximumDescendants)
        self.reader = reader
        self.signaler = signaler
    }

    func observe() -> RuntimeDescendantObservation {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        if trackingCapacityExceeded || tracked.count > maximumDescendants {
            return .limitExceeded(
                observed: tracked.count,
                trackingCapacityExceeded: trackingCapacityExceeded
            )
        }
        return .withinLimit(observed: tracked.count)
    }

    @discardableResult
    func signalTracked(_ signal: Int32, includeRoot: Bool) -> Bool {
        lock.lock()
        refreshLocked()
        var identities = Array(tracked.values)
        if includeRoot { identities.append(rootIdentity) }
        lock.unlock()

        var allSignalsConfirmed = true
        for identity in identities {
            guard let current = reader.identity(
                processIdentifier: identity.processIdentifier
            ), current.startIdentity == identity.startIdentity else {
                continue
            }
            let result = signaler.signal(
                processIdentifier: identity.processIdentifier,
                signal: signal
            )
            if result != 0, result != ESRCH { allSignalsConfirmed = false }
        }
        return allSignalsConfirmed
    }

    func hasLiveTrackedProcesses(includeRoot: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        // Capacity overflow is durable uncertainty, not a live process identity.
        // Keeping it in this liveness predicate makes cleanup mathematically
        // impossible after every recorded identity exits. `observe()` continues
        // to report the sticky overflow so the job terminates as an explicit
        // failure without claiming unobserved descendants were absent.
        if !tracked.isEmpty { return true }
        guard includeRoot else { return false }
        return identityStillMatches(rootIdentity)
    }

    private func refreshLocked() {
        tracked = tracked.filter { _, identity in identityStillMatches(identity) }

        var queue: [RuntimeObservedProcessIdentity] = []
        if identityStillMatches(rootIdentity) { queue.append(rootIdentity) }
        queue.append(contentsOf: tracked.values)
        var visited = Set<RuntimeObservedProcessIdentity>()

        while let parent = queue.popLast() {
            guard visited.insert(parent).inserted else { continue }
            let children = reader.children(
                of: parent.processIdentifier,
                // Existing children are returned again on every snapshot, so
                // always inspect one beyond the hard cap. At exactly the cap,
                // this distinguishes known leaf identities from a genuinely
                // untracked child without retaining another identity.
                maximumCount: Self.maximumTrackedDescendants + 1
            )
            if !children.complete { trackingCapacityExceeded = true }
            for processIdentifier in children.processIdentifiers {
                guard processIdentifier != rootIdentity.processIdentifier,
                      let child = reader.identity(processIdentifier: processIdentifier),
                      child.parentProcessIdentifier == parent.processIdentifier else {
                    continue
                }
                if tracked[processIdentifier]?.startIdentity == child.startIdentity {
                    tracked[processIdentifier] = child
                    queue.append(child)
                    continue
                }
                guard tracked.count < Self.maximumTrackedDescendants else {
                    trackingCapacityExceeded = true
                    continue
                }
                tracked[processIdentifier] = child
                queue.append(child)
            }
        }
    }

    private func identityStillMatches(_ expected: RuntimeObservedProcessIdentity) -> Bool {
        guard let current = reader.identity(
            processIdentifier: expected.processIdentifier
        ) else { return false }
        return current.startIdentity == expected.startIdentity
    }
}

enum RuntimeRecoveredProcessSignalResult: Sendable, Equatable {
    case signaled
    case processMissing
    case identityUnavailable
    case identityMismatch
    case signalFailed(Int32)
}

protocol RuntimeRecoveredProcessControlling: Sendable {
    func signalProcessGroup(
        _ signal: Int32,
        expectedIdentity: RuntimePersistedProcessIdentity
    ) async -> RuntimeRecoveredProcessSignalResult
}

struct DarwinRuntimeRecoveredProcessController: RuntimeRecoveredProcessControlling, Sendable {
    func signalProcessGroup(
        _ signal: Int32,
        expectedIdentity: RuntimePersistedProcessIdentity
    ) async -> RuntimeRecoveredProcessSignalResult {
        guard expectedIdentity.isValidProcessGroupLeader else { return .identityMismatch }
        if let observed = RuntimeProcessIdentityReader.identity(
            processIdentifier: expectedIdentity.processIdentifier
        ) {
            guard observed.processIdentifier == expectedIdentity.processIdentifier,
                  observed.startIdentity == expectedIdentity.startIdentity else {
                return .identityMismatch
            }
        } else {
            let leaderProbe = Darwin.kill(expectedIdentity.processIdentifier, 0)
            if leaderProbe == 0 || errno == EPERM { return .identityUnavailable }
            guard errno == ESRCH else { return .identityUnavailable }

            // A process-group ID remains reserved while any original descendant is
            // alive, even after its leader exits. Continue controlling that exact
            // group instead of declaring cleanup complete from the leader alone.
            let groupProbe = Darwin.kill(-expectedIdentity.processGroupIdentifier, 0)
            if groupProbe != 0 {
                return errno == ESRCH ? .processMissing : .identityUnavailable
            }
        }

        var firstFailure: Int32?
        if Darwin.kill(-expectedIdentity.processGroupIdentifier, signal) != 0,
           errno != ESRCH {
            firstFailure = errno
        }
        // The exact root may have called setsid/setpgid and left its launch group.
        // Its persisted start identity makes direct signaling safe despite that.
        if RuntimeProcessIdentityReader.identity(
            processIdentifier: expectedIdentity.processIdentifier
        )?.startIdentity == expectedIdentity.startIdentity,
           Darwin.kill(expectedIdentity.processIdentifier, signal) != 0,
           errno != ESRCH,
           firstFailure == nil {
            firstFailure = errno
        }
        return firstFailure.map(RuntimeRecoveredProcessSignalResult.signalFailed) ?? .signaled
    }
}

enum RuntimeProcessIdentityReader {
    static func identity(processIdentifier: Int32) -> RuntimePersistedProcessIdentity? {
        guard let observed = observedIdentity(processIdentifier: processIdentifier) else {
            return nil
        }
        return RuntimePersistedProcessIdentity(
            processIdentifier: observed.processIdentifier,
            processGroupIdentifier: observed.processGroupIdentifier,
            startIdentity: observed.startIdentity
        )
    }

    static func observedIdentity(
        processIdentifier: Int32
    ) -> RuntimeObservedProcessIdentity? {
        guard processIdentifier > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            size
        )
        guard result == size,
              let observedPID = Int32(exactly: info.pbi_pid),
              observedPID == processIdentifier,
              let observedParent = Int32(exactly: info.pbi_ppid),
              let observedGroup = Int32(exactly: info.pbi_pgid),
              let seconds = Int64(exactly: info.pbi_start_tvsec),
              let microseconds = Int64(exactly: info.pbi_start_tvusec),
              let startIdentity = RuntimeProcessStartIdentity(
                seconds: seconds,
                microseconds: microseconds
              ) else { return nil }
        return RuntimeObservedProcessIdentity(
            processIdentifier: observedPID,
            parentProcessIdentifier: observedParent,
            processGroupIdentifier: observedGroup,
            startIdentity: startIdentity
        )
    }
}

final class RuntimeOutputSpool: @unchecked Sendable {
    private struct ArtifactIdentity: Sendable, Equatable {
        let deviceIdentifier: UInt64
        let fileIdentifier: UInt64
    }

    private struct StreamState {
        var inline = Data()
        var observedBytes: UInt64 = 0
        var retainedBytes: UInt64 = 0
        var inlineLimit: Int
        var artifactLimit: Int
        var artifactRelativePath: String
        var artifactURL: URL
        var handle: FileHandle?
        var hasher = SHA256()
        var artifactIdentity: ArtifactIdentity?
        var artifactTruncated = false
        var producerEndReason: RuntimeOutputProducerEndReason?
        var producerReadErrno: Int32?
        var writeError: Error?
    }

    let jobID: UUID
    let artifactID: String
    let relativeDirectory: String

    var canonicalDirectory: URL {
        RuntimePathCanonicalizer.canonicalExistingURL(
            artifactRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        )
    }

    var canonicalScratchDirectory: URL {
        RuntimePathCanonicalizer.canonicalExistingURL(
            scratchRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        )
    }

    private let lock = NSLock()
    private let artifactRoot: URL
    private let scratchRoot: URL
    private var states: [RuntimeOutputStream: StreamState]
    private var finalized = false
    private var finalizedMetadata: [RuntimeJobOutputMetadata]?

    init(
        jobID: UUID,
        projectID: ProjectID,
        generation: ProjectGeneration,
        artifactRoot: URL,
        maximumInlineBytes: Int,
        maximumArtifactBytes: Int
    ) throws {
        self.jobID = jobID
        self.artifactID = jobID.uuidString.lowercased()
        self.artifactRoot = RuntimePathCanonicalizer.canonicalExistingURL(artifactRoot)
        let requestedScratchRoot = self.artifactRoot.appendingPathComponent(
            ".runtime-scratch",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: requestedScratchRoot,
            withIntermediateDirectories: true
        )
        self.scratchRoot = RuntimePathCanonicalizer.canonicalExistingURL(requestedScratchRoot)
        guard self.scratchRoot.path == requestedScratchRoot.path,
              Self.contains(self.scratchRoot, root: self.artifactRoot) else {
            throw RuntimeJobError.storageFailure("runtime scratch root is not canonical")
        }
        _ = chmod(self.scratchRoot.path, S_IRWXU)
        relativeDirectory = [
            projectID.description,
            String(generation.rawValue),
            jobID.uuidString.lowercased(),
        ].joined(separator: "/")
        let directory = self.artifactRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = RuntimePathCanonicalizer.canonicalExistingURL(directory)
        guard resolvedDirectory.path == directory.path,
              Self.contains(resolvedDirectory, root: self.artifactRoot) else {
            throw RuntimeJobError.storageFailure("runtime artifact directory is not canonical")
        }
        _ = chmod(directory.path, S_IRWXU)
        let scratchDirectory = self.scratchRoot.appendingPathComponent(
            relativeDirectory,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true
        )
        let resolvedScratchDirectory = RuntimePathCanonicalizer.canonicalExistingURL(scratchDirectory)
        guard resolvedScratchDirectory.path == scratchDirectory.path,
              Self.contains(resolvedScratchDirectory, root: self.scratchRoot),
              !Self.contains(resolvedScratchDirectory, root: resolvedDirectory),
              !Self.contains(resolvedDirectory, root: resolvedScratchDirectory) else {
            try? FileManager.default.removeItem(at: scratchDirectory)
            try? FileManager.default.removeItem(at: directory)
            throw RuntimeJobError.storageFailure("runtime scratch directory is not isolated")
        }
        _ = chmod(scratchDirectory.path, S_IRWXU)

        let inlineTotal = max(0, maximumInlineBytes)
        let stdoutInline = inlineTotal * 3 / 4
        let stderrInline = inlineTotal - stdoutInline
        let artifactTotal = max(0, maximumArtifactBytes)
        let stdoutArtifact = artifactTotal * 3 / 4
        let stderrArtifact = artifactTotal - stdoutArtifact
        var initialized: [RuntimeOutputStream: StreamState] = [:]
        do {
            for (stream, inlineLimit, artifactLimit) in [
                (RuntimeOutputStream.stdout, stdoutInline, stdoutArtifact),
                (RuntimeOutputStream.stderr, stderrInline, stderrArtifact),
            ] {
                let filename = "\(stream.rawValue).log"
                let relativePath = relativeDirectory + "/" + filename
                let url = directory.appendingPathComponent(filename)
                let descriptor = Darwin.open(
                    url.path,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
                guard descriptor >= 0 else {
                    throw RuntimeJobError.storageFailure("could not create runtime output artifact")
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                initialized[stream] = StreamState(
                    inlineLimit: inlineLimit,
                    artifactLimit: artifactLimit,
                    artifactRelativePath: relativePath,
                    artifactURL: url,
                    handle: handle
                )
            }
        } catch {
            for state in initialized.values { try? state.handle?.close() }
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: scratchDirectory)
            throw error
        }
        states = initialized
    }

    func append(_ data: Data, stream: RuntimeOutputStream) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finalized, var state = states[stream] else { return }
        state.observedBytes = Self.saturatingAdd(state.observedBytes, UInt64(data.count))

        let inlineRemaining = max(0, state.inlineLimit - state.inline.count)
        if inlineRemaining > 0 {
            state.inline.append(data.prefix(inlineRemaining))
        }

        let artifactRemaining = max(0, state.artifactLimit - Int(min(state.retainedBytes, UInt64(Int.max))))
        let retained = Data(data.prefix(artifactRemaining))
        if !retained.isEmpty, state.writeError == nil {
            do {
                try state.handle?.write(contentsOf: retained)
                state.hasher.update(data: retained)
                state.retainedBytes = Self.saturatingAdd(state.retainedBytes, UInt64(retained.count))
            } catch {
                state.writeError = error
                state.artifactTruncated = true
            }
        }
        if data.count > artifactRemaining { state.artifactTruncated = true }
        states[stream] = state
    }

    func endProducer(
        stream: RuntimeOutputStream,
        reason: RuntimeOutputProducerEndReason,
        readErrno: Int32? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized, var state = states[stream], state.producerEndReason == nil else { return }
        state.producerEndReason = reason
        state.producerReadErrno = reason == .readError ? readErrno : nil
        if reason != .eof { state.artifactTruncated = true }
        states[stream] = state
    }

    func finalize() throws -> [RuntimeJobOutputMetadata] {
        lock.lock()
        defer { lock.unlock() }
        if let finalizedMetadata { return finalizedMetadata }
        finalized = true
        defer {
            let scratchDirectory = scratchRoot.appendingPathComponent(
                relativeDirectory,
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        for stream in RuntimeOutputStream.allCases {
            guard var state = states[stream] else { continue }
            do {
                guard let handle = state.handle else {
                    throw RuntimeJobError.storageFailure("runtime artifact handle closed before finalization")
                }
                try handle.synchronize()
                state.artifactIdentity = try Self.identity(
                    descriptor: handle.fileDescriptor,
                    expectedBytes: state.retainedBytes
                )
                try handle.close()
            } catch {
                state.writeError = state.writeError ?? error
            }
            state.handle = nil
            states[stream] = state
        }
        if let error = states.values.compactMap(\.writeError).first {
            throw RuntimeJobError.storageFailure("runtime artifact write failed: \(error.localizedDescription)")
        }
        let metadata = try RuntimeOutputStream.allCases.map { try metadataLocked(for: $0) }
        let directory = artifactRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: directory)
        }
        finalizedMetadata = metadata
        return metadata
    }

    func discard() {
        lock.lock()
        if !finalized {
            finalized = true
            for stream in RuntimeOutputStream.allCases {
                guard var state = states[stream] else { continue }
                try? state.handle?.close()
                state.handle = nil
                states[stream] = state
            }
        }
        let directory = artifactRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        let scratchDirectory = scratchRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    private func metadataLocked(for stream: RuntimeOutputStream) throws -> RuntimeJobOutputMetadata {
        guard var state = states[stream] else {
            throw RuntimeJobError.outputUnavailable(jobID, stream)
        }
        let inlineTruncated = state.observedBytes > UInt64(state.inline.count)
        let inlineIsValidUTF8 = String(data: state.inline, encoding: .utf8) != nil
        let shouldKeepArtifact = state.retainedBytes > 0
            && (inlineTruncated || state.artifactTruncated || !inlineIsValidUTF8)
        if !shouldKeepArtifact, FileManager.default.fileExists(atPath: state.artifactURL.path) {
            try FileManager.default.removeItem(at: state.artifactURL)
        }
        let retainedByteCount: UInt64
        let digestBytes: SHA256.Digest
        if shouldKeepArtifact {
            retainedByteCount = state.retainedBytes
            digestBytes = state.hasher.finalize()
        } else {
            retainedByteCount = UInt64(state.inline.count)
            digestBytes = SHA256.hash(data: state.inline)
        }
        let digest = digestBytes.map { String(format: "%02x", $0) }.joined()
        state.hasher = SHA256()
        states[stream] = state
        return RuntimeJobOutputMetadata(
            jobID: jobID,
            stream: stream,
            inlineText: String(decoding: state.inline, as: UTF8.self),
            artifactRelativePath: shouldKeepArtifact ? state.artifactRelativePath : nil,
            artifactDeviceIdentifier: shouldKeepArtifact
                ? state.artifactIdentity?.deviceIdentifier
                : nil,
            artifactFileIdentifier: shouldKeepArtifact
                ? state.artifactIdentity?.fileIdentifier
                : nil,
            byteCount: state.observedBytes,
            retainedByteCount: retainedByteCount,
            sha256: digest,
            inlineTruncated: inlineTruncated,
            artifactTruncated: state.artifactTruncated,
            artifactEvicted: false,
            producerEndReason: state.producerEndReason,
            producerReadErrno: state.producerReadErrno
        )
    }

    private static func identity(
        descriptor: Int32,
        expectedBytes: UInt64
    ) throws -> ArtifactIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) == expectedBytes,
              metadata.st_dev >= 0 else {
            throw RuntimeJobError.storageFailure(
                "runtime artifact identity changed before durable commit"
            )
        }
        return ArtifactIdentity(
            deviceIdentifier: UInt64(metadata.st_dev),
            fileIdentifier: UInt64(metadata.st_ino)
        )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private static func contains(_ child: URL, root: URL) -> Bool {
        let childPath = child.path
        let rootPath = root.path
        return childPath == rootPath
            || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

final class RuntimeActiveProcess: @unchecked Sendable {
    let processIdentifier: Int32
    let processGroupIdentifier: Int32
    let processStartIdentity: RuntimeProcessStartIdentity?
    let spool: RuntimeOutputSpool

    private let exitMonitor: RuntimeProcessExitMonitor
    private let stdoutReader: RuntimePipeReader
    private let stderrReader: RuntimePipeReader
    private let descendantTracker: RuntimeDescendantTracker
    private let signalLock = NSLock()
    private let launchGateLock = NSLock()
    private var sentTerm = false
    private var sentKill = false
    private var launchGateWriteDescriptor: Int32 = -1
    private var launchReleased = false

    init(
        plan: RuntimeProcessPlan,
        spool: RuntimeOutputSpool,
        launcher: URL,
        maximumDescendants: Int = 16,
        processTreeReader: any RuntimeProcessTreeReading = DarwinRuntimeProcessTreeReader(),
        processSignaler: any RuntimeProcessSignaling = DarwinRuntimeProcessSignaler()
    ) throws {
        try RuntimeLaunchGate.validate(launcher, outside: plan.writableRoots)
        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        var stderrDescriptors = [Int32](repeating: -1, count: 2)
        var gateDescriptors = [Int32](repeating: -1, count: 2)
        var spawnedPID: Int32 = 0
        guard Darwin.pipe(&stdoutDescriptors) == 0 else {
            throw RuntimeJobError.spawnFailed(errno)
        }
        guard Darwin.pipe(&stderrDescriptors) == 0 else {
            let saved = errno
            Darwin.close(stdoutDescriptors[0])
            Darwin.close(stdoutDescriptors[1])
            throw RuntimeJobError.spawnFailed(saved)
        }
        guard Darwin.pipe(&gateDescriptors) == 0 else {
            let saved = errno
            stdoutDescriptors.forEach { Darwin.close($0) }
            stderrDescriptors.forEach { Darwin.close($0) }
            throw RuntimeJobError.spawnFailed(saved)
        }

        do {
            try Self.setCloseOnExec(
                stdoutDescriptors + stderrDescriptors + gateDescriptors
            )
            guard Darwin.fcntl(gateDescriptors[1], F_SETNOSIGPIPE, 1) == 0 else {
                throw RuntimeJobError.spawnFailed(errno)
            }
            let pid = try Self.spawn(
                plan: plan,
                launcher: launcher,
                stdoutDescriptors: stdoutDescriptors,
                stderrDescriptors: stderrDescriptors,
                gateDescriptors: gateDescriptors
            )
            spawnedPID = pid
            processIdentifier = pid
            processGroupIdentifier = pid
            guard let observedIdentity = RuntimeProcessIdentityReader.observedIdentity(
                processIdentifier: pid
            ),
                  observedIdentity.processGroupIdentifier == pid else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate did not expose an exact process identity"
                )
            }
            processStartIdentity = observedIdentity.startIdentity
            descendantTracker = RuntimeDescendantTracker(
                rootIdentity: observedIdentity,
                maximumDescendants: maximumDescendants,
                reader: processTreeReader,
                signaler: processSignaler
            )
            self.spool = spool
            Darwin.close(stdoutDescriptors[1])
            Darwin.close(stderrDescriptors[1])
            Darwin.close(gateDescriptors[0])
            launchGateWriteDescriptor = gateDescriptors[1]
            stdoutReader = RuntimePipeReader(
                descriptor: stdoutDescriptors[0],
                stream: .stdout,
                spool: spool
            )
            stderrReader = RuntimePipeReader(
                descriptor: stderrDescriptors[0],
                stream: .stderr,
                spool: spool
            )
            exitMonitor = RuntimeProcessExitMonitor(processIdentifier: pid)
            stdoutReader.start()
            stderrReader.start()
        } catch {
            stdoutDescriptors.forEach { if $0 >= 0 { Darwin.close($0) } }
            stderrDescriptors.forEach { if $0 >= 0 { Darwin.close($0) } }
            gateDescriptors.forEach { if $0 >= 0 { Darwin.close($0) } }
            if spawnedPID > 1 {
                _ = Darwin.kill(-spawnedPID, SIGKILL)
                var status: Int32 = 0
                while Darwin.waitpid(spawnedPID, &status, 0) < 0, errno == EINTR {}
            }
            throw error
        }
    }

    deinit {
        abortBeforeExecution()
    }

    /// Releases the trusted launcher only after the process identity has been
    /// durably committed. A parent crash before this write closes the pipe and
    /// the launcher exits without executing request-controlled code.
    func releaseForExecution() throws {
        launchGateLock.lock()
        defer { launchGateLock.unlock() }
        if launchReleased { return }
        guard launchGateWriteDescriptor >= 0 else {
            throw RuntimeJobError.storageFailure("runtime launch gate is unavailable")
        }
        var byte = RuntimeLaunchGate.releaseByte
        var result: Int = -1
        repeat {
            result = withUnsafeBytes(of: &byte) { buffer in
                Darwin.write(
                    launchGateWriteDescriptor,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        } while result < 0 && errno == EINTR
        let savedError = errno
        _ = Darwin.close(launchGateWriteDescriptor)
        launchGateWriteDescriptor = -1
        guard result == 1 else {
            throw RuntimeJobError.spawnFailed(savedError)
        }
        launchReleased = true
    }

    func abortBeforeExecution() {
        launchGateLock.lock()
        defer { launchGateLock.unlock() }
        guard launchGateWriteDescriptor >= 0 else { return }
        _ = Darwin.close(launchGateWriteDescriptor)
        launchGateWriteDescriptor = -1
    }

    func currentExit() -> RuntimeProcessExit? { exitMonitor.current() }

    func observeDescendants() -> RuntimeDescendantObservation {
        descendantTracker.observe()
    }

    func waitForExit(maximumMilliseconds: Int) async -> RuntimeProcessExit? {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(max(0, maximumMilliseconds))
        repeat {
            if let exit = exitMonitor.current() { return exit }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        } while true
    }

    @discardableResult
    func signalProcessGroup(_ signal: Int32) -> Bool {
        signalLock.lock()
        if signal == SIGKILL {
            if sentKill {
                signalLock.unlock()
                return true
            }
            sentKill = true
        } else if signal == SIGTERM {
            if sentTerm || sentKill {
                signalLock.unlock()
                return true
            }
            sentTerm = true
        }
        signalLock.unlock()
        let result = Darwin.kill(-processGroupIdentifier, signal)
        return result == 0 || errno == ESRCH
    }

    func terminateAndWait(graceMilliseconds: Int, forcedGraceMilliseconds: Int) async throws -> RuntimeProcessExit {
        _ = descendantTracker.observe()
        _ = signalProcessGroup(SIGTERM)
        _ = descendantTracker.signalTracked(SIGTERM, includeRoot: true)
        var exit = await waitForExit(maximumMilliseconds: graceMilliseconds)
        if processGroupExists()
            || descendantTracker.hasLiveTrackedProcesses(includeRoot: exit == nil) {
            _ = signalProcessGroup(SIGKILL)
            let killSignalsConfirmed = descendantTracker.signalTracked(SIGKILL, includeRoot: true)
            guard killSignalsConfirmed,
                  await waitForOwnedExit(
                    maximumMilliseconds: forcedGraceMilliseconds,
                    includeRoot: exit == nil,
                    repeatingSignal: SIGKILL
                  ) else {
                throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
            }
        }
        if exit == nil {
            exit = await waitForExit(maximumMilliseconds: forcedGraceMilliseconds)
        }
        guard let exit,
              !processGroupExists(),
              !descendantTracker.hasLiveTrackedProcesses(includeRoot: false) else {
            throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
        }
        return exit
    }

    func closeDescendants(
        graceMilliseconds: Int,
        forcedGraceMilliseconds: Int
    ) async throws {
        _ = descendantTracker.observe()
        guard processGroupExists()
            || descendantTracker.hasLiveTrackedProcesses(includeRoot: false) else { return }
        _ = Darwin.kill(-processGroupIdentifier, SIGTERM)
        let termSignalsConfirmed = descendantTracker.signalTracked(SIGTERM, includeRoot: false)
        if termSignalsConfirmed,
           await waitForOwnedExit(
            maximumMilliseconds: graceMilliseconds,
            includeRoot: false,
            repeatingSignal: SIGTERM
           ) { return }
        _ = Darwin.kill(-processGroupIdentifier, SIGKILL)
        let killSignalsConfirmed = descendantTracker.signalTracked(SIGKILL, includeRoot: false)
        guard killSignalsConfirmed,
              await waitForOwnedExit(
                maximumMilliseconds: forcedGraceMilliseconds,
                includeRoot: false,
                repeatingSignal: SIGKILL
              ) else {
            throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
        }
    }

    private func waitForOwnedExit(
        maximumMilliseconds: Int,
        includeRoot: Bool,
        repeatingSignal: Int32
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(max(0, maximumMilliseconds))
        while clock.now < deadline {
            _ = descendantTracker.observe()
            _ = descendantTracker.signalTracked(repeatingSignal, includeRoot: includeRoot)
            if !processGroupExists(),
               !descendantTracker.hasLiveTrackedProcesses(includeRoot: includeRoot) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !processGroupExists()
            && !descendantTracker.hasLiveTrackedProcesses(includeRoot: includeRoot)
    }

    func waitForReaders(maximumMilliseconds: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(max(0, maximumMilliseconds))
        while clock.now < deadline {
            if stdoutReader.finished && stderrReader.finished { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return stdoutReader.finished && stderrReader.finished
    }

    func forceCloseReaders() {
        stdoutReader.close()
        stderrReader.close()
    }

    private func processGroupExists() -> Bool {
        let result = Darwin.kill(-processGroupIdentifier, 0)
        return result == 0 || errno == EPERM
    }

    private static func spawn(
        plan: RuntimeProcessPlan,
        launcher: URL,
        stdoutDescriptors: [Int32],
        stderrDescriptors: [Int32],
        gateDescriptors: [Int32]
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else {
            throw RuntimeJobError.spawnFailed(result)
        }
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw RuntimeJobError.spawnFailed(result)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        result = posix_spawn_file_actions_adddup2(&actions, stdoutDescriptors[1], STDOUT_FILENO)
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        result = posix_spawn_file_actions_adddup2(&actions, stderrDescriptors[1], STDERR_FILENO)
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        result = posix_spawn_file_actions_adddup2(
            &actions,
            gateDescriptors[0],
            RuntimeLaunchGate.inheritedDescriptor
        )
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        for descriptor in Set(stdoutDescriptors + stderrDescriptors + gateDescriptors).sorted()
        where descriptor != STDIN_FILENO
            && descriptor != STDOUT_FILENO
            && descriptor != STDERR_FILENO
            && descriptor != RuntimeLaunchGate.inheritedDescriptor {
            result = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        }
        result = posix_spawn_file_actions_addopen(
            &actions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        )
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        result = plan.workingDirectory.path.withCString {
            posix_spawn_file_actions_addchdir(&actions, $0)
        }
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }

        var emptySignalMask = sigset_t()
        guard Darwin.sigemptyset(&emptySignalMask) == 0 else {
            throw RuntimeJobError.spawnFailed(errno)
        }
        result = posix_spawnattr_setsigmask(&attributes, &emptySignalMask)
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        var defaultSignals = sigset_t()
        guard Darwin.sigfillset(&defaultSignals) == 0 else {
            throw RuntimeJobError.spawnFailed(errno)
        }
        result = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }

        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        result = posix_spawnattr_setflags(&attributes, flags)
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }

        let argumentStrings = [
            launcher.path,
            "--parent",
            String(Darwin.getpid()),
            "--",
            plan.executable.path,
        ] + plan.arguments
        let environmentStrings = plan.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let arguments = argumentStrings.map { strdup($0) } + [nil]
        let environment = environmentStrings.map { strdup($0) } + [nil]
        defer {
            for pointer in arguments where pointer != nil {
                Darwin.free(UnsafeMutableRawPointer(pointer!))
            }
            for pointer in environment where pointer != nil {
                Darwin.free(UnsafeMutableRawPointer(pointer!))
            }
        }
        var pid: pid_t = 0
        result = arguments.withUnsafeBufferPointer { argumentBuffer in
            environment.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    launcher.path,
                    &actions,
                    &attributes,
                    UnsafeMutablePointer(mutating: argumentBuffer.baseAddress),
                    UnsafeMutablePointer(mutating: environmentBuffer.baseAddress)
                )
            }
        }
        guard result == 0 else { throw RuntimeJobError.spawnFailed(result) }
        return pid
    }

    private static func setCloseOnExec(_ descriptors: [Int32]) throws {
        for descriptor in descriptors {
            guard descriptor >= 0,
                  Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw RuntimeJobError.spawnFailed(errno)
            }
        }
    }
}

private final class RuntimeProcessExitMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var result: RuntimeProcessExit?

    init(processIdentifier: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = Darwin.waitpid(processIdentifier, &status, 0)
            } while waitResult < 0 && errno == EINTR
            let exit: RuntimeProcessExit
            if waitResult == processIdentifier {
                let signal = status & 0x7f
                if signal == 0 {
                    exit = RuntimeProcessExit(
                        rawWaitStatus: status,
                        exitCode: (status >> 8) & 0xff,
                        terminatingSignal: nil
                    )
                } else {
                    exit = RuntimeProcessExit(
                        rawWaitStatus: status,
                        exitCode: 128 + signal,
                        terminatingSignal: signal
                    )
                }
            } else {
                exit = RuntimeProcessExit(rawWaitStatus: status, exitCode: 255, terminatingSignal: nil)
            }
            self?.lock.lock()
            self?.result = exit
            self?.lock.unlock()
        }
    }

    func current() -> RuntimeProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

final class RuntimePipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let stream: RuntimeOutputStream
    private let spool: RuntimeOutputSpool
    private let stateLock = NSLock()
    private var didStart = false
    private var didFinish = false
    private var closeRequested = false

    init(descriptor: Int32, stream: RuntimeOutputStream, spool: RuntimeOutputSpool) {
        self.descriptor = descriptor
        self.stream = stream
        self.spool = spool
    }

    var finished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didFinish
    }

    func start() {
        stateLock.lock()
        guard !didStart else {
            stateLock.unlock()
            return
        }
        didStart = true
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            // Close requests leave this worker as the sole descriptor owner
            // until it has stopped reading, preventing reads from a reused FD.
            defer {
                Darwin.close(descriptor)
                stateLock.lock()
                didFinish = true
                stateLock.unlock()
            }
            let flags = Darwin.fcntl(descriptor, F_GETFL)
            guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                let saved = errno
                recordProducerEnd(reason: .readError, readErrno: saved)
                return
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                stateLock.lock()
                let shouldClose = closeRequested
                stateLock.unlock()
                if shouldClose { return }
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                let saved = errno
                if count > 0 {
                    spool.append(Data(buffer.prefix(count)), stream: stream)
                    continue
                }
                if count == 0 {
                    recordProducerEnd(reason: .eof)
                    return
                }
                if saved == EINTR { continue }
                if saved == EAGAIN || saved == EWOULDBLOCK {
                    var pending = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let result = Darwin.poll(&pending, 1, 10)
                    if result < 0, errno != EINTR {
                        let pollError = errno
                        recordProducerEnd(reason: .readError, readErrno: pollError)
                        return
                    }
                    continue
                }
                recordProducerEnd(reason: .readError, readErrno: saved)
                return
            }
        }
    }

    private func recordProducerEnd(reason: RuntimeOutputProducerEndReason, readErrno: Int32? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closeRequested else { return }
        spool.endProducer(stream: stream, reason: reason, readErrno: readErrno)
    }

    func close() {
        stateLock.lock()
        guard !didFinish, !closeRequested else {
            stateLock.unlock()
            return
        }
        closeRequested = true
        // Serialize the request with actual EOF: only an already-recorded EOF wins.
        spool.endProducer(stream: stream, reason: .forcedClose)
        stateLock.unlock()
    }
}
