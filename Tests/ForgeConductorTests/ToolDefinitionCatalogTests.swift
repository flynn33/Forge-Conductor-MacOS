// ToolDefinitionCatalogTests.swift
// Verifies one exact schema and replay catalog serves MCP and managed execution.

import XCTest
@testable import ForgeConductorCore

final class ToolDefinitionCatalogTests: XCTestCase {
    func testRendererAddsExactPublicSchemaAndPreservesResearchGrantsAndContextAdmission() throws {
        try withProductionApp("renderer-catalog") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let replay = try ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames)
            let definition = try XCTUnwrap(catalog.definition(named: "web.render"))
            let schema = try definition.inputSchemaObject()
            XCTAssertEqual(schema["required"] as? [String], ["url"])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["url", "timeout_sec", "maximum_bytes", "deadline_ms"])
            XCTAssertEqual((properties["timeout_sec"] as? [String: Any])?["maximum"] as? Int, 30)
            XCTAssertEqual((properties["maximum_bytes"] as? [String: Any])?["maximum"] as? Int, 65_536)
            XCTAssertEqual(try replay.replayClass(for: "web.render"), .readOnly)
            XCTAssertTrue(definition.description.contains("macOS 27+"))
            XCTAssertTrue(definition.description.contains("untrusted data"))
            XCTAssertTrue(definition.description.contains("at most five unique follow-up URLs"))
            XCTAssertTrue(definition.description.contains("Across a request"))
            XCTAssertTrue(definition.description.contains("including finite cookie/state redirects"))
            let researchGrants: Set<String> = ["fs_read", "fs_list", "fs_glob", "search_text", "git_log",
                "git_status", "shell_exec", "web.search", "web.fetch", "web.render"]
            XCTAssertEqual(Set(try XCTUnwrap(app.catalog.get("research")).tools), researchGrants)
            XCTAssertEqual(Set(try XCTUnwrap(AgentCatalog.builtinDefaults().first { $0.id == "research" }).tools), researchGrants)
            for name in ["web.fetch", "web.search", "web.render", "shell_exec"] {
                XCTAssertTrue(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.contains(name))
                XCTAssertTrue(app.tools.toolNames.contains(name))
            }
            let missing = try app.tools.call(name: "web.render", arguments: ["url": "https://example.com/"],
                clientID: ClientID("renderer-unattached"))
            XCTAssertEqual(missing.payload["code"] as? String, "project_context_required")
        }
    }

    private static let jobControlTools: Set<String> = [
        "job.status", "job.read_output", "job.cancel", "job.list",
    ]
    private static let nativeXcodeToolNames: Set<String> = [
        "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator",
    ]
    private static let nativeXcodeAgentTools: Set<String> = [
        "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator",
        "job.status", "job.read_output", "job.cancel", "job.list",
    ]

    func testBuiltinXcodeAgentGrantsPreserveResourceAndFallbackContracts() throws {
        let resourceGrants: [String: Set<String>] = [
            "test": ["shell_exec", "fs_read", "fs_list", "fs_glob", "search_text", "git_status"],
            "debug": ["fs_read", "fs_list", "fs_glob", "search_text", "shell_exec", "python.run", "runtime.capabilities", "git_status", "git_diff", "git_log"],
            "implement": ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text", "shell_exec", "git_status", "git_diff", "git_add", "git_commit", "session_checkpoint", "session_handoff", "context_get", "memory_set", "memory_get", "memory_search"],
        ]
        let fallbackGrants: [String: Set<String>] = [
            "test": try XCTUnwrap(resourceGrants["test"]),
            "debug": ["fs_read", "fs_list", "fs_glob", "search_text", "shell_exec", "python.run", "runtime.capabilities", "git_status", "git_diff", "git_log"],
            "implement": ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text", "shell_exec", "git_status", "git_diff", "git_add", "git_commit"],
        ]
        let forbidden: [String: Set<String>] = [
            "test": ["git_push", "git_commit"], "debug": ["git_push"], "implement": ["git_push"],
        ]
        try withProductionApp("xcode-agent-grants") { app in
            let fallback = Dictionary(uniqueKeysWithValues: AgentCatalog.builtinDefaults().map { ($0.id, $0) })
            let catalogNames = Set(app.tools.toolNames)
            for role in ["test", "debug", "implement"] {
                let loaded = try XCTUnwrap(app.catalog.get(role))
                let defaultSpec = try XCTUnwrap(fallback[role])
                XCTAssertEqual(loaded.source, "builtin", role)
                XCTAssertEqual(Set(loaded.tools), try XCTUnwrap(resourceGrants[role]).union(Self.nativeXcodeAgentTools), role)
                XCTAssertEqual(Set(defaultSpec.tools), try XCTUnwrap(fallbackGrants[role]).union(Self.nativeXcodeAgentTools), role)
                for spec in [loaded, defaultSpec] {
                    XCTAssertEqual(spec.tools.count, Set(spec.tools).count, role)
                    XCTAssertEqual(Set(spec.toolsForbidden), forbidden[role], role)
                    XCTAssertTrue(Self.nativeXcodeAgentTools.isSubset(of: catalogNames), role)
                    XCTAssertTrue(spec.body.contains("build-for-testing"), role)
                    XCTAssertTrue(spec.body.contains("test counts"), role)
                    let firstMoves = spec.firstMoves.joined(separator: " ")
                    for name in ["xcode.run", "job.status", "job.read_output", "xcode.result"] {
                        XCTAssertTrue(firstMoves.contains(name), "\(role): \(name)")
                    }
                }
            }
            for spec in app.catalog.all() where resourceGrants[spec.id] == nil {
                XCTAssertTrue(Set(spec.tools).isDisjoint(with: Self.nativeXcodeToolNames), spec.id)
                if spec.id != "docs" {
                    XCTAssertTrue(Set(spec.tools).isDisjoint(with: Self.jobControlTools), spec.id)
                }
            }
        }
    }

    func testAllBuiltinResourceAndFallbackGrantsResolveToExecutableCatalogDefinitions() throws {
        try withProductionApp("builtin-executable-grants") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let known = Set(catalog.definitions.map(\.name))
            let resources = app.catalog.all().filter { $0.source == "builtin" }
            let fallback = AgentCatalog.builtinDefaults()
            XCTAssertEqual(Set(resources.map(\.id)), Set(fallback.map(\.id)))
            XCTAssertEqual(resources.count, 10)
            for spec in resources + fallback {
                let granted = Set(spec.tools)
                XCTAssertEqual(spec.tools.count, granted.count, spec.id)
                XCTAssertTrue(granted.isSubset(of: known), "\(spec.id): \(granted.subtracting(known).sorted())")
                XCTAssertEqual(try catalog.providerToolDefinitions(allowedToolNames: granted).count,
                               try catalog.definitions(allowedToolNames: granted).count, spec.id)
            }
            let docsTools: Set<String> = [
                "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text",
                "shell_exec", "pdf_write", "pdf_from_file", "git_status", "git_diff", "git_log",
                "runtime.capabilities", "python.run",
            ]
            let auditTools: Set<String> = [
                "git_status", "git_diff", "git_log", "fs_read", "search_text", "fs_glob", "shell_exec",
            ]
            for specs in [resources, fallback] {
                let docs = try XCTUnwrap(specs.first { $0.id == "docs" })
                XCTAssertEqual(Set(docs.tools), docsTools.union(Self.jobControlTools))
                XCTAssertEqual(Set(docs.toolsForbidden), ["git_push", "git_commit"])
                XCTAssertTrue(docs.body.contains("runtime.capabilities"))
                XCTAssertTrue(docs.body.contains("python.run"))
                XCTAssertTrue(docs.body.contains("job.status"))
                XCTAssertTrue(docs.body.contains("job.read_output"))
                let audit = try XCTUnwrap(specs.first { $0.id == "precommit-audit" })
                XCTAssertEqual(Set(audit.tools), auditTools)
                XCTAssertTrue(audit.body.contains("fs_glob"))
            }
            let schema = try XCTUnwrap(catalog.definition(named: "fs_glob")).inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["pattern", "path", "deadline_ms"])
            for key in ["pattern", "path"] {
                XCTAssertEqual((properties[key] as? [String: Any])?["type"] as? String, "string", key)
            }
            XCTAssertEqual(schema["required"] as? [String], [])
            let deadline = try XCTUnwrap(properties["deadline_ms"] as? [String: Any])
            XCTAssertEqual(deadline["minimum"] as? Int, 1)
            XCTAssertEqual(deadline["maximum"] as? Int, ToolRouter.maximumRequestedDeadlineMilliseconds)
        }
    }

    func testBuiltinReplacementToolsAdmitFilenameSearchAndDurableOptionalPython() async throws {
        try await withProductionAppAsync("builtin-replacement-admission") { app in
            let project = app.paths.home.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let expectedFile = project.appendingPathComponent("Evidence.swift")
            try "// fixture".write(to: expectedFile, atomically: true, encoding: .utf8)
            let physicalExpectedFile = RuntimePathCanonicalizer.canonicalExistingURL(expectedFile)
            _ = try app.config.update(["allowed_roots": [project.path]], save: false)
            for role in ["debug", "docs", "precommit-audit"] {
                let client = ClientID("catalog-replacements-\(role)")
                let started = try app.tools.call(name: "agent_run_start",
                    arguments: ["agent_id": role, "goal": "Verify executable specialist tools", "cwd": project.path],
                    clientID: client)
                XCTAssertTrue(started.ok, "\(role): \(started.payload)")
                let globArguments = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(#"{"pattern":"*.swift","deadline_ms":10000}"#.utf8)) as? [String: Any])
                let glob = try app.tools.call(name: "fs_glob", arguments: globArguments, clientID: client)
                XCTAssertTrue(glob.ok, "\(role): \(glob.payload)")
                XCTAssertEqual(glob.payload["path"] as? String, project.path)
                XCTAssertEqual(glob.payload["matches"] as? [String], [physicalExpectedFile.path])
                guard role != "precommit-audit" else { continue }
                let capabilities = try app.tools.call(name: "runtime.capabilities", arguments: [:], clientID: client)
                XCTAssertTrue(capabilities.ok, "\(role): \(capabilities.payload)")
                let python = try XCTUnwrap(capabilities.payload["python"] as? [String: Any])
                XCTAssertEqual(python["required"] as? Bool, false)
                let available = try XCTUnwrap(python["available"] as? Bool)
                let missingReplay = try app.tools.call(name: "python.run",
                    arguments: ["script": "print('never-submitted')"], clientID: client)
                XCTAssertFalse(missingReplay.ok)
                XCTAssertEqual(missingReplay.payload["code"] as? String, "invalid_request")
                let pythonArguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
                    #"{"script":"print('specialist-python')","replay_class":"read_only","timeout_sec":5,"maximum_inline_output_bytes":1024,"deadline_ms":10000}"#.utf8
                )) as? [String: Any])
                let submitted = try app.tools.call(name: "python.run", arguments: pythonArguments, clientID: client)
                if !available {
                    XCTAssertFalse(submitted.ok, role)
                    XCTAssertEqual(submitted.payload["code"] as? String, "runtime_unavailable", role)
                    continue
                }
                XCTAssertTrue(submitted.ok, "\(role): \(submitted.payload)")
                let jobID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(submitted.payload["job_id"] as? String)))
                let context = try app.projectContexts.invocationContext(for: client)
                let terminal = try await app.runtimeJobs.service.waitForTerminal(
                    jobID: jobID, context: context, maximumWait: .seconds(10))
                XCTAssertEqual(terminal.state, .completed, role)
                XCTAssertEqual(terminal.exitCode, 0, role)
                let status = try app.tools.call(name: "job.status", arguments: ["job_id": jobID.uuidString], clientID: client)
                XCTAssertTrue(status.ok, "\(role): \(status.payload)")
                XCTAssertEqual(status.payload["state"] as? String, "completed", role)
                XCTAssertEqual(status.payload["exit_code"] as? Int32, 0, role)
                let output = try app.tools.call(name: "job.read_output",
                    arguments: ["job_id": jobID.uuidString, "stream": "stdout", "limit": 1024], clientID: client)
                XCTAssertTrue(output.ok, "\(role): \(output.payload)")
                XCTAssertEqual(output.payload["data"] as? String, "specialist-python\n", role)
                XCTAssertEqual(output.payload["eof"] as? Bool, true, role)
                XCTAssertEqual(output.payload["artifact_truncated"] as? Bool, false, role)
                let canceled = try app.tools.call(name: "job.cancel", arguments: ["job_id": jobID.uuidString], clientID: client)
                XCTAssertTrue(canceled.ok, "\(role): \(canceled.payload)")
                XCTAssertEqual(canceled.payload["state"] as? String, "completed", role)
                let listed = try app.tools.call(name: "job.list", arguments: ["limit": 10], clientID: client)
                XCTAssertTrue(listed.ok, "\(role): \(listed.payload)")
                let jobs = try XCTUnwrap(listed.payload["jobs"] as? [[String: Any]])
                XCTAssertTrue(jobs.contains { $0["job_id"] as? String == jobID.uuidString.lowercased() }, role)
            }
        }
    }

    func testUnimplementedLegacyNamesRemainRejectedByCatalogAndDispatch() throws {
        try withProductionApp("legacy-unknown-tools") { app in
            let names = ["python_exec", "python_info", "search_files"]
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            XCTAssertThrowsError(try catalog.providerToolDefinitions(allowedToolNames: Set(names))) {
                XCTAssertEqual($0 as? ToolDefinitionCatalogError, .unregisteredAllowedTools(names.sorted()))
            }
            for name in names {
                XCTAssertNil(catalog.definition(named: name))
                let result = try app.tools.call(name: name, arguments: [:], clientID: ClientID("unbound-\(name)"))
                XCTAssertFalse(result.ok, name)
                XCTAssertEqual(result.payload["code"] as? String, "unknown_tool", "\(name): \(result.payload)")
            }
        }
    }

    func testBuiltinCorrectionsPreserveCustomSpecialistGrantsAndExplicitDenials() throws {
        try withProductionApp("custom-replacement-grants") { app in
            for role in ["debug", "docs", "precommit-audit"] {
                let custom = """
                ---
                id: \(role)
                display_name: Owner specialist
                tools:
                  - fs_read
                tools_forbidden:
                  - python.run
                  - runtime.capabilities
                  - fs_glob
                  - job.status
                ---
                Owner-defined read-only role.
                """
                try custom.write(to: app.paths.agentsDir.appendingPathComponent("\(role).md"), atomically: true, encoding: .utf8)
            }
            app.catalog.reload()
            for role in ["debug", "docs", "precommit-audit"] {
                let spec = try XCTUnwrap(app.catalog.get(role))
                XCTAssertEqual(spec.source, "custom", role)
                XCTAssertEqual(spec.tools, ["fs_read"], role)
                XCTAssertEqual(Set(spec.toolsForbidden), ["python.run", "runtime.capabilities", "fs_glob", "job.status"], role)
            }
        }
    }

    func testCustomAgentGrantsAreNotWidenedByBuiltinXcodeIntegration() throws {
        try withProductionApp("custom-agent-grants") { app in
            let custom = """
            ---
            id: test
            display_name: Owner test
            description: Owner-defined read-only test role.
            tools:
              - fs_read
            tools_forbidden:
              - xcode.run
              - git_push
            ---
            Read only; preserve these explicit grants.
            """
            try custom.write(to: app.paths.agentsDir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)
            app.catalog.reload()
            let spec = try XCTUnwrap(app.catalog.get("test"))
            XCTAssertEqual(spec.source, "custom")
            XCTAssertEqual(spec.tools, ["fs_read"])
            XCTAssertEqual(Set(spec.toolsForbidden), ["xcode.run", "git_push"])
            XCTAssertTrue(Set(spec.tools).isDisjoint(with: Self.nativeXcodeAgentTools))
        }
    }

    func testBuiltinAgentRunStartAdmitsNativeXcodeDiscoveryAndJobInspection() async throws {
        try await withProductionAppAsync("xcode-agent-admission") { app in
            let project = app.paths.home.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            _ = try app.config.update(["allowed_roots": [project.path]], save: false)
            for role in ["test", "debug", "implement"] {
                let client = ClientID("catalog-xcode-\(role)")
                let started = try app.tools.call(
                    name: "agent_run_start",
                    arguments: ["agent_id": role, "goal": "Verify native Xcode admission", "cwd": project.path],
                    clientID: client
                )
                XCTAssertTrue(started.ok, "\(role): \(started.payload)")
                XCTAssertEqual(started.payload["project_context_attached"] as? Bool, true, role)
                let binding = try XCTUnwrap(app.sessions.binding(for: client))
                XCTAssertTrue(Self.nativeXcodeAgentTools.isSubset(of: Set(binding.toolsPrimary)), role)
                let discovery = try app.tools.call(
                    name: "xcode.discover",
                    arguments: ["query": "version", "timeout_sec": 15],
                    clientID: client
                )
                XCTAssertTrue(discovery.ok, "\(role): \(discovery.payload)")
                let jobID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(discovery.payload["job_id"] as? String)))
                let context = try app.projectContexts.invocationContext(for: client)
                let terminal = try await app.runtimeJobs.service.waitForTerminal(
                    jobID: jobID, context: context, maximumWait: .seconds(20)
                )
                XCTAssertEqual(terminal.state, .completed, role)
                XCTAssertEqual(terminal.exitCode, 0, role)
                let status = try app.tools.call(name: "job.status", arguments: ["job_id": jobID.uuidString], clientID: client)
                XCTAssertTrue(status.ok, "\(role): \(status.payload)")
                XCTAssertEqual(status.payload["state"] as? String, "completed", role)
                XCTAssertEqual(status.payload["exit_code"] as? Int32, 0, role)
                let output = try app.tools.call(
                    name: "job.read_output",
                    arguments: ["job_id": jobID.uuidString, "stream": "stdout", "limit": 4096],
                    clientID: client
                )
                XCTAssertTrue(output.ok, "\(role): \(output.payload)")
                XCTAssertTrue((output.payload["data"] as? String)?.contains("Xcode") == true, role)
                XCTAssertEqual(output.payload["artifact_truncated"] as? Bool, false, role)
                let listed = try app.tools.call(name: "job.list", arguments: ["limit": 10], clientID: client)
                XCTAssertTrue(listed.ok, "\(role): \(listed.payload)")
                let canceled = try app.tools.call(name: "job.cancel", arguments: ["job_id": jobID.uuidString], clientID: client)
                XCTAssertTrue(canceled.ok, "\(role): \(canceled.payload)")
                XCTAssertEqual(canceled.payload["state"] as? String, "completed", role)

                let authorization = ToolAuthorizationService(paths: app.paths, config: app.config, workspace: app.continuityAutomation)
                let denied = try authorization.authorize(
                    tool: "git_push", arguments: [:], context: context,
                    clientID: client, binding: binding, cancellation: nil
                )
                guard case .denied(let code, _) = denied else {
                    XCTFail("\(role): git_push must remain forbidden")
                    continue
                }
                XCTAssertEqual(code, "tool_forbidden", role)
            }
        }
    }

    func testProductionCatalogExactlyCoversRouterAndIsCanonical() throws {
        try withProductionApp("canonical") { app in
            let names = app.tools.toolNames
            let catalog = try ToolDefinitionCatalog.production(toolNames: names)
            let reordered = try ToolDefinitionCatalog.production(
                toolNames: Array(names.reversed())
            )

            XCTAssertEqual(catalog.definitions.map(\.name), names.sorted())
            XCTAssertEqual(catalog.definitions.count, Set(names).count)
            XCTAssertEqual(catalog.canonicalJSON, reordered.canonicalJSON)
            XCTAssertEqual(catalog.canonicalSHA256, reordered.canonicalSHA256)
            XCTAssertEqual(catalog.canonicalSHA256.count, 64)

            for definition in catalog.definitions {
                let schema = try definition.inputSchemaObject()
                XCTAssertEqual(schema["type"] as? String, "object", definition.name)
                XCTAssertFalse(definition.description.isEmpty, definition.name)
                let properties = try XCTUnwrap(
                    schema["properties"] as? [String: Any],
                    definition.name
                )
                if ContinuityControlToolName(rawValue: definition.name) != nil {
                    XCTAssertNil(properties["deadline_ms"], definition.name)
                    XCTAssertEqual(schema["additionalProperties"] as? Bool, false, definition.name)
                } else {
                    let deadline = try XCTUnwrap(
                        properties["deadline_ms"] as? [String: Any], definition.name
                    )
                    XCTAssertEqual(deadline["type"] as? String, "integer", definition.name)
                }
            }

            let allowed = try catalog.definitions(
                allowedToolNames: ["fs_read", "memory_get"]
            )
            XCTAssertEqual(allowed.map(\.name), ["fs_read", "memory_get"])
            XCTAssertEqual(
                try catalog.definitions(allowedToolNames: ["fs_delete"]).map(\.name),
                ["fs_delete", "fs_delete_recovery"]
            )
            XCTAssertEqual(
                try catalog.definitions(allowedToolNames: ["fs_delete_recovery"]).map(\.name),
                ["fs_delete_recovery"]
            )
            XCTAssertEqual(
                try catalog.definitions(allowedToolNames: ["*"]),
                catalog.definitions
            )
            let providerTools = try catalog.providerToolDefinitions(
                allowedToolNames: ["fs_read", "memory_get"]
            )
            XCTAssertEqual(providerTools.count, 2)
            for (definition, data) in zip(allowed, providerTools) {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                XCTAssertEqual(object["type"] as? String, "function")
                XCTAssertEqual(object["name"] as? String, definition.name)
                XCTAssertEqual(object["description"] as? String, definition.description)
                let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
                let parametersJSON = try JSONSerialization.data(
                    withJSONObject: parameters,
                    options: [.sortedKeys]
                )
                XCTAssertEqual(parametersJSON, definition.inputSchemaJSON)
                XCTAssertEqual(object["strict"] as? Bool, definition.strict)
            }
            XCTAssertThrowsError(
                try catalog.definitions(allowedToolNames: ["unregistered.future_tool"])
            ) { error in
                XCTAssertEqual(
                    error as? ToolDefinitionCatalogError,
                    .unregisteredAllowedTools(["unregistered.future_tool"])
                )
            }
        }
    }

    func testCatalogRejectsMissingStaleAndDuplicateDefinitions() throws {
        let one = try CanonicalToolDefinition(
            name: "one",
            description: "First tool.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]]
        )
        let two = try CanonicalToolDefinition(
            name: "two",
            description: "Second tool.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]]
        )

        XCTAssertThrowsError(
            try ToolDefinitionCatalog(toolNames: ["one", "two"], definitions: [one])
        ) { error in
            XCTAssertEqual(error as? ToolDefinitionCatalogError, .missingDefinitions(["two"]))
        }
        XCTAssertThrowsError(
            try ToolDefinitionCatalog(toolNames: ["one"], definitions: [one, two])
        ) { error in
            XCTAssertEqual(error as? ToolDefinitionCatalogError, .staleDefinitions(["two"]))
        }
        XCTAssertThrowsError(
            try ToolDefinitionCatalog(toolNames: ["one"], definitions: [one, one])
        ) { error in
            XCTAssertEqual(error as? ToolDefinitionCatalogError, .duplicateDefinition)
        }
        XCTAssertThrowsError(
            try ToolDefinitionCatalog(toolNames: ["one", "one"], definitions: [one])
        ) { error in
            XCTAssertEqual(error as? ToolDefinitionCatalogError, .invalidToolSet)
        }
    }

    func testMCPToolsListUsesTheCanonicalCatalogWithoutSchemaDrift() throws {
        try withProductionApp("mcp") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let server = MCPServer(app: app, clientID: ClientID("catalog-mcp"))
            let response = try XCTUnwrap(server.handle([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list",
            ]))
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])
            XCTAssertEqual(descriptors.count, catalog.definitions.count)

            let byName = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
                (descriptor["name"] as? String).map { ($0, descriptor) }
            })
            XCTAssertEqual(Set(byName.keys), Set(catalog.definitions.map(\.name)))
            for definition in catalog.definitions {
                let descriptor = try XCTUnwrap(byName[definition.name])
                XCTAssertEqual(descriptor["description"] as? String, definition.description)
                let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
                let wireSchema = try JSONSerialization.data(
                    withJSONObject: schema,
                    options: [.sortedKeys]
                )
                XCTAssertEqual(wireSchema, definition.inputSchemaJSON, definition.name)
            }
        }
    }

    func testLegacyShellTimeoutSchemaRemainsCompatibleWithRuntimeClamping() throws {
        try withProductionApp("legacy-shell-schema") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let definition = try XCTUnwrap(
                catalog.definitions.first(where: { $0.name == "shell_exec" })
            )
            let schema = try definition.inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let timeout = try XCTUnwrap(properties["timeout_sec"] as? [String: Any])

            XCTAssertEqual(timeout["type"] as? String, "number")
            XCTAssertEqual(Set(timeout.keys), ["type"])
        }
    }

    func testProtectedDeleteRecoverySchemaIsPathlessAndBounded() throws {
        try withProductionApp("delete-recovery-schema") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let definition = try XCTUnwrap(
                catalog.definitions.first(where: { $0.name == "fs_delete_recovery" })
            )
            let schema = try definition.inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let action = try XCTUnwrap(properties["action"] as? [String: Any])

            XCTAssertEqual(
                Set((action["enum"] as? [String]) ?? []),
                ["query", "resume", "acknowledge"]
            )
            XCTAssertNotNil(properties["transaction_id"])
            XCTAssertNil(properties["path"])
            XCTAssertEqual(
                Set((schema["required"] as? [String]) ?? []),
                ["transaction_id", "action"]
            )
        }
    }

    func testProductionReplayCatalogExactlyCoversRouterAndRejectsDrift() throws {
        try withProductionApp("replay") { app in
            let names = app.tools.toolNames
            let classifier = try ProductionToolReplayCatalog.classifier(
                productionToolNames: names
            )

            XCTAssertEqual(ProductionToolReplayCatalog.classifications.count, names.count)
            for name in names {
                XCTAssertEqual(
                    try classifier.replayClass(for: name),
                    ProductionToolReplayCatalog.classification(for: name),
                    name
                )
            }
            XCTAssertEqual(try classifier.replayClass(for: "fs_read"), .readOnly)
            XCTAssertEqual(try classifier.replayClass(for: "get_forge_status"), .idempotent)
            XCTAssertEqual(try classifier.replayClass(for: "fs_write"), .idempotent)
            XCTAssertEqual(
                try classifier.replayClass(for: "fs_delete_recovery"),
                .reconciled
            )
            XCTAssertEqual(try classifier.replayClass(for: "git_commit"), .reconciled)
            XCTAssertEqual(try classifier.replayClass(for: "process.run"), .reconciled)
            XCTAssertEqual(try classifier.replayClass(for: "shell_exec"), .nonReplayable)

            XCTAssertThrowsError(
                try ProductionToolReplayCatalog.classifier(
                    productionToolNames: Array(names.dropLast())
                )
            )
            XCTAssertThrowsError(
                try ProductionToolReplayCatalog.classifier(
                    productionToolNames: names + ["unregistered.future_tool"]
                )
            )
        }
    }

    func testProjectToolPreferencesPersistExplicitDenialsAndReconcileCatalogChanges() throws {
        try withProductionApp("project-permissions") { app in
            let projectID = ProjectID()
            let generation = ProjectGeneration(7)
            let initialCatalog = try ToolDefinitionCatalog.production(
                toolNames: ["fs_read", "git_status"]
            )
            let expandedCatalog = try ToolDefinitionCatalog.production(
                toolNames: ["fs_read", "fs_edit", "git_status", "shell_exec"]
            )
            var store: ProjectToolPermissionStore? = try ProjectToolPermissionStore(
                paths: app.paths,
                clock: app.clock
            )
            let initial = try XCTUnwrap(store).snapshot(
                projectID: projectID,
                generation: generation,
                catalog: initialCatalog,
                unavailableReasons: [:]
            )
            XCTAssertEqual(initial.selectionMode, .recommended)
            XCTAssertEqual(Set(initial.effectiveToolIDs), ["fs_read", "git_status"])

            let explicit = try XCTUnwrap(store).update(
                ManagerToolPermissionUpdate(
                    projectID: projectID.description,
                    projectGeneration: generation.rawValue,
                    expectedPreferenceRevision: initial.preferenceRevision,
                    selectionMode: .explicit,
                    selectedToolIDs: ["fs_read"]
                ),
                projectID: projectID,
                generation: generation,
                catalog: initialCatalog,
                unavailableReasons: [:]
            )
            XCTAssertEqual(explicit.preferenceRevision, 1)
            XCTAssertEqual(explicit.effectiveToolIDs, ["fs_read"])

            store = nil
            store = try ProjectToolPermissionStore(paths: app.paths, clock: app.clock)
            let afterCatalogExpansion = try XCTUnwrap(store).snapshot(
                projectID: projectID,
                generation: generation,
                catalog: expandedCatalog,
                unavailableReasons: [:]
            )
            XCTAssertEqual(afterCatalogExpansion.selectionMode, .explicit)
            XCTAssertEqual(afterCatalogExpansion.selectedToolIDs, ["fs_read"])
            XCTAssertEqual(afterCatalogExpansion.effectiveToolIDs, ["fs_read"])
            XCTAssertFalse(afterCatalogExpansion.selectedToolIDs.contains("fs_edit"))

            let reducedCatalog = try ToolDefinitionCatalog.production(
                toolNames: ["git_status"]
            )
            let afterCatalogRemoval = try XCTUnwrap(store).snapshot(
                projectID: projectID,
                generation: generation,
                catalog: reducedCatalog,
                unavailableReasons: [:]
            )
            XCTAssertEqual(afterCatalogRemoval.selectedToolIDs, ["fs_read"])
            XCTAssertTrue(afterCatalogRemoval.effectiveToolIDs.isEmpty)
            XCTAssertEqual(
                afterCatalogRemoval.tools.first(where: { $0.id == "fs_read" })?.unavailableReason,
                "Not registered by the current Forge tool catalog."
            )
            let removedStaleSelection = try XCTUnwrap(store).update(
                ManagerToolPermissionUpdate(
                    projectID: projectID.description,
                    projectGeneration: generation.rawValue,
                    expectedPreferenceRevision: afterCatalogRemoval.preferenceRevision,
                    selectionMode: .explicit,
                    selectedToolIDs: []
                ),
                projectID: projectID,
                generation: generation,
                catalog: reducedCatalog,
                unavailableReasons: [:]
            )
            XCTAssertTrue(removedStaleSelection.selectedToolIDs.isEmpty)

            let expandedAfterRemoval = try XCTUnwrap(store).snapshot(
                projectID: projectID,
                generation: generation,
                catalog: expandedCatalog,
                unavailableReasons: [:]
            )
            XCTAssertFalse(expandedAfterRemoval.selectedToolIDs.contains("fs_read"))
            XCTAssertEqual(
                expandedAfterRemoval.tools.first(where: { $0.id == "fs_edit" })?.highImpact,
                true
            )

            let allEligible = try XCTUnwrap(store).update(
                ManagerToolPermissionUpdate(
                    projectID: projectID.description,
                    projectGeneration: generation.rawValue,
                    expectedPreferenceRevision: expandedAfterRemoval.preferenceRevision,
                    selectionMode: .allEligible,
                    selectedToolIDs: []
                ),
                projectID: projectID,
                generation: generation,
                catalog: expandedCatalog,
                unavailableReasons: ["shell_exec": "Shell is disabled."]
            )
            XCTAssertEqual(allEligible.selectionMode, .allEligible)
            XCTAssertEqual(
                Set(allEligible.effectiveToolIDs),
                ["fs_read", "fs_edit", "git_status"]
            )
            XCTAssertFalse(allEligible.effectiveToolIDs.contains("shell_exec"))
            XCTAssertEqual(
                allEligible.tools.first(where: { $0.id == "shell_exec" })?.unavailableReason,
                "Shell is disabled."
            )

            let restoredAvailability = try XCTUnwrap(store).snapshot(
                projectID: projectID,
                generation: generation,
                catalog: expandedCatalog,
                unavailableReasons: [:]
            )
            XCTAssertTrue(restoredAvailability.effectiveToolIDs.contains("shell_exec"))
            XCTAssertThrowsError(try XCTUnwrap(store).update(
                ManagerToolPermissionUpdate(
                    projectID: projectID.description,
                    projectGeneration: generation.rawValue,
                    expectedPreferenceRevision: 0,
                    selectionMode: .recommended,
                    selectedToolIDs: []
                ),
                projectID: projectID,
                generation: generation,
                catalog: expandedCatalog,
                unavailableReasons: [:]
            )) { error in
                XCTAssertEqual(
                    error as? ToolPermissionStoreError,
                    .staleRevision(expected: 0, actual: 3)
                )
            }
        }
    }

    private func withProductionAppAsync(
        _ label: String,
        operation: (ForgeApp) async throws -> Void
    ) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-tool-catalog-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home, startTelemetry: false)
        defer {
            let report = app.shutdown()
            XCTAssertTrue(report.completed, "Runtime shutdown did not complete; evidence retained at \(home.path)")
            if report.completed { try? FileManager.default.removeItem(at: home) }
        }
        try await operation(app)
    }

    private func withProductionApp(
        _ label: String,
        operation: (ForgeApp) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-tool-catalog-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        defer {
            app.shutdown()
            try? FileManager.default.removeItem(at: home)
        }
        try operation(app)
    }
}
