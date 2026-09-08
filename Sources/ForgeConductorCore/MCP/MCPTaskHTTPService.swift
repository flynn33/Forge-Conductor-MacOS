import Foundation
import Network

struct MCPTaskRequestIdentity: Sendable, Hashable {
    let sessionID: UUID
    let requestIDSHA256: String
    let durableSourceSessionID: UUID?
    init(sessionID: UUID, requestIDSHA256: String, durableSourceSessionID: UUID? = nil) {
        self.sessionID = sessionID; self.requestIDSHA256 = requestIDSHA256
        self.durableSourceSessionID = durableSourceSessionID
    }
}

/// Only a freshly authenticated dispatcher supplies these pins. Protocol session
/// identifiers and model arguments are never accepted as task authority.
protocol MCPTaskHTTPDispatching: Sendable {
    var sessionBindingSHA256: String { get }
    var expiresAt: Date { get }
    func toolDescriptorsJSON() throws -> Data
    func call(name: String, argumentsJSON: Data, identity: MCPTaskRequestIdentity,
              cancellation: ToolCallCancellation) async throws -> ToolResult
}

struct MCPHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func failure(_ status: Int, _ code: String) -> Self {
        .init(status: status, headers: [:], body: Data("{\"ok\":false,\"code\":\"\(code)\"}".utf8))
    }
}

/// Construction requires the native connection's actual path and listener
/// constraint; caller-controlled Host/Origin cannot produce this evidence.
struct MCPHTTPConnectionContext: Sendable {
    let listenerEpoch: UUID
    let serverPort: UInt16
    private init(listenerEpoch: UUID, serverPort: UInt16) {
        self.listenerEpoch = listenerEpoch; self.serverPort = serverPort
    }

    static func verified(connection: NWConnection, listenerEpoch: UUID,
                         serverPort: UInt16, requiresLoopback: Bool) -> Self? {
        guard requiresLoopback, let path = connection.currentPath,
              path.usesInterfaceType(.loopback),
              isLoopback(path.localEndpoint), isLoopback(path.remoteEndpoint),
              case .hostPort(_, let port)? = path.localEndpoint, port.rawValue == serverPort else { return nil }
        return Self(listenerEpoch: listenerEpoch, serverPort: serverPort)
    }

    private static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            return bytes.count == 16 && bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        default: return false
        }
    }
}

/// Manager owns this service. Authentication and execution both reserve bounded
/// capacity before task creation; no connection owns an unbounded waiting queue.
final class MCPTaskHTTPService: @unchecked Sendable {
    static let path = "/mcp/continuity"
    static let protocolVersion = "2025-11-25"
    static let maximumResponseBytes = 1024 * 1024
    typealias Authenticate = @Sendable (NativeTaskCapabilityCredential, ToolCallCancellation) async throws -> any MCPTaskHTTPDispatching

    private struct Session {
        let id: UUID
        let listenerEpoch: UUID
        let binding: String
        let expiresAt: Date
        var lastUsed: Date
        var ready = false
    }
    private struct Authentication {
        let listenerEpoch: UUID
        let token: ToolCallCancellation
        let handle: MCPHTTPTaskHandle
        let startedAt: UInt64
    }
    private let authenticate: Authenticate
    private let clock: any Clock
    private let admission: MCPRequestAdmission
    private let lock = NSLock()
    private var open = true
    private var operational = false
    private var listenerEpoch: UUID?
    private var sessions: [UUID: Session] = [:]
    private var authentications: [UUID: Authentication] = [:]
    private var operationalRequests: Set<MCPRequestAdmission.Key> = []

    init(clock: any Clock = SystemClock(), authenticate: @escaping Authenticate) {
        self.clock = clock; self.authenticate = authenticate
        admission = MCPRequestAdmission(maximumActiveRequests: 8)
    }

    func setOperational(_ value: Bool) {
        lock.lock(); operational = value
        let cancel = value ? [] : Array(operationalRequests)
        lock.unlock()
        for key in cancel { admission.cancel(key) }
    }

    /// Called before the native listener accepts. Rebinding retires every old
    /// protocol session while preserving the separate durable capability.
    func listenerStarted(epoch: UUID) {
        lock.lock()
        let previous = listenerEpoch
        listenerEpoch = epoch
        let oldSessions = Array(sessions.keys)
        sessions.removeAll()
        let oldAuth = authentications.values.filter { $0.listenerEpoch == previous }
        lock.unlock()
        for id in oldSessions { admission.cancel(sessionID: id) }
        for auth in oldAuth { auth.token.cancel(); auth.handle.cancel() }
    }

