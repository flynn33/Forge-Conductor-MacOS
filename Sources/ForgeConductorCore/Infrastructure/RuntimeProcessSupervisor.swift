// RuntimeProcessSupervisor.swift
// POSIX process-group launch, concurrent pipe draining, and bounded artifact spill.

import CryptoKit
import Darwin
import Foundation
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

/// Builds the fail-closed macOS process sandbox used by every durable runtime job.
/// The child may read immutable system runtime files, but project data is visible
/// only below the exact read authorization roots. Writes are limited to an
/// independently granted subset and the job's private scratch directory. Durable
/// output remains in a manager-only directory that the child can read only when
/// it must consume a staged request. Network access is an explicit authorization
/// bit, never an advisory field.
enum RuntimeProcessSandbox {
    static let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    static let maximumProfileBytes = 64 * 1_024
    static let maximumRoots = 32

    private static let immutableSystemReadRoots = [
        "/System",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/usr/share",
        "/bin",
        "/sbin",
        "/Library/Apple",
        "/Library/Developer",
        "/Applications/Xcode.app",
        "/private/var/db/timezone",
    ]
    private static let systemReadFiles = [
        "/",
        "/etc",
        "/etc/bashrc",
        "/etc/localtime",
        "/etc/master.passwd",
        "/etc/passwd",
        "/etc/profile",
        "/etc/protocols",
        "/etc/services",
        "/etc/zprofile",
        "/etc/zshrc",
        "/private",
        "/private/etc",
        "/private/etc/bashrc",
        "/private/etc/localtime",
        "/private/etc/master.passwd",
        "/private/etc/passwd",
        "/private/etc/profile",
        "/private/etc/protocols",
        "/private/etc/services",
        "/private/etc/zprofile",
        "/private/etc/zshrc",
        "/dev/null",
        "/dev/random",
        "/dev/urandom",
    ]

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    static func plan(
        executable target: URL,
        arguments: [String],
        workingDirectory: URL,
        environment sourceEnvironment: [String: String],
        canonicalReadRoots: [URL],
        canonicalWritableRoots: [URL],
        managerReadDirectory: URL,
        scratchDirectory: URL,
        networkAllowed: Bool
    ) throws -> RuntimeProcessPlan {
        guard isAvailable else {
            throw RuntimeJobError.executableUnavailable("sandbox-exec")
        }
        let readAuthorizationRoots = canonicalReadRoots
            .map(canonicalExistingURL)
            .reduce(into: [URL]()) { result, root in
                if !result.contains(root) { result.append(root) }
            }
        let writableAuthorizationRoots = canonicalWritableRoots
            .map(canonicalExistingURL)
            .reduce(into: [URL]()) { result, root in
                if !result.contains(root) { result.append(root) }
            }
        guard !readAuthorizationRoots.isEmpty,
              readAuthorizationRoots.count <= maximumRoots,
              writableAuthorizationRoots.count <= maximumRoots else {
            throw RuntimeJobError.invalidRequest(
                "runtime read or writable roots exceed the sandbox bound"
            )
        }
        guard writableAuthorizationRoots.allSatisfy({ writable in
            contains(writable, in: readAuthorizationRoots)
        }) else {
            throw RuntimeJobError.invalidRequest(
                "runtime writable roots must be contained by authorized read roots"
            )
        }
        let canonicalManagerRead = canonicalExistingURL(managerReadDirectory)
        let canonicalScratch = canonicalExistingURL(scratchDirectory)
        guard !contains(canonicalScratch, root: canonicalManagerRead),
              !contains(canonicalManagerRead, root: canonicalScratch) else {
            throw RuntimeJobError.invalidRequest(
                "runtime durable output and scratch directories must not overlap"
            )
        }
        guard writableAuthorizationRoots.allSatisfy({ writable in
            !contains(canonicalManagerRead, root: writable)
                && !contains(writable, root: canonicalManagerRead)
        }) else {
            throw RuntimeJobError.invalidRequest(
                "runtime durable output must not overlap a child-writable root"
            )
        }
        let canonicalTarget = canonicalExistingURL(target)
        let canonicalWorkingDirectory = canonicalExistingURL(workingDirectory)
        guard contains(canonicalWorkingDirectory, in: readAuthorizationRoots) else {
            throw RuntimeJobError.workingDirectoryOutsideProject(canonicalWorkingDirectory.path)
        }
        guard contains(canonicalTarget, in: readAuthorizationRoots)
                || isImmutableSystemRuntime(canonicalTarget) else {
            throw RuntimeJobError.invalidRequest(
                "runtime executable is outside authorized project and system runtime roots"
            )
        }

        let readRoots = readAuthorizationRoots.map(\.path)
            + [canonicalManagerRead.path, canonicalScratch.path]
            + immutableSystemReadRoots
        let writeRoots = writableAuthorizationRoots.map(\.path) + [canonicalScratch.path]
        // Sandbox path filters need search access to every parent directory in
        // order for getcwd(3), shell startup, and script opening to reach an
        // otherwise-authorized nested root. Parent directories are literal-only:
        // their children do not become readable.
        let readAncestors = ancestorDirectories(of: readRoots)
        let readFilters = try filters(
            subpaths: readRoots,
            literals: systemReadFiles
        )
        let ancestorFilters = try filters(subpaths: [], literals: readAncestors)
        let writeFilters = try filters(subpaths: writeRoots, literals: [])
        var profile = """
        (version 1)
        (deny default)
        (allow file-read* (require-any \(readFilters)))
        (allow file-read-metadata file-test-existence (require-any \(ancestorFilters)))
        (allow file-write* (require-any \(writeFilters) (literal "/dev/null")))
        (allow process-exec process-fork)
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (deny syscall-unix (syscall-number 82 147 244))
        """
        if networkAllowed {
            profile += "\n(allow network-outbound (literal \"/private/var/run/mDNSResponder\") (remote tcp \"*:*\") (remote udp \"*:*\"))"
        }
        guard profile.utf8.count <= maximumProfileBytes else {
            throw RuntimeJobError.invalidRequest("runtime sandbox profile exceeds its byte bound")
        }

        let temporaryDirectory = canonicalScratch.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        _ = chmod(temporaryDirectory.path, S_IRWXU)
        var environment = sourceEnvironment.filter { key, _ in
            !key.hasPrefix("DYLD_")
                && !key.hasPrefix("LD_")
        }
        environment["HOME"] = canonicalWorkingDirectory.path
        environment["TMPDIR"] = temporaryDirectory.path + "/"
        return RuntimeProcessPlan(
            executable: executable,
            arguments: ["-p", profile, canonicalTarget.path] + arguments,
            workingDirectory: canonicalWorkingDirectory,
            environment: environment,
            writableRoots: writableAuthorizationRoots + [canonicalScratch]
        )
    }

