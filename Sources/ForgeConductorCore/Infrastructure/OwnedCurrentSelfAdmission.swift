import Darwin
import Foundation
import ForgeFilesystemProtocol
import Security

enum OwnedNativeExecutableRole: String, Sendable {
    case cli
    case app

    var identifier: String {
        switch self {
        case .cli: ForgeFilesystemProtocolConstants.managerIdentifier
        case .app: ForgeFilesystemProtocolConstants.appIdentifier
        }
    }
}

/// A validated named disk artifact. This is not a hash of mapped Core memory.
struct OwnedCoreArtifactIdentity: Sendable, Equatable {
    let executable: URL
    let identifier: String
    let cdhash: String
}

struct OwnedCurrentSelfIdentity: Sendable, Equatable {
    let executable: URL
    let role: OwnedNativeExecutableRole
    let identifier: String
    let cdhash: String
    let coreArtifact: OwnedCoreArtifactIdentity
}

enum OwnedCurrentSelfAdmissionError: Error, Sendable, Equatable {
    case securityFailure(OSStatus)
    case missingMetadata
    case roleRejected
    case roleMismatch
    case invalidIdentity
    case executableMismatch
    case associatedCoreUnavailable
    case associatedCoreMismatch
    case exactIdentityMismatch
    case invalidChildPID
    case auditTokenUnavailable(kern_return_t)
    case auditTokenMismatch
}

