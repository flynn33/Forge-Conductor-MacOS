# Source Evidence Excerpts

Repository archive SHA-256: `8b38cd6bf86f0e90a4fa0567fcc8e7e7ead88285f64e03880efe894d19c6aeb7`

## AGENTS requires missing design package

`AGENTS.md:1-40`

```text
    1 | <!-- FORGE-AUTONOMOUS-CONTINUITY-DESIGN:BEGIN -->
    2 | # Autonomous continuity implementation supplement
    3 | 
    4 | Before autonomy, continuity, project context, provider, shell, or runtime work, read `.forge-continuity-design/AGENTS.md` and execute `.forge-continuity-design/schemas/work-packages.json`. This supplement requires shell enabled by default, exact project-generation binding, manager-owned context enforcement, a real LM Studio transport in the existing session-host plugin, automatic fresh-root rollover, predecessor fencing, crash recovery, and automatic continuation.
    5 | <!-- FORGE-AUTONOMOUS-CONTINUITY-DESIGN:END -->
    6 | 
    7 | <!-- FORGE-CONDUCTOR-AUTONOMOUS-CONTRACT:BEGIN -->
    8 | # Forge Conductor repository execution contract
    9 | 
   10 | ## Mission
   11 | 
   12 | Deliver a production-quality native macOS Forge Conductor application in which:
   13 | 
   14 | - every current user-facing and protocol-facing feature remains available;
   15 | - memory leaks and leak-like unbounded retention are removed and proven with repeatable evidence;
   16 | - gauges and telemetry are correctly wired, bounded, responsive, and quiescent when not visible;
   17 | - project memory is exposed through a reliable project-scoped MCP server;
   18 | - continuity checkpoints and handoffs are durable, compact, crash-safe, and automatically consumed;
   19 | - the active model session can roll over without operator intervention when the host exposes a supported session API;
   20 | - a statically registered host-adapter plugin is built when Forge must own session creation;
   21 | - the application remains efficient on supported Macs with differing physical-memory capacities;
   22 | - build, test, debug, profiling, migration, compatibility, and recovery evidence is retained.
   23 | 
   24 | This file is authoritative for the repair run. Repository-specific instructions that follow this section remain in force unless they conflict with a stricter requirement here.
   25 | 
   26 | ## Required reading before editing
   27 | 
   28 | Read, in order:
   29 | 
   30 | 1. `.forge-codex/docs/EXECUTION_CONTRACT.md`
   31 | 2. `.forge-codex/docs/EVIDENCE_RULES.md`
   32 | 3. `.forge-codex/docs/DECISION_POLICY.md`
   33 | 4. `.forge-codex/docs/FAIL_FORWARD_POLICY.md`
   34 | 5. `.forge-codex/docs/FEATURE_PRESERVATION.md`
   35 | 6. `.forge-codex/docs/AUDIT_TO_REMEDIATION.md`
   36 | 7. `.forge-codex/docs/PHASE_PLAYBOOK.md`
   37 | 8. `.forge-codex/architecture/TARGET_ARCHITECTURE.md`
   38 | 9. `.forge-codex/specifications/COMPLETION_GATES.md`
   39 | 10. `.forge-codex/plans/phases.json`
   40 | 11. `.forge-codex/plans/gates.json`
```

## App tabs omit Work Queue

`Sources/ForgeConductorApp/AppModel.swift:65-90`

```text
   65 | 
   66 |     private var managerPoll: AnyCancellable?
   67 |     private var telemetryBag: AnyCancellable?
   68 |     private var managerPollInFlight = false
   69 |     private var remoteManagerLastError: String?
   70 | 
   71 |     public enum AppTab: String, CaseIterable, Identifiable {
   72 |         case rig = "FORGE RIG"
   73 |         case mcp = "LM Studio MCP"
   74 |         case agents = "Agents"
   75 |         case tools = "Tools"
   76 |         case feed = "Live Feed"
   77 |         case projects = "Projects"
   78 |         case autonomy = "Autonomy"
   79 |         case continuity = "Continuity"
   80 |         case runtimes = "Runtimes"
   81 |         case provider = "Provider"
   82 |         case evidence = "Events & Evidence"
   83 |         case diagnostics = "Diagnostics"
   84 |         case manager = "Manager"
   85 | 
   86 |         public var id: String { rawValue }
   87 | 
   88 |         public var accessibilityID: String {
   89 |             switch self {
   90 |             case .rig: return "rig"
```

## Completion evidence acceptance

`Sources/ForgeConductorCore/Application/ManagedProjectRunStepExecutor.swift:350-410`

```text
  350 |             }
  351 |             if let summary = Self.boundedAssistantSummary(turn.messages) {
  352 |                 work.metadata["provider_assistant_summary"] = summary
  353 |             }
  354 | 
  355 |             let afterAction = try await budget.observeProviderTurn(
  356 |                 turn,
  357 |                 run: run,
  358 |                 sessionID: sessionID,
  359 |                 capabilities: capabilities
  360 |             )
  361 |             strongestAction = Self.stronger(strongestAction, afterAction)
  362 | 
  363 |             guard !turn.toolCalls.isEmpty else {
  364 |                 if strongestAction == .rollover || strongestAction == .emergency {
  365 |                     return .rolloverRequired(work)
  366 |                 }
  367 |                 if strongestAction == .checkpoint { return .checkpointRequired(work) }
  368 |                 if let request = Self.completionRequest(from: turn.messages) {
  369 |                     let declaredGates = Set(run.specification.completionGates)
  370 |                     for (gate, proof) in request.gateEvidence
  371 |                     where declaredGates.contains(gate)
  372 |                         && work.evidenceReferences.contains(proof) {
  373 |                         work.metadata["completion_gate.\(gate).proof_sha256"] = proof
  374 |                     }
  375 |                     return .completionRequestedWithWork(request.summary, work)
  376 |                 }
  377 |                 work.nextAction = "Continue the mission from provider response \(turn.responseID)"
  378 |                 return .continued(work)
  379 |             }
  380 | 
  381 |             var outputs: [[String: Any]] = []
  382 |             outputs.reserveCapacity(turn.toolCalls.count)
  383 |             for call in turn.toolCalls {
  384 |                 let arguments = try Self.arguments(call.argumentsJSON)
  385 |                 let result = try await broker.invoke(
  386 |                     BrokeredToolCall(
  387 |                         providerCallID: call.callID,
  388 |                         toolName: call.name,
  389 |                         arguments: arguments,
  390 |                         idempotencyKey: "\(sessionID):\(call.callID)"
  391 |                     ),
  392 |                     turnID: record.intent.turnID,
  393 |                     context: providerContext,
  394 |                     lease: lease
  395 |                 )
  396 |                 let output = try JSONSupport.canonicalJSON(result.payload)
  397 |                 let evidenceSHA256 = JSONSupport.sha256Hex(output)
  398 |                 if !work.evidenceReferences.contains(evidenceSHA256) {
  399 |                     work.evidenceReferences.append(evidenceSHA256)
  400 |                 }
  401 |                 work.metadata[
  402 |                     "tool_evidence.\(call.name).\(call.callID)"
  403 |                 ] = evidenceSHA256
  404 |                 outputs.append([
  405 |                     "type": "function_call_output",
  406 |                     "call_id": call.callID,
  407 |                     "output": output,
  408 |                 ])
  409 |                 let toolAction = try await budget.observeToolResult(
  410 |                     serializedBytes: output.utf8.count,
```

