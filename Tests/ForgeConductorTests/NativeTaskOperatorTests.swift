import Darwin
import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class NativeTaskOperatorTests: XCTestCase, @unchecked Sendable {
    func testClosedApprovalAndRequestParsersRejectAuthorityExtensionsAndRoundedIntegers() throws {
        let input = try OperatorFixture.approval()
        var invalid = input.asDictionary()
        for (key, value) in [("allowed_tools", ["fs_read", "shell_run"] as Any), ("network_allowed", true as Any),
                             ("filesystem_access", "read_write" as Any), ("source_limits", NSNull() as Any)] {
            invalid = input.asDictionary(); invalid[key] = value
            XCTAssertThrowsError(try NativeContinuityTaskApproval(arguments: invalid))
        }
        invalid = input.asDictionary(); invalid["unknown"] = true
        XCTAssertThrowsError(try NativeContinuityTaskApproval(arguments: invalid))
        let request = try OperatorFixture.request()
        XCTAssertEqual(try NativeContinuityTaskPreparationRequest(data: request.canonicalRequestJSON), request)
        let text = String(decoding: request.canonicalRequestJSON, as: UTF8.self)
        let rounded = text.replacingOccurrences(of: "\"project_generation\":1", with: "\"project_generation\":9007199254740993.1")
        XCTAssertThrowsError(try NativeContinuityTaskPreparationRequest(data: Data(rounded.utf8)))
        let duplicate = "{\"schema_version\":1," + String(text.dropFirst())
        XCTAssertThrowsError(try NativeContinuityTaskPreparationRequest(data: Data(duplicate.utf8)))
        XCTAssertThrowsError(try NativeContinuityTaskPreparationRequest(data: Data(repeating: 32, count: NativeContinuityTaskPreparationRequest.maximumBodyBytes + 1)))
        var object = try request.asDictionary(); object["expires_at"] = "2026-09-08T12:00:00.000Z"
        XCTAssertThrowsError(try NativeContinuityTaskPreparationRequest(arguments: object))
    }

    func testExactPendingCommandSurvivesReopenAndRevocationRemovesBothSecrets() async throws {
        let home = try OperatorFixture.home(); defer { try? FileManager.default.removeItem(at: home) }
        let endpoint = OperatorFixture.endpoint, transport = OperatorReceiptTransport()
        let store = NativeTaskCredentialFileStore(paths: AppPaths(home: home))
        let client = try NativeTaskOperatorClient(store: store, transport: transport, endpoint: endpoint)
        await transport.loseNextResponse()
        let pending: NativeTaskCredentialSnapshot
        do { _ = try await client.prepare(OperatorFixture.input()); return XCTFail("Lost response must remain pending") }
        catch let error as NativeTaskOperatorPendingCommand { pending = error.snapshot }
        XCTAssertEqual(pending.localState, "prepare_pending")
        XCTAssertThrowsError(try store.credential(taskID: pending.taskID, managerEndpoint: endpoint))
        let firstRequest = try store.pending(taskID: pending.taskID, endpoint: endpoint)
        let pendingFile = try JSONSupport.object(from: Data(contentsOf: store.fileURL(taskID: pending.taskID)))
        let pendingNamespace = try XCTUnwrap(pendingFile["sourceSessionID"] as? String)
        let reopenedStore = NativeTaskCredentialFileStore(paths: AppPaths(home: home))
        let reopened = try NativeTaskOperatorClient(store: reopenedStore, transport: transport, endpoint: endpoint)
        let active = try await reopened.reconcile(taskID: pending.taskID)
        XCTAssertEqual(active.localState, "active")
        XCTAssertEqual(active.result?.replayed, true)
        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], firstRequest.data)
        XCTAssertEqual(calls[0], calls[1])
        let old = try reopenedStore.credential(taskID: active.taskID, managerEndpoint: endpoint)
        let originalAttachment = try reopenedStore.attachment(taskID: active.taskID, managerEndpoint: endpoint)
        XCTAssertEqual(originalAttachment.sourceSessionID.uuidString.lowercased(), pendingNamespace)
        let oldSecret = old.authorizationValue
        XCTAssertFalse(String(decoding: try ForgeJSONCanonicalizationV1.data(from: active.wireObject), as: UTF8.self).contains(oldSecret))
        await transport.loseNextResponse()
        do { _ = try await reopened.rotate(taskID: active.taskID, expectedEpoch: 1, expiresAt: OperatorFixture.expiry); XCTFail("Lost rotation must remain pending") }
        catch let error as NativeTaskOperatorPendingCommand { XCTAssertEqual(error.snapshot.localState, "rotate_pending") }
        XCTAssertThrowsError(try reopenedStore.credential(taskID: active.taskID, managerEndpoint: endpoint), "Pending rotation pauses new native attachment")
        let staged = try Data(contentsOf: reopenedStore.fileURL(taskID: active.taskID))
        XCTAssertTrue(String(decoding: staged, as: UTF8.self).contains(oldSecret), "Old secret survives only while exact rotation is unresolved")
        let rotated = try await reopened.reconcile(taskID: active.taskID)
        XCTAssertEqual(rotated.result?.current.epoch, 2)
        let newSecret = try reopenedStore.credential(taskID: active.taskID, managerEndpoint: endpoint).authorizationValue
        XCTAssertEqual(try reopenedStore.attachment(taskID: active.taskID, managerEndpoint: endpoint).sourceSessionID,
            originalAttachment.sourceSessionID, "Credential rotation must not invent a new source request namespace")
        XCTAssertNotEqual(oldSecret, newSecret)
        XCTAssertFalse(String(decoding: try Data(contentsOf: reopenedStore.fileURL(taskID: active.taskID)), as: UTF8.self).contains(oldSecret))
        let revoked = try await reopened.revoke(taskID: active.taskID, expectedEpoch: 2, reason: "Operator finished the task")
        XCTAssertEqual(revoked.localState, "revoked")
        let tombstone = String(decoding: try Data(contentsOf: reopenedStore.fileURL(taskID: active.taskID)), as: UTF8.self)
        XCTAssertFalse(tombstone.contains(oldSecret)); XCTAssertFalse(tombstone.contains(newSecret))
        XCTAssertFalse(tombstone.contains("fc-task-v1:"))
        XCTAssertThrowsError(try reopenedStore.credential(taskID: active.taskID, managerEndpoint: endpoint))
        do { _ = try await reopened.rotate(taskID: active.taskID, expectedEpoch: 3, expiresAt: OperatorFixture.expiry); XCTFail("Revoked capability rotated") }
        catch { XCTAssertEqual(error as? NativeTaskOperatorError, .credentialConflict) }
    }

    func testHistoricalReplayNeverPublishesSupersededCandidate() throws {
        let home = try OperatorFixture.home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = NativeTaskCredentialFileStore(paths: AppPaths(home: home)), endpoint = OperatorFixture.endpoint
        let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 7, count: 32))
        let request = try OperatorFixture.request(capabilityID: credential.capabilityID, verifier: credential.verifier.sha256)
        let command = NativeTaskOperatorCommand.prepare(request)
        _ = try store.stage(command, candidate: credential, endpoint: endpoint)
        let original = try OperatorFixture.result(command)
        var newer = original.current.wireObject; newer["epoch"] = 2
        let result = NativeTaskCapabilityCommandResult(receipt: original.receipt,
            current: try NativeTaskCapabilityDescriptor(arguments: newer), replayed: true)
        let snapshot = try store.complete(command, result: result, endpoint: endpoint)
        XCTAssertEqual(snapshot.localState, "superseded")
        XCTAssertThrowsError(try store.credential(taskID: request.taskID, managerEndpoint: endpoint))
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.fileURL(taskID: request.taskID)), as: UTF8.self).contains("fc-task-v1:"))
    }

    func testProtectedStoreRejectsModesHardlinksSymlinksFIFOAndOversizeWithoutRepair() throws {
        let home = try OperatorFixture.home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = NativeTaskCredentialFileStore(paths: AppPaths(home: home)), endpoint = OperatorFixture.endpoint
        let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 9, count: 32))
        let request = try OperatorFixture.request(capabilityID: credential.capabilityID, verifier: credential.verifier.sha256)
        _ = try store.stage(.prepare(request), candidate: credential, endpoint: endpoint)
        let path = store.fileURL(taskID: request.taskID), original = try Data(contentsOf: path)
        var status = stat(); XCTAssertEqual(lstat(path.path, &status), 0); XCTAssertEqual(status.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(store.directoryURL.path, &status), 0); XCTAssertEqual(status.st_mode & 0o777, 0o700)
        for target in [path, store.directoryURL] {
            let installed = try ProcessRunner().run(executable: "/bin/chmod", arguments: ["+a", "everyone allow read", target.path], timeoutSec: 5)
            XCTAssertEqual(installed.exitCode, 0, "The fixture must install an actual extended ACL")
            XCTAssertThrowsError(try store.snapshot(taskID: request.taskID), "Owner-only modes do not override a granting ACL")
            let removed = try ProcessRunner().run(executable: "/bin/chmod", arguments: ["-N", target.path], timeoutSec: 5)
            XCTAssertEqual(removed.exitCode, 0)
            XCTAssertEqual(try store.snapshot(taskID: request.taskID).localState, "prepare_pending")
        }
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertThrowsError(try store.snapshot(taskID: request.taskID))
        XCTAssertEqual(lstat(path.path, &status), 0); XCTAssertEqual(status.st_mode & 0o777, 0o644)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        let hardlink = home.appendingPathComponent("hardlink")
        XCTAssertEqual(link(path.path, hardlink.path), 0)
        XCTAssertThrowsError(try store.snapshot(taskID: request.taskID))
        try FileManager.default.removeItem(at: hardlink)
        try FileManager.default.removeItem(at: path)
        let outside = home.appendingPathComponent("outside.json"); try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        XCTAssertThrowsError(try store.snapshot(taskID: request.taskID))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(mkfifo(path.path, 0o600), 0)
        XCTAssertThrowsError(try store.snapshot(taskID: request.taskID), "Nonblocking no-follow reads must reject FIFOs")
        try FileManager.default.removeItem(at: path)
        try OwnerOnlyAtomicFile.write(Data(repeating: 32, count: NativeTaskCredentialFileStore.maximumFileBytes + 1), to: path)
        XCTAssertThrowsError(try store.snapshot(taskID: request.taskID))
        try FileManager.default.removeItem(at: store.directoryURL)
        let redirected = home.appendingPathComponent("redirected"); try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: store.directoryURL, withDestinationURL: redirected)
        XCTAssertThrowsError(try store.stage(.prepare(request), candidate: credential, endpoint: endpoint))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
    }

    func testWrongResponseAndCompetingCommandDoNotReplacePendingIdentity() throws {
        let home = try OperatorFixture.home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = NativeTaskCredentialFileStore(paths: AppPaths(home: home)), endpoint = OperatorFixture.endpoint
        let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 1, count: 32))
        let request = try OperatorFixture.request(capabilityID: credential.capabilityID, verifier: credential.verifier.sha256)
        let command = NativeTaskOperatorCommand.prepare(request)
        _ = try store.stage(command, candidate: credential, endpoint: endpoint)
        let before = try Data(contentsOf: store.fileURL(taskID: request.taskID))
        XCTAssertThrowsError(try store.stage(command, candidate: credential, endpoint: endpoint))
        XCTAssertThrowsError(try store.complete(command, result: OperatorFixture.result(.prepare(OperatorFixture.request())), endpoint: endpoint))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(taskID: request.taskID)), before)
        XCTAssertThrowsError(try store.pending(taskID: request.taskID, endpoint: URL(string: "http://127.0.0.1:8888/mcp/continuity")!))
    }

    func testCommandLineRejectsRawSecretsUnknownDuplicateOptionsAndMalformedCAS() throws {
        for args in [["prepare", "--secret", "private"], ["reconcile", "--task", UUID().uuidString],
                     ["prepare", "--request", "relative.json"], ["prepare", "--request", "/a", "--request", "/b"],
                     ["rotate", "--task", UUID().uuidString.lowercased(), "--expected-epoch", "01", "--expires-at", OperatorFixture.expiry]] {
            XCTAssertThrowsError(try NativeTaskOperatorCommandLine.Options(args))
        }
        let id = UUID().uuidString.lowercased()
        let options = try NativeTaskOperatorCommandLine.Options(["revoke", "--task", id, "--expected-epoch", "2", "--reason", "finished", "--home", "/tmp/installation"])
        XCTAssertEqual(options.taskID?.uuidString.lowercased(), id); XCTAssertEqual(options.epoch, 2)
        XCTAssertEqual(options.home?.path, "/tmp/installation")
    }

    func testRealLoopbackOperatorPrepareReplayRotateRevokeCreateNoRunOrProvider() async throws {
        let fixture = try await OperatorLoopbackFixture.make()
        defer { fixture.close() }
        let store = NativeTaskCredentialFileStore(paths: fixture.app.paths)
        let transport = OperatorLostLoopbackResponse(client: fixture.client)
        let client = try NativeTaskOperatorClient(store: store, transport: transport, endpoint: fixture.endpoint)
        let taskID: UUID
        do { _ = try await client.prepare(OperatorFixture.input(projectID: fixture.projectID)); return XCTFail("The post-response interruption was not retained") }
        catch let pending as NativeTaskOperatorPendingCommand { taskID = pending.snapshot.taskID }
        XCTAssertEqual(try fixture.count("native_task_capabilities"), 1)
        XCTAssertEqual(try fixture.count("native_task_commands"), 1)
        let before = try store.pending(taskID: taskID, endpoint: fixture.endpoint).data
        let restartedClient = try NativeTaskOperatorClient(store: NativeTaskCredentialFileStore(paths: fixture.app.paths), transport: fixture.client, endpoint: fixture.endpoint)
        let prepared = try await restartedClient.reconcile(taskID: taskID)
        XCTAssertEqual(prepared.result?.replayed, true)
        XCTAssertEqual(prepared.result?.receipt.requestSHA256, try NativeTaskOperatorCommand(action: "prepare", data: before).requestSHA256)
        XCTAssertEqual(try fixture.count("native_task_commands"), 1)
        XCTAssertEqual(prepared.result?.current.epoch, 1)
        let sourceFile = fixture.app.paths.home.appendingPathComponent("project/source.txt")
        try Data("first source value".utf8).write(to: sourceFile)
        let attachment = try store.attachment(taskID: taskID, managerEndpoint: fixture.endpoint)
        let protocolSession = try fixture.initialize(attachment)
        let read: [String: Any] = ["jsonrpc": "2.0", "id": "stable-source-read", "method": "tools/call",
            "params": ["name": "fs_read", "arguments": ["path": sourceFile.path]]]
        let original = try fixture.rpc(attachment, object: read, session: protocolSession)
        XCTAssertEqual(original.1.statusCode, 200)
        XCTAssertEqual(try fixture.content(original.0)["content"] as? String, "first source value")
        try Data("changed source value".utf8).write(to: sourceFile)
        let reopenedAttachment = try NativeTaskCredentialFileStore(paths: fixture.app.paths).attachment(taskID: taskID, managerEndpoint: fixture.endpoint)
        XCTAssertEqual(reopenedAttachment.sourceSessionID, attachment.sourceSessionID)
        let freshProtocolSession = try fixture.initialize(reopenedAttachment)
        XCTAssertNotEqual(protocolSession, freshProtocolSession)
        let replay = try fixture.rpc(reopenedAttachment, object: read, session: freshProtocolSession)
        XCTAssertEqual(replay.1.statusCode, 200)
        XCTAssertEqual(replay.0, original.0, "A fresh protocol session must retain the exact source request identity")
        XCTAssertEqual(try fixture.count("native_source_requests"), 1)
        let rotated = try await restartedClient.rotate(taskID: taskID, expectedEpoch: 1, expiresAt: OperatorFixture.expiry)
        XCTAssertEqual(rotated.result?.current.epoch, 2)
        let rotatedAttachment = try store.attachment(taskID: taskID, managerEndpoint: fixture.endpoint)
        XCTAssertEqual(rotatedAttachment.sourceSessionID, attachment.sourceSessionID)
        XCTAssertEqual(try fixture.rpc(attachment, object: read, session: protocolSession).1.statusCode, 401)
        let rotatedSession = try fixture.initialize(rotatedAttachment)
        let oldEpochReplay = try fixture.rpc(rotatedAttachment, object: read, session: rotatedSession)
        XCTAssertEqual(try fixture.content(oldEpochReplay.0)["code"] as? String, "source_request_conflict")
        var nextRead = read; nextRead["id"] = "new-epoch-read"
        let currentRead = try fixture.rpc(rotatedAttachment, object: nextRead, session: rotatedSession)
        XCTAssertEqual(try fixture.content(currentRead.0)["content"] as? String, "changed source value")
        XCTAssertEqual(try fixture.count("native_source_requests"), 2)
        let revoked = try await restartedClient.revoke(taskID: taskID, expectedEpoch: 2)
        XCTAssertEqual(revoked.result?.current.state, .revoked)
        XCTAssertEqual(try fixture.count("native_task_commands"), 3)
        for table in ["autonomous_runs", "provider_sessions", "provider_turns", "continuity_ingress_acceptances"] {
            XCTAssertEqual(try fixture.count(table), 0, "Operator credential setup must not enter \(table)")
        }
        XCTAssertThrowsError(try store.credential(taskID: taskID, managerEndpoint: fixture.endpoint))
        let managerToken = try ManagerControlCredentialStore(paths: fixture.app.paths).bearerToken()
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.fileURL(taskID: taskID)), as: UTF8.self).contains(managerToken))
    }

    func testActualCredentialNamespaceCannotBeReadUnderBroadFilesystemOrProcessGrant() async throws {
        // Exercise the protected subtree, without failing first on the /var convenience alias.
        let fixtureRoot = RuntimeProcessSandbox.canonicalExistingURL(try OperatorFixture.home())
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let home = fixtureRoot.appendingPathComponent("installation")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let app = try ForgeApp.bootstrap(home: home); defer { app.shutdown() }
        try app.config.update(["allowed_roots": [home.path]], save: false)
        let store = NativeTaskCredentialFileStore(paths: app.paths), transport = OperatorReceiptTransport()
        let client = try NativeTaskOperatorClient(store: store, transport: transport, endpoint: OperatorFixture.endpoint)
        let active = try await client.prepare(OperatorFixture.input())
        let secret = try store.credential(taskID: active.taskID, managerEndpoint: OperatorFixture.endpoint).authorizationValue
        let alias = home.appendingPathComponent("credential-alias")
        try FileManager.default.createSymbolicLink(at: alias,
            withDestinationURL: RuntimeProcessSandbox.canonicalExistingURL(store.directoryURL))
        let scope = ToolAuthorizationScope(canonicalRoots: [home], writableRoots: [home], allowedTools: ["*"], networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("credential-isolation"), authorizationScope: scope)
        let initialized = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": home.path], clientID: context.clientID)
        XCTAssertTrue(initialized.ok, "The control fixture must hold an actual broad project binding")
        let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
        for path in [active.credentialFile, alias.appendingPathComponent(active.credentialFile.lastPathComponent)] {
            let decision = authorization.authorize(tool: "fs_read", arguments: ["path": path.path], context: context, clientID: context.clientID, binding: nil)
            guard case .denied(let code, _) = decision else { XCTFail("Broad grant exposed credential path"); continue }
            XCTAssertEqual(code, "manager_validation_path_protected")
            do {
                let result = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: context.clientID)
                XCTAssertFalse(result.ok)
                XCTAssertEqual(result.payload["code"] as? String, "manager_validation_path_protected")
                XCTAssertFalse(String(describing: result.payload).contains(secret))
            } catch { /* The actual filesystem pack may reject with a typed error. */ }
        }
        let ordinary = home.appendingPathComponent("ordinary.txt"); try Data("ordinary work".utf8).write(to: ordinary)
        let readable = try app.tools.call(name: "fs_read", arguments: ["path": ordinary.path], clientID: context.clientID)
        XCTAssertTrue(readable.ok)
        let scratch = fixtureRoot.appendingPathComponent("scratch"), artifacts = fixtureRoot.appendingPathComponent("artifacts")
        for directory in [scratch, artifacts] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func execute(_ program: String, _ arguments: [String]) throws -> ProcessResult {
            let plan = try RuntimeProcessSandbox.plan(executable: URL(fileURLWithPath: program), arguments: arguments,
                workingDirectory: home, environment: [:], canonicalReadRoots: [home], canonicalWritableRoots: [home],
                managerReadDirectory: artifacts, scratchDirectory: scratch, networkAllowed: false,
                protectedDirectories: [app.paths.nativeValidationDir])
            return try ProcessRunner().run(executable: plan.executable.path, arguments: plan.arguments, timeoutSec: 5)
        }
        let processControl = try execute("/bin/cat", [ordinary.path])
        XCTAssertEqual(processControl.exitCode, 0, processControl.stderr)
        XCTAssertEqual(processControl.stdout, "ordinary work")
        let ordinaryAlias = home.appendingPathComponent("ordinary-alias")
        try FileManager.default.createSymbolicLink(at: ordinaryAlias, withDestinationURL: ordinary)
        let aliasControl = try execute("/bin/cat", [ordinaryAlias.path])
        XCTAssertEqual(aliasControl.exitCode, 0, aliasControl.stderr)
        XCTAssertEqual(aliasControl.stdout, "ordinary work")
        for (program, arguments) in [("/bin/cat", [RuntimeProcessSandbox.canonicalExistingURL(active.credentialFile).path]),
                                      ("/usr/bin/git", ["--no-pager", "diff", "--no-index", "/dev/null", alias.appendingPathComponent(active.credentialFile.lastPathComponent).path])] {
            let result = try execute(program, arguments)
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertFalse(result.stdout.contains(secret)); XCTAssertFalse(result.stderr.contains(secret))
        }
    }

    func testRealCommandLineUsesCustomInstallationWithoutOpeningAnotherStore() async throws {
        let fixture = try await OperatorLoopbackFixture.make(); defer { fixture.close() }
        let input = fixture.app.paths.home.appendingPathComponent("approval.json")
        let request = try OperatorFixture.request()
        var object = try request.asDictionary()
        for key in ["request_id", "task_id", "capability_id", "verifier_sha256"] { object.removeValue(forKey: key) }
        object["project_id"] = fixture.projectID.description
        try ForgeJSONCanonicalizationV1.data(from: object).write(to: input)
        let data = try await NativeTaskOperatorCommandLine.run(arguments: ["prepare", "--request", input.path, "--home", fixture.app.paths.home.path])
        let output = try JSONSupport.object(from: data)
        XCTAssertEqual(output["ok"] as? Bool, true)
        let taskID = try XCTUnwrap(output["task_id"] as? String)
        let credentialPath = try XCTUnwrap(output["credential_file"] as? String)
        XCTAssertTrue(credentialPath.hasPrefix(fixture.app.paths.nativeValidationDir.path + "/task-attachments/"))
        XCTAssertEqual(output["endpoint"] as? String, fixture.endpoint.absoluteString)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fc-task-v1:"))
        XCTAssertEqual(try fixture.count("native_task_capabilities"), 1)
        XCTAssertEqual(try fixture.count("autonomous_runs"), 0)
        let revoked = try await NativeTaskOperatorCommandLine.run(arguments: ["revoke", "--task", taskID,
            "--expected-epoch", "1", "--home", fixture.app.paths.home.path])
        XCTAssertEqual(try JSONSupport.object(from: revoked)["local_state"] as? String, "revoked")
    }

    func testDashboardClientRetriesIdenticalBytesAndBoundsOrRedactsInvalidResponses() async throws {
        let request = try OperatorFixture.request()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OperatorClientURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let credential = OperatorTestManagerCredential()
        let client = ManagerDashboardClient(host: "127.0.0.1", port: 7788, session: session, credentials: credential)
        let success = try NativeTaskOperatorResponse.data(OperatorFixture.result(.prepare(request)))
        OperatorClientURLProtocol.configure([.failure, .body(status: 200, data: success, declaredLength: nil)])
        let result = try await client.prepareNativeContinuityTask(request)
        XCTAssertEqual(result.receipt.requestID, request.requestID)
        let calls = OperatorClientURLProtocol.requests()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].body, request.canonicalRequestJSON)
        XCTAssertEqual(calls[0].body, calls[1].body)
        XCTAssertEqual(calls[0].authorization, "Bearer " + credential.bearerToken())
        XCTAssertEqual(calls[0].authorization, calls[1].authorization)
        XCTAssertEqual(calls[0].path, "/api/manager/continuity/tasks/prepare")
        OperatorClientURLProtocol.configure([.failure, .failure])
        do { _ = try await client.prepareNativeContinuityTask(request); XCTFail("Two ambiguous attempts must stop") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(OperatorClientURLProtocol.requests().count, 2)
        let sensitive = Data("private server content and an untrusted token".utf8)
        OperatorClientURLProtocol.configure([.body(status: 500, data: sensitive, declaredLength: nil)])
        do { _ = try await client.prepareNativeContinuityTask(request); XCTFail("Rejected response was accepted") }
        catch {
            XCTAssertEqual(error as? NativeTaskOperatorError, .rejected(status: 500, code: "native_task_command_rejected"))
            XCTAssertFalse(error.localizedDescription.contains("private server"))
        }
        XCTAssertEqual(OperatorClientURLProtocol.requests().count, 1)
        for declared in [nil, 32_769] as [Int?] {
            OperatorClientURLProtocol.configure([.body(status: 200, data: Data(repeating: 32, count: 32_769), declaredLength: declared)])
            do { _ = try await client.prepareNativeContinuityTask(request); XCTFail("Over-limit response was accepted") }
            catch { XCTAssertEqual(error as? NativeTaskOperatorError, .responseTooLarge) }
            XCTAssertEqual(OperatorClientURLProtocol.requests().count, 1)
        }
        let foreign = ManagerDashboardClient(host: "example.test", port: 7788, session: session, credentials: credential)
        XCTAssertEqual(OperatorClientURLProtocol.requests().count, 1)
        do { _ = try await foreign.prepareNativeContinuityTask(request); XCTFail("Non-loopback operator bearer was sent") }
        catch { XCTAssertEqual(error as? NativeTaskOperatorError, .invalidRequest("manager_endpoint")) }
        XCTAssertEqual(OperatorClientURLProtocol.requests().count, 1)
    }
}

