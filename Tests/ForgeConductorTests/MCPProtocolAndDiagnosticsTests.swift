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

    func testRendererBudgetLookupHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0.1)
    }

    func testAlreadyExpiredRendererResponseHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0)
    }

    func testPagedListingBudgetLookupHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0.1, toolName: "fs_list")
    }

    func testPagedListingRejectsFractionalWireNumbersNearIntegerRoundingBoundaries() throws {
        for field in ["limit", "maximum_bytes"] {
            for framing in ["ndjson", "content-length", "eof"] {
                for token in ["1.00000000000000001", "999.99999999999999999",
                              "1.0000000000000000000000000000000000000000001"] {
                    let pipe = Pipe()
                    let body = Data(("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_list\",\"arguments\":{\""
                                     + field + "\":" + token + "}}}").utf8)
                    let packet = framing == "content-length" ? Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
                        : framing == "ndjson" ? body + Data([10]) : body
                    try pipe.fileHandleForWriting.write(contentsOf: packet)
                    try pipe.fileHandleForWriting.close()
                    defer { try? pipe.fileHandleForReading.close() }
                    let reader = MCPStreamReader(handle: pipe.fileHandleForReading)
                    defer { reader.close() }
                    let message = try XCTUnwrap(reader.readMessage())
                    let parameters = try XCTUnwrap(message["params"] as? [String: Any])
                    let arguments = try XCTUnwrap(parameters["arguments"] as? [String: Any])
                    XCTAssertEqual(message["id"] as? Int, 1)
                    XCTAssertThrowsError(try FilesystemListingPage.Arguments(arguments), "\(field)/\(framing)/\(token)")
                }
            }
        }
    }

    func testPagedListingWireRejectionKeepsServerAliveAndCorrelationIntact() throws {
        let fixture = try MCPWireFixture(maximumConcurrentRequests: 1)
        fixture.start()
        var stopped = false
        defer { if !stopped { _ = fixture.stop() } }
        for field in ["limit", "maximum_bytes"] {
            let id = "invalid-list-\(field)"
            try fixture.sendRaw(Data(("{\"jsonrpc\":\"2.0\",\"id\":\"" + id + "\",\"method\":\"tools/call\",\"params\":{\"name\":\"fs_list\",\"arguments\":{\""
                                     + field + "\":1.0000000000000000000000000000000000000000001}}}\n").utf8))
            let rejected = try fixture.responses.read(timeout: 3)
            XCTAssertEqual(rejected["id"] as? String, id)
            let result = try XCTUnwrap(rejected["result"] as? [String: Any])
            let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(payload["code"] as? String, "listing_invalid_argument", field)
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertNil(payload["entries"])
            try fixture.send(["jsonrpc": "2.0", "id": "after-" + id, "method": "ping"])
            let ping = try fixture.responses.read(timeout: 3)
            XCTAssertEqual(ping["id"] as? String, "after-" + id)
            XCTAssertNotNil(ping["result"])
        }
        let error = fixture.stop()
        stopped = true
        XCTAssertNil(error)
    }

    func testPagedListingRawIntegerCanonicalizationPreservesExactNotationAndLegacyMode() throws {
        for token in ["1.0", "1e2", "100"] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data(("{\"method\":\"tools/call\",\"params\":{\"name\":\"fs_list\",\"arguments\":{\"limit\":" + token + "}}}\n").utf8))
            try pipe.fileHandleForWriting.close()
            defer { try? pipe.fileHandleForReading.close() }
            let reader = MCPStreamReader(handle: pipe.fileHandleForReading)
            defer { reader.close() }
            let message = try XCTUnwrap(reader.readMessage())
            let parameters = try XCTUnwrap(message["params"] as? [String: Any])
            let arguments = try XCTUnwrap(parameters["arguments"] as? [String: Any])
            XCTAssertEqual(try FilesystemListingPage.Arguments(arguments).limit, token == "1.0" ? 1 : 100)
        }
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"method\":\"tools/call\",\"params\":{\"name\":\"fs_list\",\"arguments\":{\"path\":3}}}\n".utf8))
        try pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        let reader = MCPStreamReader(handle: pipe.fileHandleForReading)
        defer { reader.close() }
        let message = try XCTUnwrap(reader.readMessage())
        let parameters = try XCTUnwrap(message["params"] as? [String: Any])
        let arguments = try XCTUnwrap(parameters["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["path"] as? Int, 3)
        XCTAssertNil(arguments["limit"])
    }

    func testAlreadyExpiredPagedListingResponseHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0, toolName: "fs_list")
    }

    private func checkRendererDeadlineDuringProjectContention(timeoutSeconds: TimeInterval,
                                                            toolName: String = "web.render") async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-render-budget-deadline-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown(); try? FileManager.default.removeItem(at: root) }
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
        let client = ClientID("render-budget-deadline")
        let initialized = try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(initialized.ok, "\(initialized.payload)")
        let context = try app.projectContexts.invocationContext(for: client)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        await app.projectContexts.repository.configureOperationObservers(beforeCommit: {
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        })
        let writer = Task.detached {
            try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: "owned-contention"),
                projectID: context.projectID, generation: context.projectGeneration,
                authorizationScope: context.authorizationScope)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success,
            "The fixture must hold actual project-operation admission before the request")
        let server = MCPServer(app: app, clientID: client)
        let control = ToolCallCancellation(timeoutSeconds: timeoutSeconds)
        let start = Date()
        let arguments: [String: Any] = toolName == "fs_list"
            ? ["path": project.path, "limit": 1]
            : toolName == "web.search"
                ? ["query": "deadline-before-dispatch"]
                : ["url": "https://example.com/"]
        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": "contended-render", "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments]
        ], cancellation: control))
        let elapsed = Date().timeIntervalSince(start)
        for _ in 0..<4 { release.signal() }
        _ = try await writer.value
        await app.projectContexts.repository.configureOperationObservers()
        XCTAssertLessThan(elapsed, 1, "The budget lookup must not replace the caller's deadline with its own wait")
        XCTAssertEqual(response["id"] as? String, "contended-render")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["code"] as? String, "deadline_exceeded")
        XCTAssertEqual(result["isError"] as? Bool, true)
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
        // The busy ping proves notification processing, not process termination.
        // Keep the hook held until the cancellation response confirms settlement;
        // releasing it here can let Git commit before the runner observes cancellation.

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
            git add tracked.txt

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

    func testMCPToolRequestAndRouterResultShareInvocationIdentity() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-mcp-correlation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let server = MCPServer(app: app, clientID: ClientID("correlation-fixture"))
        _ = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"],
        ]))
        let call = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "forge_status", "arguments": [:]] as [String: Any],
        ]))
        XCTAssertNotNil(call["result"])
        let records = app.diagnostics.recent(limit: 100)
        let request = try XCTUnwrap(records.last {
            $0.event == "mcp_tools_call" && $0.fields["tool"] == "forge_status"
        })
        let result = try XCTUnwrap(records.last {
            ($0.event == "tool_call" || $0.event == "tool_call_failed")
                && $0.fields["tool"] == "forge_status"
        })
        let invocationID = try XCTUnwrap(request.fields["invocation_id"])
        XCTAssertNotNil(UUID(uuidString: invocationID))
        XCTAssertEqual(result.fields["invocation_id"], invocationID)
        XCTAssertEqual(result.fields["client_id"], request.fields["client_id"])
    }

    func testDiagnosticErrorIdentitySurvivesPersistenceAndExport() throws {
        XCTAssertEqual(DiagnosticRedaction.redactedValue("<redacted:14b>", forKey: "error"),
                       "<redacted:14b>")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let log = DiagnosticLog(paths: AppPaths(home: home))
        log.error("read_failed", [
            "error": "Permission denied at /Users/private/secret.txt",
            "error_type": "NSPOSIXErrorDomain",
            "native_error_code": "13",
        ], category: .tools)
        let original = try XCTUnwrap(log.recent(limit: 1).first)
        XCTAssertNotNil(original.recordID)
        XCTAssertNotNil(original.processInstanceID)
        XCTAssertEqual(original.appVersion, ForgeApp.version)
        XCTAssertEqual(original.buildIdentity, ForgeApp.buildVersion)
        XCTAssertEqual(original.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(original.category, .tools)
        XCTAssertEqual(original.role, "primary")
        XCTAssertFalse(original.tsISO.isEmpty)
        XCTAssertEqual(original.component, DiagnosticCategory.tools.rawValue)
        XCTAssertEqual(original.fields["error"], "Permission denied at <redacted:path>")
        XCTAssertEqual(original.fields["redacted_fields"], "error")
        XCTAssertEqual(original.fields["sanitization_reasons"], "error=path")
        let loaded = try XCTUnwrap(log.loadPersisted().first)
        XCTAssertEqual(loaded.recordID, original.recordID)
        XCTAssertEqual(loaded.fields, original.fields)
        log.warn("already_redacted", ["path": "<redacted:14b>"], category: .tools)
        let reloadedMarker = try XCTUnwrap(log.loadPersisted().last)
        XCTAssertEqual(reloadedMarker.fields["path"], "<redacted:14b>")
        let exported = try log.export(to: home.appendingPathComponent("export"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.jsonURL)) as? [String: Any])
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["record_id"] as? String, original.recordID)
        XCTAssertEqual(records.first?["component"] as? String, DiagnosticCategory.tools.rawValue)
        XCTAssertFalse(try String(contentsOf: exported.jsonURL, encoding: .utf8).contains("/Users/private/secret.txt"))
        log.warn("long_failure", ["message": String(repeating: "x", count: 600)], category: .tools)
        let truncated = try XCTUnwrap(log.recent(limit: 1).first)
        XCTAssertEqual(truncated.fields["message"]?.count, 512)
        XCTAssertEqual(truncated.fields["truncated_fields"], "message")
        XCTAssertEqual(truncated.fields["sanitization_reasons"], "message=length_limit")
        log.warn("distinct_capture_states", [
            "path": "/Users/private/secret.txt",
            "handoff_id": "unavailable_before_packet_build",
            "message": String(repeating: "a", count: 600),
        ], category: .tools)
        let states = try XCTUnwrap(log.recent(limit: 1).first)
        XCTAssertTrue(states.fields["path"]?.hasPrefix("<redacted:") == true)
        XCTAssertEqual(states.fields["handoff_id"], "unavailable_before_packet_build")
        XCTAssertEqual(states.fields["redacted_fields"], "path")
        XCTAssertEqual(states.fields["truncated_fields"], "message")
        XCTAssertEqual(states.fields["unavailable_fields"], "handoff_id")
        XCTAssertNotEqual(states.fields["path"], states.fields["handoff_id"])
        XCTAssertNotEqual(states.fields["message"], states.fields["handoff_id"])
    }

    func testDiagnosticTimelineDisclosesItsLimit() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-timeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let log = DiagnosticLog(paths: AppPaths(home: home), ringLimit: 2_101,
                                maximumLogBytes: 8 * 1024 * 1024, retainedArchives: 1,
                                persistenceQueueCapacity: 4_096)
        for index in 0..<2_001 {
            log.info("row_\(index)", category: .diagnostics)
        }
        let exported = try log.export(to: home.appendingPathComponent("export"))
        let markdown = try String(contentsOf: exported.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("2000 of 2001 selected; 1 omitted"))
        XCTAssertTrue(markdown.contains("**Timeline is partial:** 1 earlier records omitted"))
        XCTAssertFalse(markdown.contains("| row_0 |"))
        XCTAssertTrue(markdown.contains("| row_2000 |"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.jsonURL)) as? [String: Any])
        XCTAssertEqual(json["json_record_count"] as? Int, 2_001)
        XCTAssertEqual(json["json_omitted_count"] as? Int, 0)
        XCTAssertEqual(json["markdown_record_count"] as? Int, 2_000)
        XCTAssertEqual(json["markdown_omitted_count"] as? Int, 1)
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        let firstIncluded = try XCTUnwrap(records[1]["record_id"] as? String)
        let lastIncluded = try XCTUnwrap(records.last?["record_id"] as? String)
        XCTAssertTrue(markdown.contains("**Included timeline range:** \(firstIncluded)"))
        XCTAssertTrue(markdown.contains("to \(lastIncluded)"))
        XCTAssertEqual(json["first_record_id"] as? String, records.first?["record_id"] as? String)
        XCTAssertEqual(json["last_record_id"] as? String, lastIncluded)
    }

    func testFailedToolDiagnosticUsesReturnedExecutionFields() {
        let result = ToolResult(ok: false, payload: ["ok": false, "exit_code": 7,
            "timed_out": false, "stderr": "grep failed", "count": 0], isError: true)
        let fields = ToolRouter.resultDiagnosticFields(result, tool: "search_text",
            clientID: ClientID("diagnostic-client"), durationMs: 36, mutating: false)
        XCTAssertEqual(fields["outcome"], "returned_failure")
        XCTAssertEqual(fields["exit_code"], "7")
        XCTAssertEqual(fields["stderr"], "grep failed")
        XCTAssertEqual(fields["message"], "unavailable_in_result")
        XCTAssertNotNil(fields["invocation_id"])
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

final class DesktopProviderMCPAttachmentTests: XCTestCase {
    func testHookAttachmentUnlocksOnlyFrozenRunToolsEndToEnd() async throws {
        try await withFixture { fixture in
            let arguments = try await claim(
                fixture,
                runtime: fixture.runtime,
                sessionID: "codex-session-e2e"
            )
            let token = try XCTUnwrap(arguments["attachment_token"] as? String)
            let runBindingValue = try await fixture.app.projectContexts.repository.binding(
                for: ProjectBindingOwner(
                    kind: .autonomousRun,
                    id: fixture.runID.description
                )
            )
            let runBinding = try XCTUnwrap(runBindingValue)
            XCTAssertNotNil(runBinding.leaseOwner)
            XCTAssertFalse(runBinding.leaseOwner?.contains(token) == true)

            let generic = MCPServer(
                app: fixture.app,
                clientID: ClientID("generic-serve-client")
            )
            XCTAssertEqual(
                try toolPayload(generic, name: "desktop_run_attach", arguments: arguments)["code"] as? String,
                "tool_not_allowed"
            )

            let clientID = ClientID("desktop-e2e-client")
            let server = MCPServer(
                app: fixture.app,
                clientID: clientID,
                desktopProviderID: .codexDesktop
            )
            let initialize = try response(server, method: "initialize", params: [
                "protocolVersion": "2025-11-25",
            ])
            let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
            let serverInfo = try XCTUnwrap(initializeResult["serverInfo"] as? [String: Any])
            XCTAssertEqual(serverInfo["name"] as? String, "forge-conductor-codex-desktop")
            let capabilities = try XCTUnwrap(
                initializeResult["capabilities"] as? [String: Any]
            )
            let attachmentCapability = try XCTUnwrap(
                capabilities["desktopRunAttachment"] as? [String: Any]
            )
            XCTAssertEqual(attachmentCapability["providerID"] as? String, "codex-desktop")
            XCTAssertEqual(attachmentCapability["requiredBeforeTools"] as? Bool, true)

            let listed = try response(server, method: "tools/list")
            let listedResult = try XCTUnwrap(listed["result"] as? [String: Any])
            let toolNames = Set(
                (try XCTUnwrap(listedResult["tools"] as? [[String: Any]]))
                    .compactMap { $0["name"] as? String }
            )
            XCTAssertTrue(toolNames.isSuperset(of: [
                "desktop_run_attach", "instruction_catalog", "instruction_read",
                "fs_read", "fs_write",
            ]))

            XCTAssertEqual(
                try toolPayload(
                    server,
                    name: "instruction_catalog",
                    arguments: ["snapshot_sha256": fixture.snapshotSHA256]
                )["code"] as? String,
                "desktop_attachment_required"
            )

            let attached = try toolPayload(
                server,
                name: "desktop_run_attach",
                arguments: arguments
            )
            XCTAssertEqual(attached["attached"] as? Bool, true)
            XCTAssertEqual(attached["run_id"] as? String, fixture.runID.description)
            XCTAssertNil(attached["attachment_token"])
            let consumedBindingValue = try await fixture.app.projectContexts.repository.binding(
                for: ProjectBindingOwner(
                    kind: .autonomousRun,
                    id: fixture.runID.description
                )
            )
            let consumedBinding = try XCTUnwrap(consumedBindingValue)
            XCTAssertEqual(consumedBinding.bindingID, runBinding.bindingID)
            XCTAssertEqual(consumedBinding.projectID, runBinding.projectID)
            XCTAssertEqual(consumedBinding.projectGeneration, runBinding.projectGeneration)
            XCTAssertEqual(consumedBinding.runID, runBinding.runID)
            XCTAssertEqual(consumedBinding.authorizationScope, runBinding.authorizationScope)
            XCTAssertNil(consumedBinding.leaseOwner)
            XCTAssertNil(consumedBinding.leaseExpiresAt)

            let catalog = try toolPayload(
                server,
                name: "instruction_catalog",
                arguments: ["snapshot_sha256": fixture.snapshotSHA256]
            )
            XCTAssertEqual(catalog["ok"] as? Bool, true)
            let documents = try XCTUnwrap(catalog["documents"] as? [[String: Any]])
            let documentID = try XCTUnwrap(documents.first?["id"] as? String)
            let document = try toolPayload(
                server,
                name: "instruction_read",
                arguments: [
                    "snapshot_sha256": fixture.snapshotSHA256,
                    "document_id": documentID,
                ]
            )
            XCTAssertEqual(document["ok"] as? Bool, true)
            XCTAssertTrue(
                (document["content"] as? String)?.contains("attachment fixture") == true
            )

            let read = try toolPayload(
                server,
                name: "fs_read",
                arguments: ["path": fixture.instructionSource.path]
            )
            XCTAssertEqual(read["ok"] as? Bool, true)
            let forbiddenURL = fixture.projectRoot.appendingPathComponent("forbidden.txt")
            let forbidden = try toolPayload(
                server,
                name: "fs_write",
                arguments: ["path": forbiddenURL.path, "content": "must not be written"]
            )
            XCTAssertEqual(forbidden["code"] as? String, "tool_not_granted")
            XCTAssertFalse(FileManager.default.fileExists(atPath: forbiddenURL.path))
        }
    }

    func testAttachmentRejectsWrongRoleScopeReplayConflictAndExpiry() async throws {
        try await withFixture { fixture in
            XCTAssertEqual(
                try ForgeProcessEntry.desktopProviderID(inServeArguments: [
                    "serve", "--desktop-provider", "codex-desktop",
                ]),
                .codexDesktop
            )
            XCTAssertNil(try ForgeProcessEntry.desktopProviderID(inServeArguments: ["serve"]))
            XCTAssertThrowsError(try ForgeProcessEntry.desktopProviderID(inServeArguments: [
                "serve", "--desktop-provider", "codex-desktop",
                "--desktop-provider", "claude-desktop",
            ]))
            XCTAssertThrowsError(try ForgeProcessEntry.desktopProviderID(inServeArguments: [
                "serve", "--desktop-provider", "lmstudio",
            ]))

            let original = try await claim(
                fixture,
                runtime: fixture.runtime,
                sessionID: "identity-session"
            )
            let wrongRole = MCPServer(
                app: fixture.app,
                clientID: ClientID("wrong-provider-role"),
                desktopProviderID: .claudeDesktop
            )
            XCTAssertEqual(
                try toolPayload(wrongRole, name: "desktop_run_attach", arguments: original)["code"] as? String,
                "tool_not_allowed"
            )

            let verifier = MCPServer(
                app: fixture.app,
                clientID: ClientID("identity-verifier"),
                desktopProviderID: .codexDesktop
            )
            var wrongSession = original
            wrongSession["session_sha256"] = String(repeating: "a", count: 64)
            XCTAssertEqual(
                try toolPayload(verifier, name: "desktop_run_attach", arguments: wrongSession)["code"] as? String,
                "desktop_attachment_rejected"
            )
            var wrongProject = original
            wrongProject["project_id"] = ProjectID().description
            XCTAssertEqual(
                try toolPayload(verifier, name: "desktop_run_attach", arguments: wrongProject)["code"] as? String,
                "desktop_attachment_rejected"
            )
            var wrongRun = original
            wrongRun["run_id"] = RunID().description
            XCTAssertEqual(
                try toolPayload(verifier, name: "desktop_run_attach", arguments: wrongRun)["code"] as? String,
                "desktop_attachment_rejected"
            )
            var wrongDeployment = original
            wrongDeployment["deployment_id"] = "different-deployment"
            XCTAssertEqual(
                try toolPayload(verifier, name: "desktop_run_attach", arguments: wrongDeployment)["code"] as? String,
                "desktop_attachment_rejected"
            )
            var extraField = original
            extraField["unexpected"] = true
            XCTAssertEqual(
                try toolPayload(verifier, name: "desktop_run_attach", arguments: extraField)["code"] as? String,
                "desktop_attachment_invalid"
            )

            let currentRunValue = try await fixture.app.projectContexts.repository.autonomousRun(
                fixture.runID
            )
            let currentRun = try XCTUnwrap(currentRunValue)
            let conflictID = ClientID("prebound-conflicting-client")
            _ = try await fixture.app.projectContexts.repository.bind(
                owner: ProjectBindingOwner(kind: .mcpClient, id: conflictID.rawValue),
                projectID: currentRun.projectID,
                generation: currentRun.projectGeneration,
                authorizationScope: fixture.authorizationScope
            )
            let conflictServer = MCPServer(
                app: fixture.app,
                clientID: conflictID,
                desktopProviderID: .codexDesktop
            )
            XCTAssertEqual(
                try toolPayload(conflictServer, name: "desktop_run_attach", arguments: original)["code"] as? String,
                "desktop_attachment_conflict"
            )

            XCTAssertEqual(
                try toolPayload(verifier, name: "desktop_run_attach", arguments: original)["attached"] as? Bool,
                true
            )
            let replay = MCPServer(
                app: fixture.app,
                clientID: ClientID("replay-client"),
                desktopProviderID: .codexDesktop
            )
            XCTAssertEqual(
                try toolPayload(replay, name: "desktop_run_attach", arguments: original)["code"] as? String,
                "desktop_attachment_rejected"
            )

            let superseded = try await claim(
                fixture,
                runtime: fixture.runtime,
                sessionID: "identity-session",
                event: .userPromptSubmit
            )
            let fresh = try await claim(
                fixture,
                runtime: fixture.runtime,
                sessionID: "identity-session",
                event: .userPromptSubmit
            )
            XCTAssertNotEqual(
                superseded["attachment_token"] as? String,
                fresh["attachment_token"] as? String
            )
            XCTAssertEqual(
                try toolPayload(
                    MCPServer(
                        app: fixture.app,
                        clientID: ClientID("superseded-client"),
                        desktopProviderID: .codexDesktop
                    ),
                    name: "desktop_run_attach",
                    arguments: superseded
                )["code"] as? String,
                "desktop_attachment_rejected"
            )
            XCTAssertEqual(
                try toolPayload(
                    MCPServer(
                        app: fixture.app,
                        clientID: ClientID("fresh-client"),
                        desktopProviderID: .codexDesktop
                    ),
                    name: "desktop_run_attach",
                    arguments: fresh
                )["attached"] as? Bool,
                true
            )

            let expiring = try await claim(
                fixture,
                runtime: fixture.runtime,
                sessionID: "identity-session",
                event: .userPromptSubmit
            )
            fixture.clock.date.addTimeInterval(
                DesktopProviderMCPAttachmentContract.capabilityLifetime + 1
            )
            XCTAssertEqual(
                try toolPayload(
                    MCPServer(
                        app: fixture.app,
                        clientID: ClientID("expired-client"),
                        desktopProviderID: .codexDesktop
                    ),
                    name: "desktop_run_attach",
                    arguments: expiring
                )["code"] as? String,
                "desktop_attachment_rejected"
            )
        }
    }

    func testAttachmentBindingsRemainBoundedAcrossRestartReclaimsAndTerminalState() async throws {
        try await withFixture { fixture in
            let initial = try await claim(
                fixture,
                runtime: fixture.runtime,
                sessionID: "interrupted-session"
            )
            let interruptedServer = MCPServer(
                app: fixture.app,
                clientID: ClientID("interrupted-client"),
                desktopProviderID: .codexDesktop
            )
            XCTAssertEqual(
                try toolPayload(interruptedServer, name: "desktop_run_attach", arguments: initial)["attached"] as? Bool,
                true
            )
            let initialBindingCount = try await fixture.app.projectContexts.repository
                .desktopProviderMCPBindingCount(runID: fixture.runID)
            XCTAssertEqual(initialBindingCount, 1)

            await fixture.runtime.shutdown()
            let restarted = try ManagedAutonomyRuntime(
                app: fixture.app,
                registry: HostAdapterRegistry(),
                maximumConcurrentRuns: 1
            )
            _ = try await restarted.start()
            do {
                let restartBindingCount = try await fixture.app.projectContexts.repository
                    .desktopProviderMCPBindingCount(runID: fixture.runID)
                XCTAssertEqual(restartBindingCount, 0)
                XCTAssertEqual(
                    try toolPayload(
                        interruptedServer,
                        name: "fs_read",
                        arguments: ["path": fixture.instructionSource.path]
                    )["code"] as? String,
                    "desktop_attachment_required"
                )

                for index in 0..<12 {
                    let sessionID = "reclaimed-session-\(index)"
                    let arguments = try await claim(
                        fixture,
                        runtime: restarted,
                        sessionID: sessionID
                    )
                    let server = MCPServer(
                        app: fixture.app,
                        clientID: ClientID("reclaimed-client-\(index)"),
                        desktopProviderID: .codexDesktop
                    )
                    XCTAssertEqual(
                        try toolPayload(
                            server,
                            name: "desktop_run_attach",
                            arguments: arguments
                        )["attached"] as? Bool,
                        true
                    )
                    let attachedBindingCount = try await fixture.app.projectContexts.repository
                        .desktopProviderMCPBindingCount(runID: fixture.runID)
                    XCTAssertEqual(attachedBindingCount, 1)
                    _ = try await restarted.handleDesktopProviderHook(
                        try Self.hookRequest(
                            event: .sessionEnd,
                            sessionID: sessionID,
                            cwd: fixture.projectRoot.path
                        ),
                        selectionRevision: fixture.selectionRevision
                    )
                    let endedBindingCount = try await fixture.app.projectContexts.repository
                        .desktopProviderMCPBindingCount(runID: fixture.runID)
                    XCTAssertEqual(endedBindingCount, 0)
                }

                let terminalArguments = try await claim(
                    fixture,
                    runtime: restarted,
                    sessionID: "terminal-session"
                )
                let terminalServer = MCPServer(
                    app: fixture.app,
                    clientID: ClientID("terminal-client"),
                    desktopProviderID: .codexDesktop
                )
                XCTAssertEqual(
                    try toolPayload(
                        terminalServer,
                        name: "desktop_run_attach",
                        arguments: terminalArguments
                    )["attached"] as? Bool,
                    true
                )
                let runValue = try await fixture.app.projectContexts.repository.autonomousRun(
                    fixture.runID
                )
                var run = try XCTUnwrap(runValue)
                let lease = try await fixture.app.projectContexts.repository.acquireRunLease(
                    runID: fixture.runID,
                    ownerID: "attachment-terminal-test"
                )
                run = try await fixture.app.projectContexts.repository.transitionAutonomousRun(
                    runID: fixture.runID,
                    lease: lease,
                    transition: AutonomousRunTransition(
                        expectedState: run.state,
                        expectedRevision: run.revision,
                        nextState: .cancelRequested,
                        eventType: "attachment_test_cancel_requested",
                        eventSummary: "Attachment fixture requested cancellation"
                    )
                )
                let requestedBindingCount = try await fixture.app.projectContexts.repository
                    .desktopProviderMCPBindingCount(runID: fixture.runID)
                XCTAssertEqual(requestedBindingCount, 1)
                _ = try await fixture.app.projectContexts.repository.transitionAutonomousRun(
                    runID: fixture.runID,
                    lease: lease,
                    transition: AutonomousRunTransition(
                        expectedState: run.state,
                        expectedRevision: run.revision,
                        nextState: .cancelled,
                        eventType: "attachment_test_cancelled",
                        eventSummary: "Attachment fixture cancellation completed"
                    )
                )
                _ = try await fixture.app.projectContexts.repository.releaseRunLease(lease)
                let finalBindingCount = try await fixture.app.projectContexts.repository
                    .desktopProviderMCPBindingCount()
                XCTAssertEqual(finalBindingCount, 0)
                XCTAssertEqual(
                    try toolPayload(
                        terminalServer,
                        name: "fs_read",
                        arguments: ["path": fixture.instructionSource.path]
                    )["code"] as? String,
                    "desktop_attachment_required"
                )
            } catch {
                await restarted.shutdown()
                throw error
            }
            await restarted.shutdown()
        }
    }

    private struct Fixture {
        let root: URL
        let projectRoot: URL
        let instructionSource: URL
        let app: ForgeApp
        let runtime: ManagedAutonomyRuntime
        let clock: FixedClock
        let project: ProjectControlRecord
        let runID: RunID
        let snapshotSHA256: String
        let selectionRevision: String
        let authorizationScope: ToolAuthorizationScope
    }

    private func withFixture(
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.runtime.shutdown()
            _ = fixture.app.shutdown()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        await fixture.runtime.shutdown()
        _ = fixture.app.shutdown()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-desktop-attachment-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let clock = FixedClock(try XCTUnwrap(ISO8601.date(from: "2026-09-23T12:00:00Z")))
        let app = try ForgeApp.bootstrap(home: home, clock: clock)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: false)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(),
            displayName: "Desktop Attachment Fixture",
            canonicalRoot: projectRoot
        )
        let runID = RunID()
        let instructionSource = projectRoot.appendingPathComponent("instructions.txt")
        try "Read every attachment fixture instruction before acting.\n".write(
            to: instructionSource,
            atomically: true,
            encoding: .utf8
        )
        let instructionStore = try ProjectInstructionQueueStore(paths: app.paths, clock: clock)
        let artifact = try instructionStore.importRunArtifact(
            sourceURL: instructionSource,
            projectID: project.projectID,
            generation: project.generation,
            runID: runID
        )
        let allowedTools: Set<String> = [
            "instruction_catalog", "instruction_read", "fs_read",
        ]
        let scope = ToolAuthorizationScope(
            canonicalRoots: [projectRoot],
            allowedTools: allowedTools,
            networkAllowed: false,
            maximumInlineOutputBytes: 64 * 1_024
        )
        let selectionRevision = "desktop-selection-r1"
        let request = AutonomousRunRequest(
            runID: runID,
            projectID: project.projectID,
            projectGeneration: project.generation,
            mission: "Complete the immutable desktop attachment fixture",
            providerID: ProviderIntegrationID.codexDesktop.rawValue,
            adapterID: "forge.desktop-plugin.codex-desktop",
            modelKey: "host-selected",
            specification: AutonomousRunSpecification(
                allowedTools: allowedTools.sorted(),
                completionGates: ["desktop_attachment_fixture"],
                work: AutonomousRunWork(metadata: [
                    "execution_strategy": ProviderExecutionStrategy.desktopPluginPull.rawValue,
                    "provider_selection_revision": selectionRevision,
                    "provider_deployment_id": "desktop-deployment-r1",
                    "source_kind": ManagerPreparedRunSourceKind.instructionArtifact.rawValue,
                    "source_snapshot_sha256": artifact.contentSHA256,
                ])
            ),
            authorizationScope: scope
        )
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await runtime.start()
        _ = try await runtime.createRun(request)
        return Fixture(
            root: root,
            projectRoot: projectRoot,
            instructionSource: instructionSource,
            app: app,
            runtime: runtime,
            clock: clock,
            project: project,
            runID: runID,
            snapshotSHA256: artifact.contentSHA256,
            selectionRevision: selectionRevision,
            authorizationScope: scope
        )
    }

    private func claim(
        _ fixture: Fixture,
        runtime: ManagedAutonomyRuntime,
        sessionID: String,
        event: DesktopProviderHookEvent = .sessionStart
    ) async throws -> [String: Any] {
        let directive = try await runtime.handleDesktopProviderHook(
            try Self.hookRequest(
                event: event,
                sessionID: sessionID,
                cwd: fixture.projectRoot.path
            ),
            selectionRevision: fixture.selectionRevision
        )
        guard case .context(let context) = directive else {
            throw AttachmentFixtureError.missingAssignment
        }
        let prefix = "call desktop_run_attach exactly once with this exact argument object: "
        let suffix = ". This single-use attachment expires at "
        guard let start = context.range(of: prefix)?.upperBound,
              let end = context.range(of: suffix, range: start..<context.endIndex)?.lowerBound else {
            throw AttachmentFixtureError.missingAttachment
        }
        return try JSONSupport.object(from: Data(context[start..<end].utf8))
    }

    private static func hookRequest(
        event: DesktopProviderHookEvent,
        sessionID: String,
        cwd: String
    ) throws -> DesktopProviderHookRequest {
        try DesktopProviderHookRequest(
            providerID: .codexDesktop,
            event: event,
            hostPayload: JSONSerialization.data(withJSONObject: [
                "hook_event_name": event.rawValue,
                "session_id": sessionID,
                "cwd": cwd,
            ], options: [.sortedKeys])
        )
    }

    private func response(
        _ server: MCPServer,
        method: String,
        params: [String: Any]? = nil
    ) throws -> [String: Any] {
        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString.lowercased(),
            "method": method,
        ]
        if let params { request["params"] = params }
        return try XCTUnwrap(server.handle(request))
    }

    private func toolPayload(
        _ server: MCPServer,
        name: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        let call = try response(server, method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private enum AttachmentFixtureError: Error {
        case missingAssignment
        case missingAttachment
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

    func sendRaw(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
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

extension MCPProtocolAndDiagnosticsTests {
    func testWebFetchWireBudgetIncludesEscapedIDLineFeedAndScopedNotice() async throws {
        let proof = try await Task.detached(priority: .utility) {
            try WebEnvelopeWireFixture.collect()
        }.value
        let first = try JSONSupport.object(from: Data(proof.frames[0].dropLast()))
        let second = try JSONSupport.object(from: Data(proof.frames[1].dropLast()))
        XCTAssertEqual(first["id"] as? String, proof.escapedID)
        XCTAssertEqual(second["id"] as? Int, 92)
        var expectedOffset = 0
        for frame in proof.frames {
            XCTAssertEqual(frame.last, 10)
            XCTAssertEqual(frame.filter { $0 == 10 }.count, 1,
                "Escaped newlines must not become extra wire frames")
            XCTAssertLessThanOrEqual(frame.count, proof.projectBudget,
                "Measure the actual received ID, both payload copies, required notice and LF")
            let response = try JSONSupport.object(from: Data(frame.dropLast()))
            XCTAssertNil(response["error"])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false)
            let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(blocks.count, 2)
            XCTAssertEqual(blocks[1]["text"] as? String, proof.notice)
            let canonical = try XCTUnwrap(blocks[0]["text"] as? String)
            XCTAssertEqual(try JSONSupport.canonicalJSON(JSONSupport.object(from: Data(canonical.utf8))),
                try JSONSupport.canonicalJSON(payload))
            XCTAssertEqual(payload["project_id"] as? String, proof.projectID)
            XCTAssertEqual((payload["project_generation"] as? NSNumber)?.uint64Value, proof.generation)
            XCTAssertEqual(payload["format"] as? String, "source")
            XCTAssertEqual(payload["content_sha256"] as? String, JSONSupport.sha256Hex(proof.source))
            XCTAssertEqual(payload["total_content_bytes"] as? Int, proof.source.count)
            XCTAssertEqual(payload["byte_offset"] as? Int, expectedOffset)
            let content = try XCTUnwrap(payload["content"] as? String)
            XCTAssertFalse(content.isEmpty)
            XCTAssertTrue(Data(proof.source.dropFirst(expectedOffset)).starts(with: Data(content.utf8)))
            XCTAssertEqual(payload["returned_content_bytes"] as? Int, content.utf8.count)
            expectedOffset += content.utf8.count
            XCTAssertEqual(payload["has_more"] as? Bool, expectedOffset < proof.source.count)
            XCTAssertEqual(payload["truncated"] as? Bool, expectedOffset < proof.source.count)
            if expectedOffset < proof.source.count {
                XCTAssertEqual(payload["next_byte_offset"] as? Int, expectedOffset)
            } else {
                XCTAssertTrue(payload["next_byte_offset"] is NSNull)
            }
        }
    }

    func testWebFetchContextLookupHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0.1, toolName: "web.fetch")
    }

    func testAlreadyExpiredWebFetchHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0, toolName: "web.fetch")
    }

    func testWebSearchContextLookupHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0.1, toolName: "web.search")
    }

    func testAlreadyExpiredWebSearchHonorsRequestDeadlineDuringProjectContention() async throws {
        try await checkRendererDeadlineDuringProjectContention(timeoutSeconds: 0, toolName: "web.search")
    }

    func testWebReadsWithoutProjectKeepContextDenialAndDeniedAudit() async throws {
        let proofs = try await Task.detached(priority: .utility) {
            try WebEnvelopeWireFixture.missingContext()
        }.value
        XCTAssertEqual(proofs.count, 2)
        for proof in proofs {
            let response = try JSONSupport.object(from: Data(proof.frame.dropLast()))
            XCTAssertEqual(response["id"] as? String, proof.tool)
            XCTAssertNil(response["error"])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            let payload = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(payload["code"] as? String, "project_context_required")
            XCTAssertEqual(proof.audit.tool, proof.tool)
            XCTAssertEqual(proof.audit.status, "denied")
            XCTAssertEqual(proof.audit.clientID, proof.clientID)
        }
    }
}

