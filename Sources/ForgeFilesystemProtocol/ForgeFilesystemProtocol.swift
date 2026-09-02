import Darwin
import CryptoKit
import Foundation
import Security

public enum ForgeFilesystemProtocolConstants {
    public static let version = 5
    public static let requestDigestCanonicalizationVersion = 1
    public static let productVersion = "0.9.0"
    public static let productBuildVersion = "1"
    public static let serviceName = "com.forge-conductor.filesystem-daemon"
    public static let daemonPlistName = "com.forge-conductor.filesystem-daemon.plist"
    public static let daemonExecutableName = "forge-filesystem-daemon"
    public static let appIdentifier = "com.forge-conductor.app"
    public static let managerIdentifier = "com.forge-conductor.cli"
    public static let daemonIdentifier = "com.forge-conductor.filesystem-daemon"
    public static let runtimeLauncherIdentifier = "com.forge-conductor.runtime-launcher"
    public static let coreFrameworkIdentifier = "com.forge-conductor.core"
    public static let developmentTeamIdentifier = "9AQ2C2838M"
    public static let productionTeamIdentifier = "2Y25RTLZET"
    public static let maximumRelativeComponents = 128
    public static let maximumComponentBytes = 255

    public static var requiredAppCodeSigningRequirement: String {
        requirement(
            identifier: appIdentifier,
            teamIdentifier: activeTeamIdentifier,
            certificateRequirement: activeCertificateRequirement
        )
    }

    /// The native app and separately signed manager/CLI are the only product
    /// identities allowed to submit filesystem requests. Both remain explicit
    /// designated requirements; a team-only admission rule would be too broad.
    public static var requiredClientCodeSigningRequirement: String {
        let managerRequirement = requirement(
            identifier: managerIdentifier,
            teamIdentifier: activeTeamIdentifier,
            certificateRequirement: activeCertificateRequirement
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
            certificateRequirement: activeCertificateRequirement
        )
        return "(\(designatedRequirement)) and (\(exactIdentityRequirement))"
    }

    /// Returns the stable Apple signing policy for one exact Forge product role.
    /// Team and certificate class are intentionally inseparable: development
    /// artifacts use Apple Development while distribution artifacts use
    /// Developer ID Application.
    public static func requiredProductCodeSigningRequirement(
        identifier: String,
        teamIdentifier: String
    ) -> String? {
        let knownIdentifiers: Set<String> = [
            appIdentifier,
            managerIdentifier,
            daemonIdentifier,
            runtimeLauncherIdentifier,
            coreFrameworkIdentifier,
        ]
        guard knownIdentifiers.contains(identifier) else { return nil }

        let certificateRequirement: String
        switch teamIdentifier {
        case developmentTeamIdentifier:
            certificateRequirement =
                "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        case productionTeamIdentifier:
            certificateRequirement =
                "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        default:
            return nil
        }
        return requirement(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            certificateRequirement: certificateRequirement
        )
    }

    public static var activeTeamIdentifier: String {
        #if DEBUG || FORGE_DEVELOPMENT_SIGNING
        developmentTeamIdentifier
        #else
        productionTeamIdentifier
        #endif
    }

    private static var activeCertificateRequirement: String {
        #if DEBUG || FORGE_DEVELOPMENT_SIGNING
        "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        #else
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        #endif
    }

