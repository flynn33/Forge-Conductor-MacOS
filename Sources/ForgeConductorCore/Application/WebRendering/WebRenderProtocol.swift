// Fixed bounded protocol for the owned same-executable WebKit child.
// Actual pipe EOF and signed child admission belong to the native transport owner.
import Foundation
import CoreFoundation

enum WebRenderProtocolError: Error, Equatable {
    case invalidFrame, invalidJSON, noncanonicalJSON, invalidField(String), mismatchedReply
}

enum WebRenderProtocol {
    static let version = "forge.web.render.v1"
    static let internalArgument = "--internal-web-render-v1"
    static let maximumRequestBodyBytes = 16_384
    static let maximumReplyBodyBytes = 32_768
    static let maximumTextBytes = 8_192
    static let maximumTitleBytes = 512
    static let maximumNodes = 4_096
    static let maximumURLBytes = 8_192

    /// The existing codec remains v1 unless its native caller explicitly selects v2.
    enum Profile: Sendable, Equatable {
        case v1, completeV2
        var version: String { self == .v1 ? WebRenderProtocol.version : "forge.web.render.v2" }
        var internalArgument: String { self == .v1 ? WebRenderProtocol.internalArgument : "--internal-web-render-v2" }
        var maximumTextBytes: Int { self == .v1 ? WebRenderProtocol.maximumTextBytes : 1_048_576 }
        var maximumNodes: Int { self == .v1 ? WebRenderProtocol.maximumNodes : 65_536 }
        // One JSON byte can require six escaped ASCII bytes. Metadata is bounded separately.
        var maximumReplyBodyBytes: Int {
            self == .v1 ? WebRenderProtocol.maximumReplyBodyBytes
                : 6 * (maximumTextBytes + WebRenderProtocol.maximumTitleBytes + WebRenderProtocol.maximumURLBytes) + 4_096
        }
        var maximumDOMBodyBytes: Int { 6 * (maximumTextBytes + WebRenderProtocol.maximumTitleBytes) + 1_024 }
        static func forInternalArgument(_ value: String?) -> Profile? {
            switch value {
            case WebRenderProtocol.internalArgument: .v1
            case "--internal-web-render-v2": .completeV2
            default: nil
            }
        }
    }

    enum Outcome: String, Sendable {
        case rendered, navigationFailed, downloadDenied, redirectLimit
        case contentProcessTerminated, deadline, cancelled, unsupported, protocolError, identityRejected
        case snapshotOverflow = "snapshot_overflow"
    }
    enum Readiness: String, Sendable { case boundedStability, maximumSettle, unavailable }
    enum Lifetime: String, Sendable { case notCreated, released, unreleasedAtDeadline, notObserved }

    struct Request: Equatable, Sendable {
        let requestID: UUID
        let nonce: UUID
        let projectID: UUID
        let projectGeneration: UInt64
        let url: String
        let deadlineUptimeNanoseconds: UInt64
    }

    struct Reply: Equatable, Sendable {
        let requestID: UUID
        let nonce: UUID
        let projectID: UUID
        let projectGeneration: UInt64
        let outcome: Outcome
        let finalURL: String
        let title: String
        let text: String
        let nodesVisited: Int
        let textTruncated: Bool
        let titleTruncated: Bool
        let readiness: Readiness
        let snapshotExtracted: Bool
        let lockdownEnabled: Bool
        let viewLifetime: Lifetime
        let storeLifetime: Lifetime

        func replacingText(_ value: String) -> Reply {
            Reply(requestID: requestID, nonce: nonce, projectID: projectID, projectGeneration: projectGeneration,
                  outcome: outcome, finalURL: finalURL, title: title, text: value, nodesVisited: nodesVisited,
                  textTruncated: textTruncated || value != text, titleTruncated: titleTruncated,
                  readiness: readiness, snapshotExtracted: snapshotExtracted, lockdownEnabled: lockdownEnabled,
                  viewLifetime: viewLifetime, storeLifetime: storeLifetime)
        }
        func replacingLifetime(view: Lifetime, store: Lifetime) -> Reply {
            Reply(requestID: requestID, nonce: nonce, projectID: projectID, projectGeneration: projectGeneration,
                  outcome: outcome, finalURL: finalURL, title: title, text: text, nodesVisited: nodesVisited,
                  textTruncated: textTruncated, titleTruncated: titleTruncated,
                  readiness: readiness, snapshotExtracted: snapshotExtracted, lockdownEnabled: lockdownEnabled,
                  viewLifetime: view, storeLifetime: store)
        }
    }

