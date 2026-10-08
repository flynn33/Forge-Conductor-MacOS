// ToolDefinitionCatalogTests.swift
// Verifies one exact schema and replay catalog serves MCP and managed execution.

import XCTest
@testable import ForgeConductorCore

final class ToolDefinitionCatalogTests: XCTestCase {
    func testPagedListingSchemaIsAdditiveAndPreservesNeighboringPathContracts() throws {
        try withProductionApp("paged-listing-catalog") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let replay = try ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames)
            let definition = try XCTUnwrap(catalog.definition(named: "fs_list"))
            let schema = try definition.inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["path", "limit", "cursor", "maximum_bytes", "deadline_ms"])
            XCTAssertEqual(schema["required"] as? [String], [])
            XCTAssertEqual((properties["limit"] as? [String: Any])?["maximum"] as? Int, 1_000)
            XCTAssertEqual((properties["limit"] as? [String: Any])?["default"] as? Int, 100)
            XCTAssertEqual((properties["cursor"] as? [String: Any])?["maxLength"] as? Int, 8_192)
            XCTAssertEqual((properties["maximum_bytes"] as? [String: Any])?["maximum"] as? Int, 65_536)
            XCTAssertEqual(try replay.replayClass(for: "fs_list"), .readOnly)
            XCTAssertTrue(definition.description.contains("Path-only calls retain"))
            XCTAssertTrue(definition.description.contains("not an atomic directory snapshot"))
            for name in ["fs_delete", "fs_mkdir"] {
                let neighboring = try XCTUnwrap(catalog.definition(named: name)).inputSchemaObject()
                XCTAssertEqual(neighboring["required"] as? [String], ["path"])
                XCTAssertEqual(Set(try XCTUnwrap(neighboring["properties"] as? [String: Any]).keys), ["path", "deadline_ms"])
            }
        }
    }

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
                "shell_exec", "pdf_write", "pdf_from_file", "docx_write", "xlsx_write", "git_status", "git_diff", "git_log",
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


    func testDOCXWriteHasExactSchemaReplayAndNeighboringPDFParity() throws {
        try withProductionApp("docx-schema") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let definition = try XCTUnwrap(catalog.definition(named: "docx_write"))
            let schema = try definition.inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["path", "content", "deadline_ms"])
            XCTAssertEqual(schema["required"] as? [String], ["path", "content"])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertTrue(definition.strict)
            for key in ["path", "content"] {
                XCTAssertEqual((properties[key] as? [String: Any])?["type"] as? String, "string", key)
            }
            let deadline = try XCTUnwrap(properties["deadline_ms"] as? [String: Any])
            XCTAssertEqual(deadline["type"] as? String, "integer")
            XCTAssertEqual(deadline["minimum"] as? Int, 1)
            XCTAssertEqual(deadline["maximum"] as? Int, ToolRouter.maximumRequestedDeadlineMilliseconds)
            XCTAssertTrue(definition.description.contains("65536 UTF-8 bytes"))
            XCTAssertTrue(definition.description.contains("1048576 bytes"))
            XCTAssertTrue(definition.description.contains("native paragraph terminators"))
            XCTAssertTrue(ToolRouter.isMutatingTool("docx_write"))
            let replay = try ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames)
            XCTAssertEqual(try replay.replayClass(for: "docx_write"), .idempotent)

            let descriptor = try definition.mcpDescriptor()
            let mcpSchema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
            XCTAssertEqual(try JSONSupport.data(from: mcpSchema), definition.inputSchemaJSON)
            let providerDefinitions = try catalog.providerToolDefinitions(allowedToolNames: ["docx_write"])
            XCTAssertEqual(providerDefinitions.count, 1)
            let provider = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(providerDefinitions.first)) as? [String: Any])
            XCTAssertEqual(provider["name"] as? String, "docx_write")
            XCTAssertEqual(provider["strict"] as? Bool, true)
            let providerSchema = try XCTUnwrap(provider["parameters"] as? [String: Any])
            XCTAssertEqual(try JSONSupport.data(from: providerSchema), definition.inputSchemaJSON)

            let pdf = try XCTUnwrap(catalog.definition(named: "pdf_write")).inputSchemaObject()
            XCTAssertEqual(pdf["required"] as? [String], ["path", "content"])
            XCTAssertEqual(Set(try XCTUnwrap(pdf["properties"] as? [String: Any]).keys), ["path", "content", "title", "deadline_ms"])
            let fromFile = try XCTUnwrap(catalog.definition(named: "pdf_from_file")).inputSchemaObject()
            XCTAssertEqual(fromFile["required"] as? [String], ["source_path"])
            XCTAssertEqual(Set(try XCTUnwrap(fromFile["properties"] as? [String: Any]).keys), ["source_path", "dest_path", "title", "deadline_ms"])
            let missingContext = try app.tools.call(name: "docx_write", arguments: ["path": "unattached.docx", "content": ""], clientID: ClientID("docx-unattached"))
            XCTAssertFalse(missingContext.ok)
            XCTAssertEqual(missingContext.payload["code"] as? String, "project_context_required")
        }
    }

    func testDOCXWriteRejectsRawInvalidPathsBeforeAuthorizationNormalization() throws {
        try withProductionApp("docx-path-admission") { app in
            let project = app.paths.home.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let client = ClientID("docx-path-admission")
            let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial,
                clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [project],
                    allowedTools: ["docx_write", "pdf_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
            let invalid: [(String, [String: Any])] = [
                ("missing", ["content": "plain"]),
                ("number", ["path": NSNumber(value: 3), "content": "plain"]),
                ("boolean", ["path": NSNumber(value: true), "content": "plain"]),
                ("null", ["path": NSNull(), "content": "plain"]),
                ("array", ["path": ["report.docx"], "content": "plain"]),
                ("object", ["path": ["name": "report.docx"], "content": "plain"]),
                ("empty", ["path": "", "content": "plain"]),
                ("blank", ["path": " \t\r\n", "content": "plain"]),
                ("NUL", ["path": "before\u{0000}after.docx", "content": "plain"]),
            ]
            for (label, arguments) in invalid {
                let decision = try authorization.authorize(tool: "docx_write", arguments: arguments,
                    context: context, clientID: client, binding: nil, cancellation: ToolCallCancellation(timeoutSeconds: 5))
                guard case .denied(let code, _) = decision else {
                    XCTFail("\(label): raw invalid DOCX path must not become an authorized normalized string")
                    continue
                }
                XCTAssertEqual(code, "invalid_path", label)
            }
            let arguments: [String: Any] = ["path": "relative.docx", "content": "plain\n"]
            let docx = try authorization.authorize(tool: "docx_write", arguments: arguments,
                context: context, clientID: client, binding: nil, cancellation: nil)
            let pdf = try authorization.authorize(tool: "pdf_write", arguments: arguments,
                context: context, clientID: client, binding: nil, cancellation: nil)
            guard case .allowed(let normalizedDOCX) = docx, case .allowed(let normalizedPDF) = pdf else {
                return XCTFail("Valid DOCX paths must use the existing write normalization boundary")
            }
            XCTAssertEqual(normalizedDOCX["path"] as? String, normalizedPDF["path"] as? String)
            XCTAssertEqual(normalizedDOCX["path"] as? String,
                project.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("relative.docx").standardizedFileURL.path)
            XCTAssertEqual(normalizedDOCX["content"] as? String, "plain\n")
            let legacyPDF = try authorization.authorize(tool: "pdf_write", arguments: ["path": NSNumber(value: 3), "content": "plain"],
                context: context, clientID: client, binding: nil, cancellation: nil)
            guard case .allowed = legacyPDF else {
                return XCTFail("The new raw-path rule must not change the existing PDF argument contract")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("relative.docx").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("3").path))
        }
    }

    func testDOCXWriteDefaultGrantsPreserveCustomDenialsAndFilesystemIndependence() throws {
        try withProductionApp("docx-default-grants") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            XCTAssertTrue(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.contains("docx_write"))
            XCTAssertTrue(ContinuityAutomation.progressTools.contains("docx_write"))
            for specs in [app.catalog.all(), AgentCatalog.builtinDefaults()] {
                let docs = try XCTUnwrap(specs.first { $0.id == "docs" })
                XCTAssertEqual(docs.tools.filter { $0 == "docx_write" }.count, 1)
                XCTAssertTrue(docs.body.contains("docx_write"))
                for spec in specs where spec.id != "docs" {
                    XCTAssertFalse(spec.tools.contains("docx_write"), spec.id)
                }
            }
            XCTAssertEqual(try catalog.definitions(allowedToolNames: ["fs_write"]).map(\.name), ["fs_write"])
            XCTAssertFalse(ToolGrantSemantics.grants(tool: "docx_write", from: ["fs_write"]))
            XCTAssertFalse(ToolGrantSemantics.grants(tool: "fs_write", from: ["docx_write"]))
            XCTAssertTrue(ToolGrantSemantics.grants(tool: "docx_write", from: ["*"]))
            let custom = """
            ---
            id: docs
            display_name: Owner docs
            tools:
              - fs_write
            tools_forbidden:
              - docx_write
            ---
            Owner-defined write-only documentation role.
            """
            try custom.write(to: app.paths.agentsDir.appendingPathComponent("docs.md"), atomically: true, encoding: .utf8)
            app.catalog.reload()
            let spec = try XCTUnwrap(app.catalog.get("docs"))
            XCTAssertEqual(spec.source, "custom")
            XCTAssertEqual(spec.tools, ["fs_write"])
            XCTAssertEqual(spec.toolsForbidden, ["docx_write"])
            let project = app.paths.home.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let client = ClientID("docx-grant-boundary")
            let projectID = ProjectID()
            let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
            for (granted, requested) in [("fs_write", "docx_write"), ("docx_write", "fs_write")] {
                let context = ToolInvocationContext(projectID: projectID, projectGeneration: .initial,
                    clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [project],
                        allowedTools: [granted], networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let decision = try authorization.authorize(tool: requested, arguments: ["path": "report.docx", "content": "plain"],
                    context: context, clientID: client, binding: nil, cancellation: nil)
                guard case .denied(let code, _) = decision else {
                    XCTFail("\(granted) must not grant \(requested)")
                    continue
                }
                XCTAssertEqual(code, "tool_not_granted")
            }
            let context = ToolInvocationContext(projectID: projectID, projectGeneration: .initial,
                clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [project],
                    allowedTools: ["*"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let binding = ActiveBinding(sessionID: SessionID("docx-custom-binding"), agentID: spec.id,
                toolsPrimary: spec.tools, toolsForbidden: spec.toolsForbidden, cwd: project.path)
            let decision = try authorization.authorize(tool: "docx_write", arguments: ["path": "report.docx", "content": "plain"],
                context: context, clientID: client, binding: binding, cancellation: nil)
            guard case .denied(let code, _) = decision else {
                return XCTFail("A wildcard durable grant must not override an explicit custom-agent DOCX denial")
            }
            XCTAssertEqual(code, "tool_forbidden")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("report.docx").path))
        }
    }

    func testXLSXWriteHasExactTextArraySchemaReplayAndNeighboringDocumentParity() throws {
        try withProductionApp("xlsx-schema") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let definition = try XCTUnwrap(catalog.definition(named: "xlsx_write"))
            let schema = try definition.inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["path", "rows", "deadline_ms"])
            XCTAssertEqual(schema["required"] as? [String], ["path", "rows"])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertTrue(definition.strict)
            XCTAssertEqual((properties["path"] as? [String: Any])?["type"] as? String, "string")
            let rows = try XCTUnwrap(properties["rows"] as? [String: Any])
            XCTAssertEqual(rows["type"] as? String, "array")
            XCTAssertEqual(rows["maxItems"] as? Int, 256)
            XCTAssertNil(rows["minItems"])
            let row = try XCTUnwrap(rows["items"] as? [String: Any])
            XCTAssertEqual(row["type"] as? String, "array")
            XCTAssertEqual(row["maxItems"] as? Int, 64)
            XCTAssertNil(row["minItems"])
            let cell = try XCTUnwrap(row["items"] as? [String: Any])
            XCTAssertEqual(cell["type"] as? String, "string")
            XCTAssertEqual(cell["maxLength"] as? Int, 4_096)
            XCTAssertTrue((cell["description"] as? String)?.contains("4096 UTF-8 bytes") == true)
            let deadline = try XCTUnwrap(properties["deadline_ms"] as? [String: Any])
            XCTAssertEqual(deadline["type"] as? String, "integer")
            XCTAssertEqual(deadline["minimum"] as? Int, 1)
            XCTAssertEqual(deadline["maximum"] as? Int, ToolRouter.maximumRequestedDeadlineMilliseconds)
            XCTAssertTrue(definition.description.contains("4096 cells"))
            XCTAssertTrue(definition.description.contains("65536 total cell UTF-8 bytes"))
            XCTAssertTrue(definition.description.contains("1048576 bytes"))
            XCTAssertTrue(definition.description.contains("without line normalization"))
            XCTAssertTrue(definition.description.contains("formula-like strings"))
            XCTAssertEqual(ManagerToolCategory.classify("xlsx_write"), .documents)
            XCTAssertTrue(ToolRouter.isMutatingTool("xlsx_write"))
            let replay = try ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames)
            XCTAssertEqual(try replay.replayClass(for: "xlsx_write"), .idempotent)

            let descriptor = try definition.mcpDescriptor()
            XCTAssertEqual(try JSONSupport.data(from: try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])),
                           definition.inputSchemaJSON)
            let providerDefinitions = try catalog.providerToolDefinitions(allowedToolNames: ["xlsx_write"])
            XCTAssertEqual(providerDefinitions.count, 1)
            let provider = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(providerDefinitions.first)) as? [String: Any])
            XCTAssertEqual(provider["name"] as? String, "xlsx_write")
            XCTAssertEqual(provider["strict"] as? Bool, true)
            XCTAssertEqual(try JSONSupport.data(from: try XCTUnwrap(provider["parameters"] as? [String: Any])),
                           definition.inputSchemaJSON)

            let docx = try XCTUnwrap(catalog.definition(named: "docx_write")).inputSchemaObject()
            XCTAssertEqual(docx["required"] as? [String], ["path", "content"])
            XCTAssertEqual(Set(try XCTUnwrap(docx["properties"] as? [String: Any]).keys), ["path", "content", "deadline_ms"])
            let pdf = try XCTUnwrap(catalog.definition(named: "pdf_write")).inputSchemaObject()
            XCTAssertEqual(pdf["required"] as? [String], ["path", "content"])
            XCTAssertEqual(Set(try XCTUnwrap(pdf["properties"] as? [String: Any]).keys), ["path", "content", "title", "deadline_ms"])
            let missing = try app.tools.call(name: "xlsx_write", arguments: ["path": "unattached.xlsx", "rows": [["text"]]],
                                             clientID: ClientID("xlsx-unattached"))
            XCTAssertFalse(missing.ok)
            XCTAssertEqual(missing.payload["code"] as? String, "project_context_required")
        }
    }

    func testXLSXWriteRejectsRawInvalidPathsAndPreservesTextRowsDuringNormalization() throws {
        try withProductionApp("xlsx-path-admission") { app in
            let project = app.paths.home.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let client = ClientID("xlsx-path-admission")
            let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial,
                clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [project],
                    allowedTools: ["xlsx_write", "docx_write", "pdf_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
            let rows = [["café 日本語", "=1+1"], ["", " leading and trailing "]]
            let invalid: [(String, Any?)] = [
                ("missing", nil), ("number", NSNumber(value: 3)), ("boolean", NSNumber(value: true)),
                ("null", NSNull()), ("array", ["report.xlsx"]), ("object", ["name": "report.xlsx"]),
                ("empty", ""), ("blank", " \t\r\n"), ("NUL", "before\u{0000}after.xlsx"),
            ]
            for (label, path) in invalid {
                var arguments: [String: Any] = ["rows": rows]
                if let path { arguments["path"] = path }
                let decision = try authorization.authorize(tool: "xlsx_write", arguments: arguments,
                    context: context, clientID: client, binding: nil, cancellation: ToolCallCancellation(timeoutSeconds: 5))
                guard case .denied(let code, _) = decision else {
                    XCTFail("\(label): raw XLSX path must not become an authorized normalized string")
                    continue
                }
                XCTAssertEqual(code, "invalid_path", label)
            }
            let arguments: [String: Any] = ["path": "relative.xlsx", "rows": rows]
            let xlsx = try authorization.authorize(tool: "xlsx_write", arguments: arguments,
                context: context, clientID: client, binding: nil, cancellation: nil)
            let docx = try authorization.authorize(tool: "docx_write", arguments: ["path": "relative.xlsx", "content": "plain"],
                context: context, clientID: client, binding: nil, cancellation: nil)
            guard case .allowed(let normalizedXLSX) = xlsx, case .allowed(let normalizedDOCX) = docx else {
                return XCTFail("Valid XLSX paths must use the existing write normalization boundary")
            }
            XCTAssertEqual(normalizedXLSX["path"] as? String, normalizedDOCX["path"] as? String)
            XCTAssertEqual(try JSONSupport.data(from: ["rows": try XCTUnwrap(normalizedXLSX["rows"] as? [[String]])]),
                           try JSONSupport.data(from: ["rows": rows]))
            let legacyPDF = try authorization.authorize(tool: "pdf_write", arguments: ["path": NSNumber(value: 3), "content": "plain"],
                context: context, clientID: client, binding: nil, cancellation: nil)
            guard case .allowed = legacyPDF else { return XCTFail("XLSX path validation must not alter the PDF path contract") }
            let strictDOCX = try authorization.authorize(tool: "docx_write", arguments: ["path": NSNumber(value: 3), "content": "plain"],
                context: context, clientID: client, binding: nil, cancellation: nil)
            guard case .denied(let docxCode, _) = strictDOCX else { return XCTFail("Existing DOCX raw-path validation must remain strict") }
            XCTAssertEqual(docxCode, "invalid_path")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("relative.xlsx").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("3").path))
        }
    }

    func testXLSXWriteDefaultEnrollmentPreservesCustomDenialsAndNarrowGrants() throws {
        try withProductionApp("xlsx-default-grants") { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            XCTAssertEqual(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.filter { $0 == "xlsx_write" }.count, 1)
            XCTAssertTrue(ContinuityAutomation.progressTools.contains("xlsx_write"))
            for specs in [app.catalog.all(), AgentCatalog.builtinDefaults()] {
                let docs = try XCTUnwrap(specs.first { $0.id == "docs" })
                XCTAssertEqual(docs.tools.filter { $0 == "xlsx_write" }.count, 1)
                XCTAssertTrue(docs.body.contains("xlsx_write"))
                for spec in specs where spec.id != "docs" { XCTAssertFalse(spec.tools.contains("xlsx_write"), spec.id) }
            }
            XCTAssertEqual(try catalog.definitions(allowedToolNames: ["xlsx_write"]).map(\.name), ["xlsx_write"])
            for existing in ["fs_write", "docx_write", "pdf_write"] {
                XCTAssertEqual(try catalog.definitions(allowedToolNames: [existing]).map(\.name), [existing])
                XCTAssertFalse(ToolGrantSemantics.grants(tool: "xlsx_write", from: [existing]))
                XCTAssertFalse(ToolGrantSemantics.grants(tool: existing, from: ["xlsx_write"]))
            }
            let custom = """
            ---
            id: docs
            display_name: Owner docs
            tools:
              - fs_write
              - docx_write
            tools_forbidden:
              - xlsx_write
            ---
            Owner-defined documentation grants.
            """
            try custom.write(to: app.paths.agentsDir.appendingPathComponent("docs.md"), atomically: true, encoding: .utf8)
            app.catalog.reload()
            let spec = try XCTUnwrap(app.catalog.get("docs"))
            XCTAssertEqual(spec.source, "custom")
            XCTAssertEqual(spec.tools, ["fs_write", "docx_write"])
            XCTAssertEqual(spec.toolsForbidden, ["xlsx_write"])
            let project = app.paths.home.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let client = ClientID("xlsx-grant-boundary")
            let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
            let projectID = ProjectID()
            for (granted, requested) in [("fs_write", "xlsx_write"), ("xlsx_write", "fs_write"),
                                         ("docx_write", "xlsx_write"), ("xlsx_write", "docx_write")] {
                let context = ToolInvocationContext(projectID: projectID, projectGeneration: .initial,
                    clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [project],
                        allowedTools: [granted], networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let decision = try authorization.authorize(tool: requested,
                    arguments: ["path": "report.xlsx", "rows": [["text"]], "content": "plain"],
                    context: context, clientID: client, binding: nil, cancellation: nil)
                guard case .denied(let code, _) = decision else {
                    XCTFail("\(granted) must not grant \(requested)")
                    continue
                }
                XCTAssertEqual(code, "tool_not_granted")
            }
            let context = ToolInvocationContext(projectID: projectID, projectGeneration: .initial,
                clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [project],
                    allowedTools: ["*"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let binding = ActiveBinding(sessionID: SessionID("xlsx-custom-binding"), agentID: spec.id,
                toolsPrimary: spec.tools, toolsForbidden: spec.toolsForbidden, cwd: project.path)
            let denied = try authorization.authorize(tool: "xlsx_write", arguments: ["path": "report.xlsx", "rows": [["text"]]],
                context: context, clientID: client, binding: binding, cancellation: nil)
            guard case .denied(let code, _) = denied else {
                return XCTFail("A wildcard project grant must not override the custom-agent XLSX denial")
            }
            XCTAssertEqual(code, "tool_forbidden")
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("report.xlsx").path))
        }
    }

    func testXLSXWriteDoesNotExpandImportedExplicitCapabilities() throws {
        try withProductionApp("xlsx-imported-grants") { app in
            let projectID = ProjectID()
            let source = app.paths.home.appendingPathComponent("owner-package", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "Follow the owner's existing document grants.".write(
                to: source.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
            let requested = ["fs_read", "docx_write"]
            let expected = Array(Set(requested).union(["instruction_catalog", "instruction_read"])).sorted()
            let manifest: [String: Any] = [
                "schema_version": 1, "package_id": "owner-documents", "version": "1",
                "mission": "Preserve the owner's explicit document capabilities.",
                "project_id": projectID.description, "entry_documents": ["instructions.md"],
                "requested_capabilities": requested,
                "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate],
                "resource_policy": ["profile": "project-default"],
            ]
            try JSONSupport.data(from: manifest).write(to: source.appendingPathComponent("forge-package.json"))
            let store = try ProjectInstructionQueueStore(paths: app.paths)
            let snapshot = try store.importPackage(sourceURL: source, projectID: projectID, generation: .initial)
            let package = try XCTUnwrap(snapshot.packages.first)
            XCTAssertEqual(package.allowedTools, expected)
            XCTAssertFalse(package.allowedTools.contains("xlsx_write"))
            let reread = try store.snapshot(projectID: projectID, generation: .initial)
            XCTAssertEqual(try XCTUnwrap(reread.packages.first).allowedTools, expected)
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            XCTAssertEqual(Set(try catalog.definitions(allowedToolNames: Set(package.allowedTools)).map(\.name)), Set(expected))
            let client = ClientID("xlsx-imported-grants")
            let context = ToolInvocationContext(projectID: projectID, projectGeneration: .initial,
                clientID: client, authorizationScope: ToolAuthorizationScope(canonicalRoots: [source],
                    allowedTools: Set(package.allowedTools), networkAllowed: false, maximumInlineOutputBytes: 65_536))
            let decision = try ToolAuthorizationService(paths: app.paths, config: app.config).authorize(
                tool: "xlsx_write", arguments: ["path": "report.xlsx", "rows": [["text"]]],
                context: context, clientID: client, binding: nil, cancellation: nil)
            guard case .denied(let code, _) = decision else {
                return XCTFail("New default XLSX enrollment must not expand an imported explicit grant")
            }
            XCTAssertEqual(code, "tool_not_granted")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("report.xlsx").path))
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