/// Internal fixed-mode admission only. The caller owns an unreaped child and
/// must check its owned/nonterminal state before and after this operation.
/// This helper never waits, reaps, signals, spawns, or owns a watchdog. Apple
/// Security validation is synchronous and has no cancellation/deadline API.
enum OwnedCurrentSelfAdmission {
    private static var liveValidationFlags: SecCSFlags {
        SecCSFlags(rawValue: kSecCSStrictValidate).union(.noNetworkAccess)
    }
    private static var coreValidationFlags: SecCSFlags {
        SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        ).union(.noNetworkAccess)
    }

    struct SigningMetadata: Equatable {
        let executable: URL
        let identifier: String
        let cdhash: String
    }

    static func current(
        expectedRole: OwnedNativeExecutableRole? = nil
    ) throws -> OwnedCurrentSelfIdentity {
        var rawCode: SecCode?
        try requireSuccess(SecCodeCopySelf([], &rawCode))
        guard let code = rawCode else { throw OwnedCurrentSelfAdmissionError.missingMetadata }
        // Do not use metadata from unsigned/invalid code to establish policy.
        try requireSuccess(SecCodeCheckValidity(code, liveValidationFlags, nil))
        let metadata = try signingMetadata(in: liveSigningInformation(code))
        let role = try executableRole(identifier: metadata.identifier, expectedRole: expectedRole)
        let exact = try requirement(exactRequirementText(role: role, cdhash: metadata.cdhash))
        try requireSuccess(SecCodeCheckValidity(code, liveValidationFlags, exact))

        let executable = try canonicalExistingURL(SelfExecutable.pathURL())
        guard executable == (try canonicalExistingURL(metadata.executable)) else {
            throw OwnedCurrentSelfAdmissionError.executableMismatch
        }
        let core = try associatedCoreArtifact(executable: executable, role: role)
        // A static Core inspection can take time; revalidate the live main role.
        try requireSuccess(SecCodeCheckValidity(code, liveValidationFlags, exact))
        return OwnedCurrentSelfIdentity(
            executable: executable, role: role, identifier: metadata.identifier,
            cdhash: metadata.cdhash, coreArtifact: core
        )
    }

    static func validateOwnedChild(
        pid: Int32,
        matching identity: OwnedCurrentSelfIdentity
    ) throws {
        try validateChildPID(pid, currentPID: getpid())
        try validateIdentityFields(identity)
        let exact = try requirement(exactRequirementText(role: identity.role, cdhash: identity.cdhash))

        var task: mach_port_name_t = mach_port_name_t(MACH_PORT_NULL)
        let nameStatus = task_name_for_pid(mach_task_self_, pid, &task)
        defer {
            if task != mach_port_name_t(MACH_PORT_NULL) { _ = mach_port_deallocate(mach_task_self_, task) }
        }
        guard nameStatus == KERN_SUCCESS, task != mach_port_name_t(MACH_PORT_NULL) else {
            throw OwnedCurrentSelfAdmissionError.auditTokenUnavailable(nameStatus)
        }
        let token = try auditToken(task: task)
        try validateAuditSelection(requestedPID: pid, tokenPID: audit_token_to_pid(token))
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        var rawChild: SecCode?
        // Audit selection is mandatory; PID is an additional matching constraint.
        // Failed audit lookup never falls back to PID-only guest selection.
        try requireSuccess(SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributeAudit: tokenData, kSecGuestAttributePid: pid] as CFDictionary,
            [], &rawChild
        ))
        guard let child = rawChild else { throw OwnedCurrentSelfAdmissionError.missingMetadata }
        try requireSuccess(SecCodeCheckValidity(child, liveValidationFlags, exact))
        let metadata = try signingMetadata(in: liveSigningInformation(child))
        try validateChildMetadata(metadata, matching: identity)
        guard try canonicalExistingURL(metadata.executable) == identity.executable else {
            throw OwnedCurrentSelfAdmissionError.executableMismatch
        }
        _ = try validateAssociatedCoreArtifact(matching: identity)

        // Retain the same task-name port, opaque token and live SecCode through
        // admission. Recheck public PID/version accessors; do not parse val[].
        let afterToken = try auditToken(task: task)
        try validateAuditSelection(requestedPID: pid, tokenPID: audit_token_to_pid(afterToken))
        try validateAuditVersion(
            initial: audit_token_to_pidversion(token), observed: audit_token_to_pidversion(afterToken)
        )
        let afterTokenData = withUnsafeBytes(of: afterToken) { Data($0) }
        guard tokenData == afterTokenData else {
            throw OwnedCurrentSelfAdmissionError.auditTokenMismatch
        }
        try requireSuccess(SecCodeCheckValidity(child, liveValidationFlags, exact))
        withExtendedLifetime((tokenData, child)) {}
    }

    /// Rechecks the associated native framework's named on-disk signature and
    /// selected CDHash against the parent's snapshot. Static validity assumes
    /// no concurrent replacement. It does not attest the child's mapped image.
    @discardableResult
    static func validateAssociatedCoreArtifact(
        matching identity: OwnedCurrentSelfIdentity
    ) throws -> OwnedCoreArtifactIdentity {
        try validateIdentityFields(identity)
        let observed = try associatedCoreArtifact(
            executable: identity.executable, role: identity.role, matching: identity.coreArtifact
        )
        try validateCoreArtifactSnapshot(observed: observed, expected: identity.coreArtifact)
        return observed
    }

    // Pure metadata/selection checks are internal to this helper. Callers must
    // not treat their result as a substitute for Security signature validation.
    static func signingMetadata(in information: [CFString: Any]) throws -> SigningMetadata {
        guard let identifier = information[kSecCodeInfoIdentifier] as? String, !identifier.isEmpty,
              information[kSecCodeInfoTeamIdentifier] as? String
                == ForgeFilesystemProtocolConstants.activeTeamIdentifier,
              let flags = information[kSecCodeInfoFlags] as? NSNumber,
              !SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc),
              let unique = information[kSecCodeInfoUnique] as? Data,
              unique.count == ForgeFilesystemCodeIdentity.codeDirectoryHashBytes,
              let executable = information[kSecCodeInfoMainExecutable] as? URL,
              validFileURL(executable) else {
            throw OwnedCurrentSelfAdmissionError.missingMetadata
        }
        return SigningMetadata(
            executable: executable, identifier: identifier,
            cdhash: unique.map { String(format: "%02x", $0) }.joined()
        )
    }

    static func executableRole(
        identifier: String,
        expectedRole: OwnedNativeExecutableRole? = nil
    ) throws -> OwnedNativeExecutableRole {
        let role: OwnedNativeExecutableRole
        switch identifier {
        case ForgeFilesystemProtocolConstants.managerIdentifier: role = .cli
        case ForgeFilesystemProtocolConstants.appIdentifier: role = .app
        default: throw OwnedCurrentSelfAdmissionError.roleRejected
        }
        guard expectedRole == nil || expectedRole == role else {
            throw OwnedCurrentSelfAdmissionError.roleMismatch
        }
        return role
    }

    static func exactRequirementText(role: OwnedNativeExecutableRole, cdhash: String) throws -> String {
        guard let normalized = ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(cdhash),
              let compiled = ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: role.identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier
              ) else {
            throw OwnedCurrentSelfAdmissionError.invalidIdentity
        }
        return "(\(compiled)) and cdhash H\"\(normalized)\""
    }

    static func validateIdentityFields(_ identity: OwnedCurrentSelfIdentity) throws {
        guard identity.identifier == identity.role.identifier,
              ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(identity.cdhash) == identity.cdhash,
              validFileURL(identity.executable),
              identity.coreArtifact.identifier == ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
              ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(identity.coreArtifact.cdhash)
                == identity.coreArtifact.cdhash,
              validFileURL(identity.coreArtifact.executable) else {
            throw OwnedCurrentSelfAdmissionError.invalidIdentity
        }
    }

    static func validateChildMetadata(_ metadata: SigningMetadata, matching identity: OwnedCurrentSelfIdentity) throws {
        guard metadata.identifier == identity.identifier, metadata.cdhash == identity.cdhash else {
            throw OwnedCurrentSelfAdmissionError.exactIdentityMismatch
        }
    }

    static func validateCoreArtifactSnapshot(
        observed: OwnedCoreArtifactIdentity, expected: OwnedCoreArtifactIdentity
    ) throws {
        guard observed == expected else { throw OwnedCurrentSelfAdmissionError.exactIdentityMismatch }
    }

    static func validateChildPID(_ pid: Int32, currentPID: Int32) throws {
        guard pid > 0, pid != currentPID else { throw OwnedCurrentSelfAdmissionError.invalidChildPID }
    }

    static func validateAuditSelection(requestedPID: Int32, tokenPID: Int32) throws {
        guard requestedPID > 0, requestedPID == tokenPID else {
            throw OwnedCurrentSelfAdmissionError.auditTokenMismatch
        }
    }

    static func validateAuditVersion(initial: Int32, observed: Int32) throws {
        guard initial == observed else { throw OwnedCurrentSelfAdmissionError.auditTokenMismatch }
    }

    static func associatedCoreLocations(executable: URL, role: OwnedNativeExecutableRole) -> [URL] {
        let directory = executable.deletingLastPathComponent()
        var result: [URL] = []
        if directory.deletingLastPathComponent().lastPathComponent == "Contents",
           directory.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app",
           directory.lastPathComponent == (role == .app ? "MacOS" : "Helpers") {
            result.append(directory.deletingLastPathComponent()
                .appendingPathComponent("Frameworks/ForgeConductorCore.framework", isDirectory: true))
        }
        if role == .cli {
            // Existing native manager layout stages the named framework beside CLI.
            result.append(directory.appendingPathComponent("ForgeConductorCore.framework", isDirectory: true))
        }
        return result
    }

    static func frameworkRoot(associatedBundle: URL) throws -> URL {
        if associatedBundle.lastPathComponent == "ForgeConductorCore.framework" { return associatedBundle }
        let versions = associatedBundle.deletingLastPathComponent()
        let framework = versions.deletingLastPathComponent()
        guard versions.lastPathComponent == "Versions",
              framework.lastPathComponent == "ForgeConductorCore.framework" else {
            throw OwnedCurrentSelfAdmissionError.associatedCoreUnavailable
        }
        return framework
    }

    private static func associatedCoreArtifact(
        executable: URL, role: OwnedNativeExecutableRole,
        matching expected: OwnedCoreArtifactIdentity? = nil
    ) throws -> OwnedCoreArtifactIdentity {
        // In SwiftPM ResourceBundle is a resources-only .bundle; it must not be
        // accepted as the native signed Core framework required for this mode.
        let associated = ResourceBundle.bundle
        let framework = try canonicalExistingURL(frameworkRoot(associatedBundle: associated.bundleURL))
        let allowed = associatedCoreLocations(executable: executable, role: role).compactMap { location -> URL? in
            let directory = location.deletingLastPathComponent()
            // Resolve the containing directory, not an arbitrary framework-root
            // symlink. The named framework must stay in its canonical location.
            guard let canonicalDirectory = try? canonicalExistingURL(directory),
                  canonicalDirectory.path == directory.path else { return nil }
            return canonicalDirectory.appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        }
        guard allowed.contains(where: { $0.path == framework.path }), let associatedExecutable = associated.executableURL else {
            throw OwnedCurrentSelfAdmissionError.associatedCoreMismatch
        }
        let coreExecutable = try canonicalExistingURL(associatedExecutable)
        guard coreExecutable.path.hasPrefix(framework.path + "/"),
              coreExecutable.lastPathComponent == "ForgeConductorCore",
              let compiled = ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier
              ) else {
            throw OwnedCurrentSelfAdmissionError.associatedCoreMismatch
        }
        var rawStatic: SecStaticCode?
        try requireSuccess(SecStaticCodeCreateWithPath(framework as CFURL, [], &rawStatic))
        guard let code = rawStatic else { throw OwnedCurrentSelfAdmissionError.missingMetadata }
        try requireSuccess(SecStaticCodeCheckValidity(code, coreValidationFlags, try requirement(compiled)))
        if let expected {
            // The selected architecture's exact hash is a separate validation;
            // a universal artifact has a different CDHash for each architecture.
            let exact = "(\(compiled)) and cdhash H\"\(expected.cdhash)\""
            try requireSuccess(SecStaticCodeCheckValidity(code, liveValidationFlags, try requirement(exact)))
        }
        let metadata = try signingMetadata(in: staticSigningInformation(code))
        guard metadata.identifier == ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
              try canonicalExistingURL(metadata.executable) == coreExecutable else {
            throw OwnedCurrentSelfAdmissionError.associatedCoreMismatch
        }
        return OwnedCoreArtifactIdentity(
            executable: coreExecutable, identifier: metadata.identifier, cdhash: metadata.cdhash
        )
    }

    private static func auditToken(task: mach_port_name_t) throws -> audit_token_t {
        var token = audit_token_t()
        let expected = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        var count = expected
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw OwnedCurrentSelfAdmissionError.auditTokenUnavailable(status) }
        guard count == expected else { throw OwnedCurrentSelfAdmissionError.auditTokenMismatch }
        return token
    }

    private static func liveSigningInformation(_ code: SecCode) throws -> [CFString: Any] {
        // The public SDK accepts live Code or StaticCode. Swift exposes the
        // StaticCode spelling; retain live code while using this common CF API,
        // as ForgeFilesystemCodeIdentity already does. Never use a static origin
        // conversion to replace live signature validation.
        try staticSigningInformation(unsafeBitCast(code, to: SecStaticCode.self))
    }

    private static func staticSigningInformation(_ code: SecStaticCode) throws -> [CFString: Any] {
        var raw: CFDictionary?
        try requireSuccess(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw))
        guard let information = raw as? [CFString: Any] else { throw OwnedCurrentSelfAdmissionError.missingMetadata }
        return information
    }

    private static func requirement(_ text: String) throws -> SecRequirement {
        var result: SecRequirement?
        try requireSuccess(SecRequirementCreateWithString(text as CFString, [], &result))
        guard let result else { throw OwnedCurrentSelfAdmissionError.missingMetadata }
        return result
    }

    private static func canonicalExistingURL(_ url: URL) throws -> URL {
        guard validFileURL(url) else { throw OwnedCurrentSelfAdmissionError.invalidIdentity }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard url.path.withCString({ realpath($0, &buffer) }) != nil else {
            throw OwnedCurrentSelfAdmissionError.executableMismatch
        }
        return URL(fileURLWithPath: String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self
        ))
    }

    private static func validFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.utf8.contains(0)
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw OwnedCurrentSelfAdmissionError.securityFailure(status) }
    }
}
