import Darwin
import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class XcodeCLIIntegrationTests: XCTestCase {
    func testManagedTypedXcodePreparationOwnsCanonicalCompletionIntentBeforeAdmission() async throws {
        try await withFixture(script: "printf should-not-run") { fixture in
            let context = try await fixture.autonomousRunContext()
            let memory = ProjectMemoryService(paths: AppPaths(home: fixture.root.appendingPathComponent("completion-memory")))
            defer { memory.closeAll() }
            let reconciler = ProductionToolInvocationReconciler(
                controlPlane: fixture.control, runtimeJobs: fixture.repository, memory: memory
            )
            let selected = ["FixtureTests/FixtureCase/testRealCase"]
            let runArguments: [String: Any] = [
                "action": "test-without-building", "workspace": "Fixture.xcworkspace",
                "scheme": "FixtureTests", "destination": "platform=macOS",
                "derived_data_path": "DerivedData", "result_bundle_path": "Actual.xcresult",
                "only_testing": selected, "timeout_sec": 5, "idempotency_key": "typed-test-intent"
            ]
            let resultArguments: [String: Any] = [
                "query": "test_summary", "result_bundle_path": "Actual.xcresult",
                "timeout_sec": 5, "idempotency_key": "typed-summary-intent"
            ]
            for (tool, arguments) in [("xcode.run", runArguments), ("xcode.result", resultArguments)] {
                let call = BrokeredToolCall(providerCallID: "completion-" + tool, toolName: tool, arguments: arguments)
                let descriptorOptional = try await reconciler.prepare(call: call, context: context)
                let raw = try XCTUnwrap(descriptorOptional, "Typed completion must own canonical native intent before admission")
                XCTAssertLessThanOrEqual(raw.utf8.count, 8_192)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                let command = try XcodeCLIService.command(tool: tool, arguments: arguments, context: context)
                XCTAssertEqual(object["descriptor_version"] as? Int, 1)
                XCTAssertEqual(object["typed_xcode_completion_version"] as? Int, 1)
                XCTAssertEqual(object["tool"] as? String, tool)
                XCTAssertEqual(object["arguments_sha256"] as? String, JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(arguments)))
                XCTAssertEqual(object["canonical_cwd_sha256"] as? String, JSONSupport.sha256Hex(command.workingDirectory.path))
                XCTAssertEqual(object["result_bundle_path_sha256"] as? String, JSONSupport.sha256Hex(try XCTUnwrap(command.resultBundlePath)))
                XCTAssertEqual(object["runtime_idempotency_key"] as? String, command.idempotencyKey)
                XCTAssertEqual(object["native_argument_count"] as? Int, command.arguments.count)
                XCTAssertEqual(object["timeout_seconds"] as? Int, command.timeoutSeconds)
                XCTAssertEqual(object[tool == "xcode.run" ? "action" : "query"] as? String,
                               tool == "xcode.run" ? "test-without-building" : "test_summary")
                XCTAssertNil(object["exit_code"], "Prepared intent cannot manufacture a native result")
                XCTAssertNil(object["passedTests"], "Actual counts must come from the correlated native result job")
            }
            let beforeAdmission = try await fixture.jobs.list(context: context)
            XCTAssertTrue(beforeAdmission.isEmpty, "Descriptor preparation must not admit a process")
        }
    }

    func testTypedCompletionDescriptorsKeepCanonicalIntentAndDifferentActionsDistinct() async throws {
        try await withFixture(script: "printf should-not-run") { fixture in
            let context = try await fixture.autonomousRunContext()
            let memory = ProjectMemoryService(paths: AppPaths(home: fixture.root.appendingPathComponent("completion-parity-memory")))
            defer { memory.closeAll() }
            let reconciler = ProductionToolInvocationReconciler(
                controlPlane: fixture.control, runtimeJobs: fixture.repository, memory: memory
            )
            var relative = Self.runArguments(action: .buildForTesting)
            relative["idempotency_key"] = "completion-native-parity"
            relative["only_testing"] = ["AppTests/FixtureCase/testOne"]
            let relativeCommand = try XcodeCLIService.command(tool: "xcode.run", arguments: relative, context: context)
            var canonical = relative
            canonical["cwd"] = relativeCommand.workingDirectory.path
            canonical["project"] = relativeCommand.arguments[3]
            canonical["derived_data_path"] = relativeCommand.derivedDataPath
            canonical["result_bundle_path"] = relativeCommand.resultBundlePath
            var different = canonical
            different["action"] = "test-without-building"
            var descriptors: [[String: Any]] = []
            for (index, arguments) in [relative, canonical, different].enumerated() {
                let call = BrokeredToolCall(providerCallID: "native-completion-parity-\(index)", toolName: "xcode.run", arguments: arguments)
                let descriptorOptional = try await reconciler.prepare(call: call, context: context)
                let raw = try XCTUnwrap(descriptorOptional)
                descriptors.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]))
            }
            XCTAssertEqual(descriptors[0]["runtime_idempotency_key"] as? String, descriptors[1]["runtime_idempotency_key"] as? String)
            XCTAssertEqual(descriptors[0]["result_bundle_path_sha256"] as? String, descriptors[1]["result_bundle_path_sha256"] as? String)
            XCTAssertNotEqual(descriptors[0]["arguments_sha256"] as? String, descriptors[1]["arguments_sha256"] as? String,
                              "The stored raw argument digest must remain bound to its own provider call")
            XCTAssertNotEqual(descriptors[1]["runtime_idempotency_key"] as? String, descriptors[2]["runtime_idempotency_key"] as? String)
            XCTAssertEqual(descriptors[0]["action"] as? String, "build-for-testing")
            XCTAssertEqual(descriptors[2]["action"] as? String, "test-without-building")
            XCTAssertEqual(descriptors[0]["only_testing_count"] as? Int, 1)
            let jobs = try await fixture.jobs.list(context: context)
            XCTAssertTrue(jobs.isEmpty)
        }
    }

    func testEveryAdditiveToolHasBoundedSchemaAndExistingShellSchemaIsUnchanged() throws {
        XCTAssertEqual(Set(XcodeCLIToolPack.names), ["xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator"])
        for name in XcodeCLIToolPack.names {
            XCTAssertNotNil(XcodeCLIToolPack.description(for: name))
            let schema = try XCTUnwrap(XcodeCLIToolPack.schema(for: name))
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let timeout = try XCTUnwrap(properties["timeout_sec"] as? [String: Any])
            XCTAssertEqual(timeout["maximum"] as? Int, 86_400)
            let output = try XCTUnwrap(properties["maximum_inline_output_bytes"] as? [String: Any])
            XCTAssertEqual(output["maximum"] as? Int, 65_536)
        }
        XCTAssertNil(XcodeCLIToolPack.schema(for: "shell_exec"))
        XCTAssertEqual(ShellToolPack.maximumTimeoutSec, 120)
        XCTAssertTrue(RuntimeJobToolPack.names.contains("process.run"))
        XCTAssertTrue(RuntimeJobToolPack.names.contains("bash.run"))
    }

    func testProductionRegistrationReplayAndMCPUseTheSameXcodeSchemas() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-xcode-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        defer {
            app.shutdown()
            try? FileManager.default.removeItem(at: home)
        }
        let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
        let classifier = try ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames)
        let server = MCPServer(app: app, clientID: ClientID("xcode-catalog"), role: .primary)
        let response = try XCTUnwrap(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let descriptors = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            (descriptor["name"] as? String).map { ($0, descriptor) }
        })
        for name in XcodeCLIToolPack.names {
            XCTAssertTrue(app.tools.toolNames.contains(name))
            let definition = try XCTUnwrap(catalog.definitions.first(where: { $0.name == name }))
            let schema = try definition.inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let deadline = try XCTUnwrap(properties["deadline_ms"] as? [String: Any])
            XCTAssertEqual(deadline["type"] as? String, "integer")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let descriptor = try XCTUnwrap(byName[name])
            let wireSchema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
            XCTAssertEqual(try JSONSupport.canonicalJSON(wireSchema), try JSONSupport.canonicalJSON(schema), name)
            XCTAssertEqual(descriptor["description"] as? String, XcodeCLIToolPack.description(for: name))
            XCTAssertEqual(try classifier.replayClass(for: name), .reconciled)
            XCTAssertFalse(try classifier.replayClass(for: name).permitsAutomaticReplay)
            XCTAssertTrue(ProductionToolReplayCatalog.acceptsDurableIdempotencyArgument.contains(name))
        }
        XCTAssertEqual(try catalog.definitions(allowedToolNames: ["process.run"]).map(\.name), ["process.run"])
        XCTAssertEqual(try catalog.definitions(allowedToolNames: ["xcode.discover"]).map(\.name), ["xcode.discover"])
    }

    func testDiscoveryUsesInspectedAppleArgumentVectors() throws {
        let context = Self.context()
        let expected: [(XcodeDiscoveryQuery, [String])] = [
            (.version, ["xcodebuild", "-version"]),
            (.sdks, ["xcodebuild", "-showsdks", "-json"]),
            (.schemes, ["xcodebuild", "-workspace", Self.canonicalRoot.appendingPathComponent("App.xcworkspace").path, "-list", "-json"]),
            (.destinations, ["xcodebuild", "-workspace", Self.canonicalRoot.appendingPathComponent("App.xcworkspace").path, "-scheme", "App", "-showdestinations"]),
            (.buildSettings, ["xcodebuild", "-workspace", Self.canonicalRoot.appendingPathComponent("App.xcworkspace").path, "-scheme", "App", "-showBuildSettings", "-json"]),
            (.testPlans, ["xcodebuild", "-workspace", Self.canonicalRoot.appendingPathComponent("App.xcworkspace").path, "-scheme", "App", "-showTestPlans"]),
        ]
        for (query, argv) in expected {
            let command = try XcodeCLIService.command(
                tool: "xcode.discover", arguments: ["query": query.rawValue, "workspace": "App.xcworkspace", "scheme": "App"], context: context
            )
            XCTAssertEqual(command.arguments, argv)
            XCTAssertEqual(command.replayClass, .readOnly)
        }
    }

    func testBuildTestAnalyzeAndArchiveKeepNativeArgumentsAndSigningPolicy() throws {
        for action in XcodeNativeAction.allCases {
            var arguments = Self.runArguments(action: action)
            if action.acceptsTestSelection {
                arguments["only_testing"] = ["AppTests/ConnectionTests/testFailure"]
            }
            if action == .archive { arguments["archive_path"] = "evidence/Candidate.xcarchive" }
            let command = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: Self.context())
            XCTAssertEqual(command.arguments.prefix(2), ["xcodebuild", action.rawValue])
            XCTAssertTrue(command.arguments.contains("App; $(touch should-never-exist)"))
            XCTAssertTrue(command.arguments.contains(Self.canonicalRoot.appendingPathComponent("evidence/Test.xcresult").path))
            XCTAssertFalse(command.arguments.contains(where: { $0.contains("CODE_SIGNING") || $0.contains("allowProvisioning") || $0.contains("skip-testing") }))
            XCTAssertEqual(command.arguments.filter { $0.hasPrefix("-only-testing:") }.count, action.acceptsTestSelection ? 1 : 0)
            XCTAssertEqual(command.arguments.contains("-test-timeouts-enabled"), action.executesTests)
            XCTAssertEqual(command.replayClass, .nonReplayable)
            XCTAssertEqual(command.timeoutSeconds, 1_800)
        }
        XCTAssertFalse(XcodeNativeAction.buildForTesting.executesTests)
    }

    func testResultAndSimulatorCommandsAreReadOnlyAndDebuggerIsBoundedBatch() throws {
        for query in XcodeResultQuery.allCases {
            let command = try XcodeCLIService.command(
                tool: "xcode.result", arguments: ["query": query.rawValue, "result_bundle_path": "evidence/Test.xcresult"], context: Self.context()
            )
            XCTAssertEqual(command.arguments.first, "xcresulttool")
            XCTAssertEqual(command.arguments.suffix(3), ["--path", Self.canonicalRoot.appendingPathComponent("evidence/Test.xcresult").path, "--compact"])
            XCTAssertEqual(command.replayClass, .readOnly)
        }
        for query in XcodeSimulatorQuery.allCases {
            let command = try XcodeCLIService.command(tool: "xcode.simulator", arguments: ["query": query.rawValue], context: Self.context())
            XCTAssertEqual(command.arguments.prefix(4), ["simctl", "list", "--json", query.rawValue])
            XCTAssertEqual(command.replayClass, .readOnly)
        }
        let debug = try XcodeCLIService.command(
            tool: "xcode.debug", arguments: ["executable": "bin/App", "arguments": ["value with spaces"], "commands": ["breakpoint set -n main", "run", "thread backtrace all"]], context: Self.context()
        )
        XCTAssertEqual(debug.arguments.prefix(4), ["lldb", "--batch", "--no-lldbinit", "--no-use-colors"])
        XCTAssertEqual(debug.arguments.suffix(3), ["--", Self.canonicalRoot.appendingPathComponent("bin/App").path, "value with spaces"])
        XCTAssertFalse(debug.arguments.contains("--attach-pid"))
    }

    func testMalformedAndAmbiguousRequestsFailBeforeNativeSubmission() throws {
        let context = Self.context()
        let invalid: [(String, [String: Any])] = [
            ("xcode.discover", ["query": "unknown"]),
            ("xcode.discover", ["query": "version", "timeout_sec": true]),
            ("xcode.discover", ["query": "version", "timeout_sec": 1.5]),
            ("xcode.discover", ["query": "version", "timeout_sec": 86_401]),
            ("xcode.discover", ["query": "version", "maximum_inline_output_bytes": 0]),
            ("xcode.discover", ["query": "version", "file_size_profile": "native_xcode_sparse_cas_v1"]),
            ("xcode.discover", ["query": "version", "project": 7]),
            ("xcode.discover", ["query": "sdks", "workspace": "App\0hidden.xcworkspace"]),
            ("xcode.discover", ["query": "version", "scheme": String(repeating: "x", count: 4_097)]),
            ("xcode.discover", ["query": "schemes", "project": "App.xcodeproj", "workspace": "App.xcworkspace"]),
            ("xcode.discover", ["query": "schemes", "project": "App.txt"]),
            ("xcode.run", Self.runArguments(action: .build).merging(["only_testing": ["AppTests"]]) { _, new in new }),
            ("xcode.run", Self.runArguments(action: .build).merging(["scheme": "App\0hidden"]) { _, new in new }),
            ("xcode.run", Self.runArguments(action: .archive)),
            ("xcode.run", Self.runArguments(action: .build).merging(["allowProvisioningUpdates": true]) { _, new in new }),
            ("xcode.result", ["query": "test_summary", "result_bundle_path": "wrong.json"]),
            ("xcode.debug", ["executable": "App", "commands": []]),
            ("xcode.debug", ["executable": "App", "commands": Array(repeating: "run", count: 33)]),
            ("xcode.debug", ["executable": "App", "commands": ["run\nscript ignored"]]),
            ("xcode.simulator", ["query": "boot"]),
            ("xcode.simulator", ["query": "devices", "device_id": "booted"]),
        ]
        for (tool, arguments) in invalid {
            XCTAssertThrowsError(try XcodeCLIService.command(tool: tool, arguments: arguments, context: context), "\(tool): \(arguments.keys.sorted())") { error in
                XCTAssertEqual((error as? RuntimeJobError)?.code, "invalid_request")
            }
        }
    }

    func testIdempotencyKeysSeparateNativeIntentsAndProjectsRemainIntact() throws {
        let first = try XcodeCLIService.command(tool: "xcode.discover", arguments: ["query": "version", "idempotency_key": "retry"], context: Self.context())
        let repeated = try XcodeCLIService.command(tool: "xcode.discover", arguments: ["query": "version", "idempotency_key": "retry"], context: Self.context())
        let different = try XcodeCLIService.command(tool: "xcode.discover", arguments: ["query": "sdks", "idempotency_key": "retry"], context: Self.context())
        XCTAssertEqual(first.idempotencyKey, repeated.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, different.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, "retry")
    }

    func testRoutingDeadlineIsValidatedWithoutForwardingToNativeTool() throws {
        let command = try XcodeCLIService.command(tool: "xcode.discover", arguments: ["query": "version", "deadline_ms": 500], context: Self.context())
        XCTAssertEqual(command.arguments, ["xcodebuild", "-version"])
        XCTAssertThrowsError(try XcodeCLIService.command(tool: "xcode.discover", arguments: ["query": "version", "deadline_ms": false], context: Self.context()))
    }

    func testRelativeAndCanonicalProviderPathsShareNativeIdempotencyKey() throws {
        var relative = Self.runArguments(action: .build)
        relative["cwd"] = "."
        relative["idempotency_key"] = "same-build"
        var canonical = relative
        canonical["cwd"] = Self.canonicalRoot.path
        canonical["project"] = Self.canonicalRoot.appendingPathComponent("App.xcodeproj").path
        canonical["derived_data_path"] = Self.canonicalRoot.appendingPathComponent("evidence/derived-data").path
        canonical["result_bundle_path"] = Self.canonicalRoot.appendingPathComponent("evidence/Test.xcresult").path
        let raw = try XcodeCLIService.command(tool: "xcode.run", arguments: relative, context: Self.context())
        let normalized = try XcodeCLIService.command(tool: "xcode.run", arguments: canonical, context: Self.context())
        XCTAssertEqual(raw, normalized)
    }

    func testPathsCanonicalizeMissingParentsThroughSymlinksAndPreserveNativeAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-xcode-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked"), withDestinationURL: outside)
        let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("native-path-test"),
                                            authorizationScope: ToolAuthorizationScope(canonicalRoots: [project], writableRoots: [], allowedTools: Set(XcodeCLIToolPack.names), networkAllowed: false, maximumInlineOutputBytes: 1_024))
        var arguments = Self.runArguments(action: .build)
        arguments["derived_data_path"] = "linked/new/derived-data"
        let command = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: context)
        XCTAssertEqual(command.derivedDataPath, RuntimePathCanonicalizer.canonicalExistingURL(outside).appendingPathComponent("new/derived-data").path)
        XCTAssertEqual(command.workingDirectory, RuntimePathCanonicalizer.canonicalExistingURL(project))
    }

    func testAuthorizationPreservesExplicitCwdOperandAndReconciliationIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-xcode-authorization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let subdirectory = project.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let paths = AppPaths(home: root.appendingPathComponent("home"))
        let authorization = ToolAuthorizationService(paths: paths, config: ConfigStore(paths: paths))
        let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("xcode-authorization"),
                                            authorizationScope: ToolAuthorizationScope(canonicalRoots: [project], allowedTools: Set(XcodeCLIToolPack.names), networkAllowed: false, maximumInlineOutputBytes: 1_024))
        let requests: [(String, [String: Any])] = [
            ("xcode.run", Self.runArguments(action: .archive).merging(["cwd": "nested", "archive_path": "evidence/App.xcarchive", "idempotency_key": "nested-build"]) { _, new in new }),
            ("xcode.result", ["query": "tests", "cwd": "nested", "result_bundle_path": "evidence/Test.xcresult", "idempotency_key": "nested-result"]),
            ("xcode.debug", ["cwd": "nested", "executable": "bin/App", "commands": ["target list"], "idempotency_key": "nested-debug"]),
        ]
        for (tool, arguments) in requests {
            let raw = try XcodeCLIService.command(tool: tool, arguments: arguments, context: context)
            guard case let .allowed(normalized) = authorization.authorize(tool: tool, arguments: arguments, context: context, clientID: context.clientID, binding: nil) else {
                XCTFail("Authorized native tool was denied: \(tool)")
                continue
            }
            XCTAssertEqual(raw, try XcodeCLIService.command(tool: tool, arguments: normalized, context: context), tool)
            XCTAssertEqual(raw.workingDirectory, RuntimePathCanonicalizer.canonicalExistingURL(subdirectory))
        }
    }

    func testResolvedPathByteLimitIncludesTheProjectRoot() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(String(repeating: "project/", count: 60))
        let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("xcode-path-budget"),
                                            authorizationScope: ToolAuthorizationScope(canonicalRoots: [root], allowedTools: Set(XcodeCLIToolPack.names), networkAllowed: false, maximumInlineOutputBytes: 1_024))
        var arguments = Self.runArguments(action: .build)
        let relativeOutput = String(repeating: "nested/", count: Int(PATH_MAX) / 7)
        XCTAssertLessThan(relativeOutput.utf8.count, 4_096)
        arguments["derived_data_path"] = relativeOutput
        XCTAssertThrowsError(try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: context)) { error in
            XCTAssertEqual((error as? RuntimeJobError)?.code, "invalid_request")
        }
    }

    func testNativeFailureExit65IsPreservedBeyondSuccessfulSubmissionReceipt() async throws {
        try await withFixture(script: "printf 'native compiler failed\\n' >&2; exit 65") { fixture in
            let resultOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "version"], context: fixture.context)
            let result = try XCTUnwrap(resultOptional)
            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.payload["submission_only"] as? Bool, true)
            let jobID = try Self.jobID(result)
            let terminal = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(5))
            XCTAssertEqual(terminal.state, .failed)
            XCTAssertEqual(terminal.exitCode, 65)
            XCTAssertEqual(terminal.executionProfile, .directProcess)
            let output = try await fixture.jobs.readOutput(jobID: jobID, stream: .stderr, offset: 0, limit: 1_024, context: fixture.context)
            XCTAssertTrue(output.eof)
            XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "native compiler failed\n")
        }
    }

    func testNativeDeadlineAndOutputBudgetsRemainEnforced() async throws {
        try await withFixture(script: "sleep 10") { fixture in
            let resultOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "version", "timeout_sec": 1], context: fixture.context)
            let result = try XCTUnwrap(resultOptional)
            let terminal = try await fixture.jobs.waitForTerminal(jobID: try Self.jobID(result), context: fixture.context, maximumWait: .seconds(5))
            XCTAssertEqual(terminal.state, .timedOut)
        }
        try await withFixture(script: "i=0; while [ $i -lt 2000 ]; do printf 'native-output-abcdefghijklmnopqrstuvwxyz\\n'; i=$((i + 1)); done") { fixture in
            let resultOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "sdks", "maximum_inline_output_bytes": 128], context: fixture.context)
            let result = try XCTUnwrap(resultOptional)
            let jobID = try Self.jobID(result)
            let terminal = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(5))
            XCTAssertEqual(terminal.state, .completed)
            XCTAssertEqual(terminal.exitCode, 0)
            let output = try await fixture.jobs.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 1_024, context: fixture.context)
            XCTAssertLessThanOrEqual(output.data.count, 1_024)
            XCTAssertLessThanOrEqual(output.totalRetainedBytes, 4_096)
            XCTAssertGreaterThan(output.totalObservedBytes, output.totalRetainedBytes)
            XCTAssertTrue(output.artifactTruncated)
        }
    }

    func testDeniedGrantAndCrossProjectReadCannotBypassRuntimeAuthority() async throws {
        try await withFixture(script: "printf ok") { fixture in
            let denied = ToolInvocationContext(
                projectID: fixture.context.projectID, projectGeneration: .initial,
                clientID: fixture.context.clientID,
                authorizationScope: ToolAuthorizationScope(canonicalRoots: [fixture.projectRoot], allowedTools: ["process.run"], networkAllowed: false, maximumInlineOutputBytes: 1_024)
            )
            let deniedResultOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "version"], context: denied)
            let deniedResult = try XCTUnwrap(deniedResultOptional)
            XCTAssertFalse(deniedResult.ok)
            XCTAssertEqual(deniedResult.payload["code"] as? String, "tool_not_authorized")
            let empty = try await fixture.jobs.list(context: fixture.context)
            XCTAssertTrue(empty.isEmpty)
            let resultOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "version"], context: fixture.context)
            let result = try XCTUnwrap(resultOptional)
            let jobID = try Self.jobID(result)
            _ = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(5))
            let otherID = ProjectID()
            let otherRoot = fixture.root.appendingPathComponent("other-project")
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            _ = try await fixture.control.registerProjectUnchecked(projectID: otherID, displayName: "Other Project", canonicalRoot: otherRoot)
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "other-xcode-client")
            _ = try await fixture.control.bind(owner: owner, projectID: otherID, generation: .initial, authorizationScope: fixture.context.authorizationScope)
            let other = try await fixture.control.invocationContext(for: owner)
            do {
                _ = try await fixture.jobs.readOutput(jobID: jobID, stream: .stdout, offset: 0, limit: 1_024, context: other)
                XCTFail("A different project read the native result")
            } catch let error as RuntimeJobError {
                XCTAssertEqual(error, .jobScopeMismatch(jobID))
            }
        }
    }

    func testGenerationChangeRejectsNativeSubmissionAndReusedReceiptKeepsTerminalState() async throws {
        try await withFixture(script: "printf done") { fixture in
            let arguments: [String: Any] = ["query": "version", "idempotency_key": "one-intent"]
            let firstOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: arguments, context: fixture.context)
            let first = try XCTUnwrap(firstOptional)
            let jobID = try Self.jobID(first)
            _ = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(5))
            let repeatedOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: arguments, context: fixture.context)
            let repeated = try XCTUnwrap(repeatedOptional)
            XCTAssertEqual(try Self.jobID(repeated), jobID)
            XCTAssertEqual(repeated.payload["state"] as? String, "completed")
            XCTAssertEqual(repeated.payload["exit_code"] as? Int32, 0)
            XCTAssertEqual(repeated.payload["idempotency_match"] as? Bool, true)
            _ = try await fixture.control.beginReset(projectID: fixture.context.projectID, expectedGeneration: .initial)
            _ = try await fixture.control.completeReset(projectID: fixture.context.projectID, expectedGeneration: .initial)
            let staleOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "version"], context: fixture.context)
            let stale = try XCTUnwrap(staleOptional)
            XCTAssertFalse(stale.ok)
            XCTAssertEqual(stale.payload["code"] as? String, "stale_project_generation")
        }
    }

    func testProductionReconciliationUsesCanonicalNativeIntentAndPreservesRunOwnership() async throws {
        try await withFixture(script: "printf discovered") { fixture in
            let runContext = try await fixture.autonomousRunContext()
            let nested = fixture.projectRoot.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let arguments: [String: Any] = ["query": "schemes", "cwd": "nested", "project": "App.xcodeproj", "idempotency_key": "reconcile-native"]
            let submittedOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: arguments, context: runContext)
            let submitted = try XCTUnwrap(submittedOptional)
            let jobID = try Self.jobID(submitted)
            _ = try await fixture.jobs.waitForTerminal(jobID: jobID, context: runContext, maximumWait: .seconds(5))
            let memory = ProjectMemoryService(paths: AppPaths(home: fixture.root.appendingPathComponent("memory-home")))
            defer { memory.closeAll() }
            let reconciler = ProductionToolInvocationReconciler(controlPlane: fixture.control, runtimeJobs: fixture.repository, memory: memory, xcodeExecutable: fixture.projectRoot.appendingPathComponent("fixture-xcrun"))
            var canonical = arguments
            canonical["cwd"] = RuntimePathCanonicalizer.canonicalExistingURL(nested).path
            canonical["project"] = RuntimePathCanonicalizer.canonicalExistingURL(nested).appendingPathComponent("App.xcodeproj").path
            let call = BrokeredToolCall(providerCallID: "provider-call-1", toolName: "xcode.discover", arguments: canonical, idempotencyKey: "reconcile-native")
            let outcome = try await reconciler.reconcile(invocation: Self.invocation(call: call, context: runContext), call: call, context: runContext)
            guard case let .completed(receipt) = outcome else { return XCTFail("Existing canonical native intent was not reconciled") }
            XCTAssertTrue(receipt.ok)
            XCTAssertEqual(try Self.jobID(receipt), jobID)
            XCTAssertEqual(receipt.payload["state"] as? String, "completed")
            XCTAssertEqual(receipt.payload["exit_code"] as? Int32, 0)
            XCTAssertEqual(receipt.payload["submission_only"] as? Bool, true)

            let different = BrokeredToolCall(providerCallID: "provider-call-2", toolName: "xcode.discover", arguments: canonical.merging(["query": "sdks"]) { _, new in new }, idempotencyKey: "reconcile-native")
            let differentOutcome = try await reconciler.reconcile(invocation: Self.invocation(call: different, context: runContext), call: different, context: runContext)
            guard case .safeToExecute = differentOutcome else { return XCTFail("A different native command reused a prior job") }
            let unkeyed = BrokeredToolCall(providerCallID: "provider-call-3", toolName: "xcode.discover", arguments: ["query": "version"])
            let unkeyedOutcome = try await reconciler.reconcile(invocation: Self.invocation(call: unkeyed, context: runContext), call: unkeyed, context: runContext)
            guard case .unresolved = unkeyedOutcome else { return XCTFail("An ambiguous command without a durable key was replayed") }
            let otherRun = try await fixture.autonomousRunContext()
            let otherOutcome = try await reconciler.reconcile(invocation: Self.invocation(call: call, context: otherRun), call: call, context: otherRun)
            guard case .unresolved = otherOutcome else { return XCTFail("Another autonomous run adopted a native job receipt") }
            let jobs = try await fixture.jobs.list(context: runContext)
            XCTAssertEqual(jobs.count, 1)
        }
    }

    func testTypedXcodeAllowanceDoesNotChangeGenericLimitsOrPermitEnvironmentOverride() async throws {
        let probe = "printf 'cpu=%s fd=%s file=%s core=%s' \"$(ulimit -t)\" \"$(ulimit -n)\" \"$(ulimit -f)\" \"$(ulimit -c)\""
        var environment = ProcessInfo.processInfo.environment
        environment["FORGE_RUNTIME_LIMIT_FILE_BYTES"] = String(RuntimeJobLimits.maximumNativeXcodeFileBytesPerProcess)
        try await withFixture(
            script: "exec /bin/bash --noprofile --norc -c '" + probe.replacingOccurrences(of: "'", with: "'\\''") + "'",
            processEnvironment: environment
        ) { fixture in
            let arguments: [String: Any] = ["query": "version", "idempotency_key": "native-resource-policy"]
            let receiptOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: arguments, context: fixture.context)
            let receipt = try XCTUnwrap(receiptOptional)
            let nativeJob = try Self.jobID(receipt)
            let nativeRecord = try await fixture.jobs.waitForTerminal(jobID: nativeJob, context: fixture.context, maximumWait: .seconds(5))
            XCTAssertEqual(nativeRecord.state, .completed)
            XCTAssertEqual(nativeRecord.exitCode, 0)
            let nativeOutput = try await fixture.repository.output(jobID: nativeJob, stream: .stdout, context: fixture.context)
            XCTAssertEqual(nativeOutput.inlineText, "cpu=62 fd=256 file=33554432 core=0")
            XCTAssertTrue(nativeRecord.commandSummary.contains("file_size_profile=native_xcode_sparse_cas_v1:file_size_bytes=34359738368"))

            let genericRequest = RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: fixture.context,
                executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["--noprofile", "--norc", "-c", probe],
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(60), replayClass: .readOnly
            )
            XCTAssertEqual(genericRequest.fileSizeProfile, .standard)
            let genericJob = try await fixture.jobs.submit(genericRequest)
            let genericRecord = try await fixture.jobs.waitForTerminal(jobID: genericJob, context: fixture.context, maximumWait: .seconds(5))
            XCTAssertEqual(genericRecord.state, .completed)
            let genericOutput = try await fixture.repository.output(jobID: genericJob, stream: .stdout, context: fixture.context)
            XCTAssertEqual(genericOutput.inlineText, "cpu=62 fd=256 file=1048576 core=0")
            XCTAssertFalse(genericRecord.commandSummary.contains("file_size_profile="))

            let repeatedOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: arguments, context: fixture.context)
            let repeated = try XCTUnwrap(repeatedOptional)
            XCTAssertEqual(try Self.jobID(repeated), nativeJob)
            XCTAssertEqual(repeated.payload["exit_code"] as? Int32, 0)
            let jobs = try await fixture.jobs.list(context: fixture.context)
            XCTAssertEqual(jobs.count, 2)
        }
    }

    func testExplicitFileCapsRemainAuthoritativeForTypedNativeXcode() async throws {
        let defaultLimits = RuntimeJobLimits(maximumConcurrentJobs: 1, maximumCPUHeavyJobs: 1, maximumInlineOutputBytes: 1_024, maximumArtifactBytesPerJob: 4_096)
        XCTAssertEqual(defaultLimits.maximumFileBytesPerProcess, 1_073_741_824)
        XCTAssertEqual(defaultLimits.nativeXcodeFileBytesPerProcess, 34_359_738_368)
        for cap in [1_048_576, 1_073_741_824] {
            let limits = RuntimeJobLimits(maximumConcurrentJobs: 1, maximumCPUHeavyJobs: 1, maximumInlineOutputBytes: 1_024, maximumArtifactBytesPerJob: 4_096, maximumFileBytesPerProcess: cap)
            XCTAssertEqual(limits.maximumFileBytesPerProcess, cap)
            XCTAssertEqual(limits.nativeXcodeFileBytesPerProcess, cap)
            try await withFixture(script: "exec /bin/bash --noprofile --norc -c 'ulimit -f'", fileCap: cap) { fixture in
                let receiptOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: ["query": "version"], context: fixture.context)
                let receipt = try XCTUnwrap(receiptOptional)
                let jobID = try Self.jobID(receipt)
                let record = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(5))
                XCTAssertEqual(record.state, .completed)
                let output = try await fixture.repository.output(jobID: jobID, stream: .stdout, context: fixture.context)
                XCTAssertEqual(output.inlineText, "\(cap / 1_024)\n")
                XCTAssertTrue(record.commandSummary.contains("file_size_bytes=\(cap)"))
            }
        }
    }

    func testNativeXcodeProfileRejectsOtherRuntimeKindsAndCommandsBeforePersistence() async throws {
        try await withFixture(script: "printf should-not-execute") { fixture in
            let invalid: [(RuntimeKind, RuntimeExecutionProfile, URL?, [String], String?)] = [
                (.bash, .bashNoProfile, nil, [], "printf should-not-execute"),
                (.process, .directProcess, URL(fileURLWithPath: "/bin/bash"), ["-c", "true"], nil),
                (.process, .directProcess, URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift", "--version"], nil),
                (.process, .directProcess, URL(fileURLWithPath: "/usr/bin/xcrun"), ["xcodebuild", "-version"], "printf should-not-execute"),
                (.process, .directProcess, nil, ["xcodebuild", "-version"], nil),
            ]
            for (kind, profile, executable, arguments, script) in invalid {
                let request = RuntimeJobRequest(
                    kind: kind, profile: profile, context: fixture.context, executable: executable, arguments: arguments,
                    script: script, canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5),
                    replayClass: .readOnly, fileSizeProfile: .nativeXcodeSparseCAS
                )
                do {
                    _ = try await fixture.jobs.submit(request)
                    XCTFail("Invalid native Xcode profile admitted a durable job")
                } catch {
                    XCTAssertEqual((error as? RuntimeJobError)?.code, "invalid_request")
                }
            }
            let jobs = try await fixture.jobs.list(context: fixture.context)
            XCTAssertTrue(jobs.isEmpty)
        }
    }

    func testXcrunRecognitionParsesOnlyInspectedNativeLookupOptions() {
        let positive: [([String], [String])] = [
            (["xcodebuild", "-version"], []),
            (["--sdk", "macosx", "--run", "xcodebuild", "-version"], ["--sdk", "macosx"]),
            (["--verbose", "--toolchain", "XcodeDefault", "-r", "xcodebuild"], ["--toolchain", "XcodeDefault"]),
            (["--no-cache", "--log", "xcodebuild"], ["--no-cache"]),
            (["--kill-cache", "xcodebuild"], ["--no-cache"]),
        ]
        for (arguments, lookup) in positive {
            XCTAssertEqual(ExecutionJobService.xcodebuildLookupOptions(arguments: arguments), lookup)
        }
        for arguments in [
            [], ["--find", "xcodebuild"], ["--help", "xcodebuild"], ["--version"],
            ["swift", "xcodebuild"], ["--sdk"], ["--sdk", "--run", "xcodebuild"],
            ["--unknown", "xcodebuild"], ["xcodebuild -version"],
        ] {
            XCTAssertNil(ExecutionJobService.xcodebuildLookupOptions(arguments: arguments))
        }
    }

    func testVerifiedDirectXcodebuildGetsTheBoundedProfileWithoutChangingNativeArgv() async throws {
        try await withFixture(script: "printf fixture") { fixture in
            let resolution = try ProcessRunner(inheritEnvironment: false).run(
                executable: "/usr/bin/xcrun", arguments: ["--find", "xcodebuild"],
                environment: ProcessInfo.processInfo.environment, timeoutSec: 2, maximumOutputBytes: Int(PATH_MAX)
            )
            XCTAssertEqual(resolution.exitCode, 0)
            XCTAssertFalse(resolution.timedOut || resolution.stdoutTruncated || resolution.stderrTruncated)
            let native = resolution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let xcrunLink = fixture.projectRoot.appendingPathComponent("native-xcrun-link")
            try FileManager.default.createSymbolicLink(at: xcrunLink, withDestinationURL: URL(fileURLWithPath: "/usr/bin/xcrun"))
            let commands: [(URL, [String])] = [
                (URL(fileURLWithPath: "/usr/bin/xcrun"), ["xcodebuild", "-version"]),
                (URL(fileURLWithPath: "/usr/bin/xcrun"), ["--sdk", "macosx", "--run", "xcodebuild", "-version"]),
                (URL(fileURLWithPath: "/usr/bin/xcodebuild"), ["-version"]),
                (URL(fileURLWithPath: native), ["-version"]),
                (xcrunLink, ["xcodebuild", "-version"]),
            ]
            for (index, command) in commands.enumerated() {
                let request = RuntimeJobRequest(
                    kind: .process, profile: .directProcess, context: fixture.context,
                    executable: command.0, arguments: command.1, canonicalWorkingDirectory: fixture.projectRoot,
                    timeout: .seconds(10), replayClass: .readOnly, idempotencyKey: "direct-xcode-version-\(index)"
                )
                XCTAssertTrue(ExecutionJobService.isVerifiedNativeXcodebuild(request, environment: ProcessInfo.processInfo.environment, workingDirectory: fixture.projectRoot))
                let jobID = try await fixture.jobs.submit(request)
                let record = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(15))
                XCTAssertEqual(record.state, .completed)
                XCTAssertEqual(record.exitCode, 0)
                XCTAssertTrue(record.commandSummary.contains("file_size_profile=native_xcodebuild_sparse_cas_v1:file_size_bytes=34359738368"))
                let output = try await fixture.repository.output(jobID: jobID, stream: .stdout, context: fixture.context)
                XCTAssertTrue(output.inlineText.contains("Xcode "))
                let repeated = try await fixture.jobs.submitWithOutcome(request)
                XCTAssertEqual(repeated.jobID, jobID)
                XCTAssertTrue(repeated.reused)
            }
        }
    }

    func testFakeXcodeNamesLookupOnlyAndShellProgramsKeepGenericLimits() async throws {
        try await withFixture(script: "printf fixture") { fixture in
            for name in ["xcodebuild", "xcrun"] {
                let executable = fixture.projectRoot.appendingPathComponent(name)
                try Data("#!/bin/bash\nulimit -f\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                let request = RuntimeJobRequest(
                    kind: .process, profile: .directProcess, context: fixture.context,
                    executable: executable, arguments: ["xcodebuild", "-version"], canonicalWorkingDirectory: fixture.projectRoot,
                    timeout: .seconds(5), replayClass: .readOnly
                )
                XCTAssertFalse(ExecutionJobService.isVerifiedNativeXcodebuild(request, environment: ProcessInfo.processInfo.environment, workingDirectory: fixture.projectRoot))
                let jobID = try await fixture.jobs.submit(request)
                let record = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(8))
                XCTAssertEqual(record.state, .completed)
                XCTAssertFalse(record.commandSummary.contains("file_size_profile="))
                let output = try await fixture.repository.output(jobID: jobID, stream: .stdout, context: fixture.context)
                XCTAssertEqual(output.inlineText, "1048576\n")
            }
            for arguments in [["--find", "xcodebuild"], ["--help"], ["swift", "--version"]] {
                let request = RuntimeJobRequest(
                    kind: .process, profile: .directProcess, context: fixture.context,
                    executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments,
                    canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5), replayClass: .readOnly
                )
                XCTAssertFalse(ExecutionJobService.isVerifiedNativeXcodebuild(request, environment: ProcessInfo.processInfo.environment, workingDirectory: fixture.projectRoot))
            }
            let shell = RuntimeJobRequest(
                kind: .bash, profile: .bashNoProfile, context: fixture.context,
                script: "# /usr/bin/xcrun xcodebuild -version\nulimit -f", canonicalWorkingDirectory: fixture.projectRoot,
                timeout: .seconds(5), replayClass: .readOnly
            )
            XCTAssertFalse(ExecutionJobService.isVerifiedNativeXcodebuild(shell, environment: ProcessInfo.processInfo.environment, workingDirectory: fixture.projectRoot))
            let shellJob = try await fixture.jobs.submit(shell)
            let shellRecord = try await fixture.jobs.waitForTerminal(jobID: shellJob, context: fixture.context, maximumWait: .seconds(8))
            XCTAssertEqual(shellRecord.state, .completed)
            XCTAssertFalse(shellRecord.commandSummary.contains("file_size_profile="))
            let shellOutput = try await fixture.repository.output(jobID: shellJob, stream: .stdout, context: fixture.context)
            XCTAssertEqual(shellOutput.inlineText, "1048576\n")
            var unavailableEnvironment = ProcessInfo.processInfo.environment
            unavailableEnvironment["DEVELOPER_DIR"] = fixture.projectRoot.path
            let unresolved = RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: fixture.context,
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["xcodebuild", "-version"],
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(5), replayClass: .readOnly
            )
            XCTAssertFalse(ExecutionJobService.isVerifiedNativeXcodebuild(unresolved, environment: unavailableEnvironment, workingDirectory: fixture.projectRoot))
        }
    }

    func testExplicitFileCapAlsoAppliesToRecognizedDirectXcodebuild() async throws {
        try await withFixture(script: "printf fixture", fileCap: 1_048_576) { fixture in
            let request = RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: fixture.context,
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["xcodebuild", "-version"],
                canonicalWorkingDirectory: fixture.projectRoot, timeout: .seconds(10), replayClass: .readOnly
            )
            let jobID = try await fixture.jobs.submit(request)
            let record = try await fixture.jobs.waitForTerminal(jobID: jobID, context: fixture.context, maximumWait: .seconds(15))
            XCTAssertEqual(record.state, .completed)
            XCTAssertTrue(record.commandSummary.contains("file_size_profile=native_xcodebuild_sparse_cas_v1:file_size_bytes=1048576"))
        }
    }

    func testForeignRunRowWinningTheAdmissionTransactionNeverEmitsSuccessfulDurableReceipt() async throws {
        try await withFixture(script: "printf admitted") { fixture in
            let firstRun = try await fixture.autonomousRunContext()
            let arguments: [String: Any] = ["query": "version", "idempotency_key": "concurrent-admission"]
            let submittedOptional = try await fixture.pack.handle(name: "xcode.discover", arguments: arguments, context: firstRun)
            let submitted = try XCTUnwrap(submittedOptional)
            let firstJob = try Self.jobID(submitted)
            let winnerBefore = try await fixture.jobs.waitForTerminal(jobID: firstJob, context: firstRun, maximumWait: .seconds(5))
            XCTAssertEqual(winnerBefore.state, .completed)
            XCTAssertEqual(winnerBefore.exitCode, 0)
            let otherRun = try await fixture.autonomousRunContext()
            let command = try XcodeCLIService.command(tool: "xcode.discover", arguments: arguments, context: otherRun)
            let request = RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: otherRun,
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: command.arguments,
                canonicalWorkingDirectory: command.workingDirectory, timeout: .seconds(command.timeoutSeconds),
                replayClass: .readOnly, idempotencyKey: command.idempotencyKey
            )
            let observed = RuntimeBlockingResult<RuntimeJobRecord>()
            let successfulReceipt = RuntimeBlockingResult<RuntimeJobRecord>()
            // A foreign row that wins before admission must be rejected before
            // the repository publishes any durable receipt to the losing run.
            do {
                _ = try await fixture.repository.createJob(
                    jobID: UUID(), request: request, commandSummary: "losing-admission", timeoutSeconds: 60,
                    requestArtifactRelativePath: nil,
                    commitObserver: { record in
                        XcodeCLIService.observePersistence(record, context: otherRun, receipt: observed) { record in
                            successfulReceipt.store(.success(record))
                        }
                    }
                )
                XCTFail("Foreign admission must reject the existing owner's job")
            } catch {
                XCTAssertEqual(error as? RuntimeJobError, .jobScopeMismatch(firstJob))
            }
            XCTAssertNil(observed.take())
            XCTAssertNil(successfulReceipt.take())
            let winner = try await fixture.jobs.status(jobID: firstJob, context: firstRun)
            XCTAssertEqual(winner, winnerBefore)
            let jobs = try await fixture.jobs.list(context: fixture.context)
            XCTAssertEqual(jobs, [winnerBefore])

            XcodeCLIService.observePersistence(winner, context: otherRun, receipt: observed) { record in
                successfulReceipt.store(.success(record))
            }
            let outcome = try XCTUnwrap(observed.take())
            XCTAssertThrowsError(try outcome.get()) { error in
                XCTAssertEqual((error as? RuntimeJobError)?.code, "runtime_job_scope_mismatch")
            }
            XCTAssertNil(successfulReceipt.take())
            let ownerReceipt = RuntimeBlockingResult<RuntimeJobRecord>()
            XcodeCLIService.observePersistence(winner, context: fixture.context, receipt: ownerReceipt) { record in
                successfulReceipt.store(.success(record))
            }
            XCTAssertEqual(try XCTUnwrap(ownerReceipt.take()).get().jobID, firstJob)
            XCTAssertEqual(try XCTUnwrap(successfulReceipt.take()).get().jobID, firstJob)
        }
    }

    func testReceiptBudgetCeilingIncludesAllStatesExitsMatchesAndEscapedCanonicalPaths() throws {
        let context = Self.context()
        let escaped = String(repeating: "\"\\", count: 90)
        let cases: [(String, [String: Any])] = [
            ("xcode.discover", ["query": "version", "timeout_sec": 86_400]),
            ("xcode.run", ["action": "build", "workspace": "Fixture.xcworkspace", "scheme": "Fixture",
                           "destination": "platform=macOS", "timeout_sec": 86_400,
                           "derived_data_path": "Data-\(escaped)", "result_bundle_path": "Result-\(escaped).xcresult"]),
            ("xcode.result", ["query": "test_summary", "result_bundle_path": "Result-\(escaped).xcresult", "timeout_sec": 86_400]),
            ("xcode.debug", ["executable": "/usr/bin/true", "commands": ["version"], "timeout_sec": 86_400]),
            ("xcode.simulator", ["query": "devices", "timeout_sec": 86_400]),
        ]
        for (name, arguments) in cases {
            let command = try XcodeCLIService.command(tool: name, arguments: arguments, context: context)
            let ceiling = try XcodeCLIToolPack.maximumReceiptResultBytes(command: command, context: context)
            var largestObserved = 0
            let exits: [Int32?] = [nil, Int32.min, Int32.max, 0, 65, -1]
            let matches: [Bool?] = [nil, false, true]
            for state in RuntimeJobState.allCases {
                for exit in exits {
                    let record = RuntimeJobRecord(
                        jobID: UUID(), runID: context.runID, projectID: context.projectID,
                        projectGeneration: context.projectGeneration, runtimeKind: .process,
                        executionProfile: .directProcess, replayClass: command.replayClass,
                        idempotencyKey: command.idempotencyKey, state: state,
                        canonicalWorkingDirectory: command.workingDirectory, commandSummary: "receipt-wire-fixture",
                        timeoutSeconds: command.timeoutSeconds, exitCode: exit, outputArtifactID: nil,
                        outputBytes: 0, processIdentifier: nil, processGroupIdentifier: nil,
                        errorCode: nil, errorSummary: nil, createdAt: "1970-01-01T00:00:00Z",
                        startedAt: nil, completedAt: nil, updatedAt: "1970-01-01T00:00:00Z"
                    )
                    for match in matches {
                        var payload = XcodeCLIToolPack.receipt(record, command: command)
                        if let match { payload["idempotency_match"] = match }
                        let result = ToolResult.success(payload)
                        let bytes = try JSONSupport.canonicalJSON([
                            "ok": result.ok, "is_error": result.isError, "payload": result.payload,
                        ]).utf8.count
                        XCTAssertLessThanOrEqual(bytes, ceiling, "\(name), \(state), \(String(describing: exit)), \(String(describing: match))")
                        largestObserved = max(largestObserved, bytes)
                    }
                }
            }
            XCTAssertEqual(largestObserved, ceiling, "The measured full receipt ceiling must cover the actual wire variants")
        }
    }

    func testReceiptBudgetExactBoundaryPreservesNativeFailureAndSameIntentReplay() async throws {
        for delta in [-1, 0, 1] {
            try await withFixture(script: "printf 'native boundary failed\\n' >&2; exit 65") { fixture in
                let arguments: [String: Any] = [
                    "action": "build", "workspace": "Fixture.xcworkspace", "scheme": "Fixture",
                    "destination": "platform=macOS", "timeout_sec": 5,
                    "derived_data_path": "Data \"quoted\" \\ folder",
                    "result_bundle_path": "Result \"quoted\" \\ folder.xcresult",
                    "idempotency_key": "receipt-exact-boundary"
                ]
                let template = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: fixture.context)
                let required = try XcodeCLIToolPack.maximumReceiptResultBytes(command: template, context: fixture.context)
                let budget = required + delta
                let context = try await fixture.autonomousRunContext(maximumInlineOutputBytes: budget)
                XCTAssertEqual(context.authorizationScope.maximumInlineOutputBytes, budget)
                let command = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: context)
                XCTAssertEqual(try XcodeCLIToolPack.maximumReceiptResultBytes(command: command, context: context), required)
                let resultValue = try await fixture.pack.handle(name: "xcode.run", arguments: arguments, context: context)
                let result = try XCTUnwrap(resultValue)
                let encoded = try JSONSupport.canonicalJSON([
                    "ok": result.ok, "is_error": result.isError, "payload": result.payload,
                ])
                XCTAssertLessThanOrEqual(encoded.utf8.count, budget)
                if delta < 0 {
                    XCTAssertFalse(result.ok)
                    XCTAssertTrue(result.isError)
                    XCTAssertEqual(result.payload["code"] as? String, "invalid_request")
                    XCTAssertNotNil((result.payload["message"] as? String)?.range(of: "budget", options: .caseInsensitive))
                    let jobs = try await fixture.jobs.list(context: fixture.context)
                    XCTAssertTrue(jobs.isEmpty, "One byte below the full receipt ceiling must reject before admission")
                    return
                }
                XCTAssertTrue(result.ok)
                XCTAssertFalse(result.isError)
                XCTAssertEqual(result.payload["idempotency_match"] as? Bool, false)
                XCTAssertEqual(result.payload["result_bundle_path"] as? String, command.resultBundlePath)
                XCTAssertEqual(result.payload["derived_data_path"] as? String, command.derivedDataPath)
                XCTAssertEqual(result.payload["native_tool"] as? String, "xcodebuild")
                XCTAssertEqual(result.payload["submission_only"] as? Bool, true)
                XCTAssertEqual(result.payload["project_id"] as? String, context.projectID.description)
                XCTAssertEqual(result.payload["project_generation"] as? UInt64, context.projectGeneration.rawValue)
                XCTAssertEqual(result.payload["timeout_seconds"] as? Int, 5)
                var expectedFields: Set<String> = [
                    "ok", "job_id", "state", "project_id", "project_generation", "submission_only",
                    "native_tool", "timeout_seconds", "result_bundle_path", "derived_data_path", "idempotency_match"
                ]
                if result.payload["exit_code"] != nil { expectedFields.insert("exit_code") }
                XCTAssertEqual(Set(result.payload.keys), expectedFields)
                let jobID = try Self.jobID(result)
                let terminal = try await fixture.jobs.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
                XCTAssertEqual(terminal.state, .failed)
                XCTAssertEqual(terminal.exitCode, 65)
                let output = try await fixture.jobs.readOutput(jobID: jobID, stream: .stderr, offset: 0, limit: 256, context: context)
                XCTAssertTrue(output.eof)
                XCTAssertFalse(output.artifactTruncated)
                XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "native boundary failed\n")
                let replayValue = try await fixture.pack.handle(name: "xcode.run", arguments: arguments, context: context)
                let replay = try XCTUnwrap(replayValue)
                XCTAssertTrue(replay.ok)
                XCTAssertFalse(replay.isError)
                XCTAssertEqual(try Self.jobID(replay), jobID)
                XCTAssertEqual(replay.payload["idempotency_match"] as? Bool, true)
                XCTAssertEqual(replay.payload["state"] as? String, "failed")
                XCTAssertEqual(replay.payload["exit_code"] as? Int32, 65)
                expectedFields.insert("exit_code")
                XCTAssertEqual(Set(replay.payload.keys), expectedFields)
                var expectedReplay = XcodeCLIToolPack.receipt(terminal, command: command)
                expectedReplay["idempotency_match"] = true
                let expectedReplayResult = ToolResult.success(expectedReplay)
                XCTAssertEqual(try JSONSupport.canonicalJSON(replay.payload), try JSONSupport.canonicalJSON(expectedReplayResult.payload))
                let replayEncoded = try JSONSupport.canonicalJSON([
                    "ok": replay.ok, "is_error": replay.isError, "payload": replay.payload,
                ])
                XCTAssertLessThanOrEqual(replayEncoded.utf8.count, budget)
                let jobs = try await fixture.jobs.list(context: fixture.context)
                XCTAssertEqual(jobs, [terminal], "A fitting replay must preserve the native failure and reuse one durable job")
            }
        }
    }

    func testManagedXcodeCanonicalReceiptFitsBeforeAdmissionOrCompletesDurably() async throws {
        try await withFixture(script: "printf receipt-budget-native-marker") { fixture in
            let budget = 1_024
            var cwd = fixture.projectRoot
            for index in 0..<3 {
                cwd.appendPathComponent(String(format: "segment-%02d-", index) + String(repeating: "c", count: 130))
            }
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            cwd = RuntimePathCanonicalizer.canonicalExistingURL(cwd)
            XCTAssertGreaterThan(cwd.path.utf8.count, 450)
            XCTAssertLessThan(cwd.path.utf8.count, Int(PATH_MAX) - 100)
            let sessionID = "xcode-canonical-receipt-budget"
            let run = try await fixture.control.createAutonomousRun(AutonomousRunRequest(
                projectID: fixture.context.projectID, projectGeneration: fixture.context.projectGeneration,
                mission: "Keep the native admission receipt inside the actual managed result budget",
                providerID: "xcode-budget-fixture", modelKey: "xcode-budget-fixture",
                specification: AutonomousRunSpecification(allowedTools: XcodeCLIToolPack.names, completionGates: ["bounded-native-receipt"]),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [fixture.projectRoot], allowedTools: Set(XcodeCLIToolPack.names),
                    networkAllowed: false, maximumInlineOutputBytes: budget
                )
            ))
            let lease = try await fixture.control.acquireRunLease(
                runID: run.runID, ownerID: sessionID,
                policy: RunLeasePolicy(duration: 120, renewalInterval: 10, maximumDuration: 300)
            )
            let rootResponseID = "\(sessionID)-root"
            try await fixture.control.reserveProviderSession(ProviderSessionIntent(
                sessionID: sessionID, runID: run.runID, projectID: run.projectID,
                projectGeneration: run.projectGeneration, providerID: "xcode-budget-fixture",
                adapterID: "xcode-budget-fixture", modelKey: "xcode-budget-fixture",
                providerResponseID: rootResponseID, idempotencyKey: "\(sessionID)-session"
            ), lease: lease)
            let turn = ProviderTurnIntent(
                runID: run.runID, sessionID: sessionID, projectID: run.projectID,
                projectGeneration: run.projectGeneration, kind: .normalContinuation,
                idempotencyKey: "\(sessionID)-turn", previousResponseID: rootResponseID,
                inputSHA256: String(repeating: "e", count: 64)
            )
            _ = try await fixture.control.persistProviderTurnIntent(turn, lease: lease)
            let context = try await fixture.control.invocationContext(
                for: ProjectBindingOwner(kind: .providerSession, id: sessionID), clientID: ClientID(sessionID)
            )
            XCTAssertEqual(context.runID, run.runID)
            XCTAssertEqual(context.authorizationScope.maximumInlineOutputBytes, budget)
            let arguments: [String: Any] = [
                "action": "build", "cwd": cwd.path, "workspace": "Fixture.xcworkspace",
                "scheme": "Fixture", "destination": "platform=macOS", "timeout_sec": 5,
                "derived_data_path": "DerivedData", "result_bundle_path": "Result.xcresult",
                "idempotency_key": "canonical-receipt-budget"
            ]
            XCTAssertLessThan(try JSONSupport.canonicalJSON(arguments).utf8.count, budget - 64)
            let command = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: context)
            let expectedBundle = try XCTUnwrap(command.resultBundlePath)
            let expectedDerivedData = try XCTUnwrap(command.derivedDataPath)
            let requiredPathEnvelopeBytes = try JSONSupport.canonicalJSON([
                "ok": true, "is_error": false,
                "payload": ["result_bundle_path": expectedBundle, "derived_data_path": expectedDerivedData]
            ]).utf8.count
            XCTAssertGreaterThan(requiredPathEnvelopeBytes, budget, "The complete mandatory path fields already exceed this valid result budget")
            let executor = CanonicalReceiptBudgetXcodeExecutor(
                service: XcodeCLIService(jobs: fixture.jobs, xcrunURL: fixture.projectRoot.appendingPathComponent("fixture-xcrun"))
            )
            let memory = ProjectMemoryService(paths: AppPaths(home: fixture.root.appendingPathComponent("budget-memory-home")))
            defer { memory.closeAll() }
            let broker = ToolInvocationBroker(
                repository: fixture.control, executor: executor,
                classifier: StaticToolReplayClassifier(classifications: ProductionToolReplayCatalog.classifications),
                reconciler: ProductionToolInvocationReconciler(controlPlane: fixture.control, runtimeJobs: fixture.repository, memory: memory, xcodeExecutable: fixture.projectRoot.appendingPathComponent("fixture-xcrun"))
            )
            let call = BrokeredToolCall(
                providerCallID: "\(sessionID)-call", toolName: "xcode.run", arguments: arguments,
                idempotencyKey: "canonical-receipt-budget"
            )
            var priorEncoded: String?
            for attempt in 0..<2 {
                do {
                    let result = try await broker.invoke(call, turnID: turn.turnID, context: context, lease: lease)
                    let encoded = try JSONSupport.canonicalJSON(["ok": result.ok, "is_error": result.isError, "payload": result.payload])
                    XCTAssertLessThanOrEqual(encoded.utf8.count, budget)
                    let storedValue = try await fixture.control.toolInvocation(sessionID: sessionID, providerCallID: call.providerCallID)
                    let stored = try XCTUnwrap(storedValue)
                    XCTAssertEqual(stored.state, .completed)
                    XCTAssertEqual(stored.resultSummary, encoded)
                    XCTAssertEqual(stored.resultSHA256, JSONSupport.sha256Hex(encoded))
                    XCTAssertNil(stored.lastErrorCode)
                    if let priorEncoded { XCTAssertEqual(encoded, priorEncoded) }
                    priorEncoded = encoded
                    let jobs = try await fixture.jobs.list(context: context)
                    if result.ok {
                        XCTAssertFalse(result.isError)
                        XCTAssertEqual(jobs.count, 1)
                        let jobID = try Self.jobID(result)
                        let terminal = try await fixture.jobs.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
                        XCTAssertEqual(terminal.state, .completed)
                        XCTAssertEqual(terminal.exitCode, 0)
                        XCTAssertEqual(result.payload["result_bundle_path"] as? String, expectedBundle)
                        XCTAssertEqual(result.payload["derived_data_path"] as? String, expectedDerivedData)
                        XCTAssertEqual(result.payload["native_tool"] as? String, "xcodebuild")
                        XCTAssertEqual(result.payload["submission_only"] as? Bool, true)
                        XCTAssertEqual(result.payload["project_id"] as? String, context.projectID.description)
                        XCTAssertEqual(result.payload["project_generation"] as? UInt64, context.projectGeneration.rawValue)
                    } else {
                        XCTAssertTrue(result.isError)
                        XCTAssertEqual(result.payload["code"] as? String, "invalid_request")
                        XCTAssertNotNil((result.payload["message"] as? String)?.range(of: "budget", options: .caseInsensitive))
                        XCTAssertTrue(jobs.isEmpty, "An explicit receipt-budget rejection must precede native admission")
                    }
                } catch {
                    let stored = try await fixture.control.toolInvocation(sessionID: sessionID, providerCallID: call.providerCallID)
                    let jobs = try await fixture.jobs.list(context: context)
                    XCTAssertLessThanOrEqual(jobs.count, 1, "An ambiguous native receipt must not cause duplicate admission on replay")
                    for job in jobs {
                        let terminal = try await fixture.jobs.waitForTerminal(jobID: job.jobID, context: context, maximumWait: .seconds(5))
                        XCTAssertEqual(terminal.state, .completed)
                        XCTAssertEqual(terminal.exitCode, 0)
                        let output = try await fixture.jobs.readOutput(jobID: job.jobID, stream: .stdout, offset: 0, limit: 256, context: context)
                        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), "receipt-budget-native-marker")
                        XCTAssertFalse(output.artifactTruncated)
                    }
                    XCTAssertEqual(stored?.state, .completed, "Attempt \(attempt) left a committed native admission without its bounded broker receipt: \(error)")
                    XCTAssertNil(stored?.lastErrorCode)
                    XCTAssertTrue(jobs.isEmpty, "A thrown receipt-budget error concealed \(jobs.count) admitted native job(s)")
                    XCTFail("Actual managed Xcode receipt failed at budget \(budget), attempt \(attempt): \(error)")
                }
            }
            _ = try await fixture.control.releaseRunLease(lease)
        }
    }

    // Uses the same native job owner, durable-receipt bridge and bounded wait as
    // XcodeCLISynchronousToolPack. Only the existing fake xcrun seam is selected.
    private final class CanonicalReceiptBudgetXcodeExecutor: ToolExecuting {
        private let service: XcodeCLIService
        init(service: XcodeCLIService) { self.service = service }
        var toolNames: [String] { XcodeCLIToolPack.names }
        func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
            .failure(code: "project_context_required", message: "Budget fixture requires its persisted managed context")
        }
        func call(name: String, arguments: [String: Any], context: ToolInvocationContext) throws -> ToolResult {
            let serialized = try SerializedToolArguments(arguments)
            let receipt = RuntimeBlockingResult<ToolResult>()
            let pack = XcodeCLIToolPack(service: service, durableResultObserver: { receipt.store(.success($0)) })
            return try RuntimeJobSynchronousToolPack.wait(
                timeoutSeconds: RuntimeJobSynchronousToolPack.controlTimeoutSeconds, cancellation: nil,
                committedResultWins: true, committedReceipt: receipt
            ) {
                try await pack.handle(name: name, arguments: try serialized.decoded(), context: context)
                    ?? .failure(code: "unknown_tool", message: "Unknown budget fixture tool")
            }
        }
    }

    private static func invocation(call: BrokeredToolCall, context: ToolInvocationContext) throws -> ToolInvocationRecord {
        let timestamp = ISO8601.string(from: Date())
        return ToolInvocationRecord(
            invocationID: UUID(), turnID: UUID(), runID: try XCTUnwrap(context.runID), sessionID: "xcode-reconciliation-fixture",
            projectID: context.projectID, projectGeneration: context.projectGeneration, providerCallID: call.providerCallID,
            toolName: call.toolName, replayClass: .reconciled, idempotencyKey: call.idempotencyKey,
            argumentsSHA256: JSONSupport.sha256Hex(try JSONSupport.canonicalJSON(call.arguments)), reconciliationDescriptor: nil,
            state: .ambiguous, resultSHA256: nil, resultSummary: nil, lastErrorCode: "manager_interrupted", lastErrorSummary: "Fixture interruption",
            createdAt: timestamp, updatedAt: timestamp
        )
    }

    func testTypedNativeTestSummarySatisfiesTestsWithoutInventingAProjectBuild() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            try Self.writeCompletionSummary(Self.passingCompletionSummary, fixture: fixture)
            try Data(String(repeating: "n", count: 1_500).utf8).write(to: fixture.projectRoot.appendingPathComponent("test-output.txt"))
            let harness = try await Self.nativeCompletionHarness(fixture)
            defer { harness.memory.closeAll() }
            let test = try await Self.completionCall("one-test", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
            let stdout = try await fixture.repository.output(jobID: test.jobID, stream: .stdout, context: harness.context)
            XCTAssertTrue(stdout.inlineTruncated, "A preview may truncate while the retained native stream is complete")
            XCTAssertFalse(stdout.artifactTruncated)
            XCTAssertEqual(stdout.byteCount, stdout.retainedByteCount)
            _ = try await Self.completionCall("one-summary", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
            let beforeBuild = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
            XCTAssertFalse(beforeBuild.passed)
            XCTAssertTrue(beforeBuild.summary.contains("project-build"))
            XCTAssertFalse(beforeBuild.summary.contains("project-tests"), "Actual nonzero passing native tests discharge only the test obligation")
            _ = try await Self.completionCall("one-build", tool: "xcode.run", arguments: Self.completionArguments(.build, bundle: "Build.xcresult"), harness: harness, fixture: fixture)
            let complete = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
            XCTAssertTrue(complete.passed, complete.summary)
            let beforeReplay = try await fixture.jobs.list(context: harness.context)
            _ = try await Self.completionCall("same-producer-summary-replay", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
            let afterReplay = try await fixture.jobs.list(context: harness.context)
            XCTAssertEqual(beforeReplay, afterReplay, "An unchanged producer replay must reuse the same native summary job")
            let replayed = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
            XCTAssertTrue(replayed.passed, replayed.summary)
            _ = try await fixture.control.releaseRunLease(harness.lease)
        }
    }

    func testTypedNativeSummaryRejectsZeroFailedSkippedMalformedAndNonIntegerCounts() async throws {
        let cases = [
            ("zero", #"{"result":"Passed","totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0,"expectedFailures":0}"#),
            ("failed", #"{"result":"Failed","totalTestCount":1,"passedTests":0,"failedTests":1,"skippedTests":0,"expectedFailures":0}"#),
            ("skipped", #"{"result":"Passed","totalTestCount":1,"passedTests":0,"failedTests":0,"skippedTests":1,"expectedFailures":0}"#),
            ("malformed", "{"),
            ("boolean", #"{"result":"Passed","totalTestCount":true,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}"#),
            ("fraction", #"{"result":"Passed","totalTestCount":1.5,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}"#)
        ]
        for (name, summary) in cases {
            try await withFixture(script: Self.nativeCompletionScript) { fixture in
                try Self.writeCompletionSummary(summary, fixture: fixture)
                let harness = try await Self.nativeCompletionHarness(fixture)
                defer { harness.memory.closeAll() }
                _ = try await Self.completionCall(name + "-build", tool: "xcode.run", arguments: Self.completionArguments(.build, bundle: "Build.xcresult"), harness: harness, fixture: fixture)
                _ = try await Self.completionCall(name + "-test", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
                _ = try await Self.completionCall(name + "-summary", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
                let rejected = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
                XCTAssertFalse(rejected.passed, name)
                XCTAssertTrue(rejected.summary.contains("project-tests"), name + ": " + rejected.summary)
                XCTAssertFalse(rejected.summary.contains("project-build"), name + ": a rejected result must not erase an actual build")
                _ = try await fixture.control.releaseRunLease(harness.lease)
            }
        }
    }

    func testTypedSummaryBeforeItsTestInEvidenceOrderStillUsesTheExactProducer() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            try Self.writeCompletionSummary(Self.passingCompletionSummary, fixture: fixture)
            let harness = try await Self.nativeCompletionHarness(fixture)
            defer { harness.memory.closeAll() }
            _ = try await Self.completionCall("ordered-build", tool: "xcode.run", arguments: Self.completionArguments(.build, bundle: "Build.xcresult"), harness: harness, fixture: fixture)
            _ = try await Self.completionCall("ordered-test", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
            _ = try await Self.completionCall("ordered-summary", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
            let rows = try await fixture.control.toolInvocations(runID: harness.run.runID, limit: 100)
            let summary = try XCTUnwrap(rows.first { $0.toolName == "xcode.result" })
            let test = try XCTUnwrap(rows.first { $0.providerCallID == "ordered-test" })
            let build = try XCTUnwrap(rows.first { $0.providerCallID == "ordered-build" })
            var accumulator = ProjectInstructionCompletionGate.EvidenceAccumulator(run: harness.run)
            let reversed = [summary, test, build]
            try accumulator.consume(reversed)
            let deadline = ContinuousClock().now.advanced(by: .seconds(10))
            try await accumulator.consumeNativeXcode(reversed, repository: fixture.control, jobs: fixture.jobs, deadline: deadline)
            try await accumulator.finishNativeXcode(repository: fixture.control, jobs: fixture.jobs, deadline: deadline)
            let result = accumulator.result()
            XCTAssertTrue(result.passed, "Whole-second repository UUID ordering must not discard a valid bound summary: \(result.summary)")
            _ = try await fixture.control.releaseRunLease(harness.lease)
        }
    }

    func testCachedNativeSummaryCannotRebindToANewerTestAtTheSameBundle() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            try Self.writeCompletionSummary(Self.passingCompletionSummary, fixture: fixture)
            try Data("producer-A".utf8).write(to: fixture.projectRoot.appendingPathComponent("test-output.txt"))
            let harness = try await Self.nativeCompletionHarness(fixture)
            defer { harness.memory.closeAll() }
            _ = try await Self.completionCall("cached-build", tool: "xcode.run", arguments: Self.completionArguments(.build, bundle: "Build.xcresult"), harness: harness, fixture: fixture)
            let first = try await Self.completionCall("producer-A", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
            let originalSummary = try await Self.completionCall("summary-A", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
            try Data("Executed 0 tests. producer-B".utf8).write(to: fixture.projectRoot.appendingPathComponent("test-output.txt"))
            var laterArguments = Self.completionArguments(.testWithoutBuilding)
            laterArguments["idempotency_key"] = "producer-B"
            let later = try await Self.completionCall("producer-B", tool: "xcode.run", arguments: laterArguments, harness: harness, fixture: fixture)
            XCTAssertNotEqual(first.jobID, later.jobID)
            let reused = try await Self.completionCall("summary-B-reuses-A-key", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
            XCTAssertEqual(originalSummary.jobID, reused.jobID, "The runtime's existing idempotency contract remains intact")
            let invocationOptional = try await fixture.control.toolInvocation(sessionID: harness.sessionID, providerCallID: "summary-B-reuses-A-key")
            let invocation = try XCTUnwrap(invocationOptional)
            let descriptor = try XCTUnwrap(ProjectInstructionCompletionGate.decodedXcodeDescriptor(invocation))
            XCTAssertNil(descriptor.test_job_id, "An existing A summary has no authority to bind B")
            let result = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
            XCTAssertFalse(result.passed)
            XCTAssertTrue(result.summary.contains("project-tests") || result.summary.hasPrefix("Typed Xcode completion evidence"), result.summary)
            _ = try await fixture.control.releaseRunLease(harness.lease)
        }
    }

    func testNativeQueuedFailedAndTruncatedJobsCannotUseAnOlderPassingTestProof() async throws {
        for failure in ["queued", "exit65", "truncated"] {
            try await withFixture(script: Self.nativeCompletionScript) { fixture in
                try Self.writeCompletionSummary(Self.passingCompletionSummary, fixture: fixture)
                let harness = try await Self.nativeCompletionHarness(fixture)
                defer { harness.memory.closeAll() }
                _ = try await Self.completionCall("old-build", tool: "xcode.run", arguments: Self.completionArguments(.build, bundle: "Build.xcresult"), harness: harness, fixture: fixture)
                _ = try await Self.completionCall("old-test", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
                _ = try await Self.completionCall("old-summary", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
                var newer = Self.completionArguments(.testWithoutBuilding)
                newer["idempotency_key"] = "newer-" + failure
                if failure == "queued" {
                    try Data("1".utf8).write(to: fixture.projectRoot.appendingPathComponent("test-delay.txt"))
                    let result = try await harness.broker.invoke(
                        BrokeredToolCall(providerCallID: "newer-queued", toolName: "xcode.run", arguments: newer, idempotencyKey: "newer-queued"),
                        turnID: harness.turn.turnID, context: harness.context, lease: harness.lease
                    )
                    let jobID = try Self.jobID(result)
                    let rejected = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
                    XCTAssertFalse(rejected.passed)
                    let terminal = try await fixture.jobs.waitForTerminal(jobID: jobID, context: harness.context, maximumWait: .seconds(5))
                    XCTAssertEqual(terminal.exitCode, 0)
                } else {
                    if failure == "exit65" {
                        try Data("65".utf8).write(to: fixture.projectRoot.appendingPathComponent("test-exit.txt"))
                    } else {
                        try Data(String(repeating: "x", count: 6_000).utf8).write(to: fixture.projectRoot.appendingPathComponent("test-output.txt"))
                    }
                    let terminal = try await Self.completionCall("newer-" + failure, tool: "xcode.run", arguments: newer, harness: harness, fixture: fixture, expectedExit: failure == "exit65" ? 65 : 0)
                    if failure == "truncated" {
                        let output = try await fixture.repository.output(jobID: terminal.jobID, stream: .stdout, context: harness.context)
                        XCTAssertTrue(output.artifactTruncated)
                        XCTAssertLessThan(output.retainedByteCount, output.byteCount)
                        var query = Self.completionSummaryArguments()
                        query["idempotency_key"] = "newer-truncated-summary"
                        _ = try await Self.completionCall("newer-truncated-summary", tool: "xcode.result", arguments: query, harness: harness, fixture: fixture)
                    }
                    let rejected = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
                    XCTAssertFalse(rejected.passed, failure)
                    XCTAssertTrue(rejected.summary.contains("project-tests") || rejected.summary.hasPrefix("Typed Xcode completion evidence"), failure + ": " + rejected.summary)
                }
                _ = try await fixture.control.releaseRunLease(harness.lease)
            }
        }
    }

    func testTypedSubmissionAndReconcileRejectRawSameKeyCommandCollisionButRetainLegacyReplay() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            let context = try await fixture.autonomousRunContext()
            let arguments = Self.completionArguments(.testWithoutBuilding)
            let command = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: context)
            let key = try XCTUnwrap(command.idempotencyKey)
            let rawID = try await fixture.jobs.submit(RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: context,
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: Array(repeating: "raw-echo-not-xcode", count: command.arguments.count),
                canonicalWorkingDirectory: command.workingDirectory, timeout: .seconds(5),
                maximumInlineOutputBytes: 1_024, replayClass: .readOnly, idempotencyKey: key
            ))
            let raw = try await fixture.jobs.waitForTerminal(jobID: rawID, context: context, maximumWait: .seconds(5))
            XCTAssertEqual(raw.exitCode, 0)
            XCTAssertNotNil(ExecutionJobService.storedCommandFingerprint(raw.commandSummary))
            let receipt = RuntimeBlockingResult<ToolResult>()
            let pack = XcodeCLIToolPack(service: XcodeCLIService(jobs: fixture.jobs), durableResultObserver: { receipt.store(.success($0)) })
            let resultOptional = try await pack.handle(name: "xcode.run", arguments: arguments, context: context)
            let result = try XCTUnwrap(resultOptional)
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "invalid_request")
            XCTAssertNil(receipt.take(), "A mismatched raw row cannot emit a typed successful durable receipt")
            let memory = ProjectMemoryService(paths: AppPaths(home: fixture.root.appendingPathComponent("native-collision-memory")))
            defer { memory.closeAll() }
            let reconciler = ProductionToolInvocationReconciler(controlPlane: fixture.control, runtimeJobs: fixture.repository, memory: memory)
            let call = BrokeredToolCall(providerCallID: "raw-collision", toolName: "xcode.run", arguments: arguments)
            let outcome = try await reconciler.reconcile(invocation: Self.invocation(call: call, context: context), call: call, context: context)
            if case .unresolved = outcome {} else { XCTFail("A new mismatched native fingerprint cannot be synthesized into a typed receipt") }
            let records = try await fixture.jobs.list(context: context)
            XCTAssertEqual(records, [raw])
            var legacyArguments = arguments
            legacyArguments["idempotency_key"] = "legacy-native-compatible"
            let legacyCommand = try XcodeCLIService.command(tool: "xcode.run", arguments: legacyArguments, context: context)
            let legacyID = UUID()
            let legacyRequest = RuntimeJobRequest(
                kind: .process, profile: .directProcess, context: context, executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: legacyCommand.arguments, canonicalWorkingDirectory: legacyCommand.workingDirectory,
                timeout: .seconds(5), replayClass: .readOnly, idempotencyKey: legacyCommand.idempotencyKey
            )
            _ = try await fixture.repository.createJob(
                jobID: legacyID, request: legacyRequest,
                commandSummary: "direct_process:xcrun:argv=\(legacyCommand.arguments.count):script_bytes=0",
                timeoutSeconds: 5, requestArtifactRelativePath: nil
            )
            _ = try await fixture.repository.complete(jobID: legacyID, terminalState: .failed, exitCode: 65, outputs: [], artifactID: nil, expectedContext: context)
            let legacyCall = BrokeredToolCall(providerCallID: "legacy-replay", toolName: "xcode.run", arguments: legacyArguments)
            let legacyOutcome = try await reconciler.reconcile(invocation: Self.invocation(call: legacyCall, context: context), call: legacyCall, context: context)
            if case .completed(let legacyResult) = legacyOutcome {
                XCTAssertTrue(legacyResult.ok)
                XCTAssertEqual(try Self.jobID(legacyResult), legacyID)
                XCTAssertEqual(legacyResult.payload["state"] as? String, "failed")
                XCTAssertEqual(legacyResult.payload["exit_code"] as? Int32, 65)
                XCTAssertEqual(legacyResult.payload["submission_only"] as? Bool, true)
            } else { XCTFail("Historical metadata-less native receipts must remain replayable") }
            let legacyRecord = try await fixture.repository.job(legacyID, context: context)
            XCTAssertNil(ExecutionJobService.storedCommandFingerprint(legacyRecord.commandSummary))
            XCTAssertFalse(ProjectInstructionCompletionGate.nativeFileSizeAdmissionMatches(legacyRecord.commandSummary))
        }
    }



    func testTypedCompletionRejectsUnknownReadErrorAndForcedProducerEnds() async throws {
        for reason in ["unknown", "read_error", "forced_close"] {
            try await withFixture(script: Self.nativeCompletionScript) { fixture in
                try Self.writeCompletionSummary(Self.passingCompletionSummary, fixture: fixture)
                let harness = try await Self.nativeCompletionHarness(fixture)
                defer { harness.memory.closeAll() }
                _ = try await Self.completionCall("build", tool: "xcode.run", arguments: Self.completionArguments(.build, bundle: "Build.xcresult"), harness: harness, fixture: fixture)
                let test = try await Self.completionCall("test", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
                _ = try await Self.completionCall("summary", tool: "xcode.result", arguments: Self.completionSummaryArguments(), harness: harness, fixture: fixture)
                let baseline = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
                XCTAssertTrue(baseline.passed, baseline.summary)
                let databaseURL = await fixture.repository.databaseURL
                var database: OpaquePointer?
                guard sqlite3_open_v2(databaseURL.path, &database,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
                    if let database { sqlite3_close(database) }
                    throw RuntimeJobError.storageFailure("could not open owned producer evidence control")
                }
                defer { sqlite3_close(database) }
                // Preserve native terminal zero, byte counts, hash, and retained-page EOF.
                // Only missing or failed producer-end evidence changes in this source fixture.
                let value = reason == "unknown" ? "NULL" : "'\(reason)'"
                let error = reason == "read_error" ? String(EBADF) : "NULL"
                let sql = "UPDATE runtime_job_output_streams SET producer_end_reason=\(value),producer_read_errno=\(error) WHERE job_id='\(test.jobID.uuidString.lowercased())' AND stream='stderr'"
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw RuntimeJobError.storageFailure("could not write owned producer evidence control")
                }
                XCTAssertEqual(sqlite3_changes(database), 1)
                let storedOptional = try await fixture.control.toolInvocation(sessionID: harness.sessionID, providerCallID: "test")
                let stored = try XCTUnwrap(storedOptional)
                let candidateOptional = try await ProjectInstructionCompletionGate.xcodeCandidate(
                    invocation: stored, projectID: harness.run.projectID, generation: harness.run.projectGeneration,
                    runID: harness.run.runID, repository: fixture.control, runtimeJobs: fixture.repository)
                let candidate = try XCTUnwrap(candidateOptional)
                XCTAssertTrue(candidate.isSuccessful, "An exit-zero record alone cannot establish output completeness")
                do {
                    let output = try await ProjectInstructionCompletionGate.xcodeOutput(candidate, jobs: fixture.jobs,
                        remainingBytes: 4_096, deadline: ContinuousClock().now.advanced(by: .seconds(5)))
                    XCTAssertNil(output, reason)
                    XCTAssertEqual(reason, "unknown", "Loss without its truncation flag must be rejected at the durable decode boundary")
                } catch let error as RuntimeJobError {
                    XCTAssertNotEqual(reason, "unknown")
                    XCTAssertEqual(error.code, "runtime_storage_failure")
                }
                var summaryArguments = Self.completionSummaryArguments()
                summaryArguments["idempotency_key"] = "producer-end-summary-" + reason
                let descriptorOptional = try await ProjectInstructionCompletionGate.xcodeCompletionDescriptor(
                    call: BrokeredToolCall(providerCallID: "producer-end-summary-" + reason,
                        toolName: "xcode.result", arguments: summaryArguments),
                    context: harness.context, repository: fixture.control, runtimeJobs: fixture.repository,
                    xcrunURL: fixture.projectRoot.appendingPathComponent("fixture-xcrun"))
                let descriptor = try XCTUnwrap(descriptorOptional)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(descriptor.utf8)) as? [String: Any])
                XCTAssertNil(object["test_job_id"], "An incomplete producer cannot attach a typed test-summary identity")
                let rejected = try await ProjectInstructionCompletionGate.result(run: harness.run, repository: fixture.control, runtimeJobs: fixture.jobs)
                XCTAssertFalse(rejected.passed, reason)
                let record = try await fixture.jobs.status(jobID: test.jobID, context: harness.context)
                XCTAssertEqual(record, test, "Completion refusal must preserve the native job's original receipt")
                _ = try await fixture.control.releaseRunLease(harness.lease)
            }
        }
    }

    func testTypedNativeCompletionUsesThePhysicalCwdAcrossFoundationTemporaryAliasesAndExpiredProofDeadline() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            try Self.writeCompletionSummary(Self.passingCompletionSummary, fixture: fixture)
            let harness = try await Self.nativeCompletionHarness(fixture)
            defer { harness.memory.closeAll() }
            let alias = fixture.projectRoot.appendingPathComponent("owned-cwd-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.projectRoot)
            var arguments = Self.completionArguments(.testWithoutBuilding)
            arguments["cwd"] = alias.path
            let command = try XcodeCLIService.command(tool: "xcode.run", arguments: arguments, context: harness.context)
            let test = try await Self.completionCall("alias-test", tool: "xcode.run", arguments: arguments, harness: harness, fixture: fixture)
            XCTAssertEqual(RuntimePathCanonicalizer.canonicalURL(test.canonicalWorkingDirectory), command.workingDirectory)
            let storedOptional = try await fixture.control.toolInvocation(sessionID: harness.sessionID, providerCallID: "alias-test")
            let stored = try XCTUnwrap(storedOptional)
            let descriptor = try XCTUnwrap(ProjectInstructionCompletionGate.decodedXcodeDescriptor(stored))
            XCTAssertEqual(descriptor.canonical_cwd_sha256, JSONSupport.sha256Hex(RuntimePathCanonicalizer.canonicalURL(test.canonicalWorkingDirectory).path))
            let candidateOptional = try await ProjectInstructionCompletionGate.xcodeCandidate(
                invocation: stored, projectID: harness.run.projectID, generation: harness.run.projectGeneration,
                runID: harness.run.runID, repository: fixture.control, runtimeJobs: fixture.repository
            )
            let candidate = try XCTUnwrap(candidateOptional)
            XCTAssertTrue(candidate.isSuccessful, "Foundation's temporary alias cannot erase equal native intent")
            let expired = ContinuousClock().now.advanced(by: .seconds(-1))
            let unavailable = try await ProjectInstructionCompletionGate.xcodeOutput(candidate, jobs: fixture.jobs, remainingBytes: 4_096, deadline: expired)
            XCTAssertNil(unavailable, "An expired shared proof deadline cannot begin native output paging")
            var accumulator = ProjectInstructionCompletionGate.EvidenceAccumulator(run: harness.run)
            try accumulator.consume([stored])
            try await accumulator.consumeNativeXcode([stored], repository: fixture.control, jobs: fixture.jobs, deadline: expired)
            try await accumulator.finishNativeXcode(repository: fixture.control, jobs: fixture.jobs, deadline: expired)
            XCTAssertFalse(accumulator.result().passed)
            let nativeAfter = try await fixture.jobs.status(jobID: test.jobID, context: harness.context)
            XCTAssertEqual(nativeAfter, test, "Proof expiry cannot cancel or rewrite the independently owned native job")
            _ = try await fixture.control.releaseRunLease(harness.lease)
        }
    }


    func testDistinctSuccessfulNativeJobsAtOneTimestampAreAmbiguousButSameJobReplayIsNot() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            let harness = try await Self.nativeCompletionHarness(fixture)
            defer { harness.memory.closeAll() }
            let first = try await Self.completionCall("timestamp-A", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
            var otherArguments = Self.completionArguments(.testWithoutBuilding)
            otherArguments["idempotency_key"] = "timestamp-B"
            let second = try await Self.completionCall("timestamp-B", tool: "xcode.run", arguments: otherArguments, harness: harness, fixture: fixture)
            func candidate(_ record: RuntimeJobRecord, id: UUID, completedAt: String) throws -> ProjectInstructionCompletionGate.XcodeCandidate {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
                object["jobID"] = id.uuidString
                object["completedAt"] = completedAt
                let pinned = try JSONDecoder().decode(RuntimeJobRecord.self, from: JSONSerialization.data(withJSONObject: object))
                return ProjectInstructionCompletionGate.XcodeCandidate(
                    invocationID: UUID(), invocationUpdatedAt: completedAt, descriptor: nil,
                    record: pinned, context: harness.context
                )
            }
            // Actual terminal-zero owned records supply all other fields. Pin the two
            // exposed ordering fields to force the exact source ambiguity without a sleep.
            let older = try candidate(first, id: XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")), completedAt: "2027-01-15T08:00:00Z")
            let newer = try candidate(second, id: XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001")), completedAt: "2027-01-15T08:00:00Z")
            for order in [[older, newer], [newer, older]] {
                var selected: ProjectInstructionCompletionGate.XcodeCandidate?
                var ambiguous = false
                for value in order { ProjectInstructionCompletionGate.XcodeCandidate.consider(value, selected: &selected, ambiguous: &ambiguous) }
                XCTAssertTrue(ambiguous, "UUID lexical order cannot manufacture causal completion order")
            }
            var selected: ProjectInstructionCompletionGate.XcodeCandidate?
            var ambiguous = false
            ProjectInstructionCompletionGate.XcodeCandidate.consider(older, selected: &selected, ambiguous: &ambiguous)
            ProjectInstructionCompletionGate.XcodeCandidate.consider(older, selected: &selected, ambiguous: &ambiguous)
            XCTAssertFalse(ambiguous, "A replay of one durable job remains valid")
            let later = try candidate(second, id: XCTUnwrap(newer.record).jobID, completedAt: "2027-01-15T08:00:01Z")
            ProjectInstructionCompletionGate.XcodeCandidate.consider(newer, selected: &selected, ambiguous: &ambiguous)
            XCTAssertTrue(ambiguous)
            ProjectInstructionCompletionGate.XcodeCandidate.consider(later, selected: &selected, ambiguous: &ambiguous)
            XCTAssertFalse(ambiguous, "An actual later recorded completion supersedes the ambiguous older second")
            XCTAssertEqual(selected?.record?.jobID, later.record?.jobID)
            _ = try await fixture.control.releaseRunLease(harness.lease)
        }
    }


    func testTypedCompletionDescriptorRejectsUnknownVersionMalformedIntegerAndIntentDigest() async throws {
        try await withFixture(script: "printf should-not-run") { fixture in
            let context = try await fixture.autonomousRunContext()
            let call = BrokeredToolCall(providerCallID: "descriptor-boundary", toolName: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding))
            let rawOptional = try await ProjectInstructionCompletionGate.xcodeCompletionDescriptor(
                call: call, context: context, repository: fixture.control, runtimeJobs: fixture.repository
            )
            let raw = try XCTUnwrap(rawOptional)
            let descriptorObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let prototype = try Self.invocation(call: call, context: context)
            func record(_ descriptor: [String: Any]) throws -> ToolInvocationRecord {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prototype)) as? [String: Any])
                object["reconciliationDescriptor"] = String(decoding: try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys]), as: UTF8.self)
                return try JSONDecoder().decode(ToolInvocationRecord.self, from: JSONSerialization.data(withJSONObject: object))
            }
            XCTAssertNotNil(ProjectInstructionCompletionGate.decodedXcodeDescriptor(try record(descriptorObject)))
            let malformed: [(String, Any)] = [
                ("typed_xcode_completion_version", 2),
                ("native_argument_count", true),
                ("native_argument_count", 1.5),
                ("native_argument_count", 257),
                ("timeout_seconds", 0),
                ("arguments_sha256", String(repeating: "d", count: 64)),
                ("native_command_sha256", "invalid"),
                ("action", "unsupported-action")
            ]
            for (key, value) in malformed {
                var object = descriptorObject; object[key] = value
                XCTAssertNil(ProjectInstructionCompletionGate.decodedXcodeDescriptor(try record(object)), key + ": \(value)")
            }
            let jobs = try await fixture.jobs.list(context: context)
            XCTAssertTrue(jobs.isEmpty, "Boundary parsing must not admit a process")
        }
    }

    func testTypedGateRejectsACompletedNativeJobOwnedByAnotherRun() async throws {
        try await withFixture(script: Self.nativeCompletionScript) { fixture in
            let harness = try await Self.nativeCompletionHarness(fixture)
            defer { harness.memory.closeAll() }
            _ = try await Self.completionCall("owner-test", tool: "xcode.run", arguments: Self.completionArguments(.testWithoutBuilding), harness: harness, fixture: fixture)
            let sourceOptional = try await fixture.control.toolInvocation(sessionID: harness.sessionID, providerCallID: "owner-test")
            let source = try XCTUnwrap(sourceOptional)
            let foreignContext = try await fixture.autonomousRunContext()
            XCTAssertNotEqual(foreignContext.runID, harness.context.runID)
            var foreignArguments = Self.completionArguments(.testWithoutBuilding)
            foreignArguments["idempotency_key"] = "foreign-native-job"
            let foreignOptional = try await fixture.pack.handle(name: "xcode.run", arguments: foreignArguments, context: foreignContext)
            let foreignResult = try XCTUnwrap(foreignOptional)
            let foreignID = try Self.jobID(foreignResult)
            let foreignJob = try await fixture.jobs.waitForTerminal(jobID: foreignID, context: foreignContext, maximumWait: .seconds(5))
            XCTAssertEqual(foreignJob.exitCode, 0)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
            let sourceArguments = Self.completionArguments(.testWithoutBuilding)
            let command = try XcodeCLIService.command(tool: "xcode.run", arguments: sourceArguments, context: harness.context)
            let forgedSummary = try JSONSupport.canonicalJSON([
                "ok": true, "is_error": false, "payload": XcodeCLIToolPack.receipt(foreignJob, command: command)
            ])
            object["resultSummary"] = forgedSummary
            object["resultSHA256"] = JSONSupport.sha256Hex(forgedSummary)
            let forged = try JSONDecoder().decode(ToolInvocationRecord.self, from: JSONSerialization.data(withJSONObject: object))
            do {
                _ = try await ProjectInstructionCompletionGate.xcodeCandidate(
                    invocation: forged, projectID: harness.run.projectID, generation: harness.run.projectGeneration,
                    runID: harness.run.runID, repository: fixture.control, runtimeJobs: fixture.repository
                )
                XCTFail("A successful foreign native exit cannot become this run's completion authority")
            } catch RuntimeJobError.jobScopeMismatch(let jobID) {
                XCTAssertEqual(jobID, foreignID)
            }
            let after = try await fixture.jobs.status(jobID: foreignID, context: foreignContext)
            XCTAssertEqual(after, foreignJob, "Refusing foreign evidence cannot mutate its owner's native job")
            _ = try await fixture.control.releaseRunLease(harness.lease)
        }
    }

    private static let passingCompletionSummary = #"{"result":"Passed","totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}"#
    private static let nativeCompletionScript = """
    case "$1:$2" in
      xcodebuild:test|xcodebuild:test-without-building)
        if [ -f test-delay.txt ]; then /bin/sleep 1; fi
        if [ -f test-output.txt ]; then /bin/cat test-output.txt; else printf 'Executed 1 test, 0 failures'; fi
        if [ -f test-exit.txt ]; then exit 65; fi
        ;;
      xcodebuild:*) printf 'native build completed' ;;
      xcresulttool:*) /bin/cat completion-summary.json ;;
      *) exit 64 ;;
    esac
    """

    private struct NativeCompletionHarness {
        let run: AutonomousRunRecord
        let lease: RunLease
        let turn: ProviderTurnIntent
        let sessionID: String
        let context: ToolInvocationContext
        let broker: ToolInvocationBroker
        let memory: ProjectMemoryService
    }

    private static func writeCompletionSummary(_ summary: String, fixture: Fixture) throws {
        try Data(summary.utf8).write(to: fixture.projectRoot.appendingPathComponent("completion-summary.json"))
    }

    private static func completionArguments(_ action: XcodeNativeAction, bundle: String = "Tests.xcresult") -> [String: Any] {
        var arguments: [String: Any] = [
            "action": action.rawValue, "workspace": "Fixture.xcworkspace", "scheme": "FixtureTests",
            "destination": "platform=macOS", "derived_data_path": "DerivedData",
            "result_bundle_path": bundle, "timeout_sec": 5,
            "idempotency_key": "native-" + action.rawValue + "-" + bundle
        ]
        if action.executesTests || action == .buildForTesting {
            arguments["only_testing"] = ["FixtureTests/FixtureCase/testOne"]
        }
        return arguments
    }

    private static func completionSummaryArguments() -> [String: Any] {
        ["query": "test_summary", "result_bundle_path": "Tests.xcresult", "timeout_sec": 5, "idempotency_key": "native-summary"]
    }

    private static func nativeCompletionHarness(_ fixture: Fixture) async throws -> NativeCompletionHarness {
        try FileManager.default.createDirectory(at: fixture.projectRoot.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.2\n".utf8).write(to: fixture.projectRoot.appendingPathComponent("Package.swift"))
        let digest = String(repeating: "c", count: 64)
        let plan = try AutomaticCompletionPlanResolver.resolve(.init(
            projectID: fixture.context.projectID, projectGeneration: fixture.context.projectGeneration,
            projectRoot: fixture.projectRoot, instructionArtifactSHA256: [digest],
            instructionText: "Repair the Swift defect and run the affected tests.", documentCount: 1,
            completionGates: [ProjectInstructionQueueStore.builtInCompletionGate]
        ))
        XCTAssertTrue(plan.obligations.contains { $0.kind == .projectBuild })
        XCTAssertTrue(plan.obligations.contains { $0.kind == .projectTests })
        let sessionID = "native-completion-" + UUID().uuidString.lowercased()
        let run = try await fixture.control.createAutonomousRun(AutonomousRunRequest(
            projectID: fixture.context.projectID, projectGeneration: fixture.context.projectGeneration,
            mission: "Verify native completion evidence without inventing missing obligations", providerID: "native-completion-fixture", modelKey: "native-completion-fixture",
            specification: AutonomousRunSpecification(
                allowedTools: XcodeCLIToolPack.names, completionGates: [ProjectInstructionQueueStore.builtInCompletionGate],
                completionPlan: plan,
                work: AutonomousRunWork(metadata: ["source_snapshot_sha256": digest, "completion_plan_id": plan.planID.uuidString.lowercased(), "completion_plan_revision": String(plan.revision)])
            ), authorizationScope: fixture.context.authorizationScope
        ))
        let lease = try await fixture.control.acquireRunLease(runID: run.runID, ownerID: sessionID, policy: RunLeasePolicy(duration: 120, renewalInterval: 10, maximumDuration: 300))
        let responseID = sessionID + "-root"
        try await fixture.control.reserveProviderSession(ProviderSessionIntent(
            sessionID: sessionID, runID: run.runID, projectID: run.projectID, projectGeneration: run.projectGeneration,
            providerID: "native-completion-fixture", adapterID: "native-completion-fixture", modelKey: "native-completion-fixture",
            providerResponseID: responseID, idempotencyKey: sessionID + "-session"
        ), lease: lease)
        let turn = ProviderTurnIntent(
            runID: run.runID, sessionID: sessionID, projectID: run.projectID, projectGeneration: run.projectGeneration,
            kind: .normalContinuation, idempotencyKey: sessionID + "-turn", previousResponseID: responseID, inputSHA256: String(repeating: "e", count: 64)
        )
        _ = try await fixture.control.persistProviderTurnIntent(turn, lease: lease)
        let context = try await fixture.control.invocationContext(for: ProjectBindingOwner(kind: .providerSession, id: sessionID), clientID: ClientID(sessionID))
        let memory = ProjectMemoryService(paths: AppPaths(home: fixture.root.appendingPathComponent("native-completion-memory")))
        let executable = fixture.projectRoot.appendingPathComponent("fixture-xcrun")
        let broker = ToolInvocationBroker(
            repository: fixture.control, executor: CanonicalReceiptBudgetXcodeExecutor(service: XcodeCLIService(jobs: fixture.jobs, xcrunURL: executable)),
            classifier: StaticToolReplayClassifier(classifications: ProductionToolReplayCatalog.classifications),
            reconciler: ProductionToolInvocationReconciler(controlPlane: fixture.control, runtimeJobs: fixture.repository, memory: memory, xcodeExecutable: executable)
        )
        return NativeCompletionHarness(run: run, lease: lease, turn: turn, sessionID: sessionID, context: context, broker: broker, memory: memory)
    }

    private static func completionCall(
        _ callID: String, tool: String, arguments: [String: Any],
        harness: NativeCompletionHarness, fixture: Fixture, expectedExit: Int32 = 0
    ) async throws -> RuntimeJobRecord {
        let result = try await harness.broker.invoke(
            BrokeredToolCall(providerCallID: callID, toolName: tool, arguments: arguments, idempotencyKey: callID),
            turnID: harness.turn.turnID, context: harness.context, lease: harness.lease
        )
        XCTAssertTrue(result.ok, "\(callID): \(result.payload)")
        XCTAssertFalse(result.isError)
        let jobID = try Self.jobID(result)
        let terminal = try await fixture.jobs.waitForTerminal(jobID: jobID, context: harness.context, maximumWait: .seconds(5))
        XCTAssertEqual(terminal.state, expectedExit == 0 ? .completed : .failed)
        XCTAssertEqual(terminal.exitCode, expectedExit)
        return terminal
    }

    private static func runArguments(action: XcodeNativeAction) -> [String: Any] {
        ["action": action.rawValue, "project": "App.xcodeproj", "scheme": "App; $(touch should-never-exist)",
         "destination": "platform=macOS,arch=arm64", "derived_data_path": "evidence/derived-data", "result_bundle_path": "evidence/Test.xcresult"]
    }

    private static func context() -> ToolInvocationContext {
        ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("xcode-test"),
                              authorizationScope: ToolAuthorizationScope(canonicalRoots: [URL(fileURLWithPath: "/tmp/xcode-fixture")], allowedTools: Set(XcodeCLIToolPack.names), networkAllowed: false, maximumInlineOutputBytes: 1_024))
    }

    private static var canonicalRoot: URL {
        RuntimePathCanonicalizer.canonicalURL(URL(fileURLWithPath: "/tmp/xcode-fixture"))
    }

    private static func jobID(_ result: ToolResult) throws -> UUID {
        let raw = try XCTUnwrap(result.payload["job_id"] as? String)
        return try XCTUnwrap(UUID(uuidString: raw))
    }

    private func withFixture(
        script: String,
        fileCap: Int? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture.make(script: script, fileCap: fileCap, processEnvironment: processEnvironment)
        do { try await body(fixture) }
        catch {
            try? await fixture.close()
            throw error
        }
        try await fixture.close()
    }

    private struct Fixture {
        let root: URL
        let projectRoot: URL
        let context: ToolInvocationContext
        let control: ProjectControlPlaneRepository
        let repository: RuntimeJobRepository
        let jobs: ExecutionJobService
        let pack: XcodeCLIToolPack

        static func make(script: String, fileCap: Int?, processEnvironment: [String: String]) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-xcode-tests-\(UUID().uuidString)")
            let project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let executable = project.appendingPathComponent("fixture-xcrun")
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let database = root.appendingPathComponent("control.sqlite")
            let control = try ProjectControlPlaneRepository(databaseURL: database)
            let projectID = ProjectID()
            _ = try await control.registerProjectUnchecked(projectID: projectID, displayName: "Xcode Fixture", canonicalRoot: project)
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "xcode-test-client")
            let scope = ToolAuthorizationScope(canonicalRoots: [project], allowedTools: Set(XcodeCLIToolPack.names).union(RuntimeJobToolPack.names), networkAllowed: false, maximumInlineOutputBytes: 1_024)
            _ = try await control.bind(owner: owner, projectID: projectID, generation: .initial, authorizationScope: scope)
            let context = try await control.invocationContext(for: owner)
            let repository = try RuntimeJobRepository(databaseURL: database)
            let jobs = try ExecutionJobService(
                repository: repository, contextValidator: ProjectControlPlaneRuntimeJobContextValidator(repository: control),
                artifactRoot: root.appendingPathComponent("artifacts"),
                limits: RuntimeJobLimits(maximumConcurrentJobs: 2, maximumCPUHeavyJobs: 1, maximumInlineOutputBytes: 1_024, maximumArtifactBytesPerJob: 4_096,
                                         maximumTimeoutSeconds: 60, terminationGraceMilliseconds: 100, forcedTerminationGraceMilliseconds: 1_000,
                                         maximumFileBytesPerProcess: fileCap),
                environment: processEnvironment
            )
            try await jobs.start()
            return Fixture(root: root, projectRoot: project, context: context, control: control, repository: repository, jobs: jobs,
                           pack: XcodeCLIToolPack(service: XcodeCLIService(jobs: jobs, xcrunURL: executable)))
        }

        func close() async throws {
            let report = await jobs.shutdown()
            guard report.completed else { throw RuntimeJobError.storageFailure("Xcode fixture shutdown incomplete; evidence preserved at \(root.path)") }
            await repository.close()
            await control.close()
            try FileManager.default.removeItem(at: root)
        }

        func autonomousRunContext(maximumInlineOutputBytes: Int? = nil) async throws -> ToolInvocationContext {
            let scope = maximumInlineOutputBytes.map { limit in
                ToolAuthorizationScope(
                    canonicalRoots: context.authorizationScope.canonicalRoots,
                    writableRoots: context.authorizationScope.writableRoots,
                    allowedTools: context.authorizationScope.allowedTools,
                    networkAllowed: context.authorizationScope.networkAllowed,
                    maximumInlineOutputBytes: limit
                )
            } ?? context.authorizationScope
            let run = try await control.createAutonomousRun(AutonomousRunRequest(
                projectID: context.projectID, projectGeneration: context.projectGeneration,
                mission: "Reconcile native Xcode discovery", providerID: "xcode-test-provider", modelKey: "xcode-test-model",
                specification: AutonomousRunSpecification(allowedTools: XcodeCLIToolPack.names, completionGates: ["native-receipt"]),
                authorizationScope: scope
            ))
            return try await control.invocationContext(for: ProjectBindingOwner(kind: .autonomousRun, id: run.runID.description))
        }
    }
}
