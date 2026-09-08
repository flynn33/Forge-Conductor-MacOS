import Foundation
import CoreFoundation
import CryptoKit

/// One bounded owner for admitted work. A protocol session is a namespace, never
/// authority. Closed delivery cancels tokens but retains entries until work exits.
final class MCPRequestAdmission: @unchecked Sendable {
    enum Identifier: Hashable, Sendable {
        case string(String)
        case number(String)

        init?(_ value: Any?, strict: Bool = false) {
            if let text = value as? String {
                guard !strict || text.utf8.count <= 256 else { return nil }
                self = .string(text)
            } else if let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() {
                let text = number.stringValue
                if strict {
                    guard let integer = Int64(text), String(integer) == text else { return nil }
                }
                self = .number(text)
            } else { return nil }
        }

        var sha256: String {
            let type: String
            let value: String
            switch self {
            case .string(let text): type = "string"; value = text
            case .number(let text): type = "integer"; value = text
            }
            // Strings and integer decimal strings cannot alias across types.
            let data = try! ForgeJSONCanonicalizationV1.data(from: ["type": type, "value": value])
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Key: Hashable, Sendable {
        case protocolRequest(sessionID: UUID, id: Identifier)
        case nativeProviderCall(conversationID: UUID, referenceSHA256: String)
        case nativeProviderCatalog(conversationID: UUID, requestID: UUID)

        init(sessionID: UUID, id: Identifier) { self = .protocolRequest(sessionID: sessionID, id: id) }

        var protocolSessionID: UUID? {
            guard case .protocolRequest(let sessionID, _) = self else { return nil }
            return sessionID
        }
    }
    enum Registration { case accepted; case duplicate; case capacityExceeded; case closed }
    private struct Entry {
        let token: ToolCallCancellation
        var cancelTask: (@Sendable () -> Void)?
    }
    private let lock = NSLock()
    private let limit: Int
    private var open = true
    private var entries: [Key: Entry] = [:]

    init(maximumActiveRequests: Int = 8) { limit = max(1, min(64, maximumActiveRequests)) }

    func reserve(_ key: Key, cancellation: ToolCallCancellation) -> Registration {
        lock.lock(); defer { lock.unlock() }
        guard open else { return .closed }
        guard entries[key] == nil else { return .duplicate }
        guard entries.count < limit else { return .capacityExceeded }
        entries[key] = Entry(token: cancellation)
        return .accepted
    }

    func bindTask(_ key: Key, cancellation: ToolCallCancellation,
                  cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        guard entries[key]?.token === cancellation else { lock.unlock(); cancel(); return }
        entries[key]?.cancelTask = cancel
        let closed = !open
        lock.unlock()
        if closed { cancellation.cancel(); cancel() }
        // Cancellation before task binding is retained in the same token; the
        // new worker checks that token before dispatching any effect.
    }

    func finish(_ key: Key, cancellation: ToolCallCancellation) {
        lock.lock(); defer { lock.unlock() }
        if entries[key]?.token === cancellation { entries.removeValue(forKey: key) }
    }

    func cancel(_ key: Key) {
        lock.lock(); let entry = entries[key]; lock.unlock()
        entry?.token.cancel(); entry?.cancelTask?()
    }

    func cancel(sessionID: UUID? = nil) {
        lock.lock()
        let retained = entries.filter { sessionID == nil || $0.key.protocolSessionID == sessionID }.map(\.value)
        lock.unlock()
        for entry in retained { entry.token.cancel(); entry.cancelTask?() }
    }

    func setOpen(_ value: Bool) {
        lock.lock(); open = value; lock.unlock()
        if !value { cancel() }
    }

    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    func activeCount(sessionID: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.filter { $0.protocolSessionID == sessionID }.count
    }
}
