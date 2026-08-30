import Darwin
import Foundation
import Security

public enum ForgeFilesystemProtocolConstants {
    public static let version = 3
    public static let productVersion = "0.9.0"
    public static let serviceName = "com.forge-conductor.filesystem-daemon"
    public static let daemonPlistName = "com.forge-conductor.filesystem-daemon.plist"
    public static let daemonExecutableName = "forge-filesystem-daemon"
    public static let appIdentifier = "com.forge-conductor.app"
    public static let managerIdentifier = "com.forge-conductor.cli"
    public static let daemonIdentifier = "com.forge-conductor.filesystem-daemon"
    public static let developmentTeamIdentifier = "9AQ2C2838M"
    public static let productionTeamIdentifier = "2Y25RTLZET"
    public static let maximumRelativeComponents = 128
    public static let maximumComponentBytes = 255

    public static var requiredAppCodeSigningRequirement: String {
        requirement(
            identifier: appIdentifier,
            teamIdentifier: activeTeamIdentifier,
            allowDevelopmentCertificate: isDevelopmentBuild
        )
    }

    /// The native app and separately signed manager/CLI are the only product
    /// identities allowed to submit filesystem requests. Both remain explicit
    /// designated requirements; a team-only admission rule would be too broad.
    public static var requiredClientCodeSigningRequirement: String {
        let managerRequirement = requirement(
            identifier: managerIdentifier,
            teamIdentifier: activeTeamIdentifier,
            allowDevelopmentCertificate: isDevelopmentBuild
        )
        return "(\(requiredAppCodeSigningRequirement)) or (\(managerRequirement))"
    }

    public static func requiredDaemonCodeSigningRequirement<S: Sequence>(
        codeDirectoryHashes: S
    ) -> String? where S.Element == String {
        guard let normalizedHashes = ForgeFilesystemCodeIdentity
            .normalizedCodeDirectoryHashes(codeDirectoryHashes) else {
            return nil
        }
        let exactIdentityRequirement = normalizedHashes
            .map { "cdhash H\"\($0)\"" }
            .joined(separator: " or ")
        let designatedRequirement = requirement(
            identifier: daemonIdentifier,
            teamIdentifier: activeTeamIdentifier,
            allowDevelopmentCertificate: isDevelopmentBuild
        )
        return "(\(designatedRequirement)) and (\(exactIdentityRequirement))"
    }

    public static var activeTeamIdentifier: String {
        #if DEBUG
        developmentTeamIdentifier
        #else
        productionTeamIdentifier
        #endif
    }

    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func requirement(
        identifier: String,
        teamIdentifier: String,
        allowDevelopmentCertificate: Bool
    ) -> String {
        let certificateRequirement: String
        if allowDevelopmentCertificate {
            certificateRequirement =
                "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        } else {
            certificateRequirement = "(certificate leaf[field.1.2.840.113635.100.6.1.13] exists or "
                + "certificate leaf[field.1.2.840.113635.100.6.1.12] exists)"
        }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
            + "and \(certificateRequirement)"
    }
}

public enum ForgeFilesystemCodeIdentity {
    public static let codeDirectoryHashBytes = 20
    public static let codeDirectoryHashCharacters = codeDirectoryHashBytes * 2
    public static let daemonArm64CodeDirectoryHashInfoPlistKey =
        "ForgeFilesystemDaemonCDHashArm64"
    public static let daemonX86_64CodeDirectoryHashInfoPlistKey =
        "ForgeFilesystemDaemonCDHashX86_64"
    public static let daemonCodeDirectoryHashInfoPlistKeys = [
        daemonArm64CodeDirectoryHashInfoPlistKey,
        daemonX86_64CodeDirectoryHashInfoPlistKey,
    ]