    private static let requestKeys: Set<String> = [
        "version", "request_id", "nonce", "project_id", "project_generation", "url",
        "deadline_uptime_ns",
    ]
    private static let replyKeys: Set<String> = [
        "version", "request_id", "nonce", "project_id", "project_generation", "outcome",
        "final_url", "title", "text", "text_bytes", "nodes_visited", "text_truncated",
        "title_truncated", "readiness", "snapshot_extracted", "lockdown_enabled",
        "view_lifetime", "store_lifetime",
    ]

    static func encodeRequest(_ request: Request, profile: Profile = .v1) throws -> Data {
        let values: [String: Any] = [
            "version": profile.version, "request_id": identifier(request.requestID), "nonce": identifier(request.nonce),
            "project_id": identifier(request.projectID), "project_generation": String(request.projectGeneration),
            "url": request.url, "deadline_uptime_ns": String(request.deadlineUptimeNanoseconds),
        ]
        let body = try canonical(values)
        _ = try decodeRequestBody(body, profile: profile)
        return try frame(body, maximumBodyBytes: maximumRequestBodyBytes)
    }

    static func decodeRequestFrame(_ bytes: Data, profile: Profile = .v1) throws -> Request {
        try decodeRequestBody(body(bytes, maximumBodyBytes: maximumRequestBodyBytes), profile: profile)
    }

    static func decodeRequestBody(_ bytes: Data, profile: Profile = .v1) throws -> Request {
        let values = try object(bytes, keys: requestKeys, maximumBytes: maximumRequestBodyBytes)
        guard try string(values, "version") == profile.version else { throw WebRenderProtocolError.invalidField("version") }
        let url = try string(values, "url")
        try validateURL(url)
        return Request(requestID: try uuid(values, "request_id"), nonce: try uuid(values, "nonce"),
                       projectID: try uuid(values, "project_id"),
                       projectGeneration: try decimal(values, "project_generation", positive: true), url: url,
                       deadlineUptimeNanoseconds: try decimal(values, "deadline_uptime_ns", positive: true))
        // The child validates runtime deadline/self role before creating WebKit.
    }

    static func encodeReply(_ reply: Reply, matching request: Request, profile: Profile = .v1) throws -> Data {
        let values: [String: Any] = [
            "version": profile.version, "request_id": identifier(reply.requestID), "nonce": identifier(reply.nonce),
            "project_id": identifier(reply.projectID), "project_generation": String(reply.projectGeneration),
            "outcome": reply.outcome.rawValue, "final_url": reply.finalURL, "title": reply.title, "text": reply.text,
            "text_bytes": reply.text.utf8.count, "nodes_visited": reply.nodesVisited,
            "text_truncated": reply.textTruncated, "title_truncated": reply.titleTruncated,
            "readiness": reply.readiness.rawValue, "snapshot_extracted": reply.snapshotExtracted,
            "lockdown_enabled": reply.lockdownEnabled,
            "view_lifetime": reply.viewLifetime.rawValue, "store_lifetime": reply.storeLifetime.rawValue,
        ]
        let body = try canonical(values)
        _ = try decodeReplyBody(body, matching: request, profile: profile)
        return try frame(body, maximumBodyBytes: profile.maximumReplyBodyBytes)
        // v1 may reduce text to its legacy frame cap; v2 retains complete text or fails.
    }

    static func decodeReplyFrame(_ bytes: Data, matching request: Request, profile: Profile = .v1) throws -> Reply {
        try decodeReplyBody(body(bytes, maximumBodyBytes: profile.maximumReplyBodyBytes), matching: request, profile: profile)
    }