private struct WebEnvelopeWireFixture {
    struct Proof: Sendable {
        let frames: [Data]
        let source: Data
        let escapedID: String
        let notice: String
        let projectID: String
        let generation: UInt64
        let projectBudget: Int
    }
    struct DenialProof: Sendable {
        let frame: Data
        let tool: String
        let clientID: String
        let audit: AuditEvent
    }
    enum FixtureError: Error { case invalid(String) }

    static func collect() throws -> Proof {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-web-envelope-\(UUID())")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"))
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
        let bootstrap = ClientID("web-envelope-bootstrap")
        let initialized = try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": project.path], clientID: bootstrap)
        guard initialized.ok else { throw FixtureError.invalid("project initialize failed") }
        let registered = try app.projectContexts.invocationContext(for: bootstrap)
        let projectBudget = 8_192
        let client = ClientID("web-envelope-scoped")
        let scope = ToolAuthorizationScope(canonicalRoots: registered.authorizationScope.canonicalRoots,
            allowedTools: ["web.fetch"], networkAllowed: true, maximumInlineOutputBytes: projectBudget)
        _ = try app.projectContexts.bind(owner: .init(kind: .mcpClient, id: client.rawValue),
            projectID: registered.projectID, generation: registered.projectGeneration, authorizationScope: scope)
        let context = try app.projectContexts.invocationContext(for: client)
        guard context.authorizationScope.maximumInlineOutputBytes == projectBudget else {
            throw FixtureError.invalid("project budget did not bind")
        }
        let source = Data(("<html><head><title>Owned envelope fixture</title></head><body>"
            + String(repeating: "owned😀\"\\\n", count: 2_048) + "</body></html>").utf8)
        try FileManager.default.createDirectory(at: app.telemetry.staticDir, withIntermediateDirectories: true)
        try source.write(to: app.telemetry.staticDir.appendingPathComponent("index.html"))
        let http = DashboardServer(app: app, host: "127.0.0.1", port: try freeLoopbackPort())
        try http.start()
        defer { http.stop() }
        guard let rule = RavenForgeDevelopmentPolicyAdapter().rules().first else {
            throw FixtureError.invalid("policy rule missing")
        }
        let notice = CodingAgentPolicyNotice(violationID: PolicyViolationID(), ruleReference: rule.source,
            summary: "Required project policy fixture 😀 \"quoted\" \\ newline\n",
            suggestedCorrection: "Preserve this separate additive notice.", confidence: 0.95)
        guard let text = StjornarvaldPolicyNoticeFormatter.interactivePresentation(
            notices: [notice], maximumBytes: StjornarvaldPolicyNoticeFormatter.maximumPresentationBytes) else {
            throw FixtureError.invalid("policy presentation missing")
        }
        let provider = WebEnvelopeScopedNotice(projectID: context.projectID.description,
            generation: Int(context.projectGeneration.rawValue), clientID: client.rawValue, notice: notice, text: text)
        let mcp = MCPServer(app: app, clientID: client, role: .primary,
            maximumConcurrentRequests: 1, shutdownWaitSeconds: 5,
            requestTimeoutSeconds: 5, policyNoticeProvider: provider)
        let input = Pipe(), output = Pipe()
        let inputHandle = input.fileHandleForReading, outputHandle = output.fileHandleForWriting
        let finished = DispatchSemaphore(value: 0), errors = MCPWireErrorBox()
        var joined = false
        defer {
            try? input.fileHandleForWriting.close()
            if !joined { _ = finished.wait(timeout: .now() + 10) }
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        DispatchQueue(label: "forge.test.web-envelope", qos: .utility).async {
            do { try mcp.run(input: inputHandle, output: outputHandle) }
            catch { errors.store(error) }
            finished.signal()
        }
        let reader = MCPWireResponseReader(handle: output.fileHandleForReading)
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0", "id": 90, "method": "initialize",
            "params": ["protocolVersion": MCPServer.supportedProtocolVersions[0]]]))
        _ = try reader.read(timeout: 3)
        let escapedID = String(repeating: "id😀\"\\\n", count: 140)
        let url = http.baseURL.appendingPathComponent("index.html").absoluteString
        func send(id: Any, offset: Int) throws {
            var arguments: [String: Any] = ["url": url, "format": "source", "maximum_bytes": 16_384,
                "byte_offset": offset, "deadline_ms": 5_000, "timeout_sec": 3]
            if offset > 0 { arguments["if_content_sha256"] = JSONSupport.sha256Hex(source) }
            try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "web.fetch", "arguments": arguments]]))
        }
        try send(id: escapedID, offset: 0)
        let first = try reader.readFrameForWebEnvelope(timeout: 5)
        let response = try JSONSupport.object(from: Data(first.dropLast()))
        guard let result = response["result"] as? [String: Any],
              let payload = result["structuredContent"] as? [String: Any],
              let offset = payload["next_byte_offset"] as? Int, offset > 0 else {
            throw FixtureError.invalid("first page has no real continuation")
        }
        try send(id: 92, offset: offset)
        let second = try reader.readFrameForWebEnvelope(timeout: 5)
        try input.fileHandleForWriting.close()
        joined = finished.wait(timeout: .now() + 10) == .success
        guard joined, errors.take() == nil else { throw FixtureError.invalid("MCP serve did not finish normally") }
        guard !(try reader.hasMessage(timeout: 0.1)) else { throw FixtureError.invalid("unexpected response") }
        return Proof(frames: [first, second], source: source, escapedID: escapedID, notice: text,
            projectID: context.projectID.description, generation: context.projectGeneration.rawValue, projectBudget: projectBudget)
    }

    static func missingContext() throws -> [DenialProof] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-web-no-context-\(UUID())")
        let app = try ForgeApp.bootstrap(home: root)
        defer { _ = app.shutdown(); try? FileManager.default.removeItem(at: root) }
        let client = ClientID("unbound-web-envelope")
        let mcp = MCPServer(app: app, clientID: client, role: .primary,
            policyNoticeProvider: NoInteractivePolicyNoticeProvider())
        var proofs: [DenialProof] = []
        for tool in ["web.fetch", "web.search"] {
            let arguments = tool == "web.fetch" ? ["url": "http://127.0.0.1:1/never-requested"] : ["query": "never requested"]
            guard let result = mcp.handle(["jsonrpc": "2.0", "id": tool, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments]]) else { throw FixtureError.invalid("no denial response") }
            guard app.audit.flushAttempts(timeout: 2),
                  let audit = try app.audit.recent(limit: 20).first(where: { $0.clientID == client.rawValue && $0.tool == tool }) else {
                throw FixtureError.invalid("denied audit missing")
            }
            proofs.append(DenialProof(frame: try MCPStdioTransport.encode(result), tool: tool,
                clientID: client.rawValue, audit: audit))
        }
        return proofs
    }

    private static func freeLoopbackPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.invalid("socket failed") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard status == 0 else { throw FixtureError.invalid("loopback bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw FixtureError.invalid("loopback port lookup failed") }
        return UInt16(bigEndian: address.sin_port)
    }
}

