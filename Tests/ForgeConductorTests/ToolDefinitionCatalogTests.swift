// ToolDefinitionCatalogTests.swift
// Verifies one exact schema and replay catalog serves MCP and managed execution.

import XCTest
@testable import ForgeConductorCore

final class ToolDefinitionCatalogTests: XCTestCase {
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
                let deadline = try XCTUnwrap(
                    properties["deadline_ms"] as? [String: Any],
                    definition.name
                )
                XCTAssertEqual(deadline["type"] as? String, "integer", definition.name)
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