    private static func filters(subpaths: [String], literals: [String]) throws -> String {
        let uniqueSubpaths = Array(Set(subpaths)).sorted()
        let uniqueLiterals = Array(Set(literals)).sorted()
        return try (
            uniqueSubpaths.map { "(subpath \(try literal($0)))" }
                + uniqueLiterals.map { "(literal \(try literal($0)))" }
        ).joined(separator: " ")
    }

    private static func literal(_ value: String) throws -> String {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value == 10 || $0.value == 13
              }) else {
            throw RuntimeJobError.invalidRequest("runtime sandbox paths contain unsupported control characters")
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func ancestorDirectories(of paths: [String]) -> [String] {
        var ancestors: Set<String> = ["/"]
        for path in paths {
            var candidate = URL(fileURLWithPath: path).deletingLastPathComponent()
            while candidate.path != "/", !candidate.path.isEmpty {
                ancestors.insert(candidate.path)
                candidate.deleteLastPathComponent()
            }
        }
        return ancestors.sorted()
    }

    /// Foundation intentionally preserves macOS convenience aliases such as
    /// `/var`, while sandbox path matching is evaluated against the physical
    /// `/private/var` vnode path. `realpath(3)` keeps the authorization and the
    /// kernel's policy subject in the same namespace.
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

    static func isImmutableSystemRuntime(_ url: URL) -> Bool {
        let canonical = canonicalExistingURL(url)
        return immutableSystemReadRoots.contains {
            contains(canonical, root: canonicalExistingURL(URL(fileURLWithPath: $0)))
        }
    }

    private static func contains(_ child: URL, in roots: [URL]) -> Bool {
        roots.contains { contains(child, root: $0) }
    }

    private static func contains(_ child: URL, root: URL) -> Bool {
        // Both URLs were already canonicalized with realpath(3). Foundation's
        // standardization would undo that for `/private/var`.
        let childPath = child.path
        let rootPath = root.path
        return childPath == rootPath
            || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

/// Installs the small native launcher into service-owned storage before any job
/// is accepted. Request-controlled roots are never used as an executable source,
/// and every launch rechecks that the installed copy is outside all job-writable
/// paths before it runs outside the sandbox.
enum RuntimeLaunchGate {
    static let executableName = "forge-runtime-launcher"
    static let productIdentifier = "com.forge-conductor.runtime-launcher"
    static let productTeamIdentifier = "2Y25RTLZET"
    static let inheritedDescriptor: Int32 = 3
    static let releaseByte: UInt8 = 0xA5
    static let maximumExecutableBytes = 8 * 1_024 * 1_024

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
        let canonicalServiceRoot = RuntimeProcessSandbox.canonicalExistingURL(serviceRoot)
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
        return RuntimeProcessSandbox.canonicalExistingURL(destination)
    }

    static func validate(_ launcher: URL, outside writableRoots: [URL]) throws {
        let canonicalLauncher = RuntimeProcessSandbox.canonicalExistingURL(launcher)
        let data = try readTrustedExecutable(canonicalLauncher)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard canonicalLauncher.lastPathComponent == "\(executableName)-\(digest)" else {
            throw RuntimeJobError.storageFailure("installed runtime launch gate digest does not match")
        }
        for root in writableRoots.map(RuntimeProcessSandbox.canonicalExistingURL) {
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
                return RuntimeProcessSandbox.canonicalExistingURL(standardized)
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
            guard packageTestIdentity.identifier == "ForgeConductorPackageTests",
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
            let allowedParent = ["com.forge-conductor.cli", "com.forge-conductor.tests"]
                .contains(currentIdentity.identifier)
            if allowedParent,
               sourceIdentity.teamIdentifier == productTeamIdentifier,
               currentIdentity.teamIdentifier == productTeamIdentifier {
                return sourceIdentity
            }
            let sourceIsExpectedDevelopmentSignature =
                sourceIdentity.teamIdentifier == productTeamIdentifier
                || (sourceIdentity.teamIdentifier == nil
                    && sourceIdentity.flags.contains(.adhoc))
            guard allowedParent,
                  sourceIsExpectedDevelopmentSignature,
                  currentIdentity.teamIdentifier == nil,
                  currentIdentity.flags.contains(.adhoc),
                  isExpectedDevelopmentPair(
                    source: source,
                    currentExecutable: currentExecutable
                  ) else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate does not match the command-line product"
                )
            }
            return sourceIdentity
        }

        let helperIsSwiftPackageProduct = sourceIdentity.identifier == executableName
            || sourceIdentity.identifier.hasPrefix(executableName + "-")
        let currentIsSwiftPackageProduct = ["forge-conductor", "forge-conductor-app"]
            .contains { name in
                currentIdentity.identifier == name
                    || currentIdentity.identifier.hasPrefix(name + "-")
            }
        let currentIsPackageTest = currentIdentity.identifier == "ForgeConductorPackageTests"
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
        guard RuntimeProcessSandbox.canonicalExistingURL(source)
                == RuntimeProcessSandbox.canonicalExistingURL(expectedSource),
              RuntimeProcessSandbox.canonicalExistingURL(currentExecutable)
                == RuntimeProcessSandbox.canonicalExistingURL(expectedExecutable),
              appIdentity.identifier == ManagerInstaller.bundleIdentifier,
              currentIdentity.identifier == ManagerInstaller.bundleIdentifier,
              sourceIdentity.identifier == productIdentifier else {
            throw RuntimeJobError.storageFailure(
                "bundled runtime launch gate does not match the enclosing signed product"
            )
        }

        if let appTeam = appIdentity.teamIdentifier,
           appTeam == productTeamIdentifier,
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
        let canonicalExecutable = RuntimeProcessSandbox.canonicalExistingURL(executable)
        return ([Bundle.main] + Bundle.allBundles).contains { bundle in
            guard bundle.bundleURL.pathExtension == "xctest",
                  let testExecutable = bundle.executableURL else { return false }
            return RuntimeProcessSandbox.canonicalExistingURL(testExecutable)
                == canonicalExecutable
        }
    }

    private static func isExpectedDevelopmentPair(
        source: URL,
        currentExecutable: URL
    ) -> Bool {
        let canonicalSource = RuntimeProcessSandbox.canonicalExistingURL(source)
        let canonicalExecutable = RuntimeProcessSandbox.canonicalExistingURL(
            currentExecutable
        )
        let loadedTestBundles = [Bundle.main] + Bundle.allBundles
        if let testBundle = loadedTestBundles.first(where: { bundle in
            guard bundle.bundleURL.pathExtension == "xctest",
                  let executable = bundle.executableURL else { return false }
            return RuntimeProcessSandbox.canonicalExistingURL(executable)
                == canonicalExecutable
        }) {
            let expected = testBundle.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(executableName)
            return RuntimeProcessSandbox.canonicalExistingURL(expected) == canonicalSource
        }
        let expected = canonicalExecutable.deletingLastPathComponent()
            .appendingPathComponent(executableName)
        return RuntimeProcessSandbox.canonicalExistingURL(expected) == canonicalSource
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
        return CodeIdentity(
            identifier: identifier,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
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

struct RuntimeProcessStartIdentity: Sendable, Equatable {
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
            guard observed == expectedIdentity else { return .identityMismatch }
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

        let result = Darwin.kill(-expectedIdentity.processGroupIdentifier, signal)
        guard result == 0 else {
            let failure = errno
            return failure == ESRCH ? .processMissing : .signalFailed(failure)
        }
        return .signaled
    }
}

enum RuntimeProcessIdentityReader {
    static func identity(processIdentifier: Int32) -> RuntimePersistedProcessIdentity? {
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
              let observedGroup = Int32(exactly: info.pbi_pgid),
              let seconds = Int64(exactly: info.pbi_start_tvsec),
              let microseconds = Int64(exactly: info.pbi_start_tvusec),
              let startIdentity = RuntimeProcessStartIdentity(
                seconds: seconds,
                microseconds: microseconds
              ) else { return nil }
        return RuntimePersistedProcessIdentity(
            processIdentifier: observedPID,
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
        var writeError: Error?
    }

    let jobID: UUID
    let artifactID: String
    let relativeDirectory: String

    var canonicalDirectory: URL {
        RuntimeProcessSandbox.canonicalExistingURL(
            artifactRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        )
    }

    var canonicalScratchDirectory: URL {
        RuntimeProcessSandbox.canonicalExistingURL(
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
        self.artifactRoot = RuntimeProcessSandbox.canonicalExistingURL(artifactRoot)
        let requestedScratchRoot = self.artifactRoot.appendingPathComponent(
            ".runtime-scratch",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: requestedScratchRoot,
            withIntermediateDirectories: true
        )
        self.scratchRoot = RuntimeProcessSandbox.canonicalExistingURL(requestedScratchRoot)
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
        let resolvedDirectory = RuntimeProcessSandbox.canonicalExistingURL(directory)
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
        let resolvedScratchDirectory = RuntimeProcessSandbox.canonicalExistingURL(scratchDirectory)
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
            artifactEvicted: false
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
    private let signalLock = NSLock()
    private let launchGateLock = NSLock()
    private var sentTerm = false
    private var sentKill = false
    private var launchGateWriteDescriptor: Int32 = -1
    private var launchReleased = false

    init(plan: RuntimeProcessPlan, spool: RuntimeOutputSpool, launcher: URL) throws {
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
            guard let observedIdentity = RuntimeProcessIdentityReader.identity(processIdentifier: pid),
                  observedIdentity.processGroupIdentifier == pid else {
                throw RuntimeJobError.storageFailure(
                    "runtime launch gate did not expose an exact process identity"
                )
            }
            processStartIdentity = observedIdentity.startIdentity
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
        _ = signalProcessGroup(SIGTERM)
        var exit = await waitForExit(maximumMilliseconds: graceMilliseconds)
        if processGroupExists() {
            _ = signalProcessGroup(SIGKILL)
            guard await waitForProcessGroupExit(maximumMilliseconds: forcedGraceMilliseconds) else {
                throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
            }
        }
        if exit == nil {
            exit = await waitForExit(maximumMilliseconds: forcedGraceMilliseconds)
        }
        guard let exit, !processGroupExists() else {
            throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
        }
        return exit
    }

    func closeDescendants(
        graceMilliseconds: Int,
        forcedGraceMilliseconds: Int
    ) async throws {
        guard processGroupExists() else { return }
        _ = Darwin.kill(-processGroupIdentifier, SIGTERM)
        if await waitForProcessGroupExit(maximumMilliseconds: graceMilliseconds) { return }
        _ = Darwin.kill(-processGroupIdentifier, SIGKILL)
        guard await waitForProcessGroupExit(maximumMilliseconds: forcedGraceMilliseconds) else {
            throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
        }
    }

    private func waitForProcessGroupExit(maximumMilliseconds: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(max(0, maximumMilliseconds))
        while clock.now < deadline, processGroupExists() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !processGroupExists()
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

private final class RuntimePipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let stream: RuntimeOutputStream
    private let spool: RuntimeOutputSpool
    private let stateLock = NSLock()
    private var didStart = false
    private var didFinish = false
    private var didClose = false

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
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    spool.append(Data(buffer.prefix(count)), stream: stream)
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            close()
            stateLock.lock()
            didFinish = true
            stateLock.unlock()
        }
    }

    func close() {
        stateLock.lock()
        guard !didClose else {
            stateLock.unlock()
            return
        }
        didClose = true
        stateLock.unlock()
        Darwin.close(descriptor)
    }
}
