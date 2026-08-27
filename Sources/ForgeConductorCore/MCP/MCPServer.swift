// MCPServer.swift
// What: Implements Forge's JSON-RPC MCP server over standard input/output.
// How: A bounded stream reader accepts supported framing, dispatches requests to
// ForgeApp services, and emits newline-delimited responses with role-specific identity.
// Why: The host-facing protocol remains isolated from tools and application composition.

import Foundation
import Darwin
import CoreFoundation

/// JSON-RPC 2.0 MCP server over stdio for **LM Studio** (local models).
public final class MCPServer: @unchecked Sendable {
    public static let defaultMaximumConcurrentRequests = 8
    public static let defaultShutdownWaitSeconds: TimeInterval = 15
    public static let defaultRequestTimeoutSeconds = ToolRouter.defaultCallTimeoutSeconds
    public static let defaultResponseWriteTimeoutSeconds: TimeInterval = 2

    private enum RequestKey: Hashable {
        case string(String)
        case number(String)
    }

    private enum RequestRegistration {
        case accepted(ToolCallCancellation)
        case duplicate
        case capacityExceeded
        case deliveryClosed
    }

    private let app: ForgeApp
    private let clientID: ClientID
    private let role: LMStudioConnectorRole
    private let deploymentID: String
    private let toolDefinitionCatalog: Result<ToolDefinitionCatalog, Error>
    private let maximumConcurrentRequests: Int
    private let shutdownWaitSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private let responseWriteTimeoutSeconds: TimeInterval
    private let requestQueue = DispatchQueue(
        label: "forge.mcp.requests",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let responseWriteLock = NSLock()
    private let cancellationLock = NSLock()
    private let didCloseResponseDeliveryObserver: (@Sendable () -> Void)?
    private var responseDeliveryOpen = false
    private var activeRequests: [RequestKey: ToolCallCancellation] = [:]

    public init(
        app: ForgeApp,
        clientID: ClientID = ClientID(),
        role: LMStudioConnectorRole = LMStudioConnectorRole(
            environmentValue: ProcessInfo.processInfo.environment["FORGE_MCP_ROLE"]
        ),
        maximumConcurrentRequests: Int = MCPServer.defaultMaximumConcurrentRequests,
        shutdownWaitSeconds: TimeInterval = MCPServer.defaultShutdownWaitSeconds,
        requestTimeoutSeconds: TimeInterval = MCPServer.defaultRequestTimeoutSeconds,
        responseWriteTimeoutSeconds: TimeInterval = MCPServer.defaultResponseWriteTimeoutSeconds,
        didCloseResponseDeliveryObserver: (@Sendable () -> Void)? = nil
    ) {
        self.app = app
        self.clientID = clientID
        self.role = role
        self.maximumConcurrentRequests = max(1, min(maximumConcurrentRequests, 64))
        self.shutdownWaitSeconds = max(0.1, min(shutdownWaitSeconds, 30))
        self.requestTimeoutSeconds = requestTimeoutSeconds.isFinite
            ? max(0.001, requestTimeoutSeconds)
            : Self.defaultRequestTimeoutSeconds
        self.responseWriteTimeoutSeconds = responseWriteTimeoutSeconds.isFinite
            ? max(0.01, min(responseWriteTimeoutSeconds, 30))
            : Self.defaultResponseWriteTimeoutSeconds
        self.didCloseResponseDeliveryObserver = didCloseResponseDeliveryObserver
        self.deploymentID = ProcessInfo.processInfo.environment["FORGE_DEPLOYMENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.toolDefinitionCatalog = Result {
            try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
        }
    }

    /// Blocking serve loop: read newline-delimited or Content-Length framed messages from stdin.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) throws {
        // MCP hosts (LM Studio) attach via pipes. Fully-buffered stdout delays
        // initialize responses until the buffer fills → host reports plugin timeout (~60s).
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        setResponseDelivery(open: true)

        app.diagnostics.info("mcp_serve_start", [
            "client_id": clientID.rawValue,
            "role": role.rawValue,
            "host_kind": role.hostKind,
            "deployment_id": deploymentID,
        ])
        // Best-effort presence; never block MCP handshake on a locked GUI store.
        refreshPresence()

        // Idle stdio sessions receive no host messages. Heartbeat on a timer so
        // the dashboard does not treat a live-but-quiet serve as gone.
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "forge.mcp.presence"))
        heartbeat.schedule(deadline: .now() + 10, repeating: 10)
        heartbeat.setEventHandler { [weak self] in
            self?.refreshPresence()
        }
        heartbeat.resume()
        defer { heartbeat.cancel() }

        var lastPresence = Date()
        let reader = MCPStreamReader(handle: input)
        let workers = DispatchGroup()
        let workerErrors = MCPWorkerErrorBox()
        defer {
            reader.close()
            try? app.store.presenceDelete(clientID: presenceID)
            app.diagnostics.info("mcp_serve_end", [
                "client_id": clientID.rawValue,
                "role": role.rawValue,
                "deployment_id": deploymentID,
            ])
        }

        var readerError: Error?
        do {
            while let message = try reader.readMessage() {
                // Refresh presence while the stdio session is active (dashboard TTL ~45s).
                let now = Date()
                if now.timeIntervalSince(lastPresence) >= 15 {
                    refreshPresence()
                    lastPresence = now
                }
                if Self.isNotification(message) {
                    if let response = handle(message) {
                        try write(response, to: output)
                    }
                } else {
                    try dispatchRequest(
                        message,
                        output: output,
                        workers: workers,
                        workerErrors: workerErrors
                    )
                }
            }
        } catch {
            readerError = error
        }

        // EOF or a read failure means the peer has disconnected. Close the
        // delivery boundary before cancellation so unwinding workers cannot
        // emit a response after the transport has ended.
        setResponseDelivery(open: false)
        cancelActiveRequests()
        let workerWait = workers.wait(timeout: .now() + shutdownWaitSeconds)
        if let readerError { throw readerError }
        guard workerWait == .success else {
            throw MCPStreamError.requestShutdownTimedOut(shutdownWaitSeconds)
        }
        if let workerError = workerErrors.take() { throw workerError }
    }

    // MARK: - Message handling

    public func handle(_ message: [String: Any]) -> [String: Any]? {
        handle(message, cancellation: nil)
    }

    func handle(
        _ message: [String: Any],
        cancellation: ToolCallCancellation?
    ) -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String
        // Notification (no id): ignore result
        let isNotification = id == nil || id is NSNull

        guard let method else {
            if isNotification { return nil }
            return errorResponse(id: id, code: -32600, message: "Invalid Request: missing method")
        }

        if method == "notifications/cancelled" {
            let params = message["params"] as? [String: Any] ?? [:]
            if let requestID = Self.requestKey(params["requestId"] ?? params["request_id"]) {
                cancelRequest(requestID)
            }
            return nil
        }
        // Notifications we acknowledge silently
        if method == "notifications/initialized" || method.hasPrefix("notifications/") {
            return nil
        }

        // MCP request methods require a correlatable JSON-RPC identifier. Treat
        // every other id-less/null-id method as an unsupported notification and
        // never dispatch it into a mutating tool path.
        guard !isNotification else { return nil }

        let requestCancellation = cancellation
            ?? ToolCallCancellation(timeoutSeconds: requestTimeoutSeconds)
        do {
            try requestCancellation.checkCancellation()
            if method == "tools/call",
               let milliseconds = try Self.requestedDeadlineMilliseconds(in: message) {
                // A transport-admitted token already carries the earlier absolute
                // deadline, so tightening again here can never discard queue time.
                try requestCancellation.tightenDeadline(milliseconds: milliseconds)
            }
        } catch is CancellationError {
            if isNotification { return nil }
            return errorResponse(id: id, code: -32800, message: "Cancelled")
        } catch is ToolCallDeadlineExceeded {
            if isNotification { return nil }
            return deadlineExceededResponse(id: id, method: method)
        } catch {
            if isNotification { return nil }
            return errorResponse(
                id: id,
                code: -32602,
                message: error.localizedDescription
            )
        }

        do {
            switch method {
            case "initialize":
                // Distinct names so LM Studio can list primary vs fail-forward fallback.
                let serverName = role.serverID
                // Negotiate protocol: LM Studio 0.4.x sends 2025-11-25; older clients send 2024-11-05.
                // Echo a version we support so the host does not hang ~60s on mismatch.
                let params = message["params"] as? [String: Any] ?? [:]
                let requested = (params["protocolVersion"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let negotiated = Self.negotiateProtocolVersion(requested)
                app.diagnostics.info("mcp_initialize", [
                    "requested": requested.isEmpty ? "(none)" : requested,
                    "negotiated": negotiated,
                    "server": serverName,
                    "deployment_id": deploymentID,
                ], category: .mcp)
                return ok(id: id, result: [
                    "protocolVersion": negotiated,
                    "capabilities": [
                        "tools": ["listChanged": false] as [String: Any],
                        "projectMemory": [
                            "capabilityVersion": ProjectMemoryService.capabilityVersion,
                            "schemaVersion": ProjectMemoryRepository.schemaVersion,
                            "limits": app.projectMemory.limits.asDictionary(),
                        ] as [String: Any],
                        "projectContext": [
                            "schemaVersion": ProjectControlPlaneRepository.schemaVersion,
                            "durableBindings": true,
                            "generationFencing": true,
                            "missingContextCode": ProjectContextError.projectContextRequired(
                                ProjectBindingOwner(kind: .mcpClient, id: "capability-probe")
                            ).code,
                        ] as [String: Any],
                    ] as [String: Any],
                    "serverInfo": [
                        "name": serverName,
                        "version": ForgeApp.version,
                    ] as [String: Any],
                ])
            case "ping":
                return ok(id: id, result: [:] as [String: Any])
            case "tools/list":
                let tools = try toolDescriptors()
                app.diagnostics.info("mcp_tools_list", [
                    "count": "\(tools.count)",
                    "client_id": clientID.rawValue,
                    "deployment_id": deploymentID,
                ], category: .mcp)
                return ok(id: id, result: ["tools": tools])
            case "tools/call":
                let params = message["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                app.diagnostics.info("mcp_tools_call", [
                    "tool": name,
                    "client_id": clientID.rawValue,
                ], category: .mcp)
                let result = try app.tools.call(
                    name: name,
                    arguments: arguments,
                    clientID: clientID,
                    cancellation: requestCancellation
                )
                return toolCallResponse(id: id, result: result)
            case "resources/list":
                return ok(id: id, result: ["resources": [] as [Any]])
            case "prompts/list":
                return ok(id: id, result: ["prompts": [] as [Any]])
            default:
                if isNotification { return nil }
                return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }
        } catch is CancellationError {
            if isNotification { return nil }
            return errorResponse(id: id, code: -32800, message: "Cancelled")
        } catch is ToolCallDeadlineExceeded {
            if isNotification { return nil }
            return deadlineExceededResponse(id: id, method: method)
        } catch {
            if isNotification { return nil }
            return errorResponse(id: id, code: -32000, message: "\(error)")
        }
    }

    private var presenceID: String {
        "\(clientID.rawValue):\(role.rawValue)"
    }

    private func refreshPresence() {
        try? app.store.presenceUpsert(
            clientID: presenceID,
            hostKind: role.hostKind,
            pid: ProcessInfo.processInfo.processIdentifier,
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    private func toolDescriptors() throws -> [[String: Any]] {
        try toolDefinitionCatalog.get().mcpDescriptors()
    }

    private static func isNotification(_ message: [String: Any]) -> Bool {
        let id = message["id"]
        return id == nil || id is NSNull
    }

    private func dispatchRequest(
        _ message: [String: Any],
        output: FileHandle,
        workers: DispatchGroup,
        workerErrors: MCPWorkerErrorBox
    ) throws {
        let id = message["id"]
        guard let requestID = Self.requestKey(id) else {
            try write(
                errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: unsupported id"),
                to: output
            )
            return
        }

        let cancellation = ToolCallCancellation(timeoutSeconds: requestTimeoutSeconds)
        switch registerRequest(requestID, cancellation: cancellation) {
        case .deliveryClosed:
            throw MCPStreamError.responseDeliveryClosed
        case .duplicate:
            try write(
                errorResponse(id: id, code: -32600, message: "Invalid Request: duplicate active id"),
                to: output
            )
        case .capacityExceeded:
            try write(
                errorResponse(
                    id: id,
                    code: -32000,
                    message: "Server busy: maximum concurrent requests (\(maximumConcurrentRequests)) reached"
                ),
                to: output
            )
        case .accepted(let cancellation):
            do {
                if let requestedDeadlineMilliseconds = try Self.requestedDeadlineMilliseconds(
                    in: message
                ) {
                    try cancellation.tightenDeadline(
                        milliseconds: requestedDeadlineMilliseconds
                    )
                }
            } catch is CancellationError {
                finishRequest(requestID, cancellation: cancellation)
                try write(errorResponse(id: id, code: -32800, message: "Cancelled"), to: output)
                return
            } catch is ToolCallDeadlineExceeded {
                finishRequest(requestID, cancellation: cancellation)
                try write(deadlineExceededResponse(id: id, method: "tools/call"), to: output)
                return
            } catch {
                finishRequest(requestID, cancellation: cancellation)
                try write(
                    errorResponse(id: id, code: -32602, message: error.localizedDescription),
                    to: output
                )
                return
            }
            let envelope = MCPRequestEnvelope(message)
            workers.enter()
            requestQueue.async { [self] in
                defer {
                    finishRequest(requestID, cancellation: cancellation)
                    workers.leave()
                }
                // The handler response is authoritative once execution returns.
                // Replacing it with a late cancellation can conceal committed mutations.
                guard let response = handle(envelope.message, cancellation: cancellation) else { return }
                do {
                    try write(response, to: output)
                } catch {
                    workerErrors.store(error)
                }
            }
        }
    }

    private func registerRequest(
        _ requestID: RequestKey,
        cancellation: ToolCallCancellation
    ) -> RequestRegistration {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        guard responseDeliveryOpen else { return .deliveryClosed }
        if activeRequests[requestID] != nil { return .duplicate }
        guard activeRequests.count < maximumConcurrentRequests else { return .capacityExceeded }
        activeRequests[requestID] = cancellation
        return .accepted(cancellation)
    }

    private func finishRequest(
        _ requestID: RequestKey,
        cancellation: ToolCallCancellation
    ) {
        cancellationLock.lock()
        if activeRequests[requestID] === cancellation {
            activeRequests.removeValue(forKey: requestID)
        }
        cancellationLock.unlock()
    }

    private func cancelRequest(_ requestID: RequestKey) {
        cancellationLock.lock()
        if let active = activeRequests[requestID] {
            cancellationLock.unlock()
            active.cancel()
            return
        }
        cancellationLock.unlock()
    }

    private func cancelActiveRequests() {
        cancellationLock.lock()
        let active = Array(activeRequests.values)
        cancellationLock.unlock()
        for cancellation in active {
            cancellation.cancel()
        }
    }


    /// Protocol versions we implement (tools list/call). Prefer the client's request when known.
    public static let supportedProtocolVersions: [String] = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    public static func negotiateProtocolVersion(_ requested: String) -> String {
        let r = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return supportedProtocolVersions[0] }
        if supportedProtocolVersions.contains(r) { return r }
        // Unknown future version: advertise newest we support (hosts typically accept).
        return supportedProtocolVersions[0]
    }

    private static func requestKey(_ value: Any?) -> RequestKey? {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return .number(value.stringValue)
        }
        return nil
    }

    private static func requestedDeadlineMilliseconds(
        in message: [String: Any]
    ) throws -> Int? {
        guard message["method"] as? String == "tools/call" else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        return try ToolRouter.requestedDeadlineMilliseconds(in: arguments)
    }

    private func deadlineExceededResponse(id: Any?, method: String) -> [String: Any] {
        guard method == "tools/call" else {
            return errorResponse(id: id, code: -32000, message: "deadline_exceeded")
        }
        return toolCallResponse(
            id: id,
            result: .failure(
                code: "deadline_exceeded",
                message: "Tool call deadline exceeded",
                retryable: true
            )
        )
    }

    private func toolCallResponse(id: Any?, result: ToolResult) -> [String: Any] {
        let text = (try? JSONSupport.string(from: result.payload)) ?? "{\"ok\":false}"
        return ok(id: id, result: [
            "content": [
                ["type": "text", "text": text] as [String: Any],
            ],
            "isError": result.isError || !result.ok,
            "structuredContent": result.payload,
        ])
    }

    private func ok(id: Any?, result: [String: Any]) -> [String: Any] {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { resp["id"] = id }
        return resp
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
        if let id { resp["id"] = id } else { resp["id"] = NSNull() }
        return resp
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        let packet = try MCPStdioTransport.encode(object)
        responseWriteLock.lock()
        defer { responseWriteLock.unlock() }
        guard isResponseDeliveryOpen else { return }
        do {
            try writeBounded(packet, descriptor: handle.fileDescriptor)
        } catch {
            setResponseDelivery(open: false)
            throw error
        }
    }

    private func setResponseDelivery(open: Bool) {
        cancellationLock.lock()
        let didClose = responseDeliveryOpen && !open
        responseDeliveryOpen = open
        let active = open ? [] : Array(activeRequests.values)
        cancellationLock.unlock()
        for cancellation in active {
            cancellation.cancel()
        }
        if didClose {
            didCloseResponseDeliveryObserver?()
        }
    }

    private var isResponseDeliveryOpen: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return responseDeliveryOpen
    }

    private func writeBounded(_ packet: Data, descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF))
        }
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard Darwin.fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        _ = Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1)
        defer { _ = Darwin.fcntl(descriptor, F_SETFL, originalFlags) }

        let timeoutNanoseconds = UInt64(responseWriteTimeoutSeconds * 1_000_000_000)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt.addingReportingOverflow(timeoutNanoseconds).overflow
            ? UInt64.max
            : startedAt + timeoutNanoseconds

        try packet.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < packet.count {
                guard isResponseDeliveryOpen else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    throw MCPStreamError.responseWriteTimedOut(responseWriteTimeoutSeconds)
                }
                let remainingNanoseconds = deadline - now
                let roundedMilliseconds = max(UInt64(1), (remainingNanoseconds + 999_999) / 1_000_000)
                let pollMilliseconds = Int32(min(UInt64(Int32.max), roundedMilliseconds))
                var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let pollResult = Darwin.poll(&writable, 1, pollMilliseconds)
                if pollResult == 0 {
                    throw MCPStreamError.responseWriteTimedOut(responseWriteTimeoutSeconds)
                }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let failureEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                if writable.revents & failureEvents != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
                }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    packet.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(written < 0 ? errno : EIO)
                )
            }
        }
    }
}