## Weak production completion validator

`Sources/ForgeConductorCore/Application/ManagedAutonomyRuntime.swift:1-55`

```text
    1 | // Manager-only composition for durable autonomous scheduling and provider execution.
    2 | 
    3 | import Foundation
    4 | 
    5 | public struct ManagedAutonomyRuntimeSnapshot: Sendable, Equatable {
    6 |     public let started: Bool
    7 |     public let startupReport: AutonomyStartupReport?
    8 |     public let supervisor: AutonomySupervisorSnapshot
    9 | }
   10 | 
   11 | public enum ManagedAutonomyControlAction: String, Codable, Sendable, CaseIterable {
   12 |     case pause
   13 |     case resume
   14 |     case cancel
   15 |     case retry
   16 | }
   17 | 
   18 | public struct EvidenceBoundCompletionValidator: RunCompletionValidating, Sendable {
   19 |     private let clock: any Clock
   20 | 
   21 |     public init(clock: any Clock = SystemClock()) {
   22 |         self.clock = clock
   23 |     }
   24 | 
   25 |     public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
   26 |         guard run.state == .validatingCompletion else {
   27 |             throw AutonomyError.completionValidationRequired
   28 |         }
   29 |         let results = run.specification.completionGates.map { gate in
   30 |             let key = "completion_gate.\(gate).proof_sha256"
   31 |             let proof = run.specification.work.metadata[key]
   32 |             let passed = proof.map { value in
   33 |                 value.count == 64
   34 |                     && value.allSatisfy(\.isHexDigit)
   35 |                     && run.specification.work.evidenceReferences.contains(value)
   36 |             } ?? false
   37 |             return CompletionGateResult(
   38 |                 gate: gate,
   39 |                 passed: passed,
   40 |                 summary: passed
   41 |                     ? "Deterministic evidence reference is present"
   42 |                     : "No manager-verified evidence reference is registered for this gate",
   43 |                 evidenceReferences: proof.map { [$0] } ?? []
   44 |             )
   45 |         }
   46 |         return try CompletionValidationReceipt.make(
   47 |             runID: run.runID,
   48 |             expectedRevision: run.revision,
   49 |             results: results,
   50 |             validatedAt: ISO8601.string(from: clock.now())
   51 |         )
   52 |     }
   53 | }
   54 | 
   55 | public actor ManagedAutonomyRuntime {
```

## Stronger deterministic validator exists

`Sources/ForgeConductorCore/Application/ProjectRunCoordinator.swift:60-120`

```text
   60 |         self.operation = operation
   61 |     }
   62 | 
   63 |     public func evaluate(_ run: AutonomousRunRecord) async throws -> CompletionGateResult {
   64 |         try await operation(run)
   65 |     }
   66 | }
   67 | 
   68 | public struct DeterministicCompletionValidator: RunCompletionValidating, Sendable {
   69 |     private let validators: [String: CompletionGateValidator]
   70 |     private let clock: any Clock
   71 | 
   72 |     public init(
   73 |         validators: [CompletionGateValidator],
   74 |         clock: any Clock = SystemClock()
   75 |     ) throws {
   76 |         guard !validators.isEmpty, validators.count <= 256,
   77 |               Set(validators.map(\.gate)).count == validators.count else {
   78 |             throw AutonomyError.invalidRequest("completion validators must be unique and bounded")
   79 |         }
   80 |         self.validators = Dictionary(uniqueKeysWithValues: validators.map { ($0.gate, $0) })
   81 |         self.clock = clock
   82 |     }
   83 | 
   84 |     public func validate(_ run: AutonomousRunRecord) async throws -> CompletionValidationReceipt {
   85 |         guard run.state == .validatingCompletion else {
   86 |             throw AutonomyError.completionValidationRequired
   87 |         }
   88 |         var results: [CompletionGateResult] = []
   89 |         results.reserveCapacity(run.specification.completionGates.count)
   90 |         for gate in run.specification.completionGates {
   91 |             guard let validator = validators[gate] else {
   92 |                 results.append(CompletionGateResult(
   93 |                     gate: gate,
   94 |                     passed: false,
   95 |                     summary: "No deterministic validator is registered for this gate"
   96 |                 ))
   97 |                 continue
   98 |             }
   99 |             let result = try await validator.evaluate(run)
  100 |             guard result.gate == gate else {
  101 |                 throw AutonomyError.invalidRequest("completion validator returned the wrong gate identity")
  102 |             }
  103 |             guard result.summary.utf8.count <= 2_048,
  104 |                   result.evidenceReferences.count <= 256,
  105 |                   result.evidenceReferences.allSatisfy({ $0.utf8.count <= 2_048 }) else {
  106 |                 throw AutonomyError.invalidRequest("completion result exceeds its durable bound")
  107 |             }
  108 |             results.append(result)
  109 |         }
  110 |         return try CompletionValidationReceipt.make(
  111 |             runID: run.runID,
  112 |             expectedRevision: run.revision,
  113 |             results: results,
  114 |             validatedAt: ISO8601.string(from: clock.now())
  115 |         )
  116 |     }
  117 | }
  118 | 
  119 | public struct AutonomyRetryPolicy: Sendable, Equatable {
  120 |     public let maximumAttempts: Int
```

## Legacy router blocking

`Sources/ForgeConductorCore/Application/ToolRouter.swift:380-415`

```text
  380 |         case .denied(let code, let message):
  381 |             // A denied call cannot be normalized for dispatch. Its original arguments
  382 |             // are still safe to fingerprint and will be sanitized before audit storage.
  383 |             routedArguments = arguments
  384 |             authorizationDenial = (code, message)
  385 |         }
  386 | 
  387 |         // Continuity tools never count toward identical-call loops. Every other call
  388 |         // participates, including authorization denials, so policy failures cannot
  389 |         // evade the context-budget circuit breaker indefinitely.
  390 |         let isContinuity = ContinuityToolPack().toolNames.contains(name)
  391 |             || ContinuityLifecycleToolPack().toolNames.contains(name)
  392 |         let bypassesContinuityBlock = isContinuity
  393 |             || ContinuityAutomation.resumeTools.contains(name)
  394 |         var continuityBlocked = false
  395 |         if !bypassesContinuityBlock {
  396 |             do {
  397 |                 continuityBlocked = try app.continuityAutomation.isBlocked(
  398 |                     clientID,
  399 |                     cancellation: cancellation
  400 |                 )
  401 |             } catch is CancellationError {
  402 |                 recordCancellation(
  403 |                     tool: name,
  404 |                     arguments: routedArguments,
  405 |                     clientID: clientID,
  406 |                     start: start,
  407 |                     cancellation: cancellation
  408 |                 )
  409 |                 throw CancellationError()
  410 |             } catch is ToolCallDeadlineExceeded {
  411 |                 return deadlineFailure(
  412 |                     tool: name,
  413 |                     arguments: routedArguments,
  414 |                     clientID: clientID,
  415 |                     start: start,
```