private struct WebEnvelopeScopedNotice: InteractivePolicyNoticeProviding {
    let projectID: String
    let generation: Int
    let clientID: String
    let notice: CodingAgentPolicyNotice
    let text: String

    func presentation(deliveryID: String, projectID: String?, projectGeneration: Int?, clientID: String,
                      maximumCount: Int, maximumBytes: Int) -> PolicyNoticePresentation? {
        guard projectID == self.projectID, projectGeneration == generation, clientID == self.clientID,
              maximumCount >= 1, text.utf8.count <= maximumBytes else { return nil }
        return PolicyNoticePresentation(id: deliveryID, targetKind: .mcpClient, targetIdentity: clientID,
            notices: [notice], text: text, digestSHA256: JSONSupport.sha256Hex(text))
    }
    func didPresent(_ presentation: PolicyNoticePresentation) {}
}

private extension MCPWireResponseReader {
    func readFrameForWebEnvelope(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let frame = Data(buffer[...newline])
                buffer.removeSubrange(...newline)
                return frame
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, try waitForData(timeout: remaining) else { throw MCPWireTestError.timeout("web frame") }
            let chunk = try readAvailableData()
            guard !chunk.isEmpty else { throw MCPWireTestError.fixture("web frame stream closed") }
            guard buffer.count <= 131_072 - chunk.count else { throw MCPWireTestError.fixture("web frame capture exceeded 131072") }
            buffer.append(chunk)
        }
    }
}

