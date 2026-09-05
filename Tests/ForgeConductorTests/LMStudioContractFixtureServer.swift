import Foundation

private final class BootstrapSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var requests: [ObjectIdentifier: @Sendable () -> Void] = [:]
    var isEnabled: Bool { lock.withLock { enabled } }
    var count: Int { lock.withLock { requests.count } }
    func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
    func insert(_ request: ObjectIdentifier, resume: @escaping @Sendable () -> Void) {
        lock.withLock { requests[request] = resume }
    }
    func remove(_ request: ObjectIdentifier) { _ = lock.withLock { requests.removeValue(forKey: request) } }
    func resumeAll() {
        let callbacks = lock.withLock {
            let callbacks = Array(requests.values)
            requests.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
    }
}

/// Deterministic URLSession transport for LM Studio contract tests.
/// It is compiled only into the test target and cannot be registered by product code.
final class LMStudioContractFixtureServer: URLProtocol, @unchecked Sendable {
    private static let suspension = BootstrapSuspension()
    static func suspendBootstrapRequests(_ enabled: Bool) { suspension.setEnabled(enabled) }
    static var suspendedBootstrapCount: Int { suspension.count }
    static func resumeBootstrapRequests() { suspension.resumeAll() }
    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LMStudio", isDirectory: true)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "lmstudio.fixture"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            fail(code: 400, message: "missing URL")
            return
        }

        do {
            let route = try Self.route(request)
            if route.suspendBootstrap {
                stateLock.withLock {
                    guard !stopped else { return }
                    suspendedBootstrap = true
                    Self.suspension.insert(ObjectIdentifier(self)) { [weak self] in
                        self?.deliver(route, url: url)
                    }
                }
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                if route.delay > 0 {
                    Thread.sleep(forTimeInterval: route.delay)
                }
                self?.deliver(route, url: url)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let wasSuspended = suspendedBootstrap
        suspendedBootstrap = false
        if wasSuspended { Self.suspension.remove(ObjectIdentifier(self)) }
        stateLock.unlock()
    }

    private struct Route: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var delay: TimeInterval = 0
        var firstByteDelay: TimeInterval = 0
        var interChunkDelay: TimeInterval = 0
        var failureAfterFirstChunk: URLError.Code?
        var suspendBootstrap = false
    }

    private let stateLock = NSLock()
    private var stopped = false
    private var suspendedBootstrap = false

    private func deliver(_ route: Route, url: URL) {
        stateLock.lock()
        let shouldStop = stopped
        stateLock.unlock()
        guard !shouldStop else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: route.status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": route.contentType,
                "X-LM-Studio-Version": "0.3.fixture",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if route.firstByteDelay > 0 {
            Thread.sleep(forTimeInterval: route.firstByteDelay)
        }
        for (index, chunk) in Self.fragment(route.body).enumerated() {
            if index > 0, route.interChunkDelay > 0 {
                Thread.sleep(forTimeInterval: route.interChunkDelay)
            }
            stateLock.lock()
            let shouldStop = stopped
            stateLock.unlock()
            if shouldStop { return }
            client?.urlProtocol(self, didLoad: chunk)
            if index == 0, let failure = route.failureAfterFirstChunk {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func route(_ request: URLRequest) throws -> Route {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/models"):
            return try fixture("models-loaded", extension: "json", contentType: "application/json")
        case ("POST", "/v1/responses"):
            let object = try requestObject(request)
            let requestText = String(
                data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                encoding: .utf8
            ) ?? ""
            let shouldSuspend = requestText.contains("fixture-suspend-bootstrap") && Self.suspension.isEnabled
            if requestText.contains("fixture-error-401") {
                return errorRoute(status: 401, code: "invalid_api_token")
            }
            if requestText.contains("fixture-error-403") {
                return errorRoute(status: 403, code: "permission_denied")
            }
            if requestText.contains("fixture-error-404") {
                return errorRoute(status: 404, code: "model_not_found")
            }
            if requestText.contains("fixture-error-409") {
                return errorRoute(status: 409, code: "response_conflict")
            }
            if requestText.contains("fixture-error-429") {
                return errorRoute(status: 429, code: "rate_limit_exceeded")
            }
            if requestText.contains("fixture-error-500") {
                return errorRoute(status: 500, code: "server_error")
            }
            if requestText.contains("fixture-context-overflow") {
                return errorRoute(status: 400, code: "context_length_exceeded")
            }
            if requestText.contains("fixture-response-truncated") {
                return errorRoute(status: 400, code: "response_truncated")
            }
            if requestText.contains("fixture-require-output-token-bound"),
               object["max_output_tokens"] as? Int != 321 {
                return errorRoute(status: 400, code: "missing_output_token_bound")
            }
            if requestText.contains("fixture-require-auth"),
               request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture-token" {
                return errorRoute(status: 401, code: "invalid_api_token")
            }
            if requestText.contains("fixture-first-byte-timeout") {
                var delayed = try fixture(
                    "responses-root", extension: "sse", contentType: "text/event-stream"
                )
                delayed.firstByteDelay = 0.25
                return delayed
            }
            if requestText.contains("fixture-connect-timeout") {
                var delayed = try fixture(
                    "responses-root", extension: "sse", contentType: "text/event-stream"
                )
                delayed.delay = 0.25
                return delayed
            }
            if requestText.contains("fixture-total-timeout") {
                var delayed = try fixture(
                    "responses-root", extension: "sse", contentType: "text/event-stream"
                )
                delayed.interChunkDelay = 0.02
                return delayed
            }
            if requestText.contains("fixture-idle-timeout") {
                var delayed = try fixture(
                    "responses-root", extension: "sse", contentType: "text/event-stream"
                )
                delayed.interChunkDelay = 0.12
                return delayed
            }
            if requestText.contains("fixture-disconnect") {
                var disconnected = try fixture(
                    "responses-root", extension: "sse", contentType: "text/event-stream"
                )
                disconnected.failureAfterFirstChunk = .networkConnectionLost
                return disconnected
            }
            if requestText.contains("fixture-malformed-sse") {
                return Route(
                    status: 200, contentType: "text/event-stream",
                    body: Data("data: {not-json}\n\n".utf8)
                )
            }
            if requestText.contains("fixture-oversized-sse") {
                return Route(
                    status: 200, contentType: "text/event-stream",
                    body: Data(("data: " + String(repeating: "x", count: 4096) + "\n\n").utf8)
                )
            }
            if object["previous_response_id"] == nil {
                if let route = try capabilityProbeRoute(object) { return route }
                var route = try v2BootstrapRoute(object)
                    ?? fixture("responses-root", extension: "sse", contentType: "text/event-stream")
                route.suspendBootstrap = shouldSuspend
                return route
            }
            guard object["previous_response_id"] as? String == "resp_lms_fixture_root" else {
                return errorRoute(status: 409, code: "previous_response_mismatch")
            }
            return try fixture("responses-continuation", extension: "sse", contentType: "text/event-stream")
        case ("GET", "/fixture/errors/401"):
            return errorRoute(status: 401, code: "invalid_api_token")
        case ("GET", "/fixture/errors/403"):
            return errorRoute(status: 403, code: "permission_denied")
        case ("GET", "/fixture/errors/404"):
            return errorRoute(status: 404, code: "model_not_found")
        case ("GET", "/fixture/errors/409"):
            return errorRoute(status: 409, code: "response_conflict")
        case ("GET", "/fixture/errors/429"):
            return errorRoute(status: 429, code: "rate_limit_exceeded")
        case ("GET", "/fixture/errors/500"):
            return errorRoute(status: 500, code: "server_error")
        default:
            return errorRoute(status: 404, code: "fixture_route_not_found")
        }
    }

    private static func fixture(_ name: String, extension value: String, contentType: String) throws -> Route {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("\(name).\(value)"))
        return Route(status: 200, contentType: contentType, body: data)
    }

    private static func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let body: Data
        if let direct = request.httpBody {
            body = direct
        } else if let stream = request.httpBodyStream {
            body = try readBounded(stream, maximumBytes: 1_048_576)
        } else {
            throw NSError(domain: "LMStudioContractFixtureServer", code: 400)
        }
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw NSError(domain: "LMStudioContractFixtureServer", code: 400)
        }
        return value
    }

    private static func readBounded(_ stream: InputStream, maximumBytes: Int) throws -> Data {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? NSError(domain: "LMStudioContractFixtureServer", code: 400)
            }
            if count == 0 { break }
            guard result.count + count <= maximumBytes else {
                throw NSError(domain: "LMStudioContractFixtureServer", code: 413)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func errorRoute(status: Int, code: String) -> Route {
        let body = try! JSONSerialization.data(withJSONObject: [
            "error": ["code": code, "message": "Deterministic fixture error"],
        ], options: [.sortedKeys])
        return Route(status: status, contentType: "application/json", body: body)
    }

    private static func capabilityProbeRoute(_ request: [String: Any]) throws -> Route? {
        guard let tools = request["tools"] as? [[String: Any]],
              tools.count == 1,
              let tool = tools.first,
              tool["type"] as? String == "function",
              tool["name"] as? String == "forge_provider_contract_probe",
              tool["strict"] as? Bool == true,
              let parameters = tool["parameters"] as? [String: Any],
              parameters["type"] as? String == "object",
              parameters["additionalProperties"] as? Bool == false,
              Set(parameters["required"] as? [String] ?? [])
                == Set(["contract_version", "accepted"]),
              let model = request["model"] as? String else { return nil }
        let arguments = #"{"accepted":true,"contract_version":1}"#
        let item: [String: Any] = [
            "id": "fc_lms_contract_probe", "type": "function_call",
            "status": "completed", "arguments": arguments,
            "call_id": "call_lms_contract_probe",
            "name": "forge_provider_contract_probe",
        ]
        let events: [(String, [String: Any])] = [
            ("response.created", [
                "type": "response.created", "sequence_number": 0,
                "response": [
                    "id": "resp_lms_contract_probe", "object": "response",
                    "created_at": 1_787_760_000, "status": "in_progress",
                    "model": model, "output": [],
                    "previous_response_id": NSNull(), "usage": NSNull(),
                ] as [String: Any],
            ]),
            ("response.output_item.added", [
                "type": "response.output_item.added", "sequence_number": 1,
                "output_index": 0,
                "item": [
                    "id": "fc_lms_contract_probe", "type": "function_call",
                    "status": "in_progress", "arguments": "",
                    "call_id": "call_lms_contract_probe",
                    "name": "forge_provider_contract_probe",
                ] as [String: Any],
            ]),
            ("response.function_call_arguments.done", [
                "type": "response.function_call_arguments.done", "sequence_number": 2,
                "item_id": "fc_lms_contract_probe", "output_index": 0,
                "name": "forge_provider_contract_probe", "arguments": arguments,
            ]),
            ("response.completed", [
                "type": "response.completed", "sequence_number": 3,
                "response": [
                    "id": "resp_lms_contract_probe", "object": "response",
                    "created_at": 1_787_760_000, "completed_at": 1_787_760_001,
                    "status": "completed", "model": model, "output": [item],
                    "previous_response_id": NSNull(),
                    "usage": ["input_tokens": 24, "output_tokens": 8, "total_tokens": 32],
                ] as [String: Any],
            ]),
        ]
        return try eventStream(events)
    }

    private static func eventStream(_ events: [(String, [String: Any])]) throws -> Route {
        var stream = Data()
        for (event, payload) in events {
            let payloadData = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
            )
            stream.append(Data("event: \(event)\ndata: ".utf8))
            stream.append(payloadData)
            stream.append(Data("\n\n".utf8))
        }
        stream.append(Data("data: [DONE]\n".utf8))
        return Route(status: 200, contentType: "text/event-stream", body: stream)
    }

    private static func v2BootstrapRoute(_ request: [String: Any]) throws -> Route? {
        guard let tools = request["tools"] as? [[String: Any]],
              let acknowledgementTool = tools.first(where: {
                  $0["name"] as? String == "forge_continuity_ack"
              }),
              let parameters = acknowledgementTool["parameters"] as? [String: Any],
              let properties = parameters["properties"] as? [String: Any],
              properties["acknowledgement_contract_version"] != nil else {
            return nil
        }
        guard let input = request["input"] as? [[String: Any]],
              let user = input.first(where: { $0["role"] as? String == "user" }),
              let content = user["content"] as? [[String: Any]],
              let handoffText = content.first?["text"] as? String,
              let handoffData = handoffText.data(using: .utf8),
              let handoff = try JSONSerialization.jsonObject(with: handoffData) as? [String: Any],
              let project = handoff["project"] as? [String: Any],
              let run = handoff["run"] as? [String: Any],
              let bootstrap = handoff["bootstrap"] as? [String: Any],
              let integrity = handoff["integrity"] as? [String: Any],
              let operationID = handoff["operation_id"] as? String,
              let handoffID = handoff["handoff_id"] as? String,
              let projectID = project["project_id"] as? String,
              let generation = project["generation"] as? Int,
              let runID = run["run_id"] as? String,
              let version = bootstrap["acknowledgement_contract_version"] as? Int,
              var nonce = bootstrap["nonce"] as? String,
              let checksum = integrity["content_sha256"] as? String,
              let model = request["model"] as? String else {
            throw NSError(domain: "LMStudioContractFixtureServer", code: 422)
        }

        let mission = handoff["mission"] as? String ?? ""
        if mission.contains("fixture-mismatch-nonce") { nonce += "-mismatch" }
        let responseID: String
        if mission.contains("fixture-synthetic-provider-id") {
            responseID = "native-fixture-synthetic"
        } else {
            responseID = "resp_lms_v2_" + operationID.replacingOccurrences(of: "-", with: "")
        }
        let acknowledgement: [String: Any] = [
            "acknowledgement_contract_version": version,
            "project_id": projectID,
            "project_generation": generation,
            "run_id": runID,
            "operation_id": operationID.lowercased(),
            "handoff_id": handoffID.lowercased(),
            "handoff_sha256": checksum,
            "nonce": nonce,
            "accepted": true,
        ]
        let argumentsData = try JSONSerialization.data(
            withJSONObject: acknowledgement, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let arguments = String(data: argumentsData, encoding: .utf8) else {
            throw NSError(domain: "LMStudioContractFixtureServer", code: 500)
        }
        let item: [String: Any] = [
            "id": "fc_lms_v2_ack", "type": "function_call", "status": "completed",
            "arguments": arguments, "call_id": "call_lms_v2_ack",
            "name": "forge_continuity_ack",
        ]
        let events: [(String, [String: Any])] = [
            ("response.created", [
                "type": "response.created", "sequence_number": 0,
                "response": [
                    "id": responseID, "object": "response", "created_at": 1_787_760_000,
                    "status": "in_progress", "model": model, "output": [],
                    "previous_response_id": NSNull(), "usage": NSNull(),
                ] as [String: Any],
            ]),
            ("response.output_item.added", [
                "type": "response.output_item.added", "sequence_number": 1,
                "output_index": 0,
                "item": [
                    "id": "fc_lms_v2_ack", "type": "function_call",
                    "status": "in_progress", "arguments": "",
                    "call_id": "call_lms_v2_ack", "name": "forge_continuity_ack",
                ] as [String: Any],
            ]),
            ("response.function_call_arguments.delta", [
                "type": "response.function_call_arguments.delta", "sequence_number": 2,
                "item_id": "fc_lms_v2_ack", "output_index": 0, "delta": arguments,
            ]),
            ("response.function_call_arguments.done", [
                "type": "response.function_call_arguments.done", "sequence_number": 3,
                "item_id": "fc_lms_v2_ack", "output_index": 0,
                "name": "forge_continuity_ack", "arguments": arguments,
            ]),
            ("response.completed", [
                "type": "response.completed", "sequence_number": 4,
                "response": [
                    "id": responseID, "object": "response", "created_at": 1_787_760_000,
                    "completed_at": 1_787_760_001, "status": "completed", "model": model,
                    "output": [item], "previous_response_id": NSNull(),
                    "usage": ["input_tokens": 640, "output_tokens": 48, "total_tokens": 688],
                ] as [String: Any],
            ]),
        ]
        var stream = Data()
        for (event, payload) in events {
            let payloadData = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
            )
            stream.append(Data("event: \(event)\ndata: ".utf8))
            stream.append(payloadData)
            stream.append(Data("\n\n".utf8))
        }
        stream.append(Data("data: [DONE]\n".utf8))
        return Route(status: 200, contentType: "text/event-stream", body: stream)
    }

    private static func fragment(_ data: Data) -> [Data] {
        let sizes = [1, 2, 3, 5, 8, 13, 21]
        var result: [Data] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let count = min(sizes[index % sizes.count], data.count - offset)
            result.append(data.subdata(in: offset..<(offset + count)))
            offset += count
            index += 1
        }
        return result
    }

    private func fail(code: Int, message: String) {
        client?.urlProtocol(
            self,
            didFailWithError: NSError(
                domain: "LMStudioContractFixtureServer",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }
}