## Legacy runtime handoff message

`Sources/ForgeConductorCore/Application/ToolRouter.swift:930-990`

```text
  930 |         "project_memory.update", "project_memory.forget", "project_memory.link",
  931 |         "project_memory.export", "project_memory.import",
  932 |     ]
  933 | 
  934 |     private func applyRuntimeContinuity(
  935 |         _ result: ToolResult,
  936 |         tool: String,
  937 |         arguments: [String: Any],
  938 |         clientID: ClientID,
  939 |         succeeded: Bool,
  940 |         cancellation: ToolCallCancellation?
  941 |     ) -> ToolResult {
  942 |         guard let observation = app.continuityAutomation.observe(
  943 |             tool: tool,
  944 |             arguments: arguments,
  945 |             clientID: clientID,
  946 |             succeeded: succeeded,
  947 |             cancellation: cancellation
  948 |         ) else {
  949 |             return result
  950 |         }
  951 |         var payload = result.payload
  952 |         payload["auto_continuity"] = observation.finalize ? "handoff" : "checkpoint"
  953 |         payload["auto_handoff_id"] = observation.packet.id
  954 |         if observation.finalize {
  955 |             payload["handoff_required"] = true
  956 |             payload["handoff_id"] = observation.packet.id
  957 |             payload["resume_seed"] = observation.packet.resumeSeed.isEmpty
  958 |                 ? observation.packet.defaultResumeSeed()
  959 |                 : observation.packet.resumeSeed
  960 |             payload["continuity_note"] =
  961 |                 "Context budget: Forge auto-saved handoff \(observation.packet.id). " +
  962 |                 "Further project tools are blocked on this client until context_get in a new chat."
  963 |         }
  964 |         return ToolResult(ok: result.ok, payload: payload, isError: result.isError)
  965 |     }
  966 | 
  967 |     private func contextBudgetBlockResult(
  968 |         clientID: ClientID,
  969 |         cancellation: ToolCallCancellation?
  970 |     ) throws -> ToolResult {
  971 |         let prior = try app.continuityAutomation.blockState(
  972 |             clientID,
  973 |             cancellation: cancellation
  974 |         )
  975 |         let payload: [String: Any] = [
  976 |             "ok": false,
  977 |             "code": "context_budget_exceeded",
  978 |             "message":
  979 |                 "This chat has been handed off. Start a new LM Studio chat with Forge MCP enabled, " +
  980 |                 "then call context_get. Further filesystem/shell/git tools are blocked here.",
  981 |             "retryable": false,
  982 |             "handoff_required": true,
  983 |             "handoff_id": prior.handoffID as Any,
  984 |             "resume_seed": prior.resumeSeed as Any,
  985 |         ]
  986 |         return ToolResult(ok: false, payload: payload, isError: true)
  987 |     }
  988 | 
  989 |     private static func errorSummary(_ result: ToolResult) -> String {
  990 |         if let message = result.payload["message"] as? String, !message.isEmpty {
```

## Global continuity fallback

`Sources/ForgeConductorCore/Application/ContinuityAutomation.swift:90-125`

```text
   90 |     ) throws -> [URL] {
   91 |         let implicit = try withStateLock(cancellation: cancellation) {
   92 |             state[clientID.rawValue]?.implicitRoots ?? []
   93 |         }
   94 | 
   95 |         var roots = implicit
   96 |         if let binding = try sessions.binding(for: clientID, cancellation: cancellation),
   97 |            let cwd = binding.cwd,
   98 |            !cwd.isEmpty {
   99 |             roots.append(ToolArgHelpers.resolvePath(cwd))
  100 |         }
  101 |         let clientPacket = try bestEffortHandoff(
  102 |             clientID: clientID.rawValue,
  103 |             cancellation: cancellation
  104 |         )
  105 |         let globalPacket = try bestEffortHandoff(
  106 |             clientID: nil,
  107 |             cancellation: cancellation
  108 |         )
  109 |         if let packet = clientPacket ?? globalPacket,
  110 |            let cwd = packet.cwd, !cwd.isEmpty {
  111 |             roots.append(ToolArgHelpers.resolvePath(cwd))
  112 |         }
  113 |         if let packet = globalPacket {
  114 |             for file in packet.keyFiles {
  115 |                 try cancellation?.checkCancellation()
  116 |                 let url = ToolArgHelpers.resolvePath(file)
  117 |                 var isDir: ObjCBool = false
  118 |                 if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
  119 |                     roots.append(isDir.boolValue ? url : url.deletingLastPathComponent())
  120 |                 }
  121 |             }
  122 |         }
  123 |         try cancellation?.checkCancellation()
  124 |         return uniqued(roots)
  125 |     }
```

## Project generation reset only

`Sources/ForgeConductorCore/Manager/ManagerNode.swift:410-450`

```text
  410 |                 "owner_id": owner.id,
  411 |             ],
  412 |             category: .manager
  413 |         )
  414 |         return Self.bindingDictionary(binding)
  415 |     }
  416 | 
  417 |     @discardableResult
  418 |     public func resetProjectGeneration(
  419 |         projectID: ProjectID,
  420 |         expectedGeneration: ProjectGeneration
  421 |     ) throws -> [String: Any] {
  422 |         _ = try app.projectContexts.beginReset(
  423 |             projectID: projectID,
  424 |             expectedGeneration: expectedGeneration
  425 |         )
  426 |         do {
  427 |             app.projectMemory.closeProject(projectID.description)
  428 |             let receipt = try app.projectContexts.completeReset(
  429 |                 projectID: projectID,
  430 |                 expectedGeneration: expectedGeneration
  431 |             )
  432 |             app.diagnostics.info(
  433 |                 "manager_project_generation_reset",
  434 |                 [
  435 |                     "project_id": projectID.description,
  436 |                     "prior_generation": "\(receipt.priorGeneration.rawValue)",
  437 |                     "new_generation": "\(receipt.newGeneration.rawValue)",
  438 |                     "invalidated_bindings": "\(receipt.invalidatedBindingCount)",
  439 |                 ],
  440 |                 category: .manager
  441 |             )
  442 |             return [
  443 |                 "ok": true,
  444 |                 "project_id": projectID.description,
  445 |                 "prior_generation": receipt.priorGeneration.rawValue,
  446 |                 "new_generation": receipt.newGeneration.rawValue,
  447 |                 "invalidated_binding_count": receipt.invalidatedBindingCount,
  448 |                 "completed_at": receipt.completedAt,
  449 |             ]
  450 |         } catch {
```

## Control-plane reset transaction

`Sources/ForgeConductorCore/Infrastructure/ProjectControlPlaneRepository.swift:500-585`

