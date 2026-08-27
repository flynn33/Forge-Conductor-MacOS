// MCPProtocolAndDiagnosticsTests.swift
// Validates MCP NDJSON framing, protocol behavior, diagnostics, and bounded outputs.
// These tests guard the wire boundary independently from a graphical LM Studio session.

import XCTest
import Darwin
@testable import ForgeConductorCore

final class MCPProtocolAndDiagnosticsTests: XCTestCase {
    func testStdioTransportWritesSpecCompliantNDJSON() throws {
        let packet = try MCPStdioTransport.encode([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["ok": true] as [String: Any],
        ])
        let text = try XCTUnwrap(String(data: packet, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("Content-Length"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        let decoded = try JSONSupport.object(from: Data(text.dropLast().utf8))
        XCTAssertEqual(decoded["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(decoded["id"] as? Int, 1)
    }

    func testStreamReaderRejectsOversizedContentLengthBeforeReadingBody() throws {
        let pipe = Pipe()
        let reader = MCPStreamReader(handle: pipe.fileHandleForReading, maximumMessageBytes: 64)
        try pipe.fileHandleForWriting.write(contentsOf: Data("Content-Length: 100\r\n\r\n".utf8))
        try pipe.fileHandleForWriting.close()

        XCTAssertThrowsError(try reader.readMessage()) { error in
            guard case MCPStreamError.messageTooLarge(64) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testProtocolNegotiationEchoesLMStudioVersion() {
        let expectedVersions = [
            "2025-11-25",
            "2025-06-18",
            "2025-03-26",
            "2024-11-05",
        ]
        XCTAssertEqual(MCPServer.supportedProtocolVersions, expectedVersions)
        for version in expectedVersions {
            XCTAssertEqual(MCPServer.negotiateProtocolVersion(version), version)
        }
        // Unknown → newest supported
        XCTAssertEqual(
            MCPServer.negotiateProtocolVersion("2099-01-01"),
            MCPServer.supportedProtocolVersions[0]
        )
        XCTAssertEqual(
            MCPServer.negotiateProtocolVersion(""),
            MCPServer.supportedProtocolVersions[0]
        )
    }

    func testConcurrentRequestsPreserveTypedIDsAndCompleteOutOfOrder() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 2)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": [
                "name": "shell_exec",
                "arguments": [
                    "command": "sleep 1; printf 'typed-slow-response'",
                    "cwd": fixture.projectRoot.path,
                    "timeout_sec": 5,
                ] as [String: Any],
            ] as [String: Any],
        ])
        try fixture.send([
            "jsonrpc": "2.0",
            "id": "7",
            "method": "ping",
        ])

        let first = try fixture.responses.read(timeout: 5)
        XCTAssertEqual(first["id"] as? String, "7")
        XCTAssertNotNil(first["result"] as? [String: Any])

        let second = try fixture.responses.read(timeout: 8)
        XCTAssertEqual((second["id"] as? NSNumber)?.intValue, 7)
        let result = try XCTUnwrap(second["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["stdout"] as? String, "typed-slow-response")

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testWireAcceptsNumericIDsAndRejectsInvalidIDsWithNullCorrelation() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 2)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "id": true,
            "method": "ping",
        ])
        let invalid = try fixture.responses.read(timeout: 3)
        XCTAssertTrue(invalid["id"] is NSNull)
        let invalidError = try XCTUnwrap(invalid["error"] as? [String: Any])
        XCTAssertEqual((invalidError["code"] as? NSNumber)?.intValue, -32600)

        for invalidID: Any in [
            ["nested": true] as [String: Any],
            [1, 2] as [Any],
        ] {
            try fixture.send([
                "jsonrpc": "2.0",
                "id": invalidID,
                "method": "ping",
            ])
            let invalidShape = try fixture.responses.read(timeout: 3)
            XCTAssertTrue(invalidShape["id"] is NSNull)
            let error = try XCTUnwrap(invalidShape["error"] as? [String: Any])
            XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32600)
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "ping",
        ])
        let numeric = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((numeric["id"] as? NSNumber)?.intValue, 1)
        XCTAssertNotNil(numeric["result"] as? [String: Any])

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testCancellationAfterSynchronousMutationReturnsCommittedResult() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        let runner = ProcessRunner()
        @discardableResult
        func runGit(_ arguments: [String]) throws -> ProcessResult {
            let result = try runner.run(
                executable: "/usr/bin/git",
                arguments: arguments,
                currentDirectory: fixture.projectRoot.path,
                timeoutSec: 10
            )
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            return result
        }