    public static func normalizedCodeDirectoryHash(_ hash: String) -> String? {
        guard hash.utf8.count == codeDirectoryHashCharacters,
              hash.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 70)
                      || (byte >= 97 && byte <= 102)
              }) else {
            return nil
        }
        return hash.lowercased()
    }

    public static func normalizedCodeDirectoryHashes<S: Sequence>(
        _ hashes: S
    ) -> [String]? where S.Element == String {
        var normalized = Set<String>()
        for hash in hashes {
            guard let value = normalizedCodeDirectoryHash(hash) else {
                return nil
            }
            normalized.insert(value)
        }
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized.sorted()
    }

    public static func daemonCodeDirectoryHashes(
        inSecuredInfoDictionary dictionary: [String: Any]
    ) -> [String]? {
        var hashes: [String] = []
        for key in daemonCodeDirectoryHashInfoPlistKeys where dictionary[key] != nil {
            guard let hash = dictionary[key] as? String,
                  let normalized = normalizedCodeDirectoryHash(hash) else {
                return nil
            }
            hashes.append(normalized)
        }
        return normalizedCodeDirectoryHashes(hashes)
    }

    public static func currentCodeDirectoryHash() -> String? {
        guard let information = currentValidatedSigningInformation(),
              let uniqueHash = information[kSecCodeInfoUnique] as? Data,
              uniqueHash.count == codeDirectoryHashBytes else {
            return nil
        }
        return normalizedCodeDirectoryHash(
            uniqueHash.map { String(format: "%02x", $0) }.joined()
        )
    }

    /// Returns the Info.plist dictionary sealed into the currently executing
    /// code signature. Validation of the live SecCode happens before any
    /// signing metadata is returned; callers must fail closed on nil.
    public static func currentSecuredInfoDictionary() -> [String: Any]? {
        guard let information = currentValidatedSigningInformation() else {
            return nil
        }
        if let dictionary = information[kSecCodeInfoPList] as? [String: Any] {
            return dictionary
        }
        if let dictionary = information[kSecCodeInfoPList] as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }

    private static func currentValidatedSigningInformation() -> [CFString: Any]? {
        var runningCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &runningCode)
        guard selfStatus == errSecSuccess, let runningCode else {
            return nil
        }

        var validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        validationFlags.formUnion(.noNetworkAccess)
        guard SecCodeCheckValidity(runningCode, validationFlags, nil) == errSecSuccess else {
            return nil
        }

        // Security.framework documents this API as accepting either a live
        // SecCode or a SecStaticCode. The Swift importer exposes only the
        // SecStaticCode spelling, so retain the live object while presenting
        // the documented common CF object to the imported declaration.
        let signingInformationCode = unsafeBitCast(runningCode, to: SecStaticCode.self)
        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            signingInformationCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any] else {
            return nil
        }
        return information
    }
}

@objc(ForgeFilesystemServiceInfo)
public final class ForgeFilesystemServiceInfo: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let supportsSecureCoding = true

    public let protocolVersion: Int
    public let productVersion: String
    public let serviceIdentifier: String
    public let effectiveUserIdentifier: UInt32
    public let codeDirectoryHash: String

    public init(
        protocolVersion: Int = ForgeFilesystemProtocolConstants.version,
        productVersion: String = ForgeFilesystemProtocolConstants.productVersion,
        serviceIdentifier: String = ForgeFilesystemProtocolConstants.daemonIdentifier,
        effectiveUserIdentifier: UInt32,
        codeDirectoryHash: String
    ) {
        self.protocolVersion = protocolVersion
        self.productVersion = String(productVersion.prefix(64))
        self.serviceIdentifier = String(serviceIdentifier.prefix(128))
        self.effectiveUserIdentifier = effectiveUserIdentifier
        self.codeDirectoryHash = ForgeFilesystemCodeIdentity
            .normalizedCodeDirectoryHash(codeDirectoryHash) ?? ""
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let productVersion = coder.decodeObject(
            of: NSString.self,
            forKey: "product_version"
        ) as String?,
              let serviceIdentifier = coder.decodeObject(
                  of: NSString.self,
                  forKey: "service_identifier"
              ) as String?,
              let codeDirectoryHash = coder.decodeObject(
                  of: NSString.self,
                  forKey: "code_directory_hash"
              ) as String?,
              let normalizedCodeDirectoryHash = ForgeFilesystemCodeIdentity
                  .normalizedCodeDirectoryHash(codeDirectoryHash) else {
            return nil
        }
        let decodedEffectiveUID = coder.decodeInt64(forKey: "effective_uid")
        guard decodedEffectiveUID >= 0,
              decodedEffectiveUID <= Int64(UInt32.max) else {
            return nil
        }
        protocolVersion = coder.decodeInteger(forKey: "protocol_version")
        self.productVersion = String(productVersion.prefix(64))
        self.serviceIdentifier = String(serviceIdentifier.prefix(128))
        effectiveUserIdentifier = UInt32(decodedEffectiveUID)
        self.codeDirectoryHash = normalizedCodeDirectoryHash
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocol_version")
        coder.encode(productVersion, forKey: "product_version")
        coder.encode(serviceIdentifier, forKey: "service_identifier")
        coder.encode(Int64(effectiveUserIdentifier), forKey: "effective_uid")
        coder.encode(codeDirectoryHash, forKey: "code_directory_hash")
    }

    public func matchesExpectedService<S: Sequence>(
        allowedCodeDirectoryHashes: S
    ) -> Bool where S.Element == String {
        guard let normalizedAllowed = ForgeFilesystemCodeIdentity
            .normalizedCodeDirectoryHashes(allowedCodeDirectoryHashes) else {
            return false
        }
        return protocolVersion == ForgeFilesystemProtocolConstants.version
            && productVersion == ForgeFilesystemProtocolConstants.productVersion
            && serviceIdentifier == ForgeFilesystemProtocolConstants.daemonIdentifier
            && effectiveUserIdentifier == 0
            && normalizedAllowed.contains(codeDirectoryHash)
    }
}

