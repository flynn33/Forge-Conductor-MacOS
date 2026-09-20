import Foundation

/// Shared stdio/HTTP framing. Mutation preflight uses these same duplicated
/// text/structured payload fields so escaping is included before commit.
enum MCPToolResponse {
    static func object(id: Any?, result: ToolResult, additiveNotice: String? = nil) -> [String: Any] {
        let text = (try? JSONSupport.string(from: result.payload)) ?? "{\"ok\":false}"
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let additiveNotice, !additiveNotice.isEmpty {
            content.append(["type": "text", "text": additiveNotice])
        }
        var response: [String: Any] = ["jsonrpc": "2.0", "result": [
            "content": content,
            "isError": result.isError || !result.ok,
            "structuredContent": result.payload,
        ] as [String: Any]]
        if let id { response["id"] = id }
        return response
    }

    static func data(id: Any?, result: ToolResult, additiveNotice: String? = nil) throws -> Data {
        try JSONSupport.data(from: object(id: id, result: result, additiveNotice: additiveNotice))
    }
}