    func listenerInvalidated(epoch: UUID) {
        lock.lock()
        if listenerEpoch == epoch { listenerEpoch = nil }
        let oldSessions = sessions.values.filter { $0.listenerEpoch == epoch }.map(\.id)
        for id in oldSessions { sessions.removeValue(forKey: id) }
        let oldAuth = authentications.values.filter { $0.listenerEpoch == epoch }
        lock.unlock()
        for id in oldSessions { admission.cancel(sessionID: id) }
        for auth in oldAuth { auth.token.cancel(); auth.handle.cancel() }
    }

    func closeAdmission() {
        lock.lock(); open = false
        let owned = Array(authentications.values)
        sessions.removeAll(); listenerEpoch = nil
        lock.unlock()
        admission.setOpen(false)
        for auth in owned { auth.token.cancel(); auth.handle.cancel() }
    }

    func shutdown() async -> Bool {
        closeAdmission()
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        while retainedWorkCount > 0 {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
        }
        return true
    }

    var retainedWorkCount: Int {
        lock.lock(); let count = authentications.count; lock.unlock()
        return count + admission.activeCount
    }

    @discardableResult
    func receive(_ request: DashboardHTTPRequest, connection: MCPHTTPConnectionContext,
                 completion: @escaping @Sendable (MCPHTTPResponse) -> Void) -> Bool {
        guard request.target == Self.path else { return false }
        guard Self.validOrigin(request, port: connection.serverPort) else {
            completion(.failure(403, "origin_rejected")); return true
        }
        guard let authorization = request[header: "authorization"], authorization.hasPrefix("Bearer "),
              let credential = try? NativeTaskCapabilityCredential(authorizationValue: String(authorization.dropFirst(7))) else {
            completion(.failure(401, "task_capability_required")); return true
        }
        let authenticationID = UUID()
        let token = ToolCallCancellation(timeoutSeconds: 3)
        let handle = MCPHTTPTaskHandle()
        lock.lock()
        guard open, listenerEpoch == connection.listenerEpoch else {
            lock.unlock(); completion(.failure(503, "attachment_unavailable")); return true
        }
        guard authentications.count < 8 else {
            lock.unlock(); completion(.failure(503, "authentication_busy")); return true
        }
        authentications[authenticationID] = .init(listenerEpoch: connection.listenerEpoch, token: token,
            handle: handle, startedAt: DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
        let task = Task { [self] in
            defer { handle.finish() }
            do {
                try Task.checkCancellation(); try token.checkCancellation()
                let dispatcher = try await authenticate(credential, token)
                try token.checkCancellation()
                await authenticated(request, connection: connection, authenticationID: authenticationID,
                                    dispatcher: dispatcher, completion: completion)
            } catch {
                finishAuthentication(authenticationID)
                completion(.failure(401, "task_capability_rejected"))
            }
        }
        handle.bind(task)
        return true
    }

    private func finishAuthentication(_ id: UUID) {
        lock.lock(); authentications.removeValue(forKey: id); lock.unlock()
    }

    private func authenticated(_ request: DashboardHTTPRequest, connection: MCPHTTPConnectionContext,
                               authenticationID: UUID, dispatcher: any MCPTaskHTTPDispatching,
                               completion: @escaping @Sendable (MCPHTTPResponse) -> Void) async {
        // This synchronous boundary atomically exchanges the authentication slot
        // for an execution slot. Notifications finish within the bounded preflight.
        let decision = prepare(request, connection: connection, authenticationID: authenticationID,
                               dispatcher: dispatcher)
        switch decision {
        case .response(let response): completion(response)
        case .execute(let work):
            defer { finishWork(work) }
            let result: MCPHTTPResponse
            do {
                try Task.checkCancellation(); try work.cancellation.checkCancellation()
                result = try await execute(work, dispatcher: dispatcher)
            } catch is CancellationError {
                result = Self.rpcError(id: work.idJSON, code: -32800, message: "Cancelled")
            } catch is ToolCallDeadlineExceeded {
                result = Self.rpcError(id: work.idJSON, code: -32000, message: "deadline_exceeded")
            } catch {
                result = Self.rpcError(id: work.idJSON, code: -32000, message: "request_failed")
            }
            // A retired listener cannot disclose a late response; actual committed
            // results stay durable and can be queried using a new authenticated session.
            let deliver = canDeliver(epoch: connection.listenerEpoch)
            completion(deliver ? result : .failure(503, "attachment_unavailable"))
        }
    }

    private func finishWork(_ work: Work) {
        lock.lock(); operationalRequests.remove(work.key); lock.unlock()
        admission.finish(work.key, cancellation: work.cancellation)
    }

    private func canDeliver(epoch: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return open && listenerEpoch == epoch
    }

    private struct Work: Sendable {
        let key: MCPRequestAdmission.Key
        let cancellation: ToolCallCancellation
        let idJSON: Data
        let method: String
        let name: String?
        let argumentsJSON: Data
        let initialization: Bool
        let durableSourceSessionID: UUID?
    }
    private enum Decision { case response(MCPHTTPResponse); case execute(Work) }

    private func prepare(_ request: DashboardHTTPRequest, connection: MCPHTTPConnectionContext,
                         authenticationID: UUID, dispatcher: any MCPTaskHTTPDispatching) -> Decision {
        lock.lock(); defer { lock.unlock() }
        defer { authentications.removeValue(forKey: authenticationID) }
        guard open, listenerEpoch == connection.listenerEpoch else { return .response(.failure(503, "attachment_unavailable")) }
        let now = clock.now()
        guard dispatcher.expiresAt > now else { return .response(.failure(401, "task_capability_rejected")) }
        sessions = sessions.filter { id, session in
            admission.activeCount(sessionID: id) > 0 || (session.expiresAt > now && now.timeIntervalSince(session.lastUsed) < 600)
        }
        if let version = request[header: "mcp-protocol-version"], version != Self.protocolVersion {
            return .response(.failure(400, "unsupported_protocol_version"))
        }
        guard request.method == "POST" else {
            return .response(.init(status: 405, headers: ["Allow": "POST"], body: Data()))
        }
        guard request.body.count <= DashboardHTTPRequestParser.maximumBodyBytes,
              request[header: "content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              Self.acceptsJSON(request[header: "accept"]) else { return .response(.failure(415, "mcp_json_required")) }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return .response(.failure(400, "invalid_json_rpc"))
        }
        let id = MCPRequestAdmission.Identifier(message["id"], strict: true)
        let initializing = method == "initialize"
        let sessionID: UUID
        if initializing {
            guard request[header: "mcp-session-id"] == nil, id != nil,
                  (message["params"] as? [String: Any])?["protocolVersion"] as? String == Self.protocolVersion else {
                return .response(.failure(400, "unsupported_initialization"))
            }
            guard sessions.count < 32 else { return .response(.failure(503, "session_capacity")) }
            sessionID = UUID()
        } else {
            guard let raw = request[header: "mcp-session-id"], let parsed = UUID(uuidString: raw),
                  raw == parsed.uuidString.lowercased(), let session = sessions[parsed],
                  session.binding == dispatcher.sessionBindingSHA256,
                  session.listenerEpoch == connection.listenerEpoch, session.expiresAt > now else {
                return .response(.failure(404, "session_not_found"))
            }
            guard request[header: "mcp-protocol-version"] == Self.protocolVersion else {
                return .response(.failure(400, "protocol_version_required"))
            }
            sessionID = parsed
            sessions[sessionID]?.lastUsed = now
            if method == "notifications/initialized", message["id"] == nil {
                sessions[sessionID]?.ready = true
                return .response(.init(status: 202, headers: [:], body: Data()))
            }
            if method == "notifications/cancelled", message["id"] == nil {
                let params = message["params"] as? [String: Any]
                if let target = MCPRequestAdmission.Identifier(params?["requestId"], strict: true) {
                    admission.cancel(.init(sessionID: sessionID, id: target))
                }
                return .response(.init(status: 202, headers: [:], body: Data()))
            }
            guard sessions[sessionID]?.ready == true || method == "ping" else {
                return .response(.failure(400, "session_not_initialized"))
            }
        }
        if message["id"] == nil {
            return .response(.init(status: 202, headers: [:], body: Data()))
        }
        guard let id, let rawID = message["id"],
              let idJSON = try? JSONSerialization.data(withJSONObject: rawID, options: [.fragmentsAllowed]) else {
            return .response(.failure(400, "invalid_request_id"))
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String
        var durableSourceSessionID: UUID?
        if method == "tools/call" {
            guard let name, MCPNativeTaskSourceProfile.toolNames.contains(name),
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return .response(Self.rpcError(id: idJSON, code: -32602, message: "tool_not_allowed"))
            }
            if MCPNativeTaskSourceProfile.sourceToolNames.contains(name) {
                guard let raw = request[header: "forge-source-session-id"], raw.utf8.count == 36,
                      let namespace = UUID(uuidString: raw), namespace.uuidString.lowercased() == raw else {
                    return .response(Self.rpcError(id: idJSON, code: -32602, message: "source_session_id_required"))
                }
                durableSourceSessionID = namespace
            }
            if !operational && !MCPNativeTaskSourceProfile.stoppedToolNames.contains(name) {
                return .response(Self.rpcError(id: idJSON, code: -32000, message: "service_stopped"))
            }
        }
        guard let arguments = try? ForgeJSONCanonicalizationV1.data(from: params["arguments"] as? [String: Any] ?? [:]) else {
            return .response(Self.rpcError(id: idJSON, code: -32602, message: "invalid_arguments"))
        }
        guard let authentication = authentications[authenticationID] else { return .response(.failure(503, "attachment_unavailable")) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - authentication.startedAt) / 1_000_000_000
        let token = ToolCallCancellation(timeoutSeconds: min(max(0.001, 300 - elapsed), dispatcher.expiresAt.timeIntervalSince(now)))
        let key = MCPRequestAdmission.Key(sessionID: sessionID, id: id)
        switch admission.reserve(key, cancellation: token) {
        case .duplicate: return .response(Self.rpcError(id: idJSON, code: -32600, message: "duplicate_active_id"))
        case .capacityExceeded: return .response(.failure(503, "request_capacity"))
        case .closed: return .response(.failure(503, "attachment_unavailable"))
        case .accepted: break
        }
        if method == "tools/call", let name, !MCPNativeTaskSourceProfile.stoppedToolNames.contains(name) {
            operationalRequests.insert(key)
        }
        admission.bindTask(key, cancellation: token) { authentication.handle.cancel() }
        if initializing {
            sessions[sessionID] = .init(id: sessionID, listenerEpoch: connection.listenerEpoch,
                binding: dispatcher.sessionBindingSHA256,
                expiresAt: min(dispatcher.expiresAt, now.addingTimeInterval(3600)), lastUsed: now)
        }
        return .execute(.init(key: key, cancellation: token, idJSON: idJSON, method: method,
                              name: name, argumentsJSON: arguments, initialization: initializing,
                              durableSourceSessionID: durableSourceSessionID))
    }

    private func execute(_ work: Work, dispatcher: any MCPTaskHTTPDispatching) async throws -> MCPHTTPResponse {
        let id = try JSONSerialization.jsonObject(with: work.idJSON, options: [.fragmentsAllowed])
        let body: Data
        switch work.method {
        case "initialize":
            body = try JSONSupport.data(from: ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": Self.protocolVersion, "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "forge-native-task-source", "version": ForgeApp.version],
            ] as [String: Any]])
        case "ping": body = try JSONSupport.data(from: ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]])
        case "tools/list":
            let tools = try JSONSerialization.jsonObject(with: dispatcher.toolDescriptorsJSON())
            body = try JSONSupport.data(from: ["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
        case "tools/call":
            let result = try await dispatcher.call(name: work.name!, argumentsJSON: work.argumentsJSON,
                identity: .init(sessionID: work.key.sessionID, requestIDSHA256: work.key.id.sha256,
                                durableSourceSessionID: work.durableSourceSessionID),
                cancellation: work.cancellation)
            body = try MCPToolResponse.data(id: id, result: result)
        default: return Self.rpcError(id: work.idJSON, code: -32601, message: "method_not_found")
        }
        guard body.count <= Self.maximumResponseBytes else { throw MCPTaskHTTPError.responseTooLarge }
        return .init(status: 200,
            headers: work.initialization ? ["Mcp-Session-Id": work.key.sessionID.uuidString.lowercased()] : [:], body: body)
    }

    private static func rpcError(id: Data, code: Int, message: String) -> MCPHTTPResponse {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": (try? JSONSerialization.jsonObject(with: id, options: [.fragmentsAllowed])) ?? NSNull(),
                                  "error": ["code": code, "message": message] as [String: Any]]
        return .init(status: 200, headers: [:], body: (try? JSONSupport.data(from: object)) ?? Data())
    }

    private static func validOrigin(_ request: DashboardHTTPRequest, port: UInt16) -> Bool {
        // Apply the existing mutation policy to every method without requiring a
        // meaningless JSON content type for authenticated GET/DELETE rejection.
        var policyRequest = request
        policyRequest.method = "POST"
        policyRequest.headers["content-type"] = "application/json"
        return DashboardRequestPolicy.rejection(for: policyRequest, serverPort: port) == nil
    }

    private static func acceptsJSON(_ value: String?) -> Bool {
        guard let value else { return false }
        let types = value.lowercased().split(separator: ",").map { $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "" }
        return types.contains("application/json") && types.contains("text/event-stream")
    }
}

enum MCPTaskHTTPError: Error { case responseTooLarge }

enum MCPNativeTaskSourceProfile {
    static let sourceToolNames: Set<String> = ["fs_read", "session_checkpoint", "session_handoff"]
    static let toolNames: Set<String> = ["fs_read", "session_checkpoint", "session_handoff",
        "clu_capabilities", "clu_start_handoff", "clu_status", "clu_cancel"]
    static let stoppedToolNames: Set<String> = ["clu_capabilities", "clu_status", "clu_cancel"]
}

/// Binding may race a very fast worker or cancellation. This small owner retains
/// cancellation before the Task exists and drops the Task after actual exit.
private final class MCPHTTPTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var finished = false
    func bind(_ task: Task<Void, Never>) {
        lock.lock()
        if !finished { self.task = task }
        let cancel = cancelled
        lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func finish() { lock.lock(); finished = true; task = nil; lock.unlock() }
}