extension MCPProtocolAndDiagnosticsTests {
    func testEOFSkippedNoticePacketDoesNotCommitPresentationReceipt() async throws {
        try await Task.detached(priority: .utility) {
            try MCPNoticeSkippedWriteFixture.collect()
        }.value
    }
}

private enum MCPNoticeSkippedWriteFixture {
    static func collect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcp-notice-skipped-write-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"), startTelemetry: false)
        let client = ClientID("notice-skipped-write")
        _ = try app.config.update(["allowed_roots": [root.path]], save: false)
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
            arguments: ["project_path": project.path], clientID: client).ok)
        let context = try app.projectContexts.invocationContext(for: client)
        let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
        let notice = CodingAgentPolicyNotice(violationID: PolicyViolationID(), ruleReference: rule.source,
            summary: "Exact skipped-write receipt fixture", suggestedCorrection: "Preserve receipt truth", confidence: 1)
        let text = try XCTUnwrap(StjornarvaldPolicyNoticeFormatter.interactivePresentation(notices: [notice]))
        let base = WebEnvelopeScopedNotice(projectID: context.projectID.description,
            generation: Int(context.projectGeneration.rawValue), clientID: client.rawValue,
            notice: notice, text: text)
        let provider = MCPNoticeSkippedWriteGate(base: base)
        let input = Pipe(), output = Pipe()
        let closed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let errors = MCPWireErrorBox()
        let server = MCPServer(app: app, clientID: client, role: .primary, maximumConcurrentRequests: 1,
            shutdownWaitSeconds: 3, responseWriteTimeoutSeconds: 1,
            didCloseResponseDeliveryObserver: {
                provider.markDeliveryClosedAndRelease()
                closed.signal()
            }, policyNoticeProvider: provider)
        let inputHandle = input.fileHandleForReading, outputHandle = output.fileHandleForWriting
        var joined = false
        defer {
            provider.release.signal()
            try? input.fileHandleForWriting.close()
            if !joined { joined = finished.wait(timeout: .now() + 4) == .success }
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            let complete = app.shutdown().completed
            if joined && complete { try? FileManager.default.removeItem(at: root) }
        }
        DispatchQueue(label: "forge.test.notice-skipped-write", qos: .userInitiated).async(flags: .enforceQoS) {
            do { try server.run(input: inputHandle, output: outputHandle) }
            catch { errors.store(error) }
            finished.signal()
        }
        let reader = MCPWireResponseReader(handle: output.fileHandleForReading)
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": MCPServer.supportedProtocolVersions[0]],
        ]))
        XCTAssertEqual((try reader.read(timeout: 2)["id"] as? NSNumber)?.intValue, 1)
        try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "job.list", "arguments": [:] as [String: Any]],
        ]))
        let entry = provider.entered.wait(timeout: .now() + 2)
        XCTAssertEqual(entry, .success)
        guard entry == .success else { throw POSIXError(.ETIMEDOUT) }
        try input.fileHandleForWriting.close()
        let closure = closed.wait(timeout: .now() + 2)
        XCTAssertEqual(closure, .success)
        guard closure == .success else { throw POSIXError(.ETIMEDOUT) }
        let completion = finished.wait(timeout: .now() + 4)
        XCTAssertEqual(completion, .success)
        joined = completion == .success
        guard joined else { throw POSIXError(.ETIMEDOUT) }
        let runError = errors.take()
        XCTAssertNil(runError)
        if let runError { throw runError }
        let gate = provider.snapshot()
        XCTAssertFalse(gate.timedOut)
        XCTAssertTrue(gate.deliveryClosed)
        guard !gate.timedOut, gate.deliveryClosed else { throw POSIXError(.ETIMEDOUT) }
        try output.fileHandleForWriting.close()
        let bytes = try output.fileHandleForReading.read(upToCount: 16 * 1_024)
        XCTAssertTrue(bytes?.isEmpty ?? true, "A notice response was transmitted after delivery closed")
        XCTAssertEqual(provider.snapshot().presented, 0,
            "didPresent ran despite EOF causing the complete notice packet to be skipped")
        withExtendedLifetime((server, provider)) {}
    }
}

