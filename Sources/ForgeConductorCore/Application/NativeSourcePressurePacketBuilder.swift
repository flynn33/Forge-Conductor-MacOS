import Foundation
import CoreFoundation

/// Deterministic serialization only. The caller supplies stable native snapshot facts;
/// no clock, repository, provider, filesystem, model summarizer or authority is consulted.
enum NativeSourcePressurePacketBuilder {
    static let maximumResponseBytes = 1_048_576
    static let maximumBootstrapOutputBytes = 65_536
    static let maximumOptionalPreviewBytes = 1_024

    typealias ResponsePreflight = @Sendable (PreparedContinuitySourceCommit) throws -> Data

    static func build(_ input: NativeSourcePressurePacketInput,
                      responsePreflight: ResponsePreflight) throws -> PreparedContinuitySourceCommit {
        do { return try buildValidated(input, responsePreflight: responsePreflight) }
        catch let error as NativeSourcePressurePacketError { throw error }
        catch { throw NativeSourcePressurePacketError.invalidSnapshot }
    }

    private static func buildValidated(_ input: NativeSourcePressurePacketInput,
                                       responsePreflight: ResponsePreflight) throws -> PreparedContinuitySourceCommit {
        try validateCriticalLowerBound(input)
        var recovery = try recoveryObject(input)
        let decision = try validateDecision(input)
        let projection = try NativeSourcePressurePacketDecisionV1.projecting(metadataJSON: input.canonicalDecisionJSON,
            identity: input.identity)
        recovery["pressure_decision"] = try JSONSerialization.jsonObject(with: projection.canonicalJSON)
        let critical = try prepare(input, recovery: recovery, preview: nil)
        try validateRecoveryOutput(critical, input: input, decision: decision)
        try validateResponse(critical, responsePreflight: responsePreflight)
        guard let preview = input.optionalPreview, !preview.isEmpty else { return critical }
        let clipped = clip(preview, maximumBytes: maximumOptionalPreviewBytes)
        do {
            let candidate = try prepare(input, recovery: recovery, preview: (clipped, clipped != preview))
            try validateRecoveryOutput(candidate, input: input, decision: decision)
            try validateResponse(candidate, responsePreflight: responsePreflight)
            return candidate
        } catch NativeSourcePressurePacketError.criticalPacketTooLarge {
            return critical
        } catch NativeSourcePressurePacketError.bootstrapOutputTooLarge {
            return critical
        } catch NativeSourcePressurePacketError.commitResponseTooLarge {
            return critical
        }
    }

