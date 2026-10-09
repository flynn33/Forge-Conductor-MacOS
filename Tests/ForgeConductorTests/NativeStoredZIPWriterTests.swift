import Foundation
import Darwin
import XCTest
@testable import ForgeConductorCore

final class NativeStoredZIPWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-stored-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testEmptyAndSuppliedBinaryUnicodeMembersMatchQualifiedMechanismBytes() async throws {
        try await Task.detached(priority: .utility) {
            let empty = try NativeStoredZIPWriter.encode(entries: [])
            XCTAssertEqual(empty.entryCount, 0); XCTAssertEqual(empty.inputBytes, 0)
            XCTAssertEqual(empty.data.count, 22)
            XCTAssertEqual(JSONSupport.sha256Hex(empty.data), "8739c76e681f900923b900c9df0ef75cf421d39cabb54650c4b9ad19b6a76d85")
            XCTAssertTrue(try Self.inspectZIP(empty.data).isEmpty)
            let supplied: [(String, Data)] = [("empty.bin", Data()),
                ("bytes/all-256.bin", Data((0...255).map { UInt8($0) })),
                ("données/日本語.txt", Data([0, 195, 169, 255, 10, 0, 13]))]
            let first = try NativeStoredZIPWriter.encode(entries: Self.entries(supplied))
            XCTAssertEqual(first.entryCount, 3); XCTAssertEqual(first.inputBytes, 263)
            XCTAssertEqual(first.data.count, 609)
            XCTAssertEqual(JSONSupport.sha256Hex(first.data), "18d4d650c4dbf2f181dcd3328392e79b62ec6a55ef28392cc205a41122e2da3e")
            let parsed = try Self.inspectZIP(first.data)
            XCTAssertEqual(parsed.map(\.0), supplied.map(\.0))
            XCTAssertEqual(parsed.map(\.1), supplied.map(\.1))
            XCTAssertEqual(try NativeStoredZIPWriter.encode(entries: Self.entries(supplied)).data, first.data)
        }.value
    }

    func testThirtyTwoMembersMaximumNoiseAndExactOutputCap() async throws {
        try await Task.detached(priority: .utility) {
            let supplied: [(String, Data)] = (0..<32).map { index in
                (String(format: "member-%02d.bin", index), Data([UInt8(index), UInt8(255 - index), 0, 255, UInt8(truncatingIfNeeded: index * 17)]))
            }
            let full = try NativeStoredZIPWriter.encode(entries: Self.entries(supplied))
            XCTAssertEqual(full.entryCount, 32); XCTAssertEqual(full.inputBytes, 160)
            XCTAssertEqual(full.data.count, 3446)
            XCTAssertEqual(JSONSupport.sha256Hex(full.data), "b75bf258d10199987a3986e3fa957a681b7c342156fa0b1eadcf58f869427e80")
            XCTAssertEqual(try Self.inspectZIP(full.data).map(\.1), supplied.map(\.1))
            XCTAssertEqual(try NativeStoredZIPWriter.encode(entries: Self.entries(supplied), outputByteLimit: full.data.count).data, full.data)
            for limit in [0, full.data.count - 1, NativeStoredZIPWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: Self.entries(supplied), outputByteLimit: limit)) {
                    XCTAssertEqual($0 as? NativeStoredZIPError, .outputLimit)
                }
            }
            var state: UInt32 = 0x13579BDF
            var noise = Data(); noise.reserveCapacity(1_048_576)
            for _ in 0..<1_048_576 {
                state = state &* 1_664_525 &+ 1_013_904_223
                noise.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            let maximum = try NativeStoredZIPWriter.encode(entries: Self.entries([("noise.bin", noise)]))
            XCTAssertEqual(maximum.inputBytes, 1_048_576)
            XCTAssertEqual(maximum.data.count, 1_048_692)
            XCTAssertEqual(JSONSupport.sha256Hex(maximum.data), "78ef170c69dc6046d78f6c8c1fba2e375268d0eb6a929f176140464dec8b58c7")
            XCTAssertEqual(try Self.inspectZIP(maximum.data).map(\.1), [noise])
        }.value
    }

    func testStrictEntryShapeCountNamesAndConservativeConflicts() async throws {
        try await Task.detached(priority: .utility) {
            let invalid: [(Any?, NativeStoredZIPError)] = [
                (nil, .invalidEntries), (NSNull(), .invalidEntries), ("entries", .invalidEntries),
                (Array(repeating: ["name": "a", "content": ""], count: 33), .entryLimit),
                (["entry"], .invalidEntry), ([["name": 1, "content": ""]], .invalidEntry),
                ([["name": "a", "content": false]], .invalidEntry), ([["name": "a"]], .invalidEntry),
                ([["name": "a", "content": "", "extra": 0]], .invalidEntry),
            ]
            for (value, expected) in invalid {
                XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: value)) { XCTAssertEqual($0 as? NativeStoredZIPError, expected) }
            }
            for name in ["", "/a", "C:a", "C:/a", "a\\b", "a\u{0}b", "a\n", ".", "..", "a/./b", "a/../b", "a//b", "a/"] {
                XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [["name": name, "content": ""]])) {
                    XCTAssertEqual($0 as? NativeStoredZIPError, .invalidName, name)
                }
            }
            for names in [["a", "a"], ["File.TXT", "file.txt"], ["a", "A/b"], ["A/b", "a"]] {
                XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: names.map { ["name": $0, "content": ""] })) {
                    XCTAssertEqual($0 as? NativeStoredZIPError, .nameCollision)
                }
            }
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [["name": "cafe\u{0301}.txt", "content": ""]])) {
                XCTAssertEqual($0 as? NativeStoredZIPError, .nonNFCName)
            }
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [["name": String(repeating: "a", count: 1025), "content": ""]])) {
                XCTAssertEqual($0 as? NativeStoredZIPError, .nameLimit)
            }
            for name in [String(repeating: "a", count: 256), String(repeating: "é", count: 128)] {
                XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [["name": name, "content": ""]])) {
                    XCTAssertEqual($0 as? NativeStoredZIPError, .componentLimit)
                }
            }
            let boundary = [String(repeating: "a", count: 255), String(repeating: "b", count: 255),
                String(repeating: "c", count: 255), String(repeating: "d", count: 253), "ee"].joined(separator: "/")
            XCTAssertEqual(boundary.utf8.count, 1024)
            let accepted = try Self.inspectZIP(NativeStoredZIPWriter.encode(entries: [["name": boundary, "content": "AA=="]]).data)
            XCTAssertEqual(accepted.map(\.0), [boundary]); XCTAssertEqual(accepted.map(\.1), [Data([0])])
        }.value
    }

    func testCanonicalBase64AndAggregateRawLimits() async throws {
        try await Task.detached(priority: .utility) {
            for content in ["!!!!", "AA==\n", "AA", "=AAA", "AB==", "AAB=", "===="] {
                XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [["name": "a", "content": content]])) {
                    XCTAssertEqual($0 as? NativeStoredZIPError, .invalidBase64)
                }
            }
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [["name": "a", "content": String(repeating: "A", count: 1_398_105)]])) {
                XCTAssertEqual($0 as? NativeStoredZIPError, .base64Limit)
            }
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: Self.entries([("a", Data(repeating: 0, count: 1_048_577))]))) {
                XCTAssertEqual($0 as? NativeStoredZIPError, .inputLimit)
            }
            let over = Data(repeating: 0, count: 524_289)
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: Self.entries([("a", over), ("b", over)]))) {
                XCTAssertEqual($0 as? NativeStoredZIPError, .inputLimit)
            }
            for raw in [Data(), Data([0]), Data([0, 255]), Data([0, 255, 42])] {
                let result = try NativeStoredZIPWriter.encode(entries: Self.entries([("a", raw)]))
                XCTAssertEqual(try Self.inspectZIP(result.data).map(\.1), [raw])
            }
        }.value
    }

    func testWorkerPreCancellationAndExpiredDeadlineRefuseEncoding() async throws {
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [])) { XCTAssertEqual($0 as? NativeStoredZIPError, .workerRequired) }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 5); cancelled.cancel()
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [], cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeStoredZIPWriter.encode(entries: [], cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
        }.value
    }

    func testToolReplacementMetadataFullBinaryPagesAndOwnerAuthorizedHostWrite() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let supplied = [("bytes.bin", Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0) }))]
                let arguments = Self.entries(supplied)
                let existing = project.appendingPathComponent("replace.ZIP")
                try Data("prior".utf8).write(to: existing)
                XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for destination in [existing, root.appendingPathComponent("owner-authorized.zip")] {
                    let result = try app.tools.call(name: "archive_write", arguments: ["path": destination.path, "entries": arguments], clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: destination)
                    XCTAssertEqual(result.payload["format"] as? String, "zip")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-stored-zip")
                    XCTAssertEqual(result.payload["output_contract"] as? String, "zip-stored-supplied-files-v1")
                    XCTAssertEqual(result.payload["entry_count"] as? Int, 1)
                    XCTAssertEqual(result.payload["input_bytes"] as? Int, 40_000)
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, destination == existing ? 0o600 : 0o644)
                    var reconstructed = Data(), offset = 0
                    for _ in 0..<4 {
                        let read = try app.tools.call(name: "fs_read", arguments: ["path": destination.path, "encoding": "base64", "byte_offset": offset, "maximum_bytes": 32_768], clientID: client)
                        XCTAssertTrue(read.ok, "\(read.payload)")
                        let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)))
                        reconstructed.append(raw)
                        let next = try XCTUnwrap(read.payload["next_byte_offset"] as? Int)
                        XCTAssertEqual(next, offset + raw.count)
                        offset = next
                        if read.payload["has_more"] as? Bool == false { break }
                        XCTAssertFalse(raw.isEmpty)
                    }
                    XCTAssertEqual(reconstructed, bytes); XCTAssertEqual(offset, bytes.count)
                    XCTAssertEqual(try Self.inspectZIP(bytes).map(\.1), supplied.map(\.1))
                }
                let empty = try app.tools.call(name: "archive_write", arguments: ["path": project.appendingPathComponent("empty.zip").path, "entries": []], clientID: client)
                XCTAssertTrue(empty.ok); XCTAssertEqual(empty.payload["bytes_written"] as? Int, 22)
            }
        }.value
    }

    func testMalformedToolArgumentsAndCancellationPreserveDestinationWithoutResidue() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.zip")
                let prior = Data("preserve destination".utf8); try prior.write(to: destination)
                let invalid: [([String: Any], String)] = [
                    (["path": 1, "entries": []], "invalid_path"), (["path": true, "entries": []], "invalid_path"),
                    (["path": " \n", "entries": []], "invalid_path"), (["path": "nul\u{0}.zip", "entries": []], "invalid_path"),
                    (["path": project.appendingPathComponent("no-extension").path, "entries": []], "invalid_path"),
                    (["path": destination.path], "invalid_archive_entries"),
                    (["path": destination.path, "entries": [] as [Any], "extra": true], "invalid_archive_arguments"),
                    (["path": destination.path, "entries": [["name": "../a", "content": ""]]], "invalid_archive_name"),
                    (["path": destination.path, "entries": [["name": "a", "content": "AB=="]]], "invalid_archive_base64"),
                ]
                for (arguments, code) in invalid {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: arguments, context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: destination), prior)
                }
                for control in [ToolCallCancellation(timeoutSeconds: 5), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "archive_write", arguments: ["path": destination.path, "entries": []], context: nil, clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["strict.zip"])
            }
        }.value
    }

    func testPinnedParentAndFailedRenamePreserveNeighbors() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let prior = Data("keep".utf8); try prior.write(to: outside.appendingPathComponent("target.zip"))
                let link = project.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let linked = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": link.appendingPathComponent("target.zip").path, "entries": []], context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(linked.ok); XCTAssertEqual(linked.payload["code"] as? String, "archive_write_failed")
                XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.zip")), prior)
                let directory = project.appendingPathComponent("directory.zip", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                let failed = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": directory.path, "entries": []], context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(failed.ok); XCTAssertEqual(failed.payload["code"] as? String, "archive_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.zip", "link"])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.zip"])
            }
        }.value
    }

    func testAuthorizationRejectsRawPathsAndPreservesVirtualEntriesWithoutRootConfinement() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
                let supplied: [[String: Any]] = [["name": "virtual/日本語.bin", "content": "AP8="]]
                for raw in [NSNull(), 1, true, ["bad.zip"], ["path": "bad.zip"], "", " \n", "nul\u{0}.zip"] as [Any] {
                    let decision = try authorization.authorize(tool: "archive_write", arguments: ["path": raw, "entries": supplied],
                        context: context, clientID: client, binding: nil, cancellation: nil)
                    guard case .denied(let code, _) = decision else { XCTFail("Raw path must not be coerced"); continue }
                    XCTAssertEqual(code, "invalid_path")
                }
                for path in ["relative.zip", root.appendingPathComponent("host-wide.zip").path] {
                    let decision = try authorization.authorize(tool: "archive_write", arguments: ["path": path, "entries": supplied],
                        context: context, clientID: client, binding: nil, cancellation: nil)
                    guard case .allowed(let normalized) = decision else { return XCTFail("Existing owner-authorized host-wide writes must remain available") }
                    XCTAssertEqual(try JSONSupport.data(from: ["entries": try XCTUnwrap(normalized["entries"] as? [[String: Any]])]),
                                   try JSONSupport.data(from: ["entries": supplied]))
                    let destination = try XCTUnwrap(normalized["path"] as? String)
                    XCTAssertTrue(destination.hasSuffix(path.hasPrefix("/") ? "host-wide.zip" : "relative.zip"))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
            }
        }.value
    }

    func testOwnGrantAndStaleContextPreventArchiveWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("archive-denied")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_write", "ods_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let destination = project.appendingPathComponent("denied.zip")
                let denied = try app.tools.call(name: "archive_write", arguments: ["path": destination.path, "entries": []], clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": destination.path, "entries": []], context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "archive_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }.value
    }

    func testDefaultsCustomDenialsImportedCapabilitiesAndNestedAuditStayNarrow() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, _, project in
                let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
                XCTAssertEqual(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.filter { $0 == "archive_write" }.count, 1)
                XCTAssertTrue(ContinuityAutomation.progressTools.contains("archive_write"))
                for specs in [app.catalog.all(), AgentCatalog.builtinDefaults()] {
                    let docs = try XCTUnwrap(specs.first { $0.id == "docs" })
                    XCTAssertEqual(docs.tools.filter { $0 == "archive_write" }.count, 1)
                    XCTAssertTrue(docs.body.contains("65536-byte")); XCTAssertTrue(docs.body.contains("canonical JSON"))
                    for spec in specs where spec.id != "docs" { XCTAssertFalse(spec.tools.contains("archive_write")) }
                }
                for old in ["fs_write", "pdf_write", "pdf_from_file", "docx_write", "xlsx_write", "pptx_write", "ods_write", "image_write"] {
                    XCTAssertFalse(ToolGrantSemantics.grants(tool: "archive_write", from: [old]))
                    XCTAssertFalse(ToolGrantSemantics.grants(tool: old, from: ["archive_write"]))
                    XCTAssertEqual(try catalog.definitions(allowedToolNames: [old]).map(\.name), [old])
                }
                let staticCatalog = try XCTUnwrap(app.telemetry.loadStatic("tools-catalog.js"))
                let staticText = try XCTUnwrap(String(data: staticCatalog.0, encoding: .utf8))
                XCTAssertEqual(staticText.components(separatedBy: "\"archive_write\"").count - 1, 1)
                let cards = ForgeCollector(paths: app.paths, store: app.store, catalog: app.catalog,
                    toolNames: { app.tools.toolNames }).collect().mcpTools
                XCTAssertEqual(cards.filter { $0.name == "archive_write" }.count, 1)
                for name in ["archive_write", "pdf_write", "pdf_from_file", "xlsx_write", "pptx_write", "ods_write", "image_write"] {
                    XCTAssertEqual(try XCTUnwrap(cards.first { $0.name == name }).pack, "docs")
                }
                let custom = """
                ---
                id: docs
                display_name: Owner docs
                tools:
                  - fs_write
                  - ods_write
                tools_forbidden:
                  - archive_write
                ---
                Owner grants.
                """
                try custom.write(to: app.paths.agentsDir.appendingPathComponent("docs.md"), atomically: true, encoding: .utf8)
                app.catalog.reload()
                let spec = try XCTUnwrap(app.catalog.get("docs"))
                XCTAssertEqual(spec.source, "custom"); XCTAssertEqual(spec.tools, ["fs_write", "ods_write"])
                XCTAssertEqual(spec.toolsForbidden, ["archive_write"])
                let client = ClientID("archive-custom-grant")
                let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: client,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: [project], allowedTools: ["*"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let binding = ActiveBinding(sessionID: SessionID("archive-custom"), agentID: spec.id,
                    toolsPrimary: spec.tools, toolsForbidden: spec.toolsForbidden, cwd: project.path)
                let decision = try ToolAuthorizationService(paths: app.paths, config: app.config).authorize(tool: "archive_write", arguments: ["path": "denied.zip", "entries": []], context: context, clientID: client, binding: binding, cancellation: nil)
                guard case .denied(let code, _) = decision else { return XCTFail("Custom agent denial must override wildcard") }
                XCTAssertEqual(code, "tool_forbidden")
                let source = root.appendingPathComponent("explicit-package", isDirectory: true)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try "Keep explicit grants.".write(to: source.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
                let projectID = ProjectID(), requested = ["fs_read", "ods_write"]
                let manifest: [String: Any] = ["schema_version": 1, "package_id": "archive-explicit", "version": "1", "mission": "Keep explicit grants.",
                    "project_id": projectID.description, "entry_documents": ["instructions.md"], "requested_capabilities": requested,
                    "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate], "resource_policy": ["profile": "project-default"]]
                try JSONSupport.data(from: manifest).write(to: source.appendingPathComponent("forge-package.json"))
                let store = try ProjectInstructionQueueStore(paths: app.paths)
                let imported = try store.importPackage(sourceURL: source, projectID: projectID, generation: .initial)
                let package = try XCTUnwrap(imported.packages.first)
                let published = app.paths.instructionPackageStoreDir.appendingPathComponent(package.contentSHA256)
                XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: published.path)[.posixPermissions] as? NSNumber)?.intValue, 0o500)
                defer {
                    XCTAssertNoThrow(try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: published.path))
                }
                let expected = Array(Set(requested).union(["instruction_catalog", "instruction_read"])).sorted()
                XCTAssertEqual(try XCTUnwrap(imported.packages.first).allowedTools, expected)
                XCTAssertEqual(try XCTUnwrap(store.snapshot(projectID: projectID, generation: .initial).packages.first).allowedTools, expected)
                XCTAssertFalse(expected.contains("archive_write"))
                let importedContext = ToolInvocationContext(projectID: projectID, projectGeneration: .initial, clientID: client,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: [source], allowedTools: Set(expected), networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let importedDecision = try ToolAuthorizationService(paths: app.paths, config: app.config).authorize(tool: "archive_write",
                    arguments: ["path": "denied.zip", "entries": []], context: importedContext, clientID: client, binding: nil, cancellation: nil)
                guard case .denied(let importedCode, _) = importedDecision else { return XCTFail("Imported explicit grants must remain narrow") }
                XCTAssertEqual(importedCode, "tool_not_granted")
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("denied.zip").path))
                let arguments: [String: Any] = ["path": "safe.zip", "entries": [["name": "safe.txt", "content": "c2VjcmV0"]], "deadline_ms": 1000]
                let original = try JSONSupport.data(from: arguments)
                let sanitized = ToolAuditSanitizer.sanitize(arguments)
                XCTAssertFalse(try JSONSupport.string(from: sanitized).contains("c2VjcmV0"))
                XCTAssertEqual(sanitized["path"] as? String, "safe.zip"); XCTAssertEqual(sanitized["deadline_ms"] as? Int, 1000)
                XCTAssertEqual(try JSONSupport.data(from: arguments), original)
            }
        }.value
    }

    private static func entries(_ supplied: [(String, Data)]) -> [[String: Any]] {
        supplied.map { ["name": $0.0, "content": $0.1.base64EncodedString()] }
    }

    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true), startTelemetry: false)
        defer { XCTAssertTrue(app.shutdown().completed) }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("archive-writer-tests")
        let result = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(result.ok, "\(result.payload)")
        try operation(app, client, project)
    }

    private enum WireError: Error { case malformed }

    /// Independent directory-first oracle: contiguous locals, exact headers/names/data/CRC and EOF.
    private static func inspectZIP(_ data: Data) throws -> [(String, Data)] {
        guard (22...2_097_152).contains(data.count) else { throw WireError.malformed }
        func word(_ at: Int, _ length: Int) throws -> UInt32 {
            guard at >= 0, at <= data.count - length else { throw WireError.malformed }
            return (0..<length).reduce(0) { $0 | UInt32(data[at + $1]) << ($1 * 8) }
        }
        func equal(_ at: Int, _ length: Int, _ expected: UInt32) throws {
            guard try word(at, length) == expected else { throw WireError.malformed }
        }
        let end = data.count - 22
        try equal(end, 4, 0x06054b50)
        for delta in [4, 6, 20] { try equal(end + delta, 2, 0) }
        let count = Int(try word(end + 8, 2)); guard count <= 32 else { throw WireError.malformed }
        try equal(end + 10, 2, UInt32(count))
        let start = Int(try word(end + 16, 4)), extent = Int(try word(end + 12, 4))
        guard start <= end, extent == end - start else { throw WireError.malformed }
        var cursor = start, localEnd = 0, names: Set<Data> = [], parsed: [(String, Data)] = []
        for _ in 0..<count {
            guard cursor <= end - 46 else { throw WireError.malformed }
            try equal(cursor, 4, 0x02014b50)
            for (delta, expected) in [(4, 20), (6, 20), (8, 0x0800), (10, 0), (12, 0), (14, 0x21), (30, 0), (32, 0), (34, 0), (36, 0)] {
                try equal(cursor + delta, 2, UInt32(expected))
            }
            try equal(cursor + 38, 4, 0)
            let size = Int(try word(cursor + 20, 4)), nameCount = Int(try word(cursor + 28, 2)), local = Int(try word(cursor + 42, 4))
            guard (1...1024).contains(nameCount), size <= 1_048_576, cursor <= end - 46 - nameCount,
                  local == localEnd, local <= start - 30 - nameCount else { throw WireError.malformed }
            try equal(cursor + 24, 4, UInt32(size))
            let name = Data(data[(cursor + 46)..<(cursor + 46 + nameCount)])
            guard names.insert(name).inserted, let text = String(data: name, encoding: .utf8), Data(text.utf8) == name else { throw WireError.malformed }
            try equal(local, 4, 0x04034b50)
            for (delta, expected) in [(4, 20), (6, 0x0800), (8, 0), (10, 0), (12, 0x21), (28, 0)] { try equal(local + delta, 2, UInt32(expected)) }
            let checksum = try word(cursor + 16, 4)
            try equal(local + 14, 4, checksum); try equal(local + 18, 4, UInt32(size)); try equal(local + 22, 4, UInt32(size))
            try equal(local + 26, 2, UInt32(nameCount))
            guard Data(data[(local + 30)..<(local + 30 + nameCount)]) == name else { throw WireError.malformed }
            let payload = local + 30 + nameCount
            guard size <= start - payload else { throw WireError.malformed }
            let raw = Data(data[payload..<(payload + size)])
            guard checksum == tableCRC32(raw) else { throw WireError.malformed }
            parsed.append((text, raw)); localEnd = payload + size; cursor += 46 + nameCount
        }
        guard cursor == end, localEnd == start else { throw WireError.malformed }
        return parsed
    }

    private static func tableCRC32(_ bytes: Data) -> UInt32 {
        let table: [UInt32] = (0..<256).map { index in
            (0..<8).reduce(UInt32(index)) { current, _ in
                (current >> 1) ^ ((current & 1) != 0 ? 0xEDB88320 : 0)
            }
        }
        return bytes.reduce(UInt32.max) { value, byte in
            table[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8)
        } ^ UInt32.max
    }
}