private final class MCPNoticeSkippedWriteGate: InteractivePolicyNoticeProviding, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let base: WebEnvelopeScopedNotice
    private let lock = NSLock()
    private var presented = 0
    private var timedOut = false
    private var deliveryClosed = false
    init(base: WebEnvelopeScopedNotice) { self.base = base }
    func presentation(deliveryID: String, projectID: String?, projectGeneration: Int?, clientID: String,
                      maximumCount: Int, maximumBytes: Int) -> PolicyNoticePresentation? {
        guard let value = base.presentation(deliveryID: deliveryID, projectID: projectID,
            projectGeneration: projectGeneration, clientID: clientID,
            maximumCount: maximumCount, maximumBytes: maximumBytes) else { return nil }
        entered.signal()
        if release.wait(timeout: .now() + 2) != .success {
            lock.lock(); timedOut = true; lock.unlock()
        }
        return value
    }
    func markDeliveryClosedAndRelease() {
        lock.lock(); deliveryClosed = true; lock.unlock()
        release.signal()
    }
    func didPresent(_ presentation: PolicyNoticePresentation) {
        lock.lock(); presented += 1; lock.unlock()
    }
    func snapshot() -> (presented: Int, timedOut: Bool, deliveryClosed: Bool) {
        lock.lock(); defer { lock.unlock() }; return (presented, timedOut, deliveryClosed)
    }
}