```text
  500 |                 resultSHA256: resultSHA256,
  501 |                 cancellation: cancellation
  502 |             )
  503 |             throw ProjectContextError.staleProjectGeneration(
  504 |                 expected: context.projectGeneration,
  505 |                 actual: actualGeneration
  506 |             )
  507 |         }
  508 |     }
  509 | 
  510 |     @discardableResult
  511 |     public func beginReset(
  512 |         projectID: ProjectID,
  513 |         expectedGeneration: ProjectGeneration,
  514 |         cancellation: ToolCallCancellation? = nil
  515 |     ) throws -> ProjectControlRecord {
  516 |         try cancellation?.checkCancellation()
  517 |         try Self.validate(expectedGeneration)
  518 |         let timestamp = ISO8601.string(from: clock.now())
  519 |         return try controlledTransaction(cancellation: cancellation) { connection in
  520 |             _ = try requiredActiveProjectUnlocked(
  521 |                 projectID,
  522 |                 generation: expectedGeneration,
  523 |                 connection: connection
  524 |             )
  525 |             let changed = try connection.execute(
  526 |                 """
  527 |                 UPDATE control_projects SET lifecycle_state='resetting',updated_at=?
  528 |                 WHERE project_id=? AND generation=? AND lifecycle_state='active'
  529 |                 """,
  530 |                 bindings: [
  531 |                     .text(timestamp), .text(projectID.description),
  532 |                     .int64(try Self.sqliteGeneration(expectedGeneration)),
  533 |                 ]
  534 |             )
  535 |             guard changed == 1,
  536 |                   let project = try projectUnlocked(projectID, connection: connection) else {
  537 |                 throw ProjectContextError.databaseFailure("project reset compare-and-set failed")
  538 |             }
  539 |             return project
  540 |         }
  541 |     }
  542 | 
  543 |     @discardableResult
  544 |     public func completeReset(
  545 |         projectID: ProjectID,
  546 |         expectedGeneration: ProjectGeneration,
  547 |         cancellation: ToolCallCancellation? = nil
  548 |     ) throws -> ProjectGenerationResetReceipt {
  549 |         try cancellation?.checkCancellation()
  550 |         try Self.validate(expectedGeneration)
  551 |         guard expectedGeneration.rawValue < UInt64(Int64.max) else {
  552 |             throw ProjectContextError.invalidGeneration(expectedGeneration.rawValue)
  553 |         }
  554 |         let timestamp = ISO8601.string(from: clock.now())
  555 |         return try controlledTransaction(cancellation: cancellation) { connection in
  556 |             guard let current = try projectUnlocked(projectID, connection: connection) else {
  557 |                 throw ProjectContextError.projectNotFound(projectID)
  558 |             }
  559 |             guard current.generation == expectedGeneration else {
  560 |                 throw ProjectContextError.staleProjectGeneration(
  561 |                     expected: expectedGeneration,
  562 |                     actual: current.generation
  563 |                 )
  564 |             }
  565 |             guard current.lifecycleState == .resetting else {
  566 |                 throw ProjectContextError.resetNotPrepared(projectID)
  567 |             }
  568 |             let invalidated = try connection.execute(
  569 |                 """
  570 |                 UPDATE project_bindings SET active=0,lease_owner=NULL,lease_expires_at=NULL,updated_at=?
  571 |                 WHERE project_id=? AND project_generation=? AND active=1
  572 |                 """,
  573 |                 bindings: [
  574 |                     .text(timestamp), .text(projectID.description),
  575 |                     .int64(try Self.sqliteGeneration(expectedGeneration)),
  576 |                 ]
  577 |             )
  578 |             let next = ProjectGeneration(expectedGeneration.rawValue + 1)
  579 |             let changed = try connection.execute(
  580 |                 """
  581 |                 UPDATE control_projects SET generation=?,lifecycle_state='active',updated_at=?
  582 |                 WHERE project_id=? AND generation=? AND lifecycle_state='resetting'
  583 |                 """,
  584 |                 bindings: [
  585 |                     .int64(try Self.sqliteGeneration(next)), .text(timestamp),
```

## Provider UI placeholders

`Sources/ForgeConductorApp/OperatorConsole/Views/ProviderOperatorView.swift:70-92`

```text
   70 | 
   71 |             GroupBox("Lifecycle and contract") {
   72 |                 VStack(alignment: .leading, spacing: 9) {
   73 |                     LabeledContent("Lifecycle management", value: OperatorFormat.yesNo(provider.lifecycleManagementEnabled))
   74 |                     LabeledContent("Idle TTL", value: provider.idleTTLSeconds.map { "\($0)s" } ?? "Unavailable")
   75 |                     LabeledContent("Contract fingerprint") { OperatorIdentifier(provider.contractFingerprint) }
   76 |                     LabeledContent("Last probe", value: provider.lastProbeAt ?? "Unavailable")
   77 |                     if let error = provider.lastProbeError {
   78 |                         Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
   79 |                     }
   80 |                 }
   81 |             }
   82 | 
   83 |             HStack {
   84 |                 Button("Test Connection") {}
   85 |                 Button("Run Contract Probe") {}
   86 |             }
   87 |             .disabled(true)
   88 |             Text("Probe commands are unavailable until the manager publishes an authoritative mutation route; the last persisted result is shown above.")
   89 |                 .font(.caption)
   90 |                 .foregroundStyle(.secondary)
   91 |         }
   92 |     }
```

## Disabled project/runtime/continuity controls

`Sources/ForgeConductorApp/OperatorConsole/Views/ProjectsOperatorView.swift:170-195`

```text
  170 |                         LabeledContent("Prior generation", value: "\(receipt.priorGeneration)")
  171 |                         LabeledContent("New generation", value: "\(receipt.newGeneration)")
  172 |                         LabeledContent("Fenced bindings", value: "\(receipt.invalidatedBindingCount)")
  173 |                         LabeledContent("Completed", value: receipt.completedAt ?? "Unavailable")
  174 |                     }
  175 |                     .frame(maxWidth: .infinity, alignment: .leading)
  176 |                 }
  177 |                 .accessibilityIdentifier("project-reset-receipt")
  178 |             }
  179 | 
  180 |             HStack {
  181 |                 Button("Relink…") {}
  182 |                     .disabled(true)
  183 |                     .help("The manager does not advertise a relink command in this build.")
  184 |                 Spacer()
  185 |                 Button("Reset Generation…", role: .destructive) {
  186 |                     showingResetConfirmation = true
  187 |                 }
  188 |                 .accessibilityIdentifier("project-reset")
  189 |             }
  190 |         }
  191 |     }
  192 | 
  193 |     private var registrationSheet: some View {
  194 |         VStack(alignment: .leading, spacing: 16) {
  195 |             Text("Register Project").font(.title2.bold())
```

## Disabled runtime cancel

`Sources/ForgeConductorApp/OperatorConsole/Views/RuntimesOperatorView.swift:125-145`