        _ = try runGit(["init", "--quiet"])
        _ = try runGit(["config", "user.name", "Forge Fixture"])
        _ = try runGit(["config", "user.email", "fixture@forge.invalid"])
        _ = try runGit(["config", "commit.gpgsign", "false"])
        let tracked = fixture.projectRoot.appendingPathComponent("tracked.txt")
        try Data("before\n".utf8).write(to: tracked)
        _ = try runGit(["add", "tracked.txt"])
        _ = try runGit(["commit", "--quiet", "-m", "Seed mutation fixture"])
        let headBefore = try runGit(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hook = fixture.projectRoot.appendingPathComponent(".git/hooks/pre-commit")
        let release = fixture.projectRoot.appendingPathComponent("commit-hook-release")
        defer { try? Data().write(to: release) }
        try Data(
            """
            #!/bin/sh
            : > commit-hook-ready
            attempt=0
            while [ ! -f commit-hook-release ]; do
              attempt=$((attempt + 1))
              [ "$attempt" -lt 100 ] || exit 75
              sleep 0.05
            done

            """.utf8
        ).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("after\n".utf8).write(to: tracked)
        _ = try runGit(["add", "tracked.txt"])

        fixture.start()
        try fixture.send([
            "jsonrpc": "2.0",
            "id": 51,
            "method": "tools/call",
            "params": [
                "name": "git_commit",
                "arguments": [
                    "cwd": fixture.projectRoot.path,
                    "message": "Commit mutation fixture",
                ] as [String: Any],
            ] as [String: Any],
        ])
        let ready = fixture.projectRoot.appendingPathComponent("commit-hook-ready")
        XCTAssertTrue(MCPWireFixture.waitForFile(ready, timeout: 5))
        try fixture.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 51],
        ])
        try fixture.send([
            "jsonrpc": "2.0",
            "id": 52,
            "method": "ping",
        ])
        let busy = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((busy["id"] as? NSNumber)?.intValue, 52)
        let busyError = try XCTUnwrap(busy["error"] as? [String: Any])
        XCTAssertEqual((busyError["code"] as? NSNumber)?.intValue, -32000)
        XCTAssertTrue((busyError["message"] as? String)?.contains("maximum concurrent requests") == true)
        try Data().write(to: release)

        let response = try fixture.responses.read(timeout: 8)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 51)
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual((structured["exit_code"] as? NSNumber)?.intValue, 0)
        let headAfter = try runGit(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(headAfter, headBefore)
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.5))

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testActiveCancellationRemainsResponsiveAndTerminatesLegacyShellTree() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 41,
            "method": "tools/call",
            "params": [
                "name": "shell_exec",
                "arguments": [
                    "command": """
                    (
                      trap '' TERM
                      while :; do sleep 1; done
                    ) &
                    echo $! > mcp-cancel-descendant.pid
                    : > mcp-cancel-ready
                    wait
                    """,
                    "cwd": fixture.projectRoot.path,
                    "timeout_sec": 30,
                ] as [String: Any],
            ] as [String: Any],
        ])
        let ready = fixture.projectRoot.appendingPathComponent("mcp-cancel-ready")
        XCTAssertTrue(MCPWireFixture.waitForFile(ready, timeout: 5))
        let pidFile = fixture.projectRoot.appendingPathComponent("mcp-cancel-descendant.pid")
        let descendant = try MCPWireFixture.readPID(pidFile)

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 42,
            "method": "ping",
        ])
        let busy = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((busy["id"] as? NSNumber)?.intValue, 42)
        let busyError = try XCTUnwrap(busy["error"] as? [String: Any])
        XCTAssertEqual((busyError["code"] as? NSNumber)?.intValue, -32000)
        XCTAssertTrue((busyError["message"] as? String)?.contains("maximum concurrent requests") == true)

        try fixture.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 41],
        ])
        let cancelled = try fixture.responses.read(timeout: 8)
        XCTAssertEqual((cancelled["id"] as? NSNumber)?.intValue, 41)
        let cancellationError = try XCTUnwrap(cancelled["error"] as? [String: Any])
        XCTAssertEqual((cancellationError["code"] as? NSNumber)?.intValue, -32800)
        XCTAssertEqual(cancellationError["message"] as? String, "Cancelled")
        XCTAssertTrue(MCPWireFixture.waitUntilProcessIsGone(descendant, timeout: 8))
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.5), "cancelled work emitted a late response")

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testDiagnosticExportJSONAndMarkdown() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths = AppPaths(home: tmp)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths, role: "primary")
        log.info("unit_test_event", ["k": "v"], category: .diagnostics)
        log.warn("unit_test_warn", category: .mcp)
        log.error("unit_test_error", ["code": "1"], category: .lmstudio)

        let result = try log.export(to: tmp.appendingPathComponent("out", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.markdownURL.path))
        XCTAssertGreaterThanOrEqual(result.recordCount, 3)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: result.jsonURL)) as? [String: Any]
        XCTAssertEqual(json?["product"] as? String, ForgeApp.productName)
        XCTAssertNotNil(json?["records"] as? [[String: Any]])

        let md = try String(contentsOf: result.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("# "))
        XCTAssertTrue(md.contains("unit_test_event") || md.contains("Timeline"))
    }

    func testDiagnosticLogRedactsPrivateFieldsBeforePersistenceAndExport() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-redaction-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths = AppPaths(home: tmp)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths)
        let privatePath = "/Users/private/Project/secret.txt"
        let privateGoal = "private customer remediation details"
        log.info("redaction_boundary", [
            "path": privatePath,
            "goal": privateGoal,
            "operation_id": "operation-17",
            "count": "3",
        ], category: .diagnostics)

        let record = try XCTUnwrap(log.recent(limit: 1).first)
        XCTAssertTrue(record.fields["path"]?.hasPrefix("<redacted:") == true)
        XCTAssertTrue(record.fields["goal"]?.hasPrefix("<redacted:") == true)
        XCTAssertEqual(record.fields["operation_id"], "operation-17")
        XCTAssertEqual(record.fields["count"], "3")

        let persisted = try String(contentsOf: paths.masterDiagnostics, encoding: .utf8)
        XCTAssertFalse(persisted.contains(privatePath))
        XCTAssertFalse(persisted.contains(privateGoal))

        let exported = try log.export(to: tmp.appendingPathComponent("export", isDirectory: true))
        let exportText = try String(contentsOf: exported.jsonURL, encoding: .utf8)
        XCTAssertFalse(exportText.contains(tmp.path))
        XCTAssertFalse(exportText.contains(privatePath))
        XCTAssertFalse(exportText.contains(privateGoal))
    }

    func testRealtimeEngineIsContinuousNotTwoSecondSnapshot() {
        XCTAssertGreaterThanOrEqual(RealtimeMetricsEngine.defaultTargetHz, 20)
        XCTAssertLessThan(1.0 / RealtimeMetricsEngine.defaultTargetHz, 0.1)

        let engine = RealtimeMetricsEngine()
        let requiredPushes = 8
        let delivered = expectation(description: "continuous samples delivered")
        var timestamps: [TimeInterval] = []
        let lock = NSLock()
        let id = engine.addListener { metrics in
            lock.lock()
            timestamps.append(metrics.ts)
            let reachedRequiredPushes = timestamps.count == requiredPushes
            lock.unlock()
            if reachedRequiredPushes {
                delivered.fulfill()
            }
        }
        engine.start(targetHz: 30)
        defer {
            engine.stop()
            engine.removeListener(id)
        }

        wait(for: [delivered], timeout: 2.0)
        lock.lock()
        let samples = timestamps
        lock.unlock()

        XCTAssertGreaterThanOrEqual(samples.count, requiredPushes, "must push samples to listeners (not snapshot poll); got \(samples.count)")
        XCTAssertGreaterThan(samples.last ?? 0, samples.first ?? 0, "continuous engine must advance sample timestamps")
    }

    func testDeployServiceResolvesExecutable() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-deploy-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(home: tmp)
        let log = DiagnosticLog(paths: paths)
        let svc = LMStudioDeployService(paths: paths, diagnostics: log)
        let url = svc.resolveServeBinary(preferred: nil)
        // May not exist in empty temp home — still returns a concrete path candidate.
        XCTAssertFalse(url.path.isEmpty)
    }
}