extension MCPProtocolAndDiagnosticsTests {
    func testEOFPartialNoticePacketDoesNotCommitPresentationReceipt() async throws {
        try await Task.detached(priority: .utility) {
            try mcpCollectEOFPartialNoticePacket()
        }.value
    }
}

private func mcpCollectEOFPartialNoticePacket() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mcp-notice-partial-write-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"), startTelemetry: false)
    let client = ClientID("notice-partial-write")
    _ = try app.config.update(["allowed_roots": [root.path]], save: false)
    XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
        arguments: ["project_path": project.path], clientID: client).ok)
    let context = try app.projectContexts.invocationContext(for: client)
    let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
    let notices = (0..<8).map { index in
        CodingAgentPolicyNotice(violationID: PolicyViolationID(), ruleReference: rule.source,
            summary: "Owned partial packet fixture \(index)",
            policyStatement: String(repeating: "\u{0001}", count: 4_096),
            suggestedCorrection: "Preserve complete-packet receipt truth", confidence: 1)
    }
    let text = try XCTUnwrap(StjornarvaldPolicyNoticeFormatter.interactivePresentation(notices: notices))
    XCTAssertLessThanOrEqual(text.utf8.count, 16 * 1_024)
    let minimumFrame = try MCPStdioTransport.encode(MCPToolResponse.object(id: 2,
        result: .success(["jobs": [] as [Any], "count": 0, "has_more": false]), additiveNotice: text))
    XCTAssertGreaterThan(minimumFrame.count, 80 * 1_024,
        "The legal notice did not create the intended escaped packet magnitude")
    XCTAssertLessThanOrEqual(minimumFrame.count, 128 * 1_024)
    guard minimumFrame.count > 80 * 1_024, minimumFrame.count <= 128 * 1_024 else {
        throw POSIXError(.E2BIG)
    }
    let provider = MCPPartialPacketNoticeProvider(projectID: context.projectID.description,
        generation: Int(context.projectGeneration.rawValue), clientID: client.rawValue,
        notices: notices, text: text)
    let input = Pipe(), output = Pipe()
    let closed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let errors = MCPWireErrorBox()
    let server = MCPServer(app: app, clientID: client, role: .primary, maximumConcurrentRequests: 1,
        shutdownWaitSeconds: 3, responseWriteTimeoutSeconds: 2,
        didCloseResponseDeliveryObserver: { closed.signal() }, policyNoticeProvider: provider)
    let inputHandle = input.fileHandleForReading, outputHandle = output.fileHandleForWriting
    var joined = false
    defer {
        try? input.fileHandleForWriting.close()
        if !joined { joined = finished.wait(timeout: .now() + 4) == .success }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        let complete = app.shutdown().completed
        if joined && complete { try? FileManager.default.removeItem(at: root) }
    }
    DispatchQueue(label: "forge.test.notice-partial-write", qos: .utility).async {
        do { try server.run(input: inputHandle, output: outputHandle) }
        catch { errors.store(error) }
        finished.signal()
    }
    let reader = MCPWireResponseReader(handle: output.fileHandleForReading)
    try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": MCPServer.supportedProtocolVersions[0]],
    ]))
    XCTAssertEqual((try reader.read(timeout: 2)["id"] as? NSNumber)?.intValue, 1)
    let initialQueued = try mcpPartialPacketQueuedBytes(output.fileHandleForReading.fileDescriptor)
    XCTAssertEqual(initialQueued, 0)
    guard initialQueued == 0 else { throw POSIXError(.EBUSY) }
    try input.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "job.list", "arguments": [:] as [String: Any]],
    ]))
    var queued = 0
    for _ in 0..<100 {
        queued = try mcpPartialPacketQueuedBytes(output.fileHandleForReading.fileDescriptor)
        if queued >= 4_096 { break }
        usleep(10_000)
    }
    XCTAssertGreaterThanOrEqual(queued, 4_096, "No native response prefix was observed")
    guard queued >= 4_096 else { throw POSIXError(.ETIMEDOUT) }
    let presentedBeforeEOF = provider.presentedCount()
    XCTAssertEqual(presentedBeforeEOF, 0, "The packet already completed before the failure injection")
    guard presentedBeforeEOF == 0 else { throw POSIXError(.EALREADY) }
    try input.fileHandleForWriting.close()
    let closure = closed.wait(timeout: .now() + 1)
    XCTAssertEqual(closure, .success)
    guard closure == .success else { throw POSIXError(.ETIMEDOUT) }

    // One bounded read makes a blocked POLLOUT wait progress. Keep the
    // remainder queued until the writer observes closed delivery.
    var prefix = try output.fileHandleForReading.read(upToCount: 4_096) ?? Data()
    XCTAssertEqual(prefix.count, 4_096)
    guard prefix.count == 4_096 else { throw POSIXError(.EIO) }
    let completion = finished.wait(timeout: .now() + 4)
    XCTAssertEqual(completion, .success)
    joined = completion == .success
    guard joined else { throw POSIXError(.ETIMEDOUT) }
    let runError = errors.take()
    XCTAssertNil(runError)
    if let runError { throw runError }
    try output.fileHandleForWriting.close()
    var observedEOF = false
    for _ in 0..<33 {
        let bytes = try output.fileHandleForReading.read(upToCount: 4_096) ?? Data()
        if bytes.isEmpty { observedEOF = true; break }
        guard prefix.count + bytes.count <= 128 * 1_024 else { throw POSIXError(.E2BIG) }
        prefix.append(bytes)
    }
    XCTAssertTrue(observedEOF, "Bounded prefix collection did not reach ordinary output EOF")
    XCTAssertFalse(prefix.isEmpty)
    XCTAssertEqual(prefix.first, UInt8(123), "Observed bytes were not the native JSON packet prefix")
    XCTAssertNil(prefix.firstIndex(of: 10), "The whole JSON+LF frame fit; this is not a partial-write baseline")
    XCTAssertLessThan(prefix.count, minimumFrame.count)
    guard observedEOF, !prefix.isEmpty, prefix.first == 123,
          prefix.firstIndex(of: 10) == nil, prefix.count < minimumFrame.count else {
        throw POSIXError(.EIO)
    }
    XCTAssertEqual(provider.presentedCount(), 0,
        "didPresent ran despite EOF leaving an incomplete notice-bearing JSON+LF packet")
    withExtendedLifetime((server, provider)) {}
}