```text
  125 |                 LabeledContent("Runtime", value: job.runtimeKind)
  126 |                 LabeledContent("Project") { OperatorIdentifier(job.projectID) }
  127 |                 LabeledContent("Generation", value: "\(job.projectGeneration)")
  128 |                 LabeledContent("Run") { OperatorIdentifier(job.runID) }
  129 |                 LabeledContent("Working directory") { OperatorIdentifier(job.canonicalWorkingDirectory) }
  130 |                 LabeledContent("Command summary", value: job.commandSummary)
  131 |                 LabeledContent("Timeout", value: "\(job.timeoutSeconds)s")
  132 |                 LabeledContent("Exit", value: job.exitCode.map(String.init) ?? "Unavailable")
  133 |                 LabeledContent("Output bytes", value: OperatorFormat.bytes(job.outputBytes))
  134 |                 LabeledContent("Output artifact") { OperatorIdentifier(job.outputArtifactID) }
  135 |                 if let error = job.errorSummary {
  136 |                     Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
  137 |                 }
  138 |                 Button("Cancel Job", role: .destructive) {}
  139 |                     .disabled(true)
  140 |                     .help("The manager does not advertise a runtime-job cancel command in this build.")
  141 |                     .accessibilityIdentifier("runtime-job-cancel")
  142 |             }
  143 |         }
  144 |     }
  145 | 
```

## Disabled continuity controls

`Sources/ForgeConductorApp/OperatorConsole/Views/ContinuityOperatorView.swift:150-170`

```text
  150 |                                     Text(event.summary)
  151 |                                     Text("\(event.timestamp) · \(event.kind)")
  152 |                                         .font(.caption)
  153 |                                         .foregroundStyle(.secondary)
  154 |                                 }
  155 |                             }
  156 |                         }
  157 |                     }
  158 |                 }
  159 |             }
  160 | 
  161 |             HStack {
  162 |                 Button("Checkpoint Now") {}
  163 |                 Button("Request Early Rollover") {}
  164 |                     .accessibilityIdentifier("rollover-command")
  165 |                 Spacer()
  166 |             }
  167 |             .disabled(true)
  168 |             Text("Administrative checkpoint and rollover commands are unavailable until the manager publishes authoritative mutation routes. Display state remains read-only.")
  169 |                 .font(.caption)
  170 |                 .foregroundStyle(.secondary)
```

## Telemetry duplicate history and copies

`Sources/ForgeConductorCore/Telemetry/TelemetryService.swift:175-245`

```text
  175 |     }
  176 | 
  177 |     // MARK: - Live stream core
  178 | 
  179 |     private func onSystemSample(_ system: SystemMetrics) {
  180 |         runtimeDiagnostics.increment(.telemetryEventsProduced)
  181 |         lock.lock()
  182 |         presentationSequence &+= 1
  183 |         let sequence = presentationSequence
  184 |         let forge = lastForge ?? ForgeSnapshot.empty(home: paths.home.path)
  185 |         let point = HistoryPoint(
  186 |             ts: system.ts,
  187 |             cpu: system.cpu.percent,
  188 |             ram: system.ram.percent,
  189 |             gpu: system.gpu.first?.utilGPU,
  190 |             diskIO: system.diskIO.totalMBs,
  191 |             mcp: forge.mcpServers.count,
  192 |             orch: forge.orchestration.health
  193 |         )
  194 |         history.append(point)
  195 |         let historyMax = resourcePolicy.limits(for: pressureLevel).telemetryHistoryPoints
  196 |         if history.count > historyMax { history.removeFirst(history.count - historyMax) }
  197 |         let hist = Array(history.suffix(300))
  198 |         let frame = TelemetrySnapshot(
  199 |             system: system,
  200 |             forge: forge,
  201 |             updated: system.ts,
  202 |             history: hist,
  203 |             runtime: Self.runtimeIdentifier
  204 |         )
  205 |         liveFrame = frame
  206 |         let cbs = Array(listeners.values)
  207 |         let historyCount = history.count
  208 |         lock.unlock()
  209 |         let signpost = RuntimeSignposts.beginTelemetryPresentation(sequence: sequence)
  210 |         runtimeDiagnostics.increment(.telemetrySnapshotsPublished)
  211 |         runtimeDiagnostics.set(.telemetryHistorySize, to: historyCount)
  212 |         for cb in cbs { cb(frame) }
  213 |         RuntimeSignposts.endTelemetryPresentation(signpost, sequence: sequence)
  214 |     }
  215 | 
  216 |     private func recomposeForgeAndPublish() {
  217 |         let forge = forgeCollector.collect()
  218 |         let system = realtimeEngine.latestSystem
  219 |         lock.lock()
  220 |         presentationSequence &+= 1
  221 |         let sequence = presentationSequence
  222 |         lastForge = forge
  223 |         history.append(
  224 |             HistoryPoint(
  225 |                 ts: system.ts,
  226 |                 cpu: system.cpu.percent,
  227 |                 ram: system.ram.percent,
  228 |                 gpu: system.gpu.first?.utilGPU,
  229 |                 diskIO: system.diskIO.totalMBs,
  230 |                 mcp: forge.mcpServers.count,
  231 |                 orch: forge.orchestration.health
  232 |             )
  233 |         )
  234 |         let historyMax = resourcePolicy.limits(for: pressureLevel).telemetryHistoryPoints
  235 |         if history.count > historyMax { history.removeFirst(history.count - historyMax) }
  236 |         let hist = Array(history.suffix(300))
  237 |         let frame = TelemetrySnapshot(
  238 |             system: system,
  239 |             forge: forge,
  240 |             updated: system.ts,
  241 |             history: hist,
  242 |             runtime: Self.runtimeIdentifier
  243 |         )
  244 |         liveFrame = frame
  245 |         let cbs = Array(listeners.values)
```

## Gauge surface telemetry

`Sources/ForgeConductorApp/Metal/MetalGaugeResources.swift:110-145`

```text
  110 |         buffer = replacement
  111 |         capacityBytes = capacity
  112 |         RuntimeDiagnostics.shared.increment(.gaugeBuffersCreated)
  113 |         RuntimeDiagnostics.shared.recordMaximum(.gaugeBufferCapacityBytes, candidate: capacity)
  114 |     }
  115 | }
  116 | 
  117 | @MainActor
  118 | final class GaugeSurfaceLifetime {
  119 |     private var attached = false
  120 | 
  121 |     func attach() {
  122 |         guard !attached else { return }
  123 |         attached = true
  124 |         RuntimeDiagnostics.shared.adjust(.gaugeActiveSurfaces, by: 1)
  125 |         RuntimeDiagnostics.shared.adjust(.gaugeVisibleSurfaces, by: 1)
  126 |     }
  127 | 
  128 |     func detach() {
  129 |         guard attached else { return }
  130 |         attached = false
  131 |         RuntimeDiagnostics.shared.adjust(.gaugeActiveSurfaces, by: -1)
  132 |         RuntimeDiagnostics.shared.adjust(.gaugeVisibleSurfaces, by: -1)
  133 |     }
  134 | 
  135 |     deinit {
  136 |         if attached {
  137 |             RuntimeDiagnostics.shared.adjust(.gaugeActiveSurfaces, by: -1)
  138 |             RuntimeDiagnostics.shared.adjust(.gaugeVisibleSurfaces, by: -1)
  139 |         }
  140 |     }
  141 | }
```

## Dashboard connection lifecycle

`Sources/ForgeConductorCore/Dashboard/DashboardServer.swift:96-212`