private final class MCPWireFixture {
    let projectRoot: URL
    let responses: MCPWireResponseReader

    private let root: URL
    private let app: ForgeApp
    private let server: MCPServer
    private let input = Pipe()
    private let output = Pipe()
    private let finished = DispatchSemaphore(value: 0)
    private let errorBox = MCPWireErrorBox()

    init(maximumConcurrentRequests: Int) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-mcp-wire-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        do {
            app = try ForgeApp.bootstrap(home: home)
            let clientID = ClientID("mcp-wire-\(UUID().uuidString)")
            let initialized = try app.tools.call(
                name: "project_memory.initialize",
                arguments: ["project_path": projectRoot.path],
                clientID: clientID
            )
            guard initialized.ok else {
                throw MCPWireTestError.fixture("project binding failed: \(initialized.payload)")
            }
            server = MCPServer(
                app: app,
                clientID: clientID,
                maximumConcurrentRequests: maximumConcurrentRequests,
                shutdownWaitSeconds: 10
            )
            responses = MCPWireResponseReader(handle: output.fileHandleForReading)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func start() {
        DispatchQueue(label: "forge.test.mcp-wire").async { [self] in
            do {
                try server.run(
                    input: input.fileHandleForReading,
                    output: output.fileHandleForWriting
                )
            } catch {
                errorBox.store(error)
            }
            finished.signal()
        }
    }

    func send(_ message: [String: Any]) throws {
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode(message))
    }