/// MCP stdio wire encoder. The specification requires one compact JSON-RPC
/// message per line; Content-Length headers belong to LSP, not MCP stdio.
public enum MCPStdioTransport {
    public static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSupport.data(from: object)
        data.append(0x0A)
        return data
    }
}

private final class MCPRequestEnvelope: @unchecked Sendable {
    let message: [String: Any]

    init(_ message: [String: Any]) {
        self.message = message
    }
}

private final class MCPWorkerErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func store(_ error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }

    func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

// MARK: - Stream reader

public final class MCPStreamReader {
    private let handle: FileHandle
    private let maximumMessageBytes: Int
    private var buffer = Data()

    public init(handle: FileHandle, maximumMessageBytes: Int = 4 * 1024 * 1024) {
        self.handle = handle
        self.maximumMessageBytes = maximumMessageBytes
    }

    /// Releases buffered payload bytes at the serve boundary. The caller owns
    /// the supplied handle, so standard input and test pipes are never closed here.
    public func close() {
        buffer.removeAll(keepingCapacity: false)
    }

    deinit { close() }

    public func readMessage() throws -> [String: Any]? {
        while true {
            if let msg = try extractMessage() {
                return msg
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF
                if buffer.isEmpty { return nil }
                // try parse remaining as NDJSON line
                if let msg = try extractMessage(forceLine: true) {
                    return msg
                }
                return nil
            }
            buffer.append(chunk)
            if buffer.count > maximumMessageBytes {
                throw MCPStreamError.messageTooLarge(maximumMessageBytes)
            }
        }
    }