```text
   96 |         let params = NWParameters.tcp
   97 |         // Do NOT reuse address for product dashboard — second instance must fail clearly.
   98 |         params.allowLocalEndpointReuse = false
   99 |         if host == "127.0.0.1" || host == "localhost" {
  100 |             params.requiredInterfaceType = .loopback
  101 |         }
  102 | 
  103 |         let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
  104 |         let gate = DispatchSemaphore(value: 0)
  105 |         let bindResult = DashboardBindResult()
  106 |         listener.newConnectionHandler = { [weak self] conn in
  107 |             self?.handle(connection: conn)
  108 |         }
  109 |         listener.stateUpdateHandler = { [weak self] state in
  110 |             switch state {
  111 |             case .ready:
  112 |                 self?.app.diagnostics.info("dashboard_ready", [
  113 |                     "url": self?.baseURL.absoluteString ?? "",
  114 |                     "pid": "\(ProcessInfo.processInfo.processIdentifier)",
  115 |                 ], category: .manager)
  116 |                 gate.signal()
  117 |             case .failed(let err):
  118 |                 self?.app.diagnostics.error("dashboard_failed", [
  119 |                     "error": "\(err)",
  120 |                     "port": "\(self?.port ?? 0)",
  121 |                 ], category: .manager)
  122 |                 bindResult.record(error: err)
  123 |                 gate.signal()
  124 |             case .cancelled:
  125 |                 break
  126 |             default:
  127 |                 break
  128 |             }
  129 |         }
  130 |         listener.start(queue: queue)
  131 |         let wait = gate.wait(timeout: .now() + 3)
  132 |         if wait == .timedOut {
  133 |             listener.cancel()
  134 |             app.diagnostics.error("dashboard_bind_timeout", ["port": "\(port)"], category: .manager)
  135 |             throw DashboardError.bindTimeout(port)
  136 |         }
  137 |         if let bindError = bindResult.recordedError() {
  138 |             listener.cancel()
  139 |             throw bindError
  140 |         }
  141 | 
  142 |         lock.lock()
  143 |         self.listener = listener
  144 |         isRunning = true
  145 |         lock.unlock()
  146 |     }
  147 | 
  148 |     public func stop() {
  149 |         lock.lock()
  150 |         defer { lock.unlock() }
  151 |         listener?.cancel()
  152 |         listener = nil
  153 |         isRunning = false
  154 |     }
  155 | 
  156 |     /// Run until interrupted (SIGINT/SIGTERM).
  157 |     public func runForever() throws {
  158 |         try start()
  159 |         fputs("Forge-Conductor dashboard: \(baseURL.absoluteString)\n", stderr)
  160 |         let sem = DispatchSemaphore(value: 0)
  161 |         let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
  162 |         let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
  163 |         signal(SIGINT, SIG_IGN)
  164 |         signal(SIGTERM, SIG_IGN)
  165 |         sigInt.setEventHandler { sem.signal() }
  166 |         sigTerm.setEventHandler { sem.signal() }
  167 |         sigInt.resume()
  168 |         sigTerm.resume()
  169 |         defer {
  170 |             sigInt.setEventHandler {}
  171 |             sigTerm.setEventHandler {}
  172 |             sigInt.cancel()
  173 |             sigTerm.cancel()
  174 |             stop()
  175 |         }
  176 |         sem.wait()
  177 |     }
  178 | 
  179 |     // MARK: - Connection
  180 | 
  181 |     private func handle(connection: NWConnection) {
  182 |         connection.start(queue: queue)
  183 |         receive(on: connection, buffer: Data())
  184 |     }
  185 | 
  186 |     private func receive(on connection: NWConnection, buffer: Data) {
  187 |         connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
  188 |             guard let self else {
  189 |                 connection.cancel()
  190 |                 return
  191 |             }
  192 |             if let error {
  193 |                 self.app.diagnostics.warn("dashboard_recv_error", ["error": "\(error)"])
  194 |                 connection.cancel()
  195 |                 return
  196 |             }
  197 |             var buf = buffer
  198 |             if let data { buf.append(data) }
  199 |             switch DashboardHTTPRequestParser.parse(buf, streamComplete: isComplete) {
  200 |             case .incomplete:
  201 |                 self.receive(on: connection, buffer: buf)
  202 |             case .rejected(let status, let message):
  203 |                 self.http.respond(connection, status: status, body: message, contentType: "text/plain")
  204 |             case .request(let request):
  205 |                 if let rejection = DashboardRequestPolicy.rejection(for: request, serverPort: self.port) {
  206 |                     self.http.respond(
  207 |                         connection,
  208 |                         status: rejection.status,
  209 |                         body: rejection.message,
  210 |                         contentType: "text/plain"
  211 |                     )
  212 |                     return
```

## Read endpoints exempt from auth

`Sources/ForgeConductorCore/Dashboard/ManagerRoutes.swift:180-220`

```text
  180 | }
  181 | 
  182 | /// Validates a bearer header without data-dependent comparison exits. The
  183 | /// fixed upper bound also prevents attacker-controlled header work expansion.
  184 | public struct ManagerMutationAuthorizer: Sendable {
  185 |     public static let maximumAuthorizationHeaderBytes = 512
  186 |     private let credentials: any ManagerMutationCredentialProviding
  187 | 
  188 |     public init(credentials: any ManagerMutationCredentialProviding) {
  189 |         self.credentials = credentials
  190 |     }
  191 | 
  192 |     public func authorizes(_ authorizationHeader: String?) -> Bool {
  193 |         guard let authorizationHeader,
  194 |               authorizationHeader.utf8.count <= Self.maximumAuthorizationHeaderBytes,
  195 |               let token = try? credentials.bearerToken() else {
  196 |             return false
  197 |         }
  198 |         let supplied = Array(authorizationHeader.utf8)
  199 |         let expected = Array("Bearer \(token)".utf8)
  200 |         var difference = supplied.count ^ expected.count
  201 |         for index in 0..<Self.maximumAuthorizationHeaderBytes {
  202 |             let lhs = index < supplied.count ? supplied[index] : 0
  203 |             let rhs = index < expected.count ? expected[index] : 0
  204 |             difference |= Int(lhs ^ rhs)
  205 |         }
  206 |         return difference == 0
  207 |     }
  208 | 
  209 |     public static func requiresAuthorization(method: String, path: String) -> Bool {
  210 |         switch (method.uppercased(), path) {
  211 |         case ("GET", "/api/manager/status"),
  212 |              ("GET", "/api/manager/settings"),
  213 |              ("GET", "/api/manager/operator/snapshot"),
  214 |              ("GET", "/api/manager/autonomy/status"),
  215 |              ("POST", "/api/manager/projects/status"),
  216 |              ("POST", "/api/manager/runs/status"):
  217 |             return false
  218 |         default:
  219 |             return true
  220 |         }
```

## Shell defaults enabled

`Sources/ForgeConductorCore/Domain/AppConfig.swift:20-55`

