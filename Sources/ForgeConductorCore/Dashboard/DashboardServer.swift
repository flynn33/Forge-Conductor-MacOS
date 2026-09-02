// DashboardServer.swift
// What: Owns the native Network.framework loopback HTTP listener.
// How: It accepts bounded connections, delegates parsing/policy and route selection,
// and uses HTTPResponder for transport output while ManagerNode owns server lifetime.
// Why: One listener module prevents routes from mixing business logic with socket state.

import Foundation
import Network

/// Synchronizes the listener's asynchronous bind result with the thread waiting in
/// `DashboardServer.start()`. Network.framework invokes state callbacks concurrently,
/// so a locked reference avoids capturing and mutating a local variable across tasks.
private final class DashboardBindResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }

    func recordedError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

/// Loopback HTTP control surface: status, agents, sessions, audit, diagnostics, manager controls.
/// Routing is delegated to modular route handlers (Telemetry / Manager / Operational).
public final class DashboardServer: @unchecked Sendable {
    static let maximumActiveConnections = 64
    static let incompleteRequestTimeoutSeconds: TimeInterval = 10
    static let bindTimeoutSeconds: TimeInterval = 3
    /// Covers one failed three-second bind, the five-second durable-config lock,
    /// one three-second restoration bind, and response scheduling, then fails closed.
    static let gracefulResponseDrainTimeoutSeconds: TimeInterval = 12
    private static let minimumIncompleteRequestTimeoutSeconds: TimeInterval = 0.05

    private struct ActiveConnection {
        let connection: NWConnection
        var incompleteRequestDeadlineUptimeNanoseconds: UInt64?
    }

    private let app: ForgeApp
    private let host: String
    private let port: UInt16
    private let activeConnectionLimit: Int
    private let incompleteRequestTimeout: TimeInterval
    private var listener: NWListener?
    private var incompleteRequestTimer: DispatchSourceTimer?
    private var gracefulDrainTimer: DispatchSourceTimer?
    private var gracefulDrainRetain: DashboardServer?
    private let queue = DispatchQueue(label: "forge.dashboard", qos: .userInitiated)
    private let gracefulDrainQueue = DispatchQueue(
        label: "forge.dashboard.response-drain",
        qos: .utility
    )
    private let lock = NSLock()
    private let http = HTTPResponder()
    private var acceptingConnections = false
    private var isGracefullyDraining = false
    private var activeConnections: [ObjectIdentifier: ActiveConnection] = [:]
    private var running = false

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Optional supervisor; when set, manager control APIs are available.
    public weak var manager: ManagerNode?

    public var boundHost: String { host }
    public var boundPort: UInt16 { port }

