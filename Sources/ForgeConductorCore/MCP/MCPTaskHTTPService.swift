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

/// Native calls are resolved from a durable accepted provider turn. Ordinary
/// HTTP dispatchers need not implement this additive manager-owned entry point.
protocol MCPNativeSourceDispatching: MCPTaskHTTPDispatching {
    func nativeProviderTools(credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation) async throws -> [Data]
    func resolveNativeProviderCall(reference: NativeSourceProviderCallReference,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation) async throws -> ResolvedNativeSourceProviderCall
    func submitNativeCall(resolved: ResolvedNativeSourceProviderCall,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget,
        cancellation: ToolCallCancellation) async throws -> NativeSourceProviderCallOutput
}

enum MCPNativeSourceBridgeError: Error, Sendable, Equatable {
    case unavailable, stopped, authenticationCapacity, executionCapacity
    case duplicateActiveRequest, unsupportedDispatcher, deliveryUnavailable
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
        var nativeSource = false
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
    // A projection of admitted native work, retained until its exact Task exits.
    // It does not create a second execution pool or protocol-session registry.
    private var nativeExecutionEpochs: [MCPRequestAdmission.Key: UUID] = [:]

    init(clock: any Clock = SystemClock(), authenticate: @escaping Authenticate) {
        self.clock = clock; self.authenticate = authenticate
        admission = MCPRequestAdmission(maximumActiveRequests: 8)
    }

    func setOperational(_ value: Bool) {
        lock.lock(); operational = value
        let cancel = value ? [] : Array(operationalRequests)
        let cancelAuth = value ? [] : authentications.values.filter(\.nativeSource)
        lock.unlock()
        for key in cancel { admission.cancel(key) }
        for auth in cancelAuth { auth.token.cancel(); auth.handle.cancel() }
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
        let native = nativeExecutionEpochs.filter { $0.value != epoch }.map(\.key)
        lock.unlock()
        for id in oldSessions { admission.cancel(sessionID: id) }
        for key in native { admission.cancel(key) }
        for auth in oldAuth { auth.token.cancel(); auth.handle.cancel() }
    }

