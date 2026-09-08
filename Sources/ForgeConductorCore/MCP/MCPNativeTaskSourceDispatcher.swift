import Foundation

/// Fixed native task source profile. Source work reaches the approved filesystem
/// pack directly through task-specific durable admission; it never enters the
/// shared-client router, legacy counters or a fabricated provider run/session.
final class MCPNativeTaskSourceDispatcher: MCPNativeSourceDispatching {
    private let app: ForgeApp
    private let attachment: AuthenticatedContinuityTaskAttachment
    private let managerInstanceID: UUID
    private let carrier: ContinuityNativeTaskSession
    let sessionBindingSHA256: String
    let expiresAt: Date

    init(app: ForgeApp, attachment: AuthenticatedContinuityTaskAttachment, managerInstanceID: UUID) throws {
        let descriptor = attachment.descriptor
        guard descriptor.profileID == "forge.native-task-source", descriptor.profileVersion == 1,
              descriptor.state == .active,
              let expiry = ISO8601DateFormatter().date(from: descriptor.expiresAt),
              attachment.setup.record.assignment.authorizationScope.allowedTools == ["fs_read"],
              attachment.setup.record.assignment.authorizationScope.writableRoots.isEmpty,
              !attachment.setup.record.assignment.authorizationScope.networkAllowed else {
            throw NativeTaskCapabilityError.unsupportedProfile
        }
        self.app = app; self.attachment = attachment; self.managerInstanceID = managerInstanceID
        carrier = .authenticated(app: app, attachment: attachment)
        expiresAt = expiry
        sessionBindingSHA256 = try ForgeJSONCanonicalizationV1.sha256Hex(of: [
            "capability_id": descriptor.capabilityID.uuidString.lowercased(), "epoch": descriptor.epoch,
            "task_id": descriptor.taskID.uuidString.lowercased(), "approval_sha256": descriptor.approvalSHA256,
            "project_id": descriptor.projectID.description, "generation": descriptor.projectGeneration.rawValue,
        ])
    }

