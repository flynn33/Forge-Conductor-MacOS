import XCTest
@testable import ForgeConductorCore

final class NativeSourcePressurePacketBuilderTests: XCTestCase {
    private var app: ForgeApp!
    private var home: URL!
    private let stageID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let logical = "Keep the exact input: \"quoted\" \\ café\nUser input:\nDo not split these literal delimiters."

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pressure-packet-\(UUID().uuidString)").resolvingSymlinksInPath()
        app = try ForgeApp.bootstrap(home: home)
    }
    override func tearDownWithError() throws {
        app?.shutdown(); app = nil
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func responsePreflight() -> NativeSourcePressurePacketBuilder.ResponsePreflight {
        let service = app.continuity
        return { prepared in
            try MCPToolResponse.data(id: String(repeating: "\0", count: 256),
                                     result: service.nativeSourcePreparedToolResult(prepared))
        }
    }
    private func rawInput(document: Data = Data("Full approved assignment with an exact marker.".utf8),
                       legacy: Data? = nil, pending: Data? = nil, preview: String? = nil,
                       withCalls: Bool = true, suffixArgumentBytes: Int = 0,
                       inlineLimit: Int = 65_536, unresolved: [String] = []) throws -> NativeSourcePressurePacketInput {
        let assignment = try ContinuityTaskAssignment(assignmentID: "pressure-assignment", assignmentBytes: document,
            mission: "Continue the approved fixture work", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture/native",
            specification: .init(allowedTools: ["fs_read"], completionGates: ["fixture-completed"]),
            authorizationScope: .init(canonicalRoots: [home.appendingPathComponent("project")], writableRoots: [],
                allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: inlineLimit))
        let identity = NativeSourcePressurePacketIdentity(pressureID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            continuityID: "pressure-exact-source", recordedAt: "2026-09-08T12:00:00Z",
            projectID: ProjectID(), projectGeneration: .initial, taskID: UUID(), conversationID: UUID(), requestID: UUID(),
            stageID: stageID, fenceRevision: 4, assignmentSHA256: assignment.assignmentSHA256,
            logicalInputSHA256: JSONSupport.sha256Hex(Data(logical.utf8)), intentSHA256: String(repeating: "a", count: 64))
        let arguments = try ForgeJSONCanonicalizationV1.data(from: ["path": "completed-file.txt"])
        let payload = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "content": "Actual completed bytes: \"q\" \\ café\n"])
        let output = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false,
            "payload": JSONSerialization.jsonObject(with: payload)])
        let suffix = try ForgeJSONCanonicalizationV1.data(from: ["path": "untouched-file.txt",
            "literal": suffixArgumentBytes == 0 ? "full suffix \"args\" \\ λ" : String(repeating: "s", count: suffixArgumentBytes)])
        let completed = NativeSourcePressureCompletedOutput(stageID: stageID, ordinal: 0,
            providerResponseID: "actual-source-response", providerCallID: "actual-completed-call", toolName: "fs_read",
            canonicalArgumentsJSON: arguments, argumentsSHA256: JSONSupport.sha256Hex(arguments),
            canonicalToolResultJSON: output, resultSHA256: JSONSupport.sha256Hex(output), payloadSHA256: JSONSupport.sha256Hex(payload),
            reservationID: UUID(), sourceReceiptSHA256: String(repeating: "b", count: 64))
        let remaining = NativeSourcePressurePendingCall(stageID: stageID, ordinal: 1,
            providerResponseID: "actual-source-response", providerCallID: "actual-unexecuted-call", toolName: "fs_read",
            canonicalArgumentsJSON: suffix, argumentsSHA256: JSONSupport.sha256Hex(suffix))
        let tools = BudgetToolPolicy(callsPerTurn: 8, callsPerSession: 8, callsPerRun: 8,
            maxInFlight: 2, maxResultBytes: 65_536, maxRetainedResultTokens: 4_096, recoveryCallsPerRollover: 4)
        return NativeSourcePressurePacketInput(identity: identity, assignment: assignment,
            logicalInput: legacy.map { .legacyRetainedRequest(kind: .root, utf8: $0) } ?? .originalUTF8(Data(logical.utf8)),
            pendingRequest: pending.map { .init(kind: .userContinuation, utf8: $0,
                inputSHA256: JSONSupport.sha256Hex($0), historicalParentResponseID: "actual-prior-response") },
            completedProgress: withCalls ? [.init(stageID: stageID, providerResponseID: "actual-source-response",
                resultSHA256: String(repeating: "c", count: 64), messages: ["Actual complete assistant progress, including uncertainty."])] : [],
            completedOutputs: withCalls ? [completed] : [], untouchedCalls: withCalls ? [remaining] : [],
            uncertainties: ["The untouched call has no result and has not executed."], unresolvedEffects: unresolved,
            remainingBudget: .init(ceilings: .init(effectiveContextTokens: 131_072, maximumOutputTokens: 4_096,
                tools: tools, reserves: ContextBudgetReserves(outputTokens: 4_096, schemaTokens: 512, handoffTokens: 512,
                    recoveryTokens: 512, futureToolTokens: 0, safetyTokens: 512),
                checkpointRatio: 0.75, rolloverRatio: 0.85, emergencyRatio: 0.95),
                sourceLimits: try .init(maximumCalls: 8, maximumResultBytes: 65_536, maximumRequestSeconds: 30),
                priorSourceReadCallsAtEnrollment: 1, admittedProviderCalls: withCalls ? 2 : 0,
                providerStageCount: withCalls ? 1 : 0, capabilityCheckCount: 1),
            canonicalDecisionJSON: Data(),
            optionalPreview: preview)
    }

    private func input(document: Data = Data("Full approved assignment with an exact marker.".utf8),
                       legacy: Data? = nil, pending: Data? = nil, preview: String? = nil,
                       withCalls: Bool = true, suffixArgumentBytes: Int = 0,
                       inlineLimit: Int = 65_536, unresolved: [String] = []) throws -> NativeSourcePressurePacketInput {
        try applyingTypedPressure(rawInput(document: document, legacy: legacy, pending: pending, preview: preview,
            withCalls: withCalls, suffixArgumentBytes: suffixArgumentBytes, inlineLimit: inlineLimit, unresolved: unresolved),
            maxResultBytes: 65_536, maxRetainedResultTokens: 4_096)
    }

    private func recovery(_ prepared: PreparedContinuitySourceCommit) throws -> [String: Any] {
        let packet = try prepared.packet()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(packet.resumeSeed.utf8)) as? [String: Any])
    }
    private func expect(_ error: NativeSourcePressurePacketError,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? NativeSourcePressurePacketError, error, file: file, line: line)
        }
    }

    func testDeterministicPacketRetainsExactInputAssignmentCompletedOutputAndUntouchedSuffix() throws {
        let snapshot = try input()
        let prepared = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
        XCTAssertEqual(try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight()), prepared)
        let packet = try prepared.packet(), data = try recovery(prepared)
        XCTAssertEqual(packet.source, .budget); XCTAssertTrue(packet.resumeReady); XCTAssertNil(packet.clientID)
        XCTAssertTrue(packet.agents.isEmpty); XCTAssertTrue(packet.resumeSeedIsCustom)
        XCTAssertEqual((data["logical_input"] as? [String: Any])?["text_utf8"] as? String, logical)
        var approved = try XCTUnwrap(data["approved_assignment"] as? [String: Any])
        let document = try XCTUnwrap(approved.removeValue(forKey: "assignment_text_utf8") as? String)
        approved.removeValue(forKey: "document_encoding")
        approved["assignment_base64"] = Data(document.utf8).base64EncodedString()
        XCTAssertEqual(try ContinuityTaskAssignment.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: approved)), snapshot.assignment)
        let outputs = try XCTUnwrap(data["completed_outputs"] as? [[String: Any]])
        XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: outputs[0]["completed_result"]!), snapshot.completedOutputs[0].canonicalToolResultJSON)
        let suffix = try XCTUnwrap(data["untouched_call_intents"] as? [[String: Any]])
        XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: suffix[0]["arguments"]!), snapshot.untouchedCalls[0].canonicalArgumentsJSON)
        XCTAssertEqual(suffix[0]["execution_state"] as? String, "not_executed")
        XCTAssertEqual((data["remaining_budget"] as? [String: Any])?["remaining_source_calls"] as? Int, 5)
        XCTAssertFalse(packet.resumeSeed.contains("\"previous_response_id\""))
        XCTAssertFalse(packet.resumeSeed.contains("\"function_call_output\""))

        // Actual existing source commit and exact retrieval preserve the complete seed.
        let authority = try ContinuityIngressAuthorization(projectID: snapshot.identity.projectID, projectGeneration: .initial,
            sourceBindingID: UUID(), taskID: snapshot.identity.taskID, assignmentID: snapshot.assignment.assignmentID,
            assignmentSHA256: snapshot.assignment.assignmentSHA256, authorizationScope: snapshot.assignment.authorizationScope)
        let committed = try app.continuity.commitPreparedAuthorizedSourceCommit(prepared, authorization: authority, automaticHandoffEnabled: false)
        let restored = try app.continuity.authorizedHandoff(identity: committed.revision.identity, authorization: authority)
        XCTAssertEqual(restored.canonicalPacketJSON, prepared.canonicalPacketJSON)
        let payload: [String: Any] = ["ok": true, "found": true, "packet": packet.asDictionary(),
            "continuity_id": restored.identity.continuityID, "revision": restored.identity.revision, "packet_sha256": restored.identity.packetSHA256]
        let full = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": payload])
        XCTAssertNoThrow(try ContinuityBootstrapReadResult(canonicalToolResultJSON: full).verifiedPayload(source: restored, maximumBytes: 65_536))
        XCTAssertEqual(snapshot.remainingBudget.ceilings.tools.maxRetainedResultTokens, 4_096)
        XCTAssertLessThanOrEqual(try ContextBudgetMath.estimateTokens(serializedBytes: full.count, policy: ContextBudgetPolicy()), 4_096)
        XCTAssertNil(committed.delivery)
    }

    func testProjectionBindsFullDecisionAndSelectsExactInPacketIdentityAndResult() throws {
        let snapshot = try input(), originalMetadata = snapshot.canonicalDecisionJSON
        let prepared = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
        let data = try recovery(prepared), identity = try XCTUnwrap(data["identity"] as? [String: Any])
        let projection = try XCTUnwrap(data["pressure_decision"] as? [String: Any])
        let bytes = try ForgeJSONCanonicalizationV1.data(from: projection)
        XCTAssertLessThanOrEqual(bytes.count, NativeSourcePressurePacketDecisionV1.maximumStoredBytes)
        XCTAssertEqual(projection["metadata_sha256"] as? String, JSONSupport.sha256Hex(originalMetadata))
        XCTAssertEqual(projection["binding_identity_sha256"] as? String, try ForgeJSONCanonicalizationV1.sha256Hex(of: identity))
        XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: identity), try ForgeJSONCanonicalizationV1.data(from: snapshot.identity.wireObject))
        let progress = try XCTUnwrap(data["completed_progress"] as? [[String: Any]])
        let selected = try XCTUnwrap(progress.first { $0["stage_id"] as? String == projection["observed_result_stage_id"] as? String })
        XCTAssertEqual(selected["historical_response_id"] as? String, snapshot.completedProgress.first?.providerResponseID)
        XCTAssertEqual(selected["result_sha256"] as? String, snapshot.completedProgress.first?.resultSHA256)
        let remaining = try XCTUnwrap(data["remaining_budget"] as? [String: Any])
        let ceilings = try JSONDecoder().decode(NativeSourceBudgetCeilings.self,
            from: ForgeJSONCanonicalizationV1.data(from: XCTUnwrap(remaining["frozen_ceilings"])))
        XCTAssertEqual(ceilings, snapshot.remainingBudget.ceilings)
        XCTAssertEqual(snapshot.canonicalDecisionJSON, originalMetadata)
        XCTAssertEqual(try NativeSourcePressurePacketDecisionV1.storedSnapshot(from: bytes, metadataJSON: originalMetadata,
            identity: snapshot.identity).canonicalJSON, bytes)
        expect(.invalidSnapshot) {
            _ = try NativeSourcePressurePacketBuilder.build(replacing(snapshot, decision: bytes), responsePreflight: responsePreflight())
        }

        for field in ["metadata_sha256", "binding_identity_sha256", "observed_result_stage_id", "boundary"] {
            var changed = projection
            changed[field] = field == "boundary" ? "beforeProviderPost"
                : (field == "observed_result_stage_id" ? UUID().uuidString.lowercased() : String(repeating: "0", count: 64))
            expect(.invalidSnapshot) {
                _ = try NativeSourcePressurePacketDecisionV1.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: changed),
                    metadataJSON: originalMetadata, identity: snapshot.identity)
            }
        }
        expect(.decisionProjectionTooLarge) {
            _ = try NativeSourcePressurePacketDecisionV1.storedSnapshot(from: Data(repeating: 32, count: 4_097),
                metadataJSON: originalMetadata, identity: snapshot.identity)
        }
    }

    func testProjectionKeepsActualUsageSeparateFromProspectiveReservation() throws {
        for accepted in [false, true] {
            let snapshot = try input(withCalls: accepted)
            guard case .pressure(let decision) = try NativeSourceBudgetMetadata.storedSnapshot(from: snapshot.canonicalDecisionJSON) else {
                return XCTFail("Missing typed pressure")
            }
            let prepared = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
            let projection = try XCTUnwrap(recovery(prepared)["pressure_decision"] as? [String: Any])
            let actualBytes = try ForgeJSONCanonicalizationV1.data(from: XCTUnwrap(projection["actual"]))
            let actual = try JSONDecoder().decode(NativeSourceObservedContext.self, from: actualBytes)
            XCTAssertEqual(actual, decision.observation.fields.actual)
            if accepted {
                XCTAssertEqual(actual.rawProviderUsage?.source, .providerExact)
                XCTAssertEqual(actual.retainedInputTokens, 120_100)
                XCTAssertNil(projection["prospective"])
            } else {
                XCTAssertNil(actual.rawProviderUsage)
                XCTAssertEqual(actual.retainedInputTokens, 0)
                let prospective = try XCTUnwrap(projection["prospective"] as? [String: Any])
                XCTAssertEqual(prospective["projectedRetainedInputTokens"] as? Int, 120_100)
                XCTAssertEqual(prospective["serializedInputBytes"] as? Int, decision.observation.fields.prospective?.serializedInputBytes)
                XCTAssertNil(projection["observed_result_stage_id"])
            }
        }
    }

    func testBeforePostAndLegacyFallbackContainNoInventedProviderOutcome() throws {
        let legacy = Data("Full old root:\nUser input:\nThese delimiters are literal.\nUser input:\nNothing is inferred.".utf8)
        let prepared = try NativeSourcePressurePacketBuilder.build(input(legacy: legacy, withCalls: false), responsePreflight: responsePreflight())
        let data = try recovery(prepared), logical = try XCTUnwrap(data["logical_input"] as? [String: Any])
        XCTAssertEqual(logical["kind"] as? String, "legacy_retained_provider_request")
        XCTAssertEqual(logical["retained_request_utf8"] as? String, String(decoding: legacy, as: UTF8.self))
        XCTAssertEqual(logical["original_logical_input_available"] as? Bool, false)
        XCTAssertNil(logical["text_utf8"])
        XCTAssertTrue((data["completed_outputs"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue((data["completed_progress"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertFalse(try prepared.packet().resumeSeed.contains("actual-source-response"))
    }

    func testCriticalDataCannotBeClippedToPassPacketOrExistingBootstrapBounds() throws {
        expect(.criticalPacketTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(input(pending: Data(repeating: 120, count: 300_000), withCalls: false), responsePreflight: responsePreflight())
        }
        expect(.bootstrapOutputTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(input(pending: Data(repeating: 120, count: 80_000), withCalls: false), responsePreflight: responsePreflight())
        }
        expect(.bootstrapOutputTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(input(suffixArgumentBytes: 80_000), responsePreflight: responsePreflight())
        }
        expect(.bootstrapOutputTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(input(inlineLimit: 1_024), responsePreflight: responsePreflight())
        }
        expect(.assignmentNotUTF8) {
            _ = try NativeSourcePressurePacketBuilder.build(input(document: Data([0xff, 0xfe])), responsePreflight: responsePreflight())
        }
    }

    func testOnlyOptionalPreviewClipsWithExplicitLabelAndNoReplacementCharacters() throws {
        let snapshot = try input(preview: String(repeating: "λ🧭", count: 4_000))
        let prepared = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
        let packet = try prepared.packet()
        XCTAssertTrue(packet.narrative.contains("Optional preview (clipped):"))
        XCTAssertFalse(packet.narrative.contains("�"))
        XCTAssertLessThan(packet.narrative.utf8.count, 1_300)
        XCTAssertEqual((try recovery(prepared)["logical_input"] as? [String: Any])?["text_utf8"] as? String, logical)
        XCTAssertEqual((try recovery(prepared)["completed_outputs"] as? [[String: Any]])?.count, 1)
    }

    func testUnresolvedEffectAndMismatchedLogicalInputBlockConstruction() throws {
        expect(.unresolvedEffect) {
            _ = try NativeSourcePressurePacketBuilder.build(input(unresolved: ["Actual effect outcome is unknown"]), responsePreflight: responsePreflight())
        }
        let value = try input()
        let invalid = NativeSourcePressurePacketInput(identity: value.identity, assignment: value.assignment, logicalInput: .originalUTF8(Data("different input".utf8)),
            pendingRequest: nil, completedProgress: value.completedProgress, completedOutputs: value.completedOutputs,
            untouchedCalls: value.untouchedCalls, uncertainties: value.uncertainties, unresolvedEffects: [], remainingBudget: value.remainingBudget,
            canonicalDecisionJSON: value.canonicalDecisionJSON, optionalPreview: nil)
        expect(.logicalInputNotUTF8) {
            _ = try NativeSourcePressurePacketBuilder.build(invalid, responsePreflight: responsePreflight())
        }
    }


    private func replacing(_ value: NativeSourcePressurePacketInput,
                           completed: [NativeSourcePressureCompletedOutput]? = nil,
                           decision: Data? = nil) -> NativeSourcePressurePacketInput {
        NativeSourcePressurePacketInput(identity: value.identity, assignment: value.assignment, logicalInput: value.logicalInput,
            pendingRequest: value.pendingRequest, completedProgress: value.completedProgress,
            completedOutputs: completed ?? value.completedOutputs, untouchedCalls: value.untouchedCalls,
            uncertainties: value.uncertainties, unresolvedEffects: value.unresolvedEffects, remainingBudget: value.remainingBudget,
            canonicalDecisionJSON: decision ?? value.canonicalDecisionJSON, optionalPreview: value.optionalPreview)
    }

    func testCompletedOutputTamperingAndNoncanonicalDecisionAreRejected() throws {
        let snapshot = try input(), old = try XCTUnwrap(snapshot.completedOutputs.first)
        let badBytes = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false,
            "payload": ["ok": true, "content": "changed bytes"]])
        let corrupted = NativeSourcePressureCompletedOutput(stageID: old.stageID, ordinal: old.ordinal,
            providerResponseID: old.providerResponseID, providerCallID: old.providerCallID, toolName: old.toolName,
            canonicalArgumentsJSON: old.canonicalArgumentsJSON, argumentsSHA256: old.argumentsSHA256,
            canonicalToolResultJSON: badBytes, resultSHA256: old.resultSHA256, payloadSHA256: old.payloadSHA256,
            reservationID: old.reservationID, sourceReceiptSHA256: old.sourceReceiptSHA256)
        expect(.invalidSnapshot) {
            _ = try NativeSourcePressurePacketBuilder.build(replacing(snapshot, completed: [corrupted]), responsePreflight: responsePreflight())
        }
        expect(.invalidSnapshot) {
            _ = try NativeSourcePressurePacketBuilder.build(replacing(snapshot, decision: Data("{ \"reason\": \"pressure\" }".utf8)), responsePreflight: responsePreflight())
        }
    }

    func testActualCommitResponseBoundaryAndMalformedCallbackRemainTyped() throws {
        let snapshot = try input(), native = responsePreflight()
        let padded = try NativeSourcePressurePacketBuilder.build(snapshot) { prepared in
            var data = try native(prepared)
            data.append(Data(repeating: 32, count: NativeSourcePressurePacketBuilder.maximumResponseBytes - data.count))
            return data
        }
        XCTAssertTrue(padded.finalize)
        expect(.commitResponseTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(snapshot) { prepared in
                var data = try native(prepared)
                data.append(Data(repeating: 32, count: NativeSourcePressurePacketBuilder.maximumResponseBytes + 1 - data.count))
                return data
            }
        }
        expect(.invalidResponsePreflight) {
            _ = try NativeSourcePressurePacketBuilder.build(snapshot) { _ in Data("{}".utf8) }
        }
        expect(.responsePreflightRejected) {
            _ = try NativeSourcePressurePacketBuilder.build(snapshot) { _ in throw NativeSourcePressurePacketError.invalidSnapshot }
        }
    }

    func testBlockedOrForeignTypedDecisionCannotBecomeReadyHandoff() throws {
        let snapshot = try typedPressureInput()
        let metadata = try NativeSourceBudgetMetadata.storedSnapshot(from: snapshot.canonicalDecisionJSON)
        guard case .pressure(let decision) = metadata else { return XCTFail("Missing typed pressure fixture") }
        let blocked = try NativeSourceBudgetMetadata.blocked(.init(binding: decision.observation.binding,
            code: .toolQuotaExceeded, observation: decision.observation)).canonicalJSON()
        expect(.invalidSnapshot) {
            _ = try NativeSourcePressurePacketBuilder.build(replacing(snapshot, decision: blocked), responsePreflight: responsePreflight())
        }
        for field in ["taskID", "logicalRequestID", "intentSHA256"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.canonicalDecisionJSON) as? [String: Any])
            var pressure = try XCTUnwrap(object["pressure"] as? [String: Any])
            var observation = try XCTUnwrap(pressure["observation"] as? [String: Any])
            var binding = try XCTUnwrap(observation["binding"] as? [String: Any])
            binding[field] = field == "intentSHA256" ? String(repeating: "e", count: 64) : UUID().uuidString
            observation["binding"] = binding; pressure["observation"] = observation; object["pressure"] = pressure
            let changed = try ForgeJSONCanonicalizationV1.data(from: object)
            XCTAssertNoThrow(try NativeSourceBudgetMetadata.storedSnapshot(from: changed), "The foreign metadata remains structurally valid")
            expect(.invalidSnapshot) {
                _ = try NativeSourcePressurePacketBuilder.build(replacing(snapshot, decision: changed), responsePreflight: responsePreflight())
            }
        }
    }

    func testRecoveryOutputBelowTransportLimitMustRespectInheritedByteCeiling() throws {
        let snapshot = try typedPressureInput(maxResultBytes: 1_024)
        let wide = try typedPressureInput()
        let prepared = try NativeSourcePressurePacketBuilder.build(wide, responsePreflight: responsePreflight())
        let measured = try fullRecoveryResult(prepared)
        XCTAssertLessThan(measured.count, 65_536)
        XCTAssertLessThan(measured.count, snapshot.assignment.authorizationScope.maximumInlineOutputBytes)
        XCTAssertGreaterThan(measured.count, snapshot.remainingBudget.ceilings.tools.maxResultBytes)
        expect(.bootstrapOutputTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
        }
    }

    func testRecoveryOutputBelowByteCeilingMustRespectInheritedRetainedTokens() throws {
        let snapshot = try typedPressureInput(maxRetainedResultTokens: 64)
        let wide = try typedPressureInput()
        let prepared = try NativeSourcePressurePacketBuilder.build(wide, responsePreflight: responsePreflight())
        let measured = try fullRecoveryResult(prepared)
        let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: measured.count, policy: ContextBudgetPolicy())
        XCTAssertLessThan(measured.count, min(65_536, snapshot.remainingBudget.ceilings.tools.maxResultBytes))
        XCTAssertGreaterThan(tokens, snapshot.remainingBudget.ceilings.tools.maxRetainedResultTokens)
        expect(.bootstrapOutputTooLarge) {
            _ = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
        }
    }

    func testRecoveryOutputAtExactByteAndTokenCeilingsRetainsAllCriticalData() throws {
        for byteBoundary in [true, false] {
            var limit = 65_536
            var matched = false
            for _ in 0..<4 {
                let snapshot = try typedPressureInput(maxResultBytes: byteBoundary ? limit : 65_536,
                    maxRetainedResultTokens: byteBoundary ? 65_536 : limit)
                let prepared = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight())
                let full = try fullRecoveryResult(prepared)
                let measured = try byteBoundary ? full.count
                    : ContextBudgetMath.estimateTokens(serializedBytes: full.count, policy: ContextBudgetPolicy())
                if measured == limit {
                    matched = true
                    let data = try recovery(prepared)
                    XCTAssertEqual((data["logical_input"] as? [String: Any])?["text_utf8"] as? String, logical)
                    let outputs = try XCTUnwrap(data["completed_outputs"] as? [[String: Any]])
                    XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: XCTUnwrap(outputs.first?["completed_result"])),
                        snapshot.completedOutputs.first?.canonicalToolResultJSON)
                    let suffix = try XCTUnwrap(data["untouched_call_intents"] as? [[String: Any]])
                    XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: XCTUnwrap(suffix.first?["arguments"])),
                        snapshot.untouchedCalls.first?.canonicalArgumentsJSON)
                    break
                }
                // Only numeric digit widths change the next full result. The complete critical data stays fixed.
                XCTAssertLessThan(measured, limit)
                limit = measured
            }
            XCTAssertTrue(matched, "The bounded fixture must reach its exact serialized limit")
        }
    }

    private func fullRecoveryResult(_ prepared: PreparedContinuitySourceCommit) throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": [
            "ok": true, "found": true, "packet": JSONSerialization.jsonObject(with: prepared.canonicalPacketJSON),
            "continuity_id": prepared.continuityID, "revision": Int64.max, "packet_sha256": prepared.packetSHA256]])
    }

    private func typedPressureInput(maxResultBytes: Int = 65_536,
                                    maxRetainedResultTokens: Int = 65_536) throws -> NativeSourcePressurePacketInput {
        try applyingTypedPressure(rawInput(), maxResultBytes: maxResultBytes, maxRetainedResultTokens: maxRetainedResultTokens)
    }

    private func applyingTypedPressure(_ value: NativeSourcePressurePacketInput,
                                      maxResultBytes: Int, maxRetainedResultTokens: Int) throws -> NativeSourcePressurePacketInput {
        let id = value.identity
        let tools = BudgetToolPolicy(callsPerTurn: 8, callsPerSession: 8, callsPerRun: 8, maxInFlight: 2,
            maxResultBytes: maxResultBytes, maxRetainedResultTokens: maxRetainedResultTokens, recoveryCallsPerRollover: 4)
        let selection = try BudgetPolicyState(globalPolicy: .init(tools: tools)).resolve(.init(kind: .projectOverride,
            projectID: id.projectID.description, projectGeneration: Int(id.projectGeneration.rawValue)))
        let capabilities = try ProviderCapabilities(providerID: value.assignment.providerID, providerVersion: "fixture-1",
            modelKey: value.assignment.modelKey, providerInstanceID: "fixture-instance", contextLength: 131_072,
            maximumContextLength: 131_072, statefulResponses: true, streaming: true, customTools: true, mcp: false,
            structuredOutput: true, usageReporting: true, idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "d", count: 64))
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities, selection: selection)
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        let ceilings = NativeSourceBudgetCeilings(effectiveContextTokens: resolved.effectiveContextTokens,
            maximumOutputTokens: 64, tools: tools, reserves: configuration.reserves,
            checkpointRatio: resolved.effectiveCheckpointRatio, rolloverRatio: resolved.effectiveRolloverRatio,
            emergencyRatio: resolved.effectiveEmergencyRatio)
        let usage = try ProviderUsage(capacity: 131_072, inputTokens: 120_000, outputTokens: 100,
            source: .providerExact, confidence: 1)
        let progress = value.completedProgress.first
        let prefix: [[String: Any]] = try value.completedOutputs.map { output in
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output.canonicalToolResultJSON) as? [String: Any])
            let payload = try ForgeJSONCanonicalizationV1.data(from: XCTUnwrap(result["payload"]))
            return ["type": "function_call_output", "call_id": output.providerCallID, "output": String(decoding: payload, as: UTF8.self)]
        }
        let binding = NativeSourceBudgetBinding(projectID: id.projectID, projectGeneration: id.projectGeneration,
            taskID: id.taskID, capabilityID: UUID(), capabilityEpoch: 1, conversationID: id.conversationID,
            conversationRevision: id.fenceRevision - 1, stageID: id.stageID, stageOrdinal: 1,
            logicalRequestID: id.requestID, assignmentSHA256: id.assignmentSHA256, logicalInputSHA256: id.logicalInputSHA256,
            intentSHA256: id.intentSHA256, sourceInferenceDeadline: "2026-09-08T12:05:00Z", stageState: progress == nil ? .prepared : .accepted,
            boundary: progress == nil ? .beforeProviderPost : .acceptedProviderResponse, observedResult: progress.map { .init(stageID: id.stageID,
                providerRequestID: id.stageID.uuidString.lowercased(), providerResponseID: $0.providerResponseID,
                resultSHA256: $0.resultSHA256) }, completedOutputCount: value.completedOutputs.count,
            completedOutputsSHA256: try ForgeJSONCanonicalizationV1.sha256Hex(of: prefix), pendingCall: nil,
            sourceReadCallsBeforeEnrollment: 1, admittedProviderCallsBeforeStage: 0,
            admittedCallsInStage: value.completedOutputs.count + value.untouchedCalls.count, sourceMaximumCalls: 8)
        let limits = try ProviderExecutionLimits(maximumOutputTokens: 64, maximumRequestBytes: 524_288,
            maximumResponseBytes: 1_048_576, maximumTextBytes: 1_048_576, maximumToolArgumentBytes: 262_144,
            maximumJSONBytes: 1_048_576, maximumSSELineBytes: 65_536, maximumSSEEventBytes: 1_048_576,
            connectTimeoutSeconds: 5, firstByteTimeoutSeconds: 30, idleTimeoutSeconds: 30, totalTimeoutSeconds: 120)
        let preflight = try ProviderRequestPreflight(kind: .root, modelKey: value.assignment.modelKey,
            configurationRevision: "fixture-1", configurationFingerprintSHA256: String(repeating: "d", count: 64),
            limits: limits, bodySHA256: String(repeating: "f", count: 64), bodyByteCount: 1_024, serializedInputByteCount: 512)
        let observation = try NativeSourceBudgetObservation(.init(binding: binding, preflight: .init(preflight),
            capabilities: capabilities, configuration: configuration, originalCeilings: ceilings, effectiveCeilings: ceilings,
            toolSchemaSHA256: String(repeating: "f", count: 64), actual: .init(retainedInputTokens: progress == nil ? 0 : usage.totalTokens,
                retainedSerializedBytes: progress == nil ? 0 : 1_024, rawProviderUsage: progress == nil ? nil : usage,
                source: progress == nil ? .serializedEstimate : .providerExact, confidence: progress == nil ? 0.65 : 1),
            prospective: progress == nil ? .init(projectedRetainedInputTokens: 120_100, serializedInputBytes: preflight.bodyByteCount,
                outputRequirement: nil, continuationPreflight: nil) : nil))
        let measuredTotal = try observation.projectedTotalTokens ?? observation.observedTotalTokens
        let total = try XCTUnwrap(measuredTotal)
        let emergency = total >= Int(ceil(Double(ceilings.effectiveContextTokens) * ceilings.emergencyRatio))
        let metadata = try NativeSourceBudgetMetadata.pressure(.init(observation: observation,
            reason: emergency ? .emergencyThreshold : .rolloverThreshold, action: emergency ? .emergency : .rollover)).canonicalJSON()
        return .init(identity: id, assignment: value.assignment, logicalInput: value.logicalInput, pendingRequest: value.pendingRequest,
            completedProgress: value.completedProgress, completedOutputs: value.completedOutputs, untouchedCalls: value.untouchedCalls,
            uncertainties: value.uncertainties, unresolvedEffects: value.unresolvedEffects,
            remainingBudget: .init(ceilings: ceilings, sourceLimits: value.remainingBudget.sourceLimits,
                priorSourceReadCallsAtEnrollment: 1, admittedProviderCalls: value.remainingBudget.admittedProviderCalls,
                providerStageCount: value.remainingBudget.providerStageCount, capabilityCheckCount: 1),
            canonicalDecisionJSON: metadata, optionalPreview: value.optionalPreview)
    }
}
