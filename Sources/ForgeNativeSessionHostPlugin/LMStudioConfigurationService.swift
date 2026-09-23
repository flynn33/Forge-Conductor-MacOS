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
    private struct Status: Decodable {
        let running: Bool
        let port: Int?
    }

    private let runner: ProcessRunner

    init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    func ensureRunningPort() async throws -> Int {
        guard let executable = Self.executablePath() else {
            throw ProviderConfigurationError.offline
        }
        if let port = try await status(executable: executable) {
            return port
        }

        let start = try await run(
            executable: executable,
            arguments: ["server", "start"],
            timeoutSeconds: 8
        )
        guard !start.timedOut, !start.stdoutTruncated, !start.stderrTruncated,
              start.exitCode == 0 else {
            throw ProviderConfigurationError.offline
        }
        try Task.checkCancellation()
        guard let port = try await status(executable: executable) else {
            throw ProviderConfigurationError.offline
        }
        return port
    }

    private func status(executable: String) async throws -> Int? {
        let result = try await run(
            executable: executable,
            arguments: ["server", "status", "--json", "--quiet"],
            timeoutSeconds: 4
        )
        guard !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated else {
            throw ProviderConfigurationError.offline
        }
        guard result.exitCode == 0 else { return nil }
        guard let data = result.stdout.data(using: .utf8), data.count <= 8 * 1_024,
              let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw ProviderConfigurationError.offline
        }
        guard status.running else { return nil }
        guard let port = status.port, (1...65_535).contains(port) else {
            throw ProviderConfigurationError.offline
        }
        return port
    }

    private func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> ProcessResult {
        let cancellation = ToolCallCancellation(timeoutSeconds: timeoutSeconds)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runner.run(
                    executable: executable,
                    arguments: arguments,
                    timeoutSec: timeoutSeconds,
                    maximumOutputBytes: 8 * 1_024,
                    cancellation: cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func executablePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".lmstudio/bin/lms").path,
            "/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms",
            home.appendingPathComponent(
                "Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"
            ).path,
        ]
        if let discovered = ProcessRunner.which("lms") {
            candidates.append(discovered)
        }
        var visited = Set<String>()
        return candidates.first { path in
            visited.insert(path).inserted && FileManager.default.isExecutableFile(atPath: path)
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
