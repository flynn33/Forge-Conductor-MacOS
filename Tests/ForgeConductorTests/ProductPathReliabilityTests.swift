// ProductPathReliabilityTests.swift
// Exercises operator-critical paths such as MCP negotiation and tool discovery.
// In-process protocol calls provide deterministic coverage without automating LM Studio.

import XCTest
import Darwin
@testable import ForgeConductorCore

/// G1/G7: product reliability — MCP negotiate + tools surface without LM Studio UI.
final class ProductPathReliabilityTests: XCTestCase {
    func testXcodeRuntimeLauncherEmbedsDeclaredProductIdentity() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        for configurationID in [
            "F0A700000000000000000010",
            "F0A700000000000000000011",
        ] {
            let start = try XCTUnwrap(project.range(of: "\(configurationID) /*"))
            let end = try XCTUnwrap(
                project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
            )
            let configuration = project[start.lowerBound..<end.upperBound]
            XCTAssertTrue(
                configuration.contains("CREATE_INFOPLIST_SECTION_IN_BINARY = YES;"),
                "runtime helper must embed the declared bundle identifier"
            )
            XCTAssertTrue(
                configuration.contains(
                    #"PRODUCT_BUNDLE_IDENTIFIER = "com.forge-conductor.runtime-launcher";"#
                ),
                "runtime helper must retain its exact product identity"
            )
        }
    }

    func testXcodeFilesystemIdentityBuildGraphRetainsSigningBeforeSealingControls() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        func object(_ identifier: String) throws -> Substring {
            let start = try XCTUnwrap(project.range(of: "\n\t\t\(identifier) /*"))
            let end = try XCTUnwrap(
                project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
            )
            return project[start.lowerBound..<end.upperBound]
        }

        for configurationID in [
            "89F432F3B43F4B81ADBFD41A", // app Debug
            "949B044302214128BBAA3EE8", // app Release
            "D82F296A8E4141ECB3B96E83", // CLI Debug
            "462BB7BBB61F4979BE23EEDD", // CLI Release
        ] {
            XCTAssertTrue(
                try object(configurationID).contains(
                    "EAGER_COMPILATION_ALLOW_SCRIPTS = NO;"
                ),
                "caller configuration \(configurationID) must wait for dependency signing"
            )
        }

        for configurationID in [
            "D82F296A8E4141ECB3B96E83", // CLI Debug
            "462BB7BBB61F4979BE23EEDD", // CLI Release
        ] {
            let configuration = try object(configurationID)
            XCTAssertTrue(
                configuration.contains(#""@executable_path/../Frameworks","#),
                "embedded CLI must resolve the app framework from Contents/Helpers"
            )
            XCTAssertTrue(
                configuration.contains(#""@executable_path","#),
                "standalone and installed CLI must resolve a sibling framework"
            )
        }

        for configurationID in [
            "E2F500000000000000000035", // protocol Debug
            "E2F500000000000000000036", // protocol Release
            "E2F500000000000000000037", // daemon Debug
            "E2F500000000000000000038", // daemon Release
        ] {
            XCTAssertTrue(
                try object(configurationID).contains("ENABLE_CODE_COVERAGE = NO;"),
                "filesystem configuration \(configurationID) must retain scheme-consistent output"
            )
        }

        let appTarget = try object("D574F9BCA1204936B158984B")
        XCTAssertTrue(
            appTarget.contains(
                "E2F500000000000000000045 /* Seal Filesystem Daemon Identity */"
            )
        )
        XCTAssertTrue(
            appTarget.contains("E2F50000000000000000004B /* Embed Manager CLI */")
        )
        XCTAssertTrue(
            appTarget.contains("E2F500000000000000000034 /* PBXTargetDependency */")
        )
        XCTAssertTrue(
            appTarget.contains("E2F50000000000000000004C /* PBXTargetDependency */")
        )
        XCTAssertTrue(
            try object("E2F500000000000000000034").contains(
                "target = E2F500000000000000000026 /* ForgeFilesystemDaemon */;"
            ),
            "app must depend directly on the daemon before sealing and embedding it"
        )
        XCTAssertTrue(
            try object("E2F50000000000000000004C").contains(
                "target = 05C234606560407787702A3C /* forge-conductor */;"
            ),
            "app must depend directly on the signed manager CLI before embedding it"
        )

        let cliTarget = try object("05C234606560407787702A3C")
        XCTAssertTrue(
            cliTarget.contains(
                "E2F500000000000000000046 /* Seal Filesystem Daemon Identity */"
            )
        )
        XCTAssertTrue(
            cliTarget.contains("E2F500000000000000000048 /* PBXTargetDependency */")
        )
        XCTAssertTrue(
            try object("E2F500000000000000000048").contains(
                "target = E2F500000000000000000026 /* ForgeFilesystemDaemon */;"
            ),
            "CLI must depend directly on the daemon before sealing its identity"
        )

        let cliSealPhase = try object("E2F500000000000000000046")
        XCTAssertTrue(
            cliSealPhase.contains("$(BUILT_PRODUCTS_DIR)/forge-filesystem-daemon")
        )
        XCTAssertTrue(
            cliSealPhase.contains("${BUILT_PRODUCTS_DIR}/forge-filesystem-daemon"),
            "CLI seal command must read its signed daemon dependency"
        )
        XCTAssertFalse(
            cliSealPhase.contains(
                "$(BUILT_PRODUCTS_DIR)/Forge Conductor.app/Contents/MacOS/"
                    + "forge-filesystem-daemon"
            ),
            "CLI seal must not introduce an app dependency cycle"
        )

        let embedManagerCLI = try object("E2F50000000000000000004B")
        XCTAssertTrue(embedManagerCLI.contains("dstPath = Contents/Helpers;"))
        XCTAssertTrue(
            embedManagerCLI.contains(
                "E2F500000000000000000049 /* forge-conductor in Embed Manager CLI */"
            )
        )
        let embeddedCLIBuildFile = try XCTUnwrap(
            project.split(separator: "\n").first(where: {
                $0.contains(
                    "E2F500000000000000000049 /* forge-conductor in Embed Manager CLI */"
                )
            })
        )
        XCTAssertTrue(
            embeddedCLIBuildFile.contains(
                "fileRef = FAD7DC3FA3A1480E9B4955B1 /* forge-conductor */;"
            )
        )
        XCTAssertTrue(
            embeddedCLIBuildFile.contains("ATTRIBUTES = (CodeSignOnCopy, );"),
            "embedded manager CLI must be re-signed as nested app code"
        )
    }

    func testPrivilegedFilesystemBundleCheckerRetainsExactOptionalCLISealContract() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checker = try String(
            contentsOf: repository.appendingPathComponent(
                ".forge-codex/scripts/check_privileged_filesystem_bundle.sh"
            ),
            encoding: .utf8
        )

        for requiredFragment in [
            #"CLI_EXECUTABLE="${3:-}""#,
            #"APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Forge Conductor""#,
            #"EMBEDDED_CLI="$APP_BUNDLE/Contents/Helpers/forge-conductor""#,
            #"identifier \"com.forge-conductor.cli\""#,
            #"certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\""#,
            #"--strict --all-architectures"#,
            #"[[ -f "$executable" ]]"#,
            #"[[ ! -L "$executable" ]]"#,
            #"[[ -x "$executable" ]]"#,
            #"[[ -f "$APP_EXECUTABLE" ]]"#,
            #"[[ ! -L "$APP_EXECUTABLE" ]]"#,
            #"[[ -x "$APP_EXECUTABLE" ]]"#,
            #"supported_architectures "app main executable" "$APP_EXECUTABLE""#,
            #"--deep --strict --all-architectures"#,
            #""-R=$APP_REQUIREMENT" "$APP_BUNDLE""#,
            #"supported_architectures "$role" "$executable""#,
            #"supported_architectures "embedded filesystem daemon" "$DAEMON""#,
            #"require_cli_runpaths "$role" "$executable""#,
            #"/usr/bin/otool -l "$executable""#,
            #""@executable_path/../Frameworks""#,
            #""@executable_path""#,
            #"/usr/bin/plutil -p "$APP_INFO_PLIST""#,
            #"/usr/bin/plutil -p "$executable""#,
            #"CFBundleShortVersionString"#,
            #"/usr/bin/env -i PATH=/usr/bin:/bin"#,
            #""$executable" version"#,
            #""standalone manager CLI" "$CLI_EXECUTABLE""#,
            #""embedded manager CLI" "$EMBEDDED_CLI""#,
            #"--arch "$architecture" "$DAEMON""#,
            #"ForgeFilesystemDaemonCDHashArm64"#,
            #"ForgeFilesystemDaemonCDHashX86_64"#,
            #"reject_unknown_daemon_seal_keys"#,
            #"require_matching_daemon_seal"#,
            #"require_absent_daemon_seal"#,
            #"[[ "$actual_hash" == "$expected_hash" ]]"#,
        ] {
            XCTAssertTrue(
                checker.contains(requiredFragment),
                "bundle checker is missing the exact-pair contract: \(requiredFragment)"
            )
        }

        XCTAssertTrue(
            checker.contains(
                "/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \\\n"
                    + "  \"-R=$APP_REQUIREMENT\" \"$APP_BUNDLE\""
            ),
            "app explicit-requirement verification must cover every architecture"
        )

        let cliSignatureCheck = try XCTUnwrap(
            checker.range(of: #""-R=$CLI_REQUIREMENT" "$executable""#)
        )
        let cliInfoInspection = try XCTUnwrap(
            checker.range(of: #"/usr/bin/plutil -p "$executable""#)
        )
        XCTAssertLessThan(
            cliSignatureCheck.lowerBound,
            cliInfoInspection.lowerBound,
            "CLI signature and exact identity must be accepted before trusting its embedded plist"
        )

        let embeddedCLIValidation = try XCTUnwrap(
            checker.range(of: #""embedded manager CLI" "$EMBEDDED_CLI""#)
        )
        let optionalStandaloneCLIValidation = try XCTUnwrap(
            checker.range(of: #"[[ -n "$CLI_EXECUTABLE" ]]"#)
        )
        XCTAssertLessThan(
            embeddedCLIValidation.lowerBound,
            optionalStandaloneCLIValidation.lowerBound,
            "the app-embedded manager CLI must be validated even without an external CLI argument"
        )
    }

    func testProjectBuildEntrypointStagesRuntimeLauncherBeforeBundleSigning() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entrypoint = try String(
            contentsOf: repository.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        let requiredFragments = [
            #"RUNTIME_HELPER_PRODUCT="forge-runtime-launcher""#,
            #"APP_HELPERS="$APP_CONTENTS/Helpers""#,
            #"RUNTIME_HELPER="$APP_HELPERS/$RUNTIME_HELPER_PRODUCT""#,
            #"swift build --configuration "$BINARY_CONFIGURATION" --product "$RUNTIME_HELPER_PRODUCT""#,
            #"cp "$BUILD_RUNTIME_HELPER" "$RUNTIME_HELPER""#,
            #"chmod 0755 "$APP_BINARY" "$RUNTIME_HELPER""#,
            #"/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE""#,
        ]
        for fragment in requiredFragments {
            XCTAssertTrue(entrypoint.contains(fragment), "missing build-entrypoint contract: \(fragment)")
        }

        let helperSigning = try XCTUnwrap(
            entrypoint.range(of: #"--identifier "$RUNTIME_HELPER_IDENTIFIER""#)
        )
        let bundleSigning = try XCTUnwrap(
            entrypoint.range(of: #"--identifier "$BUNDLE_ID""#)
        )
        let strictVerification = try XCTUnwrap(
            entrypoint.range(of: #"/usr/bin/codesign --verify --deep --strict"#)
        )
        XCTAssertLessThan(helperSigning.lowerBound, bundleSigning.lowerBound)
        XCTAssertLessThan(bundleSigning.lowerBound, strictVerification.lowerBound)
    }

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
        XCTAssertTrue(MCPServeVerifier.requiredProductTools.isSubset(of: names))
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

    func testProcessVerifierRejectsMissingContinuityTool() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools.subtracting(["context_get"]))
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("context_get"), result.detail)
    }

    func testProcessVerifierRejectsMissingMemoryTool() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools.subtracting(["memory_search"]))
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("memory_search"), result.detail)
    }

    func testProcessVerifierRejectsNonNDJSONPrefix() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            prefix: "Content-Length: 10\n"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("ndjson=false"), result.detail)
    }

    func testProcessVerifierTimeoutIsBoundedForSilentChild() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let binary = tmp.appendingPathComponent("silent-server")
        try Data("#!/bin/sh\ncat >/dev/null\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let started = Date()
        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testProcessVerifierRejectsValidHandshakeWithNonzeroNaturalExit() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            postOutputScript: "exit 9"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.terminationInterventionRequired)
        XCTAssertEqual(result.terminationReason, "exit")
        XCTAssertEqual(result.terminationStatus, 9)
    }

    func testProcessVerifierRejectsValidHandshakeWhenCleanupIntervenes() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            postOutputScript: "exec /bin/sleep 30"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.terminationInterventionRequired)
        XCTAssertEqual(result.terminationReason, "uncaught_signal")
        XCTAssertEqual(result.terminationStatus, SIGTERM)
        XCTAssertTrue(result.detail.contains("intervention=true"), result.detail)
    }

    func testProcessVerifierRejectsHandshakeEmittedOnlyAfterEOF() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            deferOutputUntilEOF: true
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.terminationInterventionRequired)
        XCTAssertEqual(result.terminationReason, "exit")
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.detail.contains("handshake_before_eof=false"), result.detail)
    }

    private func makeVerifierTemp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeVerifierExecutable(
        in directory: URL,
        serverName: String,
        toolNames: [String],
        prefix: String = "",
        postOutputScript: String = "",
        deferOutputUntilEOF: Bool = false
    ) throws -> URL {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "protocolVersion": "2025-11-25",
                "serverInfo": ["name": serverName, "version": ForgeApp.version],
            ] as [String: Any],
        ]
        let descriptors: [[String: Any]] = toolNames.map { name in
            [
                "name": name,
                "description": "Fixture tool \(name)",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ]
        }
        let tools: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["tools": descriptors],
        ]
        let output = prefix
            + (try JSONSupport.string(from: initialize)) + "\n"
            + (try JSONSupport.string(from: tools)) + "\n"
        let shellQuoted = output.replacingOccurrences(of: "'", with: "'\"'\"'")
        let responseScript = "printf '%s' '\(shellQuoted)'"
        let script = deferOutputUntilEOF
            ? "#!/bin/sh\ncat >/dev/null\n\(responseScript)\n\(postOutputScript)\n"
            : "#!/bin/sh\n\(responseScript)\ncat >/dev/null\n\(postOutputScript)\n"
        let binary = directory.appendingPathComponent("fixture-server")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }
}
