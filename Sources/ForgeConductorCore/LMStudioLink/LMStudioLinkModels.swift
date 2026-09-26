// LMStudioLinkModels.swift
// What: Defines the transport-independent Forge LM Studio Link wire and persistence domain.
// How: Strict Codable value types share one set of bounds, enums, revisions, and redacted views.
// Why: Discovery, pairing, transport, UI, and the Linux companion must agree before opening sockets.

import Foundation
import OSLog

public enum LMStudioLinkLimits {
    public static let maximumRetainedNodes = 16
    public static let maximumDiscoveryCandidates = 32
    public static let maximumDisplayNameBytes = 64
    public static let maximumHostBytes = 255
    public static let maximumOriginBytes = 512
    public static let maximumCredentialReferenceBytes = 512
    public static let maximumCapabilityCount = 64
    public static let maximumDiscoveryCapabilityCount = 32
    public static let maximumCapabilityBytes = 64
    public static let maximumScopeCount = 16
    public static let maximumScopeBytes = 64
    public static let minimumNonceBytes = 32
    public static let maximumNonceBytes = 128
    public static let minimumPairingCodeBytes = 8
    public static let maximumPairingCodeBytes = 32
    public static let maximumProtocolVersionBytes = 32
    public static let maximumVersionBytes = 64
    public static let maximumAPIStateCount = 8
    public static let maximumProxyPathCount = 32
    public static let maximumControlActionCount = 64
    public static let maximumMCPVersionCount = 16
    public static let maximumRouteBytes = 128
    public static let maximumErrorCodeBytes = 64
    public static let maximumDetailBytes = 1_024
    public static let maximumRetryAfterMilliseconds: UInt64 = 600_000
    public static let maximumRegistryBytes = 256 * 1_024
    public static let maximumPairingAttempts = 5
    public static let pairingLifetimeSeconds: TimeInterval = 5 * 60
    public static let maximumControlBodyBytes = 256 * 1_024
    public static let maximumDiagnosticBytes = 1 * 1_024 * 1_024
}

public enum LMStudioLinkLog {
    private static let subsystem = "com.forge-conductor.lmstudio-link"
    public static let registry = Logger(subsystem: subsystem, category: "registry")
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let pairing = Logger(subsystem: subsystem, category: "pairing")
    public static let transport = Logger(subsystem: subsystem, category: "transport")
    public static let control = Logger(subsystem: subsystem, category: "control")
}

public struct LMStudioLinkNodeID: RawRepresentable, Codable, Hashable, Sendable,
                                  CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "LM Studio Link node identifier must be a UUID."
            )
        }
        rawValue = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum LMStudioEndpointMode: Sendable, Equatable, Codable {
    case local
    case linked(nodeID: LMStudioLinkNodeID)

    private enum CodingKeys: String, CodingKey {
        case mode
        case nodeID = "node_id"
    }

    private enum Mode: String, Codable {
        case local
        case linked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Mode.self, forKey: .mode) {
        case .local:
            guard !values.contains(.nodeID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nodeID,
                    in: values,
                    debugDescription: "Local LM Studio mode cannot name a linked node."
                )
            }
            self = .local
        case .linked:
            self = .linked(nodeID: try values.decode(LMStudioLinkNodeID.self, forKey: .nodeID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try values.encode(Mode.local, forKey: .mode)
        case .linked(let nodeID):
            try values.encode(Mode.linked, forKey: .mode)
            try values.encode(nodeID, forKey: .nodeID)
        }
    }

    public var linkedNodeID: LMStudioLinkNodeID? {
        guard case .linked(let nodeID) = self else { return nil }
        return nodeID
    }
}

public enum LMStudioLinkNodeState: String, Codable, Sendable, CaseIterable {
    case active
    case inactive
    case revoked
}

public struct LMStudioLinkCandidate: Sendable, Equatable, Identifiable {
    public let id: LMStudioLinkNodeID
    public let displayName: String
    public let host: String
    public let port: UInt16
    public let apiVersion: UInt16
    public let abbreviatedSPKISHA256: String
    public let lastSeenAt: Date

    public init(
        id: LMStudioLinkNodeID,
        displayName: String,
        host: String,
        port: UInt16,
        apiVersion: UInt16,
        abbreviatedSPKISHA256: String,
        lastSeenAt: Date
    ) throws {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.apiVersion = apiVersion
        self.abbreviatedSPKISHA256 = abbreviatedSPKISHA256
        self.lastSeenAt = lastSeenAt
        try LMStudioLinkValidation.validateText(
            displayName,
            maximumBytes: LMStudioLinkLimits.maximumDisplayNameBytes,
            field: "display_name"
        )
        try LMStudioLinkValidation.validateText(
            host,
            maximumBytes: LMStudioLinkLimits.maximumHostBytes,
            field: "host"
        )
        guard port > 0, apiVersion > 0 else { throw LMStudioLinkValidationError.invalidPort }
        guard abbreviatedSPKISHA256.utf8.count == 16,
              abbreviatedSPKISHA256.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw LMStudioLinkValidationError.invalidSHA256(field: "abbreviated_spki_sha256")
        }
    }
}