private func mcpPartialPacketQueuedBytes(_ descriptor: Int32) throws -> Int {
    var count: CInt = 0
    // Swift cannot import FIONREAD's _IOR macro; use its SDK ioctl encoding.
    let request = UInt(IOC_OUT) | ((UInt(MemoryLayout<CInt>.size) & UInt(IOCPARM_MASK)) << 16)
        | (UInt(0x66) << 8) | 127
    let result = withUnsafeMutablePointer(to: &count) {
        Darwin.ioctl(descriptor, request, UnsafeMutableRawPointer($0))
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard count >= 0, count <= 128 * 1_024 else { throw POSIXError(.E2BIG) }
    return Int(count)
}

private final class MCPPartialPacketNoticeProvider: InteractivePolicyNoticeProviding, @unchecked Sendable {
    private let projectID: String
    private let generation: Int
    private let clientID: String
    private let notices: [CodingAgentPolicyNotice]
    private let text: String
    private let lock = NSLock()
    private var presented = 0
    init(projectID: String, generation: Int, clientID: String, notices: [CodingAgentPolicyNotice], text: String) {
        self.projectID = projectID; self.generation = generation; self.clientID = clientID
        self.notices = notices; self.text = text
    }
    func presentation(deliveryID: String, projectID: String?, projectGeneration: Int?, clientID: String,
                      maximumCount: Int, maximumBytes: Int) -> PolicyNoticePresentation? {
        guard projectID == self.projectID, projectGeneration == generation, clientID == self.clientID,
              notices.count <= maximumCount, text.utf8.count <= maximumBytes else { return nil }
        return PolicyNoticePresentation(id: deliveryID, targetKind: .mcpClient, targetIdentity: clientID,
            notices: notices, text: text, digestSHA256: JSONSupport.sha256Hex(text))
    }
    func didPresent(_ presentation: PolicyNoticePresentation) {
        lock.lock(); presented += 1; lock.unlock()
    }
    func presentedCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return presented
    }
}

extension MCPProtocolAndDiagnosticsTests {
    func testNoticeWriteErrorPreservesEPIPEAndDiscardsReceiptAcrossServeReuse() async throws {
        try await Task.detached(priority: .utility) {
            try mcpCollectNoticeWriteErrorReuseParity()
        }.value
    }
}

