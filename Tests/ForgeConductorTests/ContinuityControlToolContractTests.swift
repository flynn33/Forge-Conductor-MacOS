import XCTest
@testable import ForgeConductorCore

final class ContinuityControlToolContractTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testCatalogAddsFourExactClosedSchemasAndPreservesLegacyDeadline() throws {
        let controls = ContinuityControlToolName.allCases.map(\.rawValue)
        let catalog = try ToolDefinitionCatalog.production(toolNames: controls + ["fs_read", "context_get", "session_handoff"])
        XCTAssertEqual(Set(catalog.definitions.map(\.name)), Set(controls + ["fs_read", "context_get", "session_handoff"]))
        let expected: [ContinuityControlToolName: Set<String>] = [
            .capabilities: [], .startHandoff: ["continuity_id", "idempotency_key", "reason"],
            .status: ["operation_id"], .cancel: ["operation_id"],
        ]
        for name in ContinuityControlToolName.allCases {
            let definition = try XCTUnwrap(catalog.definition(named: name.rawValue))
            XCTAssertTrue(definition.strict)
            let schema = try definition.inputSchemaObject()
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), expected[name])
            XCTAssertNil(properties["deadline_ms"])
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertEqual(required, name == .capabilities ? [] : [name == .startHandoff ? "continuity_id" : "operation_id"])
        }
        for name in ["fs_read", "context_get", "session_handoff"] {
            let schema = try XCTUnwrap(catalog.definition(named: name)).inputSchemaObject()
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(properties["deadline_ms"])
        }
        XCTAssertThrowsError(try ToolDefinitionCatalog.production(toolNames: ["clu.session.start"])) {
            XCTAssertEqual($0 as? ToolDefinitionCatalogError, .missingDefinitions(["clu.session.start"]))
        }
    }

    func testProviderWildcardExcludesControlsAndExplicitGrantFails() throws {
        let controls = ContinuityControlToolName.allCases.map(\.rawValue)
        let catalog = try ToolDefinitionCatalog.production(toolNames: controls + ["fs_read", "memory_get"])
        XCTAssertEqual(try catalog.definitions(allowedToolNames: ["*"]).count, 6)
        XCTAssertEqual(try catalog.mcpDescriptors().count, 6)
        let tools = try catalog.providerToolDefinitions(allowedToolNames: ["*"])
        let names = try tools.map { try JSONSupport.object(from: $0)["name"] as? String }
        XCTAssertEqual(names, ["fs_read", "memory_get"])
        for name in controls {
            let selections: [Set<String>] = [[name], ["*", name], ["fs_read", name]]
            for allowed in selections {
                XCTAssertThrowsError(try catalog.providerToolDefinitions(allowedToolNames: allowed)) {
                    XCTAssertEqual($0 as? ToolDefinitionCatalogError, .controlPlaneOnlyTools([name]))
                }
            }
        }
        XCTAssertEqual(try catalog.providerToolDefinitions(allowedToolNames: ["fs_read"]).count, 1)
        XCTAssertEqual(ToolDefinitionCatalog.controlPlaneOnlyToolNames, Set(controls))
    }

    func testRequestsParseOnlyExactInputsAndNormalizeOperationUUID() throws {
        XCTAssertEqual(try ContinuityControlToolRequest(name: "clu_capabilities", arguments: [:]), .capabilities)
        let id = UUID()
        XCTAssertEqual(try ContinuityControlToolRequest(name: "clu_status", arguments: ["operation_id": id.uuidString]), .status(id))
        XCTAssertEqual(try ContinuityControlToolRequest(name: "clu_cancel", arguments: ["operation_id": id.uuidString.lowercased()]), .cancel(id))
        let arguments: [String: Any] = ["continuity_id": "source-1", "idempotency_key": "request-1", "reason": "Continue work"]
        XCTAssertEqual(try ContinuityControlToolRequest(name: "clu_start_handoff", arguments: arguments),
                       .start(try ContinuityExplicitHandoffRequest(arguments: arguments)))
    }

    func testDirectBrokerRejectsControlsBeforeContextClassificationOrClosedStoreAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forge-control-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try ProjectControlPlaneRepository(databaseURL: directory.appendingPathComponent("control.sqlite3"))
        await repository.close()
        let probe = ContinuityControlBrokerProbe()
        let broker = ToolInvocationBroker(repository: repository, executor: probe, classifier: probe, reconciler: probe)
        let runID = RunID()
        let lease = RunLease(runID: runID, ownerID: "unbound-test-owner", epoch: 1,
            acquiredAt: "2026-09-08T00:00:00Z", renewedAt: "2026-09-08T00:00:00Z", expiresAt: "2026-09-08T00:01:00Z")
        for tool in ContinuityControlToolName.allCases {
            let grants: [Set<String>] = [["*"], [tool.rawValue]]
            for allowedTools in grants {
                let scope = ToolAuthorizationScope(canonicalRoots: [directory], writableRoots: [],
                    allowedTools: allowedTools, networkAllowed: false, maximumInlineOutputBytes: 65_536)
                let contexts = [
                    ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("broker-control"),
                        runID: runID, providerSessionID: "unbound-test-provider", authorizationScope: scope),
                    ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("broker-control"),
                        authorizationScope: scope),
                ]
                for context in contexts {
                    do {
                        _ = try await broker.invoke(.init(providerCallID: UUID().uuidString, toolName: tool.rawValue,
                            arguments: [:]), turnID: UUID(), context: context, lease: lease)
                        XCTFail("A native control reached ordinary broker dispatch")
                    } catch {
                        XCTAssertEqual(error as? AutonomyError, .invalidToolConfiguration([tool.rawValue]))
                    }
                }
            }
        }
        XCTAssertEqual(probe.callCount, 0)
    }

    func testRequestValidationRejectsUnknownNullCoercedAndAuthorityFields() throws {
        let id = UUID().uuidString
        let invalid: [(String, [String: Any])] = [
            ("clu_capabilities", ["deadline_ms": 10]), ("clu_capabilities", ["project_id": NSNull()]),
            ("clu_start_handoff", [:]), ("clu_start_handoff", ["continuity_id": NSNull()]),
            ("clu_start_handoff", ["continuity_id": false]), ("clu_start_handoff", ["continuity_id": ["source"]]),
            ("clu_start_handoff", ["continuity_id": "source", "task_id": id]),
            ("clu_start_handoff", ["continuity_id": "source", "deadline_ms": 10]),
            ("clu_start_handoff", ["continuity_id": "source", "idempotency_key": NSNull()]),
            ("clu_start_handoff", ["continuity_id": "source", "reason": 17]),
            ("clu_status", [:]), ("clu_status", ["operation_id": NSNull()]),
            ("clu_status", ["operation_id": id, "run_id": id]),
            ("clu_status", ["operation_id": UUID()]), ("clu_status", ["operation_id": id + "\n"]),
            ("clu_status", ["operation_id": "{" + id + "}"]), ("clu_status", ["operation_id": id.replacingOccurrences(of: "-", with: "")]),
            ("clu_cancel", ["operation_id": id, "force": true]), ("clu_cancel", ["operation_id": id, "reason": "cancel"]),
            ("clu_cancel", ["operation_id": 123]), ("clu_cancel", ["operation_id": "latest"]),
        ]
        for (name, arguments) in invalid {
            XCTAssertThrowsError(try ContinuityControlToolRequest(name: name, arguments: arguments)) {
                XCTAssertEqual(($0 as? ContinuityControlToolFailure)?.code, .invalidRequest)
            }
        }
        XCTAssertThrowsError(try ContinuityControlToolRequest(name: "clu.session.start", arguments: [:])) {
            XCTAssertEqual($0 as? ContinuityControlToolFailure, .init(.invalidRequest, field: .toolName))
        }
    }

    func testStartParserEnforcesUTF8LimitsAndExistingIDGrammar() throws {
        let boundary: [String: Any] = ["continuity_id": String(repeating: "s", count: 128),
            "idempotency_key": String(repeating: "é", count: 128), "reason": String(repeating: "é", count: 256)]
        _ = try ContinuityControlToolRequest(name: "clu_start_handoff", arguments: boundary)
        for (key, values) in [
            "continuity_id": [".", "..", "source/path", "é", String(repeating: "s", count: 129)],
            "idempotency_key": ["", " key", "key ", "a\u{0085}b", String(repeating: "é", count: 129)],
            "reason": ["", "\nreason", "a\u{0}b", String(repeating: "é", count: 257)],
        ] {
            for value in values {
                var arguments = boundary
                arguments[key] = value
                XCTAssertThrowsError(try ContinuityControlToolRequest(name: "clu_start_handoff", arguments: arguments)) {
                    XCTAssertEqual(($0 as? ContinuityControlToolFailure)?.code, .invalidRequest)
                }
            }
        }
    }

    func testFailureMappingUsesFixedTemplatesAndNeverReflectsPrivateDetails() throws {
        let privateDetail = "private-provider-token:/private/project"
        let inputs: [(Error, ContinuityControlToolFailure.Code)] = [
            (ContinuityTaskAuthorizationError.taskCorrelationRequired, .taskIdentityUnavailable),
            (ContinuityTaskAuthorizationError.authorityMismatch, .authorityMismatch),
            (ContinuityTaskAuthorizationError.revoked, .revoked),
            (ContinuityIngressError.invalidRequest(privateDetail), .invalidRequest),
            (ContinuityIngressError.invalidRequest("handoff_is_not_resume_ready"), .sourceNotReady),
            (ContinuityIngressError.integrityFailure(privateDetail), .integrityFailure),
            (ContinuityOperationControlError.notFound, .notFound),
            (ContinuityOperationControlError.conflict, .conflict),
            (ContinuityOperationControlError.integrityFailure, .integrityFailure),
            (ContinuityOperationControlError.cancellationRequested, .conflict),
            (ContinuityOperationControlError.reconciliationRequired, .conflict),
            (ContinuityOperationControlError.invalidRequest, .invalidRequest),
            (ProjectContextError.databaseBusy, .operationBusy),
            (ProjectContextError.databaseFailure(privateDetail), .internalError),
            (CancellationError(), .cancelled),
            (NSError(domain: privateDetail, code: 1, userInfo: [NSLocalizedDescriptionKey: privateDetail]), .internalError),
        ]
        for (error, code) in inputs {
            let failure = ContinuityControlToolFailure.mapping(error)
            XCTAssertEqual(failure.code, code)
            let result = try ContinuityControlToolResponse.failure(failure).toolResult()
            XCTAssertFalse(result.ok); XCTAssertTrue(result.isError)
            let text = try JSONSupport.string(from: result.payload)
            XCTAssertFalse(text.contains(privateDetail))
            XCTAssertEqual(Set(result.payload.keys), ["ok", "schema_version", "code", "field", "message", "retryable"])
        }
        for code in ContinuityControlToolFailure.Code.allCases {
            let result = try ContinuityControlToolResponse.failure(.init(code)).toolResult()
            XCTAssertLessThanOrEqual(try JSONSupport.data(from: result.payload).count, 32_768)
            XCTAssertLessThanOrEqual((result.payload["message"] as? String)?.utf8.count ?? Int.max, 512)
        }
    }

    func testCapabilitiesPreserveUnknownEvidenceAndDoNotClaimUnboundReadiness() throws {
        let result = try ContinuityControlToolResponse.capabilities(capabilities()).toolResult()
        for field in ["deployed", "connected", "automatic_handoff_enabled", "deployment_id"] {
            XCTAssertTrue(result.payload[field] is NSNull, field)
        }
        XCTAssertEqual(result.payload["ready"] as? Bool, false)
        XCTAssertEqual(result.payload["task_identity"] as? String, "unavailable")
        XCTAssertEqual(result.payload["exact_id_support"] as? Bool, true)
        XCTAssertEqual((result.payload["limits"] as? [String: Int])?["maximum_response_bytes"], 32_768)
        XCTAssertThrowsError(try ContinuityControlToolResponse.capabilities(capabilities(ready: true)).toolResult())
        XCTAssertThrowsError(try ContinuityControlToolResponse.capabilities(capabilities(reasons: ["secret/path"])).toolResult())
        XCTAssertThrowsError(try ContinuityControlToolResponse.capabilities(capabilities(reasons: Array(repeating: "same", count: 17))).toolResult())
    }

    func testVerifiedReadinessDoesNotRequireAutomaticPolicyOrQualificationClaim() throws {
        let result = try ContinuityControlToolResponse.capabilities(capabilities(ready: true, verified: true)).toolResult()
        XCTAssertEqual(result.payload["ready"] as? Bool, true)
        XCTAssertEqual(result.payload["automatic_handoff_enabled"] as? Bool, false)
        let qualification = try XCTUnwrap(result.payload["qualification"] as? [String: String])
        XCTAssertEqual(Set(qualification.values), ["not_observed"])
    }

    func testStatusPreservesExactInt64RevisionAndUnknownSourceEvidence() throws {
        let operation = try status(revision: Int64.max, delivery: .unknown)
        let result = try ContinuityControlToolResponse.status(operation).toolResult()
        let bytes = try JSONSupport.data(from: result.payload)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"revision\":9223372036854775807"))
        let decoded = try JSONSupport.object(from: bytes)
        let payload = try XCTUnwrap(decoded["operation"] as? [String: Any])
        let source = try XCTUnwrap(payload["source"] as? [String: Any])
        XCTAssertEqual((source["revision"] as? NSNumber)?.stringValue, String(Int64.max))
        XCTAssertEqual(payload["delivery_state"] as? String, "unknown")
        XCTAssertTrue(payload["terminal_receipt"] is NSNull)
        XCTAssertEqual(ContinuityControlOperationStatus.DeliveryState(source: nil), .unknown)
        for state in ContinuityDeliveryState.allCases {
            XCTAssertEqual(ContinuityControlOperationStatus.DeliveryState(source: state).rawValue, state.rawValue)
        }
    }

    func testTerminalAndCancellationPayloadsCannotClaimUnprovenCompletion() throws {
        let receipt = ContinuityControlOperationStatus.TerminalReceipt(outcome: .resumed, receiptSHA256: digest,
            recordedAt: "2026-09-08T00:00:00Z")
        XCTAssertThrowsError(try ContinuityControlToolResponse.status(status(state: .successorAcknowledged, receipt: receipt)).toolResult())
        XCTAssertThrowsError(try ContinuityControlToolResponse.status(status(state: .resumed)).toolResult())
        let terminal = try status(state: .resumed, receipt: receipt)
        let result = try ContinuityControlToolResponse.cancelled(disposition: .alreadyTerminal, operation: terminal).toolResult()
        XCTAssertEqual(result.payload["disposition"] as? String, "already_terminal")
        XCTAssertThrowsError(try ContinuityControlToolResponse.cancelled(disposition: .requested, operation: terminal).toolResult())
        let pending = try status(state: .cancelRequested)
        _ = try ContinuityControlToolResponse.cancelled(disposition: .requested, operation: pending).toolResult()
        _ = try ContinuityControlToolResponse.cancelled(disposition: .alreadyRequested, operation: pending).toolResult()
        XCTAssertThrowsError(try ContinuityControlToolResponse.cancelled(disposition: .alreadyTerminal, operation: pending).toolResult())
    }

    func testResponseBoundIncludesDuplicateMCPRepresentationsAndEscaping() throws {
        let small: [String: Any] = ["ok": true, "value": String(repeating: "a", count: 1_000)]
        _ = try ContinuityControlWire.boundedResult(payload: small)
        let large: [String: Any] = ["ok": true, "value": String(repeating: "a", count: 17_000)]
        XCTAssertLessThan(try JSONSupport.data(from: large).count, 32_768)
        XCTAssertThrowsError(try ContinuityControlWire.boundedResult(payload: large)) {
            XCTAssertEqual($0 as? ContinuityControlToolFailure, .init(.capacityExceeded, field: .response))
        }
        let escaped: [String: Any] = ["ok": true, "value": String(repeating: "\"\\", count: 4_000)]
        XCTAssertLessThan(try JSONSupport.data(from: escaped).count, 32_768)
        XCTAssertThrowsError(try ContinuityControlWire.boundedResult(payload: escaped))
        XCTAssertThrowsError(try ContinuityControlWire.boundedResult(payload: ["ok": 1]))
        XCTAssertThrowsError(try ContinuityControlWire.boundedResult(payload: ["ok": true, "value": Double.infinity]))
    }

    func testStartResponseIncludesOnlyStableAcceptedHandleAndFrozenIdentity() throws {
        let privatePayload = "private-assignment-and-packet-contents"
        let scope = ToolAuthorizationScope(canonicalRoots: [URL(fileURLWithPath: "/tmp/clu-contract")],
            writableRoots: [], allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let authorization = try ContinuityIngressAuthorization(projectID: ProjectID(), projectGeneration: .initial,
            sourceBindingID: UUID(), taskID: UUID(), assignmentID: privatePayload, assignmentSHA256: digest, authorizationScope: scope)
        let packet = HandoffPacket(id: "contract-source", source: .model, resumeReady: true,
            clientID: "contract", goal: privatePayload, narrative: privatePayload)
        let bytes = try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary())
        let source = try ContinuityHandoffRevision(identity: .init(continuityID: packet.id, revision: 1,
            packetSHA256: JSONSupport.sha256Hex(bytes)), authorization: authorization, canonicalPacketJSON: bytes,
            resumeReady: true, committedAt: "2026-09-08T00:00:00Z")
        let identity = try ContinuityIngressOperationIdentity(revision: source)
        let acceptance = try ContinuityIngressAcceptanceReceipt(source: source, operationID: identity.operationID,
            runID: RunID(), policySelection: .init(scope: .globalDefault, revision: 1, globalRevision: 1,
                inherited: false, policy: BudgetPolicy()), acceptedAt: "2026-09-08T00:00:00Z")
        let permit = try ContinuityExplicitStartPermit(requestID: UUID(), acceptance: acceptance,
            callerBindingID: UUID(), issuedAt: "2026-09-08T00:00:00Z")
        let receipt = ContinuityExplicitStartReceipt(acceptance: acceptance, permit: permit)
        let result = try ContinuityControlToolResponse.started(receipt).toolResult()
        XCTAssertEqual(Set(result.payload.keys), ["ok", "schema_version", "submission", "operation_id", "run_id", "source", "acceptance_receipt_sha256"])
        XCTAssertEqual(result.payload["submission"] as? String, "accepted")
        XCTAssertEqual(result.payload["operation_id"] as? String, identity.operationID.uuidString.lowercased())
        let text = try JSONSupport.string(from: result.payload)
        XCTAssertFalse(text.contains(privatePayload)); XCTAssertFalse(text.contains(permit.permitSHA256))
        XCTAssertEqual(try JSONSupport.data(from: result.payload),
            try JSONSupport.data(from: ContinuityControlToolResponse.started(receipt).toolResult().payload))
    }

    private func capabilities(ready: Bool = false, verified: Bool = false,
        reasons: [String]? = nil) -> ContinuityControlCapabilities {
        .init(deployed: verified ? true : nil, connected: verified ? true : nil, ready: ready,
            automaticHandoffEnabled: verified ? false : nil, exactIDSupport: true,
            providerMode: .nativeLMStudioResponses, taskIdentity: verified ? .verifiedNativeTask : .unavailable,
            role: .primary, deploymentID: nil, buildVersion: "0.9.0",
            qualification: .init(nativeAPI: .notObserved, desktopNewChat: .notObserved,
                guiClosedRecovery: .notObserved, laterRollover: .notObserved),
            reasons: reasons ?? (verified ? [] : ["task_identity_unavailable"]))
    }

    private func status(revision: Int64 = 1, state: ContinuityControlOperationStatus.State = .successorAcknowledged,
        delivery: ContinuityControlOperationStatus.DeliveryState = .acknowledged,
        receipt: ContinuityControlOperationStatus.TerminalReceipt? = nil) throws -> ContinuityControlOperationStatus {
        .init(operationID: UUID(), runID: RunID(), source: try .init(continuityID: "contract-source", revision: revision, packetSHA256: digest),
            state: state, deliveryState: delivery, recovery: .init(state: .none, reasonCode: nil, retryAt: nil), terminalReceipt: receipt)
    }
}