public enum LMStudioLinkScope: String, Codable, Sendable, CaseIterable {
    case proxyModelsRead = "proxy:models:read"
    case proxyInference = "proxy:inference"
    case controlServer = "control:server"
    case controlModels = "control:models"
    case diagnosticsRead = "diagnostics:read"
    case registrationRepair = "registration:repair"
}

public enum LMStudioLinkMCPRole: String, Codable, Sendable, CaseIterable {
    case primary
    case fallback
    case clu

    public var route: String { "/mcp/\(rawValue)" }
}

public struct LMStudioLinkRoleEndpoint: Codable, Sendable, Equatable {
    public let role: LMStudioLinkMCPRole
    public let path: String
    public let credentialReference: String

    public init(
        role: LMStudioLinkMCPRole,
        path: String? = nil,
        credentialReference: String
    ) throws {
        self.role = role
        self.path = path ?? role.route
        self.credentialReference = credentialReference
        try validate()
    }

    public func validate() throws {
        guard path == role.route else { throw LMStudioLinkValidationError.invalidRoleEndpoint }
        try LMStudioLinkValidation.validateText(
            credentialReference,
            maximumBytes: LMStudioLinkLimits.maximumCredentialReferenceBytes,
            field: "credential_reference"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case path
        case credentialReference = "credential_reference"
    }
}

public struct LMStudioLinkNodeSnapshot: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = "forge-link-node/1"

    public let schemaVersion: String
    public let id: LMStudioLinkNodeID
    public let displayName: String
    public let origin: URL
    public let serviceName: String?
    public let spkiSHA256: String
    public let credentialReference: String
    public let capabilities: [String]
    public let protocolVersion: String
    public let peerGeneration: UInt64
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let lastVerifiedAt: Date?
    public let state: LMStudioLinkNodeState

    public init(
        id: LMStudioLinkNodeID,
        displayName: String,
        origin: URL,
        serviceName: String? = nil,
        spkiSHA256: String,
        credentialReference: String,
        capabilities: [String],
        protocolVersion: String = "forge-link/1",
        peerGeneration: UInt64 = 1,
        createdAt: Date,
        lastSeenAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        state: LMStudioLinkNodeState = .active
    ) throws {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.displayName = displayName
        self.origin = origin
        self.serviceName = serviceName
        self.spkiSHA256 = spkiSHA256
        self.credentialReference = credentialReference
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
        self.peerGeneration = peerGeneration
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.lastVerifiedAt = lastVerifiedAt
        self.state = state
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try LMStudioLinkValidation.validateText(
            displayName,
            maximumBytes: LMStudioLinkLimits.maximumDisplayNameBytes,
            field: "display_name"
        )
        try LMStudioLinkValidation.validateHTTPSOrigin(origin)
        if let serviceName {
            try LMStudioLinkValidation.validateText(
                serviceName,
                maximumBytes: LMStudioLinkLimits.maximumHostBytes,
                field: "service_name"
            )
        }
        try LMStudioLinkValidation.validateSHA256(spkiSHA256, field: "spki_sha256")
        try LMStudioLinkValidation.validateText(
            credentialReference,
            maximumBytes: LMStudioLinkLimits.maximumCredentialReferenceBytes,
            field: "credential_reference"
        )
        try LMStudioLinkValidation.validateText(
            protocolVersion,
            maximumBytes: LMStudioLinkLimits.maximumProtocolVersionBytes,
            field: "protocol_version"
        )
        try LMStudioLinkValidation.validateValues(
            capabilities,
            maximumCount: LMStudioLinkLimits.maximumCapabilityCount,
            maximumBytes: LMStudioLinkLimits.maximumCapabilityBytes,
            field: "capabilities"
        )
        guard peerGeneration > 0 else { throw LMStudioLinkValidationError.invalidPeerGeneration }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id = "node_id"
        case displayName = "display_name"
        case origin
        case serviceName = "service_name"
        case spkiSHA256 = "spki_sha256"
        case credentialReference = "credential_reference"
        case capabilities
        case protocolVersion = "protocol_version"
        case peerGeneration = "peer_generation"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case lastVerifiedAt = "last_verified_at"
        case state
    }
}