public enum ForgeFilesystemAccess: Int {
    case deleteLeaf = 1
}

public enum ForgeFilesystemErrorCode {
    public static let helperUnavailable = "secure_filesystem_helper_unavailable"
    public static let helperNotApproved = "secure_filesystem_helper_not_approved"
    public static let helperIdentityMismatch = "secure_filesystem_helper_identity_mismatch"
    public static let protectedNamespaceUnavailable = "protected_transaction_namespace_unavailable"
    public static let capabilityUnavailable = "filesystem_capability_unavailable"
    public static let volumeUnqualified = "filesystem_volume_unqualified"
    public static let invalidRequest = "filesystem_invalid_request"
    public static let protocolMismatch = "filesystem_protocol_mismatch"
    public static let projectGenerationStale = "filesystem_project_generation_stale"
    public static let sourceIdentityMismatch = "filesystem_source_identity_mismatch"
    public static let transactionConflict = "filesystem_transaction_conflict"
    public static let durabilityUnconfirmed = "filesystem_durability_unconfirmed"
}

/// Shared, deterministic policy for deciding whether the privileged service may
/// exercise filesystem authority on behalf of an authenticated local user.
/// The daemon separately verifies that the UID names a real local account and
/// that every inspected directory descriptor has no extended ACL.
public enum ForgeFilesystemRequesterPolicy {
    public static let invalidRequesterUID = UInt32.max
    public static let maximumRequesterUID: UInt32 = 2_147_483_647
    public static let disallowedLeafFlags = UInt32(
        UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_RESTRICTED | SF_NOUNLINK
    )

    public static func isValidRequesterUID(_ requesterUID: UInt32) -> Bool {
        requesterUID != 0 && requesterUID <= maximumRequesterUID
    }

    public static func matchesPersistedRequester(
        _ persistedRequesterUID: UInt32,
        currentRequesterUID: UInt32
    ) -> Bool {
        isValidRequesterUID(persistedRequesterUID)
            && persistedRequesterUID == currentRequesterUID
    }

    public static func permitsSourceDirectory(
        requesterUID: UInt32,
        ownerUID: UInt32,
        mode: UInt32,
        hasExtendedACL: Bool,
        requiresOwnerWrite: Bool
    ) -> Bool {
        let fileTypeMask: UInt32 = 0o170000
        let directoryType: UInt32 = 0o040000
        let ownerWrite: UInt32 = 0o000200
        let ownerSearch: UInt32 = 0o000100

        guard isValidRequesterUID(requesterUID),
              ownerUID == requesterUID,
              mode & fileTypeMask == directoryType,
              mode & ownerSearch != 0,
              !hasExtendedACL else {
            return false
        }
        return !requiresOwnerWrite || mode & ownerWrite != 0
    }

    public static func permitsLeafDeletion(
        flags: UInt32,
        hasExtendedACL: Bool
    ) -> Bool {
        !hasExtendedACL && flags & disallowedLeafFlags == 0
    }

    public static func permitsLeafType(mode: UInt32) -> Bool {
        let type = mode & UInt32(S_IFMT)
        return type == UInt32(S_IFREG) || type == UInt32(S_IFLNK)
    }
}