private func mcpCollectNoticeWriteErrorReuseParity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mcp-notice-error-reuse-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"), startTelemetry: false)
    let firstInput = Pipe(), firstOutput = Pipe(), secondInput = Pipe(), secondOutput = Pipe()
    let firstFinished = DispatchSemaphore(value: 0), secondFinished = DispatchSemaphore(value: 0)
    let firstErrors = MCPWireErrorBox(), secondErrors = MCPWireErrorBox()
    var firstStarted = false, secondStarted = false, firstJoined = false, secondJoined = false
    defer {
        try? firstInput.fileHandleForWriting.close(); try? secondInput.fileHandleForWriting.close()
        if firstStarted && !firstJoined { firstJoined = firstFinished.wait(timeout: .now() + 4) == .success }
        if secondStarted && !secondJoined { secondJoined = secondFinished.wait(timeout: .now() + 4) == .success }
        for pipe in [firstInput, firstOutput, secondInput, secondOutput] {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
        }
        let complete = app.shutdown().completed
        if (!firstStarted || firstJoined) && (!secondStarted || secondJoined) && complete {
            try? FileManager.default.removeItem(at: root)
        }
    }
    let client = ClientID("notice-write-error-reuse")
    _ = try app.config.update(["allowed_roots": [root.path]], save: false)
    XCTAssertTrue(try app.tools.call(name: "project_memory.initialize",
        arguments: ["project_path": project.path], clientID: client).ok)
    let context = try app.projectContexts.invocationContext(for: client)
    let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
    let notice = CodingAgentPolicyNotice(violationID: PolicyViolationID(), ruleReference: rule.source,
        summary: "Owned write-error receipt fixture", suggestedCorrection: "Preserve EPIPE and discard this receipt", confidence: 1)
    let text = try XCTUnwrap(StjornarvaldPolicyNoticeFormatter.interactivePresentation(notices: [notice]))
    XCTAssertLessThanOrEqual(text.utf8.count, 16 * 1_024)
    let provider = MCPWriteErrorCountingNotice(base: WebEnvelopeScopedNotice(
        projectID: context.projectID.description, generation: Int(context.projectGeneration.rawValue),
        clientID: client.rawValue, notice: notice, text: text))
    let deliveryClosed = DispatchSemaphore(value: 0)
    let server = MCPServer(app: app, clientID: client, role: .primary, maximumConcurrentRequests: 1,
        shutdownWaitSeconds: 3, responseWriteTimeoutSeconds: 1,
        didCloseResponseDeliveryObserver: { deliveryClosed.signal() }, policyNoticeProvider: provider)
    let firstRead = firstInput.fileHandleForReading, firstWrite = firstOutput.fileHandleForWriting
    firstStarted = true
    DispatchQueue(label: "forge.test.notice-write-error", qos: .utility).async {
        do { try server.run(input: firstRead, output: firstWrite) }
        catch { firstErrors.store(error) }
        firstFinished.signal()
    }
    let firstReader = MCPWireResponseReader(handle: firstOutput.fileHandleForReading)
    try firstInput.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": MCPServer.supportedProtocolVersions[0]],
    ]))
    let initialized = try firstReader.read(timeout: 2)
    XCTAssertEqual((initialized["id"] as? NSNumber)?.intValue, 1)
    XCTAssertNil(initialized["error"])
    XCTAssertNotNil(initialized["result"] as? [String: Any])
    guard (initialized["id"] as? NSNumber)?.intValue == 1, initialized["error"] == nil,
          initialized["result"] is [String: Any] else { throw POSIXError(.EIO) }
    // The input remains open until the actual write failure closes delivery.
    // Only this owned pipe's reader is closed; no process signal or global state changes.
    try firstOutput.fileHandleForReading.close()
    try firstInput.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": "job.list", "arguments": [:] as [String: Any]],
    ]))
    let failureClosed = deliveryClosed.wait(timeout: .now() + 2)
    XCTAssertEqual(failureClosed, .success)
    guard failureClosed == .success else { throw POSIXError(.ETIMEDOUT) }
    try firstInput.fileHandleForWriting.close()
    firstJoined = firstFinished.wait(timeout: .now() + 4) == .success
    XCTAssertTrue(firstJoined)
    guard firstJoined else { throw POSIXError(.ETIMEDOUT) }
    let failedWrite = try XCTUnwrap(firstErrors.take())
    let posix = failedWrite as NSError
    XCTAssertEqual(posix.domain, NSPOSIXErrorDomain)
    XCTAssertEqual(posix.code, Int(EPIPE))
    guard posix.domain == NSPOSIXErrorDomain, posix.code == Int(EPIPE) else { throw failedWrite }
    let failedCounts = provider.snapshot()
    XCTAssertEqual(failedCounts.prepared, 1, "A real scoped notice must have been prepared before EPIPE")
    XCTAssertEqual(failedCounts.presented, 0)
    guard failedCounts.prepared == 1, failedCounts.presented == 0 else { throw POSIXError(.EIO) }

    // run() reopens the existing server's admission/delivery boundaries. A ping
    // with the failed tool's same typed ID must not consume a stale presentation.
    let secondRead = secondInput.fileHandleForReading, secondWrite = secondOutput.fileHandleForWriting
    secondStarted = true
    DispatchQueue(label: "forge.test.notice-write-error-reuse", qos: .utility).async {
        do { try server.run(input: secondRead, output: secondWrite) }
        catch { secondErrors.store(error) }
        secondFinished.signal()
    }
    let secondReader = MCPWireResponseReader(handle: secondOutput.fileHandleForReading)
    try secondInput.fileHandleForWriting.write(contentsOf: MCPStdioTransport.encode([
        "jsonrpc": "2.0", "id": 2, "method": "ping",
    ]))
    let pingFrame = try secondReader.readFrameForWebEnvelope(timeout: 2)
    XCTAssertLessThanOrEqual(pingFrame.count, 1_024)
    XCTAssertEqual(pingFrame.last, UInt8(10))
    XCTAssertEqual(pingFrame.filter { $0 == 10 }.count, 1)
    let ping = try JSONSupport.object(from: Data(pingFrame.dropLast()))
    XCTAssertEqual((ping["id"] as? NSNumber)?.intValue, 2)
    XCTAssertNil(ping["error"])
    XCTAssertNotNil(ping["result"] as? [String: Any])
    guard pingFrame.count <= 1_024, pingFrame.last == 10,
          pingFrame.filter({ $0 == 10 }).count == 1,
          (ping["id"] as? NSNumber)?.intValue == 2, ping["error"] == nil,
          ping["result"] is [String: Any] else { throw POSIXError(.EIO) }
    try secondInput.fileHandleForWriting.close()
    secondJoined = secondFinished.wait(timeout: .now() + 4) == .success
    XCTAssertTrue(secondJoined)
    guard secondJoined else { throw POSIXError(.ETIMEDOUT) }
    let reuseError = secondErrors.take()
    XCTAssertNil(reuseError)
    if let reuseError { throw reuseError }
    try secondOutput.fileHandleForWriting.close()
    let trailing = try secondOutput.fileHandleForReading.read(upToCount: 1)
    XCTAssertTrue(trailing?.isEmpty ?? true, "Unexpected bytes followed the complete reuse ping frame")
    guard trailing?.isEmpty ?? true else { throw POSIXError(.EIO) }
    let reusedCounts = provider.snapshot()
    XCTAssertEqual(reusedCounts.prepared, 1, "The ping must not prepare another tool notice")
    XCTAssertEqual(reusedCounts.presented, 0,
        "A stale write-error presentation was acknowledged by the later successful same-ID ping")
    withExtendedLifetime((server, provider, firstReader, secondReader)) {}
}

private final class MCPWriteErrorCountingNotice: InteractivePolicyNoticeProviding, @unchecked Sendable {
    private let base: WebEnvelopeScopedNotice
    private let lock = NSLock()
    private var prepared = 0
    private var presented = 0
    init(base: WebEnvelopeScopedNotice) { self.base = base }
    func presentation(deliveryID: String, projectID: String?, projectGeneration: Int?, clientID: String,
                      maximumCount: Int, maximumBytes: Int) -> PolicyNoticePresentation? {
        guard let result = base.presentation(deliveryID: deliveryID, projectID: projectID,
            projectGeneration: projectGeneration, clientID: clientID,
            maximumCount: maximumCount, maximumBytes: maximumBytes) else { return nil }
        lock.lock(); prepared += 1; lock.unlock()
        return result
    }
    func didPresent(_ presentation: PolicyNoticePresentation) {
        lock.lock(); presented += 1; lock.unlock()
    }
    func snapshot() -> (prepared: Int, presented: Int) {
        lock.lock(); defer { lock.unlock() }; return (prepared, presented)
    }
}