public struct LMStudioLinkDiscoveryRecord: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = "forge-link-discovery/1"
    public static let serviceType = "_forge-lms-link._tcp"

    public let schemaVersion: String
    public let serviceType: String
    public let id: LMStudioLinkNodeID
    public let displayName: String?
    public let host: String
    public let port: UInt16
    public let interfaceIndex: UInt32?
    public let spkiSHA256: String
    public let capabilities: [String]
    public let lastSeen: Date

    public init(
        id: LMStudioLinkNodeID,
        displayName: String? = nil,
        host: String,
        port: UInt16,
        interfaceIndex: UInt32? = nil,
        spkiSHA256: String,
        capabilities: [String],
        lastSeen: Date
    ) throws {
        schemaVersion = Self.schemaVersion
        serviceType = Self.serviceType
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.interfaceIndex = interfaceIndex
        self.spkiSHA256 = spkiSHA256
        self.capabilities = capabilities
        self.lastSeen = lastSeen
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(String.self, forKey: .schemaVersion)
        let serviceType = try values.decode(String.self, forKey: .serviceType)
        guard schemaVersion == Self.schemaVersion, serviceType == Self.serviceType else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try self.init(
            id: values.decode(LMStudioLinkNodeID.self, forKey: .id),
            displayName: values.decodeIfPresent(String.self, forKey: .displayName),
            host: values.decode(String.self, forKey: .host),
            port: values.decode(UInt16.self, forKey: .port),
            interfaceIndex: values.decodeIfPresent(UInt32.self, forKey: .interfaceIndex),
            spkiSHA256: values.decode(String.self, forKey: .spkiSHA256),
            capabilities: values.decode([String].self, forKey: .capabilities),
            lastSeen: values.decode(Date.self, forKey: .lastSeen)
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion, serviceType == Self.serviceType else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        if let displayName {
            try LMStudioLinkValidation.validateText(
                displayName,
                maximumBytes: LMStudioLinkLimits.maximumDisplayNameBytes,
                field: "display_name"
            )
        }
        try LMStudioLinkValidation.validateText(
            host,
            maximumBytes: LMStudioLinkLimits.maximumHostBytes,
            field: "host"
        )
        guard port > 0 else { throw LMStudioLinkValidationError.invalidPort }
        try LMStudioLinkValidation.validateSHA256(spkiSHA256, field: "spki_sha256")
        try LMStudioLinkValidation.validateValues(
            capabilities,
            maximumCount: LMStudioLinkLimits.maximumDiscoveryCapabilityCount,
            maximumBytes: LMStudioLinkLimits.maximumCapabilityBytes,
            field: "capabilities"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case serviceType = "service_type"
        case id = "instance_id"
        case displayName = "display_name"
        case host
        case port
        case interfaceIndex = "interface_index"
        case spkiSHA256 = "spki_sha256"
        case capabilities
        case lastSeen = "last_seen"
    }
}

public struct LMStudioLinkPairingChallenge: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let challengeID: UUID
    public let serverNonce: String
    public let expiresAt: Date
    public let spkiSHA256: String

    public init(challengeID: UUID, serverNonce: String, expiresAt: Date, spkiSHA256: String) throws {
        schemaVersion = "forge-link/1"
        self.challengeID = challengeID
        self.serverNonce = serverNonce
        self.expiresAt = expiresAt
        self.spkiSHA256 = spkiSHA256
        try LMStudioLinkValidation.validateText(
            serverNonce,
            maximumBytes: LMStudioLinkLimits.maximumNonceBytes,
            minimumBytes: LMStudioLinkLimits.minimumNonceBytes,
            field: "server_nonce"
        )
        try LMStudioLinkValidation.validateSHA256(spkiSHA256, field: "spki_sha256")
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case challengeID = "challenge_id"
        case serverNonce = "server_nonce"
        case expiresAt = "expires_at"
        case spkiSHA256 = "spki_sha256"
    }
}

public struct LMStudioLinkPairingRequest: Codable, Sendable, Equatable {
    public let forgeInstanceID: UUID
    public let forgeDisplayName: String
    public let clientNonce: String
    public let requestedScopes: [LMStudioLinkScope]

    public init(
        forgeInstanceID: UUID,
        forgeDisplayName: String,
        clientNonce: String,
        requestedScopes: [LMStudioLinkScope]
    ) throws {
        self.forgeInstanceID = forgeInstanceID
        self.forgeDisplayName = forgeDisplayName
        self.clientNonce = clientNonce
        self.requestedScopes = requestedScopes
        try LMStudioLinkValidation.validateText(
            forgeDisplayName,
            maximumBytes: LMStudioLinkLimits.maximumDisplayNameBytes,
            field: "forge_display_name"
        )
        try LMStudioLinkValidation.validateText(
            clientNonce,
            maximumBytes: LMStudioLinkLimits.maximumNonceBytes,
            minimumBytes: LMStudioLinkLimits.minimumNonceBytes,
            field: "client_nonce"
        )
        guard !requestedScopes.isEmpty,
              requestedScopes.count <= LMStudioLinkLimits.maximumScopeCount,
              Set(requestedScopes.map(\.rawValue)).count == requestedScopes.count else {
            throw LMStudioLinkValidationError.invalidCollection(field: "requested_scopes")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case forgeInstanceID = "forge_instance_id"
        case forgeDisplayName = "forge_display_name"
        case clientNonce = "client_nonce"
        case requestedScopes = "requested_scopes"
    }
}

/// Secret-bearing request body. It can be encoded for the pairing call but is not Decodable.
public struct LMStudioLinkPairingCompletionRequest: Encodable, Sendable {
    public let challengeID: UUID
    public let pairingCode: String
    public let clientNonce: String
    public let serverNonce: String
    public let fingerprintConfirmed: Bool