    static func decodeReplyBody(_ bytes: Data, matching request: Request, profile: Profile = .v1) throws -> Reply {
        let values = try object(bytes, keys: replyKeys, maximumBytes: profile.maximumReplyBodyBytes)
        guard try string(values, "version") == profile.version else { throw WebRenderProtocolError.invalidField("version") }
        let requestID = try uuid(values, "request_id"), nonce = try uuid(values, "nonce")
        let projectID = try uuid(values, "project_id")
        let generation = try decimal(values, "project_generation", positive: true)
        guard requestID == request.requestID, nonce == request.nonce,
              projectID == request.projectID, generation == request.projectGeneration else {
            throw WebRenderProtocolError.mismatchedReply
        }
        guard let outcome = Outcome(rawValue: try string(values, "outcome")),
              profile == .completeV2 || outcome != .snapshotOverflow,
              let readiness = Readiness(rawValue: try string(values, "readiness")),
              let viewLifetime = Lifetime(rawValue: try string(values, "view_lifetime")),
              let storeLifetime = Lifetime(rawValue: try string(values, "store_lifetime")) else {
            throw WebRenderProtocolError.invalidField("outcome/readiness/lifetime")
        }
        let finalURL = try string(values, "final_url"), title = try string(values, "title"), text = try string(values, "text")
        if !finalURL.isEmpty { try validateURL(finalURL) }
        guard title.utf8.count <= maximumTitleBytes, text.utf8.count <= profile.maximumTextBytes,
              try integer(values, "text_bytes", range: 0...profile.maximumTextBytes) == text.utf8.count else {
            throw WebRenderProtocolError.invalidField("title/text/text_bytes")
        }
        let snapshotExtracted = try boolean(values, "snapshot_extracted")
        let lockdownEnabled = try boolean(values, "lockdown_enabled")
        if profile == .completeV2, try boolean(values, "text_truncated") {
            throw WebRenderProtocolError.invalidField("complete text_truncated")
        }
        if outcome == .rendered {
            guard !finalURL.isEmpty, snapshotExtracted, lockdownEnabled, readiness != .unavailable else {
                throw WebRenderProtocolError.invalidField("rendered fields")
            }
        } else {
            guard text.isEmpty, title.isEmpty, !snapshotExtracted, readiness == .unavailable else {
                throw WebRenderProtocolError.invalidField("failure fields")
            }
        }
        return Reply(requestID: requestID, nonce: nonce, projectID: projectID, projectGeneration: generation,
                     outcome: outcome, finalURL: finalURL, title: title, text: text,
                     nodesVisited: try integer(values, "nodes_visited", range: 0...profile.maximumNodes),
                     textTruncated: try boolean(values, "text_truncated"),
                     titleTruncated: try boolean(values, "title_truncated"), readiness: readiness,
                     snapshotExtracted: snapshotExtracted, lockdownEnabled: lockdownEnabled,
                     viewLifetime: viewLifetime, storeLifetime: storeLifetime)
    }

    /// Decodes only the fixed v2 extractor's bounded result, including explicit overflow.
    struct CompleteSnapshot {
        let title: String, text: String
        let nodes: Int
        let titleTruncated: Bool, overflow: Bool
        init(_ data: Data) throws {
            let profile = Profile.completeV2
            guard !data.isEmpty, data.count <= profile.maximumDOMBodyBytes,
                  String(data: data, encoding: .utf8) != nil,
                  let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(values.keys) == ["title", "text", "nodes", "truncated", "title_truncated", "overflow"] else {
                throw WebRenderProtocolError.invalidJSON
            }
            let title = try WebRenderProtocol.string(values, "title")
            let text = try WebRenderProtocol.string(values, "text")
            let overflow = try WebRenderProtocol.boolean(values, "overflow")
            let titleTruncated = try WebRenderProtocol.boolean(values, "title_truncated")
            guard title.utf8.count <= WebRenderProtocol.maximumTitleBytes,
                  text.utf8.count <= profile.maximumTextBytes,
                  !(try WebRenderProtocol.boolean(values, "truncated")),
                  !overflow || (text.isEmpty && title.isEmpty && !titleTruncated) else {
                throw WebRenderProtocolError.invalidField("complete snapshot")
            }
            self.title = title; self.text = text; self.overflow = overflow
            self.titleTruncated = titleTruncated
            nodes = try WebRenderProtocol.integer(values, "nodes", range: 0...profile.maximumNodes)
        }
    }

    static func frame(_ body: Data, maximumBodyBytes: Int) throws -> Data {
        guard !body.isEmpty, body.count <= maximumBodyBytes, body.count <= Int(UInt32.max) else {
            throw WebRenderProtocolError.invalidFrame
        }
        let size = UInt32(body.count)
        var bytes = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        bytes.append(body)
        return bytes
    }

    static func body(_ frame: Data, maximumBodyBytes: Int) throws -> Data {
        guard frame.count >= 4, frame.count <= maximumBodyBytes + 4 else { throw WebRenderProtocolError.invalidFrame }
        let prefix = Array(frame.prefix(4))
        let size = Int(UInt32(prefix[0]) << 24 | UInt32(prefix[1]) << 16 | UInt32(prefix[2]) << 8 | UInt32(prefix[3]))
        guard size > 0, size <= maximumBodyBytes, frame.count == size + 4 else { throw WebRenderProtocolError.invalidFrame }
        return Data(frame.dropFirst(4))
        // This finite Data check cannot prove real pipe EOF; transport must prove it separately.
    }

