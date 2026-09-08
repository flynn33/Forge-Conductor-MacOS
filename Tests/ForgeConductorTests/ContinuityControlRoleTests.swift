import XCTest
@testable import ForgeConductorCore

final class ContinuityControlRoleTests: XCTestCase {
    private var controls: Set<String> { Set(ContinuityControlToolName.allCases.map(\.rawValue)) }

    func testCLUDiscoveryIsExactlyFourCanonicalDefinitionsAndOtherRolesRetainLegacyTools() throws {
        try withApp { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            for role in LMStudioConnectorRole.allCases {
                let server = MCPServer(app: app, role: role)
                let response = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
                let result = try XCTUnwrap(response["result"] as? [String: Any])
                let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])
                let names = Set(descriptors.compactMap { $0["name"] as? String })
                XCTAssertEqual(names, role == .clu ? controls : Set(app.tools.toolNames))
                XCTAssertEqual(descriptors.count, names.count)
                for descriptor in descriptors {
                    let name = try XCTUnwrap(descriptor["name"] as? String)
                    let expected = try XCTUnwrap(catalog.definition(named: name))
                    let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
                    XCTAssertEqual(try JSONSupport.data(from: schema), expected.inputSchemaJSON)
                    XCTAssertEqual(descriptor["description"] as? String, expected.description)
                }
                if role != .clu {
                    XCTAssertTrue(names.isSuperset(of: ["context_get", "session_handoff", "fs_read", "shell_exec"]))
                }
            }
        }
    }

    func testCLURoleRejectsEveryNonControlDirectCallBeforeDispatch() throws {
        try withApp { app in
            let server = MCPServer(app: app, role: .clu)
            let denied = Set(app.tools.toolNames).subtracting(controls).union([
                "clu.session.start", "operator.budget.increase", "provider.secret", "unknown_future_tool",
            ])
            XCTAssertFalse(denied.isEmpty)
            for name in denied.sorted() {
                let result = try invoke(server, name: name, arguments: ["key": "role-marker", "body": "forbidden"])
                XCTAssertEqual(result.payload["code"] as? String, "tool_not_allowed", name)
                XCTAssertEqual(result.envelope["isError"] as? Bool, true, name)
                XCTAssertFalse(MCPToolAccessPolicy.permits(name, role: .clu), name)
            }
            XCTAssertEqual(MCPToolAccessPolicy.toolNames(app.tools.toolNames, role: .clu).sorted(), controls.sorted())
            XCTAssertEqual(MCPToolAccessPolicy.toolNames(app.tools.toolNames, role: .primary), app.tools.toolNames)
            XCTAssertEqual(MCPToolAccessPolicy.toolNames(app.tools.toolNames, role: .fallback), app.tools.toolNames)
        }
    }

    func testEverySharedRoleReturnsTaskIdentityUnavailableWithoutInventingAuthority() throws {
        try withApp { app in
            for role in LMStudioConnectorRole.allCases {
                let server = MCPServer(app: app, clientID: ClientID("shared-role-client"), role: role)
                for (name, arguments) in [
                    ("clu_start_handoff", ["continuity_id": "exact-source"]),
                    ("clu_status", ["operation_id": UUID().uuidString]),
                    ("clu_cancel", ["operation_id": UUID().uuidString]),
                ] {
                    let response = try invoke(server, name: name, arguments: arguments)
                    XCTAssertEqual(response.payload["code"] as? String, "task_identity_unavailable")
                    XCTAssertEqual(response.envelope["isError"] as? Bool, true)
                    XCTAssertNil(response.payload["operation_id"])
                }
            }
            XCTAssertTrue(try app.store.pendingContinuityHandoffs().isEmpty)
            XCTAssertTrue(try app.store.handoffListAll().isEmpty)
        }
    }

    func testCLUWireRejectsMalformedArgumentsAndUnknownDeadlineBeforeIdentityFallback() throws {
        try withApp { app in
            let server = MCPServer(app: app, role: .clu)
            let nonObjects: [Any] = [NSNull(), [String](), "arguments", 1, true]
            for value in nonObjects {
                for name in controls {
                    let response = try invoke(server, name: name, arguments: value)
                    XCTAssertEqual(response.payload["code"] as? String, "invalid_request", name)
                    XCTAssertEqual(response.payload["field"] as? String, "arguments")
                }
            }
            let unknownDeadlines: [Any] = [true, "10", 10, 0, NSNull(), 1.5]
            for value in unknownDeadlines {
                let response = try invoke(server, name: "clu_start_handoff",
                    arguments: ["continuity_id": "source", "deadline_ms": value])
                XCTAssertEqual(response.payload["code"] as? String, "invalid_request")
                XCTAssertEqual(response.payload["field"] as? String, "arguments")
            }
            let response = try invoke(server, name: "clu_start_handoff",
                arguments: ["continuity_id": "source", "task_id": UUID().uuidString])
            XCTAssertEqual(response.payload["code"] as? String, "invalid_request")
        }
    }

    func testCapabilitiesReportObservedHandshakeRoleAndUnavailableNativeTask() throws {
        try withApp { app in
            for role in LMStudioConnectorRole.allCases {
                let server = MCPServer(app: app, role: role)
                let before = try invoke(server, name: "clu_capabilities", arguments: [:] as [String: Any]).payload
                XCTAssertEqual(before["connected"] as? Bool, false)
                let initialized = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 3, "method": "initialize",
                    "params": ["protocolVersion": "2025-11-25"]]))
                let result = try XCTUnwrap(initialized["result"] as? [String: Any])
                XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, role.serverID)
                let after = try invoke(server, name: "clu_capabilities", arguments: [:] as [String: Any]).payload
                XCTAssertEqual(after["connected"] as? Bool, true)
                XCTAssertEqual(after["role"] as? String, role.rawValue)
                XCTAssertEqual(after["build_version"] as? String, ForgeApp.version)
                XCTAssertEqual(after["ready"] as? Bool, false)
                XCTAssertEqual(after["task_identity"] as? String, "unavailable")
                XCTAssertTrue(after["deployed"] is NSNull)
                XCTAssertTrue(after["automatic_handoff_enabled"] is NSNull)
                XCTAssertTrue(after["deployment_id"] is NSNull)
                XCTAssertEqual((after["qualification"] as? [String: String])?["desktop_new_chat"], "not_observed")
            }
        }
    }

    func testRoleIdentityAndHealthDistinguishCLUFromTheLegacyFailoverPair() {
        XCTAssertEqual(LMStudioConnectorRole(environmentValue: " clu "), .clu)
        XCTAssertEqual(LMStudioConnectorRole.clu.serverID, "forge-conductor-clu")
        XCTAssertEqual(LMStudioConnectorRole.clu.hostKind, "mcp-stdio-clu")
        XCTAssertEqual(Set(LMStudioConnectorRole.allCases.map(\.serverID)).count, 3)
        let environment = LMStudioEnvironment.hostEnvironment(role: .clu, deploymentID: "role-revision")
        XCTAssertEqual(environment["FORGE_MCP_ROLE"], "clu")
        XCTAssertEqual(environment["FORGE_DEPLOYMENT_ID"], "role-revision")
        let pair = [health(.primary, ready: true), health(.fallback, ready: true)]
        XCTAssertEqual(LMStudioConnectionHealth(roles: pair).state, .ready)
        let missingCLU = LMStudioConnectionHealth(roles: pair + [health(.clu, ready: false)])
        XCTAssertEqual(missingCLU.state, .continuityUnavailable)
        XCTAssertFalse(missingCLU.isStable); XCTAssertTrue(missingCLU.hasService)
        XCTAssertTrue(LMStudioConnectionHealth(roles: pair + [health(.clu, ready: true)]).isStable)
        XCTAssertEqual(LMStudioConnectionHealth(roles: [health(.clu, ready: true)]).state, .unavailable)
        XCTAssertEqual(LMStudioConnectionHealth(roles: [health(.primary, ready: false),
            health(.fallback, ready: true), health(.clu, ready: true)]).state, .fallbackPromoted)
        let activation = LMStudioHostActivationResult(deploymentID: "role-revision", runningBeforeDeploy: true,
            launched: false, restarted: false, configurationSynced: true, readyRoles: ["primary", "fallback"], detail: "fixture")
        XCTAssertTrue(activation.isReady)
        XCTAssertFalse(activation.allRolesConnected)
    }

    func testVerifierAcceptsExactFourToolCLUHandshakeBelowGeneralMinimum() throws {
        try withDirectory { directory in
            let binary = try verifierBinary(directory: directory, serverName: LMStudioConnectorRole.clu.serverID,
                names: controls.sorted())
            let result = try MCPServeVerifier.verify(binary: binary, home: directory.appendingPathComponent("home"), role: "clu", timeoutSec: 1)
            XCTAssertTrue(result.ok, result.detail)
            XCTAssertEqual(result.toolCount, 4)
            XCTAssertLessThan(result.toolCount, MCPServeVerifier.minimumToolCount)
            XCTAssertEqual(Set(result.toolNames), controls)
            XCTAssertFalse(result.terminationInterventionRequired)
            XCTAssertEqual(result.terminationStatus, 0)
        }
    }

    func testVerifierRejectsMissingExtraDuplicateToolsAndWrongCLURoleIdentity() throws {
        let cases: [(String, [String])] = [
            (LMStudioConnectorRole.clu.serverID, controls.subtracting(["clu_cancel"]).sorted()),
            (LMStudioConnectorRole.clu.serverID, controls.sorted() + ["fs_read"]),
            (LMStudioConnectorRole.clu.serverID, controls.sorted() + ["clu_cancel"]),
            (LMStudioConnectorRole.primary.serverID, controls.sorted()),
        ]
        for (serverName, names) in cases {
            try withDirectory { directory in
                let binary = try verifierBinary(directory: directory, serverName: serverName, names: names)
                let result = try MCPServeVerifier.verify(binary: binary, home: directory.appendingPathComponent("home"), role: "clu", timeoutSec: 1)
                XCTAssertFalse(result.ok, result.detail)
                XCTAssertFalse(result.terminationInterventionRequired)
            }
        }
    }

    func testInstallerCommitsAndVerifiesAllThreeRolesWithOneDeploymentRevision() throws {
        try withInstaller { _, binary in
            let result = try LMStudioMCPPluginInstaller.install(preferredBinary: binary)
            XCTAssertTrue(result.ok)
            XCTAssertEqual(Set(result.pluginsWritten), Set(LMStudioConnectorRole.allCases.map(\.serverID)))
            for role in LMStudioConnectorRole.allCases {
                XCTAssertTrue(LMStudioMCPPluginInstaller.isPluginInstalled(name: role.serverID,
                    expectedBinary: binary, expectedDeploymentID: result.deploymentID), role.rawValue)
            }
            let status = LMStudioMCPPluginInstaller.status(preferredBinary: binary)
            XCTAssertTrue(status.isFullyInstalled, status.detail)
            XCTAssertEqual(status.continuityPluginInstalled, true)
            let unchanged = try LMStudioMCPPluginInstaller.ensureConnection(preferredBinary: binary)
            XCTAssertEqual(unchanged.deploymentID, result.deploymentID)
            XCTAssertEqual(Set(unchanged.pluginsWritten), Set(result.pluginsWritten))
            XCTAssertFalse(LMStudioMCPPluginInstaller.isPluginInstalled(name: "unknown-plugin", expectedBinary: binary))
        }
    }

    func testMissingCLUBridgeOrMismatchedRegistrationCannotReportFullyInstalledAndRepairs() throws {
        try withInstaller { _, binary in
            let original = try LMStudioMCPPluginInstaller.install(preferredBinary: binary)
            try FileManager.default.removeItem(at: LMStudioMCPPluginInstaller.continuityPluginDirectory)
            let missing = LMStudioMCPPluginInstaller.status(preferredBinary: binary)
            XCTAssertTrue(missing.primaryPluginInstalled); XCTAssertTrue(missing.fallbackPluginInstalled)
            XCTAssertEqual(missing.continuityPluginInstalled, false)
            XCTAssertFalse(missing.isFullyInstalled)
            let repaired = try LMStudioMCPPluginInstaller.ensureConnection(preferredBinary: binary)
            XCTAssertNotEqual(repaired.deploymentID, original.deploymentID)
            XCTAssertTrue(LMStudioMCPPluginInstaller.status(preferredBinary: binary).isFullyInstalled)
            var config = try JSONSupport.object(from: Data(contentsOf: LMStudioEnvironment.mcpConfigURL))
            var servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
            var clu = try XCTUnwrap(servers[LMStudioConnectorRole.clu.serverID] as? [String: Any])
            var environment = try XCTUnwrap(clu["env"] as? [String: String])
            environment["FORGE_DEPLOYMENT_ID"] = "foreign-revision"
            clu["env"] = environment; servers[LMStudioConnectorRole.clu.serverID] = clu; config["mcpServers"] = servers
            try JSONSupport.data(from: config).write(to: LMStudioEnvironment.mcpConfigURL)
            XCTAssertFalse(LMStudioMCPPluginInstaller.status(preferredBinary: binary).isFullyInstalled)
            _ = try LMStudioMCPPluginInstaller.ensureConnection(preferredBinary: binary)
            XCTAssertTrue(LMStudioMCPPluginInstaller.status(preferredBinary: binary).isFullyInstalled)
        }
    }

    func testSelectiveUninstallRemovesCLUAndPreservesForeignPluginAndRegistration() throws {
        try withInstaller { _, binary in
            let foreign = LMStudioMCPPluginInstaller.pluginsRoot.appendingPathComponent("foreign-plugin")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            let sentinel = foreign.appendingPathComponent("keep.txt")
            try Data("preserve".utf8).write(to: sentinel)
            let external: [String: Any] = ["command": "/usr/bin/true", "args": [] as [String]]
            try JSONSupport.data(from: ["mcpServers": ["foreign-plugin": external]]).write(to: LMStudioEnvironment.mcpConfigURL)
            _ = try LMStudioMCPPluginInstaller.install(preferredBinary: binary)
            let removed = try LMStudioMCPPluginInstaller.uninstall()
            XCTAssertEqual(Set(removed), Set(LMStudioConnectorRole.allCases.map(\.serverID)))
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")
            let config = try JSONSupport.object(from: Data(contentsOf: LMStudioEnvironment.mcpConfigURL))
            let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
            XCTAssertEqual(Set(servers.keys), ["foreign-plugin"])
            XCTAssertEqual(try JSONSupport.data(from: XCTUnwrap(servers["foreign-plugin"] as? [String: Any])),
                try JSONSupport.data(from: external))
            for role in LMStudioConnectorRole.allCases {
                XCTAssertFalse(FileManager.default.fileExists(atPath: LMStudioMCPPluginInstaller.pluginDirectory(name: role.serverID).path))
            }
        }
    }

    private func invoke(_ server: MCPServer, name: String, arguments: Any) throws -> (envelope: [String: Any], payload: [String: Any]) {
        let response = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": "role-test", "method": "tools/call",
            "params": ["name": name, "arguments": arguments]]))
        XCTAssertNil(response["error"], "Unexpected protocol error: \(response["error"] ?? NSNull())")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return (result, try XCTUnwrap(result["structuredContent"] as? [String: Any]))
    }

    private func health(_ role: LMStudioConnectorRole, ready: Bool) -> LMStudioConnectorHealth {
        .init(role: role, isReady: ready, protocolVersion: "2025-11-25", toolCount: role == .clu ? 4 : 20, detail: "fixture")
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forge-clu-role-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withApp(_ body: (ForgeApp) throws -> Void) throws {
        try withDirectory { directory in
            let app = try ForgeApp.bootstrap(home: directory)
            defer { app.shutdown() }
            try body(app)
        }
    }

    private func withInstaller(_ body: (URL, URL) throws -> Void) throws {
        try withDirectory { directory in
            let oldHome = LMStudioEnvironment.homeDirOverride
            let oldInstalled = LMStudioEnvironment.isAppInstalledOverride
            LMStudioEnvironment.homeDirOverride = directory.appendingPathComponent("lmstudio")
            LMStudioEnvironment.isAppInstalledOverride = true
            defer {
                LMStudioEnvironment.homeDirOverride = oldHome
                LMStudioEnvironment.isAppInstalledOverride = oldInstalled
            }
            try FileManager.default.createDirectory(at: LMStudioEnvironment.homeDir, withIntermediateDirectories: true)
            let binary = directory.appendingPathComponent("forge-conductor")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try body(directory, binary)
        }
    }

    private func verifierBinary(directory: URL, serverName: String, names: [String]) throws -> URL {
        let catalog = try ToolDefinitionCatalog.production(toolNames: Array(Set(names)))
        let descriptors = try names.map { try XCTUnwrap(catalog.definition(named: $0)).mcpDescriptor() }
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2025-11-25",
            "serverInfo": ["name": serverName, "version": ForgeApp.version]]]
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 2, "result": ["tools": descriptors]]
        let frames = try JSONSupport.string(from: initialize) + "\n" + JSONSupport.string(from: list) + "\n"
        let quoted = frames.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = "#!/bin/sh\n[ \"$FORGE_MCP_ROLE\" = clu ] || exit 91\nprintf '%s' '\(quoted)'\n/bin/cat >/dev/null\n"
        let binary = directory.appendingPathComponent("fixture-server")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }
}
