import Darwin
import CryptoKit
import Foundation
import ForgeFilesystemProtocol
import Security

public enum ForgeFilesystemQualificationRole: String, Codable, CaseIterable, Sendable {
    case harness
    case adversary

    public var bundleIdentifier: String {
        switch self {
        case .harness:
            "com.forge-conductor.qualification-harness"
        case .adversary:
            "com.forge-conductor.qualification-adversary"
        }
    }
}

public enum ForgeFilesystemQualificationCommand: String, Codable, CaseIterable, Sendable {
    case describe
    case selfCheck = "self-check"
}

public struct ForgeFilesystemQualificationCompletionClaims: Codable, Equatable, Sendable {
    public let e2: Bool
    public let p10: Bool
    public let g10: Bool
    public let g12: Bool
    public let release: Bool

    public init(
        e2: Bool = false,
        p10: Bool = false,
        g10: Bool = false,
        g12: Bool = false,
        release: Bool = false
    ) {
        self.e2 = e2
        self.p10 = p10
        self.g10 = g10
        self.g12 = g12
        self.release = release
    }

    public var isAllFalse: Bool {
        !e2 && !p10 && !g10 && !g12 && !release
    }
}

public struct ForgeFilesystemQualificationReadiness: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let command: ForgeFilesystemQualificationCommand
    public let role: ForgeFilesystemQualificationRole
    public let processID: Int32
    public let parentProcessID: Int32
    public let effectiveUserID: UInt32
    public let executablePath: String
    public let bundleIdentifier: String
    public let signingTeamIdentifier: String
    public let signingEntitlements: [String: String]
    public let codeDirectoryHash: String
    public let hardenedRuntime: Bool
    public let selfIdentityRequirementSatisfied: Bool
    public let daemonClientRequirementSHA256: String
    public let daemonClientRequirementSatisfied: Bool
    public let teamOnlyAdmissionProbeSatisfied: Bool
    public let recorderContextPresent: Bool
    public let supportedCommands: [String]
    public let productionMutationExercised: Bool
    public let qualificationStatus: String
    public let rowsUpdated: Int
    public let formalPredicatesUpdated: Int
    public let completionClaims: ForgeFilesystemQualificationCompletionClaims

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case role
        case processID = "process_id"
        case parentProcessID = "parent_process_id"
        case effectiveUserID = "effective_user_id"
        case executablePath = "executable_path"
        case bundleIdentifier = "bundle_identifier"
        case signingTeamIdentifier = "signing_team_identifier"
        case signingEntitlements = "signing_entitlements"
        case codeDirectoryHash = "code_directory_hash"
        case hardenedRuntime = "hardened_runtime"
        case selfIdentityRequirementSatisfied = "self_identity_requirement_satisfied"
        case daemonClientRequirementSHA256 = "daemon_client_requirement_sha256"
        case daemonClientRequirementSatisfied = "daemon_client_requirement_satisfied"
        case teamOnlyAdmissionProbeSatisfied = "team_only_admission_probe_satisfied"
        case recorderContextPresent = "recorder_context_present"
        case supportedCommands = "supported_commands"
        case productionMutationExercised = "production_mutation_exercised"
        case qualificationStatus = "qualification_status"
        case rowsUpdated = "rows_updated"
        case formalPredicatesUpdated = "formal_predicates_updated"
        case completionClaims = "completion_claims"
    }

    public init(
        schemaVersion: Int = 1,
        command: ForgeFilesystemQualificationCommand,
        role: ForgeFilesystemQualificationRole,
        processID: Int32,
        parentProcessID: Int32,
        effectiveUserID: UInt32,
        executablePath: String,
        bundleIdentifier: String,
        signingTeamIdentifier: String = ForgeFilesystemProtocolConstants.activeTeamIdentifier,
        signingEntitlements: [String: String] = [:],
        codeDirectoryHash: String,
        hardenedRuntime: Bool = true,
        selfIdentityRequirementSatisfied: Bool = true,
        daemonClientRequirementSHA256: String = String(repeating: "d", count: 64),
        daemonClientRequirementSatisfied: Bool = false,
        teamOnlyAdmissionProbeSatisfied: Bool = true,
        recorderContextPresent: Bool,
        supportedCommands: [String] = ForgeFilesystemQualificationCommand.allCases
            .map(\.rawValue).sorted(),
        productionMutationExercised: Bool = false,
        qualificationStatus: String = "not_run",
        rowsUpdated: Int = 0,
        formalPredicatesUpdated: Int = 0,
        completionClaims: ForgeFilesystemQualificationCompletionClaims = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.role = role
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.effectiveUserID = effectiveUserID
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.signingTeamIdentifier = signingTeamIdentifier
        self.signingEntitlements = signingEntitlements
        self.codeDirectoryHash = codeDirectoryHash
        self.hardenedRuntime = hardenedRuntime
        self.selfIdentityRequirementSatisfied = selfIdentityRequirementSatisfied
        self.daemonClientRequirementSHA256 = daemonClientRequirementSHA256
        self.daemonClientRequirementSatisfied = daemonClientRequirementSatisfied
        self.teamOnlyAdmissionProbeSatisfied = teamOnlyAdmissionProbeSatisfied
        self.recorderContextPresent = recorderContextPresent
        self.supportedCommands = supportedCommands
        self.productionMutationExercised = productionMutationExercised
        self.qualificationStatus = qualificationStatus
        self.rowsUpdated = rowsUpdated
        self.formalPredicatesUpdated = formalPredicatesUpdated
        self.completionClaims = completionClaims
    }
}