    public init(
        challengeID: UUID,
        pairingCode: String,
        clientNonce: String,
        serverNonce: String,
        fingerprintConfirmed: Bool
    ) throws {
        self.challengeID = challengeID
        self.pairingCode = pairingCode
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.fingerprintConfirmed = fingerprintConfirmed
        try LMStudioLinkValidation.validateText(
            pairingCode,
            maximumBytes: LMStudioLinkLimits.maximumPairingCodeBytes,
            minimumBytes: LMStudioLinkLimits.minimumPairingCodeBytes,
            field: "pairing_code"
        )
        for (value, field) in [(clientNonce, "client_nonce"), (serverNonce, "server_nonce")] {
            try LMStudioLinkValidation.validateText(
                value,
                maximumBytes: LMStudioLinkLimits.maximumNonceBytes,
                minimumBytes: LMStudioLinkLimits.minimumNonceBytes,
                field: field
            )
        }
        guard fingerprintConfirmed else {
            throw LMStudioLinkValidationError.fingerprintNotConfirmed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case pairingCode = "pairing_code"
        case clientNonce = "client_nonce"
        case serverNonce = "server_nonce"
        case fingerprintConfirmed = "fingerprint_confirmed"
    }
}

/// Redacted result committed after the one-time token has been installed in Keychain.
public struct LMStudioLinkPairingReceipt: Codable, Sendable, Equatable {
    public let challengeID: UUID
    public let nodeID: LMStudioLinkNodeID
    public let peerID: UUID
    public let grantedScopes: [LMStudioLinkScope]
    public let generation: UInt64
    public let completedAt: Date

    public init(
        challengeID: UUID,
        nodeID: LMStudioLinkNodeID,
        peerID: UUID,
        grantedScopes: [LMStudioLinkScope],
        generation: UInt64,
        completedAt: Date
    ) throws {
        self.challengeID = challengeID
        self.nodeID = nodeID
        self.peerID = peerID
        self.grantedScopes = grantedScopes
        self.generation = generation
        self.completedAt = completedAt
        guard !grantedScopes.isEmpty,
              grantedScopes.count <= LMStudioLinkLimits.maximumScopeCount,
              Set(grantedScopes.map(\.rawValue)).count == grantedScopes.count else {
            throw LMStudioLinkValidationError.invalidCollection(field: "granted_scopes")
        }
        guard generation > 0 else { throw LMStudioLinkValidationError.invalidPeerGeneration }
    }

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nodeID = "node_id"
        case peerID = "peer_id"
        case grantedScopes = "granted_scopes"
        case generation
        case completedAt = "completed_at"
    }
}

public enum LMStudioLinkPostPairHealth: String, Codable, Sendable, CaseIterable {
    case ready
    case degraded
}

/// Durable, redacted evidence matching pairing.schema.json.
public struct LMStudioLinkPairingEvidence: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let forgeInstanceID: UUID
    public let linkInstanceID: LMStudioLinkNodeID
    public let fingerprintConfirmed: Bool
    public let challengeID: UUID
    public let grantedScopes: [LMStudioLinkScope]
    public let completedAt: Date
    public let credentialReference: String?
    public let postPairHealth: LMStudioLinkPostPairHealth?

