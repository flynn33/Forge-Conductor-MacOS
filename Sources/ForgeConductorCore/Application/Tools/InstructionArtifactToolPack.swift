// InstructionArtifactToolPack.swift
// Project/run-bound, read-only access to immutable imported instruction artifacts.

import Foundation

public struct InstructionArtifactToolPack: ToolPackHandling {
    public static let names = ["instruction_catalog", "instruction_read"]
    static let responseEnvelopeReserveBytes = 4 * 1_024
    static let contextContinuationReserveTokens = 2 * 1_024
    static let conservativeUTF8BytesPerToken = 2

    public var toolNames: [String] { Self.names }

    public init() {}

    public func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard Self.names.contains(name) else { return nil }
        guard let context, context.runID != nil else {
            return .failure(
                code: "instruction_scope_required",
                message: "Instruction artifacts require an active project-bound run.",
                retryable: false
            )
        }
        do {
            try cancellation?.checkCancellation()
            guard let digest = arguments["snapshot_sha256"] as? String else {
                throw ProjectInstructionQueueError.invalidRequest("snapshot_sha256 is required")
            }
            let store = try ProjectInstructionQueueStore(paths: app.paths, clock: app.clock)
            switch name {
            case "instruction_catalog":
                let cursor = arguments["cursor"] as? Int ?? 0
                let limit = arguments["limit"] as? Int ?? 64
                let page = try store.catalogPage(
                    contentSHA256: digest,
                    projectID: context.projectID,
                    generation: context.projectGeneration,
                    runID: context.runID,
                    cursor: cursor,
                    limit: limit
                )
                return .success([
                    "snapshot_sha256": page.contentSHA256,
                    "total_documents": page.totalDocuments,
                    "cursor": page.cursor,
                    "next_cursor": page.nextCursor as Any,
                    "documents": page.documents,
                ].compactNSNull())
            case "instruction_read":
                guard let documentID = arguments["document_id"] as? String else {
                    throw ProjectInstructionQueueError.invalidRequest("document_id is required")
                }
                let requestedMaximum = arguments["maximum_bytes"] as? Int ?? 32 * 1_024
                let effectiveMaximum = try Self.effectiveMaximumBytes(
                    requested: requestedMaximum,
                    context: context
                )
                let page = try store.readDocument(
                    contentSHA256: digest,
                    documentID: documentID,
                    projectID: context.projectID,
                    generation: context.projectGeneration,
                    runID: context.runID,
                    byteOffset: arguments["byte_offset"] as? Int ?? 0,
                    maximumBytes: effectiveMaximum
                )
                return .success([
                    "snapshot_sha256": digest,
                    "document_id": page.documentID,
                    "source_path": page.sourcePath,
                    "content": page.content,
                    "byte_offset": page.byteOffset,
                    "next_byte_offset": page.nextByteOffset as Any,
                    "total_bytes": page.totalBytes,
                    "sha256": page.sha256,
                    "requested_maximum_bytes": requestedMaximum,
                    "effective_maximum_bytes": effectiveMaximum,
                    "remaining_context_tokens": context.remainingContextTokens as Any,
                ].compactNSNull())
            default:
                return nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(
                code: "instruction_artifact_error",
                message: error.localizedDescription,
                retryable: false
            )
        }
    }

    static func effectiveMaximumBytes(
        requested: Int,
        context: ToolInvocationContext
    ) throws -> Int {
        guard (1...ProjectInstructionQueueStore.maximumDeliveryBytes).contains(requested) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction delivery byte budget is outside its supported range."
            )
        }
        let inlineBudget = context.authorizationScope.maximumInlineOutputBytes
            - responseEnvelopeReserveBytes
        guard inlineBudget > 0 else {
            throw ProjectInstructionQueueError.invalidRequest(
                "The current inline result budget is too small for instruction delivery."
            )
        }
        var effective = min(
            requested,
            ProjectInstructionQueueStore.maximumDeliveryBytes,
            inlineBudget
        )
        if let remaining = context.remainingContextTokens {
            let usableTokens = remaining - contextContinuationReserveTokens
            guard usableTokens > 0 else {
                throw ProjectInstructionQueueError.invalidRequest(
                    "The current provider context budget cannot safely accept another instruction page. Continue after the managed rollover."
                )
            }
            let contextBytes = usableTokens.multipliedReportingOverflow(
                by: conservativeUTF8BytesPerToken
            )
            effective = min(effective, contextBytes.overflow ? Int.max : contextBytes.partialValue)
        }
        guard effective > 0 else {
            throw ProjectInstructionQueueError.invalidRequest(
                "The current provider context budget cannot safely accept another instruction page."
            )
        }
        return effective
    }
}