public struct ForgeFilesystemQualificationControlFrame: Codable, Equatable, Sendable {
    public enum Event: String, Codable, CaseIterable, Sendable {
        case ready
        case release
        case stop
    }

    public let schemaVersion: Int
    public let role: ForgeFilesystemQualificationRole
    public let sequence: UInt64
    public let caseID: String
    public let iteration: Int
    public let event: Event
    public let monotonicTimestampNanoseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case role
        case sequence
        case caseID = "case_id"
        case iteration
        case event
        case monotonicTimestampNanoseconds = "monotonic_timestamp_nanoseconds"
    }

    public init(
        schemaVersion: Int = 1,
        role: ForgeFilesystemQualificationRole,
        sequence: UInt64,
        caseID: String,
        iteration: Int,
        event: Event,
        monotonicTimestampNanoseconds: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.role = role
        self.sequence = sequence
        self.caseID = caseID
        self.iteration = iteration
        self.event = event
        self.monotonicTimestampNanoseconds = monotonicTimestampNanoseconds
    }
}

public struct ForgeFilesystemH0RecorderContext: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let command: ForgeFilesystemQualificationCommand
    public let role: ForgeFilesystemQualificationRole
    public let templateSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case command
        case role
        case templateSHA256 = "template_sha256"
    }
}

public enum ForgeFilesystemQualificationContractError: Error, Equatable, LocalizedError {
    case invalidArguments
    case oversizedJSON
    case malformedJSON
    case unexpectedFields
    case duplicateJSONKey
    case invalidValue(String)
    case recorderContextRequired
    case unsignedExecutable
    case wrongSigningIdentifier
    case privilegedExecutionForbidden
    case qualificationIdentityAuthorized
    case admissionControlProbeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "expected exactly one supported command"
        case .oversizedJSON: "JSON exceeds the qualification bound"
        case .malformedJSON: "JSON is malformed"
        case .unexpectedFields: "JSON contains missing or unexpected fields"
        case .duplicateJSONKey: "JSON contains a duplicate object key"
        case .invalidValue(let field): "invalid value for \(field)"
        case .recorderContextRequired: "bounded H0 recorder context is required"
        case .unsignedExecutable: "a valid signed executable identity is required"
        case .wrongSigningIdentifier: "the executable signing identifier does not match its role"
        case .privilegedExecutionForbidden: "qualification tools must run as a non-root user"
        case .qualificationIdentityAuthorized: "qualification identity must not be daemon-authorized"
        case .admissionControlProbeFailed: "the broad-admission detector did not recognize the current signed identity"
        }
    }
}

private struct ForgeFilesystemStrictJSONKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
    }

    private mutating func parseValue() throws {
        guard index < bytes.count else {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        switch bytes[index] {
        case 0x7B:
            try parseObject()
        case 0x5B:
            try parseArray()
        case 0x22:
            _ = try parseString()
        default:
            try parseScalar()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw ForgeFilesystemQualificationContractError.duplicateJSONKey
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start ..< index])
                do {
                    return try JSONDecoder().decode(String.self, from: encoded)
                } catch {
                    throw ForgeFilesystemQualificationContractError.malformedJSON
                }
            }
            if byte < 0x20 {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else {
                    throw ForgeFilesystemQualificationContractError.malformedJSON
                }
                if bytes[index] == 0x75 {
                    guard index + 4 < bytes.count else {
                        throw ForgeFilesystemQualificationContractError.malformedJSON
                    }
                    index += 5
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        throw ForgeFilesystemQualificationContractError.malformedJSON
    }

    private mutating func parseScalar() throws {
        let start = index
        while index < bytes.count,
              ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

private struct ForgeFilesystemQualificationSigningFacts {
    let identifier: String
    let teamIdentifier: String
    let entitlements: [String: String]
    let codeDirectoryHash: String
    let hardenedRuntime: Bool
}

public enum ForgeFilesystemQualificationContract {
    public static let maximumJSONBytes = 16 * 1024
    public static let maximumRecorderContextBytes = 4 * 1024
    public static let maximumCaseIDBytes = 128
    public static let maximumIteration = 100_000
    public static let recorderContextEnvironmentKey = "FORGE_FILESYSTEM_H0_RECORDER_CONTEXT"
    public static let startSuspendedEnvironmentKey = "FORGE_FILESYSTEM_H0_START_SUSPENDED"

    public static var activeTeamIdentifier: String {
        ForgeFilesystemProtocolConstants.activeTeamIdentifier
    }

    public static func expectedSigningEntitlements(
        for role: ForgeFilesystemQualificationRole
    ) -> [String: String] {
        [
            "com.apple.application-identifier":
                "\(activeTeamIdentifier).\(role.bundleIdentifier)",
        ]
    }

    private static let readinessKeys: Set<String> = [
        "schema_version", "command", "role", "process_id", "parent_process_id",
        "effective_user_id", "executable_path", "bundle_identifier",
        "signing_team_identifier", "signing_entitlements", "code_directory_hash",
        "hardened_runtime", "self_identity_requirement_satisfied",
        "daemon_client_requirement_sha256",
        "daemon_client_requirement_satisfied", "team_only_admission_probe_satisfied",
        "recorder_context_present", "supported_commands",
        "production_mutation_exercised", "qualification_status", "rows_updated",
        "formal_predicates_updated", "completion_claims",
    ]
    private static let completionClaimKeys: Set<String> = [
        "e2", "p10", "g10", "g12", "release",
    ]
    private static let recorderContextKeys: Set<String> = [
        "schema_version", "run_id", "command", "role", "template_sha256",
    ]
    private static let controlFrameKeys: Set<String> = [
        "schema_version", "role", "sequence", "case_id", "iteration", "event",
        "monotonic_timestamp_nanoseconds",
    ]

    public static func parseCommand(arguments: [String]) throws -> ForgeFilesystemQualificationCommand {
        guard arguments.count == 2,
              let command = ForgeFilesystemQualificationCommand(rawValue: arguments[1]) else {
            throw ForgeFilesystemQualificationContractError.invalidArguments
        }
        return command
    }

    public static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumJSONBytes else {
            throw ForgeFilesystemQualificationContractError.oversizedJSON
        }
        return data
    }

    public static func decodeReadiness(_ data: Data) throws -> ForgeFilesystemQualificationReadiness {
        let object = try strictObject(data, maximumBytes: maximumJSONBytes)
        guard Set(object.keys) == readinessKeys,
              let claims = object["completion_claims"] as? [String: Any],
              Set(claims.keys) == completionClaimKeys else {
            throw ForgeFilesystemQualificationContractError.unexpectedFields
        }
        let decoded: ForgeFilesystemQualificationReadiness
        do {
            decoded = try JSONDecoder().decode(ForgeFilesystemQualificationReadiness.self, from: data)
        } catch {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        try validate(decoded)
        return decoded
    }

    public static func decodeControlFrame(_ data: Data) throws -> ForgeFilesystemQualificationControlFrame {
        let object = try strictObject(data, maximumBytes: maximumJSONBytes)
        guard Set(object.keys) == controlFrameKeys else {
            throw ForgeFilesystemQualificationContractError.unexpectedFields
        }
        let decoded: ForgeFilesystemQualificationControlFrame
        do {
            decoded = try JSONDecoder().decode(ForgeFilesystemQualificationControlFrame.self, from: data)
        } catch {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        guard decoded.schemaVersion == 1 else {
            throw ForgeFilesystemQualificationContractError.invalidValue("schema_version")
        }
        try validateCaseID(decoded.caseID)
        guard decoded.sequence > 0 else {
            throw ForgeFilesystemQualificationContractError.invalidValue("sequence")
        }
        guard (0 ... maximumIteration).contains(decoded.iteration) else {
            throw ForgeFilesystemQualificationContractError.invalidValue("iteration")
        }
        guard decoded.monotonicTimestampNanoseconds > 0 else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "monotonic_timestamp_nanoseconds"
            )
        }
        return decoded
    }

    public static func validateSingleComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\0"),
              component.utf8.count <= ForgeFilesystemProtocolConstants.maximumComponentBytes else {
            throw ForgeFilesystemQualificationContractError.invalidValue("component")
        }
    }

    public static func makeReadiness(
        role: ForgeFilesystemQualificationRole,
        command: ForgeFilesystemQualificationCommand,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ForgeFilesystemQualificationReadiness {
        let effectiveUserID = geteuid()
        guard effectiveUserID != 0 else {
            throw ForgeFilesystemQualificationContractError.privilegedExecutionForbidden
        }
        let daemonClientRequirement =
            ForgeFilesystemProtocolConstants.requiredClientCodeSigningRequirement
        guard !currentCodeSatisfies(requirement: daemonClientRequirement) else {
            throw ForgeFilesystemQualificationContractError.qualificationIdentityAuthorized
        }
        let teamOnlyRequirement = "anchor apple generic and certificate leaf[subject.OU] = "
            + "\"\(ForgeFilesystemProtocolConstants.activeTeamIdentifier)\""
        guard currentCodeSatisfies(requirement: teamOnlyRequirement) else {
            throw ForgeFilesystemQualificationContractError.admissionControlProbeFailed
        }

        let executablePath = URL(
            fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]
        ).resolvingSymlinksInPath().standardizedFileURL.path
        guard executablePath.hasPrefix("/") else {
            throw ForgeFilesystemQualificationContractError.invalidValue("executable_path")
        }
        guard let signingFacts = currentSigningFacts() else {
            throw ForgeFilesystemQualificationContractError.unsignedExecutable
        }
        guard signingFacts.identifier == role.bundleIdentifier else {
            throw ForgeFilesystemQualificationContractError.wrongSigningIdentifier
        }
        let activeTeamIdentifier = Self.activeTeamIdentifier
        guard signingFacts.teamIdentifier == activeTeamIdentifier else {
            throw ForgeFilesystemQualificationContractError.invalidValue("signing_team_identifier")
        }
        let applicationIdentifier = "\(activeTeamIdentifier).\(role.bundleIdentifier)"
        guard signingFacts.entitlements == expectedSigningEntitlements(for: role),
              signingFacts.entitlements["com.apple.application-identifier"]
                  == applicationIdentifier else {
            throw ForgeFilesystemQualificationContractError.invalidValue("signing_entitlements")
        }
        guard signingFacts.hardenedRuntime else {
            throw ForgeFilesystemQualificationContractError.invalidValue("hardened_runtime")
        }
        #if DEBUG
        let certificateRequirement =
            "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        #else
        let certificateRequirement =
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        #endif
        let selfIdentityRequirement =
            "anchor apple generic and identifier \"\(role.bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(activeTeamIdentifier)\" "
            + "and \(certificateRequirement)"
        guard currentCodeSatisfies(requirement: selfIdentityRequirement) else {
            throw ForgeFilesystemQualificationContractError.invalidValue(
                "self_identity_requirement_satisfied"
            )
        }

        let rawContext = environment[recorderContextEnvironmentKey]
        if command == .selfCheck, rawContext == nil {
            throw ForgeFilesystemQualificationContractError.recorderContextRequired
        }
        if let rawContext {
            let context = try decodeRecorderContext(rawContext)
            guard context.command == command, context.role == role else {
                throw ForgeFilesystemQualificationContractError.invalidValue("recorder_context")
            }
        }

        let result = ForgeFilesystemQualificationReadiness(
            command: command,
            role: role,
            processID: getpid(),
            parentProcessID: getppid(),
            effectiveUserID: effectiveUserID,
            executablePath: executablePath,
            bundleIdentifier: signingFacts.identifier,
            signingTeamIdentifier: signingFacts.teamIdentifier,
            signingEntitlements: signingFacts.entitlements,
            codeDirectoryHash: signingFacts.codeDirectoryHash,
            hardenedRuntime: signingFacts.hardenedRuntime,
            selfIdentityRequirementSatisfied: true,
            daemonClientRequirementSHA256: sha256(daemonClientRequirement),
            daemonClientRequirementSatisfied: false,
            teamOnlyAdmissionProbeSatisfied: true,
            recorderContextPresent: rawContext != nil
        )
        try validate(result)
        return result
    }

    private static func currentSigningFacts() -> ForgeFilesystemQualificationSigningFacts? {
        var runningCode: SecCode?
        guard SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode else {
            return nil
        }
        var validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        validationFlags.formUnion(.noNetworkAccess)
        guard SecCodeCheckValidity(runningCode, validationFlags, nil) == errSecSuccess else {
            return nil
        }
        let signingInformationCode = unsafeBitCast(runningCode, to: SecStaticCode.self)
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            signingInformationCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
        let information = rawInformation as? [CFString: Any],
        let identifier = information[kSecCodeInfoIdentifier] as? String,
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
        let uniqueHash = information[kSecCodeInfoUnique] as? Data,
        uniqueHash.count == ForgeFilesystemCodeIdentity.codeDirectoryHashBytes,
        let codeDirectoryHash = ForgeFilesystemCodeIdentity.normalizedCodeDirectoryHash(
            uniqueHash.map { String(format: "%02x", $0) }.joined()
        ),
        let codeFlags = information[kSecCodeInfoFlags] as? NSNumber,
        let rawEntitlements = information[kSecCodeInfoEntitlementsDict] as? [String: Any],
        rawEntitlements.count == 1,
        let applicationIdentifier = rawEntitlements[
            "com.apple.application-identifier"
        ] as? String else {
            return nil
        }
        let hardenedRuntime = codeFlags.uint32Value
            & SecCodeSignatureFlags.runtime.rawValue != 0
        return ForgeFilesystemQualificationSigningFacts(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            entitlements: [
                "com.apple.application-identifier": applicationIdentifier,
            ],
            codeDirectoryHash: codeDirectoryHash,
            hardenedRuntime: hardenedRuntime
        )
    }

    private static func decodeRecorderContext(_ raw: String) throws -> ForgeFilesystemH0RecorderContext {
        guard let data = raw.data(using: .utf8), data.count <= maximumRecorderContextBytes else {
            throw ForgeFilesystemQualificationContractError.oversizedJSON
        }
        let object = try strictObject(data, maximumBytes: maximumRecorderContextBytes)
        guard Set(object.keys) == recorderContextKeys else {
            throw ForgeFilesystemQualificationContractError.unexpectedFields
        }
        let context: ForgeFilesystemH0RecorderContext
        do {
            context = try JSONDecoder().decode(ForgeFilesystemH0RecorderContext.self, from: data)
        } catch {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
        guard context.schemaVersion == 1,
              isBoundedIdentifier(context.runID, maximumBytes: 128),
              isLowercaseHex(context.templateSHA256, length: 64) else {
            throw ForgeFilesystemQualificationContractError.invalidValue("recorder_context")
        }
        return context
    }

    private static func validate(_ value: ForgeFilesystemQualificationReadiness) throws {
        guard value.schemaVersion == 1 else {
            throw ForgeFilesystemQualificationContractError.invalidValue("schema_version")
        }
        guard value.processID > 0 else {
            throw ForgeFilesystemQualificationContractError.invalidValue("process_id")
        }
        guard value.parentProcessID > 0 else {
            throw ForgeFilesystemQualificationContractError.invalidValue("parent_process_id")
        }
        guard value.effectiveUserID > 0 else {
            throw ForgeFilesystemQualificationContractError.invalidValue("effective_user_id")
        }
        guard value.executablePath.hasPrefix("/"),
              value.bundleIdentifier == value.role.bundleIdentifier,
              value.signingTeamIdentifier == activeTeamIdentifier,
              value.signingEntitlements == expectedSigningEntitlements(for: value.role),
              isLowercaseHex(
                  value.codeDirectoryHash,
                  length: ForgeFilesystemCodeIdentity.codeDirectoryHashCharacters
              ),
              value.hardenedRuntime,
              value.selfIdentityRequirementSatisfied,
              isLowercaseHex(value.daemonClientRequirementSHA256, length: 64),
              !value.daemonClientRequirementSatisfied,
              value.teamOnlyAdmissionProbeSatisfied,
              value.supportedCommands == ForgeFilesystemQualificationCommand.allCases
                  .map(\.rawValue).sorted(),
              !value.productionMutationExercised,
              value.qualificationStatus == "not_run",
              value.rowsUpdated == 0,
              value.formalPredicatesUpdated == 0,
              value.completionClaims.isAllFalse else {
            throw ForgeFilesystemQualificationContractError.invalidValue("readiness_nonclaim")
        }
        if value.command == .selfCheck, !value.recorderContextPresent {
            throw ForgeFilesystemQualificationContractError.recorderContextRequired
        }
    }

    private static func strictObject(
        _ data: Data,
        maximumBytes: Int
    ) throws -> [String: Any] {
        guard data.count <= maximumBytes else {
            throw ForgeFilesystemQualificationContractError.oversizedJSON
        }
        var keyScanner = ForgeFilesystemStrictJSONKeyScanner(data: data)
        try keyScanner.validate()
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ) as? [String: Any] else {
                throw ForgeFilesystemQualificationContractError.malformedJSON
            }
            return object
        } catch let error as ForgeFilesystemQualificationContractError {
            throw error
        } catch {
            throw ForgeFilesystemQualificationContractError.malformedJSON
        }
    }

    private static func validateCaseID(_ value: String) throws {
        guard isBoundedIdentifier(value, maximumBytes: maximumCaseIDBytes) else {
            throw ForgeFilesystemQualificationContractError.invalidValue("case_id")
        }
    }

    private static func isBoundedIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func currentCodeSatisfies(requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess, let requirement else {
            return false
        }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return false
        }
        var flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        flags.formUnion(.noNetworkAccess)
        return SecCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

public enum ForgeFilesystemQualificationToolMain {
    public static func run(role: ForgeFilesystemQualificationRole) -> Never {
        do {
            if ProcessInfo.processInfo.environment[
                ForgeFilesystemQualificationContract.startSuspendedEnvironmentKey
            ] == "1" {
                guard raise(SIGSTOP) == 0 else {
                    throw ForgeFilesystemQualificationContractError.invalidValue(
                        "start_suspended"
                    )
                }
            }
            let command = try ForgeFilesystemQualificationContract.parseCommand(
                arguments: CommandLine.arguments
            )
            let readiness = try ForgeFilesystemQualificationContract.makeReadiness(
                role: role,
                command: command
            )
            var data = try ForgeFilesystemQualificationContract.canonicalJSON(readiness)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let message = String((error as? LocalizedError)?.errorDescription ?? "qualification error")
                .prefix(512)
            let payload: [String: Any] = [
                "error": "qualification_contract_rejected",
                "message": String(message),
                "schema_version": 1,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) {
                var line = data
                line.append(0x0A)
                FileHandle.standardError.write(line)
            }
            Darwin.exit(EX_USAGE)
        }
    }
}
