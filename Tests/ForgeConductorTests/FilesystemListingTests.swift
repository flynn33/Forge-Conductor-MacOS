import Darwin
import Foundation
import Synchronization
import XCTest
@testable import ForgeConductorCore

final class FilesystemListingTests: XCTestCase {
    func testPagedModeRequiresPresenceOfAnOptInField() {
        XCTAssertFalse(FilesystemListingPage.usesPagedMode(arguments: [:]))
        XCTAssertFalse(FilesystemListingPage.usesPagedMode(arguments: ["path": "/", "deadline_ms": 1]))
        for field in ["limit", "cursor", "maximum_bytes"] {
            XCTAssertTrue(FilesystemListingPage.usesPagedMode(arguments: [field: NSNull()]))
        }
    }

    func testArgumentsRejectInvalidTypesAndBounds() throws {
        let defaults = try FilesystemListingPage.Arguments([:])
        XCTAssertEqual(defaults.limit, 100)
        XCTAssertEqual(defaults.maximumBytes, 16_384)
        let invalidValues: [Any] = [true, false, "1", NSNull(), 1.5, Double.infinity, 0, -1]
        for field in ["limit", "maximum_bytes", "deadline_ms"] {
            for value in invalidValues {
                XCTAssertThrowsError(try FilesystemListingPage.Arguments([field: value]))
            }
        }
        let invalidArguments: [[String: Any]] = [
            ["limit": 1_001], ["maximum_bytes": 65_537], ["deadline_ms": 60_001],
            ["path": 3], ["path": "bad\0path"], ["unexpected": 1], ["cursor": NSNull()]
        ]
        for arguments in invalidArguments { XCTAssertThrowsError(try FilesystemListingPage.Arguments(arguments)) }
        XCTAssertEqual(try FilesystemListingPage.Arguments(["limit": 1_000]).limit, 1_000)
        XCTAssertEqual(try FilesystemListingPage.Arguments(["deadline_ms": 60_000]).deadlineMilliseconds, 60_000)
    }

    func testCursorCanonicalRoundTripRejectsAlternateAndDuplicateEncodings() throws {
        let cursor = try listingCursor(Data("e\u{301}".utf8))
        let token = try cursor.encoded()
        XCTAssertEqual(try FilesystemListingPage.Cursor(token), cursor)
        let scope = String(repeating: "a", count: 64), directory = String(repeating: "b", count: 64)
        let name = Data("name".utf8).base64EncodedString()
        let canonical = "{\"directory\":\"\(directory)\",\"last_name\":\"\(name)\",\"scope\":\"\(scope)\",\"version\":1}"
        XCTAssertNoThrow(try FilesystemListingPage.Cursor(listingBase64URL(Data(canonical.utf8))))
        for altered in [canonical + " ", canonical.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
                        canonical.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
                        canonical.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
                        canonical.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")] {
            XCTAssertThrowsError(try FilesystemListingPage.Cursor(listingBase64URL(Data(altered.utf8))))
        }
        for invalid in [token + "=", token + " ", "a", "!", String(repeating: "A", count: 8_193)] {
            XCTAssertThrowsError(try FilesystemListingPage.Cursor(invalid))
        }
        for invalidName in [Data(), Data([0]), Data([47]), Data([46]), Data([46, 46]), Data(repeating: 65, count: Int(PATH_MAX))] {
            XCTAssertThrowsError(try listingCursor(invalidName))
        }
        XCTAssertThrowsError(try FilesystemListingPage.Cursor(scopeFingerprint: String(repeating: "A", count: 64),
            directoryFingerprint: directory, lastName: Data("name".utf8)))
    }