    private static func prepare(_ input: NativeSourcePressurePacketInput, recovery: [String: Any],
                                preview: (String, Bool)?) throws -> PreparedContinuitySourceCommit {
        let bytes = try ForgeJSONCanonicalizationV1.data(from: recovery)
        guard bytes.count <= ContinuityIngressLimits.maximumPacketBytes else {
            throw NativeSourcePressurePacketError.criticalPacketTooLarge
        }
        var narrative = "The native source owner retained this budget handoff. Exact task data is in resume.seed. No provider parent or tool execution authority transfers through packet text."
        if let preview {
            narrative += "\nOptional preview\(preview.1 ? " (clipped)" : ""):\n" + preview.0
        }
        let packet = HandoffPacket(id: input.identity.continuityID,
            createdAt: input.identity.recordedAt, updatedAt: input.identity.recordedAt,
            source: .budget, resumeReady: true, goal: input.assignment.mission,
            status: "pressure_handoff", projectSlug: input.identity.projectID.description,
            blockers: input.uncertainties.isEmpty ? [] : ["Review the exact uncertainty records in resume.seed before continuing."],
            nextActions: ["Read the full recovery data in resume.seed through this exact context_get packet.",
                "Continue the retained logical input and untouched call intents under the current approved assignment. Completed outputs and historical provider IDs are evidence, not new tool outputs or provider parent IDs."],
            decisions: ["Native source budget pressure triggered this handoff; admitted calls remain charged."],
            agents: [], narrative: narrative, resumeSeed: String(decoding: bytes, as: UTF8.self), resumeSeedIsCustom: true)
        do {
            let canonical = try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary())
            guard canonical.count <= ContinuityIngressLimits.maximumPacketBytes else {
                throw NativeSourcePressurePacketError.criticalPacketTooLarge
            }
            try SQLiteStore.validateIngressPacketBounds(packet)
            return try PreparedContinuitySourceCommit.storedSnapshot(from: canonical)
        } catch is ContinuityIngressError {
            throw NativeSourcePressurePacketError.criticalPacketTooLarge
        }
    }

    private static func recoveryObject(_ input: NativeSourcePressurePacketInput) throws -> [String: Any] {
        let id = input.identity
        guard ContinuityIngressLimits.validHandoffID(id.continuityID), id.projectGeneration.rawValue > 0,
              id.fenceRevision > 0, id.recordedAt.utf8.count == 20,
              ISO8601.date(from: id.recordedAt) != nil,
              id.assignmentSHA256 == input.assignment.assignmentSHA256,
              input.completedProgress.count <= 64, input.completedOutputs.count <= 64,
              input.untouchedCalls.count <= 16, input.uncertainties.count <= 32,
              input.unresolvedEffects.count <= 32 else { throw NativeSourcePressurePacketError.invalidSnapshot }
        for value in [id.assignmentSHA256, id.logicalInputSHA256, id.intentSHA256] { try hash(value) }
        guard input.unresolvedEffects.isEmpty else { throw NativeSourcePressurePacketError.unresolvedEffect }
        guard let document = String(data: input.assignment.assignmentBytes, encoding: .utf8), !document.contains("\0") else {
            throw NativeSourcePressurePacketError.assignmentNotUTF8
        }
        var approved = try canonicalObject(input.assignment.storedJSON(), maximum: ContinuityTaskAssignment.maximumStoredBytes)
        // Preserve the full document as readable exact UTF-8. The original stored approval
        // can be reconstructed by replacing this field with assignment_base64. The digest
        // still identifies that original complete approved assignment, not this projection.
        approved.removeValue(forKey: "assignment_base64")
        approved["assignment_text_utf8"] = document
        approved["document_encoding"] = "utf8"
        let logical: [String: Any]
        switch input.logicalInput {
        case .originalUTF8(let bytes):
            guard !bytes.isEmpty, bytes.count <= NativeSourceSendRequest.maximumInputBytes,
                  JSONSupport.sha256Hex(bytes) == id.logicalInputSHA256,
                  let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
                throw NativeSourcePressurePacketError.logicalInputNotUTF8
            }
            logical = ["kind": "original_logical_input", "version": 1,
                       "sha256": id.logicalInputSHA256, "text_utf8": text]
        case .legacyRetainedRequest(let kind, let bytes):
            guard !bytes.isEmpty, bytes.count <= 524_288,
                  let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
                throw NativeSourcePressurePacketError.logicalInputNotUTF8
            }
            logical = ["kind": "legacy_retained_provider_request", "request_kind": kind.rawValue,
                "original_logical_input_available": false, "original_logical_input_sha256": id.logicalInputSHA256,
                "retained_request_sha256": JSONSupport.sha256Hex(bytes), "retained_request_utf8": text,
                "interpretation": "The complete old request is retained as data. No logical-input substring was inferred."]
        }
        var pending: [String: Any] = ["present": false]
        if let value = input.pendingRequest {
            try hash(value.inputSHA256)
            guard !value.utf8.isEmpty, value.utf8.count <= 524_288,
                  JSONSupport.sha256Hex(value.utf8) == value.inputSHA256,
                  let text = String(data: value.utf8, encoding: .utf8) else {
                throw NativeSourcePressurePacketError.invalidSnapshot
            }
            if let parent = value.historicalParentResponseID { try identifier(parent, maximum: 1_024) }
            guard value.kind != .root || value.historicalParentResponseID == nil else {
                throw NativeSourcePressurePacketError.invalidSnapshot
            }
            pending = ["present": true, "kind": value.kind.rawValue, "input_sha256": value.inputSHA256,
                "input_utf8": text, "dispatch_state": "not_submitted",
                "interpretation": "Retained pending request data only. The successor uses a fresh provider root."]
            if let parent = value.historicalParentResponseID { pending["historical_parent_response_id"] = parent }
        }
        var seenCalls = Set<String>()
        var stageResponses: [UUID: String] = [:]
        func retainResponse(_ stage: UUID, _ response: String) throws {
            if let prior = stageResponses[stage], prior != response { throw NativeSourcePressurePacketError.invalidSnapshot }
            stageResponses[stage] = response
        }
        var lastCompleted: [UUID: Int] = [:]
        let outputs: [[String: Any]] = try input.completedOutputs.map { value in
            try callIdentity(stage: value.stageID, ordinal: value.ordinal, response: value.providerResponseID,
                             call: value.providerCallID, tool: value.toolName, seen: &seenCalls)
            guard value.ordinal == (lastCompleted[value.stageID] ?? -1) + 1 else {
                throw NativeSourcePressurePacketError.invalidSnapshot
            }
            lastCompleted[value.stageID] = value.ordinal
            try retainResponse(value.stageID, value.providerResponseID)
            let args = try checkedObject(value.canonicalArgumentsJSON, sha256: value.argumentsSHA256, maximum: 262_144)
            let result = try checkedObject(value.canonicalToolResultJSON, sha256: value.resultSHA256, maximum: 1_048_576)
            try hash(value.payloadSHA256); try hash(value.sourceReceiptSHA256)
            guard Set(result.keys) == ["ok", "is_error", "payload"],
                  let payload = result["payload"] as? [String: Any],
                  let ok = boolean(result["ok"]), let failed = boolean(result["is_error"]), ok != failed,
                  JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: payload)) == value.payloadSHA256,
                  value.toolName != "session_handoff" else { throw NativeSourcePressurePacketError.invalidSnapshot }
            return ["stage_id": value.stageID.uuidString.lowercased(), "ordinal": value.ordinal,
                "historical_response_id": value.providerResponseID, "historical_call_id": value.providerCallID,
                "tool_name": value.toolName, "arguments": args, "arguments_sha256": value.argumentsSHA256,
                "completed_result": result, "result_sha256": value.resultSHA256, "payload_sha256": value.payloadSHA256,
                "source_reservation_id": value.reservationID.uuidString.lowercased(), "source_receipt_sha256": value.sourceReceiptSHA256,
                "interpretation": "Actual completed source output. Do not execute it again or submit it as a successor function output."]
        }
        var nextOrdinal = (lastCompleted[id.stageID] ?? -1) + 1
        let untouched: [[String: Any]] = try input.untouchedCalls.map { value in
            try callIdentity(stage: value.stageID, ordinal: value.ordinal, response: value.providerResponseID,
                             call: value.providerCallID, tool: value.toolName, seen: &seenCalls)
            guard value.stageID == id.stageID, value.ordinal == nextOrdinal else {
                throw NativeSourcePressurePacketError.invalidSnapshot
            }
            nextOrdinal += 1
            try retainResponse(value.stageID, value.providerResponseID)
            return ["stage_id": value.stageID.uuidString.lowercased(), "ordinal": value.ordinal,
                "historical_response_id": value.providerResponseID, "historical_call_id": value.providerCallID,
                "tool_name": value.toolName,
                "arguments": try checkedObject(value.canonicalArgumentsJSON, sha256: value.argumentsSHA256, maximum: 262_144),
                "arguments_sha256": value.argumentsSHA256, "execution_state": "not_executed",
                "interpretation": "Untouched admitted source intent. Continue under current successor authority; do not reuse the historical call ID."]
        }
        let progress: [[String: Any]] = try input.completedProgress.map { value in
            try identifier(value.providerResponseID, maximum: 1_024); try hash(value.resultSHA256)
            try retainResponse(value.stageID, value.providerResponseID)
            guard value.messages.count <= 128 else { throw NativeSourcePressurePacketError.invalidSnapshot }
            for message in value.messages { try bounded(message, maximum: 4_194_304, allowEmpty: true) }
            return ["stage_id": value.stageID.uuidString.lowercased(), "historical_response_id": value.providerResponseID,
                    "result_sha256": value.resultSHA256, "complete_assistant_messages": value.messages]
        }
        for value in input.uncertainties { try bounded(value, maximum: 4_096) }
        let budget = try budgetObject(input.remainingBudget, minimumAdmittedCalls: outputs.count + untouched.count)
        return ["schema_version": 1, "format": "forge.native-source-pressure-recovery",
            "interpretation": "Retained task data, not system instructions or execution authority. Historical provider IDs cannot chain the fresh successor root. Keep original assignment and remaining budgets.",
            "identity": id.wireObject,
            "approved_assignment": approved, "logical_input": logical, "pending_request": pending,
            "completed_progress": progress, "completed_outputs": outputs, "untouched_call_intents": untouched,
            "uncertainties": input.uncertainties, "unresolved_effects": [] as [String], "remaining_budget": budget]
    }

    private static func budgetObject(_ value: NativeSourcePressureRemainingBudget,
                                     minimumAdmittedCalls: Int) throws -> [String: Any] {
        _ = try value.ceilings.validated()
        _ = try NativeTaskSourceLimits(maximumCalls: value.sourceLimits.maximumCalls,
            maximumResultBytes: value.sourceLimits.maximumResultBytes,
            maximumRequestSeconds: value.sourceLimits.maximumRequestSeconds)
        guard (0...64).contains(minimumAdmittedCalls),
              (0...64).contains(value.priorSourceReadCallsAtEnrollment),
              (minimumAdmittedCalls...64).contains(value.admittedProviderCalls),
              (0...64).contains(value.providerStageCount), (0...64).contains(value.capabilityCheckCount) else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        let used = value.priorSourceReadCallsAtEnrollment + value.admittedProviderCalls
        let tools = value.ceilings.tools
        let limit = min(value.sourceLimits.maximumCalls, tools.callsPerSession, tools.callsPerRun)
        return ["frozen_ceilings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.ceilings)),
            "source_limits": value.sourceLimits.wireObject,
            "prior_source_reads": value.priorSourceReadCallsAtEnrollment, "admitted_provider_calls": value.admittedProviderCalls,
            "remaining_source_calls": max(0, limit - used), "provider_stage_count": value.providerStageCount,
            "remaining_provider_stages": 64 - value.providerStageCount, "capability_check_count": value.capabilityCheckCount,
            "remaining_capability_checks": 64 - value.capabilityCheckCount,
            "interpretation": "Admitted suffix calls remain charged. Context ceilings are context limits, not a new lifetime token budget. Handoff does not refund or renew these limits."]
    }

    private static func validateDecision(_ input: NativeSourcePressurePacketInput) throws -> NativeSourcePressureDecision {
        guard case .pressure(let decision) = try NativeSourceBudgetMetadata.storedSnapshot(from: input.canonicalDecisionJSON) else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        let fields = decision.observation.fields, binding = fields.binding, id = input.identity
        let nextRevision = binding.conversationRevision.addingReportingOverflow(1)
        let admitted = binding.admittedProviderCallsBeforeStage.addingReportingOverflow(binding.admittedCallsInStage)
        guard !nextRevision.overflow, !admitted.overflow, id.fenceRevision == nextRevision.partialValue,
              binding.projectID == id.projectID, binding.projectGeneration == id.projectGeneration,
              binding.taskID == id.taskID, binding.conversationID == id.conversationID, binding.stageID == id.stageID,
              binding.logicalRequestID == id.requestID, binding.assignmentSHA256 == id.assignmentSHA256,
              binding.logicalInputSHA256 == id.logicalInputSHA256, binding.intentSHA256 == id.intentSHA256,
              fields.capabilities.providerID == input.assignment.providerID,
              fields.capabilities.modelKey == input.assignment.modelKey,
              input.remainingBudget.ceilings == fields.effectiveCeilings,
              input.remainingBudget.priorSourceReadCallsAtEnrollment == binding.sourceReadCallsBeforeEnrollment,
              input.remainingBudget.admittedProviderCalls == admitted.partialValue,
              input.remainingBudget.sourceLimits.maximumCalls == binding.sourceMaximumCalls else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        let completed = input.completedOutputs.filter { $0.stageID == id.stageID }
        guard completed.count == binding.completedOutputCount,
              completed.count + input.untouchedCalls.count == binding.admittedCallsInStage else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        let prefix: [[String: Any]] = try completed.map { output in
            let result = try canonicalObject(output.canonicalToolResultJSON, maximum: 1_048_576)
            guard let payload = result["payload"] as? [String: Any] else { throw NativeSourcePressurePacketError.invalidSnapshot }
            return ["type": "function_call_output", "call_id": output.providerCallID,
                "output": String(decoding: try ForgeJSONCanonicalizationV1.data(from: payload), as: UTF8.self)]
        }
        guard try ForgeJSONCanonicalizationV1.sha256Hex(of: prefix) == binding.completedOutputsSHA256 else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        if let observed = binding.observedResult {
            guard input.completedProgress.contains(where: { $0.stageID == observed.stageID
                && $0.providerResponseID == observed.providerResponseID && $0.resultSHA256 == observed.resultSHA256 }),
                completed.allSatisfy({ $0.providerResponseID == observed.providerResponseID }),
                input.untouchedCalls.allSatisfy({ $0.providerResponseID == observed.providerResponseID }) else {
                throw NativeSourcePressurePacketError.invalidSnapshot
            }
        }
        if let pending = binding.pendingCall {
            guard let next = input.untouchedCalls.first, next.ordinal == pending.ordinal,
                  next.providerCallID == pending.providerCallID, next.toolName == pending.toolName,
                  next.argumentsSHA256 == pending.argumentsSHA256 else { throw NativeSourcePressurePacketError.invalidSnapshot }
        }
        return decision
    }

    private static func validateRecoveryOutput(_ prepared: PreparedContinuitySourceCommit,
                                              input: NativeSourcePressurePacketInput,
                                              decision: NativeSourcePressureDecision) throws {
        // This is the existing SourceBootstrapRequest/ContinuityBootstrapReadResult wire
        // shape. Int64.max measures the widest revision; it is never a stored receipt.
        let payload: [String: Any] = ["ok": true, "found": true,
            "packet": try JSONSerialization.jsonObject(with: prepared.canonicalPacketJSON),
            "continuity_id": prepared.continuityID, "revision": Int64.max, "packet_sha256": prepared.packetSHA256]
        let result = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": payload])
        let fields = decision.observation.fields
        let tools = fields.effectiveCeilings.tools, original = fields.originalCeilings?.tools
        let byteLimit = min(maximumBootstrapOutputBytes, input.assignment.authorizationScope.maximumInlineOutputBytes,
            input.remainingBudget.ceilings.tools.maxResultBytes, tools.maxResultBytes, original?.maxResultBytes ?? Int.max)
        let tokenLimit = min(input.remainingBudget.ceilings.tools.maxRetainedResultTokens,
            tools.maxRetainedResultTokens, original?.maxRetainedResultTokens ?? Int.max)
        let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: result.count, policy: ContextBudgetPolicy())
        guard result.count <= byteLimit, tokens <= tokenLimit else {
            throw NativeSourcePressurePacketError.bootstrapOutputTooLarge
        }
        _ = try ContinuityBootstrapReadResult(canonicalToolResultJSON: result)
    }

    private static func validateResponse(_ prepared: PreparedContinuitySourceCommit,
                                         responsePreflight: ResponsePreflight) throws {
        let response: Data
        do { response = try responsePreflight(prepared) }
        catch { throw NativeSourcePressurePacketError.responsePreflightRejected }
        guard response.count <= maximumResponseBytes else { throw NativeSourcePressurePacketError.commitResponseTooLarge }
        do {
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let payload = result["structuredContent"] as? [String: Any],
                  let packet = payload["packet"] as? [String: Any],
                  try ForgeJSONCanonicalizationV1.data(from: packet) == prepared.canonicalPacketJSON,
                  payload["packet_sha256"] as? String == prepared.packetSHA256,
                  payload["continuity_id"] as? String == prepared.continuityID else {
                throw NativeSourcePressurePacketError.invalidResponsePreflight
            }
        } catch { throw NativeSourcePressurePacketError.invalidResponsePreflight }
    }

    private static func validateCriticalLowerBound(_ input: NativeSourcePressurePacketInput) throws {
        // Every counted byte must appear in recovery data, before additional escaping.
        // Reject an impossible packet before decoding a bounded but large source history.
        guard input.completedProgress.count <= 64, input.completedOutputs.count <= 64,
              input.untouchedCalls.count <= 16, input.uncertainties.count <= 32 else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        var count = 0
        func add(_ bytes: Int) throws {
            let next = count.addingReportingOverflow(bytes)
            guard bytes >= 0, !next.overflow, next.partialValue <= ContinuityIngressLimits.maximumPacketBytes else {
                throw NativeSourcePressurePacketError.criticalPacketTooLarge
            }
            count = next.partialValue
        }
        try add(input.assignment.assignmentBytes.count)
        switch input.logicalInput {
        case .originalUTF8(let bytes), .legacyRetainedRequest(_, let bytes): try add(bytes.count)
        }
        try add(input.pendingRequest?.utf8.count ?? 0)
        for progress in input.completedProgress {
            guard progress.messages.count <= 128 else { throw NativeSourcePressurePacketError.invalidSnapshot }
            for message in progress.messages { try add(message.utf8.count) }
        }
        for output in input.completedOutputs {
            try add(output.canonicalArgumentsJSON.count); try add(output.canonicalToolResultJSON.count)
        }
        for call in input.untouchedCalls { try add(call.canonicalArgumentsJSON.count) }
        for uncertainty in input.uncertainties { try add(uncertainty.utf8.count) }
        // Full audit metadata is bounded independently; only its compact projection enters the packet.
        guard (1...NativeSourceBudgetMetadata.maximumStoredBytes).contains(input.canonicalDecisionJSON.count) else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
    }

    private static func checkedObject(_ data: Data, sha256: String, maximum: Int) throws -> [String: Any] {
        try hash(sha256)
        guard JSONSupport.sha256Hex(data) == sha256 else { throw NativeSourcePressurePacketError.invalidSnapshot }
        return try canonicalObject(data, maximum: maximum)
    }

    private static func canonicalObject(_ data: Data, maximum: Int) throws -> [String: Any] {
        do {
            guard !data.isEmpty, data.count <= maximum,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  try ForgeJSONCanonicalizationV1.data(from: value) == data else {
                throw NativeSourcePressurePacketError.invalidSnapshot
            }
            return value
        } catch { throw NativeSourcePressurePacketError.invalidSnapshot }
    }

    private static func callIdentity(stage: UUID, ordinal: Int, response: String, call: String,
                                     tool: String, seen: inout Set<String>) throws {
        guard (0..<16).contains(ordinal), ["fs_read", "session_checkpoint", "session_handoff"].contains(tool) else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        try identifier(response, maximum: 1_024); try identifier(call, maximum: 1_024)
        guard seen.insert(stage.uuidString + ":" + call).inserted else { throw NativeSourcePressurePacketError.invalidSnapshot }
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func hash(_ value: String) throws {
        guard ContinuityIngressLimits.validSHA256(value) else { throw NativeSourcePressurePacketError.invalidSnapshot }
    }
    private static func identifier(_ value: String, maximum: Int) throws {
        try bounded(value, maximum: maximum)
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
    }
    private static func bounded(_ value: String, maximum: Int, allowEmpty: Bool = false) throws {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= maximum else { throw NativeSourcePressurePacketError.invalidSnapshot }
    }
    private static func clip(_ value: String, maximumBytes: Int) -> String {
        var result = String.UnicodeScalarView(), bytes = 0
        for scalar in value.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= maximumBytes else { break }
            result.append(scalar); bytes += size
        }
        return String(result)
    }
}
