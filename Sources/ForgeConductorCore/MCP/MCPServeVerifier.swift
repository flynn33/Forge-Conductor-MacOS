// MCPServeVerifier.swift
// What: Performs a process-level MCP initialize and tools/list acceptance smoke.
// How: It launches a candidate binary with a clean role environment, exchanges bounded
// NDJSON frames, validates negotiated protocol and role identity, then terminates it.
// Why: Deployment must fail closed before registering a binary that a host cannot use.

import Foundation

/// Verifies a Forge binary can speak MCP stdio (initialize + tools/list).
/// Used after Deploy so product path failures are caught before the operator opens LM Studio.
public enum MCPServeVerifier {
    public struct Result: Sendable, Equatable {
        public var ok: Bool
        public var protocolVersion: String?
        public var serverName: String?
        public var toolCount: Int
        public var detail: String
        public var durationMs: Int

        public init(
            ok: Bool,
            protocolVersion: String?,
            serverName: String?,
            toolCount: Int,
            detail: String,
            durationMs: Int
        ) {
            self.ok = ok
            self.protocolVersion = protocolVersion
            self.serverName = serverName
            self.toolCount = toolCount
            self.detail = detail
            self.durationMs = durationMs
        }
    }

    /// Spawn `binary serve`, send LM Studio-style initialize (2025-11-25) + tools/list.
    public static func verify(
        binary: URL,
        home: URL,
        role: String = "primary",
        timeoutSec: TimeInterval = 8
    ) throws -> Result {
        let start = Date()
        let connectorRole = LMStudioConnectorRole(environmentValue: role)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return Result(
                ok: false,
                protocolVersion: nil,
                serverName: nil,
                toolCount: 0,
                detail: "not executable: \(binary.path)",
                durationMs: 0
            )
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve"]
        proc.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "FORGE_CONDUCTOR_HOME": home.path,
            "FORGE_MCP_ROLE": connectorRole.rawValue,
            "TMPDIR": NSTemporaryDirectory(),
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()

        // LM Studio client shape (NDJSON).
        let initMsg =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"forge-deploy-verify","version":"1.0.0"}}}"#
            + "\n"
        let inited = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
        let tools = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"# + "\n"
        stdin.fileHandleForWriting.write(Data(initMsg.utf8))
        stdin.fileHandleForWriting.write(Data(inited.utf8))
        stdin.fileHandleForWriting.write(Data(tools.utf8))
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeoutSec)
        var outData = Data()
        var frames: [[String: Any]] = []
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if !chunk.isEmpty {
                outData.append(chunk)
                frames = decodeFrames(outData)
            }
            if proc.isRunning == false { break }
            // Do not terminate on the initialize capability's "tools" key;
            // wait for the complete tools/list response (id 2).
            if frames.contains(where: { numericID($0["id"]) == 2 }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
        }
        proc.waitUntilExit()
        let errTail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        // Accept only standards-compliant newline-delimited MCP output. This
        // deliberately prevents Forge's verifier from self-certifying LSP-style
        // Content-Length responses that LM Studio rejects.
        if frames.isEmpty { frames = decodeFrames(outData) }
        var protocolVersion: String?
        var serverName: String?
        var toolCount = 0
        if let initialize = frames.first(where: { numericID($0["id"]) == 1 }),
           let result = initialize["result"] as? [String: Any] {
            protocolVersion = result["protocolVersion"] as? String
            serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
        }
        if let list = frames.first(where: { numericID($0["id"]) == 2 }),
           let result = list["result"] as? [String: Any],
           let tools = result["tools"] as? [[String: Any]] {
            toolCount = tools.count
        }

        let identityOK = serverName == connectorRole.serverID
        let ok = protocolVersion != nil && toolCount >= 10 && identityOK
        var detail: String
        if ok {
            detail = "initialize ok protocol=\(protocolVersion ?? "?") tools=\(toolCount) in \(ms)ms"
        } else {
            detail = "handshake incomplete role=\(connectorRole.rawValue) server=\(serverName ?? "nil") tools=\(toolCount) protocol=\(protocolVersion ?? "nil") stderr=\(errTail.prefix(200))"
        }

        return Result(
            ok: ok,
            protocolVersion: protocolVersion,
            serverName: serverName,
            toolCount: toolCount,
            detail: detail,
            durationMs: ms
        )
    }

    private static func numericID(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func decodeFrames(_ data: Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if !line.isEmpty, let object = try? JSONSupport.object(from: line) {
                messages.append(object)
            }
        }
        return messages
    }
}

/// Foundation `Process` adapter behind the deployment verifier port.
public struct NativeMCPServeVerifier: MCPServeVerifying {
    public init() {}

    public func verify(
        binary: URL,
        home: URL,
        role: LMStudioConnectorRole,
        timeoutSec: TimeInterval
    ) throws -> MCPServeVerifier.Result {
        try MCPServeVerifier.verify(
            binary: binary,
            home: home,
            role: role.rawValue,
            timeoutSec: timeoutSec
        )
    }
}
