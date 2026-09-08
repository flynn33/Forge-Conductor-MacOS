import Foundation
import XCTest
@testable import ForgeConductorCore

final class NativeSourceOperatorTests: XCTestCase, @unchecked Sendable {
    func testClosedRequestsPreserveExactInputAndRejectAuthorityAndIntegerExtensions() throws {
        let taskID = UUID(), requestID = UUID()
        let request = try NativeSourceSendRequest(taskID: taskID, requestID: requestID, input: "  Read the file.\n")
        XCTAssertEqual(try NativeSourceSendRequest(data: request.canonicalRequestJSON), request)
        XCTAssertEqual(request.input, "  Read the file.\n")
        let numericText = try NativeSourceSendRequest(taskID: taskID, requestID: requestID, input: "Keep 1.0 and 1e0 unchanged")
        XCTAssertEqual(try NativeSourceSendRequest(data: numericText.canonicalRequestJSON), numericText)
        let escapedKey = String(decoding: request.canonicalRequestJSON, as: UTF8.self)
            .replacingOccurrences(of: "schema_version", with: "schema_\\u0076ersion")
        XCTAssertEqual(try NativeSourceSendRequest(data: Data(escapedKey.utf8)), request)
        XCTAssertThrowsError(try NativeSourceSendRequest(data: Data(escapedKey
            .replacingOccurrences(of: "\":1,", with: "\":1e0,").utf8)))
        let changed = try NativeSourceSendRequest(taskID: taskID, requestID: requestID, input: "Read the file.")
        XCTAssertNotEqual(changed.requestSHA256, request.requestSHA256)
        var object = try JSONSupport.object(from: request.canonicalRequestJSON)
        for key in ["provider_id", "model_key", "project_id", "credential", "deadline_ms", "conversation_id"] {
            var extended = object; extended[key] = "untrusted"
            XCTAssertThrowsError(try NativeSourceSendRequest(arguments: extended), key)
        }
        object["input"] = NSNull()
        XCTAssertThrowsError(try NativeSourceSendRequest(arguments: object))
        let raw = String(decoding: request.canonicalRequestJSON, as: UTF8.self)
        for replacement in ["true", "1.0", "1e0", "9007199254740993"] {
            let altered = raw.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":" + replacement)
            XCTAssertThrowsError(try NativeSourceSendRequest(data: Data(altered.utf8)), replacement)
        }
        XCTAssertNoThrow(try NativeSourceSendRequest(taskID: taskID, requestID: requestID,
            input: String(repeating: "x", count: NativeSourceSendRequest.maximumInputBytes)))
        XCTAssertThrowsError(try NativeSourceSendRequest(taskID: taskID, requestID: requestID,
            input: String(repeating: "x", count: NativeSourceSendRequest.maximumInputBytes + 1)))
        XCTAssertThrowsError(try NativeSourceSendRequest(taskID: taskID, requestID: requestID, input: "bad\0input"))
        let cancellation = try NativeSourceCancelRequest(taskID: taskID, requestID: requestID,
            cancelRequestID: UUID(), reason: "Stop this exchange")
        XCTAssertEqual(try NativeSourceCancelRequest(data: cancellation.canonicalRequestJSON), cancellation)
        let statusRequest = try NativeSourceStatusRequest(taskID: taskID, requestID: requestID)
        for spelling in ["1.0", "1e0", "1E+0"] {
            let statusBytes = String(decoding: statusRequest.canonicalRequestJSON, as: UTF8.self)
                .replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":" + spelling)
            XCTAssertThrowsError(try NativeSourceStatusRequest(data: Data(statusBytes.utf8)))
            let cancelBytes = String(decoding: cancellation.canonicalRequestJSON, as: UTF8.self)
                .replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":" + spelling)
            XCTAssertThrowsError(try NativeSourceCancelRequest(data: Data(cancelBytes.utf8)))
        }
        var fractionalArguments = try JSONSupport.object(from: request.canonicalRequestJSON)
        fractionalArguments["schema_version"] = NSNumber(value: 1.0)
        XCTAssertThrowsError(try NativeSourceSendRequest(arguments: fractionalArguments))
        XCTAssertThrowsError(try NativeSourceCancelRequest(taskID: taskID, requestID: requestID,
            cancelRequestID: UUID(), reason: "bad\nreason"))
        var status = try JSONSupport.object(from: NativeSourceStatusRequest(taskID: taskID, requestID: requestID).canonicalRequestJSON)
        status["task_id"] = taskID.uuidString.uppercased()
        XCTAssertThrowsError(try NativeSourceStatusRequest(arguments: status))
    }

    func testClientPreservesRequestIdentityAndNeverRepostsAnAmbiguousCommandAutomatically() async throws {
        try await withClient { client, transport, _ in
            let request = try NativeSourceSendRequest(taskID: UUID(), requestID: UUID(), input: "Private operator input")
            let response = try await client.sendSource(request)
            XCTAssertEqual(response.taskID, request.taskID)
            XCTAssertEqual(response.requestID, request.requestID)
            XCTAssertFalse(String(decoding: response.canonicalJSON, as: UTF8.self).contains(request.input))
            _ = try await client.sourceStatus(NativeSourceStatusRequest(taskID: request.taskID, requestID: request.requestID))
            _ = try await client.cancelSource(NativeSourceCancelRequest(taskID: request.taskID,
                requestID: request.requestID, cancelRequestID: UUID()))
            let observed = await transport.requests()
            XCTAssertEqual(observed.map(\.0), ["send", "status", "cancel"])
            XCTAssertEqual(observed[0].1, request.canonicalRequestJSON)
            await transport.setMode(.ambiguous)
            do { _ = try await client.sendSource(request); XCTFail("Unknown operator result was accepted") }
            catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
            let afterLoss = await transport.requests()
            XCTAssertEqual(afterLoss.count, 4)
            XCTAssertEqual(afterLoss.last?.1, request.canonicalRequestJSON)
            await transport.setMode(.foreignTask)
            do { _ = try await client.sendSource(request); XCTFail("Foreign task response was accepted") }
            catch { XCTAssertEqual(error as? NativeSourceOperatorError, .invalidResponse) }
        }
    }

    func testSourceCommandLineUsesExactUUIDsAndBoundedInputFile() async throws {
        try await withClient { client, transport, root in
            let taskID = UUID().uuidString.lowercased(), requestID = UUID().uuidString.lowercased()
            let inputURL = root.appendingPathComponent("input.txt")
            try Data("  Exact input\n".utf8).write(to: inputURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
            let args = ["send", "--task", taskID, "--request-id", requestID, "--input-file", inputURL.path]
            let data = try await NativeTaskOperatorCommandLine.execute(.init(args), client: client)
            XCTAssertEqual(try NativeSourceOperatorResponse(data: data).requestID.uuidString.lowercased(), requestID)
            let calls = await transport.requests()
            XCTAssertEqual(try NativeSourceSendRequest(data: calls[0].1).input, "  Exact input\n")
            XCTAssertThrowsError(try NativeTaskOperatorCommandLine.Options(args + ["--token", "secret"]))
            XCTAssertThrowsError(try NativeTaskOperatorCommandLine.Options(args + ["--request-id", requestID]))
            XCTAssertThrowsError(try NativeTaskOperatorCommandLine.Options(["send", "--task", taskID, "--input-file", inputURL.path]))
            try Data(repeating: 120, count: NativeSourceSendRequest.maximumInputBytes + 1).write(to: inputURL)
            do {
                _ = try await NativeTaskOperatorCommandLine.execute(.init(args), client: client)
                XCTFail("Oversized input reached the transport")
            } catch { }
            let finalCalls = await transport.requests()
            XCTAssertEqual(finalCalls.count, 1)
        }
    }

    func testResponseBoundsClosedFieldsAndExactRevision() throws {
        var object = SourceOperatorTransportFixture.response(taskID: UUID(), requestID: UUID(), action: "status")
        object["provider_response_id"] = "private-response"
        XCTAssertThrowsError(try NativeSourceOperatorResponse(arguments: object))
        object.removeValue(forKey: "provider_response_id")
        object["assistant_preview"] = String(repeating: "x", count: 8_193)
        object["assistant_truncated"] = true
        object["assistant_sha256"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try NativeSourceOperatorResponse(arguments: object))
        object.removeValue(forKey: "assistant_preview")
        object.removeValue(forKey: "assistant_truncated")
        object.removeValue(forKey: "assistant_sha256")
        object["handoff"] = ["continuity_id": "exact-handoff", "revision": Int64.max,
            "packet_sha256": String(repeating: "b", count: 64), "operation_id": UUID().uuidString.lowercased()]
        let valid = try NativeSourceOperatorResponse(arguments: object)
        XCTAssertEqual(try NativeSourceOperatorResponse(data: valid.canonicalJSON), valid)
        for (field, old, replacement) in [("schema_version", "1", "1e0"), ("stage_ordinal", "1", "1.0"),
                                           ("revision", "9223372036854775807", "9223372036854775807.0")] {
            let noninteger = String(decoding: valid.canonicalJSON, as: UTF8.self)
                .replacingOccurrences(of: "\"" + field + "\":" + old, with: "\"" + field + "\":" + replacement)
            XCTAssertThrowsError(try NativeSourceOperatorResponse(data: Data(noninteger.utf8)), field)
        }
        let malformed = String(decoding: valid.canonicalJSON, as: UTF8.self)
            .replacingOccurrences(of: "\"revision\":9223372036854775807", with: "\"revision\":9223372036854775808")
        XCTAssertThrowsError(try NativeSourceOperatorResponse(data: Data(malformed.utf8)))
        XCTAssertThrowsError(try NativeSourceOperatorResponse(data: Data(repeating: 32, count: 32_769)))
    }

    private func withClient(_ body: (NativeTaskOperatorClient, SourceOperatorTransportFixture, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-source-operator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SourceOperatorTransportFixture()
        let client = try NativeTaskOperatorClient(store: NativeTaskCredentialFileStore(paths: AppPaths(home: root)),
            transport: transport, endpoint: URL(string: "http://127.0.0.1:7788/mcp/continuity")!)
        try await body(client, transport, root)
    }
}

private actor SourceOperatorTransportFixture: NativeTaskOperatorTransport, NativeSourceOperatorTransport {
    enum Mode { case success, ambiguous, foreignTask }
    private var mode = Mode.success
    private var retained: [(String, Data)] = []
    func setMode(_ value: Mode) { mode = value }
    func requests() -> [(String, Data)] { retained }
    func submitNativeTaskCommand(action: String, body: Data) async throws -> NativeTaskCapabilityCommandResult {
        throw NativeSourceOperatorError.unavailable
    }
    func submitNativeSourceCommand(action: String, body: Data) async throws -> Data {
        retained.append((action, body))
        if mode == .ambiguous { throw URLError(.networkConnectionLost) }
        let object = try JSONSupport.object(from: body)
        let taskID = try (mode == .foreignTask ? UUID() : NativeSourceOperatorWire.uuid(object, "task_id"))
        let requestID = try NativeSourceOperatorWire.uuid(object, "request_id")
        return try NativeSourceOperatorResponse(arguments: Self.response(taskID: taskID, requestID: requestID, action: action)).canonicalJSON
    }
    nonisolated static func response(taskID: UUID, requestID: UUID, action: String) -> [String: Any] {
        ["schema_version": 1, "ok": true, "task_id": taskID.uuidString.lowercased(),
         "request_id": requestID.uuidString.lowercased(), "conversation_id": UUID().uuidString.lowercased(),
         "stage_id": UUID().uuidString.lowercased(), "disposition": action == "send" ? "accepted" : action == "cancel" ? "cancel_requested" : "observed",
         "conversation_state": "active", "stage_state": "prepared", "stage_ordinal": 1,
         "deadline": ISO8601.string(from: Date().addingTimeInterval(300)), "intent_sha256": String(repeating: "a", count: 64)]
    }
}