    private static func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func object(_ bytes: Data, keys: Set<String>, maximumBytes: Int) throws -> [String: Any] {
        guard !bytes.isEmpty, bytes.count <= maximumBytes, String(data: bytes, encoding: .utf8) != nil else {
            throw WebRenderProtocolError.invalidJSON
        }
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(value.keys) == keys else {
            throw WebRenderProtocolError.invalidJSON
        }
        // The sole producer uses this exact canonical encoder. Re-encoding rejects
        // duplicate-key loss, extra whitespace, alternate escapes and number spellings.

        guard try canonical(value) == bytes else { throw WebRenderProtocolError.noncanonicalJSON }
        return value
    }

    private static func string(_ values: [String: Any], _ key: String) throws -> String {
        guard let value = values[key] as? String else { throw WebRenderProtocolError.invalidField(key) }
        return value
    }
    private static func uuid(_ values: [String: Any], _ key: String) throws -> UUID {
        let value = try string(values, key)
        guard let parsed = UUID(uuidString: value), identifier(parsed) == value else { throw WebRenderProtocolError.invalidField(key) }
        return parsed
    }
    private static func decimal(_ values: [String: Any], _ key: String, positive: Bool) throws -> UInt64 {
        let value = try string(values, key)
        guard !value.isEmpty, value.utf8.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = UInt64(value), String(parsed) == value, !positive || parsed > 0 else {
            throw WebRenderProtocolError.invalidField(key)
        }
        return parsed
    }
    private static func integer(_ values: [String: Any], _ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: value.objCType)),
              let parsed = Int(value.stringValue), range.contains(parsed) else { throw WebRenderProtocolError.invalidField(key) }
        return parsed
    }
    private static func boolean(_ values: [String: Any], _ key: String) throws -> Bool {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw WebRenderProtocolError.invalidField(key)
        }
        return value.boolValue
    }
    private static func identifier(_ value: UUID) -> String { value.uuidString.lowercased() }
    static func validatedURL(_ value: String) throws -> URL {
        guard !value.isEmpty, value.utf8.count <= maximumURLBytes,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let result = components.url else {
            throw WebRenderProtocolError.invalidField("url")
        }
        return result // Fragments are retained for JavaScript hash routers.
    }
    private static func validateURL(_ value: String) throws { _ = try validatedURL(value) }

    static func isAttachmentDisposition(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }

    static func prefixUTF8(_ value: String, bytes: Int) -> String {
        let prefix = Data(value.utf8.prefix(max(0, bytes)))
        for trim in 0...min(3, prefix.count) {
            if let result = String(data: prefix.prefix(prefix.count - trim), encoding: .utf8) { return result }
        }
        return ""
    }
}

/// Only compiled CLI/app entry code selects this role; it is never a model argument.
public enum WebRenderProductRole: String, Sendable {
    case cli = "com.forge-conductor.cli"
    case app = "com.forge-conductor.app"
}

enum WebRenderError: Error, Sendable, Equatable, LocalizedError {
    case invalidArgument(String), unsupportedOS, busy, stopped, workerRequired
    case deadline, cancelled, identityRejected, transportFailed, invalidResponse, terminationUnconfirmed, outputBudget

    var code: String {
        switch self {
        case .invalidArgument: "invalid_argument"
        case .unsupportedOS: "web_render_unsupported"
        case .busy: "web_render_busy"
        case .stopped: "web_render_stopped"
        case .workerRequired: "web_render_worker_required"
        case .deadline: "web_render_timeout"
        case .cancelled: "web_render_cancelled"
        case .identityRejected: "web_render_identity_rejected"
        case .transportFailed: "web_render_transport_error"
        case .invalidResponse: "web_render_invalid_response"
        case .terminationUnconfirmed: "web_render_termination_unconfirmed"
        case .outputBudget: "web_render_output_budget"
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidArgument(let field): "Invalid renderer argument: \(field)"
        case .unsupportedOS: "JavaScript rendering requires macOS 27 or later"
        case .busy: "The renderer already owns an active request"
        case .stopped: "The renderer is shutting down"
        case .workerRequired: "Rendering must be invoked on a worker executor"
        case .deadline: "The renderer deadline expired"
        case .cancelled: "Rendering was cancelled"
        case .identityRejected: "Rendering requires the validated native Forge executable and its matching signed Core framework"
        case .transportFailed: "The owned renderer transport failed"
        case .invalidResponse: "The renderer returned an invalid or incomplete response"
        case .terminationUnconfirmed: "The owned renderer did not confirm termination"
        case .outputBudget: "The inline budget cannot hold a render result"
        }
    }
}