private final class ContinuityControlBrokerProbe: ToolExecuting, ToolReplayClassifying, ToolInvocationReconciling, @unchecked Sendable {
    private enum Failure: Error { case unexpectedDispatch }
    private let lock = NSLock()
    private var calls = 0
    var toolNames: [String] { ContinuityControlToolName.allCases.map(\.rawValue) }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    private func reached() throws {
        lock.lock(); calls += 1; lock.unlock()
        throw Failure.unexpectedDispatch
    }
    func call(name: String, arguments: [String: Any], clientID: ClientID) throws -> ToolResult {
        try reached(); return .failure(code: "unexpected_dispatch", message: "Unexpected dispatch")
    }
    func call(name: String, arguments: [String: Any], context: ToolInvocationContext) throws -> ToolResult {
        try reached(); return .failure(code: "unexpected_dispatch", message: "Unexpected dispatch")
    }
    func replayClass(for toolName: String) throws -> ToolReplayClass {
        try reached(); return .nonReplayable
    }
    func prepare(call: BrokeredToolCall, context: ToolInvocationContext) async throws -> String? {
        try reached(); return nil
    }
    func reconcile(invocation: ToolInvocationRecord, call: BrokeredToolCall,
        context: ToolInvocationContext) async throws -> ToolReconciliationOutcome {
        try reached(); return .unresolved
    }
}
