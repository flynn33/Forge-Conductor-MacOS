import Foundation
import Security
import LocalAuthentication
import Darwin
#if SWIFT_PACKAGE
import ForgeConductorCore
#endif

public protocol LMStudioCredentialStoring: Sendable {
    func insert(token: String, reference: String) throws
    func remove(reference: String) throws
}

public struct LMStudioKeychainCredentialStore: LMStudioCredentialStoring {
    private let addItem: @Sendable (CFDictionary) -> OSStatus
    private let deleteItem: @Sendable (CFDictionary) -> OSStatus

    public init() {
        addItem = { SecItemAdd($0, nil) }
        deleteItem = { SecItemDelete($0) }
    }

    init(addItem: @escaping @Sendable (CFDictionary) -> OSStatus,
         deleteItem: @escaping @Sendable (CFDictionary) -> OSStatus) {
        self.addItem = addItem; self.deleteItem = deleteItem
    }

    static func query(_ reference: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword,
                kSecAttrService: LMStudioKeychainAuthorization.service,
                kSecAttrAccount: reference,
                kSecUseAuthenticationContext: context]
    }

    public func insert(token: String, reference: String) throws {
        var item = Self.query(reference)
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard addItem(item as CFDictionary) == errSecSuccess else {
            throw ProviderConfigurationError.credentialUnavailable
        }
    }

    public func remove(reference: String) throws {
        let status = deleteItem(Self.query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderConfigurationError.credentialUnavailable
        }
    }
}

