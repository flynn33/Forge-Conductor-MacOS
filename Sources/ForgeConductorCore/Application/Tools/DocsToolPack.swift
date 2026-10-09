// DocsToolPack.swift
// What: Provides native PDF, plain-text DOCX, text-cell XLSX/ODS, text-slide PPTX, and PNG/TIFF/JPEG/GIF/WebP/BMP/ICO and supplied-entry ZIP/PCM16 WAV tools to external MCP clients.
// How: It translates validated tool arguments into PDFWriter operations and returns
// bounded, structured success or error payloads.
// Why: Document capability is an optional module rather than a responsibility of Core routing.

import Foundation
import Darwin
import AppKit
import CryptoKit

/// Documentation tools: PDF write / PDF from file / plain-text DOCX / text-cell XLSX/ODS / text-slide PPTX / PNG/TIFF/JPEG/GIF/WebP/BMP/ICO / supplied-entry ZIP / supplied PCM16 WAV.
public struct DocsToolPack: ToolPackHandling {
    private static let maximumSourceBytes = 4 * 1024 * 1024
    private let exporter: NativeDOCXExporter?

    public init() { exporter = nil }
    init(exporter: NativeDOCXExporter) { self.exporter = exporter }

    public var toolNames: [String] { ["pdf_write", "pdf_from_file", "docx_write", "xlsx_write", "pptx_write", "ods_write", "image_write", "archive_write", "audio_write"] }

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
        case "docx_write":
            return try docxWrite(arguments, context: context, app: app, cancellation: cancellation)
        case "xlsx_write":
            return try xlsxWrite(arguments, context: context, app: app, cancellation: cancellation)
        case "pptx_write":
            return try pptxWrite(arguments, context: context, app: app, cancellation: cancellation)
        case "ods_write":
            return try odsWrite(arguments, context: context, app: app, cancellation: cancellation)
        case "image_write":
            return try imageWrite(arguments, context: context, app: app, cancellation: cancellation)
        case "archive_write":
            return try archiveWrite(arguments, context: context, app: app, cancellation: cancellation)
        case "audio_write":
            return try audioWrite(arguments, context: context, app: app, cancellation: cancellation)
        default:
            return nil
        }
    }

    private func audioWrite(_ args: [String: Any], context: ToolInvocationContext?,
                            app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard Set(args.keys).isSubset(of: ["path", "content", "sample_rate", "channels", "deadline_ms"]) else {
            return .failure(code: "invalid_audio_arguments", message: "Only path, content, sample_rate, channels and the shared deadline_ms field are accepted")
        }
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "WAV path must be a nonblank string without NUL bytes")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard url.pathExtension.lowercased() == "wav" else {
            return .failure(code: "invalid_path", message: "An explicit .wav destination is required")
        }
        guard let content = args["content"] as? String else {
            return .failure(code: "invalid_audio_content", message: "content must be a canonical padded base64 string")
        }
        let encoded: NativePCM16WAVWriter.EncodedAudio
        do {
            let rate = try NativePCM16WAVWriter.sampleRate(args["sample_rate"])
            let channels = try NativePCM16WAVWriter.channels(args["channels"])
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try NativePCM16WAVWriter.encode(content: content, sampleRate: rate,
                channels: channels, cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativePCM16WAVError {
            return .failure(code: error.code, message: error.localizedDescription)
        } catch {
            return .failure(code: "audio_encode_failed", message: "Native encoding or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded.data, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            return .failure(code: "audio_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        return .success([
            "path": url.path, "format": "wav", "engine": "swift-pcm16-riff",
            "bytes_written": encoded.data.count,
            "sha256": SHA256.hash(data: encoded.data).map { String(format: "%02x", $0) }.joined(),
            "pcm_bytes": encoded.pcmBytes, "sample_rate": encoded.sampleRate,
            "channels": encoded.channels, "frames": encoded.frames,
            "input_contract": NativePCM16WAVWriter.inputContract,
            "output_contract": NativePCM16WAVWriter.outputContract,
        ])
    }

    private func archiveWrite(_ args: [String: Any], context: ToolInvocationContext?,
                              app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard Set(args.keys).isSubset(of: ["path", "entries", "deadline_ms"]) else {
            return .failure(code: "invalid_archive_arguments", message: "Only path, entries and the shared deadline_ms field are accepted")
        }
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "ZIP path must be a nonblank string without NUL bytes")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard url.pathExtension.lowercased() == "zip" else {
            return .failure(code: "invalid_path", message: "An explicit .zip destination is required")
        }
        let encoded: NativeStoredZIPWriter.EncodedArchive
        do {
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try NativeStoredZIPWriter.encode(entries: args["entries"], cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativeStoredZIPError {
            return .failure(code: error.code, message: error.localizedDescription)
        } catch {
            return .failure(code: "archive_encode_failed", message: "Native encoding or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded.data, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            return .failure(code: "archive_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        return .success([
            "path": url.path, "format": "zip", "engine": "swift-stored-zip",
            "bytes_written": encoded.data.count,
            "sha256": SHA256.hash(data: encoded.data).map { String(format: "%02x", $0) }.joined(),
            "entry_count": encoded.entryCount, "input_bytes": encoded.inputBytes,
            "output_contract": NativeStoredZIPWriter.outputContract,
        ])
    }

    private func imageWrite(_ args: [String: Any], context: ToolInvocationContext?,
                            app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "Image path must be a nonblank string without NUL bytes")
        }
        let url = ToolArgHelpers.resolvePath(path)
        let isTIFF = (args["format"] as? String) == "tiff"
        let isJPEG = (args["format"] as? String) == "jpeg"
        let isGIF = (args["format"] as? String) == "gif"
        let isWebP = (args["format"] as? String) == "webp"
        let isBMP = (args["format"] as? String) == "bmp"
        let isICO = (args["format"] as? String) == "ico"
        let extensions = isTIFF ? ["tif", "tiff"] : isJPEG ? ["jpg", "jpeg"] : isGIF ? ["gif"] : isWebP ? ["webp"] : isBMP ? ["bmp"] : isICO ? ["ico"] : ["png"]
        guard extensions.contains(url.pathExtension.lowercased()) else {
            return .failure(code: "invalid_path", message: isTIFF
                ? "An explicit .tif or .tiff destination is required for format=tiff"
                : isJPEG ? "An explicit .jpg or .jpeg destination is required for format=jpeg"
                : isGIF ? "An explicit .gif destination is required for format=gif"
                : isWebP ? "An explicit .webp destination is required for format=webp"
                : isBMP ? "An explicit .bmp destination is required for format=bmp"
                : isICO ? "An explicit .ico destination is required for format=ico"
                : "An explicit .png destination is required")
        }
        guard let content = args["content"] as? String else {
            return .failure(code: "invalid_content", message: "content must be a base64 string")
        }
        let pixelFormat: String
        if let value = args["pixel_format"] {
            guard let string = value as? String else {
                return .failure(code: "invalid_pixel_format", message: "pixel_format must be a string")
            }
            pixelFormat = string
        } else { pixelFormat = "rgba8" }
        let format: String
        if let value = args["format"] {
            guard let string = value as? String else {
                return .failure(code: "invalid_image_format", message: "format must be a string")
            }
            format = string
        } else { format = "png" }
        let width: Int
        let height: Int
        let encoded: Data
        do {
            width = try NativeRasterWriter.integerDimension(args["width"])
            height = try NativeRasterWriter.integerDimension(args["height"])
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try NativeRasterWriter.encode(width: width, height: height, content: content,
                pixelFormat: pixelFormat, format: format, cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativeRasterError {
            return .failure(code: error.code, message: error.localizedDescription)
        } catch {
            return .failure(code: "image_encode_failed", message: "Native encoding or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            return .failure(code: "image_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        var result = ToolResult.success([
            "path": url.path, "format": format, "engine": format == "tiff" ? "swift-tiff-rgba8" : isWebP ? "swift-webp-vp8l" : isICO ? "swift-ico-dib32" : "apple-imageio",
            "width": width, "height": height, "pixel_format": "rgba8", "color_space": "srgb",
            "bytes_written": encoded.count,
            "sha256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            "pixel_bytes": width * height * 4, "pixel_contract": NativeRasterWriter.pixelContract,
        ])
        if isJPEG { result.payload["output_contract"] = NativeRasterWriter.jpegOutputContract }
        if isGIF { result.payload["output_contract"] = NativeRasterWriter.gifOutputContract }
        if isWebP { result.payload["output_contract"] = NativeRasterWriter.webpOutputContract }
        if isICO { result.payload["output_contract"] = NativeRasterWriter.icoOutputContract }
        return result
    }

    private func odsWrite(_ args: [String: Any], context: ToolInvocationContext?,
                          app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "ODS path must be a nonblank string without NUL bytes")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard url.pathExtension.lowercased() == "ods" else {
            return .failure(code: "invalid_path", message: "An explicit .ods destination is required")
        }
        let rows: [[String]]
        let encoded: Data
        do {
            rows = try NativeODSWriter.rows(from: args["rows"])
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try NativeODSWriter.encode(rows: rows, cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativeODSError {
            return .failure(code: error.code, message: error.localizedDescription)
        } catch {
            return .failure(code: "ods_encode_failed", message: "Native encoding or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            return .failure(code: "ods_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        return .success([
            "path": url.path, "format": "ods", "engine": "swift-odf-stored-zip",
            "bytes_written": encoded.count,
            "sha256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            "input_text_bytes": rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } },
            "rows": rows.count, "cells": rows.reduce(0) { $0 + $1.count },
            "text_contract": NativeODSWriter.textContract,
        ])
    }

    private func pptxWrite(_ args: [String: Any], context: ToolInvocationContext?,
                           app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "PPTX path must be a nonblank string without NUL bytes")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard url.pathExtension.lowercased() == "pptx" else {
            return .failure(code: "invalid_path", message: "An explicit .pptx destination is required")
        }
        let slides: [NativePPTXWriter.Slide]
        let encoded: Data
        do {
            slides = try NativePPTXWriter.slides(from: args["slides"])
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try NativePPTXWriter.encode(slides: slides, cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativePPTXError {
            return .failure(code: error.code, message: error.localizedDescription)
        } catch {
            return .failure(code: "pptx_encode_failed", message: "Native encoding or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            return .failure(code: "pptx_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        return .success([
            "path": url.path, "format": "pptx", "engine": "swift-ooxml-stored-zip",
            "bytes_written": encoded.count,
            "sha256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            "input_text_bytes": slides.reduce(0) { $0 + $1.title.utf8.count + $1.paragraphs.reduce(0) { $0 + $1.utf8.count } },
            "slides": slides.count,
            "paragraphs": slides.reduce(0) { $0 + $1.paragraphs.count + ($1.title.isEmpty ? 0 : 1) },
            "text_contract": NativePPTXWriter.textContract,
        ])
    }

    private func xlsxWrite(_ args: [String: Any], context: ToolInvocationContext?,
                           app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "XLSX path must be a nonblank string without NUL bytes")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard url.pathExtension.lowercased() == "xlsx" else {
            return .failure(code: "invalid_path", message: "An explicit .xlsx destination is required")
        }
        let rows: [[String]]
        let encoded: Data
        do {
            rows = try NativeXLSXWriter.rows(from: args["rows"])
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try NativeXLSXWriter.encode(rows: rows, cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativeXLSXError {
            return .failure(code: error.code, message: error.localizedDescription)
        } catch {
            return .failure(code: "xlsx_encode_failed", message: "Native encoding or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            return .failure(code: "xlsx_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        return .success([
            "path": url.path, "format": "xlsx", "engine": "swift-ooxml-stored-zip",
            "bytes_written": encoded.count,
            "sha256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            "input_text_bytes": rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } },
            "rows": rows.count, "cells": rows.reduce(0) { $0 + $1.count },
            "text_contract": NativeXLSXWriter.textContract,
        ])
    }

    private func docxWrite(_ args: [String: Any], context: ToolInvocationContext?,
                           app: ForgeApp, cancellation: ToolCallCancellation?) throws -> ToolResult {
        guard let path = args["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.utf8.contains(0) else {
            return .failure(code: "invalid_path", message: "DOCX path must be a nonblank string without NUL bytes")
        }
        guard let content = args["content"] as? String else {
            return .failure(code: "missing_args", message: "content must be a string")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard url.pathExtension.lowercased() == "docx" else {
            return .failure(code: "invalid_path", message: "An explicit .docx destination is required")
        }
        let encoded: Data
        do {
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
            encoded = try (exporter ?? app.docxExporter).encode(content, cancellation: cancellation)
            try cancellation?.checkCancellation()
            if let context { try app.projectContexts.validate(context, cancellation: cancellation) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let error as NativeDOCXError {
            return .failure(code: error.code, message: error.localizedDescription, retryable: error == .busy)
        } catch is OwnedNativeTerminationUnconfirmed {
            return .failure(code: "docx_termination_unconfirmed", message: "Native export termination is unresolved")
        } catch {
            return .failure(code: "docx_export_failed", message: "Native export or project authorization failed")
        }
        try cancellation?.checkCancellation()
        do {
            try FilesystemToolPack.writePinnedText(encoded, to: url, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch {
            // The pinned writer can rename successfully before directory fsync fails.
            return .failure(code: "docx_write_failed", message: "Destination write or durability confirmation failed; inspect the destination before retrying")
        }
        return .success([
            "path": url.path, "format": "docx", "engine": "appkit-office-open-xml",
            "bytes_written": encoded.count,
            "sha256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            "input_text_bytes": content.utf8.count, "text_contract": "docx-paragraphs-v1",
        ])
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

enum NativeDOCXError: Error, Equatable, LocalizedError {
    case workerRequired, contentTooLarge, invalidText, outputTooLarge
    case busy, stopped, transport, unresolved

    var code: String {
        switch self {
        case .workerRequired: "docx_worker_required"
        case .contentTooLarge: "content_too_large"
        case .invalidText: "invalid_text"
        case .outputTooLarge: "docx_output_too_large"
        case .busy: "docx_busy"
        case .stopped: "docx_stopped"
        case .transport: "docx_export_failed"
        case .unresolved: "docx_termination_unconfirmed"
        }
    }

    var errorDescription: String? {
        switch self {
        case .workerRequired: "DOCX export requires a worker thread"
        case .contentTooLarge: "DOCX content is limited to 65536 UTF-8 bytes"
        case .invalidText: "DOCX text contains a character disallowed by XML 1.0"
        case .outputTooLarge: "Encoded DOCX is limited to 1048576 bytes"
        case .busy: "A native DOCX export is active or unresolved"
        case .stopped: "The DOCX exporter has shut down"
        case .transport: "The native DOCX child did not return a complete admitted export"
        case .unresolved: "Native DOCX child termination is unresolved"
        }
    }
}

/// One app-owned, queue-free native operation. An unreaped child keeps this slot.
final class NativeDOCXExporter: @unchecked Sendable {
    typealias Run = @Sendable (Data, UInt64, ToolCallCancellation) throws -> OwnedDuplexResult
    typealias Recover = @Sendable (UInt64) -> Bool
    private struct Active {
        let id: UUID
        let cancellation: ToolCallCancellation
        let end: UInt64
        var inFlight = true
        var recovering = false
    }
    private let condition = NSCondition()
    private var active: Active?
    private var stopped = false
    private let run: Run
    private let recover: Recover

    convenience init() {
        let runner = ProcessRunner(inheritEnvironment: false)
        self.init(run: { data, end, cancellation in
            try runner.runOwnedCurrentSelf(mode: .docxExportV1, standardInput: data,
                deadlineUptimeNanoseconds: end, cancellation: cancellation)
        }, recover: { end in runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: end) })
    }

    init(run: @escaping Run, recover: @escaping Recover) {
        self.run = run
        self.recover = recover
    }

    func encode(_ content: String, cancellation: ToolCallCancellation?) throws -> Data {
        guard !Thread.isMainThread else { throw NativeDOCXError.workerRequired }
        _ = try DOCXExportChildEntry.normalizedText(content)
        let input = Data(content.utf8)
        let control = cancellation ?? ToolCallCancellation(timeoutSeconds: 30)
        try control.checkCancellation()
        let entered = DispatchTime.now().uptimeNanoseconds
        let seconds = min(30, control.remainingTimeInterval ?? 30)
        guard seconds > 2.5 else { throw ToolCallDeadlineExceeded() }
        let end = entered + UInt64(seconds * 1_000_000_000)
        let id = UUID()
        condition.lock()
        guard !stopped, active == nil else {
            let error: NativeDOCXError = stopped ? .stopped : .busy
            condition.unlock()
            throw error
        }
        active = Active(id: id, cancellation: control, end: end)
        condition.unlock()
        var unresolved = false
        defer {
            condition.lock()
            if active?.id == id {
                if unresolved { active?.inFlight = false }
                else { active = nil }
            }
            condition.broadcast()
            condition.unlock()
        }
        let result: OwnedDuplexResult
        do { result = try run(input, end, control) }
        catch let error as OwnedNativeTerminationUnconfirmed {
            unresolved = true
            throw error
        }
        guard result.terminationConfirmed else {
            unresolved = true
            throw NativeDOCXError.unresolved
        }
        try control.checkCancellation()
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw ToolCallDeadlineExceeded() }
        guard result.admission == .admitted,
              result.terminationSignal == nil, !result.termRequested, !result.killRequested,
              result.stdinBytesWritten == input.count, result.stdinClosed,
              result.stdout.end == .eof, result.stderr.end == .eof,
              !result.stdout.truncated, !result.stderr.truncated else {
            throw NativeDOCXError.transport
        }
        if result.exitCode == DOCXExportChildEntry.outputTooLargeExitCode {
            throw NativeDOCXError.outputTooLarge
        }
        guard result.exitCode == 0 else { throw NativeDOCXError.transport }
        guard result.stdout.data.count <= DOCXExportChildEntry.maximumOutputBytes else {
            throw NativeDOCXError.outputTooLarge
        }
        guard result.stdout.data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw NativeDOCXError.transport
        }
        return result.stdout.data
    }

    /// Cancellation/recovery use the original operation deadline, never new grace.
    func shutdown() -> Bool {
        condition.lock()
        stopped = true
        active?.cancellation.cancel()
        while let operation = active, operation.inFlight {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < operation.end else { condition.unlock(); return false }
            _ = condition.wait(until: Date(timeIntervalSinceNow:
                min(0.05, Double(operation.end - now) / 1_000_000_000)))
        }
        guard let operation = active else { condition.unlock(); return true }
        guard !operation.recovering else {
            condition.unlock()
            return false
        }
        active?.recovering = true
        condition.unlock()
        let confirmed = recover(operation.end)
        condition.lock()
        if active?.id == operation.id {
            if confirmed { active = nil }
            else { active?.recovering = false }
        }
        condition.broadcast()
        condition.unlock()
        return confirmed
    }
}

/// Fixed exact-self mode, entered before application/configuration bootstrap.
public enum DOCXExportChildEntry {
    static let maximumInputBytes = 65_536
    static let maximumOutputBytes = 1_048_576
    static let outputTooLargeExitCode: Int32 = 3

    static func normalizedText(_ content: String) throws -> String {
        guard content.utf8.count <= maximumInputBytes else { throw NativeDOCXError.contentTooLarge }
        guard content.unicodeScalars.allSatisfy({ scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13
                || (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }) else { throw NativeDOCXError.invalidText }
        return content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    static func serialize(content: String, maximumOutputBytes: Int = maximumOutputBytes) throws -> Data {
        guard !Thread.isMainThread else { throw NativeDOCXError.workerRequired }
        let text = try normalizedText(content)
        return try autoreleasepool {
            let attributed = NSAttributedString(string: text)
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            guard data.count <= maximumOutputBytes else { throw NativeDOCXError.outputTooLarge }
            return data
        }
    }

    @discardableResult
    public static func runIfRequested(arguments: [String] = CommandLine.arguments,
                                      expectedRole: WebRenderProductRole) -> Bool {
        guard arguments.dropFirst().first == OwnedCurrentSelfMode.docxExportV1.argument else { return false }
        guard arguments.count == 2, Thread.isMainThread else { _exit(2) }
        let end = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { _exit(124) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try OwnedCurrentSelfAdmission.current(expectedRole: expectedRole == .app ? .app : .cli)
                let input = try readInput(end: min(end, DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
                guard let content = String(data: input, encoding: .utf8) else { _exit(2) }
                let output = try serialize(content: content)
                try writeOutput(output, end: end)
                guard Darwin.close(STDOUT_FILENO) == 0, Darwin.close(STDERR_FILENO) == 0 else { _exit(2) }
                _exit(0)
            } catch NativeDOCXError.outputTooLarge { _exit(outputTooLargeExitCode) }
            catch { _exit(2) }
        }
        dispatchMain()
    }

    private static func makeNonblocking(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NativeDOCXError.transport
        }
    }

    private static func readInput(end: UInt64) throws -> Data {
        try makeNonblocking(STDIN_FILENO)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while DispatchTime.now().uptimeNanoseconds < end {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(STDIN_FILENO, $0.baseAddress, min($0.count, maximumInputBytes + 1 - data.count))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumInputBytes else { throw NativeDOCXError.contentTooLarge }
            } else if count == 0 { return data }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 20)
            } else { throw NativeDOCXError.transport }
        }
        throw ToolCallDeadlineExceeded()
    }

    private static func writeOutput(_ data: Data, end: UInt64) throws {
        try makeNonblocking(STDOUT_FILENO)
        guard Darwin.fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { throw NativeDOCXError.transport }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < end else { throw ToolCallDeadlineExceeded() }
                let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), min(8_192, bytes.count - offset))
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&descriptor, 1, 20)
                } else { throw NativeDOCXError.transport }
            }
        }
    }
}
