// DashboardTests.swift
// Starts the real native dashboard server and validates its principal HTTP resources.
// Random loopback ports keep integration coverage isolated and safe for parallel runs.

import XCTest
import Darwin
@testable import ForgeConductorCore

final class DashboardTests: XCTestCase {
    func testDashboardStartsAndServesStatus() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 18_000...28_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop(); app.shutdown() }
        Thread.sleep(forTimeInterval: 0.15)

        let url = URL(string: "http://127.0.0.1:\(port)/api/status")!
        let (data, http) = try HTTPTestHelpers.fetch(url)
        XCTAssertEqual(http.statusCode, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(payload?["ok"] as? Bool, true)
        XCTAssertEqual(payload?["runtime"] as? String, "swift")
        XCTAssertEqual(payload?["version"] as? String, ForgeApp.version)
    }

    func testDashboardIndexHTML() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Seed production telemetry UI so / serves FORGE RIG (same path as live install).
        try Self.seedTelemetryStatic(into: home)

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 18_000...28_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop(); app.shutdown() }
        Thread.sleep(forTimeInterval: 0.15)

        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, http) = try HTTPTestHelpers.fetch(url)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        // Package resources serve FORGE RIG; fallback control surface uses Forge-Conductor.
        let okTitle = body.contains("FORGE") || body.contains("Forge-Conductor") || body.contains("Forge Conductor")
        XCTAssertTrue(okTitle, "Unexpected index body prefix: \(body.prefix(120))")
        XCTAssertTrue(
            body.contains("/api/snapshot") || body.contains("/api/status") || body.contains("api/"),
            "Index should reference a telemetry or status API"
        )
        // Main dashboard must expose a clear shortcut to the management console.
        XCTAssertTrue(
            body.contains("href=\"/control\"") || body.contains("href='/control'"),
            "Dashboard must link to /control management console"
        )
        XCTAssertTrue(
            body.contains("MANAGEMENT CONSOLE") || body.contains("Management Console") || body.contains("Manager controls"),
            "Dashboard must label the management console shortcut clearly"
        )
    }

    /// Copy source TelemetryStatic into a test home so loadStatic serves the production UI.
    private static func seedTelemetryStatic(into home: URL) throws {
        let fm = FileManager.default
        let dest = home.appendingPathComponent("telemetry/static", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let srcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ForgeConductorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/ForgeConductorCore/Resources/TelemetryStatic")

        for name in ["index.html", "style.css", "app.js"] {
            let src = srcRoot.appendingPathComponent(name)
            let out = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: out.path) {
                try fm.removeItem(at: out)
            }
            guard fm.fileExists(atPath: src.path) else {
                XCTFail("Missing source static file: \(src.path)")
                return
            }
            try fm.copyItem(at: src, to: out)
        }
    }

    func testControlSurfaceHasManagerControls() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 18_000...28_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop(); app.shutdown() }
        Thread.sleep(forTimeInterval: 0.15)

        let url = URL(string: "http://127.0.0.1:\(port)/control")!
        let (data, http) = try HTTPTestHelpers.fetch(url)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("/api/manager/start"), body.prefix(200).description)
        XCTAssertTrue(body.contains("/api/manager/stop"))
        XCTAssertTrue(body.contains("/api/manager/settings") || body.contains("Settings"))
        XCTAssertTrue(
            body.contains("href=\"/\"") || body.contains("Telemetry dashboard"),
            "Control surface should link back to telemetry dashboard"
        )
    }

    func testIncompleteConnectionsAreCappedAndExpire() throws {
        XCTAssertEqual(DashboardServer.maximumActiveConnections, 64)
        XCTAssertEqual(DashboardServer.incompleteRequestTimeoutSeconds, 10)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 40_000...49_000)
        let server = DashboardServer(
            app: app,
            host: "127.0.0.1",
            port: port,
            activeConnectionLimit: 2,
            incompleteRequestTimeout: 0.8
        )
        try server.start()
        defer { server.stop(); app.shutdown() }

        let sockets = try (0..<2).map { _ in
            try Self.openIncompleteConnection(port: port)
        }
        defer { sockets.forEach { Darwin.close($0) } }
        XCTAssertTrue(
            Self.waitForActiveConnectionCount(server, expected: 2, timeout: 1),
            "The two admitted loopback sockets must be owned by the server"
        )

        let overflow = try Self.openIncompleteConnection(port: port)
        defer { Darwin.close(overflow) }
        XCTAssertTrue(
            Self.waitForSocketClosure(overflow, timeout: 0.5),
            "A connection above the strict active-connection cap must be cancelled"
        )
        XCTAssertEqual(server.activeConnectionCount, 2)

        XCTAssertTrue(
            Self.waitForActiveConnectionCount(server, expected: 0, timeout: 1.5),
            "Incomplete requests must be removed when their parsing deadline expires"
        )
        for socket in sockets {
            XCTAssertTrue(
                Self.waitForSocketClosure(socket, timeout: 0.5),
                "The server must cancel each expired incomplete request"
            )
        }

        let (data, response) = try HTTPTestHelpers.fetch(
            URL(string: "http://127.0.0.1:\(port)/api/status")!
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
        XCTAssertTrue(
            Self.waitForActiveConnectionCount(server, expected: 0, timeout: 1),
            "A completed response must release its connection slot"
        )
    }

    func testPeerCancellationReleasesConnectionSlot() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash-peer-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        let port = UInt16.random(in: 40_000...49_000)
        let server = DashboardServer(
            app: app,
            host: "127.0.0.1",
            port: port,
            activeConnectionLimit: 2,
            incompleteRequestTimeout: 5
        )
        try server.start()
        defer { server.stop(); app.shutdown() }

        let socket = try Self.openIncompleteConnection(port: port)
        XCTAssertTrue(Self.waitForActiveConnectionCount(server, expected: 1, timeout: 1))
        Darwin.close(socket)
        XCTAssertTrue(
            Self.waitForActiveConnectionCount(server, expected: 0, timeout: 1),
            "A peer-side cancellation must release the registry slot before the request deadline"
        )
    }

    func testStopCancelsAndDrainsIncompleteConnections() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash-stop-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let port = UInt16.random(in: 40_000...49_000)
        let server = DashboardServer(
            app: app,
            host: "127.0.0.1",
            port: port,
            activeConnectionLimit: 4,
            incompleteRequestTimeout: 5
        )
        try server.start()
        defer { server.stop() }

        let sockets = try (0..<3).map { _ in
            try Self.openIncompleteConnection(port: port)
        }
        defer { sockets.forEach { Darwin.close($0) } }
        XCTAssertTrue(Self.waitForActiveConnectionCount(server, expected: 3, timeout: 1))

        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(server.activeConnectionCount, 0)
        for socket in sockets {
            XCTAssertTrue(
                Self.waitForSocketClosure(socket, timeout: 1),
                "Stopping the server must cancel every accepted connection"
            )
        }
    }

    func testGracefulReplacementDrainHasHardDeadlineWhileImmediateStopRemainsAvailable() throws {
        XCTAssertEqual(DashboardServer.gracefulResponseDrainTimeoutSeconds, 12)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-dash-graceful-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let port = UInt16.random(in: 40_000...49_000)
        let server = DashboardServer(app: app, host: "127.0.0.1", port: port)
        try server.start()
        defer { server.stop() }

        let socket = try Self.openRequestConnection(
            port: port,
            request: "GET /api/stream?hz=1 HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(port)\r\n"
                + "Connection: close\r\n\r\n"
        )
        defer { Darwin.close(socket) }
        XCTAssertTrue(Self.waitForSocketReadable(socket, timeout: 1))
        var initialBytes = [UInt8](repeating: 0, count: 4_096)
        let initialCount = Darwin.recv(socket, &initialBytes, initialBytes.count, 0)
        XCTAssertGreaterThan(initialCount, 0)
        XCTAssertTrue(Self.waitForActiveConnectionCount(server, expected: 1, timeout: 1))

        let startedAt = Date()
        server.stopAllowingCompletedResponses(timeout: 0.1)
        XCTAssertFalse(server.isRunning)
        XCTAssertTrue(
            Self.waitForActiveConnectionCount(server, expected: 0, timeout: 1),
            "The single deadline must release every retained completed request"
        )
        XCTAssertTrue(
            Self.waitForSocketEOFDraining(socket, timeout: 1),
            "The response drain must force-close a stream at its bounded deadline"
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    private static func openIncompleteConnection(port: UInt16) throws -> Int32 {
        try openRequestConnection(
            port: port,
            request: "GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:\(port)"
        )
    }

    private static func openRequestConnection(port: UInt16, request: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "dashboard-connection-test", code: Int(errno))
        }
        do {
            var noSignal: Int32 = 1
            guard Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw NSError(domain: "dashboard-connection-test", code: Int(errno))
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port.bigEndian)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard connected == 0 else {
                throw NSError(domain: "dashboard-connection-test", code: Int(errno))
            }

            let requestData = Data(request.utf8)
            let sent = requestData.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
            }
            guard sent == requestData.count else {
                throw NSError(domain: "dashboard-connection-test", code: Int(errno))
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func waitForActiveConnectionCount(
        _ server: DashboardServer,
        expected: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if server.activeConnectionCount == expected { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return server.activeConnectionCount == expected
    }

    private static func waitForSocketClosure(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let remainingMilliseconds = Int32(
                max(1, min(deadline.timeIntervalSinceNow * 1_000, 50))
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, remainingMilliseconds)
            if pollResult > 0 {
                var byte: UInt8 = 0
                let received = Darwin.recv(descriptor, &byte, 1, MSG_PEEK)
                if received == 0 { return true }
                if received < 0, errno != EAGAIN, errno != EINTR { return true }
            } else if pollResult < 0, errno != EINTR {
                return true
            }
        } while Date() < deadline
        return false
    }

    private static func waitForSocketReadable(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&pollDescriptor, 1, Int32(timeout * 1_000)) > 0
    }

    private static func waitForSocketEOFDraining(
        _ descriptor: Int32,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var bytes = [UInt8](repeating: 0, count: 4_096)
        repeat {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let remainingMilliseconds = Int32(
                max(1, min(deadline.timeIntervalSinceNow * 1_000, 50))
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, remainingMilliseconds)
            if pollResult > 0 {
                let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
                if received == 0 { return true }
                if received < 0, errno != EAGAIN, errno != EINTR { return true }
            } else if pollResult < 0, errno != EINTR {
                return true
            }
        } while Date() < deadline
        return false
    }
}
