// DocsToolPack.swift
// What: Provides native PDF-generation tools to external MCP clients.
// How: It translates validated tool arguments into PDFWriter operations and returns
// bounded, structured success or error payloads.
// Why: Document capability is an optional module rather than a responsibility of Core routing.

import Foundation
import Darwin

/// Documentation tools: PDF write / PDF from file.
public struct DocsToolPack: ToolPackHandling {
    private static let maximumSourceBytes = 4 * 1024 * 1024

    public init() {}

    public var toolNames: [String] { ["pdf_write", "pdf_from_file"] }

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        try cancellation?.checkCancellation()
        switch name {
        case "pdf_write":
            return try pdfWrite(arguments, cancellation: cancellation)
        case "pdf_from_file":
            return try pdfFromFile(arguments, cancellation: cancellation)
        default:
            return nil
        }
    }

    private func pdfWrite(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let content = ToolArgHelpers.string(args, "content") else {
            return .failure(code: "missing_args", message: "path and content required")
        }
        var url = ToolArgHelpers.resolvePath(path)
        if url.pathExtension.lowercased() != "pdf" {
            url = url.appendingPathExtension("pdf")
        }
        guard content.utf8.count <= Self.maximumSourceBytes else {
            return .failure(
                code: "content_too_large",
                message: "Document content is limited to \(Self.maximumSourceBytes) bytes",
                retryable: false
            )
        }
        let title = ToolArgHelpers.string(args, "title") ?? url.deletingPathExtension().lastPathComponent
        let meta = try PDFWriter.write(
            path: url,
            content: content,
            title: title,
            cancellationCheck: {
                if let cancellation { try cancellation.checkCancellation() }
            }
        )
        return .success(meta)
    }

    private func pdfFromFile(
        _ args: [String: Any],
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let source = ToolArgHelpers.string(args, "source_path") else {
            return .failure(code: "missing_source", message: "source_path required")
        }
        let src = ToolArgHelpers.resolvePath(source)
        let content: String
        do {
            content = try Self.readBoundedUTF8Source(
                at: src,
                cancellation: cancellation
            )
        } catch BoundedSourceReadError.tooLarge {
            return .failure(
                code: "source_too_large",
                message: "Document sources are limited to \(Self.maximumSourceBytes) bytes",
                retryable: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolCallDeadlineExceeded {
            throw error
        } catch {
            return .failure(code: "not_found", message: src.path)
        }
        try cancellation?.checkCancellation()
        let dest: URL
        if let d = ToolArgHelpers.string(args, "dest_path"), !d.isEmpty {
            dest = ToolArgHelpers.resolvePath(d)
        } else {
            dest = src.deletingPathExtension().appendingPathExtension("pdf")
        }
        let title = ToolArgHelpers.string(args, "title") ?? src.deletingPathExtension().lastPathComponent
        var meta = try PDFWriter.write(
            path: dest,
            content: content,
            title: title,
            cancellationCheck: {
                if let cancellation { try cancellation.checkCancellation() }
            }
        )
        meta["source_path"] = src.path
        return .success(meta)
    }

    private enum BoundedSourceReadError: Error {
        case tooLarge
        case unreadable
    }

    private static func readBoundedUTF8Source(
        at url: URL,
        cancellation: ToolCallCancellation?
    ) throws -> String {
        try cancellation?.checkCancellation()
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw BoundedSourceReadError.unreadable }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw BoundedSourceReadError.unreadable
        }
        guard information.st_size >= 0,
              information.st_size <= Self.maximumSourceBytes else {
            throw BoundedSourceReadError.tooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(information.st_size), Self.maximumSourceBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= Self.maximumSourceBytes {
            try cancellation?.checkCancellation()
            let remaining = Self.maximumSourceBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw BoundedSourceReadError.unreadable
        }
        guard data.count <= Self.maximumSourceBytes else {
            throw BoundedSourceReadError.tooLarge
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw BoundedSourceReadError.unreadable
        }
        try cancellation?.checkCancellation()
        return content
    }
}