    func testRawSelectorMatchesIndependentSortAndPreservesCanonicalSpellings() {
        let composed = Data("é".utf8), decomposed = Data("e\u{301}".utf8)
        XCTAssertNotEqual(composed, decomposed)
        let manifest = (0..<1_103).map { Data(String(format: "f%04d", $0).utf8) } + [composed, decomposed]
        let expected = manifest.sorted { Array($0).lexicographicallyPrecedes(Array($1)) }
        for supplied in [manifest, Array(manifest.reversed()), Array(manifest.dropFirst(300)) + Array(manifest.prefix(300))] {
            var selector = FilesystemListingPage.NameSelector(capacity: 1_001, after: nil)
            for name in supplied + Array(supplied.prefix(3)) { selector.consider(name) }
            XCTAssertEqual(selector.ordered, Array(expected.prefix(1_001)))
            XCTAssertLessThanOrEqual(selector.names.count, 1_001)
            var continuation = FilesystemListingPage.NameSelector(capacity: 150, after: expected[999])
            for name in supplied { continuation.consider(name) }
            XCTAssertEqual(continuation.ordered, Array(expected.dropFirst(1_000).prefix(150)))
        }
        var spellings = FilesystemListingPage.NameSelector(capacity: 3, after: nil)
        spellings.consider(composed); spellings.consider(decomposed)
        XCTAssertEqual(spellings.ordered.count, 2)
    }

    func testInvalidUTF8SelectedNameHasExplicitError() throws {
        XCTAssertEqual(try FilesystemListingPage.displayName(Data("valid é".utf8)), "valid é")
        XCTAssertThrowsError(try FilesystemListingPage.displayName(Data([0xff, 0xfe]))) { error in
            XCTAssertEqual((error as? FilesystemListingPage.Failure)?.result.payload["code"] as? String,
                           "listing_name_encoding_unsupported")
        }
    }