    public init(
        forgeInstanceID: UUID,
        linkInstanceID: LMStudioLinkNodeID,
        challengeID: UUID,
        grantedScopes: [LMStudioLinkScope],
        completedAt: Date,
        credentialReference: String? = nil,
        postPairHealth: LMStudioLinkPostPairHealth? = nil
    ) throws {
        schemaVersion = "forge-link-pairing-evidence/1"
        self.forgeInstanceID = forgeInstanceID
        self.linkInstanceID = linkInstanceID
        fingerprintConfirmed = true
        self.challengeID = challengeID
        self.grantedScopes = grantedScopes
        self.completedAt = completedAt
        self.credentialReference = credentialReference
        self.postPairHealth = postPairHealth
        try LMStudioLinkValidation.validateScopes(grantedScopes, field: "granted_scopes")
        if let credentialReference {
            try LMStudioLinkValidation.validateText(
                credentialReference,
                maximumBytes: LMStudioLinkLimits.maximumCredentialReferenceBytes,
                field: "credential_reference"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .schemaVersion) == "forge-link-pairing-evidence/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        guard try values.decode(Bool.self, forKey: .fingerprintConfirmed) else {
            throw LMStudioLinkValidationError.fingerprintNotConfirmed
        }
        guard let forgeInstanceID = UUID(
            uuidString: try values.decode(String.self, forKey: .forgeInstanceID)
        ), let challengeID = UUID(
            uuidString: try values.decode(String.self, forKey: .challengeID)
        ) else {
            throw LMStudioLinkValidationError.invalidUUID
        }
        try self.init(
            forgeInstanceID: forgeInstanceID,
            linkInstanceID: values.decode(LMStudioLinkNodeID.self, forKey: .linkInstanceID),
            challengeID: challengeID,
            grantedScopes: values.decode([LMStudioLinkScope].self, forKey: .grantedScopes),
            completedAt: values.decode(Date.self, forKey: .completedAt),
            credentialReference: values.decodeIfPresent(String.self, forKey: .credentialReference),
            postPairHealth: values.decodeIfPresent(LMStudioLinkPostPairHealth.self, forKey: .postPairHealth)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(forgeInstanceID.uuidString.lowercased(), forKey: .forgeInstanceID)
        try values.encode(linkInstanceID, forKey: .linkInstanceID)
        try values.encode(fingerprintConfirmed, forKey: .fingerprintConfirmed)
        try values.encode(challengeID.uuidString.lowercased(), forKey: .challengeID)
        try values.encode(grantedScopes, forKey: .grantedScopes)
        try values.encode(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(credentialReference, forKey: .credentialReference)
        try values.encodeIfPresent(postPairHealth, forKey: .postPairHealth)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case forgeInstanceID = "forge_instance_id"
        case linkInstanceID = "link_instance_id"
        case fingerprintConfirmed = "fingerprint_confirmed"
        case challengeID = "challenge_id"
        case grantedScopes = "granted_scopes"
        case completedAt = "completed_at"
        case credentialReference = "credential_reference"
        case postPairHealth = "post_pair_health"
    }
}

/// Token-bearing values deliberately do not conform to Codable, Equatable, or CustomStringConvertible.
public struct LMStudioLinkIssuedCredential: Decodable, Sendable {
    public let schemaVersion: String
    public let peerID: UUID
    public let token: String
    public let grantedScopes: [LMStudioLinkScope]
    public let generation: UInt64

    public init(peerID: UUID, token: String, grantedScopes: [LMStudioLinkScope], generation: UInt64) throws {
        schemaVersion = "forge-link/1"
        self.peerID = peerID
        self.token = token
        self.grantedScopes = grantedScopes
        self.generation = generation
        guard token.utf8.count >= 43, token.utf8.count <= 256 else {
            throw LMStudioLinkValidationError.invalidText(field: "token")
        }
        try LMStudioLinkValidation.validateScopes(grantedScopes, field: "granted_scopes")
        guard generation > 0 else { throw LMStudioLinkValidationError.invalidPeerGeneration }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .schemaVersion) == "forge-link/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try self.init(
            peerID: values.decode(UUID.self, forKey: .peerID),
            token: values.decode(String.self, forKey: .token),
            grantedScopes: values.decode([LMStudioLinkScope].self, forKey: .grantedScopes),
            generation: values.decode(UInt64.self, forKey: .generation)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case peerID = "peer_id"
        case token
        case grantedScopes = "granted_scopes"
        case generation
    }
}

public enum LMStudioLinkConnectorHealthState: String, Codable, Sendable, CaseIterable {
    case ready
    case degraded
}

public enum LMStudioLinkLMStudioHealthState: String, Codable, Sendable, CaseIterable {
    case ready
    case stopped
    case starting
    case unavailable
    case authenticationFailed = "authentication_failed"
}

public enum LMStudioLinkRegistrationHealthState: String, Codable, Sendable, CaseIterable {
    case ready
    case degraded
    case absent
}

public struct LMStudioLinkHealth: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let linkInstanceID: LMStudioLinkNodeID
    public let connector: LMStudioLinkConnectorHealthState
    public let lmstudio: LMStudioLinkLMStudioHealthState
    public let registration: LMStudioLinkRegistrationHealthState
    public let version: String?
    public let uptimeSeconds: UInt64?