private enum OperatorFixture {
    static let endpoint = URL(string: "http://127.0.0.1:7788/mcp/continuity")!
    static var expiry: String { ISO8601.string(from: Date().addingTimeInterval(3_600)) }
    static func home() throws -> URL {
        let result = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-operator-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return result
    }
    static func approval() throws -> NativeContinuityTaskApproval {
        try NativeContinuityTaskApproval(assignmentID: "operator-assignment", assignmentBytes: Data("Approved document".utf8),
            mission: "Read the exact project file", providerID: "lmstudio", adapterID: "forge.native-session-host", modelKey: "fixture-model",
            allowedTools: ["fs_read"], completionGates: ["file-read"], resourceProfile: .standard, filesystemAccess: "read_only",
            networkAllowed: false, maximumInlineOutputBytes: 1_024,
            sourceLimits: NativeTaskSourceLimits(maximumCalls: 4, maximumResultBytes: 1_024, maximumRequestSeconds: 5))
    }
    static func input(projectID: ProjectID = ProjectID()) throws -> NativeContinuityTaskPreparationInput {
        try NativeContinuityTaskPreparationInput(projectID: projectID, projectGeneration: .initial, approval: approval(), expiresAt: expiry)
    }
    static func request(capabilityID: UUID = UUID(), verifier: String = String(repeating: "a", count: 64)) throws -> NativeContinuityTaskPreparationRequest {
        try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: UUID(), capabilityID: capabilityID,
            projectID: ProjectID(), projectGeneration: .initial, approval: approval(), verifierSHA256: verifier, expiresAt: expiry)
    }
    static func result(_ command: NativeTaskOperatorCommand, prior: NativeTaskCapabilityCommandResult? = nil) throws -> NativeTaskCapabilityCommandResult {
        let now = ISO8601.string(from: Date())
        var object: [String: Any] = prior?.current.wireObject ?? ["task_id": command.taskID.uuidString.lowercased(),
            "capability_id": command.capabilityID.uuidString.lowercased(), "project_id": command.projectID.description,
            "project_generation": command.projectGeneration.rawValue, "profile_id": "forge.native-task-source", "profile_version": 1,
            "approval_sha256": String(repeating: "b", count: 64), "scope_sha256": String(repeating: "c", count: 64),
            "original_caller_binding_id": UUID().uuidString.lowercased(), "source_binding_id": UUID().uuidString.lowercased()]
        object["epoch"] = command.resultEpoch; object["state"] = command.action == "revoke" ? "revoked" : "active"
        object["issued_at"] = now; object["expires_at"] = command.expiresAt ?? prior?.current.expiresAt ?? expiry
        object["revoked_at"] = command.action == "revoke" ? now as Any : NSNull()
        let descriptor = try NativeTaskCapabilityDescriptor(arguments: object)
        let document: String
        if case .prepare(let request) = command { document = JSONSupport.sha256Hex(request.approval.assignmentBytes) }
        else { document = try XCTUnwrap(prior?.receipt.documentSHA256) }
        let receipt = try NativeTaskCapabilityCommandReceipt(requestID: command.requestID, action: command.action,
            requestSHA256: command.requestSHA256, descriptor: descriptor, priorEpoch: command.expectedEpoch,
            documentSHA256: document, verifierSHA256: command.verifierSHA256, recordedAt: now)
        return .init(receipt: receipt, current: descriptor, replayed: false)
    }
}

