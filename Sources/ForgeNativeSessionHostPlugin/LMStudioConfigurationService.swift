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

/// One manager-owned actor serializes settings transactions. Its bounded journal
/// contains only opaque references. Recovery reads the committed configuration
/// before deleting anything, preserving credentials after ambiguous file commits.
public actor LMStudioConfigurationService: ProviderConfigurationServicing {
    public typealias Persist = @Sendable (Data, URL) throws -> Void
    public typealias Inventory = @Sendable (LMStudioProviderConfiguration) async throws -> [LMStudioModel]
    private struct CredentialIntent: Codable {
        let oldReference: String?
        let newReference: String?
    }

    private let directory: URL
    private let credentials: any LMStudioCredentialStoring
    private let persist: Persist
    private let inventory: Inventory
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
        directory = storageDirectory; self.credentials = credentials
        self.persist = persist; self.inventory = inventory
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
