import Foundation
import XCTest

final class LMStudioContractFixtureTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LMStudioContractFixtureServer.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testLoadedModelFixtureDeclaresToolCapabilityAndContext() async throws {
        let request = URLRequest(url: URL(string: "http://lmstudio.fixture/api/v1/models")!)
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let model = try XCTUnwrap((root["models"] as? [[String: Any]])?.first)
        let capability = try XCTUnwrap(model["capabilities"] as? [String: Any])
        let instance = try XCTUnwrap((model["loaded_instances"] as? [[String: Any]])?.first)
        let config = try XCTUnwrap(instance["config"] as? [String: Any])
        XCTAssertEqual(model["key"] as? String, "fixture/tool-model")
        XCTAssertEqual(capability["trained_for_tool_use"] as? Bool, true)
        XCTAssertEqual(config["context_length"] as? Int, 32_768)
        XCTAssertEqual(model["max_context_length"] as? Int, 131_072)
    }

    func testRootAndContinuationResponsesRemainDistinct() async throws {
        let root = try await postResponse([
            "model": "fixture/tool-model",
            "store": true,
            "stream": true,
            "input": "bounded handoff",
        ])
        XCTAssertTrue(root.contains("resp_lms_fixture_root"))
        XCTAssertTrue(root.contains("forge_continuity_ack"))
        XCTAssertTrue(root.contains("\"previous_response_id\":null"))
        let rootEvents = try events(from: root)
        XCTAssertEqual(rootEvents.first?["type"] as? String, "response.created")
        XCTAssertEqual(rootEvents.last?["type"] as? String, "response.completed")
        let deltas = rootEvents
            .filter { $0["type"] as? String == "response.function_call_arguments.delta" }
            .compactMap { $0["delta"] as? String }
            .joined()
        let done = try XCTUnwrap(rootEvents.first {
            $0["type"] as? String == "response.function_call_arguments.done"
        }?["arguments"] as? String)
        XCTAssertEqual(deltas, done)
        let acknowledgment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(done.utf8)) as? [String: Any]
        )
        XCTAssertEqual(acknowledgment["schema_version"] as? Int, 2)
        XCTAssertEqual(acknowledgment["bootstrap_nonce"] as? String, "fixture-nonce-0001")

        let continuation = try await postResponse([
            "model": "fixture/tool-model",
            "store": true,
            "stream": true,
            "previous_response_id": "resp_lms_fixture_root",
            "input": [["type": "function_call_output", "call_id": "call_lms_fixture_ack", "output": "{}"]],
        ])
        XCTAssertTrue(continuation.contains("resp_lms_fixture_continuation"))
        XCTAssertTrue(continuation.contains("Continuation accepted."))
        XCTAssertTrue(continuation.contains("\"previous_response_id\":\"resp_lms_fixture_root\""))
    }

    func testErrorFixturesAreTypedAndBounded() async throws {
        for (path, status, code) in [
            ("401", 401, "invalid_api_token"),
            ("429", 429, "rate_limit_exceeded"),
            ("500", 500, "server_error"),
        ] {
            let request = URLRequest(url: URL(string: "http://lmstudio.fixture/fixture/errors/\(path)")!)
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertLessThan(data.count, 1024)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let error = try XCTUnwrap(root["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, code)
        }
    }

    private func postResponse(_ object: [String: Any]) async throws -> String {
        var request = URLRequest(url: URL(string: "http://lmstudio.fixture/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func events(from stream: String) throws -> [[String: Any]] {
        try stream.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("data: ") else { return nil }
            let payload = line.dropFirst(6)
            guard payload != "[DONE]" else { return nil }
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            )
        }
    }
}
