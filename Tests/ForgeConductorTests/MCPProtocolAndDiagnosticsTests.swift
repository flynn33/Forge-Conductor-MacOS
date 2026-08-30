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

    func testWireRejectsInvalidToolDeadlineAtAdmission() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        let invalidDeadlines: [Any] = [true, "25", 0, 60_001, 1.5]
        for (offset, deadline) in invalidDeadlines.enumerated() {
            let requestID = 100 + offset
            try fixture.send([
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/call",
                "params": [
                    "name": "forge_status",
                    "arguments": ["deadline_ms": deadline],
                ] as [String: Any],
            ])
            let response = try fixture.responses.read(timeout: 3)
            XCTAssertEqual((response["id"] as? NSNumber)?.intValue, requestID)
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual((error["code"] as? NSNumber)?.intValue, -32602)
            XCTAssertTrue((error["message"] as? String)?.contains("deadline_ms") == true)

            try fixture.send([
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "ping",
            ])
            let reused = try fixture.responses.read(timeout: 3)
            XCTAssertEqual((reused["id"] as? NSNumber)?.intValue, requestID)
            XCTAssertNotNil(reused["result"] as? [String: Any])
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 160],
        ])
        try fixture.send([
            "jsonrpc": "2.0",
            "id": 160,
            "method": "ping",
        ])
        let requestAfterUnknownCancellation = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((requestAfterUnknownCancellation["id"] as? NSNumber)?.intValue, 160)
        XCTAssertNotNil(requestAfterUnknownCancellation["result"] as? [String: Any])
        try fixture.send([
            "jsonrpc": "2.0",
            "id": 160,
            "method": "ping",
        ])
        let reusedAfterCancellation = try fixture.responses.read(timeout: 3)
        XCTAssertNotNil(reusedAfterCancellation["result"] as? [String: Any])

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testResponseBackpressureCannotBlockServerShutdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-mcp-backpressure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true))
        let input = Pipe()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let errors = MCPWireErrorBox()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            _ = app.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        let server = MCPServer(
            app: app,
            clientID: ClientID("mcp-backpressure"),
            maximumConcurrentRequests: 8,
            shutdownWaitSeconds: 2,
            responseWriteTimeoutSeconds: 0.1
        )
        DispatchQueue(label: "forge.test.mcp-backpressure").async {
            do {
                try server.run(
                    input: input.fileHandleForReading,
                    output: output.fileHandleForWriting
                )
            } catch {
                errors.store(error)
            }
            finished.signal()
        }

        for requestID in 200..<208 {
            try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/list",
            ]))
        }
        usleep(400_000)
        try input.fileHandleForWriting.close()

        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        guard let error = errors.take() else {
            return XCTFail("saturated response transport must report its bounded failure")
        }
        guard case MCPStreamError.responseWriteTimedOut = error else {
            return XCTFail("unexpected response transport error: \(error)")
        }
    }

    func testClosedResponseDeliveryRejectsLaterMutationBeforeDispatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-mcp-closed-delivery-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
        let clientID = ClientID("mcp-closed-delivery")
        let initialized = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": projectRoot.path],
            clientID: clientID
        )
        XCTAssertTrue(initialized.ok, "\(initialized.payload)")
        let input = Pipe()
        let output = Pipe()
        let deliveryClosed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let errors = MCPWireErrorBox()
        let marker = projectRoot.appendingPathComponent("must-not-be-written.txt")
        let notificationMarker = projectRoot.appendingPathComponent(
            "notification-must-not-be-written.txt"
        )
        let nullIDMarker = projectRoot.appendingPathComponent(
            "null-id-must-not-be-written.txt"
        )
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            _ = app.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        let server = MCPServer(
            app: app,
            clientID: clientID,
            maximumConcurrentRequests: 8,
            shutdownWaitSeconds: 2,
            responseWriteTimeoutSeconds: 0.05,
            didCloseResponseDeliveryObserver: { deliveryClosed.signal() }
        )
        DispatchQueue(label: "forge.test.mcp-closed-delivery").async {
            do {
                try server.run(
                    input: input.fileHandleForReading,
                    output: output.fileHandleForWriting
                )
            } catch {
                errors.store(error)
            }
            finished.signal()
        }

        for requestID in 300..<308 {
            try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/list",
            ]))
        }
        XCTAssertEqual(
            deliveryClosed.wait(timeout: .now() + 3),
            .success,
            "response backpressure did not close delivery"
        )

        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": [
                "name": "fs_write",
                "arguments": [
                    "path": notificationMarker.path,
                    "content": "late notification mutation",
                ],
            ] as [String: Any],
        ]))
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0",
            "id": NSNull(),
            "method": "tools/call",
            "params": [
                "name": "fs_write",
                "arguments": [
                    "path": nullIDMarker.path,
                    "content": "late null-id mutation",
                ],
            ] as [String: Any],
        ]))
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0",
            "id": 308,
            "method": "tools/call",
            "params": [
                "name": "fs_write",
                "arguments": ["path": marker.path, "content": "late mutation"],
            ] as [String: Any],
        ]))
        try input.fileHandleForWriting.close()

        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a request admitted after response delivery closed committed a mutation"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: notificationMarker.path),
            "an id-less tools/call notification committed a mutation"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: nullIDMarker.path),
            "a null-id tools/call notification committed a mutation"
        )
        guard let error = errors.take() else {
            return XCTFail("closed response delivery must terminate request admission")
        }
        guard case MCPStreamError.responseDeliveryClosed = error else {
            return XCTFail("unexpected closed-delivery error: \(error)")
        }
    }

    func testWireToolDeadlineStopsInFlightWorkAndReturnsStructuredFailure() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 120,
            "method": "tools/call",
            "params": [
                "name": "shell_exec",
                "arguments": [
                    "command": "sleep 5",
                    "cwd": fixture.projectRoot.path,
                    "timeout_sec": 10,
                    "deadline_ms": 100,
                ] as [String: Any],
            ] as [String: Any],
        ])

        let response = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 120)
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["code"] as? String, "deadline_exceeded")
        XCTAssertEqual(structured["ok"] as? Bool, false)
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.3))

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testWireDefaultRequestDeadlineBoundsToolCallsWithoutOverride() throws {
        let fixture = try MCPWireFixture(
            maximumConcurrentRequests: 1,
            requestTimeoutSeconds: 0.1
        )
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 121,
            "method": "tools/call",
            "params": [
                "name": "shell_exec",
                "arguments": [
                    "command": "sleep 5",
                    "cwd": fixture.projectRoot.path,
                    "timeout_sec": 10,
                ] as [String: Any],
            ] as [String: Any],
        ])

        let response = try fixture.responses.read(timeout: 3)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["code"] as? String, "deadline_exceeded")

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testWireCancellationStopsBlockingNonShellSearchWithoutLateResponse() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        let searchRoot = fixture.projectRoot.appendingPathComponent(
            "blocking-cancel-search",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: searchRoot, withIntermediateDirectories: false)
        let fifo = searchRoot.appendingPathComponent("input.pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 130,
            "method": "tools/call",
            "params": [
                "name": "search_text",
                "arguments": [
                    "path": searchRoot.path,
                    "pattern": "never-written-needle",
                ],
            ] as [String: Any],
        ])
        let writer = try XCTUnwrap(
            MCPWireFixture.openFIFOWhenReaderIsReady(fifo, timeout: 3),
            "search_text did not begin reading the FIFO"
        )
        defer { _ = Darwin.close(writer) }

        try fixture.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 130],
        ])
        let response = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 130)
        XCTAssertNil(response["result"])
        let cancellation = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual((cancellation["code"] as? NSNumber)?.intValue, -32800)
        XCTAssertEqual(cancellation["message"] as? String, "Cancelled")
        XCTAssertTrue(MCPWireFixture.waitUntilFIFOHasNoReader(fifo, timeout: 2))

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 131,
            "method": "ping",
        ])
        let ping = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((ping["id"] as? NSNumber)?.intValue, 131)
        XCTAssertNotNil(ping["result"] as? [String: Any])
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.3))

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testWireDeadlineStopsBlockingNonShellSearchWithoutLateResponse() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        fixture.start()
        var stopped = false
        defer {
            if !stopped { _ = fixture.stop() }
        }

        let searchRoot = fixture.projectRoot.appendingPathComponent(
            "blocking-deadline-search",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: searchRoot, withIntermediateDirectories: false)
        let fifo = searchRoot.appendingPathComponent("input.pipe")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 132,
            "method": "tools/call",
            "params": [
                "name": "search_text",
                "arguments": [
                    "path": searchRoot.path,
                    "pattern": "never-written-needle",
                    "deadline_ms": 2_000,
                ] as [String: Any],
            ] as [String: Any],
        ])
        let writer = try XCTUnwrap(
            MCPWireFixture.openFIFOWhenReaderIsReady(fifo, timeout: 1),
            "search_text did not begin reading the FIFO before its deadline"
        )
        defer { _ = Darwin.close(writer) }

        let response = try fixture.responses.read(timeout: 4)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 132)
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ok"] as? Bool, false)
        XCTAssertEqual(structured["code"] as? String, "deadline_exceeded")
        XCTAssertTrue(MCPWireFixture.waitUntilFIFOHasNoReader(fifo, timeout: 2))

        try fixture.send([
            "jsonrpc": "2.0",
            "id": 133,
            "method": "ping",
        ])
        let ping = try fixture.responses.read(timeout: 3)
        XCTAssertEqual((ping["id"] as? NSNumber)?.intValue, 133)
        XCTAssertNotNil(ping["result"] as? [String: Any])
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.3))

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
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

    func testCancellationDuringPreCommitStopsMutationAndPreservesHead() throws {
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
        XCTAssertNil(response["result"])
        let cancellation = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual((cancellation["code"] as? NSNumber)?.intValue, -32800)
        XCTAssertEqual(cancellation["message"] as? String, "Cancelled")
        let headAfter = try runGit(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(headAfter, headBefore)
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.5))

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testCancellationDuringPostCommitReturnsReconciledSuccess() throws {
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
        _ = try runGit(["commit", "--quiet", "-m", "Seed post-commit fixture"])
        let headBefore = try runGit(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hook = fixture.projectRoot.appendingPathComponent(".git/hooks/post-commit")
        let release = fixture.projectRoot.appendingPathComponent("post-commit-hook-release")
        defer { try? Data().write(to: release) }
        let preCommitHook = fixture.projectRoot.appendingPathComponent(".git/hooks/pre-commit")
        try Data(
            """
            #!/bin/sh
            printf 'hook-adjusted\n' > tracked.txt
            /usr/bin/git add tracked.txt

            """.utf8
        ).write(to: preCommitHook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: preCommitHook.path
        )
        let commitMessageHook = fixture.projectRoot.appendingPathComponent(".git/hooks/commit-msg")
        try Data(
            """
            #!/bin/sh
            printf '%s\n' 'Hook-adjusted commit message' > "$1"

            """.utf8
        ).write(to: commitMessageHook)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: commitMessageHook.path
        )
        try Data(
            """
            #!/bin/sh
            : > post-commit-hook-ready
            attempt=0
            while [ ! -f post-commit-hook-release ]; do
              attempt=$((attempt + 1))
              [ "$attempt" -lt 200 ] || exit 75
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
            "id": 53,
            "method": "tools/call",
            "params": [
                "name": "git_commit",
                "arguments": [
                    "cwd": fixture.projectRoot.path,
                    "message": "Requested subject   \n\n\nRequested body   ",
                ] as [String: Any],
            ] as [String: Any],
        ])

        let ready = fixture.projectRoot.appendingPathComponent("post-commit-hook-ready")
        XCTAssertTrue(MCPWireFixture.waitForFile(ready, timeout: 5))
        let committedHead = try runGit(["rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(committedHead, headBefore, "HEAD must advance before post-commit returns")

        try fixture.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 53],
        ])

        let response = try fixture.responses.read(timeout: 8)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 53)
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ok"] as? Bool, true)
        XCTAssertEqual((structured["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(structured["commit"] as? String, committedHead)
        XCTAssertEqual(structured["reconciled"] as? Bool, true)
        XCTAssertEqual(
            try runGit(["show", "HEAD:tracked.txt"]).stdout,
            "hook-adjusted\n"
        )
        XCTAssertEqual(
            try runGit(["log", "-1", "--format=%B"]).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Hook-adjusted commit message"
        )
        XCTAssertFalse(try fixture.responses.hasMessage(timeout: 0.5))

        let stopError = fixture.stop()
        stopped = true
        XCTAssertNil(stopError)
    }

    func testCancellationAfterGitAddIndexCommitReturnsReconciledSuccess() throws {
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
        _ = try runGit(["commit", "--quiet", "-m", "Seed add fixture"])

        let hook = fixture.projectRoot.appendingPathComponent(".git/hooks/post-index-change")
        let release = fixture.projectRoot.appendingPathComponent("post-index-hook-release")
        defer { try? Data().write(to: release) }
        try Data(
            """
            #!/bin/sh
            [ -f post-index-hook-ready ] && exit 0
            /usr/bin/git diff --cached --quiet -- tracked.txt && exit 0
            : > post-index-hook-ready
            attempt=0
            while [ ! -f post-index-hook-release ]; do
              attempt=$((attempt + 1))
              [ "$attempt" -lt 200 ] || exit 75
              sleep 0.05
            done

            """.utf8
        ).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try Data("after\n".utf8).write(to: tracked)

        fixture.start()
        try fixture.send([
            "jsonrpc": "2.0",
            "id": 54,
            "method": "tools/call",
            "params": [
                "name": "git_add",
                "arguments": [
                    "cwd": fixture.projectRoot.path,
                    "path": "tracked.txt",
                ] as [String: Any],
            ] as [String: Any],
        ])
        let ready = fixture.projectRoot.appendingPathComponent("post-index-hook-ready")
        XCTAssertTrue(MCPWireFixture.waitForFile(ready, timeout: 5))

        try fixture.send([
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": ["requestId": 54],
        ])

        let response = try fixture.responses.read(timeout: 8)
        XCTAssertEqual((response["id"] as? NSNumber)?.intValue, 54)
        XCTAssertNil(response["error"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ok"] as? Bool, true)
        XCTAssertEqual((structured["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(structured["reconciled"] as? Bool, true)
        XCTAssertNotNil(structured["index_fingerprint"] as? String)
        XCTAssertEqual(try runGit(["show", ":tracked.txt"]).stdout, "after\n")
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

        XCTAssertTrue(log.flush(timeout: 2))
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

    init(
        maximumConcurrentRequests: Int,
        requestTimeoutSeconds: TimeInterval = MCPServer.defaultRequestTimeoutSeconds
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-mcp-wire-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        do {
            app = try ForgeApp.bootstrap(home: home)
            _ = try app.config.update(["allowed_roots": [root.path]], save: false)
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
                shutdownWaitSeconds: 10,
                requestTimeoutSeconds: requestTimeoutSeconds
            )
            responses = MCPWireResponseReader(handle: output.fileHandleForReading)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func start() {
        let server = server
        let inputHandle = input.fileHandleForReading
        let outputHandle = output.fileHandleForWriting
        let errorBox = errorBox
        let finished = finished
        DispatchQueue(label: "forge.test.mcp-wire").async {
            do {
                try server.run(
                    input: inputHandle,
                    output: outputHandle
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

    static func openFIFOWhenReaderIsReady(_ url: URL, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_WRONLY | O_NONBLOCK)
            }
            if descriptor >= 0 { return descriptor }
            guard errno == ENXIO else { return nil }
            usleep(10_000)
        }
        return nil
    }

    static func waitUntilFIFOHasNoReader(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_WRONLY | O_NONBLOCK)
            }
            if descriptor < 0 {
                if errno == ENXIO { return true }
                return false
            }
            _ = Darwin.close(descriptor)
            usleep(10_000)
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_NONBLOCK)
        }
        if descriptor < 0 { return errno == ENXIO }
        _ = Darwin.close(descriptor)
        return false
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