```text
   20 |     public var manager: ManagerConfigSection
   21 |     public var mcp: MCPConfig
   22 |     public var sessions: SessionsConfig
   23 |     public var coordinator: CoordinatorConfig
   24 | 
   25 |     public struct ShellConfig: Sendable, Equatable, Codable {
   26 |         public var enabled: Bool
   27 |         public var userDisabled: Bool
   28 |         public var policyVersion: Int
   29 |         public var policyOrigin: String
   30 |         public var defaultTimeoutSec: Int
   31 | 
   32 |         public init(
   33 |             enabled: Bool = true,
   34 |             userDisabled: Bool = false,
   35 |             policyVersion: Int = AppConfig.currentSchemaVersion,
   36 |             policyOrigin: String = "default_enabled",
   37 |             defaultTimeoutSec: Int = 30
   38 |         ) {
   39 |             self.enabled = enabled
   40 |             self.userDisabled = userDisabled
   41 |             self.policyVersion = policyVersion
   42 |             self.policyOrigin = policyOrigin
   43 |             self.defaultTimeoutSec = defaultTimeoutSec
   44 |         }
   45 | 
   46 |         enum CodingKeys: String, CodingKey {
   47 |             case enabled
   48 |             case userDisabled = "user_disabled"
   49 |             case policyVersion = "policy_version"
   50 |             case policyOrigin = "policy_origin"
   51 |             case defaultTimeoutSec = "default_timeout_sec"
   52 |         }
   53 |     }
   54 | 
   55 |     public struct DashboardConfig: Sendable, Equatable, Codable {
```

## Legacy shell compatibility

`Sources/ForgeConductorCore/Application/Tools/ShellToolPack.swift:1-65`

```text
    1 | // ShellToolPack.swift
    2 | // What: Implements the explicitly granted shell-execution capability.
    3 | // How: It requires an active authorized workspace, applies timeout/output limits,
    4 | // and delegates process mechanics to ProcessRunner before returning structured status.
    5 | // Why: The most powerful tool needs a narrow, independently reviewable boundary.
    6 | 
    7 | import Foundation
    8 | 
    9 | /// Shell tool pack: shell_exec.
   10 | public struct ShellToolPack: ToolPackHandling {
   11 |     public static let maximumTimeoutSec: TimeInterval = 120
   12 |     private let runner = ProcessRunner()
   13 | 
   14 |     public init() {}
   15 | 
   16 |     public var toolNames: [String] { ["shell_exec"] }
   17 | 
   18 |     public func handle(
   19 |         name: String,
   20 |         arguments: [String: Any],
   21 |         context: ToolInvocationContext?,
   22 |         clientID: ClientID,
   23 |         app: ForgeApp,
   24 |         cancellation: ToolCallCancellation?
   25 |     ) throws -> ToolResult? {
   26 |         guard name == "shell_exec" else { return nil }
   27 |         try cancellation?.checkCancellation()
   28 |         guard let command = ToolArgHelpers.string(arguments, "command"), !command.isEmpty else {
   29 |             return .failure(code: "missing_command", message: "command required")
   30 |         }
   31 |         let cwd = ToolArgHelpers.string(arguments, "cwd")
   32 |         let requestedTimeout = (arguments["timeout_sec"] as? NSNumber)?.doubleValue
   33 |             ?? Double(app.config.int("shell", "default_timeout_sec", default: 30))
   34 |         guard requestedTimeout.isFinite, requestedTimeout > 0 else {
   35 |             return .failure(
   36 |                 code: "invalid_timeout",
   37 |                 message: "timeout_sec must be finite and positive",
   38 |                 retryable: false
   39 |             )
   40 |         }
   41 |         let timeout = min(requestedTimeout, Self.maximumTimeoutSec)
   42 |         let result = try runner.run(
   43 |             executable: "/bin/bash",
   44 |             arguments: ["-lc", command],
   45 |             currentDirectory: cwd,
   46 |             timeoutSec: timeout,
   47 |             maximumOutputBytes: 100_000,
   48 |             cancellation: cancellation
   49 |         )
   50 |         let ok = result.exitCode == 0 && !result.timedOut
   51 |         return ToolResult(
   52 |             ok: ok,
   53 |             payload: [
   54 |                 "ok": ok,
   55 |                 "exit_code": result.exitCode,
   56 |                 "stdout": String(result.stdout.prefix(80_000)),
   57 |                 "stderr": String(result.stderr.prefix(20_000)),
   58 |                 "timed_out": result.timedOut,
   59 |                 "stdout_truncated": result.stdoutTruncated,
   60 |                 "stderr_truncated": result.stderrTruncated,
   61 |                 "command": command,
   62 |                 "cwd": cwd as Any,
   63 |             ],
   64 |             isError: !ok
   65 |         )
```

## Runtime profiles

`Sources/ForgeConductorCore/Application/ExecutionJobService.swift:2145-2200`

```text
 2145 |         )
 2146 |         environment["FORGE_RUNTIME_LIMIT_CORE_BYTES"] = String(
 2147 |             limits.maximumCoreBytesPerProcess
 2148 |         )
 2149 |         let executable: URL
 2150 |         let arguments: [String]
 2151 |         let requestArtifact: String?
 2152 |         switch request.profile {
 2153 |         case .directProcess:
 2154 |             guard let requested = request.executable else {
 2155 |                 throw RuntimeJobError.invalidRequest("process.run requires an executable")
 2156 |             }
 2157 |             executable = try Self.executableURL(requested)
 2158 |             arguments = request.arguments
 2159 |             requestArtifact = nil
 2160 |         case .zshNoProfile:
 2161 |             executable = try requiredCapabilityURL(discoveredCapabilities.zsh, name: "zsh")
 2162 |             let script = try Self.requiredScript(request)
 2163 |             requestArtifact = try stageScript(script, extension: "zsh", spool: spool)
 2164 |             arguments = ["-f", artifactRoot.appendingPathComponent(requestArtifact!).path]
 2165 |         case .bashNoProfile:
 2166 |             executable = try requiredCapabilityURL(discoveredCapabilities.bash, name: "bash")
 2167 |             let script = try Self.requiredScript(request)
 2168 |             requestArtifact = try stageScript(script, extension: "bash", spool: spool)
 2169 |             arguments = ["--noprofile", "--norc", artifactRoot.appendingPathComponent(requestArtifact!).path]
 2170 |         case .legacyBashLogin:
 2171 |             executable = try requiredCapabilityURL(discoveredCapabilities.bash, name: "bash")
 2172 |             let script = try Self.requiredScript(request)
 2173 |             requestArtifact = try stageScript(script, extension: "legacy-bash", spool: spool)
 2174 |             arguments = ["-lc", script]
 2175 |         case .pythonIsolated:
 2176 |             executable = try requiredCapabilityURL(discoveredCapabilities.python, name: "python3")
 2177 |             let script = try Self.requiredScript(request)
 2178 |             requestArtifact = try stageScript(script, extension: "py", spool: spool)
 2179 |             arguments = ["-I", "-B", artifactRoot.appendingPathComponent(requestArtifact!).path]
 2180 |         case .powershellNoProfile:
 2181 |             executable = try requiredCapabilityURL(discoveredCapabilities.powershell, name: "pwsh")
 2182 |             let script = try Self.requiredScript(request)
 2183 |             requestArtifact = try stageScript(script, extension: "ps1", spool: spool)
 2184 |             arguments = [
 2185 |                 "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
 2186 |                 artifactRoot.appendingPathComponent(requestArtifact!).path,
 2187 |             ]
 2188 |         }
 2189 |         let summary = "\(request.profile.rawValue):\(executable.lastPathComponent):argv=\(arguments.count):script_bytes=\(request.script?.utf8.count ?? 0)"
 2190 |         let sandboxedPlan = try RuntimeProcessSandbox.plan(
 2191 |             executable: executable,
 2192 |             arguments: arguments,
 2193 |             workingDirectory: canonicalWorkingDirectory,
 2194 |             environment: environment,
 2195 |             canonicalReadRoots: request.context.authorizationScope.canonicalRoots,
 2196 |             canonicalWritableRoots: request.context.authorizationScope.writableRoots,
 2197 |             managerReadDirectory: spool.canonicalDirectory,
 2198 |             scratchDirectory: spool.canonicalScratchDirectory,
 2199 |             networkAllowed: request.context.authorizationScope.networkAllowed
 2200 |         )
```