    func toolDescriptorsJSON() throws -> Data {
        let descriptors = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames).mcpDescriptors()
            .filter { ($0["name"] as? String).map(MCPNativeTaskSourceProfile.toolNames.contains) == true }
        guard descriptors.count == MCPNativeTaskSourceProfile.toolNames.count else {
            throw NativeTaskCapabilityError.unsupportedProfile
        }
        return try ForgeJSONCanonicalizationV1.data(from: descriptors)
    }

    func call(name: String, argumentsJSON: Data, identity: MCPTaskRequestIdentity,
              cancellation: ToolCallCancellation) async throws -> ToolResult {
        do {
            try Task.checkCancellation(); try cancellation.checkCancellation()
            guard MCPNativeTaskSourceProfile.toolNames.contains(name),
                  let arguments = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any],
                  try ForgeJSONCanonicalizationV1.data(from: arguments) == argumentsJSON else {
                throw NativeTaskCapabilityError.invalidRequest("tool")
            }
            let result: ToolResult
            switch name {
            case "fs_read":
                result = try await read(argumentsJSON: argumentsJSON, identity: identity, cancellation: cancellation)
            case "session_checkpoint", "session_handoff":
                result = try await commit(argumentsJSON: argumentsJSON, identity: identity,
                    finalize: name == "session_handoff", cancellation: cancellation)
            default:
                result = try await carrier.call(name: name, arguments: arguments, connected: true, cancellation: cancellation)
            }
            cancellation.promoteCommittedResultIfPresent(result)
            return result
        } catch NativeSourceConversationError.ownerManaged {
            return .failure(code: "source_owner_managed", message: "This task's source work is owned by its native conversation.")
        } catch let error as NativeTaskCapabilityError {
            return .failure(code: Self.code(error), message: error.localizedDescription)
        } catch is CancellationError { throw CancellationError() }
          catch let error as ToolCallDeadlineExceeded { throw error }
          catch { return try ContinuityControlToolResponse.failure(.mapping(error)).toolResult() }

    }

    func nativeProviderTools(credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation) async throws -> [Data] {
        let current = try await app.projectContexts.repository.validateNativeSourceConversationLease(
            lease: lease, credential: credential, cancellation: cancellation)
        try requireMatchingAttachment(current)
        return try MCPNativeTaskSourceProfile.providerToolDefinitions(
            catalog: .production(toolNames: app.tools.toolNames))
    }

    func resolveNativeProviderCall(reference: NativeSourceProviderCallReference,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation) async throws -> ResolvedNativeSourceProviderCall {
        let resolved = try await app.projectContexts.repository.resolveNativeSourceProviderCall(
            reference: reference, credential: credential, lease: lease, cancellation: cancellation)
        try requireMatchingAttachment(resolved.attachment)
        guard MCPNativeTaskSourceProfile.sourceToolNames.contains(resolved.toolName),
              !resolved.callID.isEmpty, resolved.callID.utf8.count <= 512,
              !resolved.callID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              try ForgeJSONCanonicalizationV1.data(from: JSONSupport.object(from: resolved.canonicalArgumentsJSON))
                == resolved.canonicalArgumentsJSON else { throw NativeSourceConversationError.integrityFailure }
        return resolved
    }

    func submitNativeCall(resolved: ResolvedNativeSourceProviderCall,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget,
        cancellation: ToolCallCancellation) async throws -> NativeSourceProviderCallOutput {
        try Task.checkCancellation(); try cancellation.checkCancellation()
        // Resolve again after winning the execution slot. Every effect below
        // independently validates the same opaque reference inside its CP writer.
        let current = try await resolveNativeProviderCall(reference: resolved.reference,
            credential: credential, lease: lease, cancellation: cancellation)
        guard current.providerOperationID == resolved.providerOperationID,
              current.responseID == resolved.responseID, current.callID == resolved.callID,
              current.toolName == resolved.toolName, current.canonicalArgumentsJSON == resolved.canonicalArgumentsJSON,
              current.key == resolved.key else { throw NativeSourceConversationError.integrityFailure }
        let repository = app.projectContexts.repository
        if let completed = try await repository.nativeSourceProviderCallOutput(reference: current.reference,
            credential: credential, lease: lease, policySelection: selection(), cancellation: cancellation) {
            return completed
        }
        switch current.toolName {
        case "fs_read":
            try await readNative(current, credential: credential, lease: lease,
                outputBudget: outputBudget, cancellation: cancellation)
        case "session_checkpoint", "session_handoff":
            try await commitNative(current, credential: credential, lease: lease,
                outputBudget: outputBudget, cancellation: cancellation)
        default: throw NativeSourceConversationError.integrityFailure
        }
        guard let completed = try await repository.nativeSourceProviderCallOutput(reference: current.reference,
            credential: credential, lease: lease, policySelection: selection(), cancellation: cancellation) else {
            throw NativeSourceConversationError.integrityFailure
        }
        return completed
    }

    private func requireMatchingAttachment(_ current: AuthenticatedContinuityTaskAttachment) throws {
        guard current.descriptor == attachment.descriptor else { throw NativeTaskCapabilityError.credentialRejected }
    }

    private func readNative(_ resolved: ResolvedNativeSourceProviderCall,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget, cancellation: ToolCallCancellation) async throws {
        let repository = app.projectContexts.repository
        let policy = try selection()
        let ceiling = min(65_536, attachment.sourceLimits.maximumResultBytes,
            attachment.setup.record.assignment.authorizationScope.maximumInlineOutputBytes,
            policy.policy.tools.maxResultBytes, resolved.prepared.frozenCeilings?.tools.maxResultBytes ?? Int.max)
        let escaped = ceiling.multipliedReportingOverflow(by: CanonicalToolResultOutputBounds.maximumStringExpansion)
        guard ceiling > 0, !escaped.overflow,
              ceiling <= outputBudget.maximumCanonicalToolResultBytes,
              escaped.partialValue <= outputBudget.maximumEscapedPayloadBytes else {
            throw NativeSourceConversationError.budgetExceeded
        }
        let request = try NativeSourceReadRequest(key: resolved.key, toolName: "fs_read",
            canonicalArgumentsJSON: resolved.canonicalArgumentsJSON, managerInstanceID: lease.managerInstanceID)
        try cancellation.tightenDeadline(milliseconds: request.effectiveDeadlineMilliseconds(limits: attachment.sourceLimits))
        let decision = try await repository.admitContinuitySourceRead(request: request,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: policy, reference: resolved.reference, credential: credential, lease: lease,
            outputBudget: outputBudget, cancellation: cancellation)
        switch decision {
        case .completed: return
        case .inProgress: throw NativeSourceConversationError.conflict
        case .execute(let admission):
            do {
                guard let deadline = ISO8601.date(from: admission.deadline) else {
                    throw NativeSourceConversationError.integrityFailure
                }
                try cancellation.tightenDeadline(milliseconds: Int(max(0, deadline.timeIntervalSince(app.clock.now()) * 1_000)))
                let context = ToolInvocationContext(projectID: attachment.context.projectID,
                    projectGeneration: attachment.context.projectGeneration, clientID: attachment.context.clientID,
                    authorizationScope: attachment.setup.record.assignment.authorizationScope)
                let authorized = try ToolAuthorizationService(paths: app.paths, config: app.config).authorize(
                    tool: "fs_read", arguments: JSONSupport.object(from: resolved.canonicalArgumentsJSON),
                    context: context, clientID: context.clientID, binding: nil, cancellation: cancellation)
                try await repository.beginContinuitySourceRead(admission: admission, policySelection: selection(),
                    reference: resolved.reference, credential: credential, lease: lease,
                    outputBudget: outputBudget, cancellation: cancellation)
                let result: ToolResult
                switch authorized {
                case .denied(let code, let message): result = .failure(code: code, message: message)
                case .allowed(let normalized):
                    guard let executed = try FilesystemToolPack().handle(name: "fs_read", arguments: normalized,
                        context: context, clientID: context.clientID, app: app, cancellation: cancellation) else {
                        throw NativeSourceConversationError.integrityFailure
                    }
                    result = executed
                }
                _ = try await repository.completeContinuitySourceRead(admission: admission,
                    canonicalToolResultJSON: Self.canonicalToolResult(result), policySelection: selection(),
                    reference: resolved.reference, credential: credential, lease: lease,
                    outputBudget: outputBudget, cancellation: cancellation)
            } catch {
                try? await repository.finishContinuitySourceReadWithoutDisclosure(admission: admission,
                    outcome: error is CancellationError ? .cancelled : .withheld,
                    cancellation: ToolCallCancellation(timeoutSeconds: 3))
                throw error
            }
        }
    }

    private func commitNative(_ resolved: ResolvedNativeSourceProviderCall,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget, cancellation: ToolCallCancellation) async throws {
        let repository = app.projectContexts.repository
        let source = app.continuity
        let clientID = attachment.context.clientID
        let finalize = resolved.toolName == "session_handoff"
        let argumentsJSON = resolved.canonicalArgumentsJSON
        let request = try NativeSourceCommitRequest(key: resolved.key, canonicalArgumentsJSON: argumentsJSON,
            managerInstanceID: lease.managerInstanceID, finalize: finalize)
        let encodeResult: @Sendable (ContinuityHandoffCommit) throws -> Data = { committed in
            try Self.canonicalToolResult(.success(source.authorizedCommitPayload(committed, finalize: finalize)))
        }
        let decision = try await repository.prepareContinuitySourceCommit(request: request,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: selection(), prepare: { authorization in
                try source.prepareAuthorizedSourceCommit(arguments: JSONSupport.object(from: argumentsJSON),
                    clientID: clientID, source: .model, finalize: finalize,
                    authorization: authorization, cancellation: cancellation)
            }, reference: resolved.reference, credential: credential, lease: lease, outputBudget: outputBudget,
            validatePreparedOutput: { prepared in
                // A ready handoff ends the source turn. Its actual receipt is
                // retained without claiming a further provider output was sent.
                guard !prepared.finalize else { return }
                let result = try source.nativeSourcePreparedToolResult(prepared)
                let full = try Self.canonicalToolResult(result)
                let payload = try ForgeJSONCanonicalizationV1.data(from: result.payload)
                let escaped = try JSONEncoder().encode(String(decoding: payload, as: UTF8.self)).count - 2
                let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: full.count, policy: ContextBudgetPolicy())
                guard full.count <= outputBudget.maximumCanonicalToolResultBytes,
                      escaped <= outputBudget.maximumEscapedPayloadBytes,
                      tokens <= outputBudget.maximumResultTokens else { throw NativeSourceConversationError.budgetExceeded }
            }, encodeResult: encodeResult, cancellation: cancellation)
        switch decision {
        case .completed: return
        case .commit(let admission):
            _ = try await repository.commitContinuitySourceRequest(admission: admission, commit: { prepared, authorization, automatic in
                try source.commitPreparedAuthorizedSourceCommit(prepared, authorization: authorization,
                    automaticHandoffEnabled: automatic, cancellation: cancellation)
            }, policySelection: selection(), reference: resolved.reference, credential: credential, lease: lease,
                outputBudget: outputBudget, encodeResult: encodeResult, cancellation: cancellation)
        }
    }

    private static func canonicalToolResult(_ result: ToolResult) throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: ["ok": result.ok, "is_error": result.isError, "payload": result.payload])
    }

    /// Static host metadata survives protocol reconnects. It selects a request
    /// namespace only; every CP transaction still validates the live capability.
    private func durableSourceKey(_ identity: MCPTaskRequestIdentity) throws -> NativeSourceRequestKey {
        guard let namespace = identity.durableSourceSessionID else {
            throw NativeTaskCapabilityError.invalidRequest("source_session_id")
        }
        let domain = "forge.continuity.source-session.v1\0" + attachment.descriptor.capabilityID.uuidString.lowercased()
            + "\0" + namespace.uuidString.lowercased()
        let hash = String(JSONSupport.sha256Hex(Data(domain.utf8)).prefix(32))
        let text = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.dropFirst(20))"
        guard let durableID = UUID(uuidString: text) else { throw NativeTaskCapabilityError.integrityFailure }
        return try NativeSourceRequestKey(sessionID: durableID, requestIDSHA256: identity.requestIDSHA256)
    }

    private func selection() throws -> BudgetPolicySelection {
        guard let generation = Int(exactly: attachment.descriptor.projectGeneration.rawValue) else {
            throw NativeTaskCapabilityError.integrityFailure
        }
        return try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: attachment.descriptor.projectID.description, projectGeneration: generation))
    }

    private func read(argumentsJSON: Data, identity: MCPTaskRequestIdentity,
                      cancellation: ToolCallCancellation) async throws -> ToolResult {
        let repository = app.projectContexts.repository
        let request = try NativeSourceReadRequest(key: durableSourceKey(identity), toolName: "fs_read",
            canonicalArgumentsJSON: argumentsJSON, managerInstanceID: managerInstanceID)
        try cancellation.tightenDeadline(milliseconds: request.effectiveDeadlineMilliseconds(limits: attachment.sourceLimits))
        let decision = try await repository.admitContinuitySourceRead(request: request,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: selection(), cancellation: cancellation)
        switch decision {
        case .completed(let receipt): return try Self.toolResult(receipt.canonicalToolResultJSON)
        case .inProgress:
            return .failure(code: "source_request_in_progress", message: "This source request is already admitted.", retryable: true)
        case .execute(let admission):
            do {
                let arguments = try JSONSupport.object(from: argumentsJSON)
                guard let deadline = ISO8601.date(from: admission.deadline) else { throw NativeTaskCapabilityError.integrityFailure }
                try cancellation.tightenDeadline(milliseconds: Int(max(0, deadline.timeIntervalSinceNow * 1_000)))
                let scope = attachment.setup.record.assignment.authorizationScope
                let context = ToolInvocationContext(projectID: attachment.context.projectID,
                    projectGeneration: attachment.context.projectGeneration, clientID: attachment.context.clientID,
                    authorizationScope: scope)
                let authorizer = ToolAuthorizationService(paths: app.paths, config: app.config)
                let authorized = try authorizer.authorize(tool: "fs_read", arguments: arguments,
                    context: context, clientID: context.clientID, binding: nil, cancellation: cancellation)
                let result: ToolResult
                switch authorized {
                case .denied(let code, let message):
                    try await repository.finishContinuitySourceReadWithoutDisclosure(admission: admission,
                        outcome: .failed, cancellation: cancellation)
                    return .failure(code: code, message: message)
                case .allowed(let normalized):
                    // The admission is already charged. Revalidate immediately
                    // before the bounded pack read, without holding a CP writer.
                    try await repository.beginContinuitySourceRead(admission: admission,
                        policySelection: selection(), cancellation: cancellation)
                    guard let executed = try FilesystemToolPack().handle(name: "fs_read", arguments: normalized,
                        context: context, clientID: context.clientID, app: app, cancellation: cancellation) else {
                        throw NativeTaskCapabilityError.integrityFailure
                    }
                    result = executed
                }
                let bytes = try ForgeJSONCanonicalizationV1.data(from: ["ok": result.ok,
                    "is_error": result.isError, "payload": result.payload])
                let receipt = try await repository.completeContinuitySourceRead(admission: admission,
                    canonicalToolResultJSON: bytes, policySelection: selection(), cancellation: cancellation)
                return try Self.toolResult(receipt.canonicalToolResultJSON)
            } catch {
                // An uncertain dispatched read stays charged. A separate bounded
                // cleanup token records no-disclosure even if the request expired.
                try? await repository.finishContinuitySourceReadWithoutDisclosure(admission: admission,
                    outcome: error is CancellationError ? .cancelled : .withheld,
                    cancellation: ToolCallCancellation(timeoutSeconds: 3))
                throw error
            }
        }
    }

    private func commit(argumentsJSON: Data, identity: MCPTaskRequestIdentity, finalize: Bool,
                        cancellation: ToolCallCancellation) async throws -> ToolResult {
        let repository = app.projectContexts.repository
        let source = app.continuity
        let clientID = attachment.context.clientID
        let request = try NativeSourceCommitRequest(key: durableSourceKey(identity), canonicalArgumentsJSON: argumentsJSON,
            managerInstanceID: managerInstanceID, finalize: finalize)
        let decision = try await repository.prepareContinuitySourceCommit(request: request,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: selection(), prepare: { authorization in
                try source.prepareAuthorizedSourceCommit(arguments: JSONSupport.object(from: argumentsJSON),
                    clientID: clientID, source: .model, finalize: finalize,
                    authorization: authorization, cancellation: cancellation)
            }, cancellation: cancellation)
        let committed: ContinuityHandoffCommit
        switch decision {
        case .completed(let result): committed = result
        case .commit(let admission):
            committed = try await repository.commitContinuitySourceRequest(admission: admission, commit: { prepared, authorization, automatic in
                try source.commitPreparedAuthorizedSourceCommit(prepared, authorization: authorization,
                    automaticHandoffEnabled: automatic, cancellation: cancellation)
            }, cancellation: cancellation)
        }
        return .success(try source.authorizedCommitPayload(committed, finalize: finalize))
    }

    private static func toolResult(_ data: Data) throws -> ToolResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool, let isError = object["is_error"] as? Bool,
              let payload = object["payload"] as? [String: Any] else { throw NativeTaskCapabilityError.integrityFailure }
        return .init(ok: ok, payload: payload, isError: isError)
    }

    private static func code(_ error: NativeTaskCapabilityError) -> String {
        switch error {
        case .invalidRequest: "invalid_request"
        case .unsupportedProfile: "unsupported_source_profile"
        case .credentialRejected, .capabilityRevoked, .epochConflict: "task_capability_rejected"
        case .requestConflict: "source_request_conflict"
        case .capacityExceeded: "source_capacity_exceeded"
        case .integrityFailure: "integrity_failure"
        case .operationBusy: "source_request_in_progress"
        case .resultExpired: "source_result_expired"
        case .sourceFenced: "source_fenced"
        case .budgetExceeded: "budget_exceeded"
        }
    }
}

extension MCPTaskHTTPService {
    convenience init(app: ForgeApp) {
        let managerInstanceID = UUID()
        self.init(clock: app.clock) { credential, cancellation in
            let attachment = try await app.projectContexts.repository.authenticateNativeTaskCapability(
                credential: credential, cancellation: cancellation)
            return try MCPNativeTaskSourceDispatcher(app: app, attachment: attachment, managerInstanceID: managerInstanceID)
        }
    }
}