private actor OperatorReceiptTransport: NativeTaskOperatorTransport {
    private var retained: [UUID: NativeTaskCapabilityCommandResult] = [:]
    private var current: NativeTaskCapabilityCommandResult?
    private var lose = false
    private var bodies: [Data] = []
    func loseNextResponse() { lose = true }
    func calls() -> [Data] { bodies }
    func submitNativeTaskCommand(action: String, body: Data) async throws -> NativeTaskCapabilityCommandResult {
        bodies.append(body)
        let command = try NativeTaskOperatorCommand(action: action, data: body)
        let result: NativeTaskCapabilityCommandResult
        if let retained = retained[command.requestID] {
            result = .init(receipt: retained.receipt, current: current!.current, replayed: true)
        } else {
            result = try OperatorFixture.result(command, prior: current); retained[command.requestID] = result; current = result
        }
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        return result
    }
}

private actor OperatorLostLoopbackResponse: NativeTaskOperatorTransport {
    let client: ManagerDashboardClient
    private var lose = true
    init(client: ManagerDashboardClient) { self.client = client }
    func submitNativeTaskCommand(action: String, body: Data) async throws -> NativeTaskCapabilityCommandResult {
        let result = try await client.submitNativeTaskCommand(action: action, body: body)
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        return result
    }
}