    func stop() -> Error? {
        try? input.fileHandleForWriting.close()
        let completed = finished.wait(timeout: .now() + 15) == .success
        let serverError = errorBox.take()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        _ = app.shutdown()
        try? FileManager.default.removeItem(at: root)
        if !completed { return MCPWireTestError.timeout("server shutdown") }
        return serverError
    }

    static func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(10_000)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func readPID(_ url: URL) throws -> Int32 {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(text), pid > 1 else {
            throw MCPWireTestError.fixture("invalid descendant process identifier")
        }
        return pid
    }

    static func waitUntilProcessIsGone(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(10_000)
        }
        return Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }
}

private final class MCPWireResponseReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func read(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return try JSONSupport.object(from: line)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MCPWireTestError.timeout("response")
            }
            guard try waitForData(timeout: remaining) else {
                throw MCPWireTestError.timeout("response")
            }
            let chunk = try readAvailableData()
            guard !chunk.isEmpty else {
                throw MCPWireTestError.fixture("response stream closed")
            }
            buffer.append(chunk)
        }
    }

    func hasMessage(timeout: TimeInterval) throws -> Bool {
        if buffer.contains(0x0A) { return true }
        guard try waitForData(timeout: timeout) else { return false }
        let chunk = try readAvailableData()
        buffer.append(chunk)
        return buffer.contains(0x0A)
    }

    private func readAvailableData() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        guard count >= 0 else {
            throw MCPWireTestError.fixture(
                "response read failed: \(String(cString: strerror(errno)))"
            )
        }
        return Data(bytes.prefix(count))
    }

    private func waitForData(timeout: TimeInterval) throws -> Bool {
        var descriptor = pollfd(
            fd: handle.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let milliseconds = Int32(max(1, min(timeout * 1_000, Double(Int32.max))))
        let result = Darwin.poll(&descriptor, 1, milliseconds)
        if result < 0 {
            throw MCPWireTestError.fixture("response poll failed: \(String(cString: strerror(errno)))")
        }
        return result > 0 && (descriptor.revents & Int16(POLLIN)) != 0
    }
}

private final class MCPWireErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func store(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func take() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private enum MCPWireTestError: Error, LocalizedError {
    case fixture(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .fixture(let message): message
        case .timeout(let operation): "Timed out waiting for \(operation)"
        }
    }
}