    public init(
        linkInstanceID: LMStudioLinkNodeID,
        connector: LMStudioLinkConnectorHealthState,
        lmstudio: LMStudioLinkLMStudioHealthState,
        registration: LMStudioLinkRegistrationHealthState,
        version: String? = nil,
        uptimeSeconds: UInt64? = nil
    ) throws {
        schemaVersion = "forge-link/1"
        self.linkInstanceID = linkInstanceID
        self.connector = connector
        self.lmstudio = lmstudio
        self.registration = registration
        self.version = version
        self.uptimeSeconds = uptimeSeconds
        if let version {
            try LMStudioLinkValidation.validateText(
                version,
                maximumBytes: LMStudioLinkLimits.maximumVersionBytes,
                field: "version"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .schemaVersion) == "forge-link/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try self.init(
            linkInstanceID: values.decode(LMStudioLinkNodeID.self, forKey: .linkInstanceID),
            connector: values.decode(LMStudioLinkConnectorHealthState.self, forKey: .connector),
            lmstudio: values.decode(LMStudioLinkLMStudioHealthState.self, forKey: .lmstudio),
            registration: values.decode(LMStudioLinkRegistrationHealthState.self, forKey: .registration),
            version: values.decodeIfPresent(String.self, forKey: .version),
            uptimeSeconds: values.decodeIfPresent(UInt64.self, forKey: .uptimeSeconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case linkInstanceID = "link_instance_id"
        case connector
        case lmstudio
        case registration
        case version
        case uptimeSeconds = "uptime_seconds"
    }
}

public struct LMStudioLinkCapabilities: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let linkProtocol: String
    public let proxyPaths: [String]
    public let controlActions: [String]
    public let mcpVersions: [String]
    public let architecture: String
    public let lmsVersion: String?
    public let lmstudioVersion: String?

    public init(
        proxyPaths: [String],
        controlActions: [String],
        mcpVersions: [String],
        architecture: String,
        lmsVersion: String? = nil,
        lmstudioVersion: String? = nil,
        linkProtocol: String = "forge-link/1"
    ) throws {
        schemaVersion = "forge-link-capabilities/1"
        self.linkProtocol = linkProtocol
        self.proxyPaths = proxyPaths
        self.controlActions = controlActions
        self.mcpVersions = mcpVersions
        self.architecture = architecture
        self.lmsVersion = lmsVersion
        self.lmstudioVersion = lmstudioVersion
        guard linkProtocol == "forge-link/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try LMStudioLinkValidation.validateValues(proxyPaths, maximumCount: LMStudioLinkLimits.maximumProxyPathCount, maximumBytes: LMStudioLinkLimits.maximumRouteBytes, field: "proxy_paths")
        try LMStudioLinkValidation.validateValues(controlActions, maximumCount: LMStudioLinkLimits.maximumControlActionCount, maximumBytes: LMStudioLinkLimits.maximumRouteBytes, field: "control_actions")
        try LMStudioLinkValidation.validateValues(mcpVersions, maximumCount: LMStudioLinkLimits.maximumMCPVersionCount, maximumBytes: LMStudioLinkLimits.maximumProtocolVersionBytes, field: "mcp_versions")
        guard ["aarch64", "x86_64"].contains(architecture) else {
            throw LMStudioLinkValidationError.invalidArchitecture
        }
        for (value, field) in [(lmsVersion, "lms_version"), (lmstudioVersion, "lmstudio_version")] {
            if let value {
                try LMStudioLinkValidation.validateText(
                    value,
                    maximumBytes: LMStudioLinkLimits.maximumVersionBytes,
                    field: field
                )
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .schemaVersion) == "forge-link-capabilities/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try self.init(
            proxyPaths: values.decode([String].self, forKey: .proxyPaths),
            controlActions: values.decode([String].self, forKey: .controlActions),
            mcpVersions: values.decode([String].self, forKey: .mcpVersions),
            architecture: values.decode(String.self, forKey: .architecture),
            lmsVersion: values.decodeIfPresent(String.self, forKey: .lmsVersion),
            lmstudioVersion: values.decodeIfPresent(String.self, forKey: .lmstudioVersion),
            linkProtocol: values.decode(String.self, forKey: .linkProtocol)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case linkProtocol = "link_protocol"
        case proxyPaths = "proxy_paths"
        case controlActions = "control_actions"
        case mcpVersions = "mcp_versions"
        case architecture
        case lmsVersion = "lms_version"
        case lmstudioVersion = "lmstudio_version"
    }
}

public enum LMStudioLinkControlAction: String, Codable, Sendable, CaseIterable {
    case serverStart = "server_start"
    case serverStop = "server_stop"
    case serverRestart = "server_restart"
    case modelLoad = "model_load"
    case modelUnload = "model_unload"
    case modelDownload = "model_download"
    case repairRegistration = "repair_registration"
    case revokePeer = "revoke_peer"
}

public enum LMStudioLinkOperationPhase: String, Codable, Sendable, CaseIterable {
    case accepted
    case running
    case completed
    case failedRecoverable = "failed_recoverable"
    case failedTerminal = "failed_terminal"
    case cancelled
}

public struct LMStudioLinkControlRequest: Codable, Sendable, Equatable {
    public let nodeID: LMStudioLinkNodeID
    public let action: LMStudioLinkControlAction
    public let idempotencyKey: UUID
    public let modelKey: String?

    public init(
        nodeID: LMStudioLinkNodeID,
        action: LMStudioLinkControlAction,
        idempotencyKey: UUID,
        modelKey: String? = nil
    ) throws {
        self.nodeID = nodeID
        self.action = action
        self.idempotencyKey = idempotencyKey
        self.modelKey = modelKey
        if let modelKey {
            try LMStudioLinkValidation.validateText(modelKey, maximumBytes: 512, field: "model_key")
        }
        let modelAction = action == .modelLoad || action == .modelUnload || action == .modelDownload
        guard modelAction == (modelKey != nil) else {
            throw LMStudioLinkValidationError.invalidControlRequest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case action
        case idempotencyKey = "idempotency_key"
        case modelKey = "model_key"
    }
}

public struct LMStudioLinkOperationReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let operationID: UUID
    public let action: LMStudioLinkControlAction
    public let phase: LMStudioLinkOperationPhase
    public let detail: String?
    public let errorCode: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        operationID: UUID,
        action: LMStudioLinkControlAction,
        phase: LMStudioLinkOperationPhase,
        detail: String? = nil,
        errorCode: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        schemaVersion = "forge-link/1"
        self.operationID = operationID
        self.action = action
        self.phase = phase
        self.detail = detail
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        if let detail {
            try LMStudioLinkValidation.validateText(detail, maximumBytes: LMStudioLinkLimits.maximumDetailBytes, field: "detail", permitsEmpty: true)
        }
        if let errorCode {
            try LMStudioLinkValidation.validateText(errorCode, maximumBytes: LMStudioLinkLimits.maximumErrorCodeBytes, field: "error_code")
        }
        guard updatedAt >= createdAt else { throw LMStudioLinkValidationError.invalidTimestampOrder }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .schemaVersion) == "forge-link/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        try self.init(
            operationID: values.decode(UUID.self, forKey: .operationID),
            action: values.decode(LMStudioLinkControlAction.self, forKey: .action),
            phase: values.decode(LMStudioLinkOperationPhase.self, forKey: .phase),
            detail: values.decodeIfPresent(String.self, forKey: .detail),
            errorCode: values.decodeIfPresent(String.self, forKey: .errorCode),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operationID = "operation_id"
        case action
        case phase
        case detail
        case errorCode = "error_code"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public enum LMStudioLinkErrorCode: String, Codable, Sendable, CaseIterable {
    case invalidRequest = "invalid_request"
    case authenticationFailed = "authentication_failed"
    case authorizationDenied = "authorization_denied"
    case pairingUnavailable = "pairing_unavailable"
    case pairingCodeExpired = "pairing_code_expired"
    case pairingCodeInvalid = "pairing_code_invalid"
    case pairingRateLimited = "pairing_rate_limited"
    case fingerprintMismatch = "fingerprint_mismatch"
    case peerRevoked = "peer_revoked"
    case scopeMissing = "scope_missing"
    case idempotencyConflict = "idempotency_conflict"
    case busy
    case overloaded
    case lmstudioOffline = "lmstudio_offline"
    case lmstudioAuthenticationFailed = "lmstudio_authentication_failed"
    case lmstudioIncompatible = "lmstudio_incompatible"
    case upstreamTimeout = "upstream_timeout"
    case upstreamInvalidResponse = "upstream_invalid_response"
    case upstreamRedirectRejected = "upstream_redirect_rejected"
    case requestTooLarge = "request_too_large"
    case responseTooLarge = "response_too_large"
    case registrationConflict = "registration_conflict"
    case registrationMalformed = "registration_malformed"
    case mcpProtocolIncompatible = "mcp_protocol_incompatible"
    case mcpRoleDenied = "mcp_role_denied"
    case cancelled
    case internalError = "internal_error"

    public var retryable: Bool {
        switch self {
        case .pairingUnavailable, .pairingRateLimited, .busy, .overloaded,
             .lmstudioOffline, .upstreamTimeout, .cancelled:
            true
        default:
            false
        }
    }
}

public struct LMStudioLinkErrorDetail: Codable, Sendable, Equatable {
    public let code: LMStudioLinkErrorCode
    public let message: String
    public let retryable: Bool
    public let retryAfterMilliseconds: UInt64?

    public init(
        code: LMStudioLinkErrorCode,
        message: String,
        retryAfterMilliseconds: UInt64? = nil
    ) throws {
        self.code = code
        self.message = message
        retryable = code.retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
        try LMStudioLinkValidation.validateText(
            message,
            maximumBytes: LMStudioLinkLimits.maximumDetailBytes,
            field: "message"
        )
        guard retryAfterMilliseconds.map({ $0 <= LMStudioLinkLimits.maximumRetryAfterMilliseconds }) ?? true,
              retryable || retryAfterMilliseconds == nil else {
            throw LMStudioLinkValidationError.invalidRetryPolicy
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decode(LMStudioLinkErrorCode.self, forKey: .code)
        let retryable = try values.decode(Bool.self, forKey: .retryable)
        guard retryable == code.retryable else {
            throw LMStudioLinkValidationError.invalidRetryPolicy
        }
        try self.init(
            code: code,
            message: values.decode(String.self, forKey: .message),
            retryAfterMilliseconds: values.decodeIfPresent(UInt64.self, forKey: .retryAfterMilliseconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case retryAfterMilliseconds = "retry_after_ms"
    }
}

public struct LMStudioLinkErrorEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let requestID: UUID
    public let error: LMStudioLinkErrorDetail

    public init(requestID: UUID, error: LMStudioLinkErrorDetail) {
        schemaVersion = "forge-link/1"
        self.requestID = requestID
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .schemaVersion) == "forge-link/1" else {
            throw LMStudioLinkValidationError.unsupportedSchemaVersion
        }
        self.init(
            requestID: try values.decode(UUID.self, forKey: .requestID),
            error: try values.decode(LMStudioLinkErrorDetail.self, forKey: .error)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case error
    }
}

public enum LMStudioLinkValidationError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion
    case invalidText(field: String)
    case invalidCollection(field: String)
    case invalidHTTPSOrigin
    case invalidSHA256(field: String)
    case invalidPort
    case invalidPeerGeneration
    case invalidRoleEndpoint
    case invalidArchitecture
    case invalidTimestampOrder
    case fingerprintNotConfirmed
    case invalidControlRequest
    case invalidRetryPolicy
    case invalidUUID

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion: "The LM Studio Link schema version is unsupported."
        case .invalidText(let field): "The LM Studio Link \(field) value is invalid."
        case .invalidCollection(let field): "The LM Studio Link \(field) collection is invalid."
        case .invalidHTTPSOrigin: "A linked LM Studio node must use an HTTPS origin."
        case .invalidSHA256(let field): "The LM Studio Link \(field) digest is invalid."
        case .invalidPort: "The LM Studio Link port is invalid."
        case .invalidPeerGeneration: "The LM Studio Link peer generation is invalid."
        case .invalidRoleEndpoint: "The MCP role endpoint does not match its immutable role."
        case .invalidArchitecture: "The connector architecture is unsupported."
        case .invalidTimestampOrder: "The operation timestamps are inconsistent."
        case .fingerprintNotConfirmed: "The connector fingerprint must be confirmed locally."
        case .invalidControlRequest: "The control request arguments do not match its action."
        case .invalidRetryPolicy: "The link error retry policy is inconsistent."
        case .invalidUUID: "The LM Studio Link UUID is invalid."
        }
    }
}

public enum LMStudioLinkValidation {
    public static func validateText(
        _ value: String,
        maximumBytes: Int,
        minimumBytes: Int = 1,
        field: String,
        permitsEmpty: Bool = false
    ) throws {
        let bytes = value.utf8.count
        guard (permitsEmpty && bytes == 0) || (bytes >= minimumBytes && bytes <= maximumBytes),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LMStudioLinkValidationError.invalidText(field: field)
        }
    }