    var activeConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections.count
    }

    public init(app: ForgeApp, host: String? = nil, port: UInt16? = nil) {
        self.app = app
        self.host = host ?? app.config.string("dashboard", "host", default: "127.0.0.1")
        let cfgPort = app.config.int("dashboard", "port", default: 7788)
        self.port = port ?? UInt16(clamping: cfgPort)
        activeConnectionLimit = Self.maximumActiveConnections
        incompleteRequestTimeout = Self.incompleteRequestTimeoutSeconds
    }

    init(
        app: ForgeApp,
        host: String? = nil,
        port: UInt16? = nil,
        activeConnectionLimit: Int,
        incompleteRequestTimeout: TimeInterval
    ) {
        self.app = app
        self.host = host ?? app.config.string("dashboard", "host", default: "127.0.0.1")
        let cfgPort = app.config.int("dashboard", "port", default: 7788)
        self.port = port ?? UInt16(clamping: cfgPort)
        self.activeConnectionLimit = min(max(activeConnectionLimit, 1), Self.maximumActiveConnections)
        self.incompleteRequestTimeout = min(
            max(incompleteRequestTimeout, Self.minimumIncompleteRequestTimeoutSeconds),
            Self.incompleteRequestTimeoutSeconds
        )
    }

    deinit {
        stop()
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)/")!
    }

    public func start() throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard DashboardRequestPolicy.isConfiguredLoopbackHost(host) else {
            throw DashboardError.nonLoopbackHost(host)
        }

        // Fail closed if another process already owns the port (dual Forge / foreign app).
        let state = DashboardPortGuard.inspect(host: host, port: Int(port))
        switch state {
        case .free, .heldBySelf:
            break
        case .heldByOtherForge(let h):
            let msg = "Dashboard port \(port) held by another Forge process pid=\(h.pid.map(String.init) ?? "?") cmd=\(h.command ?? "?"). Stop the other instance or run only one product (LaunchAgent manager OR GUI), not both claiming HTTP."
            app.diagnostics.error("dashboard_port_conflict_forge", [
                "port": "\(port)",
                "holder_pid": h.pid.map(String.init) ?? "",
                "holder": h.command ?? "",
            ], category: .manager)
            throw DashboardError.portInUse(msg)
        case .heldByForeign(let h):
            let msg = "Dashboard port \(port) held by non-Forge process pid=\(h.pid.map(String.init) ?? "?") cmd=\(h.command ?? "?")."
            app.diagnostics.error("dashboard_port_conflict_foreign", [
                "port": "\(port)",
                "holder_pid": h.pid.map(String.init) ?? "",
                "holder": h.command ?? "",
            ], category: .manager)
            throw DashboardError.portInUse(msg)
        case .unknown(let d):
            app.diagnostics.warn("dashboard_port_unknown", ["detail": d], category: .manager)
        }

        let params = NWParameters.tcp
        // Do NOT reuse address for product dashboard — second instance must fail clearly.
        params.allowLocalEndpointReuse = false
        if host == "127.0.0.1" || host == "localhost" {
            params.requiredInterfaceType = .loopback
        }

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let incompleteRequestTimer = DispatchSource.makeTimerSource(queue: queue)
        incompleteRequestTimer.schedule(deadline: .distantFuture)
        incompleteRequestTimer.setEventHandler { [weak self] in
            self?.expireIncompleteConnections()
        }
        incompleteRequestTimer.resume()
        let gate = DispatchSemaphore(value: 0)
        let bindResult = DashboardBindResult()
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.app.diagnostics.info("dashboard_ready", [
                    "url": self?.baseURL.absoluteString ?? "",
                    "pid": "\(ProcessInfo.processInfo.processIdentifier)",
                ], category: .manager)
                gate.signal()
            case .failed(let err):
                self?.app.diagnostics.error("dashboard_failed", [
                    "error": "\(err)",
                    "port": "\(self?.port ?? 0)",
                ], category: .manager)
                bindResult.record(error: err)
                gate.signal()
            case .waiting(let err):
                bindResult.record(error: err)
                gate.signal()
            case .cancelled:
                bindResult.record(error: DashboardError.startCancelled)
                gate.signal()
            default:
                break
            }
        }
        lock.lock()
        guard self.listener == nil else {
            lock.unlock()
            incompleteRequestTimer.cancel()
            listener.cancel()
            return
        }
        self.listener = listener
        self.incompleteRequestTimer = incompleteRequestTimer
        acceptingConnections = true
        lock.unlock()

        listener.start(queue: queue)
        let wait = gate.wait(timeout: .now() + Self.bindTimeoutSeconds)
        if wait == .timedOut {
            stop()
            app.diagnostics.error("dashboard_bind_timeout", ["port": "\(port)"], category: .manager)
            throw DashboardError.bindTimeout(port)
        }
        if let bindError = bindResult.recordedError() {
            stop()
            throw bindError
        }

        lock.lock()
        guard self.listener === listener, acceptingConnections else {
            lock.unlock()
            listener.cancel()
            throw DashboardError.startCancelled
        }
        running = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        acceptingConnections = false
        let activeListener = listener
        let activeIncompleteRequestTimer = incompleteRequestTimer
        let activeGracefulDrainTimer = gracefulDrainTimer
        listener = nil
        self.incompleteRequestTimer = nil
        gracefulDrainTimer = nil
        gracefulDrainRetain = nil
        isGracefullyDraining = false
        running = false
        let connections = Array(activeConnections.values)
        activeConnections.removeAll(keepingCapacity: false)
        lock.unlock()

        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()
        activeIncompleteRequestTimer?.cancel()
        activeGracefulDrainTimer?.setEventHandler {}
        activeGracefulDrainTimer?.cancel()
        for record in connections {
            record.connection.cancel()
        }
    }

    /// Stops accepting immediately while allowing only requests that have already
    /// parsed completely to send their final response. The active registry is
    /// strictly capped, incomplete clients are cancelled synchronously, and one
    /// deadline force-closes any response that does not finish on its own.
    func stopAllowingCompletedResponses(
        timeout: TimeInterval = DashboardServer.gracefulResponseDrainTimeoutSeconds
    ) {
        let boundedTimeout = min(
            max(timeout, Self.minimumIncompleteRequestTimeoutSeconds),
            Self.gracefulResponseDrainTimeoutSeconds
        )

        lock.lock()
        acceptingConnections = false
        let activeListener = listener
        let activeIncompleteRequestTimer = incompleteRequestTimer
        listener = nil
        self.incompleteRequestTimer = nil
        running = false

        let incompleteIdentifiers = activeConnections.compactMap { element in
            element.value.incompleteRequestDeadlineUptimeNanoseconds == nil
                ? nil
                : element.key
        }
        let incompleteConnections = incompleteIdentifiers.compactMap {
            activeConnections.removeValue(forKey: $0)?.connection
        }

        if !activeConnections.isEmpty, !isGracefullyDraining {
            isGracefullyDraining = true
            gracefulDrainRetain = self
            let timer = DispatchSource.makeTimerSource(queue: gracefulDrainQueue)
            timer.schedule(
                deadline: .now() + boundedTimeout,
                leeway: .milliseconds(20)
            )
            timer.setEventHandler { [weak self] in
                self?.forceCloseGracefulDrain(timeout: boundedTimeout)
            }
            gracefulDrainTimer = timer
            timer.resume()
        }
        lock.unlock()

        activeListener?.newConnectionHandler = nil
        activeListener?.cancel()
        activeIncompleteRequestTimer?.cancel()
        incompleteConnections.forEach { $0.cancel() }
    }

    /// Run until interrupted (SIGINT/SIGTERM).
    public func runForever() throws {
        try start()
        fputs("Forge-Conductor dashboard: \(baseURL.absoluteString)\n", stderr)
        let sem = DispatchSemaphore(value: 0)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sigInt.setEventHandler { sem.signal() }
        sigTerm.setEventHandler { sem.signal() }
        sigInt.resume()
        sigTerm.resume()
        defer {
            sigInt.setEventHandler {}
            sigTerm.setEventHandler {}
            sigInt.cancel()
            sigTerm.cancel()
            stop()
        }
        sem.wait()
    }

    // MARK: - Connection

    private func handle(connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        let timeoutNanoseconds = UInt64((incompleteRequestTimeout * 1_000_000_000).rounded(.up))
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        lock.lock()
        guard acceptingConnections, activeConnections.count < activeConnectionLimit else {
            let activeCount = activeConnections.count
            lock.unlock()
            app.diagnostics.warn("dashboard_connection_capacity_rejected", [
                "active": "\(activeCount)",
                "limit": "\(activeConnectionLimit)",
            ], category: .manager)
            connection.cancel()
            return
        }
        activeConnections[identifier] = ActiveConnection(
            connection: connection,
            incompleteRequestDeadlineUptimeNanoseconds: deadline
        )
        scheduleNextIncompleteRequestDeadlineLocked()
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.app.diagnostics.warn(
                    "dashboard_connection_failed",
                    ["error": "\(error)"],
                    category: .manager
                )
                self?.removeConnection(identifier)
            case .cancelled:
                self?.removeConnection(identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, identifier: identifier, buffer: Data())
    }

    private func receive(
        on connection: NWConnection,
        identifier: ObjectIdentifier,
        buffer: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.app.diagnostics.warn("dashboard_recv_error", ["error": "\(error)"])
                self.removeConnection(identifier)
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            switch DashboardHTTPRequestParser.parse(buf, streamComplete: isComplete) {
            case .incomplete:
                self.receive(on: connection, identifier: identifier, buffer: buf)
            case .rejected(let status, let message):
                guard self.markRequestComplete(identifier) else {
                    connection.cancel()
                    return
                }
                self.http.respond(connection, status: status, body: message, contentType: "text/plain")
            case .request(let request):
                guard self.markRequestComplete(identifier) else {
                    connection.cancel()
                    return
                }
                if let rejection = DashboardRequestPolicy.rejection(for: request, serverPort: self.port) {
                    self.http.respond(
                        connection,
                        status: rejection.status,
                        body: rejection.message,
                        contentType: "text/plain"
                    )
                    return
                }
                self.route(request: request, connection: connection)
            }
        }
    }

    private func markRequestComplete(_ identifier: ObjectIdentifier) -> Bool {
        lock.lock()
        guard var record = activeConnections[identifier] else {
            lock.unlock()
            return false
        }
        record.incompleteRequestDeadlineUptimeNanoseconds = nil
        activeConnections[identifier] = record
        scheduleNextIncompleteRequestDeadlineLocked()
        lock.unlock()
        return true
    }

    private func expireIncompleteConnections() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let expiredRecords: [(ObjectIdentifier, NWConnection)] = activeConnections.compactMap { element in
            let (identifier, record) = element
            guard let deadline = record.incompleteRequestDeadlineUptimeNanoseconds,
                  deadline <= now else { return nil }
            return (identifier, record.connection)
        }
        expiredRecords.forEach { activeConnections[$0.0] = nil }
        scheduleNextIncompleteRequestDeadlineLocked()
        lock.unlock()

        guard !expiredRecords.isEmpty else { return }
        app.diagnostics.warn("dashboard_incomplete_request_timeout", [
            "deadline_ms": "\(Int(incompleteRequestTimeout * 1_000))",
            "expired_count": "\(expiredRecords.count)",
        ], category: .manager)
        expiredRecords.forEach { $0.1.cancel() }
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        lock.lock()
        activeConnections[identifier] = nil
        scheduleNextIncompleteRequestDeadlineLocked()
        let completedDrainTimer = completeGracefulDrainIfEmptyLocked()
        lock.unlock()
        completedDrainTimer?.setEventHandler {}
        completedDrainTimer?.cancel()
    }

    private func forceCloseGracefulDrain(timeout: TimeInterval) {
        lock.lock()
        guard isGracefullyDraining else {
            lock.unlock()
            return
        }
        let connections = activeConnections.values.map(\.connection)
        activeConnections.removeAll(keepingCapacity: false)
        let timer = gracefulDrainTimer
        gracefulDrainTimer = nil
        gracefulDrainRetain = nil
        isGracefullyDraining = false
        lock.unlock()

        timer?.setEventHandler {}
        timer?.cancel()
        if !connections.isEmpty {
            app.diagnostics.warn("dashboard_graceful_drain_timeout", [
                "deadline_ms": "\(Int(timeout * 1_000))",
                "forced_count": "\(connections.count)",
            ], category: .manager)
        }
        connections.forEach { $0.cancel() }
    }

    /// Must be called with `lock` held. Returning the source lets the caller
    /// cancel it after unlocking while the method's strong `self` keeps teardown safe.
    private func completeGracefulDrainIfEmptyLocked() -> DispatchSourceTimer? {
        guard isGracefullyDraining, activeConnections.isEmpty else { return nil }
        let timer = gracefulDrainTimer
        gracefulDrainTimer = nil
        gracefulDrainRetain = nil
        isGracefullyDraining = false
        return timer
    }

    /// Must be called with `lock` held. A single one-shot source owns every
    /// request deadline so rapid completed requests cannot accumulate delayed blocks.
    private func scheduleNextIncompleteRequestDeadlineLocked() {
        guard let incompleteRequestTimer else { return }
        let deadline = activeConnections.values.compactMap {
            $0.incompleteRequestDeadlineUptimeNanoseconds
        }.min()
        if let deadline {
            incompleteRequestTimer.schedule(
                deadline: DispatchTime(uptimeNanoseconds: deadline),
                leeway: .milliseconds(10)
            )
        } else {
            incompleteRequestTimer.schedule(deadline: .distantFuture)
        }
    }

    private func route(request: DashboardHTTPRequest, connection: NWConnection) {
        let rawPath = request.target
        let pathOnly = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let path = pathOnly.hasPrefix("/") ? pathOnly : "/" + pathOnly
        let m = request.method
        let body = request.body

        do {
            if path.hasPrefix("/api/manager") {
                guard let manager else {
                    http.respondJSON(connection, status: 503, object: [
                        "ok": false,
                        "code": "no_manager",
                        "message": "Not running under manager. Start with: forge-conductor manager run",
                    ])
                    return
                }
                try ManagerRoutes(manager: manager, http: http)
                    .handle(
                        method: m,
                        path: rawPath.hasPrefix("/") ? rawPath : "/" + rawPath,
                        headers: request.headers,
                        body: body,
                        connection: connection
                    )
                return
            }

            if pathOnly.hasPrefix("/api/snapshot") || pathOnly.hasPrefix("/api/live")
                || pathOnly.hasPrefix("/api/frame") || pathOnly.hasPrefix("/api/system")
                || pathOnly.hasPrefix("/api/forge") || pathOnly.hasPrefix("/api/stream")
                || pathOnly.hasPrefix("/api/health") || pathOnly.hasPrefix("/static/")
                || pathOnly == "/ping" {
                // Pass raw path (with query) so /api/stream?hz=20 can parse target rate.
                try TelemetryRoutes(app: app, http: http)
                    .handle(method: m, path: rawPath.hasPrefix("/") ? rawPath : "/" + rawPath, connection: connection)
                return
            }

            switch (m, path) {
            case ("GET", "/"), ("GET", "/index.html"):
                if let (data, type) = app.telemetry.loadStatic("index.html") {
                    http.respondData(connection, status: 200, data: data, contentType: type)
                } else {
                    http.respond(connection, status: 200, body: DashboardHTML.index, contentType: "text/html; charset=utf-8")
                }
            case ("GET", "/control"), ("GET", "/manager"):
                http.respond(connection, status: 200, body: DashboardHTML.index, contentType: "text/html; charset=utf-8")
            case ("GET", "/api/status"):
                var snap = try app.statusSnapshot()
                if let manager {
                    snap["manager"] = manager.status()
                    snap["service_active"] = manager.isServiceActive()
                } else {
                    snap["service_active"] = true
                    snap["manager"] = ["manager": false, "state": "standalone"] as [String: Any]
                }
                http.respondJSON(connection, status: 200, object: snap)
            case ("OPTIONS", _):
                http.respond(connection, status: 405, body: "Method Not Allowed", contentType: "text/plain")
            default:
                if let manager, !manager.isServiceActive(), path.hasPrefix("/api/") {
                    http.respondJSON(connection, status: 503, object: [
                        "ok": false,
                        "code": "service_stopped",
                        "message": "Operational APIs paused. Telemetry remains at / and /api/snapshot.",
                        "manager": manager.status(),
                    ])
                    return
                }
                try OperationalRoutes(app: app, http: http)
                    .handle(method: m, path: path, body: body, connection: connection)
            }
        } catch {
            http.respondJSON(connection, status: 500, object: ["ok": false, "message": "\(error)"])
        }
    }
}

public enum DashboardError: Error, LocalizedError {
    case portInUse(String)
    case bindTimeout(UInt16)
    case startCancelled
    case nonLoopbackHost(String)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let msg): msg
        case .bindTimeout(let p): "Timed out binding dashboard on port \(p)"
        case .startCancelled: "Dashboard startup was cancelled"
        case .nonLoopbackHost(let host):
            "Dashboard host must be loopback-only (localhost, 127.0.0.1, or ::1); got \(host)"
        }
    }
}