    private static func requirement(
        identifier: String,
        teamIdentifier: String,
        certificateRequirement: String
    ) -> String {
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

/// Classifies documented atomic-rename failures that leave both namespace
/// arguments unchanged. These failures can terminate a reserved transaction as
/// rejected instead of indefinitely consuming a protected recovery slot.
public enum ForgeFilesystemAtomicCaptureFailurePolicy {
    public static func isDeterministicNoMutationFailure(_ code: Int32) -> Bool {
        [
            EACCES,
            EBUSY,
            EDEADLK,
            EDQUOT,
            EINVAL,
            EISDIR,
            ELOOP,
            ENAMETOOLONG,
            ENOSPC,
            ENOTCAPABLE,
            ENOTDIR,
            ENOTEMPTY,
            ENOTSUP,
            EPERM,
            EROFS,
        ].contains(code)
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
    public static let versionConflict = "filesystem_version_conflict"
    public static let versionUnprovable = "filesystem_version_unprovable"
    public static let contentExclusivityUnavailable =
        "filesystem_content_exclusivity_unavailable"
    public static let restoreConflict = "filesystem_restore_conflict"
    public static let requestReplayMismatch = "filesystem_request_replay_mismatch"
    public static let transactionConflict = "filesystem_transaction_conflict"
    public static let durabilityUnconfirmed = "filesystem_durability_unconfirmed"
    public static let transactionUnavailable = "filesystem_transaction_unavailable"
    public static let transactionNotTerminal = "filesystem_transaction_not_terminal"
}

@objc(ForgeFilesystemOperationContract)
public enum ForgeFilesystemOperationContract: Int, Codable, Sendable {
    case currentEntry = 1
    case namespaceVersionExact = 2
    case contentVersionExact = 3
}

public enum ForgeFilesystemCapturedMutationDecision<Value> {
    case commit(Value)
    case quarantine(Value, code: String, message: String)
}

public enum ForgeFilesystemCaptureFirstCoordinator {
    /// Makes successful atomic capture the sole linearization point. No
    /// authorization decision or terminal mutation runs when capture fails,
    /// and commit can consume only the value returned by post-capture
    /// verification.
    public static func perform<Capture, Verified, Output>(
        capture: () throws -> Capture,
        verify: (Capture) throws -> ForgeFilesystemCapturedMutationDecision<Verified>,
        commit: (Verified) throws -> Output,
        quarantine: (Verified, String, String) throws -> Output
    ) rethrows -> Output {
        let captured = try capture()
        switch try verify(captured) {
        case .commit(let verified):
            return try commit(verified)
        case .quarantine(let verified, let code, let message):
            return try quarantine(verified, code, message)
        }
    }
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
    public let contractRawValue: Int
    public let expectedLeafIdentity: ForgeFilesystemIdentity?
    public let requestDigestSHA256: String

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
        contract: ForgeFilesystemOperationContract,
        expectedLeafIdentity: ForgeFilesystemIdentity? = nil
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
        contractRawValue = contract.rawValue
        self.expectedLeafIdentity = expectedLeafIdentity
        requestDigestSHA256 = Self.calculateRequestDigest(
            protocolVersion: protocolVersion,
            requestID: requestID,
            transactionID: transactionID,
            projectID: projectID,
            projectGeneration: projectGeneration,
            rootID: rootID,
            rootIdentity: rootIdentity,
            relativePathComponents: relativePathComponents,
            accessRawValue: access.rawValue,
            contractRawValue: contract.rawValue,
            expectedLeafIdentity: expectedLeafIdentity
        )
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
              let requestDigestSHA256 = coder.decodeObject(
                  of: NSString.self,
                  forKey: "request_digest_sha256"
              ) as String? else {
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
        contractRawValue = coder.decodeInteger(forKey: "operation_contract")
        expectedLeafIdentity = coder.decodeObject(
            of: ForgeFilesystemIdentity.self,
            forKey: "expected_leaf_identity"
        )
        self.requestDigestSHA256 = requestDigestSHA256
        super.init()
        guard validationError() == nil else { return nil }
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
        coder.encode(contractRawValue, forKey: "operation_contract")
        coder.encode(expectedLeafIdentity, forKey: "expected_leaf_identity")
        coder.encode(requestDigestSHA256, forKey: "request_digest_sha256")
    }

    public var access: ForgeFilesystemAccess? {
        ForgeFilesystemAccess(rawValue: accessRawValue)
    }

    public var contract: ForgeFilesystemOperationContract? {
        ForgeFilesystemOperationContract(rawValue: contractRawValue)
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
              contract != nil,
              !rootID.isEmpty,
              rootID.utf8.count <= 128 else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        switch contract {
        case .currentEntry:
            guard expectedLeafIdentity == nil else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        case .namespaceVersionExact, .contentVersionExact:
            guard let expectedLeafIdentity,
                  ForgeFilesystemRequesterPolicy.permitsLeafType(
                      mode: expectedLeafIdentity.mode
                  ) else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        case nil:
            return ForgeFilesystemErrorCode.invalidRequest
        }
        guard !relativePathComponents.isEmpty,
              relativePathComponents.count <= ForgeFilesystemProtocolConstants.maximumRelativeComponents,
              relativePathComponents.allSatisfy(Self.validRelativeComponent) else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        guard requestDigestSHA256 == Self.calculateRequestDigest(
            protocolVersion: protocolVersion,
            requestID: requestID,
            transactionID: transactionID,
            projectID: projectID,
            projectGeneration: projectGeneration,
            rootID: rootID,
            rootIdentity: rootIdentity,
            relativePathComponents: relativePathComponents,
            accessRawValue: accessRawValue,
            contractRawValue: contractRawValue,
            expectedLeafIdentity: expectedLeafIdentity
        ) else {
            return ForgeFilesystemErrorCode.requestReplayMismatch
        }
        return nil
    }

    private struct DigestIdentity: Codable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let group: UInt32
        let linkCount: UInt64

        init(_ identity: ForgeFilesystemIdentity) {
            device = identity.device
            inode = identity.inode
            mode = identity.mode
            owner = identity.owner
            group = identity.group
            linkCount = identity.linkCount
        }
    }

    private struct DigestEnvelope: Codable {
        let canonicalizationVersion: Int
        let protocolVersion: Int
        let requestID: String
        let transactionID: String
        let projectID: String
        let projectGeneration: UInt64
        let rootID: String
        let rootIdentity: DigestIdentity
        let relativePathComponents: [String]
        let accessRawValue: Int
        let contractRawValue: Int
        let expectedLeafIdentity: DigestIdentity?
    }

    private static func calculateRequestDigest(
        protocolVersion: Int,
        requestID: String,
        transactionID: String,
        projectID: String,
        projectGeneration: UInt64,
        rootID: String,
        rootIdentity: ForgeFilesystemIdentity,
        relativePathComponents: [String],
        accessRawValue: Int,
        contractRawValue: Int,
        expectedLeafIdentity: ForgeFilesystemIdentity?
    ) -> String {
        let envelope = DigestEnvelope(
            canonicalizationVersion:
                ForgeFilesystemProtocolConstants.requestDigestCanonicalizationVersion,
            protocolVersion: protocolVersion,
            requestID: requestID.lowercased(),
            transactionID: transactionID.lowercased(),
            projectID: projectID.lowercased(),
            projectGeneration: projectGeneration,
            rootID: rootID,
            rootIdentity: DigestIdentity(rootIdentity),
            relativePathComponents: relativePathComponents,
            accessRawValue: accessRawValue,
            contractRawValue: contractRawValue,
            expectedLeafIdentity: expectedLeafIdentity.map(DigestIdentity.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

@objc(ForgeFilesystemTransactionDisposition)
public enum ForgeFilesystemTransactionDisposition: Int, Codable, Sendable {
    case unavailable = 0
    case recoveryRequired = 1
    case committed = 2
    case restored = 3
    case rejected = 4
    case quarantined = 5
    case conflicted = 6
}

@objc(ForgeFilesystemTransactionControlRequest)
public final class ForgeFilesystemTransactionControlRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let supportsSecureCoding = true

    public let protocolVersion: Int
    public let transactionID: String
    public let projectID: String
    public let projectGeneration: UInt64
    public let rootID: String
    public let rootIdentity: ForgeFilesystemIdentity

    public init(
        protocolVersion: Int = ForgeFilesystemProtocolConstants.version,
        transactionID: String,
        projectID: String,
        projectGeneration: UInt64,
        rootID: String,
        rootIdentity: ForgeFilesystemIdentity
    ) {
        self.protocolVersion = protocolVersion
        self.transactionID = transactionID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.rootID = rootID
        self.rootIdentity = rootIdentity
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let transactionID = coder.decodeObject(
            of: NSString.self,
            forKey: "transaction_id"
        ) as String?,
              let projectID = coder.decodeObject(
                  of: NSString.self,
                  forKey: "project_id"
              ) as String?,
              let rootID = coder.decodeObject(
                  of: NSString.self,
                  forKey: "root_id"
              ) as String?,
              let rootIdentity = coder.decodeObject(
                  of: ForgeFilesystemIdentity.self,
                  forKey: "root_identity"
              ) else {
            return nil
        }
        let decodedProjectGeneration = coder.decodeInt64(forKey: "project_generation")
        guard decodedProjectGeneration > 0 else { return nil }
        protocolVersion = coder.decodeInteger(forKey: "protocol_version")
        self.transactionID = transactionID
        self.projectID = projectID
        projectGeneration = UInt64(decodedProjectGeneration)
        self.rootID = rootID
        self.rootIdentity = rootIdentity
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocol_version")
        coder.encode(transactionID, forKey: "transaction_id")
        coder.encode(projectID, forKey: "project_id")
        coder.encode(Int64(bitPattern: projectGeneration), forKey: "project_generation")
        coder.encode(rootID, forKey: "root_id")
        coder.encode(rootIdentity, forKey: "root_identity")
    }

    public func validationError() -> String? {
        guard protocolVersion == ForgeFilesystemProtocolConstants.version else {
            return ForgeFilesystemErrorCode.protocolMismatch
        }
        guard UUID(uuidString: transactionID) != nil,
              UUID(uuidString: projectID) != nil,
              projectGeneration > 0,
              projectGeneration <= UInt64(Int64.max),
              !rootID.isEmpty,
              rootID.utf8.count <= 128 else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        return nil
    }
}

public enum ForgeFilesystemTransactionRecoveryBoundary: Sendable {
    case beforeIntentPublication
    case intentPublicationStarted
    case persistedTransactionPresent
}

public enum ForgeFilesystemTransactionRecoveryPolicy {
    /// Once intent publication begins, a durable receipt may exist even when
    /// the publishing operation reports failure. Every later failure must
    /// therefore return the original transaction identity to the caller.
    public static func recoveryTransactionID(
        _ transactionID: String,
        at boundary: ForgeFilesystemTransactionRecoveryBoundary
    ) -> String? {
        guard UUID(uuidString: transactionID) != nil else { return nil }
        switch boundary {
        case .beforeIntentPublication:
            return nil
        case .intentPublicationStarted, .persistedTransactionPresent:
            return transactionID
        }
    }
}

public enum ForgeFilesystemCapturedLeafRollbackDisposition: Equatable, Sendable {
    case retainForRecovery
}

public enum ForgeFilesystemCapturedLeafRollbackPolicy {
    /// A directory descriptor pins an object but does not prove that object still
    /// resides below the authorized root. macOS exposes no public rename form
    /// that atomically predicates the destination parent on that containment, so
    /// a root process must retain the captured leaf instead of restoring it.
    public static var disposition: ForgeFilesystemCapturedLeafRollbackDisposition {
        .retainForRecovery
    }
}

public enum ForgeFilesystemTransactionAuthorityPolicy {
    public enum AcknowledgementDecision: Equatable, Sendable {
        case idempotentSuccess
        case authorizedCleanup
        case reject
    }

    public static func matchesPersistedAuthority(
        request: ForgeFilesystemTransactionControlRequest,
        currentRequesterUID: UInt32,
        persistedRequesterUID: UInt32,
        persistedTransactionID: String,
        persistedProjectID: String,
        persistedProjectGeneration: UInt64,
        persistedRootID: String,
        persistedRootIdentity: ForgeFilesystemIdentity
    ) -> Bool {
        request.validationError() == nil
            && ForgeFilesystemRequesterPolicy.matchesPersistedRequester(
            persistedRequesterUID,
            currentRequesterUID: currentRequesterUID
        )
            && persistedTransactionID.caseInsensitiveCompare(request.transactionID) == .orderedSame
            && persistedProjectID.caseInsensitiveCompare(request.projectID) == .orderedSame
            && persistedProjectGeneration == request.projectGeneration
            && persistedRootID == request.rootID
            && sameIdentity(persistedRootIdentity, request.rootIdentity)
    }

    public static func acknowledgementDecision(
        transactionExists: Bool,
        authorityMatches: Bool
    ) -> AcknowledgementDecision {
        guard transactionExists else { return .idempotentSuccess }
        return authorityMatches ? .authorizedCleanup : .reject
    }

    private static func sameIdentity(
        _ lhs: ForgeFilesystemIdentity,
        _ rhs: ForgeFilesystemIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.mode == rhs.mode
            && lhs.owner == rhs.owner
            && lhs.group == rhs.group
            && lhs.linkCount == rhs.linkCount
    }
}

@objc(ForgeFilesystemTransactionStatus)
public final class ForgeFilesystemTransactionStatus: NSObject, NSSecureCoding, @unchecked Sendable {
    public static let supportsSecureCoding = true

    public let protocolVersion: Int
    public let transactionID: String?
    public let dispositionRawValue: Int
    public let code: String
    public let message: String
    public let terminal: Bool
    public let committed: Bool
    public let durabilityConfirmed: Bool
    public let recoveryRequired: Bool
    public let acknowledgementRequired: Bool

    public init(
        protocolVersion: Int = ForgeFilesystemProtocolConstants.version,
        transactionID: String?,
        disposition: ForgeFilesystemTransactionDisposition,
        code: String,
        message: String,
        terminal: Bool,
        committed: Bool,
        durabilityConfirmed: Bool,
        recoveryRequired: Bool,
        acknowledgementRequired: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.transactionID = transactionID
        dispositionRawValue = disposition.rawValue
        self.code = String(code.prefix(128))
        self.message = String(message.prefix(1_024))
        self.terminal = terminal
        self.committed = committed
        self.durabilityConfirmed = durabilityConfirmed
        self.recoveryRequired = recoveryRequired
        self.acknowledgementRequired = acknowledgementRequired
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let code = coder.decodeObject(of: NSString.self, forKey: "code") as String?,
              let message = coder.decodeObject(of: NSString.self, forKey: "message") as String? else {
            return nil
        }
        protocolVersion = coder.decodeInteger(forKey: "protocol_version")
        transactionID = coder.decodeObject(
            of: NSString.self,
            forKey: "transaction_id"
        ) as String?
        dispositionRawValue = coder.decodeInteger(forKey: "disposition")
        self.code = String(code.prefix(128))
        self.message = String(message.prefix(1_024))
        terminal = coder.decodeBool(forKey: "terminal")
        committed = coder.decodeBool(forKey: "committed")
        durabilityConfirmed = coder.decodeBool(forKey: "durability_confirmed")
        recoveryRequired = coder.decodeBool(forKey: "recovery_required")
        acknowledgementRequired = coder.decodeBool(forKey: "acknowledgement_required")
        super.init()
        guard validationError() == nil else { return nil }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocol_version")
        coder.encode(transactionID, forKey: "transaction_id")
        coder.encode(dispositionRawValue, forKey: "disposition")
        coder.encode(code, forKey: "code")
        coder.encode(message, forKey: "message")
        coder.encode(terminal, forKey: "terminal")
        coder.encode(committed, forKey: "committed")
        coder.encode(durabilityConfirmed, forKey: "durability_confirmed")
        coder.encode(recoveryRequired, forKey: "recovery_required")
        coder.encode(acknowledgementRequired, forKey: "acknowledgement_required")
    }

    public var disposition: ForgeFilesystemTransactionDisposition? {
        ForgeFilesystemTransactionDisposition(rawValue: dispositionRawValue)
    }

    public func validationError() -> String? {
        guard protocolVersion == ForgeFilesystemProtocolConstants.version else {
            return ForgeFilesystemErrorCode.protocolMismatch
        }
        guard disposition != nil,
              !code.isEmpty,
              code.utf8.count <= 128,
              message.utf8.count <= 1_024 else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        switch disposition {
        case .unavailable:
            guard transactionID == nil,
                  !terminal,
                  !committed,
                  !durabilityConfirmed,
                  !recoveryRequired,
                  !acknowledgementRequired else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        case .recoveryRequired:
            guard transactionID.flatMap(UUID.init(uuidString:)) != nil,
                  !terminal,
                  !committed,
                  !durabilityConfirmed,
                  recoveryRequired,
                  !acknowledgementRequired else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        case .committed, .restored, .rejected, .conflicted:
            guard transactionID.flatMap(UUID.init(uuidString:)) != nil,
                  (disposition == .committed ? code == "ok" : code != "ok"),
                  terminal,
                  durabilityConfirmed,
                  !recoveryRequired,
                  acknowledgementRequired,
                  committed == (disposition == .committed) else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        case .quarantined:
            guard transactionID.flatMap(UUID.init(uuidString:)) != nil,
                  code != "ok",
                  terminal,
                  !committed,
                  durabilityConfirmed,
                  recoveryRequired,
                  !acknowledgementRequired else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        case nil:
            return ForgeFilesystemErrorCode.invalidRequest
        }
        return nil
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
    public let acknowledgementRequired: Bool

    public init(
        ok: Bool,
        code: String,
        message: String,
        committed: Bool = false,
        durabilityConfirmed: Bool = false,
        recoveryTransactionID: String? = nil,
        acknowledgementRequired: Bool = false
    ) {
        self.ok = ok
        self.code = String(code.prefix(128))
        self.message = String(message.prefix(1_024))
        self.committed = committed
        self.durabilityConfirmed = durabilityConfirmed
        self.recoveryTransactionID = recoveryTransactionID
        self.acknowledgementRequired = acknowledgementRequired
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
        acknowledgementRequired = coder.decodeBool(forKey: "acknowledgement_required")
        super.init()
        guard validationError() == nil else { return nil }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(ok, forKey: "ok")
        coder.encode(code, forKey: "code")
        coder.encode(message, forKey: "message")
        coder.encode(committed, forKey: "committed")
        coder.encode(durabilityConfirmed, forKey: "durability_confirmed")
        coder.encode(recoveryTransactionID, forKey: "recovery_transaction_id")
        coder.encode(acknowledgementRequired, forKey: "acknowledgement_required")
    }

    public func validationError() -> String? {
        guard !code.isEmpty,
              code.utf8.count <= 128,
              message.utf8.count <= 1_024 else {
            return ForgeFilesystemErrorCode.invalidRequest
        }
        if acknowledgementRequired {
            guard durabilityConfirmed,
                  recoveryTransactionID.flatMap(UUID.init(uuidString:)) != nil else {
                return ForgeFilesystemErrorCode.invalidRequest
            }
        }
        return nil
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

    func queryTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemTransactionStatus) -> Void
    )

    func resumeTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemResponse) -> Void
    )

    func acknowledgeTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemResponse) -> Void
    )
}