    func listenerInvalidated(epoch: UUID) {
        lock.lock()
        if listenerEpoch == epoch { listenerEpoch = nil }
        let oldSessions = sessions.values.filter { $0.listenerEpoch == epoch }.map(\.id)
        for id in oldSessions { sessions.removeValue(forKey: id) }
        let oldAuth = authentications.values.filter { $0.listenerEpoch == epoch }
        let native = nativeExecutionEpochs.filter { $0.value == epoch }.map(\.key)
        lock.unlock()
        for id in oldSessions { admission.cancel(sessionID: id) }
        for key in native { admission.cancel(key) }
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

    func nativeProviderTools(credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation) async throws -> [Data] {
        let requestID = UUID()
        return try await performNative(credential: credential, cancellation: cancellation, prepare: { dispatcher, token in
            let tools = try await dispatcher.nativeProviderTools(credential: credential, lease: lease, cancellation: token)
            guard let expiry = ISO8601.date(from: lease.expiresAt) else { throw NativeSourceConversationError.integrityFailure }
            return NativePrepared(key: .nativeProviderCatalog(conversationID: lease.conversationID, requestID: requestID),
                expiresAt: expiry, value: tools)
        }, execute: { _, tools, _ in tools })
    }

    func submitNativeCall(credential: NativeTaskCapabilityCredential,
        reference: NativeSourceProviderCallReference, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget,
        cancellation: ToolCallCancellation) async throws -> NativeSourceProviderCallOutput {
        try await performNative(credential: credential, cancellation: cancellation, prepare: { dispatcher, token in
            let resolved = try await dispatcher.resolveNativeProviderCall(reference: reference,
                credential: credential, lease: lease, cancellation: token)
            guard MCPNativeTaskSourceProfile.sourceToolNames.contains(resolved.toolName),
                  !resolved.callID.isEmpty, resolved.callID.utf8.count <= 512,
                  !resolved.callID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let expiry = ISO8601.date(from: lease.expiresAt) else { throw NativeSourceConversationError.integrityFailure }
            let digest = try ForgeJSONCanonicalizationV1.sha256Hex(of: [
                "stage_id": resolved.reference.stageID.uuidString.lowercased(), "ordinal": resolved.reference.ordinal,
                "response_id": resolved.responseID, "call_id": resolved.callID,
            ])
            return NativePrepared(key: .nativeProviderCall(conversationID: resolved.reference.conversationID,
                referenceSHA256: digest), expiresAt: expiry, value: resolved)
        }, execute: { dispatcher, resolved, token in
            try await dispatcher.submitNativeCall(resolved: resolved, credential: credential,
                lease: lease, outputBudget: outputBudget, cancellation: token)
        })
    }

    private struct NativePrepared<Value: Sendable>: Sendable {
        let key: MCPRequestAdmission.Key
        let expiresAt: Date
        let value: Value
    }
    private struct NativeWork {
        let key: MCPRequestAdmission.Key
        let epoch: UUID
        let cancellation: ToolCallCancellation
    }

    /// Each call owns its token. A source exchange never lends this slot to a
    /// provider POST; authentication and execution share the HTTP service pools.
    private func performNative<Value: Sendable, Output: Sendable>(
        credential: NativeTaskCapabilityCredential, cancellation: ToolCallCancellation,
        prepare: @escaping @Sendable (any MCPNativeSourceDispatching, ToolCallCancellation) async throws -> NativePrepared<Value>,
        execute: @escaping @Sendable (any MCPNativeSourceDispatching, Value, ToolCallCancellation) async throws -> Output
    ) async throws -> Output {
        let authenticationID = UUID()
        let authenticationToken = ToolCallCancellation(timeoutSeconds: min(3, cancellation.remainingTimeInterval ?? 3))
        let handle = MCPHTTPTaskHandle()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); try cancellation.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try reserveNativeAuthentication(id: authenticationID, token: authenticationToken, handle: handle)
                } catch { continuation.resume(throwing: error); return }
                let task = Task { [self] in
                    var work: NativeWork?
                    defer {
                        if let work { finishNativeWork(work) }
                        finishAuthentication(authenticationID)
                        handle.finish()
                    }
                    do {
                        try Task.checkCancellation(); try cancellation.checkCancellation()
                        try authenticationToken.checkCancellation()
                        let authenticated = try await authenticate(credential, authenticationToken)
                        guard let dispatcher = authenticated as? any MCPNativeSourceDispatching else {
                            throw MCPNativeSourceBridgeError.unsupportedDispatcher
                        }
                        try cancellation.checkCancellation(); try authenticationToken.checkCancellation()
                        let prepared = try await prepare(dispatcher, authenticationToken)
                        try Task.checkCancellation(); try cancellation.checkCancellation()
                        try authenticationToken.checkCancellation()
                        let admitted = try exchangeNativeAuthentication(id: authenticationID, prepared: prepared,
                            dispatcher: dispatcher, cancellation: cancellation)
                        work = admitted
                        try Task.checkCancellation(); try cancellation.checkCancellation()
                        let value = try await execute(dispatcher, prepared.value, cancellation)
                        guard canDeliverNative(epoch: admitted.epoch) else { throw MCPNativeSourceBridgeError.deliveryUnavailable }
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
                handle.bind(task)
            }
        } onCancel: {
            authenticationToken.cancel(); cancellation.cancel(); handle.cancel()
        }
    }

    private func reserveNativeAuthentication(id: UUID, token: ToolCallCancellation, handle: MCPHTTPTaskHandle) throws {
        lock.lock(); defer { lock.unlock() }
        guard open, let epoch = listenerEpoch else { throw MCPNativeSourceBridgeError.unavailable }
        guard operational else { throw MCPNativeSourceBridgeError.stopped }
        guard authentications.count < 8 else { throw MCPNativeSourceBridgeError.authenticationCapacity }
        try token.checkCancellation()
        authentications[id] = .init(listenerEpoch: epoch, token: token, handle: handle,
            startedAt: DispatchTime.now().uptimeNanoseconds, nativeSource: true)
    }

    private func exchangeNativeAuthentication<Value: Sendable>(id: UUID, prepared: NativePrepared<Value>,
        dispatcher: any MCPNativeSourceDispatching, cancellation: ToolCallCancellation) throws -> NativeWork {
        lock.lock(); defer { lock.unlock() }
        guard let authentication = authentications[id], open, listenerEpoch == authentication.listenerEpoch else {
            throw MCPNativeSourceBridgeError.unavailable
        }
        guard operational else { throw MCPNativeSourceBridgeError.stopped }
        let now = clock.now()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - authentication.startedAt) / 1_000_000_000
        let remaining = min(300 - elapsed, min(dispatcher.expiresAt, prepared.expiresAt).timeIntervalSince(now))
        guard remaining > 0 else { throw ToolCallDeadlineExceeded() }
        try cancellation.tightenDeadline(milliseconds: Int(remaining * 1_000))
        switch admission.reserve(prepared.key, cancellation: cancellation) {
        case .accepted: break
        case .duplicate: throw MCPNativeSourceBridgeError.duplicateActiveRequest
        case .capacityExceeded: throw MCPNativeSourceBridgeError.executionCapacity
        case .closed: throw MCPNativeSourceBridgeError.unavailable
        }
        authentications.removeValue(forKey: id)
        operationalRequests.insert(prepared.key)
        nativeExecutionEpochs[prepared.key] = authentication.listenerEpoch
        admission.bindTask(prepared.key, cancellation: cancellation) { authentication.handle.cancel() }
        return .init(key: prepared.key, epoch: authentication.listenerEpoch, cancellation: cancellation)
    }

    private func finishNativeWork(_ work: NativeWork) {
        lock.lock()
        operationalRequests.remove(work.key)
        nativeExecutionEpochs.removeValue(forKey: work.key)
        lock.unlock()
        admission.finish(work.key, cancellation: work.cancellation)
    }

    private func canDeliverNative(epoch: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return open && operational && listenerEpoch == epoch
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
        let sessionID: UUID
        let requestIDSHA256: String
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
        return .execute(.init(key: key, sessionID: sessionID, requestIDSHA256: id.sha256,
                              cancellation: token, idJSON: idJSON, method: method,
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
                identity: .init(sessionID: work.sessionID, requestIDSHA256: work.requestIDSHA256,
                                durableSourceSessionID: work.durableSourceSessionID),
                cancellation: work.cancellation)
            body = try MCPToolResponse.data(id: id, result: result)
        default: return Self.rpcError(id: work.idJSON, code: -32601, message: "method_not_found")
        }
        guard body.count <= Self.maximumResponseBytes else { throw MCPTaskHTTPError.responseTooLarge }
        return .init(status: 200,
            headers: work.initialization ? ["Mcp-Session-Id": work.sessionID.uuidString.lowercased()] : [:], body: body)
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

    /// Pure catalog conversion for local request preflight. The admitted method
    /// above additionally verifies the live task lease before exposing tools.
    static func providerToolDefinitions(catalog: ToolDefinitionCatalog) throws -> [Data] {
        let definitions = try catalog.providerToolDefinitions(allowedToolNames: sourceToolNames)
        let names = try definitions.map { try JSONSupport.object(from: $0)["name"] as? String }
        guard definitions.count == sourceToolNames.count,
              Set(names.compactMap { $0 }) == sourceToolNames else { throw NativeTaskCapabilityError.unsupportedProfile }
        return definitions
    }
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
