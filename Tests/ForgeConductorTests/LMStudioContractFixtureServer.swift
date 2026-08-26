import Foundation

/// Deterministic URLSession transport for LM Studio contract tests.
/// It is compiled only into the test target and cannot be registered by product code.
final class LMStudioContractFixtureServer: URLProtocol, @unchecked Sendable {
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
            let response = HTTPURLResponse(
                url: url,
                statusCode: route.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": route.contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in Self.fragment(route.body) {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private struct Route {
        var status: Int
        var contentType: String
        var body: Data
    }

    private static func route(_ request: URLRequest) throws -> Route {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/v1/models"):
            return try fixture("models-loaded", extension: "json", contentType: "application/json")
        case ("POST", "/v1/responses"):
            let object = try requestObject(request)
            if object["previous_response_id"] == nil {
                return try fixture("responses-root", extension: "sse", contentType: "text/event-stream")
            }
            guard object["previous_response_id"] as? String == "resp_lms_fixture_root" else {
                return errorRoute(status: 409, code: "previous_response_mismatch")
            }
            return try fixture("responses-continuation", extension: "sse", contentType: "text/event-stream")
        case ("GET", "/fixture/errors/401"):
            return errorRoute(status: 401, code: "invalid_api_token")
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