    func testScopeFingerprintFencesProjectClientGenerationAndPath() throws {
        let scope = ToolAuthorizationScope(canonicalRoots: [URL(fileURLWithPath: "/tmp")],
            allowedTools: ["fs_list"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let project = ProjectID(UUID()), client = ClientID("listing-scope")
        let original = ToolInvocationContext(projectID: project, projectGeneration: ProjectGeneration(1),
            clientID: client, authorizationScope: scope)
        let baseline = try FilesystemListingPage.scopeFingerprint(context: original, path: "/one")
        for variant in [
            ToolInvocationContext(projectID: ProjectID(UUID()), projectGeneration: original.projectGeneration, clientID: client, authorizationScope: scope),
            ToolInvocationContext(projectID: project, projectGeneration: ProjectGeneration(2), clientID: client, authorizationScope: scope),
            ToolInvocationContext(projectID: project, projectGeneration: original.projectGeneration, clientID: ClientID("other"), authorizationScope: scope)
        ] { XCTAssertNotEqual(try FilesystemListingPage.scopeFingerprint(context: variant, path: "/one"), baseline) }
        XCTAssertNotEqual(try FilesystemListingPage.scopeFingerprint(context: original, path: "/two"), baseline)
    }

    func testFinalResponseIncludesLFAndNeverTrimsAnIssuedCursor() throws {
        let page = ToolResult.success(["entries": ["a", "b"], "next_cursor": "issued-token", "has_more": true])
        let response = MCPToolResponse.object(id: "id", result: page)
        let data = try MCPToolResponse.data(id: "id", result: page)
        let packet = try MCPStdioTransport.encode(response)
        XCTAssertEqual(packet.count, data.count + 1)
        XCTAssertEqual(packet.last, 10)
        let exact = FilesystemListingPage.finalMCPResponse(id: "id", result: page, additiveNotice: nil, budget: packet.count)
        XCTAssertEqual(try listingStructured(exact)["next_cursor"] as? String, "issued-token")
        let tooSmall = FilesystemListingPage.finalMCPResponse(id: "id", result: page, additiveNotice: nil, budget: data.count)
        let failure = try listingStructured(tooSmall)
        XCTAssertEqual(failure["code"] as? String, "listing_output_budget")
        XCTAssertNil(failure["entries"])
        XCTAssertNil(failure["next_cursor"])
        XCTAssertEqual(tooSmall["id"] as? String, "id")
    }

    func testFinalResponseMeasuresActualIDRequiredNoticeAndScopeBudget() throws {
        let page = ToolResult.success(["entries": [String(repeating: "x", count: 1_000)], "next_cursor": "token"])
        let id = String(repeating: "\n\"", count: 2_000), notice = "required notice"
        let full = try MCPStdioTransport.encode(MCPToolResponse.object(id: id, result: page, additiveNotice: notice))
        let rejected = FilesystemListingPage.finalMCPResponse(id: id, result: page, additiveNotice: notice, budget: full.count - 1)
        XCTAssertEqual(rejected["id"] as? String, id)
        XCTAssertEqual(try listingStructured(rejected)["code"] as? String, "listing_output_budget")
        let contents = try XCTUnwrap(rejected["result"] as? [String: Any])["content"] as? [[String: Any]]
        XCTAssertTrue(contents?.contains(where: { ($0["text"] as? String) == notice }) == true)
        XCTAssertLessThan(try MCPStdioTransport.encode(rejected).count, full.count)
        let scope = ToolAuthorizationScope(canonicalRoots: [], allowedTools: ["fs_list"], networkAllowed: false, maximumInlineOutputBytes: 400)
        XCTAssertEqual(FilesystemListingPage.responseBudget(arguments: ["maximum_bytes": 8_000], scope: scope), 400)
        XCTAssertEqual(FilesystemListingPage.responseBudget(arguments: [:], scope: nil), 16_384)
        let impossible = FilesystemListingPage.finalMCPResponse(id: id, result: page, additiveNotice: notice, budget: 1)
        XCTAssertEqual(impossible["id"] as? String, id)
        XCTAssertEqual(try listingStructured(impossible)["code"] as? String, "listing_output_budget")
    }

    func testEmptyDirectoryReturnsExplicitEOF() async throws {
        try await withListingFixture { fixture in
            let result = try fixture.page(["limit": 1])
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["entries"] as? [String], [])
            XCTAssertEqual(result.payload["returned_entries"] as? Int, 0)
            XCTAssertEqual(result.payload["has_more"] as? Bool, false)
            XCTAssertEqual(result.payload["truncated"] as? Bool, false)
            XCTAssertTrue(result.payload["next_cursor"] is NSNull)
            XCTAssertEqual(result.payload["ordering"] as? String, "raw_filename_bytes_v1")
        }
    }

    func testThreeEntryContinuationUsesOnlyReturnedCursors() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["z", "a", "m"])
            var cursor: String?, observed: [String] = []
            for index in 0..<3 {
                var arguments: [String: Any] = ["limit": 1]
                if let cursor { arguments["cursor"] = cursor }
                let page = try fixture.page(arguments)
                XCTAssertTrue(page.ok, "\(page.payload)")
                let names = try XCTUnwrap(page.payload["entries"] as? [String])
                XCTAssertEqual(names.count, 1)
                observed += names
                XCTAssertEqual(page.payload["has_more"] as? Bool, index < 2)
                cursor = page.payload["next_cursor"] as? String
                if index < 2 {
                    let decoded = try FilesystemListingPage.Cursor(try XCTUnwrap(cursor))
                    XCTAssertEqual(decoded.lastName, Data(try XCTUnwrap(names.last).utf8))
                } else { XCTAssertTrue(page.payload["next_cursor"] is NSNull) }
            }
            XCTAssertEqual(observed, ["a", "m", "z"])
        }
    }

    func testThousandAndOneEntryPagesRecoverExactManifest() async throws {
        try await withListingFixture { fixture in
            let manifest = (0..<1_001).map { String(format: "f%04d", $0) }
            try fixture.create(Array(manifest.reversed()))
            var cursor: String?, recovered: [String] = [], reachedEOF = false
            for _ in 0..<20 {
                var arguments: [String: Any] = ["limit": 137, "maximum_bytes": 65_536]
                if let cursor { arguments["cursor"] = cursor }
                let page = try fixture.page(arguments)
                XCTAssertTrue(page.ok, "\(page.payload)")
                let names = try XCTUnwrap(page.payload["entries"] as? [String])
                XCTAssertLessThanOrEqual(names.count, 137)
                XCTAssertEqual(page.payload["returned_entries"] as? Int, names.count)
                recovered += names
                cursor = page.payload["next_cursor"] as? String
                if cursor == nil { reachedEOF = true; XCTAssertEqual(page.payload["has_more"] as? Bool, false); break }
            }
            XCTAssertTrue(reachedEOF)
            XCTAssertEqual(recovered.map { Data($0.utf8) }, manifest.map { Data($0.utf8) })
            XCTAssertEqual(Set(recovered.map { Data($0.utf8) }).count, 1_001)
        }
    }

    func testBudgetReducedPrefixesRetainExactContinuation() async throws {
        try await withListingFixture { fixture in
            let manifest = (0..<12).map { String(format: "f%02d-", $0) + String(repeating: "\n\"😀", count: 18) }
            try fixture.create(manifest)
            var cursor: String?, recovered: [String] = [], sawReduction = false, ended = false
            for _ in 0..<20 {
                var arguments: [String: Any] = ["limit": 12, "maximum_bytes": 3_000]
                if let cursor { arguments["cursor"] = cursor }
                let page = try fixture.page(arguments)
                XCTAssertTrue(page.ok, "\(page.payload)")
                guard page.ok else { break }
                let entries = try XCTUnwrap(page.payload["entries"] as? [String])
                XCTAssertFalse(entries.isEmpty)
                sawReduction = sawReduction || entries.count < 12
                let wire = try MCPStdioTransport.encode(MCPToolResponse.object(id: String(repeating: "x", count: 128), result: page))
                XCTAssertLessThanOrEqual(wire.count, 3_000)
                recovered += entries
                cursor = page.payload["next_cursor"] as? String
                if let cursor {
                    XCTAssertEqual(try FilesystemListingPage.Cursor(cursor).lastName, Data(try XCTUnwrap(entries.last).utf8))
                } else { ended = true; break }
            }
            XCTAssertTrue(sawReduction)
            XCTAssertTrue(ended)
            XCTAssertEqual(recovered.map { Data($0.utf8) }, manifest.map { Data($0.utf8) })
        }
    }

    func testTinyBudgetFailsWithoutFabricatingEOF() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["one"])
            let result = try fixture.page(["maximum_bytes": 1])
            XCTAssertEqual(result.payload["code"] as? String, "listing_output_budget")
            XCTAssertNil(result.payload["has_more"])
            XCTAssertNil(result.payload["next_cursor"])
        }
    }

    func testLegacyBranchPreservesBoundAndPathDeadlineBehavior() async throws {
        try await withListingFixture { fixture in
            try fixture.create((0..<1_001).map { String(format: "f%04d", $0) })
            let cases: [[String: Any]] = [[:], ["deadline_ms": 10_000]]
            for extra in cases {
                let result = try fixture.pack(extra)
                XCTAssertTrue(result.ok, "\(result.payload)")
                XCTAssertEqual((result.payload["entries"] as? [String])?.count, 1_000)
                XCTAssertEqual(result.payload["truncated"] as? Bool, true)
                XCTAssertEqual(result.payload["maximum_entries"] as? Int, 1_000)
                XCTAssertNil(result.payload["next_cursor"])
                XCTAssertNil(result.payload["has_more"])
                XCTAssertEqual(Set(result.payload.keys), ["ok", "path", "entries", "truncated", "maximum_entries"])
            }
        }
    }

    func testCursorScopeRejectsDifferentPathAndBoundClient() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let cursor = try XCTUnwrap(try fixture.page(["limit": 1]).payload["next_cursor"] as? String)
            let other = fixture.root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            XCTAssertEqual(try fixture.page(["limit": 1, "cursor": cursor, "path": other.path]).payload["code"] as? String,
                           "listing_cursor_scope_mismatch")
            let client = ClientID("listing-other")
            _ = try fixture.app.projectContexts.bind(owner: .init(kind: .mcpClient, id: client.rawValue),
                projectID: fixture.context.projectID, generation: fixture.context.projectGeneration,
                authorizationScope: fixture.context.authorizationScope)
            let context = try fixture.app.projectContexts.invocationContext(for: client)
            XCTAssertEqual(try fixture.page(["limit": 1, "cursor": cursor], context: context).payload["code"] as? String,
                           "listing_cursor_scope_mismatch")
        }
    }

    func testContinuationDetectsDirectoryMutationAndCanRestart() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let cursor = try XCTUnwrap(try fixture.page(["limit": 1]).payload["next_cursor"] as? String)
            try fixture.create(["c"])
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: fixture.directory.path)
            let stale = try fixture.page(["limit": 1, "cursor": cursor])
            XCTAssertEqual(stale.payload["code"] as? String, "directory_changed")
            XCTAssertEqual(stale.payload["retryable"] as? Bool, true)
            XCTAssertEqual(try fixture.page(["limit": 10]).payload["entries"] as? [String], ["a", "b", "c"])
        }
    }

    func testScanDetectsMutationBeforeReturningSuccess() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let policy = FilesystemListingPage.ScanPolicy(observe: { observation in
                if case .entry(1) = observation {
                    try fixture.create(["c"])
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: fixture.directory.path)
                }
            })
            XCTAssertEqual(try fixture.page(["limit": 10], policy: policy).payload["code"] as? String, "directory_changed")
        }
    }

    func testScanRejectsReplacementAndNewSymlinkAtFinalPath() async throws {
        for substituteSymlink in [false, true] {
            try await withListingFixture { fixture in
                try fixture.create(["a", "b"])
                let moved = fixture.root.appendingPathComponent("moved-directory")
                let policy = FilesystemListingPage.ScanPolicy(observe: { observation in
                    if case .scanned = observation {
                        try FileManager.default.moveItem(at: fixture.directory, to: moved)
                        if substituteSymlink {
                            try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: moved)
                        } else { try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true) }
                    }
                })
                let result = try fixture.page(["limit": 10], policy: policy)
                XCTAssertEqual(result.payload["code"] as? String, "directory_changed")
                XCTAssertEqual(result.payload["retryable"] as? Bool, true)
            }
        }
    }

    func testFinalCapturedContextValidationRejectsChangedAuthorization() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a"])
            let captured = try fixture.contextAwaitingWebUpgrade()
            XCTAssertFalse(captured.authorizationScope.networkAllowed)
            let policy = FilesystemListingPage.ScanPolicy(observe: { observation in
                if case .scanned = observation {
                    _ = try fixture.app.projectContexts.invocationContext(for: captured.clientID)
                }
            })
            XCTAssertEqual(try fixture.page(["limit": 10], context: captured, policy: policy).payload["code"] as? String, "project_context_stale")
            let current = try fixture.app.projectContexts.invocationContext(for: captured.clientID)
            XCTAssertEqual(current.projectID, captured.projectID)
            XCTAssertEqual(current.projectGeneration, captured.projectGeneration)
            XCTAssertTrue(current.authorizationScope.networkAllowed)
        }
    }

    func testQuotaDistinguishesExactEOFAndOverflow() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let exact = try fixture.page(["limit": 10], policy: .init(maximumNames: 2))
            XCTAssertTrue(exact.ok, "\(exact.payload)")
            XCTAssertTrue(exact.payload["next_cursor"] is NSNull)
            try fixture.create(["c"])
            let excess = try fixture.page(["limit": 10], policy: .init(maximumNames: 2))
            XCTAssertEqual(excess.payload["code"] as? String, "listing_scan_limit")
            XCTAssertNil(excess.payload["has_more"])
            XCTAssertNil(excess.payload["next_cursor"])
        }
    }

    func testCancellationBeforeAndDuringScanPropagates() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let preCancelled = ToolCallCancellation(timeoutSeconds: 10)
            preCancelled.cancel()
            XCTAssertThrowsError(try fixture.page(["limit": 10], cancellation: preCancelled)) { XCTAssertTrue($0 is CancellationError) }
            let during = ToolCallCancellation(timeoutSeconds: 10)
            let policy = FilesystemListingPage.ScanPolicy(observe: { observation in if case .entry(1) = observation { during.cancel() } })
            XCTAssertThrowsError(try fixture.page(["limit": 10], policy: policy, cancellation: during)) { XCTAssertTrue($0 is CancellationError) }
        }
    }

    func testOriginalDeadlineAndIndependentScanDeadlineRemainDistinct() async throws {
        try await withListingFixture { fixture in
            let expired = ToolCallCancellation(timeoutSeconds: 0)
            XCTAssertThrowsError(try fixture.page(["limit": 1], cancellation: expired)) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
            let result = try fixture.page(["limit": 1], policy: .init(maximumSeconds: 0))
            XCTAssertEqual(result.payload["code"] as? String, "listing_scan_deadline")
            XCTAssertNil(result.payload["next_cursor"])
        }
    }

    func testInvalidArgumentsFailBeforeOpeningDirectory() async throws {
        try await withListingFixture { fixture in
            let policy = FilesystemListingPage.ScanPolicy(observe: { _ in XCTFail("Invalid arguments entered the scan") })
            let result = try fixture.page(["limit": true, "path": fixture.root.appendingPathComponent("absent").path], policy: policy)
            XCTAssertEqual(result.payload["code"] as? String, "listing_invalid_argument")
            let malformed = try fixture.page(["cursor": "not!base64"], policy: policy)
            XCTAssertEqual(malformed.payload["code"] as? String, "listing_invalid_cursor")
        }
    }

    func testPagedListingRejectsMainThreadWithoutScanning() async throws {
        let fixture = try await Task.detached(priority: .utility) { try ListingFixture.make() }.value
        do {
            let result = try await MainActor.run {
                try fixture.page(["limit": 1], policy: .init(observe: { _ in XCTFail("Main-thread call entered directory scan") }))
            }
            XCTAssertEqual(result.payload["code"] as? String, "listing_worker_required")
            await Task.detached(priority: .utility) { fixture.close() }.value
        } catch {
            await Task.detached(priority: .utility) { fixture.close() }.value
            throw error
        }
    }

    func testAuthorizedAliasAndOutsideProjectReadsRemainAvailable() async throws {
        try await withListingFixture { fixture in
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data().write(to: outside.appendingPathComponent("outside-file"))
            let alias = fixture.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
            let result = try fixture.app.tools.call(name: "fs_list", arguments: ["path": alias.path, "limit": 1], clientID: fixture.clientID)
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["path"] as? String, RuntimePathCanonicalizer.canonicalExistingURL(outside).path)
            XCTAssertEqual(result.payload["entries"] as? [String], ["outside-file"])
        }
    }

    func testRootDirectoryUsesReadableDescriptorAndBoundedPage() async throws {
        try await withListingFixture { fixture in
            let result = try fixture.page(["path": "/", "limit": 1])
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["path"] as? String, "/")
            XCTAssertLessThanOrEqual((result.payload["entries"] as? [String])?.count ?? Int.max, 1)
        }
    }

    func testRoutedPagedListingRejectsNumericPathBeforeNormalization() async throws {
        try await withListingFixture { fixture in
            let numericPath = fixture.directory.deletingLastPathComponent().appendingPathComponent("3")
            try FileManager.default.createDirectory(at: numericPath, withIntermediateDirectories: true)
            try Data().write(to: numericPath.appendingPathComponent("sentinel"))
            let result = try fixture.app.tools.call(name: "fs_list", arguments: ["path": 3, "limit": 1], clientID: fixture.clientID)
            XCTAssertEqual(result.payload["code"] as? String, "listing_invalid_argument")
            XCTAssertFalse(result.ok)
            XCTAssertNil(result.payload["entries"])
        }
    }

    func testCursorRejectsActualGenerationResetAndRebinding() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let cursor = try XCTUnwrap(try fixture.page(["limit": 1]).payload["next_cursor"] as? String)
            let reset = try ManagerNode(app: fixture.app).resetProjectGeneration(
                projectID: fixture.context.projectID, expectedGeneration: fixture.context.projectGeneration)
            let generation = ProjectGeneration(try XCTUnwrap(reset["new_generation"] as? UInt64))
            XCTAssertNotEqual(generation, fixture.context.projectGeneration)
            XCTAssertEqual(try fixture.page(["cursor": cursor]).payload["code"] as? String, "project_context_stale")
            _ = try fixture.app.projectContexts.bind(owner: .init(kind: .mcpClient, id: fixture.clientID.rawValue),
                projectID: fixture.context.projectID, generation: generation, authorizationScope: fixture.context.authorizationScope)
            let current = try fixture.app.projectContexts.invocationContext(for: fixture.clientID)
            XCTAssertEqual(current.projectGeneration, generation)
            XCTAssertEqual(try fixture.page(["cursor": cursor], context: current).payload["code"] as? String,
                           "listing_cursor_scope_mismatch")
            XCTAssertEqual(try fixture.page(["limit": 10], context: current).payload["entries"] as? [String], ["a", "b"])
        }
    }

    func testCursorRejectsActualProjectSwitchEvenForSameDirectory() async throws {
        try await withListingFixture { fixture in
            try fixture.create(["a", "b"])
            let cursor = try XCTUnwrap(try fixture.page(["limit": 1]).payload["next_cursor"] as? String)
            let project = fixture.root.appendingPathComponent("other-project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let registered = try ManagerNode(app: fixture.app).registerProject(path: project.path)
            let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: try XCTUnwrap(registered["project_id"] as? String))))
            let generation = ProjectGeneration(try XCTUnwrap(registered["project_generation"] as? UInt64))
            let originalScope = fixture.context.authorizationScope
            let scope = ToolAuthorizationScope(canonicalRoots: [project.resolvingSymlinksInPath().standardizedFileURL], allowedTools: originalScope.allowedTools,
                networkAllowed: originalScope.networkAllowed, maximumInlineOutputBytes: originalScope.maximumInlineOutputBytes)
            _ = try ManagerNode(app: fixture.app).resetProjectGeneration(
                projectID: fixture.context.projectID, expectedGeneration: fixture.context.projectGeneration)
            _ = try fixture.app.projectContexts.bind(owner: .init(kind: .mcpClient, id: fixture.clientID.rawValue),
                projectID: projectID, generation: generation, authorizationScope: scope)
            let current = try fixture.app.projectContexts.invocationContext(for: fixture.clientID)
            XCTAssertNotEqual(current.projectID, fixture.context.projectID)
            XCTAssertEqual(try fixture.page(["cursor": cursor]).payload["code"] as? String, "project_context_stale")
            XCTAssertEqual(try fixture.page(["cursor": cursor], context: current).payload["code"] as? String,
                           "listing_cursor_scope_mismatch")
            XCTAssertEqual(try fixture.page(["limit": 10], context: current).payload["entries"] as? [String], ["a", "b"])
        }
    }

    func testReadableDirectoryClosesExactlyOnceOnSuccessAndFailurePaths() async throws {
        for mode in ["success", "cancel", "quota", "context"] {
            try await withListingFixture { fixture in
                try fixture.create(["a", "b"])
                let statuses = Mutex<[Int32]>([])
                let cancellation = ToolCallCancellation(timeoutSeconds: 15)
                let captured = mode == "context" ? try fixture.contextAwaitingWebUpgrade() : fixture.context
                let policy = FilesystemListingPage.ScanPolicy(maximumNames: mode == "quota" ? 0 : 100_000,
                    didClose: { status in statuses.withLock { $0.append(status) } }, observe: { observation in
                        if mode == "cancel", case .entry(1) = observation { cancellation.cancel() }
                        if mode == "context", case .scanned = observation {
                            _ = try fixture.app.projectContexts.invocationContext(for: captured.clientID)
                        }
                    })
                if mode == "cancel" {
                    XCTAssertThrowsError(try fixture.page(["limit": 10], context: captured, policy: policy, cancellation: cancellation)) {
                        XCTAssertTrue($0 is CancellationError)
                    }
                } else {
                    let result = try fixture.page(["limit": 10], context: captured, policy: policy, cancellation: cancellation)
                    if mode == "success" { XCTAssertTrue(result.ok, "\(result.payload)") }
                    else { XCTAssertEqual(result.payload["code"] as? String, mode == "quota" ? "listing_scan_limit" : "project_context_stale") }
                }
                XCTAssertEqual(statuses.withLock { $0 }, [0], "\(mode) must observe exactly one successful closedir")
            }
        }
    }
}