/// Bounded deterministic open addressing for protected project bindings.
/// Every UUID receives a complete permutation of the fixed slot set, so a
/// hash collision cannot permanently deny a project while another slot is free.
public enum ForgeFilesystemBindingPolicy {
    public static let maximumSlots = 256

    public static func probeSlots(for projectID: UUID) -> [Int] {
        var bytes = projectID.uuid
        let hash = withUnsafeBytes(of: &bytes) { rawBytes -> UInt64 in
            rawBytes.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
                (partial ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }
        let initial = Int(hash % UInt64(maximumSlots))
        return (0..<maximumSlots).map { (initial + $0) % maximumSlots }
    }
}

@objc(ForgeFilesystemIdentity)
public final class ForgeFilesystemIdentity: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let supportsSecureCoding = true

    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let owner: UInt32
    public let group: UInt32
    public let linkCount: UInt64

    public init(
        device: UInt64,
        inode: UInt64,
        mode: UInt32,
        owner: UInt32,
        group: UInt32,
        linkCount: UInt64
    ) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.owner = owner
        self.group = group
        self.linkCount = linkCount
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let device = coder.decodeObject(of: NSNumber.self, forKey: "device"),
              let inode = coder.decodeObject(of: NSNumber.self, forKey: "inode"),
              let mode = coder.decodeObject(of: NSNumber.self, forKey: "mode"),
              let owner = coder.decodeObject(of: NSNumber.self, forKey: "owner"),
              let group = coder.decodeObject(of: NSNumber.self, forKey: "group"),
              let linkCount = coder.decodeObject(of: NSNumber.self, forKey: "link_count") else {
            return nil
        }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
        self.mode = mode.uint32Value
        self.owner = owner.uint32Value
        self.group = group.uint32Value
        self.linkCount = linkCount.uint64Value
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(NSNumber(value: device), forKey: "device")
        coder.encode(NSNumber(value: inode), forKey: "inode")
        coder.encode(NSNumber(value: mode), forKey: "mode")
        coder.encode(NSNumber(value: owner), forKey: "owner")
        coder.encode(NSNumber(value: group), forKey: "group")
        coder.encode(NSNumber(value: linkCount), forKey: "link_count")
    }
}

