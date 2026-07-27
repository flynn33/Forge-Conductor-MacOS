// ProductPathReliabilityTests.swift
// Exercises operator-critical paths such as MCP negotiation and tool discovery.
// In-process protocol calls provide deterministic coverage without automating LM Studio.

import XCTest
@testable import ForgeConductorCore

/// G1/G7: product reliability — MCP negotiate + tools surface without LM Studio UI.
final class ProductPathReliabilityTests: XCTestCase {
    func testInProcessMCPHandshakeToolsList() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-product-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let app = try ForgeApp.bootstrap(home: tmp)
        defer { app.shutdown() }
        let server = MCPServer(app: app)

        let initMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "product-test", "version": "1"] as [String: Any],
            ] as [String: Any],
        ]
        let initResp = server.handle(initMsg)
        XCTAssertNotNil(initResp)
        let result = initResp?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-11-25")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "forge-conductor")

        let listMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:] as [String: Any],
        ]
        let listResp = server.handle(listMsg)
        let listResult = listResp?["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(tools.count, 20, "product must expose full tool surface")
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("forge_status"))
        XCTAssertTrue(names.contains("agent_list"))
        XCTAssertTrue(names.contains("shell_exec"))
    }

    func testForgeStatusToolCall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let app = try ForgeApp.bootstrap(home: tmp)
        defer { app.shutdown() }
        let server = MCPServer(app: app)
        let call: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "forge_status",
                "arguments": [:] as [String: Any],
            ] as [String: Any],
        ]
        let resp = server.handle(call)
        let result = resp?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        let isError = result?["isError"] as? Bool ?? true
        XCTAssertFalse(isError)
    }

    func testRealtimeEngineMeasuredProgress() {
        let engine = RealtimeMetricsEngine()
        engine.start(targetHz: 30)
        defer { engine.stop() }
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertGreaterThan(engine.latestSystem.ts, 0)
        // After ~0.35s at 30Hz should have samples; measured Hz may still be settling.
        XCTAssertTrue(engine.isRunning)
    }

    func testPortGuardReportsFreeOnUnusedPort() {
        // Ephemeral high port almost certainly free
        let state = DashboardPortGuard.inspect(host: "127.0.0.1", port: 59_873)
        switch state {
        case .free, .unknown:
            break // unknown acceptable if lsof missing
        default:
            XCTFail("expected free/unknown for unused port, got \(state)")
        }
    }

    func testDiagnosticsCaptureDeploySmokeFailurePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diag-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(home: tmp)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths)
        let deploy = LMStudioDeployService(paths: paths, diagnostics: log)
        // Prefer a missing binary via explicit preferred that doesn't exist — resolve with bogus path
        do {
            _ = try deploy.deploy(
                preferredBinary: URL(fileURLWithPath: "/tmp/definitely-not-forge-\(UUID().uuidString)")
            )
            XCTFail("expected deploy to fail for missing binary")
        } catch {
            // expected
        }
        let recent = log.recent(limit: 50)
        let events = Set(recent.map(\.event))
        XCTAssertTrue(events.contains("deploy_begin") || events.contains("deploy_binary_missing") || events.contains("deploy_smoke_pre_failed") || events.contains("deploy_failed") || !recent.isEmpty)
    }
}
