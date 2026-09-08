import Foundation

/// Shared stdio/HTTP framing. Mutation preflight uses these same duplicated
/// text/structured payload fields so escaping is included before commit.
enum MCPToolResponse {
    static func object(id: Any?, result: ToolResult) -> [String: Any] {
        let text = (try? JSONSupport.string(from: result.payload)) ?? "{\"ok\":false}"
        var response: [String: Any] = ["jsonrpc": "2.0", "result": [
            "content": [["type": "text", "text": text]],
            "isError": result.isError || !result.ok,
            "structuredContent": result.payload,
        ] as [String: Any]]
        if let id { response["id"] = id }
        return response
    }

    static func data(id: Any?, result: ToolResult) throws -> Data {
        try JSONSupport.data(from: object(id: id, result: result))
    }
}