private func listingCursor(_ name: Data) throws -> FilesystemListingPage.Cursor {
    try .init(scopeFingerprint: String(repeating: "a", count: 64),
              directoryFingerprint: String(repeating: "b", count: 64), lastName: name)
}

private func listingBase64URL(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func listingStructured(_ response: [String: Any]) throws -> [String: Any] {
    let result = try XCTUnwrap(response["result"] as? [String: Any])
    return try XCTUnwrap(result["structuredContent"] as? [String: Any])
}

/// All bootstrap, traversal and shutdown work runs on an owned utility task.
private func withListingFixture(_ operation: @escaping @Sendable (ListingFixture) throws -> Void) async throws {
    try await Task.detached(priority: .utility) {
        let fixture = try ListingFixture.make()
        defer { fixture.close() }
        try operation(fixture)
    }.value
}

private struct ListingFixture: Sendable {
    let root: URL
    let directory: URL
    let app: ForgeApp
    let context: ToolInvocationContext
    var clientID: ClientID { context.clientID }

    static func make() throws -> ListingFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-listing-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project"), directory = project.appendingPathComponent("listing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var app: ForgeApp?
        do {
            let instance = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"), startTelemetry: false)
            app = instance
            _ = try instance.config.update(["allowed_roots": [root.path]], save: false)
            let client = ClientID("listing-fixture")
            let initialized = try instance.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
            guard initialized.ok else { throw RuntimeJobError.invalidRequest("listing fixture initialization failed: \(initialized.payload)") }
            return ListingFixture(root: root, directory: directory, app: instance,
                                  context: try instance.projectContexts.invocationContext(for: client))
        } catch { app?.shutdown(); try? FileManager.default.removeItem(at: root); throw error }
    }

    func create(_ names: [String]) throws {
        for name in names { try Data().write(to: directory.appendingPathComponent(name)) }
    }

    func contextAwaitingWebUpgrade() throws -> ToolInvocationContext {
        let client = ClientID("listing-legacy-web-upgrade")
        let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
        let scope = ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
            writableRoots: context.authorizationScope.writableRoots, allowedTools: ["*"], networkAllowed: false,
            maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes)
        _ = try app.projectContexts.bind(owner: owner, projectID: context.projectID,
            generation: context.projectGeneration, authorizationScope: scope)
        return try app.projectContexts.invocationContext(for: owner, clientID: client)
    }

    func page(_ values: [String: Any], context supplied: ToolInvocationContext? = nil,
              policy: FilesystemListingPage.ScanPolicy = .init(), cancellation: ToolCallCancellation? = nil) throws -> ToolResult {
        let context = supplied ?? self.context
        return try FilesystemListingPage.list(arguments: values.merging(["path": directory.path]) { existing, _ in existing },
            context: context, clientID: context.clientID, app: app,
            cancellation: cancellation ?? ToolCallCancellation(timeoutSeconds: 15), policy: policy)
    }

    func pack(_ values: [String: Any]) throws -> ToolResult {
        try XCTUnwrap(FilesystemToolPack().handle(name: "fs_list",
            arguments: values.merging(["path": directory.path]) { existing, _ in existing },
            context: context, clientID: clientID, app: app, cancellation: ToolCallCancellation(timeoutSeconds: 15)))
    }

    func close() { app.shutdown(); try? FileManager.default.removeItem(at: root) }
}