private final class OperatorLoopbackFixture: @unchecked Sendable {
    let app: ForgeApp
    var node: ManagerNode?
    let projectID: ProjectID
    let client: ManagerDashboardClient
    let endpoint: URL
    private init(app: ForgeApp, node: ManagerNode, projectID: ProjectID, port: Int) {
        self.app = app; self.node = node; self.projectID = projectID
        client = ManagerDashboardClient(host: "127.0.0.1", port: port, credentials: ManagerControlCredentialStore(paths: app.paths))
        endpoint = URL(string: "http://127.0.0.1:\(port)/mcp/continuity")!
    }
    static func make() async throws -> OperatorLoopbackFixture {
        let home = try OperatorFixture.home(), app = try ForgeApp.bootstrap(home: home)
        let node = ManagerNode(app: app), port = Int.random(in: 29_000...38_000)
        do {
            let project = home.appendingPathComponent("project"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try app.config.update(["dashboard": ["host": "127.0.0.1", "port": port], "allowed_roots": [project.path]], save: true)
            let registered = try node.registerProject(path: project.path)
            let projectID = ProjectID(try XCTUnwrap((registered["project_id"] as? String).flatMap(UUID.init(uuidString:))))
            _ = try node.startService()
            return OperatorLoopbackFixture(app: app, node: node, projectID: projectID, port: port)
        } catch { _ = node.shutdownNativeTaskAttachment(); app.shutdown(); try? FileManager.default.removeItem(at: home); throw error }
    }
    func close() {
        _ = try? node?.stopService(); node?.shutdownManagedAutonomy(); _ = node?.shutdownNativeTaskAttachment(); node = nil
        app.shutdown(); try? FileManager.default.removeItem(at: app.paths.home)
    }
    func count(_ table: String) throws -> Int {
        guard ["native_task_capabilities", "native_task_commands", "native_source_requests", "autonomous_runs", "provider_sessions", "provider_turns", "continuity_ingress_acceptances"].contains(table) else { throw NativeTaskOperatorError.invalidResponse }
        var db: OpaquePointer?
        guard sqlite3_open_v2(app.paths.controlPlaneSQLite.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { throw NativeTaskOperatorError.invalidResponse }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM " + table, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeTaskOperatorError.invalidResponse }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NativeTaskOperatorError.invalidResponse }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func rpc(_ attachment: NativeTaskHTTPAttachment, object: [String: Any], session: String? = nil) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: attachment.endpoint); request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + attachment.credential.authorizationValue, forHTTPHeaderField: "Authorization")
        request.setValue(attachment.sourceSessionID.uuidString.lowercased(), forHTTPHeaderField: "Forge-Source-Session-ID")
        if let session {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(MCPTaskHTTPService.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONSupport.data(from: object)
        return try HTTPTestHelpers.fetch(request)
    }
    func initialize(_ attachment: NativeTaskHTTPAttachment) throws -> String {
        let response = try rpc(attachment, object: ["jsonrpc": "2.0", "id": UUID().uuidString.lowercased(), "method": "initialize",
            "params": ["protocolVersion": MCPTaskHTTPService.protocolVersion]])
        XCTAssertEqual(response.1.statusCode, 200)
        let session = try XCTUnwrap(response.1.value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(try rpc(attachment, object: ["jsonrpc": "2.0", "method": "notifications/initialized"], session: session).1.statusCode, 202)
        return session
    }
    func content(_ data: Data) throws -> [String: Any] {
        let object = try JSONSupport.object(from: data)
        return try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
    }
}

private struct OperatorTestManagerCredential: ManagerMutationCredentialProviding {
    func bearerToken() -> String { String(repeating: "d", count: 64) }
}

private final class OperatorClientURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable { case failure; case body(status: Int, data: Data, declaredLength: Int?) }
    struct Captured: Sendable { let body: Data; let authorization: String?; let path: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var captured: [Captured] = []
    static func configure(_ values: [Reply]) { lock.lock(); replies = values; captured = []; lock.unlock() }
    static func requests() -> [Captured] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0, data.count <= NativeContinuityTaskPreparationRequest.maximumBodyBytes - count else { break }
                data.append(buffer, count: count)
            }
        }
        Self.lock.lock()
        Self.captured.append(Captured(body: data, authorization: request.value(forHTTPHeaderField: "Authorization"), path: request.url?.path ?? ""))
        let reply = Self.replies.isEmpty ? Reply.failure : Self.replies.removeFirst()
        Self.lock.unlock()
        switch reply {
        case .failure: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .body(let status, let data, let length):
            var headers = ["Content-Type": "application/json"]
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