    public static func validateValues(
        _ values: [String],
        maximumCount: Int,
        maximumBytes: Int,
        field: String
    ) throws {
        guard !values.isEmpty, values.count <= maximumCount, Set(values).count == values.count else {
            throw LMStudioLinkValidationError.invalidCollection(field: field)
        }
        for value in values {
            try validateText(value, maximumBytes: maximumBytes, field: field)
        }
    }

    public static func validateScopes(_ scopes: [LMStudioLinkScope], field: String) throws {
        guard !scopes.isEmpty,
              scopes.count <= LMStudioLinkLimits.maximumScopeCount,
              Set(scopes.map(\.rawValue)).count == scopes.count else {
            throw LMStudioLinkValidationError.invalidCollection(field: field)
        }
    }

    public static func validateSHA256(_ value: String, field: String) throws {
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              }) else {
            throw LMStudioLinkValidationError.invalidSHA256(field: field)
        }
    }

    public static func validateHTTPSOrigin(_ origin: URL) throws {
        guard origin.absoluteString.utf8.count <= LMStudioLinkLimits.maximumOriginBytes,
              origin.scheme?.lowercased() == "https",
              let host = origin.host, !host.isEmpty,
              origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              origin.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw LMStudioLinkValidationError.invalidHTTPSOrigin
        }
    }
}
