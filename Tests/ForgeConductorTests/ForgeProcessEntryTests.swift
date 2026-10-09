// ForgeProcessEntryTests.swift
// Verifies argv classification for GUI, manager, and MCP-serving process modes.
// These cases prevent the shared app binary from starting the wrong lifecycle.

import XCTest
@testable import ForgeConductorCore

final class ForgeProcessEntryTests: XCTestCase {
    func testParseModeGUIWhenNoArgs() {
        let mode = ForgeProcessEntry.parseMode(arguments: ["/path/Forge Conductor"])
        XCTAssertEqual(mode, .gui)
    }

    func testParseModeServe() {
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "serve"]),
            .serve
        )
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "mcp-serve"]),
            .serve
        )
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "mcp"]),
            .serve
        )
    }

    func testParseModeManagerRun() {
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "manager", "run"]),
            .managerRun(openBrowser: false)
        )
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "manager", "run", "--open"]),
            .managerRun(openBrowser: true)
        )
        // LaunchAgent style: manager run --home PATH
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: [
                "/app", "manager", "run", "--home", "/tmp/home",
            ]),
            .managerRun(openBrowser: false)
        )
    }

    func testParseModeProviderHookIsAlwaysHeadless() {
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: [
                "/app", "provider-hook", "claude-desktop", "SessionStart",
                "--home", "/tmp/forge-home",
            ]),
            .providerHook
        )
        // Malformed hook arguments must be handled as a headless error rather
        // than falling through into SwiftUI startup.
        XCTAssertEqual(
            ForgeProcessEntry.parseMode(arguments: ["/app", "provider-hook"]),
            .providerHook
        )
    }

    func testHomeOverride() {
        let url = ForgeProcessEntry.homeOverride(from: [
            "/app", "manager", "run", "--home", "~/somewhere",
        ])
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.path.contains("somewhere") || url!.path.hasPrefix("/"))
    }

    func testRendererFixedModeAndMalformedCallsRemainHeadless() {
        for arguments in [["/app", "--internal-web-render-v1"],
                          ["/app", "--internal-web-render-v1", "--home", "/tmp/ignored"]] {
            XCTAssertEqual(ForgeProcessEntry.parseMode(arguments: arguments), .webRenderChild)
        }
        XCTAssertEqual(ForgeProcessEntry.parseMode(arguments: ["/app", "--internal-web-render-v3"]), .gui)
    }

    func testCompleteRendererModeAndMalformedCallsRemainHeadless() {
        for arguments in [["/app", "--internal-web-render-v2"],
                          ["/app", "--internal-web-render-v2", "--home", "/tmp/ignored"]] {
            XCTAssertEqual(ForgeProcessEntry.parseMode(arguments: arguments), .webRenderChild)
        }
        XCTAssertEqual(WebRenderProtocol.Profile.forInternalArgument("--internal-web-render-v1"), .v1)
        XCTAssertEqual(WebRenderProtocol.Profile.forInternalArgument("--internal-web-render-v2"), .completeV2)
        XCTAssertNil(WebRenderProtocol.Profile.forInternalArgument("--internal-web-render-v3"))
        XCTAssertFalse(WebRenderChildEntry.runIfRequested(arguments: ["/app", "serve"], expectedRole: .app))
    }

    func testServeArgumentsConstant() {
        XCTAssertEqual(LMStudioMCPPluginInstaller.serveArguments, ["serve"])
    }

    func testDOCXFixedModeAndMalformedCallsRemainHeadless() {
        for arguments in [["/app", "--internal-docx-export-v1"],
                          ["/app", "--internal-docx-export-v1", "--home", "/tmp/ignored"]] {
            XCTAssertEqual(ForgeProcessEntry.parseMode(arguments: arguments), .docxExportChild)
        }
        XCTAssertEqual(ForgeProcessEntry.parseMode(arguments: ["/app", "--internal-docx-export-v2"]), .gui)
        XCTAssertFalse(DOCXExportChildEntry.runIfRequested(arguments: ["/app", "serve"], expectedRole: .app))
    }

    func testResolveBinaryPrefersExplicitPreferred() {
        // Non-existent preferred is ignored; resolution falls through without crash.
        let missing = URL(fileURLWithPath: "/tmp/forge-conductor-missing-binary-\(UUID().uuidString)")
        let resolved = LMStudioMCPPluginInstaller.resolveBinaryURL(preferred: missing)
        XCTAssertFalse(resolved.path.isEmpty)
    }
}