    private func extractMessage(forceLine: Bool = false) throws -> [String: Any]? {
        // Content-Length framing
        if let range = buffer.range(of: Data("\r\n\r\n".utf8))
            ?? buffer.range(of: Data("\n\n".utf8)) {
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            if let lenLine = header.split(separator: "\n").map(String.init)
                .first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                let parts = lenLine.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    guard length >= 0, length <= maximumMessageBytes else {
                        throw MCPStreamError.messageTooLarge(maximumMessageBytes)
                    }
                    let bodyStart = range.upperBound
                    let needed = buffer.distance(from: bodyStart, to: buffer.endIndex)
                    if needed < length { return nil }
                    let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                    let body = buffer.subdata(in: bodyStart..<bodyEnd)
                    buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                    return try JSONSupport.object(from: body)
                }
            }
        }

        // NDJSON fallback
        if let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty || line == Data([0x0D]) { return try extractMessage(forceLine: forceLine) }
            let trimmed = line.drop(while: { $0 == 0x0D })
            if trimmed.isEmpty { return try extractMessage(forceLine: forceLine) }
            return try JSONSupport.object(from: Data(trimmed))
        }
        if forceLine, !buffer.isEmpty {
            let body = buffer
            buffer.removeAll()
            return try JSONSupport.object(from: body)
        }
        return nil
    }
}

public enum MCPStreamError: Error, LocalizedError, Sendable {
    case messageTooLarge(Int)
    case requestShutdownTimedOut(TimeInterval)
    case responseWriteTimedOut(TimeInterval)
    case responseDeliveryClosed

    public var errorDescription: String? {
        switch self {
        case .messageTooLarge(let maximum):
            "MCP message exceeds the \(maximum)-byte limit"
        case .requestShutdownTimedOut(let seconds):
            "MCP requests did not stop within the \(seconds)-second shutdown deadline"
        case .responseWriteTimedOut(let seconds):
            "MCP response delivery exceeded the \(seconds)-second transport deadline"
        case .responseDeliveryClosed:
            "MCP response delivery is closed"
        }
    }
}