@objc(ForgeFilesystemMutationRequest)
public final class ForgeFilesystemMutationRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let supportsSecureCoding = true

    public let protocolVersion: Int
    public let requestID: String
    public let transactionID: String
    public let projectID: String
    public let projectGeneration: UInt64
    public let rootID: String
    public let rootIdentity: ForgeFilesystemIdentity
    public let relativePathComponents: [String]
    public let accessRawValue: Int
    public let expectedLeafIdentity: ForgeFilesystemIdentity
    public let exactContentRequired: Bool

    public init(
        protocolVersion: Int = ForgeFilesystemProtocolConstants.version,
        requestID: String,
        transactionID: String,
        projectID: String,
        projectGeneration: UInt64,
        rootID: String,
        rootIdentity: ForgeFilesystemIdentity,
        relativePathComponents: [String],
        access: ForgeFilesystemAccess,
        expectedLeafIdentity: ForgeFilesystemIdentity,
        exactContentRequired: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.transactionID = transactionID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.rootID = rootID
        self.rootIdentity = rootIdentity
        self.relativePathComponents = relativePathComponents
        accessRawValue = access.rawValue
        self.expectedLeafIdentity = expectedLeafIdentity
        self.exactContentRequired = exactContentRequired
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSString.self, forKey: "request_id") as String?,
              let transactionID = coder.decodeObject(of: NSString.self, forKey: "transaction_id") as String?,
              let projectID = coder.decodeObject(of: NSString.self, forKey: "project_id") as String?,
              let rootID = coder.decodeObject(of: NSString.self, forKey: "root_id") as String?,
              let rootIdentity = coder.decodeObject(
                of: ForgeFilesystemIdentity.self,
                forKey: "root_identity"
              ),
              let components = coder.decodeObject(
                of: [NSArray.self, NSString.self],
                forKey: "relative_components"
              ) as? [String],
              let expectedLeafIdentity = coder.decodeObject(
                of: ForgeFilesystemIdentity.self,
                forKey: "expected_leaf_identity"
              ) else {
            return nil
        }
        let decodedProjectGeneration = coder.decodeInt64(forKey: "project_generation")
        guard decodedProjectGeneration > 0 else { return nil }
        protocolVersion = coder.decodeInteger(forKey: "protocol_version")
        self.requestID = requestID
        self.transactionID = transactionID
        self.projectID = projectID
        projectGeneration = UInt64(decodedProjectGeneration)
        self.rootID = rootID
        self.rootIdentity = rootIdentity
        relativePathComponents = components
        accessRawValue = coder.decodeInteger(forKey: "access")
        self.expectedLeafIdentity = expectedLeafIdentity
        exactContentRequired = coder.decodeBool(forKey: "exact_content_required")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocol_version")
        coder.encode(requestID, forKey: "request_id")
        coder.encode(transactionID, forKey: "transaction_id")
        coder.encode(projectID, forKey: "project_id")
        coder.encode(Int64(bitPattern: projectGeneration), forKey: "project_generation")
        coder.encode(rootID, forKey: "root_id")
        coder.encode(rootIdentity, forKey: "root_identity")
        coder.encode(relativePathComponents, forKey: "relative_components")
        coder.encode(accessRawValue, forKey: "access")
        coder.encode(expectedLeafIdentity, forKey: "expected_leaf_identity")
        coder.encode(exactContentRequired, forKey: "exact_content_required")
    }

    public var access: ForgeFilesystemAccess? {
        ForgeFilesystemAccess(rawValue: accessRawValue)
    }

    public func validationError() -> String? {
        guard protocolVersion == ForgeFilesystemProtocolConstants.version else {
            return ForgeFilesystemErrorCode.protocolMismatch
        }
        guard UUID(uuidString: requestID) != nil,
              UUID(uuidString: transactionID) != nil,
              UUID(uuidString: projectID) != nil,
              projectGeneration > 0,
              projectGeneration <= UInt64(Int64.max),
              access == .deleteLeaf,
              ForgeFilesystemRequesterPolicy.permitsLeafType(mode: expectedLeafIdentity.mode),
              !rootID.isEmpty,
              rootID.utf8.count <= 128,
              !exactContentRequired else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        guard !relativePathComponents.isEmpty,
              relativePathComponents.count <= ForgeFilesystemProtocolConstants.maximumRelativeComponents,
              relativePathComponents.allSatisfy(Self.validRelativeComponent) else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        return nil
    }

    private static func validRelativeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
            && component.utf8.count <= ForgeFilesystemProtocolConstants.maximumComponentBytes
    }
}

@objc(ForgeFilesystemResponse)
public final class ForgeFilesystemResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let supportsSecureCoding = true

    public let ok: Bool
    public let code: String
    public let message: String
    public let committed: Bool
    public let durabilityConfirmed: Bool
    public let recoveryTransactionID: String?

    public init(
        ok: Bool,
        code: String,
        message: String,
        committed: Bool = false,
        durabilityConfirmed: Bool = false,
        recoveryTransactionID: String? = nil
    ) {
        self.ok = ok
        self.code = String(code.prefix(128))
        self.message = String(message.prefix(1_024))
        self.committed = committed
        self.durabilityConfirmed = durabilityConfirmed
        self.recoveryTransactionID = recoveryTransactionID
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let code = coder.decodeObject(of: NSString.self, forKey: "code") as String?,
              let message = coder.decodeObject(of: NSString.self, forKey: "message") as String? else {
            return nil
        }
        ok = coder.decodeBool(forKey: "ok")
        self.code = String(code.prefix(128))
        self.message = String(message.prefix(1_024))
        committed = coder.decodeBool(forKey: "committed")
        durabilityConfirmed = coder.decodeBool(forKey: "durability_confirmed")
        recoveryTransactionID = coder.decodeObject(
            of: NSString.self,
            forKey: "recovery_transaction_id"
        ) as String?
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(ok, forKey: "ok")
        coder.encode(code, forKey: "code")
        coder.encode(message, forKey: "message")
        coder.encode(committed, forKey: "committed")
        coder.encode(durabilityConfirmed, forKey: "durability_confirmed")
        coder.encode(recoveryTransactionID, forKey: "recovery_transaction_id")
    }
}

@objc public protocol ForgeFilesystemServiceXPC {
    func serviceInfo(withReply reply: @escaping (ForgeFilesystemServiceInfo) -> Void)

    func status(withReply reply: @escaping (ForgeFilesystemResponse) -> Void)

    func deleteLeaf(
        _ request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemResponse) -> Void
    )
}
