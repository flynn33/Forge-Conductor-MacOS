import Foundation

/// Redacted configuration shared by the manager and native client. Revision is an
/// opaque compare-and-swap token, including across manager restarts.
public struct ProviderConfigurationSnapshot: Codable, Sendable, Equatable {
    public let revision: String
    public let endpoint: String
    public let modelKey: String?
    public let credentialConfigured: Bool
    public let saved: Bool
    public let credentialCleanupPending: Bool

    public init(revision: String, endpoint: String, modelKey: String?, credentialConfigured: Bool,
                saved: Bool, credentialCleanupPending: Bool = false) {
        self.revision = revision; self.endpoint = endpoint; self.modelKey = modelKey
        self.credentialConfigured = credentialConfigured; self.saved = saved
        self.credentialCleanupPending = credentialCleanupPending
    }
}

public enum ProviderCredentialAction: String, Codable, Sendable, CaseIterable {
    case keep, replace, clear
}

/// Token material is transient request input and must never be logged or encoded
/// into provider configuration, receipts, or diagnostic snapshots.
public struct ProviderConfigurationUpdate: Codable, Sendable {
    public let expectedRevision: String
    public let endpoint: String
    public let modelKey: String?
    public let credentialAction: ProviderCredentialAction
    public let token: String?

    public init(expectedRevision: String, endpoint: String, modelKey: String?,
                credentialAction: ProviderCredentialAction = .keep, token: String? = nil) {
        self.expectedRevision = expectedRevision; self.endpoint = endpoint; self.modelKey = modelKey
        self.credentialAction = credentialAction; self.token = token
    }
}

public struct ProviderAvailableModel: Codable, Sendable, Equatable {
    public let key: String
    public let loaded: Bool
    public let toolUseCapable: Bool
    public init(key: String, loaded: Bool, toolUseCapable: Bool) {
        self.key = key; self.loaded = loaded; self.toolUseCapable = toolUseCapable
    }
}

public struct ProviderModelInventory: Codable, Sendable, Equatable {
    public let revision: String
    public let models: [ProviderAvailableModel]
    public init(revision: String, models: [ProviderAvailableModel]) {
        self.revision = revision; self.models = models
    }
}

public enum ProviderConfigurationError: String, Error, LocalizedError, Sendable {
    case unavailable, invalidRequest, revisionConflict, busy, credentialUnavailable, persistenceFailed
    case authenticationFailed, offline, timeout, modelEndpointUnavailable, connectionFailed
    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: "LM Studio rejected or denied the credential. Replace the token or verify server permissions."
        case .offline: "LM Studio is offline or unreachable. Start its server and verify the saved endpoint."
        case .timeout: "LM Studio timed out. Check the server and network, then retry."
        case .modelEndpointUnavailable: "The LM Studio model inventory endpoint is unavailable. Verify the server version and saved endpoint."
        case .connectionFailed: "LM Studio returned an invalid or unsupported response. Verify the server version and try again."
        case .unavailable: "Provider configuration is unavailable. Restart the manager from this build."
        case .invalidRequest: "Invalid provider settings. Use an HTTP loopback or HTTPS origin, a bounded model identifier, and a valid credential action."
        case .revisionConflict: "Provider settings changed. Refresh before saving again."
        case .busy: "Provider settings are busy. Finish or cancel active runs and wait for provider requests to settle, then retry."
        case .credentialUnavailable: "Keychain access failed or was denied. Unlock the login Keychain and retry. The last committed configuration is retained."
        case .persistenceFailed: "Provider settings could not be committed safely. Refresh to reconcile the saved revision before retrying."
        }
    }
}

public protocol ProviderConfigurationServicing: Sendable {
    func read() async throws -> ProviderConfigurationSnapshot
    func update(_ request: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot
    func models() async throws -> ProviderModelInventory
}