/// Uses LM Studio's supported CLI to discover or start its local HTTP server.
/// Process execution is direct (never through a shell), bounded, cancellable,
/// and kept off the actor executor because the shared process runner is
/// intentionally synchronous.
struct LMStudioLocalServerController: Sendable {
    typealias Command = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval
    ) async throws -> ProcessResult
    typealias Delay = @Sendable (_ duration: Duration) async throws -> Void

    private struct Status: Decodable {
        let running: Bool
        let port: Int?

        private enum CodingKeys: String, CodingKey {
            case running
            case port
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            running = try container.decode(Bool.self, forKey: .running)
            if let integerPort = try? container.decode(Int.self, forKey: .port) {
                port = integerPort
            } else if let stringPort = try? container.decode(String.self, forKey: .port) {
                port = Int(stringPort)
            } else {
                port = nil
            }
        }
    }

    private enum StatusObservation {
        case running(port: Int)
        case stopped
        case unusable
    }

    private static let maximumExecutableCandidates = 6
    private static let maximumOutputBytes = 8 * 1_024
    private static let statusTimeoutSeconds: TimeInterval = 1.5
    private static let startTimeoutSeconds: TimeInterval = 8
    private static let readinessDelays: [Duration] = [
        .zero,
        .milliseconds(150),
        .milliseconds(350),
        .milliseconds(750),
    ]

    private let discoverExecutables: @Sendable () -> [String]
    private let command: Command
    private let delay: Delay

    init(runner: ProcessRunner = ProcessRunner()) {
        discoverExecutables = {
            Self.executablePaths(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                discoveredPath: ProcessRunner.which("lms"),
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
            )
        }
        command = { executable, arguments, timeoutSeconds in
            let cancellation = ToolCallCancellation(timeoutSeconds: timeoutSeconds)
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try runner.run(
                        executable: executable,
                        arguments: arguments,
                        timeoutSec: timeoutSeconds,
                        maximumOutputBytes: Self.maximumOutputBytes,
                        cancellation: cancellation
                    )
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        }
        delay = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        discoverExecutables: @escaping @Sendable () -> [String],
        command: @escaping Command,
        delay: @escaping Delay = { try await Task.sleep(for: $0) }
    ) {
        self.discoverExecutables = discoverExecutables
        self.command = command
        self.delay = delay
    }

    func ensureRunningPort() async throws -> Int {
        let executables = Array(
            discoverExecutables().prefix(Self.maximumExecutableCandidates)
        )
        guard !executables.isEmpty else {
            throw ProviderConfigurationError.offline
        }

        var stoppedExecutables: [String] = []
        var unusableExecutables: [String] = []
        for executable in executables {
            try Task.checkCancellation()
            switch try await status(executable: executable) {
            case .running(let port):
                return port
            case .stopped:
                stoppedExecutables.append(executable)
            case .unusable:
                unusableExecutables.append(executable)
            }
        }

        // Prefer a CLI that understood the status contract. If none did, retain
        // one bounded attempt with the app-matched first candidate: some lms
        // releases have reported the server as unavailable while start was still
        // able to wake it and report the bound port.
        let startupCandidates = stoppedExecutables + unusableExecutables
        for executable in startupCandidates.prefix(1) {
            if let port = try await startAndResolvePort(executable: executable) {
                return port
            }
        }
        throw ProviderConfigurationError.offline
    }

    private func startAndResolvePort(executable: String) async throws -> Int? {
        let start: ProcessResult
        do {
            start = try await command(
                executable,
                ["server", "start"],
                Self.startTimeoutSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard !start.timedOut, !start.stdoutTruncated, !start.stderrTruncated else {
            return nil
        }

        let startReportedPort = Self.portFromStartOutput(
            start.stdout + "\n" + start.stderr
        )
        for readinessDelay in Self.readinessDelays {
            try Task.checkCancellation()
            if readinessDelay > .zero {
                try await delay(readinessDelay)
            }
            if case .running(let port) = try await status(executable: executable) {
                return port
            }
        }

        // The normal HTTP inventory transport verifies this loopback port before
        // the Manager may persist it. Retaining the CLI's bounded start result
        // avoids a false offline result when lms starts the server successfully
        // but its own status command briefly lags or misreports readiness.
        return startReportedPort
    }

    private func status(executable: String) async throws -> StatusObservation {
        let result: ProcessResult
        do {
            result = try await command(
                executable,
                ["server", "status", "--json", "--quiet"],
                Self.statusTimeoutSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unusable
        }
        guard !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated else {
            return .unusable
        }
        guard result.exitCode == 0,
              let status = Self.decodeStatus(from: result.stdout) else {
            return .unusable
        }
        guard status.running else { return .stopped }
        guard let port = status.port, (1...65_535).contains(port) else {
            return .unusable
        }
        return .running(port: port)
    }

    private static func decodeStatus(from output: String) -> Status? {
        guard output.utf8.count <= maximumOutputBytes else { return nil }
        var candidates = output.split(whereSeparator: \Character.isNewline).reversed().map(String.init)
        candidates.append(output)
        for candidate in candidates {
            let json: Substring
            if let start = candidate.firstIndex(of: "{"),
               let end = candidate.lastIndex(of: "}"), start <= end {
                json = candidate[start...end]
            } else {
                continue
            }
            guard let data = String(json).data(using: .utf8) else { continue }
            if let status = try? JSONDecoder().decode(Status.self, from: data) {
                return status
            }
        }
        return nil
    }

    private static func portFromStartOutput(_ output: String) -> Int? {
        let tokens = output.split { !$0.isLetter && !$0.isNumber }
        guard tokens.count >= 2 else { return nil }
        for index in tokens.indices.dropLast() where tokens[index].lowercased() == "port" {
            guard let port = Int(tokens[tokens.index(after: index)]),
                  (1...65_535).contains(port) else { continue }
            return port
        }
        return nil
    }

    static func executablePaths(
        homeDirectory: URL,
        discoveredPath: String?,
        isExecutable: (String) -> Bool
    ) -> [String] {
        let systemApplication = URL(fileURLWithPath: "/Applications/LM Studio.app", isDirectory: true)
        let userApplication = homeDirectory.appendingPathComponent(
            "Applications/LM Studio.app",
            isDirectory: true
        )
        let bundledRelativePaths = [
            "Contents/Resources/app/.webpack/lms",
            "Contents/Resources/app.asar.unpacked/.webpack/lms",
        ]
        var candidates = [systemApplication, userApplication].flatMap { application in
            bundledRelativePaths.map { application.appendingPathComponent($0).path }
        }
        candidates += [
            discoveredPath,
            homeDirectory.appendingPathComponent(".lmstudio/bin/lms").path,
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms",
        ].compactMap { $0 }

        var visited = Set<String>()
        return candidates.filter { path in
            let canonical = URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            return visited.insert(canonical).inserted && isExecutable(path)
        }
    }
}

/// One manager-owned actor serializes settings transactions. Its bounded journal
/// contains only opaque references. Recovery reads the committed configuration
/// before deleting anything, preserving credentials after ambiguous file commits.
public actor LMStudioConfigurationService: ProviderConfigurationServicing {
    public typealias Persist = @Sendable (Data, URL) throws -> Void
    public typealias Inventory = @Sendable (LMStudioProviderConfiguration) async throws -> [LMStudioModel]
    typealias LocalServerRecovery = @Sendable () async throws -> Int
    private struct CredentialIntent: Codable {
        let oldReference: String?
        let newReference: String?
    }

    private let directory: URL
    private let credentials: any LMStudioCredentialStoring
    private let persist: Persist
    private let inventory: Inventory
    private let localServerRecovery: LocalServerRecovery
    private var modelRequestInProgress = false

    public init(storageDirectory: URL,
                credentials: any LMStudioCredentialStoring = LMStudioKeychainCredentialStore(),
                persist: @escaping Persist = { try OwnerOnlyAtomicFile.write($0, to: $1) },
                inventory: @escaping Inventory = { configuration in
                    let authorization: any LMStudioAuthorizationProviding
                    if let reference = configuration.keychainTokenReference {
                        authorization = try LMStudioKeychainAuthorization(reference: reference)
                    } else {
                        authorization = LMStudioNoAuthorization()
                    }
                    return try await LMStudioRESTClient(configuration: configuration, authorization: authorization).listModels()
                }) {
        self.init(
            storageDirectory: storageDirectory,
            credentials: credentials,
            persist: persist,
            inventory: inventory,
            localServerRecovery: {
                try await LMStudioLocalServerController().ensureRunningPort()
            }
        )
    }

    init(storageDirectory: URL,
         credentials: any LMStudioCredentialStoring = LMStudioKeychainCredentialStore(),
         persist: @escaping Persist = { try OwnerOnlyAtomicFile.write($0, to: $1) },
         inventory: @escaping Inventory,
         localServerRecovery: @escaping LocalServerRecovery) {
        directory = storageDirectory; self.credentials = credentials
        self.persist = persist; self.inventory = inventory
        self.localServerRecovery = localServerRecovery
    }

    private var configurationURL: URL { directory.appendingPathComponent(LMStudioProviderConfiguration.fileName) }
    private var journalURL: URL { directory.appendingPathComponent("provider-credential-intent.json") }

    public func read() throws -> ProviderConfigurationSnapshot {
        try withStorageLock { try readLocked() }
    }

    private func readLocked() throws -> ProviderConfigurationSnapshot {
        let configuration = try load()
        let pending = !recoverCredentials(configuration)
        return snapshot(configuration, cleanupPending: pending)
    }

    public func update(_ request: ProviderConfigurationUpdate) throws -> ProviderConfigurationSnapshot {
        try withStorageLock { try updateLocked(request) }
    }

    private func updateLocked(_ request: ProviderConfigurationUpdate) throws -> ProviderConfigurationSnapshot {
        try Task.checkCancellation()
        guard !modelRequestInProgress else { throw ProviderConfigurationError.busy }
        guard request.expectedRevision.utf8.count <= 36,
              request.endpoint.utf8.count <= 2048,
              let endpoint = URL(string: request.endpoint),
              request.token == nil || request.credentialAction == .replace else {
            throw ProviderConfigurationError.invalidRequest
        }
        if request.credentialAction == .replace {
            guard let token = request.token, !token.isEmpty, token.utf8.count <= 8192,
                  !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ProviderConfigurationError.invalidRequest
            }
        }
        let previous = try load()
        guard request.expectedRevision == (previous?.revision ?? "0") else {
            throw ProviderConfigurationError.revisionConflict
        }
        var next = previous ?? LMStudioProviderConfiguration()
        next.baseURL = endpoint
        next.modelKey = request.modelKey
        next.revision = UUID().uuidString.lowercased()
        if request.credentialAction == .clear { next.keychainTokenReference = nil }
        if request.credentialAction == .replace {
            next.keychainTokenReference = "provider-" + next.revision
        }
        do { _ = try next.validated() } catch { throw ProviderConfigurationError.invalidRequest }
        guard recoverCredentials(previous) else { throw ProviderConfigurationError.credentialUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= LMStudioProviderConfiguration.maximumFileBytes else {
            throw ProviderConfigurationError.invalidRequest
        }
        let changesCredential = request.credentialAction != .keep
        if changesCredential {
            let intent = CredentialIntent(oldReference: previous?.keychainTokenReference,
                                          newReference: next.keychainTokenReference)
            do { try persist(encoder.encode(intent), journalURL) }
            catch { throw ProviderConfigurationError.persistenceFailed }
            if let token = request.token, let reference = next.keychainTokenReference {
                do { try credentials.insert(token: token, reference: reference) }
                catch {
                    _ = recoverCredentials(previous)
                    throw ProviderConfigurationError.credentialUnavailable
                }
            }
        }
        do {
            try Task.checkCancellation()
            try persist(data, configurationURL)
        } catch {
            // Never acknowledge durability after an ambiguous rename/fsync error.
            // Keep both references until a later read durably reconciles the file.
            throw ProviderConfigurationError.persistenceFailed
        }
        return snapshot(next, cleanupPending: !recoverCredentials(next))
    }

    public func models() async throws -> ProviderModelInventory {
        guard !modelRequestInProgress else { throw ProviderConfigurationError.busy }
        guard var configuration = try load() else { throw ProviderConfigurationError.unavailable }
        modelRequestInProgress = true
        defer { modelRequestInProgress = false }
        configuration.totalTimeoutSeconds = min(configuration.totalTimeoutSeconds, 15)
        configuration.firstByteTimeoutSeconds = min(configuration.firstByteTimeoutSeconds, 10)
        let models: [LMStudioModel]
        do { models = try await inventory(configuration) }
        catch is CancellationError { throw CancellationError() }
        catch let error as LMStudioProviderError {
            switch error {
            case .unauthorized, .forbidden: throw ProviderConfigurationError.authenticationFailed
            case .providerUnavailable: throw ProviderConfigurationError.offline
            case .deadlineExceeded: throw ProviderConfigurationError.timeout
            case .endpointNotFound: throw ProviderConfigurationError.modelEndpointUnavailable
            case .invalidConfiguration: throw ProviderConfigurationError.credentialUnavailable
            case .cancelled: throw CancellationError()
            default: throw ProviderConfigurationError.connectionFailed
            }
        } catch { throw ProviderConfigurationError.connectionFailed }
        try Task.checkCancellation()
        guard models.count <= 512, models.allSatisfy({
            !$0.key.isEmpty && $0.key.utf8.count <= 512 && !$0.key.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        }) else { throw ProviderConfigurationError.invalidRequest }
        return ProviderModelInventory(revision: configuration.revision, models: models.map {
            ProviderAvailableModel(key: $0.key, loaded: !$0.loadedInstances.isEmpty,
                                   toolUseCapable: $0.capabilities?.trainedForToolUse == true)
        })
    }

    /// Recovers only an HTTP loopback LM Studio origin after the Manager has
    /// observed a transport-level offline failure. The CLI-reported port is the
    /// only alternate port considered; Forge never scans the host. Every
    /// candidate is verified with the normal authenticated inventory transport
    /// before the Manager is allowed to persist it.
    public func recoverConnection() async throws -> ProviderConnectionRecovery {
        guard !modelRequestInProgress else { throw ProviderConfigurationError.busy }
        guard let configuration = try load() else { throw ProviderConfigurationError.unavailable }
        guard Self.isRecoverableLocalOrigin(configuration.baseURL) else {
            throw ProviderConfigurationError.offline
        }
        modelRequestInProgress = true
        defer { modelRequestInProgress = false }

        let port: Int
        do {
            port = try await localServerRecovery()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderConfigurationError.offline
        }
        try Task.checkCancellation()

        var observedTimeout = false
        for endpoint in Self.localCandidateEndpoints(configuration.baseURL, reportedPort: port) {
            var candidate = configuration
            candidate.baseURL = endpoint
            candidate.connectTimeoutSeconds = min(candidate.connectTimeoutSeconds, 1.5)
            candidate.firstByteTimeoutSeconds = min(candidate.firstByteTimeoutSeconds, 2)
            candidate.idleTimeoutSeconds = min(candidate.idleTimeoutSeconds, 2)
            candidate.totalTimeoutSeconds = min(candidate.totalTimeoutSeconds, 3)
            do {
                let models = try await inventory(candidate)
                try Task.checkCancellation()
                let mapped = try Self.validatedInventory(models, revision: configuration.revision)
                return ProviderConnectionRecovery(
                    endpoint: endpoint == configuration.baseURL
                        ? configuration.baseURL.absoluteString
                        : endpoint.absoluteString,
                    inventory: mapped
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LMStudioProviderError {
                switch error {
                case .providerUnavailable:
                    continue
                case .deadlineExceeded:
                    observedTimeout = true
                    continue
                default:
                    throw Self.configurationError(for: error)
                }
            } catch {
                throw ProviderConfigurationError.connectionFailed
            }
        }
        throw observedTimeout ? ProviderConfigurationError.timeout : ProviderConfigurationError.offline
    }

    private static func isRecoverableLocalOrigin(_ endpoint: URL) -> Bool {
        guard endpoint.scheme?.lowercased() == "http",
              let host = endpoint.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func localCandidateEndpoints(_ configured: URL, reportedPort: Int) -> [URL] {
        guard (1...65_535).contains(reportedPort), let configuredHost = configured.host else { return [] }
        let configuredPort = configured.port ?? 80
        var endpoints: [URL] = configuredPort == reportedPort ? [configured] : []
        for host in [configuredHost, "127.0.0.1", "::1"] {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = reportedPort
            if let endpoint = components.url { endpoints.append(endpoint) }
        }
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func validatedInventory(
        _ models: [LMStudioModel],
        revision: String
    ) throws -> ProviderModelInventory {
        guard models.count <= 512, models.allSatisfy({
            !$0.key.isEmpty && $0.key.utf8.count <= 512 && !$0.key.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        }) else { throw ProviderConfigurationError.invalidRequest }
        return ProviderModelInventory(revision: revision, models: models.map {
            ProviderAvailableModel(
                key: $0.key,
                loaded: !$0.loadedInstances.isEmpty,
                toolUseCapable: $0.capabilities?.trainedForToolUse == true
            )
        })
    }

    private static func configurationError(for error: LMStudioProviderError) -> ProviderConfigurationError {
        switch error {
        case .unauthorized, .forbidden: .authenticationFailed
        case .providerUnavailable: .offline
        case .deadlineExceeded: .timeout
        case .endpointNotFound: .modelEndpointUnavailable
        case .invalidConfiguration: .credentialUnavailable
        case .cancelled: .connectionFailed
        default: .connectionFailed
        }
    }

    private func withStorageLock<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ProviderConfigurationError.persistenceFailed }
        let path = directory.appendingPathComponent("provider-configuration.lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ProviderConfigurationError.persistenceFailed }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600 else {
            throw ProviderConfigurationError.persistenceFailed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ProviderConfigurationError.busy }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func load() throws -> LMStudioProviderConfiguration? {
        do { return try LMStudioProviderConfiguration.loadIfPresent(in: directory) }
        catch { throw ProviderConfigurationError.persistenceFailed }
    }

    private func snapshot(_ configuration: LMStudioProviderConfiguration?, cleanupPending: Bool) -> ProviderConfigurationSnapshot {
        ProviderConfigurationSnapshot(revision: configuration?.revision ?? "0",
            endpoint: configuration?.baseURL.absoluteString ?? "http://127.0.0.1:1234",
            modelKey: configuration?.modelKey,
            credentialConfigured: configuration?.keychainTokenReference != nil,
            saved: configuration != nil, credentialCleanupPending: cleanupPending)
    }

    private func recoverCredentials(_ configuration: LMStudioProviderConfiguration?) -> Bool {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return true }
        do {
            let data = try OwnerOnlyAtomicFile.read(from: journalURL, maximumBytes: 4096)
            // A cleared journal is a durable tombstone; it avoids an unlink/fsync
            // ambiguity and occupies one bounded file across all updates.
            if data == Data("{}".utf8) { return true }
            let intent = try JSONDecoder().decode(CredentialIntent.self, from: data)
            if let configuration {
                // Make an observed post-rename revision durable before discarding
                // either credential; read-back alone is not a persistence proof.
                try persist(JSONEncoder().encode(configuration), configurationURL)
            }
            for reference in Set([intent.oldReference, intent.newReference].compactMap { $0 }) {
                guard reference.utf8.count <= 512 else { return false }
                if reference != configuration?.keychainTokenReference {
                    try credentials.remove(reference: reference)
                }
            }
            try persist(Data("{}".utf8), journalURL)
            return true
        } catch { return false }
    }
}