## Resource pressure policy definitions

`Sources/ForgeConductorCore/Infrastructure/ResourcePolicy.swift:25-70`

```text
   25 |     public let telemetryHistoryPoints: Int
   26 |     public let diagnosticRingRecords: Int
   27 |     public let processOutputBytesPerStream: Int
   28 |     public let logFileBytes: UInt64
   29 |     public let retainedLogArchives: Int
   30 |     public let activeModelStreamBytes: Int
   31 |     public let decodedMemoryCacheBytes: Int
   32 |     public let searchCacheBytes: Int
   33 |     public let memorySearchDefaultLimit: Int
   34 |     public let memorySearchHardLimit: Int
   35 |     public let mcpResponseBytes: Int
   36 |     public let activeGaugeFPS: Int
   37 | }
   38 | 
   39 | /// Bounded provider-model defaults for one physical-memory tier. These values are
   40 | /// ceilings, not scheduling targets; provider capacity and model-size estimates may
   41 | /// lower them further at admission time.
   42 | public struct ResourceModelPolicy: Sendable, Codable, Equatable {
   43 |     public let defaultLoadedInstances: Int
   44 |     public let maximumLoadedInstances: Int
   45 |     public let maximumParallelRequests: Int
   46 |     public let idleTTLSeconds: Int
   47 |     public let jitLoadingRequired: Bool
   48 |     public let autoEvictRequired: Bool
   49 |     public let serializeSuccessorCreation: Bool
   50 | }
   51 | 
   52 | /// Manager/runtime/event limits that must be resolved from the same memory tier.
   53 | /// Keeping these together prevents each long-lived owner from independently assuming
   54 | /// that it can consume the machine's entire scheduling and retention budget.
   55 | public struct ResourceExecutionLimits: Sendable, Codable, Equatable {
   56 |     public let maximumActiveManagedGenerations: Int
   57 |     public let maximumActiveRuntimeJobs: Int
   58 |     public let maximumCPUHeavyRuntimeJobs: Int
   59 |     public let maximumInMemoryEvents: Int
   60 |     public let modelPolicy: ResourceModelPolicy
   61 | }
   62 | 
   63 | public struct ResourcePolicy: Sendable, Equatable {
   64 |     public static let gibibyte: UInt64 = 1_073_741_824
   65 |     public static var current: ResourcePolicy {
   66 |         ResourcePolicy(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
   67 |     }
   68 | 
   69 |     public let tier: ResourceMemoryTier
   70 |     public let nominalLimits: ResourceLimits
```

## Manual continuity documentation

`USER-GUIDE.md:127-180`

```text
  127 | nor shell compatibility is release-qualified.
  128 | 
  129 | ---
  130 | 
  131 | ## 5. Daily use with LM Studio
  132 | 
  133 | 1. Open Forge Conductor (dashboard) if you want live telemetry. Default: `http://127.0.0.1:7788/`.
  134 | 2. Open LM Studio. Load a model. Enable the **Forge-Conductor** preset if you use one.
  135 | 3. In the chat, enable MCP servers **forge-conductor** and **forge-conductor-fallback**.
  136 | 4. Start a **new** chat for a new work block. Do not keep an already-handed-off chat alive for more project tools.
  137 | 5. First useful model calls (the preset asks for these; Forge also survives if they are skipped):
  138 |    - `forge_status`
  139 |    - `context_get`
  140 |    - `memory_search` / `memory_list` as needed
  141 | 6. Work. Prefer `agent_run_start` with an explicit `cwd` for write work and any locally enabled shell work. Read-only listing of folders under your home is allowed without a session (not `Library`, `.ssh`, and similar).
  142 | 7. When Forge hands off, **start a new chat** and call `context_get`. Read `~/.forge-conductor/memory/NEXT-CHAT.md` if the model is confused.
  143 | 
  144 | LM Studio only starts the `serve` processes when a chat has those MCP servers selected. Idle “MCP not running” on the dashboard with no chat open is expected.
  145 | 
  146 | ---
  147 | 
  148 | ## 6. Continuity (packet automation and current boundary)
  149 | 
  150 | The checkpoint and handoff behavior below is implemented. The current release
  151 | candidate has not yet proven autonomous session succession through a
  152 | manager-owned, threshold-forced real-provider rollover. Until that test also
  153 | proves exact successor acknowledgment, predecessor fencing, idempotent sealing,
  154 | automatic continuation, GUI-closed operation, and crash-state recovery, use the
  155 | new-chat recipe as the operational path rather than treating autonomous
  156 | continuity as qualified.
  157 | 
  158 | ### 6.1 What the model can still call
  159 | 
  160 | | Tool | Effect |
  161 | |------|--------|
  162 | | `session_checkpoint` | Soft-save packet; work may continue |
  163 | | `session_handoff` | Finalize; mark resume-ready; return `resume_seed` |
  164 | | `context_get` | Load latest (or a given id) packet; adopt workspace; **clear a context-budget block** on this client |
  165 | | `context_list` | List recent packets |
  166 | 
  167 | ### 6.2 What Forge does without being asked
  168 | 
  169 | Progress tools are: `fs_*`, `shell_exec`, `git_*`, `memory_set`, `search_text`, `pdf_*`, `agent_run_start`, `agent_run_complete`.
  170 | 
  171 | | When | What happens |
  172 | |------|----------------|
  173 | | Every **5** progress tools, or **3 minutes** | Auto-checkpoint. Existing goal, next actions, and narrative on the packet are **kept**. |
  174 | | `agent_run_start` / `agent_run_complete` | Checkpoint immediately. |
  175 | | Every **20** progress tools, or **12 minutes** | Auto-handoff: packet `resume_ready`, `memory/NEXT-CHAT.md`, `handoff_required` on the tool result. |
  176 | | After that handoff, or after **9** identical tool calls | Further `fs_*` / `shell_exec` / `git_*` on **that MCP client** return `context_budget_exceeded`. The write is not executed. |
  177 | | New LM Studio chat | New `serve` process, new client id. The in-memory block from the old process is gone. Call `context_get` so the model loads the packet. |
  178 | 
  179 | Identical-call budget (separate from the 20-tool rule):
  180 | 
```
