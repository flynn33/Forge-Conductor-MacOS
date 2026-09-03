// ManagerTests.swift
// Verifies manager start, stop, status, settings, and PID-file lifecycle behavior.
// Each test uses an isolated home to avoid signalling or reconfiguring an installed manager.

import XCTest
import Security
import Darwin
import ForgeFilesystemProtocol
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

private enum ManagerArtifactFixtureError: Error {
    case forcedCopyFailure
    case forcedSigningFailure
    case forcedVerificationFailure
    case forcedCommitFailure
}

private enum ManagerProviderProbeFixtureError: Error {
    case unsupported
}

private enum ManagerConcurrentRegistrationFixtureError: Error {
    case barrierTimedOut
}

private final class ManagerConcurrentRegistrationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrivals = 0

    func arriveAndWait() throws {
        condition.lock()
        defer { condition.unlock() }
        arrivals += 1
        if arrivals == 2 {
            condition.broadcast()
            return
        }
        let deadline = Date().addingTimeInterval(2)
        while arrivals < 2 {
            guard condition.wait(until: deadline) else {
                throw ManagerConcurrentRegistrationFixtureError.barrierTimedOut
            }
        }
    }
}

private final class ManagerRelinkLostResponseProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var lostResponseCount = 1
    nonisolated(unsafe) private static var recordedBodies: [Data] = []
    nonisolated(unsafe) private static var recordedAuthorizationHeaders: [String?] = []

    static func configure(responseData: Data, lostResponseCount: Int = 1) {
        lock.lock()
        self.responseData = responseData
        self.lostResponseCount = max(0, lostResponseCount)
        recordedBodies = []
        recordedAuthorizationHeaders = []
        lock.unlock()
    }

    static func transcript() -> (bodies: [Data], authorizationHeaders: [String?]) {
        lock.lock()
        defer { lock.unlock() }
        return (recordedBodies, recordedAuthorizationHeaders)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/manager/projects/relink"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let attempt: Int
        let responseData: Data
        let lostResponseCount: Int
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        Self.recordedBodies.append(body)
        Self.recordedAuthorizationHeaders.append(
            request.value(forHTTPHeaderField: "Authorization")
        )
        attempt = Self.recordedBodies.count
        responseData = Self.responseData
        lostResponseCount = Self.lostResponseCount
        Self.lock.unlock()

        guard attempt > lostResponseCount else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.networkConnectionLost)
            )
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ManagerRegistrationLostResponseProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var lostResponseCount = 1
    nonisolated(unsafe) private static var recordedBodies: [Data] = []
    nonisolated(unsafe) private static var recordedAuthorizationHeaders: [String?] = []

    static func configure(responseData: Data, lostResponseCount: Int = 1) {
        lock.lock()
        self.responseData = responseData
        self.lostResponseCount = max(0, lostResponseCount)
        recordedBodies = []
        recordedAuthorizationHeaders = []
        lock.unlock()
    }

    static func transcript() -> (bodies: [Data], authorizationHeaders: [String?]) {
        lock.lock()
        defer { lock.unlock() }
        return (recordedBodies, recordedAuthorizationHeaders)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/manager/projects/register"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let attempt: Int
        let responseData: Data
        let lostResponseCount: Int
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        Self.recordedBodies.append(body)
        Self.recordedAuthorizationHeaders.append(
            request.value(forHTTPHeaderField: "Authorization")
        )
        attempt = Self.recordedBodies.count
        responseData = Self.responseData
        lostResponseCount = Self.lostResponseCount
        Self.lock.unlock()

        guard attempt > lostResponseCount else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ManagerRotatingCredentialFixture:
    ManagerMutationCredentialProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var invocationCount = 0

    func bearerToken() throws -> String {
        lock.lock()
        invocationCount += 1
        let scalar = invocationCount == 1 ? "a" : "b"
        lock.unlock()
        return String(
            repeating: scalar,
            count: ManagerControlCredentialStore.tokenCharacterCount
        )
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }
}

private struct ManagerRelinkCredentialFixture: ManagerMutationCredentialProviding {
    func bearerToken() throws -> String {
        String(repeating: "a", count: ManagerControlCredentialStore.tokenCharacterCount)
    }
}

private final class ManagerRelinkOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<ManagerProjectRelinkResult, Error>] = []

    func append(_ value: Result<ManagerProjectRelinkResult, Error>) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func load() -> [Result<ManagerProjectRelinkResult, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ManagerBoundedProcessOutput: @unchecked Sendable {
    let pipe = Pipe()

    private let maximumBytes: Int
    private let lock = NSLock()
    private let finishLock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var captured = Data()
    private var truncated = false
    private var reachedEnd = false
    private var finalText: String?

    init(maximumBytes: Int = 64 * 1_024) {
        self.maximumBytes = maximumBytes
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
    }

    func closeParentWriter() {
        try? pipe.fileHandleForWriting.close()
    }

    func finish() -> String {
        finishLock.lock()
        defer { finishLock.unlock() }
        if let finalText { return finalText }
        _ = completed.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        lock.lock()
        let data = captured
        let wasTruncated = truncated
        lock.unlock()
        let text = (String(data: data, encoding: .utf8) ?? "")
            + (wasTruncated ? "\n[child output truncated at \(maximumBytes) bytes]" : "")
        finalText = text
        return text
    }

    private func consume(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            if !reachedEnd {
                reachedEnd = true
                completed.signal()
            }
            lock.unlock()
            return
        }
        let remaining = maximumBytes - captured.count
        if remaining > 0 {
            captured.append(data.prefix(remaining))
        }
        if data.count > remaining {
            truncated = true
        }
        lock.unlock()
    }
}

private struct ExternalConfigLockHolder {
    let process: Process
    let readyURL: URL
}

private final class ManagerProviderStorageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStorageDirectory: URL?

    var storageDirectory: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedStorageDirectory
    }

    func record(_ storageDirectory: URL) {
        lock.lock()
        recordedStorageDirectory = storageDirectory.standardizedFileURL
        lock.unlock()
    }
}

private actor ManagerProviderProbeFixture: ManagedModelProvider {
    nonisolated let providerID = "lmstudio"
    private let capabilities: ProviderCapabilities
    private var probeCount = 0
    private var lookupCount = 0
    private var holdNextProbe = false
    private var heldProbeContinuation: CheckedContinuation<Void, Never>?
    private var cancelNextProbe = false
    private var awaitingProbeCancellation = false
    private var observedProbeCancellation = false
    private var ignoreCancellationNextProbe = false
    private var cancellationIgnoringProbeContinuation: CheckedContinuation<Void, Never>?

    init(capabilities: ProviderCapabilities) {
        self.capabilities = capabilities
    }

    func probe() async throws -> ProviderCapabilities {
        probeCount += 1
        if ignoreCancellationNextProbe {
            ignoreCancellationNextProbe = false
            await withCheckedContinuation { continuation in
                cancellationIgnoringProbeContinuation = continuation
            }
        }
        if cancelNextProbe {
            cancelNextProbe = false
            awaitingProbeCancellation = true
            do {
                try await Task.sleep(for: .seconds(60))
                awaitingProbeCancellation = false
            } catch {
                awaitingProbeCancellation = false
                observedProbeCancellation = Task.isCancelled || error is CancellationError
                throw error
            }
        }
        if holdNextProbe {
            holdNextProbe = false
            await withCheckedContinuation { continuation in
                heldProbeContinuation = continuation
            }
        }
        return capabilities
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        _ = request
        throw ManagerProviderProbeFixtureError.unsupported
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        _ = request
        throw ManagerProviderProbeFixtureError.unsupported
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? {
        _ = idempotencyKey
        lookupCount += 1
        return nil
    }

    func cancel(requestID: String) async {
        _ = requestID
    }

    func calls() -> (probes: Int, lookups: Int) {
        (probeCount, lookupCount)
    }

    func holdNextProbeUntilReleased() {
        holdNextProbe = true
    }

    func isHoldingProbe() -> Bool {
        heldProbeContinuation != nil
    }

    func releaseHeldProbe() {
        let continuation = heldProbeContinuation
        heldProbeContinuation = nil
        continuation?.resume()
    }

    func cancelNextProbeAtDeadline() {
        cancelNextProbe = true
        observedProbeCancellation = false
    }

    func isAwaitingProbeCancellation() -> Bool {
        awaitingProbeCancellation
    }

    func didObserveProbeCancellation() -> Bool {
        observedProbeCancellation
    }

    func ignoreCancellationUntilReleasedForNextProbe() {
        ignoreCancellationNextProbe = true
    }

    func isHoldingCancellationIgnoringProbe() -> Bool {
        cancellationIgnoringProbeContinuation != nil
    }

    func releaseCancellationIgnoringProbe() {
        let continuation = cancellationIgnoringProbeContinuation
        cancellationIgnoringProbeContinuation = nil
        continuation?.resume()
    }
}

private struct ManagerProviderProbeSessionAdapter: SessionHostAdapter {
    let identifier = ManagerNode.nativeSessionHostAdapterID
    let version = "fixture"

    func capabilities() async throws -> HostCapabilities {
        managerProviderHostCapabilities()
    }

    func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        _ = request
        throw ManagerProviderProbeFixtureError.unsupported
    }

    func session(forIdempotencyKey key: String) async throws -> HostSession? {
        _ = key
        return nil
    }

    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        _ = session
        _ = handoff
        throw ManagerProviderProbeFixtureError.unsupported
    }

    func awaitAcknowledgement(
        session: HostSession,
        handoffID: String,
        timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        _ = session
        _ = handoffID
        _ = timeout
        throw ManagerProviderProbeFixtureError.unsupported
    }

    func cancel(operationID: String) async {
        _ = operationID
    }
}

private func managerProviderHostCapabilities() -> HostCapabilities {
    HostCapabilities(
        create: true,
        bootstrap: true,
        usageReporting: true,
        resume: true,
        idempotency: true,
        queryByIdempotencyKey: true
    )
}

private func managerProviderCapabilities(
    statefulResponses: Bool = true,
    customTools: Bool = true,
    usageReporting: Bool = true,
    idempotencyLookup: Bool = true
) throws -> ProviderCapabilities {
    try ProviderCapabilities(
        providerID: "lmstudio",
        providerVersion: "fixture-1.0",
        modelKey: "fixture/tool-model",
        providerInstanceID: "fixture-instance",
        contextLength: 16_384,
        maximumContextLength: 32_768,
        statefulResponses: statefulResponses,
        streaming: true,
        customTools: customTools,
        mcp: false,
        structuredOutput: true,
        usageReporting: usageReporting,
        idempotencyLookup: idempotencyLookup,
        capabilityFingerprintSHA256: String(repeating: "a", count: 64)
    )
}

private func managerProviderRegistry(
    provider: ManagerProviderProbeFixture,
    recorder: ManagerProviderStorageRecorder,
    hostCapabilities: HostCapabilities = managerProviderHostCapabilities()
) -> HostAdapterRegistry {
    let registry = HostAdapterRegistry()
    registry.register(
        manifest: HostPluginManifest(
            identifier: ManagerNode.nativeSessionHostAdapterID,
            version: "fixture",
            minimumContractVersion: 2,
            hostType: "fixture",
            capabilities: hostCapabilities,
            configurationKeys: [],
            privacyRequirements: [],
            migrationVersion: 1
        ),
        managedProviderFactory: { storageDirectory in
            recorder.record(storageDirectory)
            return provider
        },
        factory: { _ in ManagerProviderProbeSessionAdapter() }
    )
    return registry
}

#if SWIFT_PACKAGE
private func writeLiveManagerProviderConfiguration(
    baseURL: URL,
    modelKey: String,
    paths: AppPaths
) throws {
    let directory = paths.managedProvidersDir.appendingPathComponent(
        ForgeNativeSessionHostPlugin.identifier,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let configuration = LMStudioProviderConfiguration(
        baseURL: baseURL,
        modelKey: modelKey,
        connectTimeoutSeconds: 5,
        firstByteTimeoutSeconds: 15,
        idleTimeoutSeconds: 30,
        totalTimeoutSeconds: 120,
        maximumOutputTokens: 256
    )
    try OwnerOnlyAtomicFile.write(
        try JSONEncoder().encode(configuration),
        to: directory.appendingPathComponent(
            LMStudioProviderConfiguration.fileName,
            isDirectory: false
        )
    )
}
#endif

private final class TestManagerArtifactValidator: ManagerArtifactValidating {
    enum Operation: Equatable {
        case sign(ManagerArtifactKind)
        case verify(ManagerArtifactKind)
    }

    let failingOperation: Operation?
    private(set) var operations: [Operation] = []

    init(failingOperation: Operation? = nil) {
        self.failingOperation = failingOperation
    }

    func prepareAndSign(_ url: URL, kind: ManagerArtifactKind) throws {
        _ = url
        let operation = Operation.sign(kind)
        operations.append(operation)
        if operation == failingOperation {
            throw ManagerArtifactFixtureError.forcedSigningFailure
        }
    }

    func verify(_ url: URL, kind: ManagerArtifactKind) throws {
        _ = url
        let operation = Operation.verify(kind)
        operations.append(operation)
        if operation == failingOperation {
            throw ManagerArtifactFixtureError.forcedVerificationFailure
        }
    }
}

private final class TestManagerArtifactCopier: ManagerArtifactCopying {
    let failingCopy: Int?
    private(set) var copyCount = 0

    init(failingCopy: Int? = nil) {
        self.failingCopy = failingCopy
    }

    func copyItem(at source: URL, to destination: URL) throws {
        copyCount += 1
        if copyCount == failingCopy {
            throw ManagerArtifactFixtureError.forcedCopyFailure
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private final class TestManagerArtifactReplacer: ManagerArtifactReplacing {
    let failingReplacement: Int?
    private(set) var replacementCount = 0

    init(failingReplacement: Int? = nil) {
        self.failingReplacement = failingReplacement
    }

    func applyReplacement(
        target: URL,
        staged: URL?,
        backup: URL,
        hadOriginal: Bool
    ) throws {
        replacementCount += 1
        let failAfterReplacement = replacementCount == failingReplacement
        let fm = FileManager.default
        if let staged {
            if hadOriginal {
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    try fm.moveItem(at: target, to: backup)
                    try fm.moveItem(at: staged, to: target)
                } else {
                    _ = try fm.replaceItemAt(
                        target,
                        withItemAt: staged,
                        backupItemName: backup.lastPathComponent,
                        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                    )
                }
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } else if hadOriginal {
            try fm.moveItem(at: target, to: backup)
        }
        if failAfterReplacement {
            throw ManagerArtifactFixtureError.forcedCommitFailure
        }
    }
}

private struct TestManagerCodeSignatureInspector: ManagerCodeSignatureInspecting {
    let inspection: ManagerArtifactSignatureInspection

    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind,
        requirement: String?
    ) throws -> ManagerArtifactSignatureInspection {
        _ = url
        _ = kind
        _ = requirement
        return inspection
    }
}

private final class TestManagerPrivilegedApplicationIdentityValidator:
    ManagerPrivilegedApplicationIdentityValidating
{
    enum Context: Equatable {
        case invocation
        case stagedCopy
    }

    struct Validation: Equatable {
        let applicationBundle: URL
        let sourceExecutable: URL
        let context: Context
    }

    let failure: Error?
    let failingContext: Context?
    private(set) var validations: [Validation] = []

    init(
        failure: Error? = nil,
        failingContext: Context? = nil
    ) {
        self.failure = failure
        self.failingContext = failingContext
    }

    func validate(applicationBundle: URL, invokedBy sourceExecutable: URL) throws {
        try record(
            applicationBundle: applicationBundle,
            sourceExecutable: sourceExecutable,
            context: .invocation
        )
    }

    func validateStaged(applicationBundle: URL, executable: URL) throws {
        try record(
            applicationBundle: applicationBundle,
            sourceExecutable: executable,
            context: .stagedCopy
        )
    }

    private func record(
        applicationBundle: URL,
        sourceExecutable: URL,
        context: Context
    ) throws {
        validations.append(
            Validation(
                applicationBundle: applicationBundle.standardizedFileURL,
                sourceExecutable: sourceExecutable.standardizedFileURL,
                context: context
            )
        )
        if let failure, failingContext == nil || failingContext == context {
            throw failure
        }
    }
}

private final class PathManagerCodeSignatureInspector: ManagerCodeSignatureInspecting {
    let inspections: [String: ManagerArtifactSignatureInspection]
    private(set) var requirementsByPath: [String: String] = [:]

    init(inspections: [String: ManagerArtifactSignatureInspection]) {
        self.inspections = inspections
    }

    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind,
        requirement: String?
    ) throws -> ManagerArtifactSignatureInspection {
        _ = kind
        let path = url.standardizedFileURL.path
        requirementsByPath[path] = requirement ?? ""
        guard let inspection = inspections[path] else {
            throw NSError(
                domain: "ManagerTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "No signature inspection fixture for \(url.path)"]
            )
        }
        return inspection
    }
}

private struct TestManagerExecutableCodeDirectoryHashInspector:
    ManagerExecutableCodeDirectoryHashInspecting
{
    let hashes: [String: String]

    func hashesByInfoPlistKey(at executable: URL) throws -> [String: String] {
        _ = executable
        return hashes
    }
}

private final class TestManagerLaunchctlRunner: ManagerLaunchctlRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let timeoutSec: TimeInterval
    }

    private var results: [ProcessResult]
    private(set) var invocations: [Invocation] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(arguments: [String], timeoutSec: TimeInterval) throws -> ProcessResult {
        invocations.append(Invocation(arguments: arguments, timeoutSec: timeoutSec))
        guard !results.isEmpty else {
            throw NSError(
                domain: "ManagerTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "No launchctl result remains for \(arguments)"]
            )
        }
        return results.removeFirst()
    }
}

private func launchctlResult(
    exitCode: Int32,
    stdout: String = "",
    stderr: String = "",
    timedOut: Bool = false
) -> ProcessResult {
    ProcessResult(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        timedOut: timedOut,
        stdoutTruncated: false,
        stderrTruncated: false
    )
}

private func missingLaunchctlJobResult() -> ProcessResult {
    launchctlResult(
        exitCode: 113,
        stderr: "Bad request.\nCould not find service \"\(ManagerInstaller.launchAgentLabel)\" "
            + "in domain for user gui: 501"
    )
}

final class ManagerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testManagerStartStopService() throws {
        let app = try ForgeApp.bootstrap(home: home)
        try app.config.update([
            "dashboard": ["port": Int.random(in: 19_000...28_000)] as [String: Any],
        ], save: true)

        let node = ManagerNode(app: app)
        let started = try node.startService()
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.serviceActive, true)
        XCTAssertTrue(node.isServiceActive())

        let port = app.config.int("dashboard", "port", default: 7788)
        let statusURL = URL(string: "http://127.0.0.1:\(port)/api/manager/status")!
        Thread.sleep(forTimeInterval: 0.2)
        let live = try HTTPTestHelpers.fetchJSON(statusURL)
        XCTAssertEqual(live["ok"] as? Bool, true)
        XCTAssertEqual(live["state"] as? String, "running")

        let stopped = try node.stopService()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.serviceActive, false)
        XCTAssertFalse(node.isServiceActive())

        let mgr = try HTTPTestHelpers.fetchJSON(statusURL)
        XCTAssertEqual(mgr["state"] as? String, "stopped")

        let sessionsURL = URL(string: "http://127.0.0.1:\(port)/api/sessions")!
        let code = try HTTPTestHelpers.fetchStatusCode(sessionsURL)
        XCTAssertEqual(code, 503)

        let again = try node.startService()
        XCTAssertEqual(again.serviceActive, true)
        Thread.sleep(forTimeInterval: 0.15)
        let sessionsOK = try HTTPTestHelpers.fetchJSON(sessionsURL)
        XCTAssertEqual(sessionsOK["ok"] as? Bool, true)
        _ = node
    }

    func testOperatorSnapshotRouteIsBoundedRedactedAndPreservesExistingQueryPaths() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 19_000...28_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let projectRoot = home.appendingPathComponent("operator-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(path: projectRoot.path, displayName: "Operator Project")
        let projectID = try XCTUnwrap((registered["project_id"] as? String).flatMap(UUID.init(uuidString:)))
        let storedProject = try await app.projectContexts.repository.project(ProjectID(projectID))
        let project = try XCTUnwrap(storedProject)
        let scope = ToolAuthorizationScope(
            canonicalRoots: [projectRoot],
            allowedTools: ["project_memory.search"],
            networkAllowed: false,
            maximumInlineOutputBytes: 1_024
        )
        for mission in ["Earlier run", "Inspect api_key=supersecretvalue without exposing it"] {
            _ = try await app.projectContexts.repository.createAutonomousRun(
                AutonomousRunRequest(
                    projectID: project.projectID,
                    projectGeneration: project.generation,
                    mission: mission,
                    providerID: "lmstudio",
                    adapterID: "forge.native-session-host",
                    modelKey: "fixture-model",
                    specification: AutonomousRunSpecification(
                        allowedTools: ["project_memory.search"],
                        completionGates: ["fixture-gate"]
                    ),
                    authorizationScope: scope
                )
            )
        }

        _ = try node.startService()
        defer { _ = try? node.stopService() }
        try await Task.sleep(for: .milliseconds(150))

        let base = "http://127.0.0.1:\(port)"
        let status = try HTTPTestHelpers.fetchJSON(
            try XCTUnwrap(URL(string: base + "/api/manager/status?ignored=1"))
        )
        XCTAssertEqual(status["ok"] as? Bool, true)

        let snapshot = try HTTPTestHelpers.fetchJSON(
            try XCTUnwrap(URL(string: base + "/api/manager/operator/snapshot?limit=1"))
        )
        XCTAssertEqual(snapshot["limit"] as? Int, 1)
        XCTAssertLessThanOrEqual((snapshot["projects"] as? [Any] ?? []).count, 1)
        XCTAssertLessThanOrEqual((snapshot["runs"] as? [Any] ?? []).count, 1)
        XCTAssertLessThanOrEqual((snapshot["continuity_operations"] as? [Any] ?? []).count, 1)
        XCTAssertLessThanOrEqual((snapshot["runtime_jobs"] as? [Any] ?? []).count, 1)
        XCTAssertLessThanOrEqual((snapshot["events"] as? [Any] ?? []).count, 1)
        XCTAssertNotNil(snapshot["provider"] as? [String: Any])
        XCTAssertNotNil(snapshot["runtime"] as? [String: Any])
        let redactedSnapshot = try node.operatorSnapshot(limit: 100)
        let mission = try XCTUnwrap(
            redactedSnapshot.runs.first(where: { $0.mission.contains("<redacted>") })?.mission
        )
        XCTAssertTrue(mission.contains("<redacted>"))
        XCTAssertFalse(mission.contains("supersecretvalue"))
        XCTAssertNotNil(snapshot["next_cursor"] as? String)

        for suffix in [
            "?limit=0",
            "?limit=abc",
            "?limit=1&limit=2",
            "?limit=1&cursor=0",
        ] {
            let code = try HTTPTestHelpers.fetchStatusCode(
                try XCTUnwrap(URL(string: base + "/api/manager/operator/snapshot" + suffix))
            )
            XCTAssertEqual(code, 400, "Expected a rejected snapshot query for \(suffix)")
        }
    }

    func testProjectMutationRoutesMatchExactOperatorProjectionAndResetReceipt() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update([
            "dashboard": ["port": port] as [String: Any],
            "allowed_roots": [home.path],
        ], save: true)
        let original = home.appendingPathComponent("projection-original", isDirectory: true)
        let replacement = home.appendingPathComponent("projection-replacement", isDirectory: true)
        for root in [original, replacement] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/projection.git", to: root)
        }
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        let registered = try node.registerProject(path: original.path, displayName: "Projection")
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let projectID = ProjectID(projectUUID)
        _ = try node.bindProject(
            projectID: projectID,
            expectedGeneration: .initial,
            owner: ProjectBindingOwner(kind: .mcpClient, id: "projection-before-reset")
        )
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))

        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let base = "http://127.0.0.1:\(port)"
        func post(_ path: String, _ object: [String: Any], authorized: Bool) throws -> [String: Any] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
            request.httpMethod = "POST"
            request.httpBody = try JSONSupport.data(from: object)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if authorized {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try HTTPTestHelpers.fetch(request)
            XCTAssertEqual(response.statusCode, 200)
            return try JSONSupport.object(from: data)
        }
        func snapshotProject() throws -> [String: Any] {
            let snapshot = try HTTPTestHelpers.fetchJSON(
                try XCTUnwrap(URL(string: base + "/api/manager/operator/snapshot?limit=10"))
            )
            return try XCTUnwrap(
                (snapshot["projects"] as? [[String: Any]])?.first(where: {
                    $0["project_id"] as? String == projectID.description
                })
            )
        }
        let projectionKeys = [
            "project_id", "display_name", "canonical_root", "project_generation",
            "lifecycle_state", "bindings", "memory", "continuity", "migration_warnings",
            "reset_receipt", "pending_transition", "created_at", "updated_at",
        ]
        func assertProjectionParity(
            _ response: [String: Any],
            _ snapshot: [String: Any],
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            for key in projectionKeys {
                let responseData = try JSONSupport.data(from: [
                    "value": response[key] ?? NSNull(),
                ])
                let snapshotData = try JSONSupport.data(from: [
                    "value": snapshot[key] ?? NSNull(),
                ])
                XCTAssertEqual(responseData, snapshotData, "Projection mismatch for \(key)", file: file, line: line)
            }
        }

        let reset = try post(
            "/api/manager/projects/reset-generation",
            ["project_id": projectID.description, "project_generation": UInt64(1)],
            authorized: true
        )
        let resetSnapshot = try snapshotProject()
        try assertProjectionParity(reset, resetSnapshot)
        XCTAssertEqual((reset["new_generation"] as? NSNumber)?.uint64Value, 2)
        XCTAssertEqual((reset["project_generation"] as? NSNumber)?.uint64Value, 2)
        let resetReceipt = try XCTUnwrap(reset["reset_receipt"] as? [String: Any])
        XCTAssertEqual((resetReceipt["prior_generation"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual((resetReceipt["new_generation"] as? NSNumber)?.uint64Value, 2)
        XCTAssertEqual((resetReceipt["invalidated_binding_count"] as? NSNumber)?.intValue, 1)

        let relink = try post(
            "/api/manager/projects/relink",
            [
                "project_id": projectID.description,
                "project_generation": UInt64(2),
                "path": replacement.path,
            ],
            authorized: true
        )
        try assertProjectionParity(relink, try snapshotProject())
        XCTAssertEqual((relink["project_generation"] as? NSNumber)?.uint64Value, 3)
        XCTAssertEqual((relink["new_generation"] as? NSNumber)?.uint64Value, 3)

        _ = try node.bindProject(
            projectID: projectID,
            expectedGeneration: ProjectGeneration(3),
            owner: ProjectBindingOwner(kind: .mcpClient, id: "projection-after-relink")
        )
        _ = try app.projectMemory.repositoryForProject(projectID.description)
        let replay = try post(
            "/api/manager/projects/register",
            ["path": replacement.path, "display_name": "Projection"],
            authorized: true
        )
        let status = try post(
            "/api/manager/projects/status",
            ["project_id": projectID.description],
            authorized: false
        )
        let finalSnapshot = try snapshotProject()
        try assertProjectionParity(replay, finalSnapshot)
        try assertProjectionParity(status, finalSnapshot)
        XCTAssertEqual(replay["reconciled"] as? Bool, true)
        XCTAssertEqual((replay["bindings"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((replay["memory"] as? [String: Any])?["state"] as? String, "available_unverified")
        XCTAssertNotNil(replay["continuity"] as? [String: Any])
        XCTAssertNotNil(replay["reset_receipt"] as? [String: Any])
    }

    func testOperatorSnapshotSerializesPersistedContinuityCheckpointAndAcknowledgement() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent(
            "operator-continuity-project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(
            path: projectRoot.path,
            displayName: "Operator Continuity Project"
        )
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let projectID = ProjectID(projectUUID)
        let runID = RunID()
        try await app.projectContexts.repository.reserveContinuityRun(
            runID: runID,
            projectID: projectID,
            projectGeneration: .initial,
            mission: "Publish exact durable continuity evidence",
            mode: .managedAutonomous
        )
        let handoff = try makeManagerOperatorHandoff(
            projectID: projectID,
            runID: runID,
            repositoryRoot: projectRoot
        )
        let engine = ContinuityStateEngine(memory: app.projectMemory)
        var operation = try engine.prepareV2(
            handoff: handoff,
            predecessorSessionID: "operator-predecessor",
            predecessorProviderResponseID: "operator-predecessor-response",
            adapterID: "forge.native-session-host",
            idempotencyKey: "operator-snapshot-\(handoff.operationID)"
        )
        let operationID = try XCTUnwrap(UUID(uuidString: operation.operationID))
        _ = try await app.projectContexts.repository.enqueueContinuityCommand(
            ContinuityCommandRequest(
                operationID: operationID,
                runID: runID,
                projectID: projectID,
                projectGeneration: .initial,
                type: .rollover,
                requestedBy: "operator-test",
                reason: "serialize durable continuity evidence",
                idempotencyKey: "operator-command-\(handoff.operationID)",
                payloadSHA256: handoff.contentSHA256
            )
        )
        operation = try engine.transitionV2(
            projectID: projectID.description,
            operationID: operation.operationID,
            expected: .checkpointPersisted,
            to: .successorRequested
        )
        operation = try engine.transitionV2(
            projectID: projectID.description,
            operationID: operation.operationID,
            expected: .successorRequested,
            to: .successorCreated,
            successorSessionID: "operator-successor",
            successorProviderResponseID: "operator-successor-response"
        )
        operation = try engine.transitionV2(
            projectID: projectID.description,
            operationID: operation.operationID,
            expected: .successorCreated,
            to: .successorBootstrapping
        )
        let acknowledgement = BootstrapAcknowledgementV2(
            projectID: projectID,
            projectGeneration: .initial,
            runID: runID,
            operationID: operationID,
            handoffID: try XCTUnwrap(UUID(uuidString: handoff.handoffID)),
            handoffSHA256: handoff.contentSHA256,
            nonce: try XCTUnwrap(handoff.bootstrapNonce)
        )
        operation = try engine.acknowledgeV2(
            projectID: projectID.description,
            operationID: operation.operationID,
            receipt: BootstrapReceipt(
                acknowledgement: acknowledgement,
                internalSessionID: "operator-successor",
                providerResponseID: "operator-successor-response",
                modelKey: "fixture/tool-model",
                adapterID: "forge.native-session-host"
            )
        )
        let persistedAcknowledgement = try XCTUnwrap(operation.acknowledgementSHA256)

        let snapshot = try node.operatorSnapshotDictionary(limit: 10)
        let operations = try XCTUnwrap(
            snapshot["continuity_operations"] as? [[String: Any]]
        )
        let serialized = try XCTUnwrap(operations.first)
        XCTAssertEqual(serialized["operation_id"] as? String, operation.operationID)
        XCTAssertEqual(serialized["checkpoint_id"] as? String, handoff.handoffID)
        XCTAssertEqual(serialized["handoff_id"] as? String, handoff.handoffID)
        XCTAssertEqual(
            serialized["acknowledgement_sha256"] as? String,
            persistedAcknowledgement
        )
    }

    private func makeManagerOperatorHandoff(
        projectID: ProjectID,
        runID: RunID,
        repositoryRoot: URL
    ) throws -> ContinuityHandoffV2 {
        try ContinuityHandoffV2(
            operationID: UUID().uuidString.lowercased(),
            project: [
                "project_id": projectID.description,
                "generation": ProjectGeneration.initial.rawValue,
                "display_name": "Operator Continuity Project",
                "repository_root": repositoryRoot.path,
                "branch": "main",
                "commit": "1234567",
                "dirty_summary": [] as [String],
            ],
            run: [
                "run_id": runID.description,
                "continuity_mode": ContinuityMode.managedAutonomous.rawValue,
                "assignment_id": "operator-snapshot",
            ],
            predecessorSession: [
                "session_id": "operator-predecessor",
                "provider_id": "lmstudio",
                "provider_response_id": "operator-predecessor-response",
                "adapter_id": "forge.native-session-host",
                "model": "fixture/tool-model",
            ],
            mission: "Publish exact durable continuity evidence",
            currentWork: [
                "phase_id": "operator-snapshot",
                "work_item_id": "continuity-projection",
                "summary": "Project persisted continuity evidence",
                "active_files": [] as [String],
            ],
            openWork: [[
                "id": "continuity-projection",
                "summary": "Publish the durable identifiers",
                "status": "open",
            ]],
            nextActions: [[
                "order": 1,
                "action": "Continue the managed run",
                "command": "",
                "success_condition": "The successor consumes the exact handoff",
                "replay_class": "idempotent",
            ]],
            contextBudget: [
                "capacity": 32_768,
                "used": 27_000,
                "reserved": 4_096,
                "remaining": 1_672,
                "source": "provider_exact",
                "confidence": 1.0,
                "action": "rollover",
                "trigger": "rollover threshold crossed",
            ],
            bootstrap: [
                "nonce": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "acknowledgement_contract_version": 2,
            ]
        ).validated()
    }

    func testManagerRuntimeThrottlesPresenceMaintenance() {
        let runtime = ManagerRuntime()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(runtime.claimPresencePrune(now: start, minimumInterval: 60))
        XCTAssertFalse(
            runtime.claimPresencePrune(
                now: start.addingTimeInterval(59),
                minimumInterval: 60
            )
        )
        XCTAssertTrue(
            runtime.claimPresencePrune(
                now: start.addingTimeInterval(60),
                minimumInterval: 60
            )
        )
    }

    func testManagerStartPrunesDeadStalePresence() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: home, clock: clock)
        try app.store.presenceUpsert(
            clientID: "stale-client",
            hostKind: "lm-studio-mcp",
            pid: Int32.max,
            cwd: home.path
        )
        clock.date = clock.date.addingTimeInterval(121)
        try app.config.update([
            "dashboard": ["port": Int.random(in: 19_000...28_000)] as [String: Any],
        ], save: true)

        let node = ManagerNode(app: app)
        _ = try node.startService()

        XCTAssertTrue(try app.store.presenceRecords().isEmpty)
    }

    func testManagerSettingsPersist() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 19_000...28_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        let result = try node.updateSettings([
            "dashboard": [
                "refresh_interval_sec": 12,
            ] as [String: Any],
            "manager": [
                "auto_restart": false,
                "watchdog_interval_sec": 5,
            ] as [String: Any],
            "shell": [
                "enabled": false,
                "default_timeout_sec": 37,
            ] as [String: Any],
        ], apply: true)

        XCTAssertEqual(result["ok"] as? Bool, true)
        let mgr = result["manager"] as? [String: Any]
        XCTAssertEqual(mgr?["auto_restart"] as? Bool, false)
        XCTAssertEqual(mgr?["watchdog_interval_sec"] as? Int, 5)
        let dash = result["dashboard"] as? [String: Any]
        XCTAssertEqual(dash?["refresh_interval_sec"] as? Int, 12)
        let shell = result["shell"] as? [String: Any]
        XCTAssertEqual(shell?["enabled"] as? Bool, false)
        XCTAssertEqual(shell?["user_disabled"] as? Bool, true)
        XCTAssertEqual(shell?["policy_version"] as? Int, AppConfig.currentSchemaVersion)
        XCTAssertEqual(shell?["policy_origin"] as? String, "user_disabled")
        XCTAssertEqual(shell?["default_timeout_sec"] as? Int, 37)
        XCTAssertNotNil(shell?["runtimes"] as? [String: Any])

        app.config.reload()
        XCTAssertEqual(app.config.bool("manager", "auto_restart", default: true), false)
        XCTAssertEqual(app.config.int("dashboard", "refresh_interval_sec", default: 8), 12)
        XCTAssertFalse(app.config.model.shell.enabled)
        XCTAssertTrue(app.config.model.shell.userDisabled)
        XCTAssertEqual(app.config.model.shell.policyOrigin, "user_disabled")

        let reenabled = try node.updateSettings(
            ManagerSettingsPatch(shellEnabled: true),
            apply: false
        )
        XCTAssertTrue(reenabled.shellEnabled)
        XCTAssertFalse(reenabled.shellUserDisabled)
        XCTAssertEqual(reenabled.shellPolicyOrigin, "user_enabled")
        app.config.reload()
        XCTAssertTrue(app.config.model.shell.enabled)
        XCTAssertFalse(app.config.model.shell.userDisabled)
    }

    func testManagerRestartAPI() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 19_000...28_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()
        Thread.sleep(forTimeInterval: 0.15)

        let restarted = try node.restartService()
        XCTAssertEqual(restarted.state, .running)
        XCTAssertGreaterThanOrEqual(restarted.restartCount, 1)

        Thread.sleep(forTimeInterval: 0.2)
        let url = URL(string: "http://127.0.0.1:\(port)/api/manager/status")!
        let live = try HTTPTestHelpers.fetchJSON(url)
        XCTAssertEqual(live["service_active"] as? Bool, true)
    }

    func testDashboardClientAttachesToExistingManager() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let status = try await client.status()
        XCTAssertTrue(status.ok)
        XCTAssertTrue(status.serviceActive)
        XCTAssertEqual(status.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(status.dashboardPort, port)

        let settings = try await client.settings()
        XCTAssertEqual(settings.dashboardPort, port)
        XCTAssertEqual(settings.dashboardHost, "127.0.0.1")

        let allowedRoot = home.appendingPathComponent("client-project", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        let canonicalAllowedRoot = try XCTUnwrap(
            ManagerSettingsNormalizer.canonicalAllowedRoot(allowedRoot.path)
        )
        let updated = try await client.updateSettings(
            ManagerSettingsPatch(
                dashboardRefreshSec: 11,
                allowedRoots: [allowedRoot.path]
            ),
            apply: false
        )
        XCTAssertEqual(updated.dashboardRefreshSec, 11)
        XCTAssertEqual(updated.allowedRoots, [canonicalAllowedRoot])
        XCTAssertEqual(app.config.model.allowedRoots, [canonicalAllowedRoot])
    }

    func testDashboardClientRemoteRestartReturnsCompleteDecodedStatus() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let restarted = try await client.restartService()

        XCTAssertTrue(restarted.ok)
        XCTAssertEqual(restarted.state, .running)
        XCTAssertTrue(restarted.serviceActive)
        XCTAssertEqual(restarted.dashboardPort, port)
        XCTAssertGreaterThanOrEqual(restarted.restartCount, 1)
        let live = try await client.status()
        XCTAssertEqual(live.state, .running)
        XCTAssertEqual(live.dashboardPort, port)
        _ = node
    }

    func testManagerMutationDeadlinesCoverEveryBoundedServerTransition() {
        let postTeardownSettingsMaximum =
            ManagerNode.listenerReplacementPauseSeconds
            + ConfigStore.configurationLockTimeoutSeconds
            + (2 * DashboardServer.bindTimeoutSeconds)
        XCTAssertGreaterThan(
            DashboardServer.gracefulResponseDrainTimeoutSeconds,
            postTeardownSettingsMaximum,
            "The old response connection must outlive the complete rollback path"
        )
        XCTAssertGreaterThan(
            ManagerDashboardClient.lifecycleMutationRequestTimeoutSeconds,
            ManagerNode.lifecycleTransitionWaitTimeoutSeconds
                + ConfigStore.configurationLockTimeoutSeconds
                + ManagerNode.listenerReplacementPauseSeconds
                + DashboardServer.bindTimeoutSeconds
        )
        XCTAssertGreaterThan(
            ManagerDashboardClient.settingsMutationRequestTimeoutSeconds,
            ManagerNode.lifecycleTransitionWaitTimeoutSeconds
                + (2 * ConfigStore.configurationLockTimeoutSeconds)
                + ManagerNode.listenerReplacementPauseSeconds
                + (2 * DashboardServer.bindTimeoutSeconds)
        )
        XCTAssertEqual(ManagerDashboardClient.ordinaryRequestTimeoutSeconds, 2)
    }

    func testDashboardClientDelayedRestartSerializesWatchdogAndReturnsDecodedStatus() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        _ = try node.startService()
        _ = try node.updateSettings(
            ManagerSettingsPatch(watchdogIntervalSec: 1),
            apply: true
        )

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let before = try await client.status()
        let holder = try Self.startExternalConfigLockHolder(
            paths: app.paths,
            holdSeconds: ManagerDashboardClient.ordinaryRequestTimeoutSeconds + 1.25
        )
        defer { Self.finishExternalConfigLockHolder(holder) }

        let startedAt = Date()
        async let pendingRestart = client.restartService()
        let restartingDeadline = Date().addingTimeInterval(1)
        while node.statusModel().state != .restarting, Date() < restartingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(node.statusModel().state, .restarting)

        let busyStartedAt = Date()
        XCTAssertThrowsError(try node.stopService()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("stop was not started"),
                "The bounded contention error must identify the rejected operation: \(error)"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(busyStartedAt),
            ManagerNode.lifecycleTransitionWaitTimeoutSeconds + 0.5
        )

        let restarted = try await pendingRestart
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertGreaterThan(
            elapsed,
            ManagerDashboardClient.ordinaryRequestTimeoutSeconds,
            "This production loopback response must exceed the ordinary request deadline"
        )
        XCTAssertLessThan(elapsed, ManagerDashboardClient.lifecycleMutationRequestTimeoutSeconds)
        XCTAssertEqual(restarted.state, .running)
        XCTAssertTrue(restarted.serviceActive)
        XCTAssertEqual(restarted.restartCount, before.restartCount + 1)
        let live = try await client.status()
        XCTAssertEqual(live.state, .running)
        XCTAssertEqual(live.restartCount, restarted.restartCount)
    }

    func testDashboardClientDelayedStartMovesEndpointAndReturnsDecodedStatus() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let oldPort = try Self.availableLoopbackPort()
        let newPort = try Self.availableLoopbackPort(excluding: [oldPort])
        try app.config.update(["dashboard": ["port": oldPort] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        _ = try node.startService()
        let oldClient = ManagerDashboardClient(
            host: "127.0.0.1",
            port: oldPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        _ = try await oldClient.stopService()
        let staged = try await oldClient.updateSettings(
            ManagerSettingsPatch(dashboardPort: newPort),
            apply: false
        )
        XCTAssertEqual(staged.dashboardPort, newPort)

        let holder = try Self.startExternalConfigLockHolder(
            paths: app.paths,
            holdSeconds: ManagerDashboardClient.ordinaryRequestTimeoutSeconds + 1.25
        )
        defer { Self.finishExternalConfigLockHolder(holder) }
        let startedAt = Date()
        let started = try await oldClient.startService()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThan(elapsed, ManagerDashboardClient.ordinaryRequestTimeoutSeconds)
        XCTAssertLessThan(elapsed, ManagerDashboardClient.lifecycleMutationRequestTimeoutSeconds)
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.dashboardPort, newPort)
        let newClient = ManagerDashboardClient(
            host: "127.0.0.1",
            port: newPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let live = try await newClient.status()
        XCTAssertEqual(live.state, .running)
        XCTAssertEqual(live.dashboardPort, newPort)
    }

    func testDashboardClientBindChangeReturnsCompleteResponseAndCommittedEndpointTakesOwnership() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let oldPort = try Self.availableLoopbackPort()
        let newPort = try Self.availableLoopbackPort(excluding: [oldPort])
        try app.config.update(["dashboard": ["port": oldPort] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        let oldClient = ManagerDashboardClient(
            host: "127.0.0.1",
            port: oldPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let committed = try await oldClient.updateSettings(
            ManagerSettingsPatch(
                dashboardPort: newPort,
                dashboardRefreshSec: 17
            ),
            apply: true
        )

        XCTAssertEqual(committed.dashboardHost, "127.0.0.1")
        XCTAssertEqual(committed.dashboardPort, newPort)
        XCTAssertEqual(committed.dashboardRefreshSec, 17)
        XCTAssertEqual(app.config.model.dashboard.port, newPort)
        let committedClient = ManagerDashboardClient(
            host: committed.dashboardHost,
            port: committed.dashboardPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let live = try await committedClient.status()
        XCTAssertEqual(live.state, .running)
        XCTAssertTrue(live.serviceActive)
        XCTAssertEqual(live.dashboardPort, newPort)
        _ = node
    }

    func testDashboardSettingsPUTBindChangeReturnsCompleteResponseOnNewEndpoint() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let oldPort = try Self.availableLoopbackPort()
        let newPort = try Self.availableLoopbackPort(excluding: [oldPort])
        try app.config.update(["dashboard": ["port": oldPort] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        var request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(oldPort)/api/manager/settings")
            )
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(try ManagerControlCredentialStore(paths: app.paths).bearerToken())",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONSupport.data(from: [
            "settings": [
                "dashboard": ["port": newPort] as [String: Any],
            ] as [String: Any],
            "apply": true,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let committed = try ManagerSettings(dictionary: JSONSupport.object(from: data))
        XCTAssertEqual(committed.dashboardPort, newPort)
        let newClient = ManagerDashboardClient(
            host: committed.dashboardHost,
            port: committed.dashboardPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let live = try await newClient.status()
        XCTAssertEqual(live.dashboardPort, newPort)
        _ = node
    }

    func testDashboardClientBindChangeMovesControlPlaneWhileServiceRemainsStopped() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let oldPort = try Self.availableLoopbackPort()
        let newPort = try Self.availableLoopbackPort(excluding: [oldPort])
        try app.config.update(["dashboard": ["port": oldPort] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        let oldClient = ManagerDashboardClient(
            host: "127.0.0.1",
            port: oldPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let stopped = try await oldClient.stopService()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.desiredRunning)

        let committed = try await oldClient.updateSettings(
            ManagerSettingsPatch(dashboardPort: newPort),
            apply: true
        )
        XCTAssertEqual(committed.dashboardPort, newPort)
        let newClient = ManagerDashboardClient(
            host: committed.dashboardHost,
            port: committed.dashboardPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let live = try await newClient.status()
        XCTAssertEqual(live.state, .stopped)
        XCTAssertFalse(live.desiredRunning)
        XCTAssertTrue(live.httpListening)
        XCTAssertFalse(live.serviceActive)
        XCTAssertEqual(live.dashboardPort, newPort)
        _ = node
    }

    func testDashboardClientFailedBindReturnsServerErrorAndRestoresOldEndpoint() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let oldPort = try Self.availableLoopbackPort()
        let occupied = try Self.makeOccupiedLoopbackPort(excluding: [oldPort])
        defer { Darwin.close(occupied.descriptor) }
        try app.config.update(["dashboard": ["port": oldPort] as [String: Any]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()

        let oldClient = ManagerDashboardClient(
            host: "127.0.0.1",
            port: oldPort,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let holder = try Self.startExternalConfigLockHolder(
            paths: app.paths,
            holdSeconds: ManagerDashboardClient.ordinaryRequestTimeoutSeconds + 1.25
        )
        defer { Self.finishExternalConfigLockHolder(holder) }
        let startedAt = Date()
        do {
            _ = try await oldClient.updateSettings(
                ManagerSettingsPatch(
                    dashboardPort: occupied.port,
                    dashboardRefreshSec: 23
                ),
                apply: true
            )
            XCTFail("An occupied replacement endpoint must be rejected")
        } catch let error as ManagerDashboardClient.ClientError {
            guard case .rejected(let status, let message) = error else {
                return XCTFail("Expected a decoded HTTP rejection, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Expected a real HTTP server error rather than transport loss: \(error)")
        }
        XCTAssertGreaterThan(
            Date().timeIntervalSince(startedAt),
            ManagerDashboardClient.ordinaryRequestTimeoutSeconds,
            "The decoded failure must survive a settings lock delay beyond the ordinary deadline"
        )

        let restored = try await oldClient.status()
        XCTAssertEqual(restored.state, .running)
        XCTAssertTrue(restored.serviceActive)
        XCTAssertEqual(restored.dashboardHost, "127.0.0.1")
        XCTAssertEqual(restored.dashboardPort, oldPort)
        app.config.reload()
        XCTAssertEqual(app.config.model.dashboard.host, "127.0.0.1")
        XCTAssertEqual(app.config.model.dashboard.port, oldPort)
        XCTAssertEqual(
            app.config.model.dashboard.refreshIntervalSec,
            23,
            "A safe unrelated setting from the same patch must remain committed"
        )
        _ = node
    }

    func testManagerRegistrationInfersHTTPIdentityAndRejectsExistingControlledRepositoryBeforeAliasPublication() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let original = home.appendingPathComponent("register-original", isDirectory: true)
        let replacement = home.appendingPathComponent("register-replacement", isDirectory: true)
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/register.git", to: directory)
        }
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        let registered = try node.registerProject(path: original.path)
        let projectID = try XCTUnwrap(registered["project_id"] as? String)
        let descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        let identity = try XCTUnwrap(descriptor.repositoryIdentity)
        let before = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(try XCTUnwrap(UUID(uuidString: projectID))))
        )

        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))
        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/projects/register")
        )
        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        func request(repositoryIdentity: String) throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONSupport.data(from: [
                "path": replacement.path,
                "repository_identity": repositoryIdentity,
            ])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            return try HTTPTestHelpers.fetch(request)
        }

        let (forgedData, forgedResponse) = try request(
            repositoryIdentity: "git:" + String(repeating: "0", count: 64)
        )
        XCTAssertEqual(forgedResponse.statusCode, 409)
        XCTAssertEqual(
            try JSONSupport.object(from: forgedData)["code"] as? String,
            ProjectMemoryError.projectScopeMismatch.code
        )

        let (matchingData, matchingResponse) = try request(repositoryIdentity: identity)
        XCTAssertEqual(matchingResponse.statusCode, 409)
        XCTAssertEqual(
            try JSONSupport.object(from: matchingData)["code"] as? String,
            ProjectContextError.projectRelinkRequired(before.projectID).code
        )
        let after = try XCTUnwrap(try app.projectContexts.project(before.projectID))
        XCTAssertEqual(after.canonicalRoot, before.canonicalRoot)
        XCTAssertEqual(after.generation, before.generation)
        let finalDescriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        XCTAssertFalse(finalDescriptor.aliases.contains(replacement.standardizedFileURL.path))
    }

    func testFCProjectBootstrapAuthorityHTTPRegistrationCannotMintUnapprovedBindingOrRunScope() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        let approvedRoot = home.appendingPathComponent("approved-roots", isDirectory: true)
        let approvedProject = approvedRoot.appendingPathComponent(
            "approved-project",
            isDirectory: true
        )
        let unapprovedProject = home.appendingPathComponent(
            "unapproved-project",
            isDirectory: true
        )
        for directory in [approvedProject, unapprovedProject] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try app.config.update([
            "dashboard": ["port": port] as [String: Any],
            "allowed_roots": [approvedRoot.path],
        ], save: true)
        let canonicalApprovedRoot = try XCTUnwrap(
            ManagerSettingsNormalizer.canonicalAllowedRoot(approvedRoot.path)
        )
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            node.shutdownManagedAutonomy()
            app.shutdown()
        }
        _ = try node.recoverManagedAutonomy()
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))

        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        func post(
            _ endpoint: String,
            object: [String: Any]
        ) throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(port)\(endpoint)")
            ))
            request.httpMethod = "POST"
            request.httpBody = try JSONSupport.data(from: object)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            return try HTTPTestHelpers.fetch(request)
        }

        let (registrationData, registrationResponse) = try post(
            "/api/manager/projects/register",
            object: ["path": unapprovedProject.path]
        )
        XCTAssertEqual(registrationResponse.statusCode, 200)
        let registration = try JSONSupport.object(from: registrationData)
        let projectIDValue = try XCTUnwrap(registration["project_id"] as? String)
        let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: projectIDValue)))
        let generationValue = try XCTUnwrap(
            (registration["project_generation"] as? NSNumber)?.uint64Value
        )
        let generation = ProjectGeneration(generationValue)
        XCTAssertEqual(app.config.model.allowedRoots, [canonicalApprovedRoot])
        XCTAssertEqual(
            try app.projectContexts.project(projectID)?.canonicalRoot,
            unapprovedProject.resolvingSymlinksInPath().standardizedFileURL
        )

        let bindingOwner = ProjectBindingOwner(
            kind: .mcpClient,
            id: "unapproved-http-binding"
        )
        let (bindingData, bindingResponse) = try post(
            "/api/manager/projects/bind",
            object: [
                "project_id": projectID.description,
                "project_generation": generation.rawValue,
                "owner_kind": bindingOwner.kind.rawValue,
                "owner_id": bindingOwner.id,
                "allowed_tools": ["shell_exec"],
            ]
        )
        XCTAssertEqual(bindingResponse.statusCode, 403)
        XCTAssertEqual(
            try JSONSupport.object(from: bindingData)["code"] as? String,
            ProjectContextError.projectRootNotAuthorized(unapprovedProject).code
        )
        let rejectedBinding = try await app.projectContexts.repository.binding(
            for: bindingOwner,
            includeInactive: true
        )
        XCTAssertNil(rejectedBinding)

        let rejectedRunID = RunID()
        let (runData, runResponse) = try post(
            "/api/manager/runs/start",
            object: [
                "run_id": rejectedRunID.description,
                "project_id": projectID.description,
                "project_generation": generation.rawValue,
                "mission": "This unapproved project must not receive runtime authority",
                "provider_id": "lmstudio",
                "adapter_id": ManagerNode.nativeSessionHostAdapterID,
                "model_key": "fixture/model",
                "allowed_tools": ["shell_exec"],
                "completion_gates": ["fixture_gate"],
            ]
        )
        XCTAssertEqual(runResponse.statusCode, 403)
        XCTAssertEqual(
            try JSONSupport.object(from: runData)["code"] as? String,
            ProjectContextError.projectRootNotAuthorized(unapprovedProject).code
        )
        let rejectedRun = try await app.projectContexts.repository.autonomousRun(rejectedRunID)
        XCTAssertNil(rejectedRun)
        let rejectedRunBinding = try await app.projectContexts.repository.binding(
            for: ProjectBindingOwner(
                kind: .autonomousRun,
                id: rejectedRunID.description
            ),
            includeInactive: true
        )
        XCTAssertNil(rejectedRunBinding)

        let (approvedRegistrationData, approvedRegistrationResponse) = try post(
            "/api/manager/projects/register",
            object: ["path": approvedProject.path]
        )
        XCTAssertEqual(approvedRegistrationResponse.statusCode, 200)
        let approvedRegistration = try JSONSupport.object(from: approvedRegistrationData)
        let approvedProjectID = try XCTUnwrap(
            approvedRegistration["project_id"] as? String
        )
        let approvedGeneration = try XCTUnwrap(
            (approvedRegistration["project_generation"] as? NSNumber)?.uint64Value
        )
        let (approvedBindingData, approvedBindingResponse) = try post(
            "/api/manager/projects/bind",
            object: [
                "project_id": approvedProjectID,
                "project_generation": approvedGeneration,
                "owner_kind": ProjectBindingOwnerKind.mcpClient.rawValue,
                "owner_id": "approved-http-binding",
                "allowed_tools": ["shell_exec"],
            ]
        )
        XCTAssertEqual(approvedBindingResponse.statusCode, 200)
        XCTAssertEqual(
            try JSONSupport.object(from: approvedBindingData)["authorization_roots"] as? [String],
            [approvedProject.resolvingSymlinksInPath().standardizedFileURL.path]
        )
    }

    func testMCPRegistrationTreatsRepositoryIdentityAsAssertionAndRequiresRelinkBeforePublication() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent(
            "mcp-register-assertion-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "mcp-register-assertion-replacement",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote(
                "ssh://git@example.test/team/mcp-register-assertion.git",
                to: directory
            )
        }
        _ = try app.config.update(["allowed_roots": [home.path]], save: false)
        let registered = try ManagerNode(app: app).registerProject(path: original.path)
        let projectID = try XCTUnwrap(registered["project_id"] as? String)
        let controlBefore = try XCTUnwrap(
            try app.projectContexts.project(
                ProjectID(try XCTUnwrap(UUID(uuidString: projectID)))
            )
        )
        let descriptorBefore = try app.projectMemory.identities.descriptor(
            projectID: projectID
        )
        let inferredIdentity = try XCTUnwrap(descriptorBefore.repositoryIdentity)
        let clientID = ClientID("mcp-registration-assertion")

        let forged = try app.tools.call(
            name: "project_memory.initialize",
            arguments: [
                "project_path": replacement.path,
                "repository_identity": "git:" + String(repeating: "0", count: 64),
            ],
            clientID: clientID
        )
        XCTAssertFalse(forged.ok)
        XCTAssertEqual(forged.payload["code"] as? String, ProjectMemoryError.projectScopeMismatch.code)

        let matching = try app.tools.call(
            name: "project_memory.initialize",
            arguments: [
                "project_path": replacement.path,
                "repository_identity": inferredIdentity,
            ],
            clientID: clientID
        )
        XCTAssertFalse(matching.ok)
        XCTAssertEqual(
            matching.payload["code"] as? String,
            ProjectContextError.projectRelinkRequired(controlBefore.projectID).code
        )
        let controlAfter = try XCTUnwrap(
            try app.projectContexts.project(controlBefore.projectID)
        )
        XCTAssertEqual(controlAfter.canonicalRoot, controlBefore.canonicalRoot)
        XCTAssertEqual(controlAfter.generation, controlBefore.generation)
        let descriptorAfter = try app.projectMemory.identities.descriptor(projectID: projectID)
        XCTAssertFalse(descriptorAfter.aliases.contains(replacement.standardizedFileURL.path))
        XCTAssertThrowsError(try app.projectContexts.invocationContext(for: clientID)) {
            guard case ProjectContextError.projectContextRequired = $0 else {
                return XCTFail("Rejected bootstrap must not bind the MCP client: \($0)")
            }
        }
    }

    func testManagerRegistrationProjectsPreControlIntentAfterFullRestart() throws {
        let projectRoot = home.appendingPathComponent(
            "register-intent-only-restart",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try writeGitRemote(
            "ssh://git@example.test/team/register-intent-only-restart.git",
            to: projectRoot
        )
        let displayName = "Intent-only restart"
        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        let target = try XCTUnwrap(firstApp).projectMemory.identities.discoverTarget(
            path: projectRoot.path
        )
        let repositoryIdentity = try XCTUnwrap(target.repositoryIdentity)
        let expected = try XCTUnwrap(firstApp).projectContexts.prepareControlledRegistration(
            identities: try XCTUnwrap(firstApp).projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: displayName
        )
        let expectedID = try XCTUnwrap(UUID(uuidString: expected.descriptor.id))
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRegistrationCheckpoint: { checkpoint in
                if case .identityIntentStaged = checkpoint {
                    throw ManagerProjectRegistrationInterruption.simulatedProcessExit(
                        checkpoint
                    )
                }
            }
        )

        XCTAssertThrowsError(try XCTUnwrap(firstNode).registerProjectResult(
            path: projectRoot.path,
            displayName: displayName,
            repositoryIdentity: repositoryIdentity
        )) { error in
            guard case ManagerProjectRegistrationInterruption.simulatedProcessExit(
                .identityIntentStaged
            ) = error else {
                return XCTFail("Expected the post-intent registration boundary, got \(error)")
            }
        }
        XCTAssertNil(try XCTUnwrap(firstApp).projectContexts.project(ProjectID(expectedID)))
        XCTAssertThrowsError(try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
            projectID: expected.descriptor.id
        ))
        let retained = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectMemory.identities.pendingRegistration(
                projectID: expected.descriptor.id
            )
        )
        XCTAssertEqual(retained.preparation.operationID, expected.operationID)

        let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
        XCTAssertFalse(firstSnapshot.projects.contains {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        })
        let firstPending = try XCTUnwrap(firstSnapshot.pendingProjectRegistrations.first {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        })
        XCTAssertEqual(firstPending.state, "reconciliation_required")
        XCTAssertEqual(firstPending.requestPath, projectRoot.path)
        XCTAssertEqual(firstPending.requestedDisplayName, displayName)
        XCTAssertEqual(firstPending.repositoryIdentityAssertion, repositoryIdentity)
        XCTAssertEqual(firstPending.operationID, expected.operationID)
        let encodedPending = try XCTUnwrap(
            try firstSnapshot.asDictionary()["pending_project_registrations"]
                as? [[String: Any]]
        )
        XCTAssertEqual(encodedPending.count, 1)
        XCTAssertEqual(encodedPending[0]["project_id"] as? String, expected.descriptor.id)
        XCTAssertEqual(encodedPending[0]["request_path"] as? String, projectRoot.path)
        XCTAssertEqual(encodedPending[0]["operation_id"] as? String, expected.operationID)

        _ = try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let restartedNode = ManagerNode(app: restartedApp)
        let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertFalse(restartedSnapshot.projects.contains {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        })
        let durable = try XCTUnwrap(restartedSnapshot.pendingProjectRegistrations.first {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        })
        XCTAssertEqual(durable, firstPending)

        let committed = try restartedNode.registerProjectResult(
            path: durable.requestPath,
            displayName: durable.requestedDisplayName,
            repositoryIdentity: durable.repositoryIdentityAssertion
        )
        XCTAssertEqual(committed.registrationState, .committed)
        XCTAssertFalse(committed.reconciled)
        XCTAssertEqual(committed.projectID, expected.descriptor.id)
        XCTAssertEqual(committed.displayName, displayName)
        XCTAssertEqual(committed.canonicalRoot, target.canonicalRoot.path)
        XCTAssertEqual(committed.projectGeneration, ProjectGeneration.initial.rawValue)
        XCTAssertEqual(committed.lifecycleState, ProjectLifecycleState.active.rawValue)
        XCTAssertEqual(committed.requestPath, durable.requestPath)
        XCTAssertEqual(committed.requestedDisplayName, durable.requestedDisplayName)
        XCTAssertEqual(
            committed.repositoryIdentityAssertion,
            durable.repositoryIdentityAssertion
        )
        XCTAssertNil(try restartedApp.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))
        let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertFalse(finalSnapshot.pendingProjectRegistrations.contains {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        })
        let active = try XCTUnwrap(
            try restartedApp.projectContexts.project(ProjectID(expectedID))
        )
        XCTAssertEqual(active.lifecycleState, .active)
        XCTAssertEqual(active.generation, .initial)
    }

    func testManagerRegistrationRecoversControlAcceptanceBeforeIdentityPublicationWithExactID() throws {
        let projectRoot = home.appendingPathComponent(
            "register-control-accepted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try writeGitRemote("ssh://git@example.test/team/register-crash.git", to: projectRoot)
        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        let target = try XCTUnwrap(firstApp).projectMemory.identities.discoverTarget(
            path: projectRoot.path
        )
        let expected = try XCTUnwrap(firstApp).projectContexts.prepareControlledRegistration(
            identities: try XCTUnwrap(firstApp).projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: "Crash-safe registration"
        )
        let expectedID = try XCTUnwrap(UUID(uuidString: expected.descriptor.id))
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRegistrationCheckpoint: { checkpoint in
                if case .controlPlaneAccepted = checkpoint {
                    throw ManagerProjectRegistrationInterruption.simulatedProcessExit(
                        checkpoint
                    )
                }
            }
        )

        XCTAssertThrowsError(try firstNode?.registerProject(
            path: projectRoot.path,
            displayName: "Crash-safe registration"
        )) { error in
            guard case ManagerProjectRegistrationInterruption.simulatedProcessExit(
                .controlPlaneAccepted
            ) = error else {
                return XCTFail("Expected the post-control acceptance crash boundary, got \(error)")
            }
        }
        let committed = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectContexts.project(ProjectID(expectedID))
        )
        XCTAssertEqual(committed.canonicalRoot, target.canonicalRoot)
        XCTAssertEqual(committed.generation, .initial)
        XCTAssertEqual(committed.lifecycleState, .maintenance)
        try assertExternalProcessCannotUseMaintenanceGeneration(
            projectID: expectedID,
            generation: ProjectGeneration.initial.rawValue,
            canonicalRoot: target.canonicalRoot
        )
        XCTAssertThrowsError(
            try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
                projectID: expected.descriptor.id
            )
        )
        firstNode = nil
        try XCTUnwrap(firstApp).shutdown()
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let replay = try ManagerNode(app: restartedApp).registerProject(
            path: projectRoot.path,
            displayName: "Crash-safe registration"
        )
        XCTAssertEqual(replay["project_id"] as? String, expected.descriptor.id)
        let published = try restartedApp.projectMemory.identities.descriptor(
            projectID: expected.descriptor.id
        )
        XCTAssertEqual(published.repositoryIdentity, target.repositoryIdentity)
        XCTAssertEqual(
            published.aliases.filter { $0 == target.canonicalRoot.path }.count,
            1
        )
        let recoveredControl = try XCTUnwrap(
            try restartedApp.projectContexts.project(ProjectID(expectedID))
        )
        XCTAssertEqual(recoveredControl.generation, .initial)
        XCTAssertEqual(recoveredControl.canonicalRoot, target.canonicalRoot)
        XCTAssertEqual(recoveredControl.lifecycleState, .active)
    }

    func testManagerRegistrationReturnsPendingAndRestartReplaysExactDurableRequestAtBothCommitBoundaries() async throws {
        for interruptAfterIdentityPublication in [false, true] {
            let suffix = interruptAfterIdentityPublication ? "identity" : "control"
            let projectRoot = home.appendingPathComponent(
                "register-pending-\(suffix)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: true
            )
            try writeGitRemote(
                "ssh://git@example.test/team/register-pending-\(suffix).git",
                to: projectRoot
            )
            var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
            var firstNode: ManagerNode? = ManagerNode(
                app: try XCTUnwrap(firstApp),
                projectRegistrationCheckpoint: { checkpoint in
                    switch checkpoint {
                    case .controlPlaneAccepted where !interruptAfterIdentityPublication:
                        throw NSError(
                            domain: "ManagerTests.RegistrationPending",
                            code: 1
                        )
                    case .identityPublished where interruptAfterIdentityPublication:
                        throw NSError(
                            domain: "ManagerTests.RegistrationPending",
                            code: 2
                        )
                    default:
                        break
                    }
                }
            )

            let pending = try XCTUnwrap(firstNode).registerProjectResult(
                path: projectRoot.path,
                displayName: "Pending \(suffix)"
            )
            XCTAssertEqual(pending.registrationState, .reconciliationRequired)
            XCTAssertEqual(pending.requestPath, projectRoot.path)
            XCTAssertEqual(pending.requestedDisplayName, "Pending \(suffix)")
            XCTAssertEqual(pending.lifecycleState, ProjectLifecycleState.maintenance.rawValue)
            let projectID = try XCTUnwrap(pending.projectID)
            let projectUUID = try XCTUnwrap(UUID(uuidString: projectID))
            let staged = try XCTUnwrap(
                try XCTUnwrap(firstApp).projectContexts.project(ProjectID(projectUUID))
            )
            XCTAssertEqual(staged.generation, .initial)
            XCTAssertEqual(staged.lifecycleState, .maintenance)
            XCTAssertTrue(try XCTUnwrap(firstApp).projectMemory.identities.pendingRegistration(
                projectID: projectID
            ) != nil)
            if interruptAfterIdentityPublication {
                let descriptor = try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
                    projectID: projectID
                )
                XCTAssertEqual(
                    descriptor.aliases.filter {
                        $0 == projectRoot.standardizedFileURL.path
                    }.count,
                    1
                )
            } else {
                XCTAssertThrowsError(try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
                    projectID: projectID
                ))
            }
            try assertExternalProcessCannotUseMaintenanceGeneration(
                projectID: projectUUID,
                generation: ProjectGeneration.initial.rawValue,
                canonicalRoot: projectRoot
            )
            let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
            let firstProject = try XCTUnwrap(firstSnapshot.projects.first {
                $0.projectID.caseInsensitiveCompare(projectID) == .orderedSame
            })
            let firstTransition = try XCTUnwrap(firstProject.pendingTransition)
            XCTAssertEqual(firstTransition.kind, "registration")
            XCTAssertEqual(firstTransition.state, "reconciliation_required")
            XCTAssertEqual(firstTransition.requestPath, projectRoot.path)
            XCTAssertEqual(firstTransition.requestedDisplayName, "Pending \(suffix)")

            firstNode = nil
            try XCTUnwrap(firstApp).shutdown()
            firstApp = nil

            let restartedApp = try ForgeApp.bootstrap(home: home)
            let restartedNode = ManagerNode(app: restartedApp)
            let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
            let restartedProject = try XCTUnwrap(restartedSnapshot.projects.first {
                $0.projectID.caseInsensitiveCompare(projectID) == .orderedSame
            })
            let durable = try XCTUnwrap(restartedProject.pendingTransition)
            XCTAssertEqual(durable.operationID, firstTransition.operationID)
            XCTAssertEqual(durable.requestPath, firstTransition.requestPath)
            XCTAssertEqual(durable.requestedDisplayName, firstTransition.requestedDisplayName)

            let committed = try restartedNode.registerProjectResult(
                path: durable.requestPath,
                displayName: durable.requestedDisplayName,
                repositoryIdentity: durable.repositoryIdentityAssertion
            )
            XCTAssertEqual(committed.registrationState, .committed)
            XCTAssertTrue(committed.reconciled)
            XCTAssertEqual(committed.projectID, projectID)
            XCTAssertEqual(committed.projectGeneration, ProjectGeneration.initial.rawValue)
            XCTAssertEqual(committed.lifecycleState, ProjectLifecycleState.active.rawValue)
            let active = try XCTUnwrap(
                try restartedApp.projectContexts.project(ProjectID(projectUUID))
            )
            XCTAssertEqual(active.lifecycleState, .active)
            XCTAssertEqual(active.generation, .initial)
            let descriptor = try restartedApp.projectMemory.identities.descriptor(
                projectID: projectID
            )
            XCTAssertEqual(
                descriptor.aliases.filter { $0 == projectRoot.standardizedFileURL.path }.count,
                1
            )
            XCTAssertNil(try restartedApp.projectMemory.identities.pendingRegistration(
                projectID: projectID
            ))
            let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
            XCTAssertNil(finalSnapshot.projects.first {
                $0.projectID.caseInsensitiveCompare(projectID) == .orderedSame
            }?.pendingTransition)
            let allEvents = try await restartedApp.projectContexts.repository.operatorAutonomyEvents(
                limit: 101
            )
            let events = allEvents.filter { $0.projectID == ProjectID(projectUUID) }
            XCTAssertEqual(events.filter { $0.eventType == "project_registration_staged" }.count, 1)
            XCTAssertEqual(events.filter { $0.eventType == "project_registration_published" }.count, 1)
            restartedApp.shutdown()
        }
    }

    func testManagerRegistrationExactRestartRetryAfterActivationBeforeIntentCleanup() async throws {
        let projectRoot = home.appendingPathComponent(
            "register-post-activation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try writeGitRemote(
            "ssh://git@example.test/team/register-post-activation.git",
            to: projectRoot
        )

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        let target = try XCTUnwrap(firstApp).projectMemory.identities.discoverTarget(
            path: projectRoot.path
        )
        let expected = try XCTUnwrap(firstApp).projectContexts.prepareControlledRegistration(
            identities: try XCTUnwrap(firstApp).projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: "Post-activation registration"
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: expected.descriptor.id))
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRegistrationCheckpoint: { checkpoint in
                if case .controlPlaneActivated = checkpoint {
                    throw ManagerProjectRegistrationInterruption.simulatedProcessExit(checkpoint)
                }
            }
        )

        XCTAssertThrowsError(try XCTUnwrap(firstNode).registerProjectResult(
            path: projectRoot.path,
            displayName: "Post-activation registration"
        )) { error in
            guard case ManagerProjectRegistrationInterruption.simulatedProcessExit(
                .controlPlaneActivated
            ) = error else {
                return XCTFail("Expected a post-activation interruption, received \(error)")
            }
        }
        let activeBeforeRestart = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(activeBeforeRestart.lifecycleState, .active)
        XCTAssertEqual(activeBeforeRestart.generation, .initial)
        let retainedBeforeRestart = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectMemory.identities.pendingRegistration(
                projectID: expected.descriptor.id
            )
        )
        XCTAssertEqual(retainedBeforeRestart.preparation.operationID, expected.operationID)
        let publishedBeforeRestart = try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
            projectID: expected.descriptor.id
        )
        XCTAssertEqual(
            publishedBeforeRestart.aliases.filter {
                $0 == projectRoot.standardizedFileURL.path
            }.count,
            1
        )
        let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
        let firstTransition = try XCTUnwrap(firstSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(firstTransition.kind, "registration")
        XCTAssertEqual(firstTransition.operationID, expected.operationID)
        XCTAssertEqual(firstTransition.requestPath, projectRoot.path)

        try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let restartedNode = ManagerNode(app: restartedApp)
        let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        let durableTransition = try XCTUnwrap(restartedSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(durableTransition.operationID, expected.operationID)
        XCTAssertEqual(durableTransition.requestPath, firstTransition.requestPath)
        XCTAssertEqual(
            durableTransition.requestedDisplayName,
            firstTransition.requestedDisplayName
        )

        let committed = try restartedNode.registerProjectResult(
            path: durableTransition.requestPath,
            displayName: durableTransition.requestedDisplayName,
            repositoryIdentity: durableTransition.repositoryIdentityAssertion
        )
        XCTAssertEqual(committed.registrationState, .committed)
        XCTAssertTrue(committed.reconciled)
        XCTAssertEqual(committed.projectID, expected.descriptor.id)
        XCTAssertEqual(committed.projectGeneration, ProjectGeneration.initial.rawValue)
        XCTAssertEqual(committed.lifecycleState, ProjectLifecycleState.active.rawValue)
        XCTAssertNil(try restartedApp.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))
        let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertNil(finalSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(expected.descriptor.id) == .orderedSame
        }?.pendingTransition)
        let allEvents = try await restartedApp.projectContexts.repository.operatorAutonomyEvents(
            limit: 101
        )
        let events = allEvents.filter { $0.projectID == ProjectID(projectUUID) }
        XCTAssertEqual(events.filter { $0.eventType == "project_registration_staged" }.count, 1)
        XCTAssertEqual(events.filter { $0.eventType == "project_registration_published" }.count, 1)
        let authorityCounts = try await restartedApp.projectContexts.repository
            .projectTransitionAuthorityCountsForTesting(projectID: ProjectID(projectUUID))
        XCTAssertEqual(authorityCounts.staged, 0)
        XCTAssertEqual(authorityCounts.published, 1)
        XCTAssertEqual(authorityCounts.total, 1)
    }

    func testPendingRegistrationIntentFencesRelinkUntilExactReplay() throws {
        let original = home.appendingPathComponent(
            "register-pending-relink-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "register-pending-relink-replacement",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writeGitRemote(
                "ssh://git@example.test/team/register-pending-relink.git",
                to: directory
            )
        }

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let displayName = "Pending registration relink fence"
        let target = try app.projectMemory.identities.discoverTarget(path: original.path)
        let expected = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: displayName
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: expected.descriptor.id))
        let projectID = ProjectID(projectUUID)
        let interruptedNode = ManagerNode(
            app: app,
            projectRegistrationCheckpoint: { checkpoint in
                if case .controlPlaneActivated = checkpoint {
                    throw ManagerProjectRegistrationInterruption.simulatedProcessExit(checkpoint)
                }
            }
        )

        XCTAssertThrowsError(try interruptedNode.registerProjectResult(
            path: original.path,
            displayName: displayName
        )) { error in
            guard case ManagerProjectRegistrationInterruption.simulatedProcessExit(
                .controlPlaneActivated
            ) = error else {
                return XCTFail("Expected a post-activation interruption, received \(error)")
            }
        }

        let manager = ManagerNode(app: app)
        let controlBefore = try XCTUnwrap(try app.projectContexts.project(projectID))
        let descriptorBefore = try app.projectMemory.identities.descriptor(
            projectID: expected.descriptor.id
        )
        XCTAssertEqual(controlBefore.lifecycleState, .active)
        XCTAssertEqual(controlBefore.generation, .initial)
        XCTAssertNotNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))

        XCTAssertThrowsError(try manager.relinkProject(
            projectID: projectID,
            expectedGeneration: .initial,
            path: replacement.path
        )) { error in
            XCTAssertEqual(
                error as? ProjectContextError,
                .projectTransitionConflict(projectID)
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(try app.projectContexts.project(projectID)),
            controlBefore
        )
        XCTAssertEqual(
            try app.projectMemory.identities.descriptor(projectID: expected.descriptor.id),
            descriptorBefore
        )
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: expected.descriptor.id
        ))
        XCTAssertNotNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))

        let replay = try manager.registerProjectResult(
            path: original.path,
            displayName: displayName
        )
        XCTAssertEqual(replay.registrationState, .committed)
        XCTAssertTrue(replay.reconciled)
        XCTAssertEqual(replay.projectID, expected.descriptor.id)
        XCTAssertNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))

        let relinked = try manager.relinkProject(
            projectID: projectID,
            expectedGeneration: .initial,
            path: replacement.path
        )
        XCTAssertFalse(relinked.reconciled)
        XCTAssertEqual(relinked.priorGeneration, ProjectGeneration.initial.rawValue)
        XCTAssertEqual(relinked.newGeneration, ProjectGeneration.initial.rawValue + 1)
        XCTAssertEqual(relinked.canonicalRoot, replacement.standardizedFileURL.path)
        let controlAfter = try XCTUnwrap(try app.projectContexts.project(projectID))
        XCTAssertEqual(controlAfter.lifecycleState, .active)
        XCTAssertEqual(
            controlAfter.generation,
            ProjectGeneration(ProjectGeneration.initial.rawValue + 1)
        )
        XCTAssertEqual(controlAfter.canonicalRoot, replacement.standardizedFileURL)
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: expected.descriptor.id
        ))
    }

    func testPendingRegistrationIntentFencesResetUntilExactReplay() throws {
        let projectRoot = home.appendingPathComponent(
            "register-pending-reset",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try writeGitRemote(
            "ssh://git@example.test/team/register-pending-reset.git",
            to: projectRoot
        )

        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let displayName = "Pending registration reset fence"
        let target = try app.projectMemory.identities.discoverTarget(path: projectRoot.path)
        let expected = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: displayName
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: expected.descriptor.id))
        let projectID = ProjectID(projectUUID)
        let interruptedNode = ManagerNode(
            app: app,
            projectRegistrationCheckpoint: { checkpoint in
                if case .controlPlaneActivated = checkpoint {
                    throw ManagerProjectRegistrationInterruption.simulatedProcessExit(checkpoint)
                }
            }
        )

        XCTAssertThrowsError(try interruptedNode.registerProjectResult(
            path: projectRoot.path,
            displayName: displayName
        )) { error in
            guard case ManagerProjectRegistrationInterruption.simulatedProcessExit(
                .controlPlaneActivated
            ) = error else {
                return XCTFail("Expected a post-activation interruption, received \(error)")
            }
        }

        let manager = ManagerNode(app: app)
        let controlBefore = try XCTUnwrap(try app.projectContexts.project(projectID))
        let descriptorBefore = try app.projectMemory.identities.descriptor(
            projectID: expected.descriptor.id
        )
        XCTAssertEqual(controlBefore.lifecycleState, .active)
        XCTAssertEqual(controlBefore.generation, .initial)
        XCTAssertNotNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))

        XCTAssertThrowsError(try manager.resetProjectGeneration(
            projectID: projectID,
            expectedGeneration: .initial
        )) { error in
            XCTAssertEqual(
                error as? ProjectContextError,
                .projectTransitionConflict(projectID)
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(try app.projectContexts.project(projectID)),
            controlBefore
        )
        XCTAssertEqual(
            try app.projectMemory.identities.descriptor(projectID: expected.descriptor.id),
            descriptorBefore
        )
        XCTAssertNotNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))

        let replay = try manager.registerProjectResult(
            path: projectRoot.path,
            displayName: displayName
        )
        XCTAssertEqual(replay.registrationState, .committed)
        XCTAssertTrue(replay.reconciled)
        XCTAssertEqual(replay.projectID, expected.descriptor.id)
        XCTAssertNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))

        let reset = try manager.resetProjectGeneration(
            projectID: projectID,
            expectedGeneration: .initial
        )
        XCTAssertEqual(
            reset["prior_generation"] as? UInt64,
            ProjectGeneration.initial.rawValue
        )
        XCTAssertEqual(
            reset["new_generation"] as? UInt64,
            ProjectGeneration.initial.rawValue + 1
        )
        let controlAfter = try XCTUnwrap(try app.projectContexts.project(projectID))
        XCTAssertEqual(controlAfter.lifecycleState, .active)
        XCTAssertEqual(
            controlAfter.generation,
            ProjectGeneration(ProjectGeneration.initial.rawValue + 1)
        )
        XCTAssertEqual(controlAfter.canonicalRoot, projectRoot.standardizedFileURL)
        XCTAssertNil(try app.projectMemory.identities.pendingRegistration(
            projectID: expected.descriptor.id
        ))
    }

    func testConcurrentExactManagerRegistrationsConvergeToOnePublishedIdentity() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent(
            "register-concurrent-exact",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        try writeGitRemote(
            "ssh://git@example.test/team/register-concurrent-exact.git",
            to: projectRoot
        )

        let preflightBarrier = ManagerConcurrentRegistrationBarrier()
        let firstNode = ManagerNode(
            app: app,
            projectRegistrationCheckpoint: { checkpoint in
                if case .targetCaptured = checkpoint {
                    try preflightBarrier.arriveAndWait()
                }
            }
        )
        let secondNode = ManagerNode(
            app: app,
            projectRegistrationCheckpoint: { checkpoint in
                if case .targetCaptured = checkpoint {
                    try preflightBarrier.arriveAndWait()
                }
            }
        )
        let results = try await withThrowingTaskGroup(
            of: ManagerProjectRegistrationResult.self,
            returning: [ManagerProjectRegistrationResult].self
        ) { group in
            group.addTask {
                try firstNode.registerProjectResult(
                    path: projectRoot.path,
                    displayName: "Concurrent exact registration"
                )
            }
            group.addTask {
                try secondNode.registerProjectResult(
                    path: projectRoot.path,
                    displayName: "Concurrent exact registration"
                )
            }
            var completed: [ManagerProjectRegistrationResult] = []
            completed.reserveCapacity(2)
            for try await result in group {
                completed.append(result)
            }
            return completed
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.registrationState == .committed })
        let reference = try XCTUnwrap(results.first)
        XCTAssertTrue(results.allSatisfy { result in
            result.registrationState == reference.registrationState
                && result.projectID == reference.projectID
                && result.displayName == reference.displayName
                && result.canonicalRoot == reference.canonicalRoot
                && result.projectGeneration == reference.projectGeneration
                && result.lifecycleState == reference.lifecycleState
                && result.requestPath == reference.requestPath
                && result.requestedDisplayName == reference.requestedDisplayName
                && result.repositoryIdentityAssertion
                    == reference.repositoryIdentityAssertion
                && result.code == reference.code
                && result.message == reference.message
        })
        XCTAssertEqual(
            results.map(\.reconciled).sorted { !$0 && $1 },
            [false, true]
        )
        let projectIDs = Set(results.compactMap(\.projectID))
        XCTAssertEqual(projectIDs.count, 1)
        let projectID = try XCTUnwrap(projectIDs.first)
        let projectUUID = try XCTUnwrap(UUID(uuidString: projectID))
        XCTAssertTrue(results.allSatisfy { result in
            result.projectID == projectID
                && result.displayName == "Concurrent exact registration"
                && result.canonicalRoot == projectRoot.standardizedFileURL.path
                && result.projectGeneration == ProjectGeneration.initial.rawValue
                && result.lifecycleState == ProjectLifecycleState.active.rawValue
                && result.requestPath == projectRoot.path
                && result.requestedDisplayName == "Concurrent exact registration"
                && result.repositoryIdentityAssertion == nil
                && result.code == nil
                && result.message == nil
        })

        let active = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(active.generation, .initial)
        XCTAssertEqual(active.lifecycleState, .active)
        XCTAssertEqual(active.displayName, "Concurrent exact registration")
        XCTAssertEqual(active.canonicalRoot, projectRoot.standardizedFileURL)
        let descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        XCTAssertEqual(descriptor.id.caseInsensitiveCompare(projectID), .orderedSame)
        XCTAssertEqual(descriptor.displayName, "Concurrent exact registration")
        XCTAssertEqual(
            descriptor.aliases.filter { $0 == projectRoot.standardizedFileURL.path }.count,
            1
        )
        XCTAssertNil(try app.projectMemory.identities.pendingRegistration(
            projectID: projectID
        ))

        let allEvents = try await app.projectContexts.repository.operatorAutonomyEvents(
            limit: 101
        )
        let events = allEvents.filter { $0.projectID == ProjectID(projectUUID) }
        XCTAssertEqual(events.filter { $0.eventType == "project_registration_staged" }.count, 1)
        XCTAssertEqual(events.filter { $0.eventType == "project_registration_published" }.count, 1)
        let authorityCounts = try await app.projectContexts.repository
            .projectTransitionAuthorityCountsForTesting(projectID: ProjectID(projectUUID))
        XCTAssertEqual(authorityCounts.staged, 0)
        XCTAssertEqual(authorityCounts.published, 1)
        XCTAssertEqual(authorityCounts.total, 1)

        let snapshot = try firstNode.operatorSnapshot(limit: 100)
        let project = try XCTUnwrap(snapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(projectID) == .orderedSame
        })
        XCTAssertNil(project.pendingTransition)
    }

    func testManagerAndMCPRegistrationFenceTheExactPublishedControlProjectID() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let managerRoot = home.appendingPathComponent("register-fence-manager", isDirectory: true)
        let mcpRoot = home.appendingPathComponent("register-fence-mcp", isDirectory: true)
        for directory in [managerRoot, mcpRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeGitRemote("ssh://git@example.test/team/fence-manager.git", to: managerRoot)
        try writeGitRemote("ssh://git@example.test/team/fence-mcp.git", to: mcpRoot)
        _ = try app.config.update(["allowed_roots": [home.path]], save: false)

        let managerTarget = try app.projectMemory.identities.discoverTarget(path: managerRoot.path)
        let managerPreparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: managerTarget,
            requestedProjectID: nil,
            displayName: nil
        )
        let managerProjectID = try XCTUnwrap(UUID(uuidString: managerPreparation.descriptor.id))
        let managerTransaction = try retainFilesystemAuthority(
            paths: app.paths,
            projectID: ProjectID(managerProjectID),
            root: managerRoot
        )
        XCTAssertThrowsError(try ManagerNode(app: app).registerProject(path: managerRoot.path)) {
            XCTAssertEqual(
                $0 as? ProjectContextError,
                .retainedFilesystemRecovery(ProjectID(managerProjectID))
            )
        }
        XCTAssertNil(try app.projectContexts.project(ProjectID(managerProjectID)))
        XCTAssertThrowsError(try app.projectMemory.identities.descriptor(
            projectID: managerPreparation.descriptor.id
        ))
        XCTAssertTrue(try SecureFilesystemRecoveryLedger(paths: app.paths).remove(
            transactionID: managerTransaction
        ))
        let managerRegistered = try ManagerNode(app: app).registerProject(path: managerRoot.path)
        XCTAssertEqual(
            managerRegistered["project_id"] as? String,
            managerPreparation.descriptor.id
        )

        let mcpTarget = try app.projectMemory.identities.discoverTarget(path: mcpRoot.path)
        let mcpPreparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: mcpTarget,
            requestedProjectID: nil,
            displayName: nil
        )
        let mcpProjectID = try XCTUnwrap(UUID(uuidString: mcpPreparation.descriptor.id))
        let mcpTransaction = try retainFilesystemAuthority(
            paths: app.paths,
            projectID: ProjectID(mcpProjectID),
            root: mcpRoot
        )
        let clientID = ClientID("registration-fence-mcp")
        let blocked = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": mcpRoot.path],
            clientID: clientID
        )
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(
            blocked.payload["code"] as? String,
            ProjectContextError.retainedFilesystemRecovery(ProjectID(mcpProjectID)).code
        )
        XCTAssertNil(try app.projectContexts.project(ProjectID(mcpProjectID)))
        XCTAssertThrowsError(try app.projectMemory.identities.descriptor(
            projectID: mcpPreparation.descriptor.id
        ))
        XCTAssertTrue(try SecureFilesystemRecoveryLedger(paths: app.paths).remove(
            transactionID: mcpTransaction
        ))
        let initialized = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": mcpRoot.path],
            clientID: clientID
        )
        XCTAssertTrue(initialized.ok, "\(initialized.payload)")
        XCTAssertEqual(initialized.payload["project_id"] as? String, mcpPreparation.descriptor.id)
        let mcpControl = try XCTUnwrap(try app.projectContexts.project(ProjectID(mcpProjectID)))
        XCTAssertEqual(mcpControl.canonicalRoot, mcpTarget.canonicalRoot)
        let mcpDescriptor = try app.projectMemory.identities.descriptor(
            projectID: mcpPreparation.descriptor.id
        )
        XCTAssertTrue(mcpDescriptor.aliases.contains(mcpTarget.canonicalRoot.path))
    }

    func testExistingGenerationRegistrationFencesExactLiveGenerationForManagerAndMCP() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent(
            "registration-generation-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "registration-generation-current",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote(
                "ssh://git@example.test/team/registration-generation.git",
                to: directory
            )
        }
        _ = try app.config.update(["allowed_roots": [home.path]], save: false)
        let manager = ManagerNode(app: app)
        let registered = try manager.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let initialGeneration = try XCTUnwrap(
            registered["project_generation"] as? UInt64
        )
        let relink = try manager.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(initialGeneration),
            path: replacement.path
        )
        let liveGeneration = ProjectGeneration(relink.newGeneration)
        XCTAssertGreaterThan(liveGeneration.rawValue, ProjectGeneration.initial.rawValue)
        let controlBefore = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        let descriptorBefore = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        let transactionID = try retainFilesystemAuthority(
            paths: app.paths,
            projectID: ProjectID(projectUUID),
            generation: liveGeneration,
            root: replacement
        )
        defer {
            _ = try? SecureFilesystemRecoveryLedger(paths: app.paths).remove(
                transactionID: transactionID
            )
        }

        XCTAssertThrowsError(try manager.registerProject(
            path: replacement.path,
            displayName: "Must Not Mutate"
        )) {
            XCTAssertEqual(
                $0 as? ProjectContextError,
                .retainedFilesystemRecovery(ProjectID(projectUUID))
            )
        }
        let clientID = ClientID("registration-live-generation-mcp")
        let blocked = try app.tools.call(
            name: "project_memory.initialize",
            arguments: ["project_path": replacement.path],
            clientID: clientID
        )
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(
            blocked.payload["code"] as? String,
            ProjectContextError.retainedFilesystemRecovery(ProjectID(projectUUID)).code
        )
        XCTAssertThrowsError(try app.projectContexts.invocationContext(for: clientID)) {
            guard case ProjectContextError.projectContextRequired = $0 else {
                return XCTFail("Blocked registration must not bind the MCP client: \($0)")
            }
        }
        let controlAfter = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(controlAfter, controlBefore)
        let descriptorAfter = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(descriptorAfter, descriptorBefore)
    }

    func testRegistrationGenerationChangeAfterPreparationFailsClosed() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent(
            "registration-generation-change",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try writeGitRemote(
            "ssh://git@example.test/team/registration-generation-change.git",
            to: projectRoot
        )
        let manager = ManagerNode(app: app)
        let registered = try manager.registerProject(path: projectRoot.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = ProjectGeneration(try XCTUnwrap(
            registered["project_generation"] as? UInt64
        ))
        let descriptorBefore = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        let target = try app.projectMemory.identities.discoverTarget(path: projectRoot.path)
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: projectUUID.uuidString.lowercased(),
            displayName: "Stale Prepared Display Name"
        )
        XCTAssertEqual(preparation.expectedControlGeneration, generation)

        let reset = try manager.resetProjectGeneration(
            projectID: ProjectID(projectUUID),
            expectedGeneration: generation
        )
        let advancedGeneration = try XCTUnwrap(reset["new_generation"] as? UInt64)
        XCTAssertEqual(advancedGeneration, generation.rawValue + 1)

        XCTAssertThrowsError(try app.projectContexts.validateControlledRegistration(
            preparation,
            identities: app.projectMemory.identities,
            requestedProjectID: projectUUID.uuidString.lowercased(),
            displayName: "Stale Prepared Display Name"
        )) {
            guard case ProjectMemoryError.conflict = $0 else {
                return XCTFail("Generation drift must invalidate the captured preparation: \($0)")
            }
        }
        XCTAssertThrowsError(try app.projectContexts.registerProject(
            preparation: preparation
        )) {
            guard case ProjectContextError.staleProjectGeneration(
                let expected,
                let actual
            ) = $0 else {
                return XCTFail("The control-plane write must compare the captured generation: \($0)")
            }
            XCTAssertEqual(expected, generation)
            XCTAssertEqual(actual, ProjectGeneration(advancedGeneration))
        }
        let control = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(control.generation, ProjectGeneration(advancedGeneration))
        XCTAssertEqual(control.canonicalRoot, projectRoot.standardizedFileURL)
        let descriptorAfter = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(descriptorAfter, descriptorBefore)
    }

    func testMCPBootstrapRecoversControlAcceptanceBeforeRegistryPublication() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent(
            "mcp-register-control-accepted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try writeGitRemote("ssh://git@example.test/team/mcp-register-crash.git", to: projectRoot)
        _ = try app.config.update(["allowed_roots": [home.path]], save: false)
        let target = try app.projectMemory.identities.discoverTarget(path: projectRoot.path)
        let repositoryIdentity = try XCTUnwrap(target.repositoryIdentity)
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: "MCP recovered registration"
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: preparation.descriptor.id))
        let accepted = try app.projectContexts.registerProject(preparation: preparation)
        XCTAssertEqual(accepted.projectID, ProjectID(projectUUID))
        XCTAssertEqual(accepted.lifecycleState, .maintenance)
        try assertExternalProcessCannotUseMaintenanceGeneration(
            projectID: projectUUID,
            generation: ProjectGeneration.initial.rawValue,
            canonicalRoot: target.canonicalRoot
        )
        XCTAssertThrowsError(try app.projectMemory.identities.descriptor(
            projectID: preparation.descriptor.id
        ))

        let clientID = ClientID("mcp-registration-crash-replay")
        let replay = try app.tools.call(
            name: "project_memory.initialize",
            arguments: [
                "project_path": projectRoot.path,
                "display_name": "MCP recovered registration",
                "repository_identity": repositoryIdentity,
            ],
            clientID: clientID
        )
        XCTAssertTrue(replay.ok, "\(replay.payload)")
        XCTAssertEqual(replay.payload["project_id"] as? String, preparation.descriptor.id)
        XCTAssertEqual(replay.payload["project_context_attached"] as? Bool, true)
        let context = try app.projectContexts.invocationContext(for: clientID)
        XCTAssertEqual(context.projectID, ProjectID(projectUUID))
        XCTAssertEqual(context.projectGeneration, .initial)
        XCTAssertEqual(context.authorizationScope.canonicalRoots, [target.canonicalRoot])
        let activated = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(activated.lifecycleState, .active)
        let published = try app.projectMemory.identities.descriptor(
            projectID: preparation.descriptor.id
        )
        XCTAssertEqual(published.repositoryIdentity, target.repositoryIdentity)
        XCTAssertEqual(
            published.aliases.filter { $0 == target.canonicalRoot.path }.count,
            1
        )
    }

    @available(*, deprecated, message: "Exercises the fail-closed compatibility facade")
    func testDeprecatedProjectContextMutationFacadesRemainSourceCompatibleAndFailClosed() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent(
            "compatibility-facade-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "compatibility-facade-replacement",
            isDirectory: true
        )
        let unregistered = home.appendingPathComponent(
            "compatibility-facade-unregistered",
            isDirectory: true
        )
        for directory in [original, replacement, unregistered] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeGitRemote("ssh://git@example.test/team/compatibility.git", to: original)
        try writeGitRemote("ssh://git@example.test/team/compatibility.git", to: replacement)
        let registered = try ManagerNode(app: app).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let forgedID = ProjectID()
        let descriptor = ProjectMemoryDescriptor(
            id: forgedID.description,
            displayName: "Legacy compatibility caller",
            repositoryIdentity: "git:" + String(repeating: "0", count: 64),
            aliases: [unregistered.path]
        )
        let unregisteredTarget = try app.projectMemory.identities.discoverTarget(
            path: unregistered.path
        )
        let unregisteredPreparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: unregisteredTarget,
            requestedProjectID: nil,
            displayName: nil
        )

        XCTAssertThrowsError(try app.projectMemory.initialize(
            path: unregistered.path
        )) {
            XCTAssertEqual(
                $0 as? ProjectContextError,
                .projectTransitionCoordinatorRequired
            )
        }
        let directPack = try XCTUnwrap(try ProjectMemoryToolPack().handle(
            name: "project_memory.initialize",
            arguments: ["project_path": unregistered.path],
            context: nil,
            clientID: ClientID("legacy-direct-pack-client"),
            app: app,
            cancellation: nil
        ))
        XCTAssertFalse(directPack.ok)
        XCTAssertEqual(
            directPack.payload["code"] as? String,
            "project_registration_coordinator_required"
        )
        XCTAssertEqual(directPack.payload["retryable"] as? Bool, false)
        XCTAssertNil(try app.projectContexts.project(forgedID))
        XCTAssertThrowsError(try app.projectMemory.identities.descriptor(
            projectID: unregisteredPreparation.descriptor.id
        ))

        XCTAssertThrowsError(try app.projectContexts.registerProject(
            descriptor: descriptor,
            canonicalRoot: unregistered
        )) {
            XCTAssertEqual(
                $0 as? ProjectContextError,
                .projectTransitionCoordinatorRequired
            )
        }
        XCTAssertThrowsError(try app.projectContexts.registerAndBindMCPClient(
            descriptor: descriptor,
            canonicalRoot: unregistered,
            clientID: ClientID("legacy-registration-client")
        )) {
            XCTAssertEqual(
                $0 as? ProjectContextError,
                .projectTransitionCoordinatorRequired
            )
        }
        XCTAssertNil(try app.projectContexts.project(forgedID))

        do {
            _ = try await app.projectContexts.repository.registerProject(
                projectID: forgedID,
                displayName: descriptor.displayName,
                canonicalRoot: unregistered,
                repositoryFingerprint: descriptor.repositoryIdentity
            )
            XCTFail("The deprecated raw repository registration facade must fail closed")
        } catch let error as ProjectContextError {
            XCTAssertEqual(error, .projectTransitionCoordinatorRequired)
        }
        XCTAssertNil(try app.projectContexts.project(forgedID))

        XCTAssertThrowsError(try app.projectContexts.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            newCanonicalRoot: replacement,
            repositoryFingerprint: "git:" + String(repeating: "1", count: 64)
        )) {
            XCTAssertEqual(
                $0 as? ProjectContextError,
                .projectTransitionCoordinatorRequired
            )
        }
        do {
            _ = try await app.projectContexts.repository.relinkProject(
                projectID: ProjectID(projectUUID),
                expectedGeneration: ProjectGeneration(generation),
                newCanonicalRoot: replacement,
                repositoryFingerprint: "git:" + String(repeating: "1", count: 64)
            )
            XCTFail("The deprecated raw repository relink facade must fail closed")
        } catch let error as ProjectContextError {
            XCTAssertEqual(error, .projectTransitionCoordinatorRequired)
        }
        let control = try XCTUnwrap(try app.projectContexts.project(ProjectID(projectUUID)))
        XCTAssertEqual(control.generation, ProjectGeneration(generation))
        XCTAssertEqual(control.canonicalRoot, original.standardizedFileURL)
        let published = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(published.aliases.contains(replacement.standardizedFileURL.path))
    }

    func testManagerRelinkUsesOneCapturedTargetAcrossRawSymlinkNamespaceSwap() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent("relink-symlink-original", isDirectory: true)
        let accepted = home.appendingPathComponent("relink-symlink-accepted", isDirectory: true)
        let attacker = home.appendingPathComponent("relink-symlink-attacker", isDirectory: true)
        let selected = home.appendingPathComponent("relink-symlink-selected")
        for directory in [original, accepted, attacker] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeGitRemote("ssh://git@example.test/team/symlink.git", to: original)
        try writeGitRemote("ssh://git@example.test/team/symlink.git", to: accepted)
        try writeGitRemote("ssh://git@example.test/team/other.git", to: attacker)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: accepted)
        let initialNode = ManagerNode(app: app)
        let registered = try initialNode.registerProject(path: original.path)
        let projectID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let node = ManagerNode(app: app, projectRelinkCheckpoint: { checkpoint in
            if case .targetCaptured = checkpoint {
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.createSymbolicLink(
                    at: selected,
                    withDestinationURL: attacker
                )
            }
        })

        let receipt = try node.relinkProject(
            projectID: ProjectID(projectID),
            expectedGeneration: ProjectGeneration(generation),
            path: selected.path
        )
        XCTAssertEqual(receipt.canonicalRoot, accepted.standardizedFileURL.path)
        let control = try XCTUnwrap(try app.projectContexts.project(ProjectID(projectID)))
        XCTAssertEqual(control.canonicalRoot, accepted.standardizedFileURL)
        let descriptor = try app.projectMemory.identities.descriptor(
            projectID: projectID.uuidString.lowercased()
        )
        XCTAssertTrue(descriptor.aliases.contains(accepted.standardizedFileURL.path))
        XCTAssertFalse(descriptor.aliases.contains(attacker.standardizedFileURL.path))
    }

    func testManagerRelinkRejectsAtomicTargetSwapAfterTransactionValidation() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent("relink-swap-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-swap-target", isDirectory: true)
        let attacker = home.appendingPathComponent("relink-swap-attacker", isDirectory: true)
        for directory in [original, replacement, attacker] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeGitRemote("ssh://git@example.test/team/swap.git", to: original)
        try writeGitRemote("ssh://git@example.test/team/swap.git", to: replacement)
        try writeGitRemote("ssh://git@example.test/team/attacker.git", to: attacker)
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        await app.projectContexts.repository.configureOperationObservers(beforeCommit: {
            let result = replacement.path.withCString { acceptedPath in
                attacker.path.withCString { attackerPath in
                    Darwin.renamex_np(
                        acceptedPath,
                        attackerPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard result == 0 else {
                throw ProjectContextError.databaseFailure(
                    "atomic relink target exchange failed"
                )
            }
        })

        XCTAssertThrowsError(try node.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            XCTAssertEqual(
                error as? ProjectContextError,
                .projectRelinkTargetChanged(ProjectID(projectUUID))
            )
        }
        await app.projectContexts.repository.configureOperationObservers()
        let control = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(control.canonicalRoot, original.standardizedFileURL)
        XCTAssertEqual(control.generation, ProjectGeneration(generation))
        XCTAssertEqual(control.lifecycleState, .active)
        let descriptor = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(descriptor.aliases.contains(replacement.standardizedFileURL.path))
        XCTAssertFalse(descriptor.aliases.contains(attacker.standardizedFileURL.path))
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testManagerRegistrationRejectsAtomicTargetSwapBeforeControlAcceptance() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let selected = home.appendingPathComponent("register-swap-target", isDirectory: true)
        let attacker = home.appendingPathComponent("register-swap-attacker", isDirectory: true)
        for directory in [selected, attacker] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeGitRemote("ssh://git@example.test/team/register-swap.git", to: selected)
        try writeGitRemote("ssh://git@example.test/team/register-attacker.git", to: attacker)
        let target = try app.projectMemory.identities.discoverTarget(path: selected.path)
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: "Atomic registration swap"
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: preparation.descriptor.id))
        await app.projectContexts.repository.configureOperationObservers(beforeCommit: {
            let result = selected.path.withCString { selectedPath in
                attacker.path.withCString { attackerPath in
                    Darwin.renamex_np(
                        selectedPath,
                        attackerPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard result == 0 else {
                throw ProjectContextError.databaseFailure(
                    "atomic registration target exchange failed"
                )
            }
        })

        XCTAssertThrowsError(try ManagerNode(app: app).registerProject(
            path: selected.path,
            displayName: "Atomic registration swap"
        )) { error in
            XCTAssertEqual(
                error as? ProjectContextError,
                .projectRegistrationTargetChanged(ProjectID(projectUUID))
            )
        }
        await app.projectContexts.repository.configureOperationObservers()
        XCTAssertNil(try app.projectContexts.project(ProjectID(projectUUID)))
        XCTAssertThrowsError(try app.projectMemory.identities.descriptor(
            projectID: preparation.descriptor.id
        )) { error in
            XCTAssertEqual(error as? ProjectMemoryError, .projectNotFound(preparation.descriptor.id))
        }
    }

    func testProjectRelinkRouteIsProtectedBoundedIdentityVerifiedAndIdempotent() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let original = home.appendingPathComponent("relink-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-replacement", isDirectory: true)
        let mismatch = home.appendingPathComponent("relink-mismatch", isDirectory: true)
        let staleTarget = home.appendingPathComponent("relink-stale-target", isDirectory: true)
        for directory in [original, replacement, mismatch, staleTarget] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeGitRemote("ssh://git@example.test/team/forge.git", to: original)
        try writeGitRemote("ssh://git@example.test/team/forge.git", to: replacement)
        try writeGitRemote("ssh://git@example.test/team/forge.git", to: staleTarget)
        try writeGitRemote("ssh://git@example.test/other/forge.git", to: mismatch)

        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        let registered = try node.registerProject(path: original.path, displayName: "Relink Fixture")
        let projectID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))

        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/projects/relink")
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSupport.data(from: [
            "project_id": projectID.uuidString.lowercased(),
            "project_generation": generation,
            "path": replacement.path,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, unauthorized) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(unauthorized.statusCode, 401)

        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            repeating: UInt8(ascii: " "),
            count: ManagerRoutes.maximumProjectRelinkBodyBytes + 1
        )
        let (oversizedData, oversized) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(oversized.statusCode, 413)
        XCTAssertEqual(
            try JSONSupport.object(from: oversizedData)["code"] as? String,
            "project_relink_body_too_large"
        )

        request.httpBody = try JSONSupport.data(from: [
            "project_id": projectID.uuidString.lowercased(),
            "project_generation": generation,
            "path": "/" + String(
                repeating: "a",
                count: ManagerRoutes.maximumProjectRelinkPathBytes
            ),
        ])
        let (pathBoundData, pathBound) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(pathBound.statusCode, 400)
        XCTAssertEqual(
            try JSONSupport.object(from: pathBoundData)["code"] as? String,
            "invalid_project_relink"
        )

        request.httpBody = try JSONSupport.data(from: [
            "project_id": projectID.uuidString.lowercased(),
            "project_generation": generation,
            "path": replacement.path,
            "repository_identity": "git:caller-asserted",
        ])
        let (forgedData, forged) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(forged.statusCode, 400)
        XCTAssertEqual(
            try JSONSupport.object(from: forgedData)["code"] as? String,
            "invalid_project_relink"
        )

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        do {
            _ = try await client.relinkProject(
                projectID: projectID,
                expectedGeneration: generation,
                path: mismatch.path
            )
            XCTFail("A different Git remote identity must not relink")
        } catch let error as ManagerDashboardClient.ClientError {
            guard case .rejected(let status, _) = error else {
                return XCTFail("Expected a typed manager rejection, received \(error)")
            }
            XCTAssertEqual(status, 409)
        }

        let receipt = try await client.relinkProject(
            projectID: projectID,
            expectedGeneration: generation,
            path: replacement.path
        )
        XCTAssertEqual(receipt.projectID, projectID.uuidString.lowercased())
        XCTAssertEqual(receipt.canonicalRoot, replacement.standardizedFileURL.path)
        XCTAssertEqual(receipt.priorGeneration, generation)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        XCTAssertEqual(receipt.invalidatedBindingCount, 0)
        XCTAssertFalse(receipt.reconciled)

        let retry = try await client.relinkProject(
            projectID: projectID,
            expectedGeneration: generation,
            path: replacement.path
        )
        XCTAssertEqual(retry.canonicalRoot, receipt.canonicalRoot)
        XCTAssertEqual(retry.newGeneration, receipt.newGeneration)
        XCTAssertTrue(retry.reconciled)

        do {
            _ = try await client.relinkProject(
                projectID: projectID,
                expectedGeneration: generation,
                path: staleTarget.path
            )
            XCTFail("A stale generation must not add another relink target")
        } catch let error as ManagerDashboardClient.ClientError {
            guard case .rejected(let status, _) = error else {
                return XCTFail("Expected a stale-generation rejection, received \(error)")
            }
            XCTAssertEqual(status, 409)
        }

        let status = try node.projectStatus(projectID: ProjectID(projectID))
        XCTAssertEqual(status["canonical_root"] as? String, replacement.standardizedFileURL.path)
        XCTAssertEqual(status["project_generation"] as? UInt64, generation + 1)
        let descriptor = try ProjectIdentityResolver(paths: app.paths).descriptor(
            projectID: projectID.uuidString.lowercased()
        )
        XCTAssertEqual(
            descriptor.aliases.filter { $0 == replacement.standardizedFileURL.path }.count,
            1
        )
        XCTAssertFalse(descriptor.aliases.contains(staleTarget.standardizedFileURL.path))
    }

    func testManagerProjectRelinkBusyLeavesAliasAndGenerationUnchanged() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent("relink-busy-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-busy-replacement", isDirectory: true)
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/busy.git", to: directory)
        }
        _ = try app.config.update(["allowed_roots": [original.path]], save: false)
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        _ = try node.bindProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            owner: ProjectBindingOwner(kind: .mcpClient, id: "relink-busy-client")
        )

        XCTAssertThrowsError(try node.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            guard case ProjectContextError.projectRelinkBusy = error else {
                return XCTFail("Expected the manager-owned quiescence gate, received \(error)")
            }
        }

        let status = try node.projectStatus(projectID: ProjectID(projectUUID))
        XCTAssertEqual(status["canonical_root"] as? String, original.standardizedFileURL.path)
        XCTAssertEqual(status["project_generation"] as? UInt64, generation)
        let descriptor = try ProjectIdentityResolver(paths: app.paths).descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(descriptor.aliases.contains(replacement.standardizedFileURL.path))
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testManagerProjectRelinkControlPlaneConflictLeavesAliasAndGenerationUnchanged() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent("relink-conflict-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-conflict-replacement", isDirectory: true)
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/conflict.git", to: directory)
        }
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let originalControl = try XCTUnwrap(
            try app.projectContexts.project(ProjectID(projectUUID))
        )
        let conflictID = ProjectID()
        _ = try app.projectContexts.registerProjectUnchecked(
            descriptor: ProjectMemoryDescriptor(
                id: conflictID.description,
                displayName: "Relink Conflict Owner",
                repositoryIdentity: originalControl.repositoryFingerprint,
                aliases: [replacement.standardizedFileURL.path]
            ),
            canonicalRoot: replacement
        )

        XCTAssertThrowsError(try node.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            guard case ProjectContextError.projectRootAlreadyRegistered = error else {
                return XCTFail("Expected a control-plane root conflict, received \(error)")
            }
        }

        let status = try XCTUnwrap(try app.projectContexts.project(ProjectID(projectUUID)))
        XCTAssertEqual(status.canonicalRoot, original.standardizedFileURL)
        XCTAssertEqual(status.generation, ProjectGeneration(generation))
        let descriptor = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(descriptor.aliases.contains(replacement.standardizedFileURL.path))
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testManagerProjectRelinkReplaysStagedIdentityAfterRestart() throws {
        let original = home.appendingPathComponent("relink-stage-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-stage-replacement", isDirectory: true)
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/staged-restart.git", to: directory)
        }

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRelinkCheckpoint: { checkpoint in
            if case .identityStaged = checkpoint {
                throw ManagerProjectRelinkInterruption.simulatedProcessExit(checkpoint)
            }
        })
        let registered = try XCTUnwrap(firstNode).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)

        XCTAssertThrowsError(try XCTUnwrap(firstNode).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            guard case ManagerProjectRelinkInterruption.simulatedProcessExit(.identityStaged) = error else {
                return XCTFail("Expected a staged-identity interruption, received \(error)")
            }
        }
        let stagedControl = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(stagedControl.canonicalRoot, original.standardizedFileURL)
        XCTAssertEqual(stagedControl.generation, ProjectGeneration(generation))
        let stagedDescriptor = try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(stagedDescriptor.aliases.contains(replacement.standardizedFileURL.path))
        XCTAssertTrue(try XCTUnwrap(firstApp).projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
        let firstProject = try XCTUnwrap(firstSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        })
        let firstTransition = try XCTUnwrap(firstProject.pendingTransition)
        XCTAssertEqual(firstTransition.kind, "relink")
        XCTAssertEqual(firstTransition.state, "reconciliation_required")
        XCTAssertEqual(firstTransition.requestPath, replacement.standardizedFileURL.path)
        XCTAssertEqual(firstTransition.expectedGeneration, generation)
        try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let restartedNode = ManagerNode(app: restartedApp)
        let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        let restartedProject = try XCTUnwrap(restartedSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        })
        let durableTransition = try XCTUnwrap(restartedProject.pendingTransition)
        XCTAssertEqual(durableTransition.operationID, firstTransition.operationID)
        XCTAssertEqual(durableTransition.requestPath, firstTransition.requestPath)
        XCTAssertEqual(durableTransition.expectedGeneration, firstTransition.expectedGeneration)
        let receipt = try restartedNode.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(try XCTUnwrap(
                durableTransition.expectedGeneration
            )),
            path: durableTransition.requestPath
        )

        XCTAssertFalse(receipt.reconciled)
        XCTAssertEqual(receipt.priorGeneration, generation)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        let recoveredControl = try XCTUnwrap(
            try restartedApp.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(recoveredControl.canonicalRoot, replacement.standardizedFileURL)
        XCTAssertEqual(recoveredControl.generation, ProjectGeneration(generation + 1))
        let recoveredDescriptor = try restartedApp.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            recoveredDescriptor.aliases.filter {
                $0 == replacement.standardizedFileURL.path
            }.count,
            1
        )
        XCTAssertFalse(try restartedApp.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertNil(finalSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
    }

    func testManagerProjectRelinkReplacesAbandonedPreCASStageAfterRestart() throws {
        let original = home.appendingPathComponent("relink-abandoned-original", isDirectory: true)
        let abandoned = home.appendingPathComponent("relink-abandoned-target", isDirectory: true)
        let selected = home.appendingPathComponent("relink-new-target", isDirectory: true)
        for directory in [original, abandoned, selected] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/abandoned-stage.git", to: directory)
        }

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRelinkCheckpoint: { checkpoint in
            if case .identityStaged = checkpoint {
                throw ManagerProjectRelinkInterruption.simulatedProcessExit(checkpoint)
            }
        })
        let registered = try XCTUnwrap(firstNode).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        XCTAssertThrowsError(try XCTUnwrap(firstNode).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: abandoned.path
        ))
        XCTAssertTrue(try XCTUnwrap(firstApp).projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let receipt = try ManagerNode(app: restartedApp).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: selected.path
        )

        XCTAssertFalse(receipt.reconciled)
        XCTAssertEqual(receipt.canonicalRoot, selected.standardizedFileURL.path)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        let descriptor = try restartedApp.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(descriptor.aliases.contains(abandoned.standardizedFileURL.path))
        XCTAssertEqual(
            descriptor.aliases.filter { $0 == selected.standardizedFileURL.path }.count,
            1
        )
        XCTAssertFalse(try restartedApp.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testManagerProjectRelinkReconcilesControlPlaneCommitAfterRestart() throws {
        let original = home.appendingPathComponent("relink-commit-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-commit-replacement", isDirectory: true)
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/commit-restart.git", to: directory)
        }

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRelinkCheckpoint: { checkpoint in
            if case .controlPlaneCommitted = checkpoint {
                throw ManagerProjectRelinkInterruption.simulatedProcessExit(checkpoint)
            }
        })
        let registered = try XCTUnwrap(firstNode).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)

        XCTAssertThrowsError(try XCTUnwrap(firstNode).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            guard case ManagerProjectRelinkInterruption.simulatedProcessExit(.controlPlaneCommitted) = error else {
                return XCTFail("Expected a post-CAS interruption, received \(error)")
            }
        }
        let committedControl = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(committedControl.canonicalRoot, replacement.standardizedFileURL)
        XCTAssertEqual(committedControl.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(committedControl.lifecycleState, .maintenance)
        try assertExternalProcessCannotUseMaintenanceGeneration(
            projectID: projectUUID,
            generation: generation + 1,
            canonicalRoot: replacement
        )
        let unpublishedDescriptor = try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertFalse(unpublishedDescriptor.aliases.contains(replacement.standardizedFileURL.path))
        XCTAssertTrue(try XCTUnwrap(firstApp).projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
        let firstTransition = try XCTUnwrap(firstSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(firstTransition.kind, "relink")
        XCTAssertEqual(firstTransition.state, "reconciliation_required")
        XCTAssertEqual(firstTransition.requestPath, replacement.standardizedFileURL.path)
        XCTAssertEqual(firstTransition.expectedGeneration, generation)
        try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let restartedNode = ManagerNode(app: restartedApp)
        let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        let durableTransition = try XCTUnwrap(restartedSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(durableTransition.operationID, firstTransition.operationID)
        let receipt = try restartedNode.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(try XCTUnwrap(
                durableTransition.expectedGeneration
            )),
            path: durableTransition.requestPath
        )

        XCTAssertTrue(receipt.reconciled)
        XCTAssertEqual(receipt.priorGeneration, generation)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        let recoveredControl = try XCTUnwrap(
            try restartedApp.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(recoveredControl.canonicalRoot, replacement.standardizedFileURL)
        XCTAssertEqual(recoveredControl.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(recoveredControl.lifecycleState, .active)
        let recoveredDescriptor = try restartedApp.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            recoveredDescriptor.aliases.filter {
                $0 == replacement.standardizedFileURL.path
            }.count,
            1
        )
        XCTAssertFalse(try restartedApp.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertNil(finalSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
    }

    func testManagerProjectRelinkReconcilesPublishedAliasBeforeActivationAfterRestart() throws {
        let original = home.appendingPathComponent(
            "relink-published-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "relink-published-replacement",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writeGitRemote(
                "ssh://git@example.test/team/published-restart.git",
                to: directory
            )
        }

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRelinkCheckpoint: { checkpoint in
                if case .aliasPublished = checkpoint {
                    throw ManagerProjectRelinkInterruption.simulatedProcessExit(checkpoint)
                }
            }
        )
        let registered = try XCTUnwrap(firstNode).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)

        XCTAssertThrowsError(try XCTUnwrap(firstNode).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            guard case ManagerProjectRelinkInterruption.simulatedProcessExit(
                .aliasPublished
            ) = error else {
                return XCTFail("Expected a post-alias interruption, received \(error)")
            }
        }
        let fenced = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(fenced.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(fenced.canonicalRoot, replacement.standardizedFileURL)
        XCTAssertEqual(fenced.lifecycleState, .maintenance)
        let published = try XCTUnwrap(firstApp).projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            published.aliases.filter { $0 == replacement.standardizedFileURL.path }.count,
            1
        )
        XCTAssertTrue(try XCTUnwrap(firstApp).projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
        let firstTransition = try XCTUnwrap(firstSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(firstTransition.kind, "relink")
        XCTAssertEqual(firstTransition.requestPath, replacement.standardizedFileURL.path)
        XCTAssertEqual(firstTransition.expectedGeneration, generation)
        try assertExternalProcessCannotUseMaintenanceGeneration(
            projectID: projectUUID,
            generation: generation + 1,
            canonicalRoot: replacement
        )
        try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let restartedNode = ManagerNode(app: restartedApp)
        let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        let durableTransition = try XCTUnwrap(restartedSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(durableTransition.operationID, firstTransition.operationID)
        XCTAssertEqual(durableTransition.requestPath, firstTransition.requestPath)
        XCTAssertEqual(durableTransition.expectedGeneration, firstTransition.expectedGeneration)
        let receipt = try restartedNode.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(try XCTUnwrap(
                durableTransition.expectedGeneration
            )),
            path: durableTransition.requestPath
        )
        XCTAssertTrue(receipt.reconciled)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        let active = try XCTUnwrap(
            try restartedApp.projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(active.lifecycleState, .active)
        XCTAssertEqual(active.generation, ProjectGeneration(generation + 1))
        let recovered = try restartedApp.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            recovered.aliases.filter { $0 == replacement.standardizedFileURL.path }.count,
            1
        )
        XCTAssertFalse(try restartedApp.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertNil(finalSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
    }

    func testManagerProjectRelinkExactRestartRetryAfterActivationBeforeIntentCleanup() async throws {
        let original = home.appendingPathComponent(
            "relink-activated-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "relink-activated-replacement",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writeGitRemote(
                "ssh://git@example.test/team/activated-restart.git",
                to: directory
            )
        }

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var firstNode: ManagerNode? = ManagerNode(
            app: try XCTUnwrap(firstApp),
            projectRelinkCheckpoint: { checkpoint in
                if case .controlPlaneActivated = checkpoint {
                    throw ManagerProjectRelinkInterruption.simulatedProcessExit(checkpoint)
                }
            }
        )
        let registered = try XCTUnwrap(firstNode).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)

        XCTAssertThrowsError(try XCTUnwrap(firstNode).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacement.path
        )) { error in
            guard case ManagerProjectRelinkInterruption.simulatedProcessExit(
                .controlPlaneActivated
            ) = error else {
                return XCTFail("Expected a post-activation interruption, received \(error)")
            }
        }
        let activeBeforeRestart = try XCTUnwrap(
            try XCTUnwrap(firstApp).projectContexts.project(ProjectID(projectUUID))
        )
        XCTAssertEqual(activeBeforeRestart.lifecycleState, .active)
        XCTAssertEqual(activeBeforeRestart.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(activeBeforeRestart.canonicalRoot, replacement.standardizedFileURL)
        XCTAssertTrue(try XCTUnwrap(firstApp).projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let firstSnapshot = try XCTUnwrap(firstNode).operatorSnapshot(limit: 100)
        let firstTransition = try XCTUnwrap(firstSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(firstTransition.kind, "relink")
        XCTAssertEqual(firstTransition.requestPath, replacement.standardizedFileURL.path)
        XCTAssertEqual(firstTransition.expectedGeneration, generation)

        try XCTUnwrap(firstApp).shutdown()
        firstNode = nil
        firstApp = nil

        let restartedApp = try ForgeApp.bootstrap(home: home)
        defer { restartedApp.shutdown() }
        let restartedNode = ManagerNode(app: restartedApp)
        let restartedSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        let durableTransition = try XCTUnwrap(restartedSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        XCTAssertEqual(durableTransition.operationID, firstTransition.operationID)
        XCTAssertEqual(durableTransition.requestPath, firstTransition.requestPath)
        XCTAssertEqual(durableTransition.expectedGeneration, firstTransition.expectedGeneration)

        let receipt = try restartedNode.relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: ProjectGeneration(try XCTUnwrap(
                durableTransition.expectedGeneration
            )),
            path: durableTransition.requestPath
        )
        XCTAssertTrue(receipt.reconciled)
        XCTAssertEqual(receipt.priorGeneration, generation)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        XCTAssertEqual(receipt.canonicalRoot, replacement.standardizedFileURL.path)
        XCTAssertFalse(try restartedApp.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
        let finalSnapshot = try restartedNode.operatorSnapshot(limit: 100)
        XCTAssertNil(finalSnapshot.projects.first {
            $0.projectID.caseInsensitiveCompare(
                projectUUID.uuidString.lowercased()
            ) == .orderedSame
        }?.pendingTransition)
        let authorityCounts = try await restartedApp.projectContexts.repository
            .projectTransitionAuthorityCountsForTesting(projectID: ProjectID(projectUUID))
        XCTAssertEqual(authorityCounts.staged, 0)
        XCTAssertEqual(authorityCounts.published, 2)
        XCTAssertEqual(authorityCounts.total, 2)
    }

    func testRegistrationCannotConsumeRelinkMaintenanceBeforeOrAfterAliasPublication() throws {
        for aliasPublished in [false, true] {
            let scenarioHome = home.appendingPathComponent(
                aliasPublished ? "cross-path-post-alias" : "cross-path-pre-alias",
                isDirectory: true
            )
            let app = try ForgeApp.bootstrap(home: scenarioHome)
            _ = try app.config.update(
                ["allowed_roots": [scenarioHome.path]],
                save: false
            )
            let fixture = try stageRelinkTransition(
                app: app,
                root: scenarioHome,
                name: aliasPublished ? "post-alias" : "pre-alias"
            )
            if aliasPublished {
                _ = try app.projectMemory.identities.commitRelink(fixture.preparation)
            }
            let result = try app.tools.call(
                name: "project_memory.initialize",
                arguments: ["project_path": fixture.replacement.path],
                clientID: ClientID("cross-path-registration-\(aliasPublished)")
            )
            XCTAssertFalse(result.ok)
            XCTAssertEqual(
                result.payload["code"] as? String,
                ProjectContextError.projectTransitionConflict(fixture.projectID).code
            )
            let fenced = try XCTUnwrap(
                try app.projectContexts.project(fixture.projectID)
            )
            XCTAssertEqual(fenced.lifecycleState, .maintenance)
            XCTAssertEqual(
                fenced.generation,
                ProjectGeneration(fixture.expectedGeneration.rawValue + 1)
            )
            if !aliasPublished {
                let descriptor = try app.projectMemory.identities.descriptor(
                    projectID: fixture.projectID.description
                )
                XCTAssertFalse(
                    descriptor.aliases.contains(fixture.replacement.path)
                )
                _ = try app.projectMemory.identities.commitRelink(fixture.preparation)
            }
            let active = try app.projectContexts.finalizeRelink(
                projectID: fixture.projectID,
                priorGeneration: fixture.expectedGeneration,
                target: fixture.preparation.target,
                transitionOperationID: fixture.preparation.operationID
            )
            XCTAssertEqual(active.lifecycleState, .active)
            XCTAssertEqual(
                active.generation,
                ProjectGeneration(fixture.expectedGeneration.rawValue + 1)
            )
            XCTAssertThrowsError(try app.projectContexts.invocationContext(
                for: ClientID("cross-path-registration-\(aliasPublished)")
            ))
            app.shutdown()
        }
    }

    func testRelinkCannotConsumeRegistrationMaintenance() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent(
            "cross-path-registration-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "cross-path-registration-relink",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writeGitRemote(
                "ssh://git@example.test/team/cross-path-registration.git",
                to: directory
            )
        }
        let target = try app.projectMemory.identities.discoverTarget(path: original.path)
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: "Cross-path registration"
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: preparation.descriptor.id))
        let staged = try app.projectContexts.registerProject(preparation: preparation)
        XCTAssertEqual(staged.lifecycleState, .maintenance)
        XCTAssertThrowsError(try ManagerNode(app: app).relinkProject(
            projectID: ProjectID(projectUUID),
            expectedGeneration: .initial,
            path: replacement.path
        )) { error in
            XCTAssertEqual(
                error as? ProjectContextError,
                .projectNotActive(.maintenance)
            )
        }
        _ = try app.projectMemory.identities.commitRegistration(preparation)
        let active = try app.projectContexts.finalizeRegistration(
            preparation: preparation
        )
        XCTAssertEqual(active.lifecycleState, .active)
        XCTAssertEqual(active.generation, .initial)
    }

    func testRegistrationTransitionAuthorityRejectsStaleOperationAndThenConverges() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let root = home.appendingPathComponent(
            "registration-stale-operation",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeGitRemote(
            "ssh://git@example.test/team/registration-stale-operation.git",
            to: root
        )
        let target = try app.projectMemory.identities.discoverTarget(path: root.path)
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: "Registration operation fence"
        )
        let projectUUID = try XCTUnwrap(UUID(uuidString: preparation.descriptor.id))
        let projectID = ProjectID(projectUUID)
        let staged = try app.projectContexts.registerProject(preparation: preparation)
        XCTAssertEqual(staged.lifecycleState, .maintenance)
        _ = try app.projectMemory.identities.commitRegistration(preparation)
        do {
            _ = try await app.projectContexts.repository.finalizeRegistration(
                projectID: projectID,
                generation: .initial,
                target: target,
                transitionOperationID: String(repeating: "0", count: 64)
            )
            XCTFail("A stale registration operation must not activate maintenance")
        } catch let error as ProjectContextError {
            XCTAssertEqual(error, .projectTransitionConflict(projectID))
        }
        let stillFenced = try XCTUnwrap(try app.projectContexts.project(projectID))
        XCTAssertEqual(stillFenced.lifecycleState, .maintenance)
        let active = try app.projectContexts.finalizeRegistration(
            preparation: preparation
        )
        XCTAssertEqual(active.lifecycleState, .active)
        XCTAssertEqual(active.generation, .initial)
    }

    func testRelinkTransitionAuthorityIgnoresAuditNoiseAndRejectsMissingCorruptOrStaleAuthority() async throws {
        enum Adversary: String, CaseIterable {
            case unrelatedAuditEvent
            case duplicateStageAuditEvent
            case malformedStageAuditEvent
            case priorTerminalAuditEvent
            case missingAuthority
            case corruptAuthority
            case staleOperation

            var leavesAuthorityIntact: Bool {
                switch self {
                case .unrelatedAuditEvent, .duplicateStageAuditEvent,
                     .malformedStageAuditEvent, .priorTerminalAuditEvent:
                    true
                case .missingAuthority, .corruptAuthority, .staleOperation:
                    false
                }
            }
        }

        for adversary in Adversary.allCases {
            let scenarioHome = home.appendingPathComponent(
                "transition-authority-\(adversary.rawValue)",
                isDirectory: true
            )
            let app = try ForgeApp.bootstrap(home: scenarioHome)
            let fixture = try stageRelinkTransition(
                app: app,
                root: scenarioHome,
                name: adversary.rawValue
            )
            let metadata = projectTransitionMetadata(for: fixture.preparation)
            switch adversary {
            case .unrelatedAuditEvent:
                try await app.projectContexts.repository
                    .appendProjectTransitionEventForTesting(
                        projectID: fixture.projectID,
                        eventType: "unrelated_project_event",
                        metadata: metadata
                    )
            case .duplicateStageAuditEvent:
                try await app.projectContexts.repository
                    .appendProjectTransitionEventForTesting(
                        projectID: fixture.projectID,
                        eventType: "project_relink_staged",
                        metadata: metadata
                    )
            case .malformedStageAuditEvent:
                var malformed = metadata
                malformed["new_generation"] = "999"
                try await app.projectContexts.repository
                    .appendProjectTransitionEventForTesting(
                        projectID: fixture.projectID,
                        eventType: "project_relink_staged",
                        metadata: malformed
                    )
            case .priorTerminalAuditEvent:
                try await app.projectContexts.repository
                    .appendProjectTransitionEventForTesting(
                        projectID: fixture.projectID,
                        eventType: "project_relinked",
                        metadata: metadata
                    )
            case .missingAuthority:
                try await app.projectContexts.repository
                    .removeProjectTransitionAuthorityForTesting(
                        projectID: fixture.projectID,
                        transitionKind: "relink",
                        operationID: fixture.preparation.operationID
                    )
            case .corruptAuthority:
                try await app.projectContexts.repository
                    .mutateProjectTransitionAuthorityForTesting(
                        projectID: fixture.projectID,
                        transitionKind: "relink",
                        operationID: fixture.preparation.operationID,
                        field: "target_root_sha256",
                        value: String(repeating: "0", count: 64)
                    )
            case .staleOperation:
                break
            }
            _ = try app.projectMemory.identities.commitRelink(fixture.preparation)
            let operationID = adversary == .staleOperation
                ? String(repeating: "0", count: 64)
                : fixture.preparation.operationID
            if adversary.leavesAuthorityIntact {
                let active = try app.projectContexts.finalizeRelink(
                    projectID: fixture.projectID,
                    priorGeneration: fixture.expectedGeneration,
                    target: fixture.preparation.target,
                    transitionOperationID: operationID
                )
                XCTAssertEqual(active.lifecycleState, .active)
                let replay = try app.projectContexts.finalizeRelink(
                    projectID: fixture.projectID,
                    priorGeneration: fixture.expectedGeneration,
                    target: fixture.preparation.target,
                    transitionOperationID: operationID
                )
                XCTAssertEqual(replay, active)
                let counts = try await app.projectContexts.repository
                    .projectTransitionAuthorityCountsForTesting(projectID: fixture.projectID)
                XCTAssertEqual(counts.staged, 0)
                XCTAssertEqual(counts.published, 2)
                XCTAssertEqual(counts.total, 2)
            } else {
                XCTAssertThrowsError(try app.projectContexts.finalizeRelink(
                    projectID: fixture.projectID,
                    priorGeneration: fixture.expectedGeneration,
                    target: fixture.preparation.target,
                    transitionOperationID: operationID
                )) { error in
                    XCTAssertEqual(
                        error as? ProjectContextError,
                        .projectTransitionConflict(fixture.projectID),
                        "Unexpected authority result for \(adversary.rawValue)"
                    )
                }
                let stillFenced = try XCTUnwrap(
                    try app.projectContexts.project(fixture.projectID)
                )
                XCTAssertEqual(stillFenced.lifecycleState, .maintenance)
                let counts = try await app.projectContexts.repository
                    .projectTransitionAuthorityCountsForTesting(projectID: fixture.projectID)
                if adversary == .missingAuthority {
                    XCTAssertEqual(counts.staged, 0)
                    XCTAssertEqual(counts.published, 1)
                    XCTAssertEqual(counts.total, 1)
                } else {
                    XCTAssertEqual(counts.staged, 1)
                    XCTAssertEqual(counts.published, 1)
                    XCTAssertEqual(counts.total, 2)
                }
            }
            app.shutdown()
        }
    }

    func testConcurrentIdenticalProjectRelinksConvergeOnce() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent("relink-concurrent-original", isDirectory: true)
        let replacement = home.appendingPathComponent("relink-concurrent-target", isDirectory: true)
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/concurrent-identical.git", to: directory)
        }
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let outcomes = ManagerRelinkOutcomeBox()
        let completed = expectation(description: "identical relinks complete")
        completed.expectedFulfillmentCount = 2

        for _ in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async {
                outcomes.append(Result {
                    try node.relinkProject(
                        projectID: ProjectID(projectUUID),
                        expectedGeneration: ProjectGeneration(generation),
                        path: replacement.path
                    )
                })
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 10)

        let results = outcomes.load()
        XCTAssertEqual(results.count, 2)
        let receipts = results.compactMap { try? $0.get() }
        XCTAssertEqual(receipts.count, 2, "Both exact requests must converge: \(results)")
        XCTAssertEqual(receipts.map(\.reconciled).sorted { !$0 && $1 }, [false, true])
        let status = try XCTUnwrap(try app.projectContexts.project(ProjectID(projectUUID)))
        XCTAssertEqual(status.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(status.canonicalRoot, replacement.standardizedFileURL)
        let descriptor = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            descriptor.aliases.filter { $0 == replacement.standardizedFileURL.path }.count,
            1
        )
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testConcurrentConflictingProjectRelinksPublishOnlyCASWinner() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let original = home.appendingPathComponent("relink-race-original", isDirectory: true)
        let firstTarget = home.appendingPathComponent("relink-race-first", isDirectory: true)
        let secondTarget = home.appendingPathComponent("relink-race-second", isDirectory: true)
        for directory in [original, firstTarget, secondTarget] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote("ssh://git@example.test/team/concurrent-conflict.git", to: directory)
        }
        let node = ManagerNode(app: app)
        let registered = try node.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let outcomes = ManagerRelinkOutcomeBox()
        let completed = expectation(description: "conflicting relinks complete")
        completed.expectedFulfillmentCount = 2

        for target in [firstTarget, secondTarget] {
            DispatchQueue.global(qos: .userInitiated).async {
                outcomes.append(Result {
                    try node.relinkProject(
                        projectID: ProjectID(projectUUID),
                        expectedGeneration: ProjectGeneration(generation),
                        path: target.path
                    )
                })
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 10)

        let results = outcomes.load()
        let receipts = results.compactMap { try? $0.get() }
        let failures = results.filter {
            if case .failure = $0 { return true }
            return false
        }
        XCTAssertEqual(receipts.count, 1, "Exactly one CAS may win: \(results)")
        XCTAssertEqual(failures.count, 1, "The losing request must be rejected: \(results)")
        let winner = try XCTUnwrap(receipts.first)
        XCTAssertTrue(
            [firstTarget.standardizedFileURL.path, secondTarget.standardizedFileURL.path]
                .contains(winner.canonicalRoot)
        )
        let loser = winner.canonicalRoot == firstTarget.standardizedFileURL.path
            ? secondTarget.standardizedFileURL.path
            : firstTarget.standardizedFileURL.path
        let status = try XCTUnwrap(try app.projectContexts.project(ProjectID(projectUUID)))
        XCTAssertEqual(status.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(status.canonicalRoot.path, winner.canonicalRoot)
        let descriptor = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(descriptor.aliases.filter { $0 == winner.canonicalRoot }.count, 1)
        XCTAssertFalse(descriptor.aliases.contains(loser))
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testDistinctProcessManagerRelinkContentionIsRetryableAndConverges() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let original = home.appendingPathComponent(
            "relink-process-original",
            isDirectory: true
        )
        let replacement = home.appendingPathComponent(
            "relink-process-replacement",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeGitRemote(
                "ssh://git@example.test/team/distinct-process.git",
                to: directory
            )
        }
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        let registered = try node.registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))

        let readyURL = home.appendingPathComponent(
            ".relink-child-ready-\(UUID().uuidString.lowercased())"
        )
        let releaseURL = home.appendingPathComponent(
            ".relink-child-release-\(UUID().uuidString.lowercased())"
        )
        let childOutput = ManagerBoundedProcessOutput()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest",
            "-XCTest",
            "ForgeConductorTests.ManagerTests/testExternalProcessRelinkLockHolder",
            Bundle(for: ManagerTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        for key in ["XCTestSessionIdentifier", "XCTestConfigurationFilePath"] {
            environment.removeValue(forKey: key)
        }
        environment["FORGE_RELINK_CHILD_HOME"] = home.path
        environment["FORGE_RELINK_CHILD_PROJECT_ID"] = projectUUID.uuidString.lowercased()
        environment["FORGE_RELINK_CHILD_GENERATION"] = String(generation)
        environment["FORGE_RELINK_CHILD_PATH"] = replacement.path
        environment["FORGE_RELINK_CHILD_READY"] = readyURL.path
        environment["FORGE_RELINK_CHILD_RELEASE"] = releaseURL.path
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = childOutput.pipe
        child.standardError = childOutput.pipe
        try child.run()
        childOutput.closeParentWriter()
        defer {
            if child.isRunning {
                try? Data("release".utf8).write(to: releaseURL, options: .atomic)
                child.terminate()
                child.waitUntilExit()
            }
            _ = childOutput.finish()
            try? FileManager.default.removeItem(at: readyURL)
            try? FileManager.default.removeItem(at: releaseURL)
        }

        let readyDeadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: readyURL.path),
              child.isRunning,
              Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
            let output = childOutput.finish()
            return XCTFail("The second manager process did not acquire the relink fence: \(output)")
        }

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        do {
            _ = try await client.relinkProject(
                projectID: projectUUID,
                expectedGeneration: generation,
                path: replacement.path
            )
            XCTFail("A distinct manager process must retain the recovery-ledger fence")
        } catch let error as ManagerDashboardClient.ClientError {
            guard case .reconciliationRequired(let status, let code, _) = error else {
                return XCTFail("Expected a typed retryable reconciliation response, got \(error)")
            }
            XCTAssertEqual(status, 503)
            XCTAssertEqual(code, ProjectContextError.databaseBusy.code)
        }

        try Data("release".utf8).write(to: releaseURL, options: .atomic)
        let completionDeadline = Date().addingTimeInterval(10)
        while child.isRunning, Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        let output = childOutput.finish()
        XCTAssertEqual(child.terminationStatus, 0, "Second manager failed: \(output)")

        let reconciled = try await client.relinkProject(
            projectID: projectUUID,
            expectedGeneration: generation,
            path: replacement.path
        )
        XCTAssertTrue(reconciled.reconciled)
        XCTAssertEqual(reconciled.priorGeneration, generation)
        XCTAssertEqual(reconciled.newGeneration, generation + 1)
        XCTAssertEqual(reconciled.canonicalRoot, replacement.standardizedFileURL.path)
        let control = try XCTUnwrap(try app.projectContexts.project(ProjectID(projectUUID)))
        XCTAssertEqual(control.generation, ProjectGeneration(generation + 1))
        XCTAssertEqual(control.canonicalRoot, replacement.standardizedFileURL)
        let descriptor = try app.projectMemory.identities.descriptor(
            projectID: projectUUID.uuidString.lowercased()
        )
        XCTAssertEqual(
            descriptor.aliases.filter { $0 == replacement.standardizedFileURL.path }.count,
            1
        )
        XCTAssertFalse(try app.projectMemory.identities.hasPendingRelink(
            projectID: projectUUID.uuidString.lowercased()
        ))
    }

    func testExternalProcessRelinkLockHolder() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["FORGE_PROJECT_TRANSITION_CHILD_MODE"]
                == "assert-maintenance-fence" {
            guard let sharedHome = environment["FORGE_RELINK_CHILD_HOME"],
                  let projectID = environment["FORGE_RELINK_CHILD_PROJECT_ID"],
                  let rawProjectID = UUID(uuidString: projectID),
                  let generationValue = environment["FORGE_RELINK_CHILD_GENERATION"],
                  let generation = UInt64(generationValue),
                  let root = environment["FORGE_PROJECT_TRANSITION_CHILD_ROOT"] else {
                return XCTFail("Maintenance-fence child configuration is incomplete")
            }
            let contexts = try ProjectContextService(
                databaseURL: AppPaths(
                    home: URL(fileURLWithPath: sharedHome, isDirectory: true)
                ).controlPlaneSQLite
            )
            defer { contexts.close() }
            let owner = ProjectBindingOwner(
                kind: .mcpClient,
                id: "external-maintenance-probe"
            )
            let scope = ToolAuthorizationScope(
                canonicalRoots: [URL(fileURLWithPath: root, isDirectory: true)],
                allowedTools: ["project_memory.search"],
                networkAllowed: false,
                maximumInlineOutputBytes: 1_024
            )
            let project = ProjectID(rawProjectID)
            let fencedGeneration = ProjectGeneration(generation)
            XCTAssertThrowsError(try contexts.bind(
                owner: owner,
                projectID: project,
                generation: fencedGeneration,
                authorizationScope: scope
            )) { error in
                XCTAssertEqual(
                    error as? ProjectContextError,
                    .projectNotActive(.maintenance)
                )
            }
            let forged = ToolInvocationContext(
                projectID: project,
                projectGeneration: fencedGeneration,
                clientID: ClientID(owner.id),
                authorizationScope: scope
            )
            XCTAssertThrowsError(try contexts.validate(forged, for: owner)) { error in
                XCTAssertEqual(
                    error as? ProjectContextError,
                    .projectNotActive(.maintenance)
                )
            }
            return
        }
        guard let sharedHome = environment["FORGE_RELINK_CHILD_HOME"],
              let projectID = environment["FORGE_RELINK_CHILD_PROJECT_ID"],
              let rawProjectID = UUID(uuidString: projectID),
              let generationValue = environment["FORGE_RELINK_CHILD_GENERATION"],
              let generation = UInt64(generationValue),
              let replacementPath = environment["FORGE_RELINK_CHILD_PATH"],
              let readyPath = environment["FORGE_RELINK_CHILD_READY"],
              let releasePath = environment["FORGE_RELINK_CHILD_RELEASE"] else {
            throw XCTSkip("External relink helper runs only under the parent process harness")
        }
        let readyURL = URL(fileURLWithPath: readyPath)
        let releaseURL = URL(fileURLWithPath: releasePath)
        let app = try ForgeApp.bootstrap(home: URL(fileURLWithPath: sharedHome))
        defer { app.shutdown() }
        let node = ManagerNode(app: app, projectRelinkCheckpoint: { checkpoint in
            guard case .identityStaged = checkpoint else { return }
            try Data("ready".utf8).write(to: readyURL, options: .atomic)
            let deadline = Date().addingTimeInterval(8)
            while !FileManager.default.fileExists(atPath: releaseURL.path),
                  Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard FileManager.default.fileExists(atPath: releaseURL.path) else {
                throw NSError(
                    domain: "ManagerTests.DistinctProcessRelink",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Parent did not release relink fence"]
                )
            }
        })

        let receipt = try node.relinkProject(
            projectID: ProjectID(rawProjectID),
            expectedGeneration: ProjectGeneration(generation),
            path: replacementPath
        )
        XCTAssertFalse(receipt.reconciled)
        XCTAssertEqual(receipt.priorGeneration, generation)
        XCTAssertEqual(receipt.newGeneration, generation + 1)
        XCTAssertEqual(receipt.canonicalRoot, URL(fileURLWithPath: replacementPath).standardizedFileURL.path)
    }

    func testDashboardClientReplaysExactRelinkAfterLostResponse() async throws {
        let projectID = UUID()
        let replacement = home.appendingPathComponent("relink-lost-response", isDirectory: true)
        let generation: UInt64 = 7
        let expected = ManagerProjectRelinkResult(
            projectID: projectID.uuidString.lowercased(),
            canonicalRoot: replacement.standardizedFileURL.path,
            priorGeneration: generation,
            newGeneration: generation + 1,
            invalidatedBindingCount: 0,
            completedAt: "2026-08-31T12:00:00Z",
            reconciled: true
        )
        ManagerRelinkLostResponseProtocol.configure(
            responseData: try JSONEncoder().encode(expected)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagerRelinkLostResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: 8_899,
            session: session,
            credentials: ManagerRelinkCredentialFixture()
        )

        let actual = try await client.relinkProject(
            projectID: projectID,
            expectedGeneration: generation,
            path: replacement.path
        )

        XCTAssertEqual(actual, expected)
        let transcript = ManagerRelinkLostResponseProtocol.transcript()
        XCTAssertEqual(transcript.bodies.count, 2)
        XCTAssertEqual(transcript.bodies.first, transcript.bodies.last)
        XCTAssertEqual(
            transcript.authorizationHeaders,
            Array(repeating: "Bearer " + String(
                repeating: "a",
                count: ManagerControlCredentialStore.tokenCharacterCount
            ), count: 2)
        )
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transcript.bodies[0]) as? [String: Any]
        )
        XCTAssertEqual(Set(request.keys), ["path", "project_generation", "project_id"])
        XCTAssertEqual(request["path"] as? String, replacement.path)
        XCTAssertEqual((request["project_generation"] as? NSNumber)?.uint64Value, generation)
        XCTAssertEqual(request["project_id"] as? String, projectID.uuidString.lowercased())
    }

    func testDashboardClientReplaysExactRegistrationBodyAndCredentialOnceAfterLostResponse() async throws {
        let projectID = UUID()
        let projectRoot = home.appendingPathComponent(
            "registration-lost-response",
            isDirectory: true
        )
        let expected = ManagerProjectRegistrationResult(
            registrationState: .committed,
            projectID: projectID.uuidString.lowercased(),
            displayName: "Lost response fixture",
            canonicalRoot: projectRoot.standardizedFileURL.path,
            projectGeneration: 1,
            lifecycleState: "active",
            requestPath: projectRoot.path,
            requestedDisplayName: "Lost response fixture",
            repositoryIdentityAssertion: "git:" + String(repeating: "1", count: 64),
            reconciled: true
        )
        ManagerRegistrationLostResponseProtocol.configure(
            responseData: try JSONEncoder().encode(expected)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagerRegistrationLostResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = ManagerRotatingCredentialFixture()
        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: 8_899,
            session: session,
            credentials: credentials
        )

        let actual = try await client.registerProject(
            path: projectRoot.path,
            displayName: "Lost response fixture",
            repositoryIdentity: "git:" + String(repeating: "1", count: 64)
        )

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(credentials.count(), 1)
        let transcript = ManagerRegistrationLostResponseProtocol.transcript()
        XCTAssertEqual(transcript.bodies.count, 2)
        XCTAssertEqual(transcript.bodies.first, transcript.bodies.last)
        XCTAssertEqual(Set(transcript.authorizationHeaders.compactMap { $0 }).count, 1)
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transcript.bodies[0]) as? [String: Any]
        )
        XCTAssertEqual(Set(request.keys), ["path", "display_name", "repository_identity"])
        XCTAssertEqual(request["path"] as? String, projectRoot.path)
        XCTAssertEqual(request["display_name"] as? String, "Lost response fixture")
        XCTAssertEqual(
            request["repository_identity"] as? String,
            "git:" + String(repeating: "1", count: 64)
        )
    }

    func testDashboardClientBoundsRegistrationRetryAndReturnsExactManualReconciliation() async throws {
        let projectID = UUID()
        let projectRoot = home.appendingPathComponent(
            "registration-two-lost-responses",
            isDirectory: true
        )
        let expected = ManagerProjectRegistrationResult(
            registrationState: .committed,
            projectID: projectID.uuidString.lowercased(),
            displayName: "Two lost responses",
            canonicalRoot: projectRoot.standardizedFileURL.path,
            projectGeneration: 1,
            lifecycleState: "active",
            requestPath: projectRoot.path,
            requestedDisplayName: "Two lost responses",
            repositoryIdentityAssertion: nil,
            reconciled: true
        )
        ManagerRegistrationLostResponseProtocol.configure(
            responseData: try JSONEncoder().encode(expected),
            lostResponseCount: 2
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagerRegistrationLostResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = ManagerRotatingCredentialFixture()
        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: 8_899,
            session: session,
            credentials: credentials
        )

        let pending = try await client.registerProject(
            path: projectRoot.path,
            displayName: "Two lost responses"
        )
        XCTAssertEqual(pending.registrationState, .reconciliationRequired)
        XCTAssertEqual(pending.requestPath, projectRoot.path)
        XCTAssertEqual(pending.requestedDisplayName, "Two lost responses")
        XCTAssertEqual(pending.code, "project_registration_response_ambiguous")
        XCTAssertNil(pending.projectID)
        var transcript = ManagerRegistrationLostResponseProtocol.transcript()
        XCTAssertEqual(transcript.bodies.count, 2)
        XCTAssertEqual(transcript.bodies[0], transcript.bodies[1])
        XCTAssertEqual(transcript.authorizationHeaders[0], transcript.authorizationHeaders[1])
        XCTAssertEqual(credentials.count(), 1)

        let reconciled = try await client.registerProject(
            path: pending.requestPath,
            displayName: pending.requestedDisplayName,
            repositoryIdentity: pending.repositoryIdentityAssertion
        )
        XCTAssertEqual(reconciled, expected)
        transcript = ManagerRegistrationLostResponseProtocol.transcript()
        XCTAssertEqual(transcript.bodies.count, 3)
        XCTAssertTrue(transcript.bodies.dropFirst().allSatisfy {
            $0 == transcript.bodies[0]
        })
        XCTAssertEqual(credentials.count(), 2)
    }

    func testDashboardClientExposesManualExactReconciliationAfterBothAutomaticResponsesAreLost() async throws {
        let projectID = UUID()
        let replacement = home.appendingPathComponent(
            "relink-two-lost-responses",
            isDirectory: true
        )
        let generation: UInt64 = 11
        let expected = ManagerProjectRelinkResult(
            projectID: projectID.uuidString.lowercased(),
            canonicalRoot: replacement.standardizedFileURL.path,
            priorGeneration: generation,
            newGeneration: generation + 1,
            invalidatedBindingCount: 0,
            completedAt: "2026-08-31T12:00:00Z",
            reconciled: true
        )
        ManagerRelinkLostResponseProtocol.configure(
            responseData: try JSONEncoder().encode(expected),
            lostResponseCount: 2
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagerRelinkLostResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: 8_899,
            session: session,
            credentials: ManagerRelinkCredentialFixture()
        )

        do {
            _ = try await client.relinkProject(
                projectID: projectID,
                expectedGeneration: generation,
                path: replacement.path
            )
            XCTFail("Both automatic responses must remain ambiguous")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        let reconciled = try await client.relinkProject(
            projectID: projectID,
            expectedGeneration: generation,
            path: replacement.path
        )
        XCTAssertEqual(reconciled, expected)
        let transcript = ManagerRelinkLostResponseProtocol.transcript()
        XCTAssertEqual(transcript.bodies.count, 3)
        XCTAssertTrue(transcript.bodies.dropFirst().allSatisfy {
            $0 == transcript.bodies[0]
        })
        XCTAssertEqual(Set(transcript.authorizationHeaders.compactMap { $0 }).count, 1)
    }

    func testDashboardClientCancelsOneRuntimeJobThroughProtectedBoundedRoute() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let projectRoot = home.appendingPathComponent("runtime-cancel-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: false)
        let node = ManagerNode(app: app)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }

        let registered = try node.registerProject(path: projectRoot.path)
        let projectID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let clientID = ClientID("manager-runtime-cancel-test")
        _ = try node.bindProject(
            projectID: ProjectID(projectID),
            expectedGeneration: ProjectGeneration(generation),
            owner: ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue),
            allowedTools: Set(RuntimeJobToolPack.names)
        )
        let context = try app.projectContexts.invocationContext(for: clientID)
        let jobID = try await app.runtimeJobs.service.submit(
            RuntimeJobRequest(
                kind: .bash,
                profile: .bashNoProfile,
                context: context,
                script: "while :; do sleep 1; done",
                canonicalWorkingDirectory: projectRoot,
                timeout: .seconds(30),
                replayClass: .readOnly
            )
        )
        var reachedRunning = false
        for _ in 0..<200 {
            if try await app.runtimeJobs.service.status(jobID: jobID, context: context).state == .running {
                reachedRunning = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reachedRunning)

        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(150))
        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/runtime-jobs/cancel")
        )
        var unauthorizedRequest = URLRequest(url: endpoint)
        unauthorizedRequest.httpMethod = "POST"
        unauthorizedRequest.httpBody = try JSONSupport.data(from: [
            "job_id": jobID.uuidString.lowercased(),
        ])
        unauthorizedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, unauthorizedResponse) = try HTTPTestHelpers.fetch(unauthorizedRequest)
        XCTAssertEqual(unauthorizedResponse.statusCode, 401)

        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        var oversizedRequest = unauthorizedRequest
        oversizedRequest.httpBody = Data(
            repeating: UInt8(ascii: " "),
            count: ManagerRoutes.maximumRuntimeJobCancelBodyBytes + 1
        )
        oversizedRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let (oversizedData, oversizedResponse) = try HTTPTestHelpers.fetch(oversizedRequest)
        XCTAssertEqual(oversizedResponse.statusCode, 413)
        XCTAssertEqual(
            try JSONSupport.object(from: oversizedData)["code"] as? String,
            "runtime_job_cancel_body_too_large"
        )

        var forgedScopeRequest = unauthorizedRequest
        forgedScopeRequest.httpBody = try JSONSupport.data(from: [
            "job_id": jobID.uuidString.lowercased(),
            "project_id": UUID().uuidString.lowercased(),
        ])
        forgedScopeRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let (forgedData, forgedResponse) = try HTTPTestHelpers.fetch(forgedScopeRequest)
        XCTAssertEqual(forgedResponse.statusCode, 400)
        XCTAssertEqual(
            try JSONSupport.object(from: forgedData)["code"] as? String,
            "invalid_runtime_job_cancel"
        )

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let receipt = try await client.cancelRuntimeJob(jobID: jobID)
        XCTAssertEqual(receipt.jobID, jobID.uuidString.lowercased())
        XCTAssertTrue(receipt.state == RuntimeJobState.cancelling.rawValue
            || receipt.state == RuntimeJobState.cancelled.rawValue)
        let terminal = try await app.runtimeJobs.service.waitForTerminal(
            jobID: jobID,
            context: context,
            maximumWait: .seconds(8)
        )
        XCTAssertEqual(terminal.state, .cancelled)
    }

    func testManagerProviderConnectionAndContractProbesPublishActualMemoryOnlyResult() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let provider = ManagerProviderProbeFixture(
            capabilities: try managerProviderCapabilities()
        )
        let recorder = ManagerProviderStorageRecorder()
        let registry = managerProviderRegistry(provider: provider, recorder: recorder)
        let node = ManagerNode(app: app, hostAdapterRegistry: registry)

        let connection = try node.probeProvider(
            adapterID: ManagerNode.nativeSessionHostAdapterID,
            mode: .connection
        )
        XCTAssertEqual(connection.health, "reachable")
        XCTAssertEqual(connection.adapterID, ManagerNode.nativeSessionHostAdapterID)
        XCTAssertEqual(connection.providerID, "lmstudio")
        XCTAssertEqual(connection.modelKey, "fixture/tool-model")
        XCTAssertEqual(connection.instanceID, "fixture-instance")
        XCTAssertEqual(connection.activeContextLength, 16_384)
        XCTAssertEqual(connection.maximumContextLength, 32_768)
        XCTAssertEqual(connection.toolUseCapable, true)
        XCTAssertEqual(connection.lifecycleManagementEnabled, true)
        XCTAssertEqual(connection.lastProbeMode, ManagerProviderProbeMode.connection.rawValue)
        XCTAssertEqual(connection.probeResultStorage, "memory_only")
        XCTAssertNil(connection.lastProbeError)

        var calls = await provider.calls()
        XCTAssertEqual(calls.probes, 1)
        XCTAssertEqual(calls.lookups, 0)
        XCTAssertEqual(
            recorder.storageDirectory,
            app.paths.managedProvidersDir.appendingPathComponent(
                ManagerNode.nativeSessionHostAdapterID,
                isDirectory: true
            ).standardizedFileURL
        )

        let contract = try node.probeProvider(
            adapterID: ManagerNode.nativeSessionHostAdapterID,
            mode: .contract
        )
        XCTAssertEqual(contract.health, "contract_valid")
        XCTAssertEqual(contract.lastProbeMode, ManagerProviderProbeMode.contract.rawValue)
        XCTAssertEqual(contract.contractFingerprint, String(repeating: "a", count: 64))
        calls = await provider.calls()
        XCTAssertEqual(calls.probes, 2)
        XCTAssertEqual(calls.lookups, 1)

        let projected = try node.operatorSnapshot(limit: 10).provider
        XCTAssertEqual(projected, contract)

        let restartedNode = ManagerNode(app: app, hostAdapterRegistry: registry)
        let afterManagerRestart = try restartedNode.operatorSnapshot(limit: 10).provider
        XCTAssertEqual(afterManagerRestart.health, "unavailable")
        XCTAssertNil(afterManagerRestart.lastProbeAt)
        XCTAssertNil(afterManagerRestart.probeResultStorage)
    }

    func testManagerProviderAllowsOnlyOneProbeInFlight() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let provider = ManagerProviderProbeFixture(
            capabilities: try managerProviderCapabilities()
        )
        let registry = managerProviderRegistry(
            provider: provider,
            recorder: ManagerProviderStorageRecorder()
        )
        let node = ManagerNode(app: app, hostAdapterRegistry: registry)

        await provider.holdNextProbeUntilReleased()
        let firstProbe = Task.detached {
            try node.probeProvider(
                adapterID: ManagerNode.nativeSessionHostAdapterID,
                mode: .connection
            )
        }

        let holdDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await provider.isHoldingProbe()), ContinuousClock.now < holdDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await provider.isHoldingProbe() else {
            await provider.releaseHeldProbe()
            firstProbe.cancel()
            _ = try? await firstProbe.value
            return XCTFail("The first provider probe did not reach the registered fixture")
        }

        XCTAssertThrowsError(
            try node.probeProvider(
                adapterID: ManagerNode.nativeSessionHostAdapterID,
                mode: .contract
            )
        ) { error in
            XCTAssertEqual(error as? ManagerProviderProbeError, .probeInProgress)
        }

        await provider.releaseHeldProbe()
        let completed = try await firstProbe.value
        XCTAssertEqual(completed.health, "reachable")
        let calls = await provider.calls()
        XCTAssertEqual(calls.probes, 1)
        XCTAssertEqual(calls.lookups, 0)
    }

    func testManagerContractProbeFailsVisiblyWhenRequiredCapabilityIsAbsent() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        var missingLifecycle = managerProviderHostCapabilities()
        missingLifecycle.resume = false
        let cases: [(ProviderCapabilities, HostCapabilities, String)] = [
            (
                try managerProviderCapabilities(statefulResponses: false),
                managerProviderHostCapabilities(),
                "stateful responses"
            ),
            (
                try managerProviderCapabilities(customTools: false),
                managerProviderHostCapabilities(),
                "custom tools"
            ),
            (
                try managerProviderCapabilities(usageReporting: false),
                managerProviderHostCapabilities(),
                "usage reporting"
            ),
            (
                try managerProviderCapabilities(idempotencyLookup: false),
                managerProviderHostCapabilities(),
                "idempotency lookup"
            ),
            (
                try managerProviderCapabilities(),
                missingLifecycle,
                "stateful lifecycle"
            ),
        ]

        for (capabilities, hostCapabilities, expectedGap) in cases {
            let provider = ManagerProviderProbeFixture(capabilities: capabilities)
            let registry = managerProviderRegistry(
                provider: provider,
                recorder: ManagerProviderStorageRecorder(),
                hostCapabilities: hostCapabilities
            )
            let node = ManagerNode(app: app, hostAdapterRegistry: registry)
            XCTAssertEqual(
                try node.probeProvider(
                    adapterID: ManagerNode.nativeSessionHostAdapterID,
                    mode: .connection
                ).health,
                "reachable"
            )
            XCTAssertThrowsError(try node.probeProvider(
                adapterID: ManagerNode.nativeSessionHostAdapterID,
                mode: .contract
            )) { error in
                guard case ManagerProviderProbeError.contractUnavailable(let detail) = error else {
                    return XCTFail("Expected contract capability failure, received \(error)")
                }
                XCTAssertTrue(detail.contains(expectedGap), detail)
            }
            let projected = try node.operatorSnapshot(limit: 10).provider
            XCTAssertEqual(projected.health, "contract_invalid")
            XCTAssertEqual(projected.lastProbeMode, ManagerProviderProbeMode.contract.rawValue)
            XCTAssertEqual(projected.probeResultStorage, "memory_only")
            XCTAssertTrue(projected.lastProbeError?.contains(expectedGap) == true)
        }
    }

    func testManagerProviderProbeRejectsPathDerivedAndUnregisteredAdapterIdentifiers() throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let emptyRegistry = HostAdapterRegistry()
        let node = ManagerNode(app: app, hostAdapterRegistry: emptyRegistry)

        XCTAssertThrowsError(
            try node.probeProvider(adapterID: "../forge.native-session-host", mode: .connection)
        ) { error in
            XCTAssertEqual(error as? ManagerProviderProbeError, .invalidAdapterIdentifier)
        }
        XCTAssertThrowsError(
            try node.probeProvider(
                adapterID: String(repeating: "a", count: ManagerNode.maximumProviderAdapterIDBytes + 1),
                mode: .connection
            )
        ) { error in
            XCTAssertEqual(error as? ManagerProviderProbeError, .invalidAdapterIdentifier)
        }
        XCTAssertThrowsError(
            try node.probeProvider(
                adapterID: ManagerNode.nativeSessionHostAdapterID,
                mode: .connection
            )
        ) { error in
            XCTAssertEqual(error as? ManagerProviderProbeError, .adapterNotRegistered)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: app.paths.managedProvidersDir
                    .appendingPathComponent("forge.native-session-host", isDirectory: true).path
            )
        )
    }

    func testProviderProbeRouteIsAuthorizedBodyBoundedAndTypedClientBacked() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let provider = ManagerProviderProbeFixture(
            capabilities: try managerProviderCapabilities()
        )
        let registry = managerProviderRegistry(
            provider: provider,
            recorder: ManagerProviderStorageRecorder()
        )
        var node: ManagerNode? = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            node = nil
            app.shutdown()
        }
        _ = try XCTUnwrap(node).startService()
        try await Task.sleep(for: .milliseconds(150))

        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/provider/probe")
        )
        let validBody = try JSONSupport.data(from: [
            "adapter_id": ManagerNode.nativeSessionHostAdapterID,
            "mode": ManagerProviderProbeMode.connection.rawValue,
        ])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = validBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, unauthorized) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(unauthorized.statusCode, 401)

        request.setValue(
            "Bearer \(String(repeating: "0", count: ManagerControlCredentialStore.tokenCharacterCount))",
            forHTTPHeaderField: "Authorization"
        )
        let (_, wrongCredential) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(wrongCredential.statusCode, 401)

        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            repeating: UInt8(ascii: " "),
            count: ManagerRoutes.maximumProviderProbeBodyBytes + 1
        )
        let (oversizedData, oversized) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(oversized.statusCode, 413)
        XCTAssertEqual(
            try JSONSupport.object(from: oversizedData)["code"] as? String,
            "provider_probe_body_too_large"
        )

        request.httpBody = try JSONSupport.data(from: [
            "adapter_id": ManagerNode.nativeSessionHostAdapterID,
            "mode": ManagerProviderProbeMode.connection.rawValue,
            "storage_path": "/tmp/caller-selected",
        ])
        let (forgedData, forged) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(forged.statusCode, 400)
        XCTAssertEqual(
            try JSONSupport.object(from: forgedData)["code"] as? String,
            "invalid_provider_probe"
        )

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let connection = try await client.probeProvider(
            adapterID: ManagerNode.nativeSessionHostAdapterID,
            mode: .connection
        )
        XCTAssertEqual(connection.health, "reachable")
        XCTAssertEqual(connection.adapterID, ManagerNode.nativeSessionHostAdapterID)
        XCTAssertEqual(connection.providerID, "lmstudio")
        XCTAssertEqual(connection.modelKey, "fixture/tool-model")
        XCTAssertEqual(connection.lastProbeMode, ManagerProviderProbeMode.connection.rawValue)
        XCTAssertEqual(connection.probeResultStorage, "memory_only")

        let contract = try await client.probeProvider(
            adapterID: ManagerNode.nativeSessionHostAdapterID,
            mode: .contract
        )
        XCTAssertEqual(contract.health, "contract_valid")
        XCTAssertEqual(contract.adapterID, ManagerNode.nativeSessionHostAdapterID)
        XCTAssertEqual(contract.lastProbeMode, ManagerProviderProbeMode.contract.rawValue)
        XCTAssertEqual(contract.probeResultStorage, "memory_only")
        let calls = await provider.calls()
        XCTAssertEqual(calls.probes, 2)
        XCTAssertEqual(calls.lookups, 1)

        let snapshotURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/operator/snapshot?limit=10")
        )
        let beforeRestart = try HTTPTestHelpers.fetchJSON(snapshotURL)
        let probedProvider = try XCTUnwrap(beforeRestart["provider"] as? [String: Any])
        XCTAssertEqual(probedProvider["health"] as? String, "contract_valid")
        XCTAssertEqual(probedProvider["probe_result_storage"] as? String, "memory_only")

        node = nil
        try await Task.sleep(for: .milliseconds(150))

        node = ManagerNode(app: app, hostAdapterRegistry: registry)
        _ = try XCTUnwrap(node).startService()
        try await Task.sleep(for: .milliseconds(150))
        let afterRestart = try HTTPTestHelpers.fetchJSON(snapshotURL)
        let restartedProvider = try XCTUnwrap(afterRestart["provider"] as? [String: Any])
        XCTAssertEqual(restartedProvider["health"] as? String, "unavailable")
        XCTAssertNil(restartedProvider["last_probe_at"])
        XCTAssertNil(restartedProvider["last_probe_mode"])
        XCTAssertNil(restartedProvider["probe_result_storage"])
    }

    func testSlowProviderProbeRouteDoesNotBlockManagerStatusOrControlRoutes() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let provider = ManagerProviderProbeFixture(
            capabilities: try managerProviderCapabilities()
        )
        let registry = managerProviderRegistry(
            provider: provider,
            recorder: ManagerProviderStorageRecorder()
        )
        var node: ManagerNode? = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            node = nil
            app.shutdown()
        }
        _ = try XCTUnwrap(node).startService()
        try await Task.sleep(for: .milliseconds(150))

        await provider.holdNextProbeUntilReleased()
        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let probeEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/provider/probe")
        )
        var probeRequest = URLRequest(url: probeEndpoint)
        probeRequest.httpMethod = "POST"
        probeRequest.httpBody = try JSONSupport.data(from: [
            "adapter_id": ManagerNode.nativeSessionHostAdapterID,
            "mode": ManagerProviderProbeMode.connection.rawValue,
        ])
        probeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probeRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let probeTask = Task {
            try await URLSession.shared.data(for: probeRequest)
        }

        let holdDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await provider.isHoldingProbe()), ContinuousClock.now < holdDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await provider.isHoldingProbe() else {
            probeTask.cancel()
            await provider.releaseHeldProbe()
            _ = try? await probeTask.value
            return XCTFail("The HTTP provider probe did not reach the registered fixture")
        }

        let statusURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/status")
        )
        let (_, statusResponse) = try HTTPTestHelpers.fetch(statusURL, timeout: 1)
        XCTAssertEqual(statusResponse.statusCode, 200)

        let startURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/start")
        )
        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        startRequest.httpBody = try JSONSupport.data(from: [:])
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let (_, startResponse) = try HTTPTestHelpers.fetch(startRequest, timeout: 1)
        XCTAssertEqual(startResponse.statusCode, 200)

        await provider.releaseHeldProbe()
        let (probeData, probeResponse) = try await probeTask.value
        XCTAssertEqual((probeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            try JSONSupport.object(from: probeData)["health"] as? String,
            "reachable"
        )
    }

    func testProviderProbeRouteDeadlineCancelsInFlightProviderTask() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let provider = ManagerProviderProbeFixture(
            capabilities: try managerProviderCapabilities()
        )
        let registry = managerProviderRegistry(
            provider: provider,
            recorder: ManagerProviderStorageRecorder()
        )
        var node: ManagerNode? = ManagerNode(
            app: app,
            hostAdapterRegistry: registry,
            providerProbeTimeoutSeconds: 0.1
        )
        defer {
            node = nil
            app.shutdown()
        }
        _ = try XCTUnwrap(node).startService()
        try await Task.sleep(for: .milliseconds(150))

        await provider.cancelNextProbeAtDeadline()
        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let endpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/provider/probe")
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSupport.data(from: [
            "adapter_id": ManagerNode.nativeSessionHostAdapterID,
            "mode": ManagerProviderProbeMode.connection.rawValue,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let (data, response) = try HTTPTestHelpers.fetch(request, timeout: 2)
        XCTAssertEqual(response.statusCode, 502)
        XCTAssertEqual(
            try JSONSupport.object(from: data)["code"] as? String,
            ManagerProviderProbeError.connectionFailed("").code
        )

        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await provider.didObserveProbeCancellation()),
              ContinuousClock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancellationObserved = await provider.didObserveProbeCancellation()
        let cancellationPending = await provider.isAwaitingProbeCancellation()
        XCTAssertTrue(cancellationObserved)
        XCTAssertFalse(cancellationPending)

        let failedProbe = try XCTUnwrap(node).operatorSnapshot(limit: 10).provider
        XCTAssertEqual(failedProbe.health, "unreachable")
        XCTAssertTrue(
            failedProbe.lastProbeError?.contains("exceeded its bounded deadline") == true
        )

        let recovered = try XCTUnwrap(node).probeProvider(
            adapterID: ManagerNode.nativeSessionHostAdapterID,
            mode: .connection
        )
        XCTAssertEqual(recovered.health, "reachable")
        let calls = await provider.calls()
        XCTAssertEqual(calls.probes, 2)
    }

    func testProviderProbeDeadlineKeepsAdmissionFencedUntilCancellationIgnoringTaskTerminates()
        async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let provider = ManagerProviderProbeFixture(
            capabilities: try managerProviderCapabilities()
        )
        let registry = managerProviderRegistry(
            provider: provider,
            recorder: ManagerProviderStorageRecorder()
        )
        let node = ManagerNode(
            app: app,
            hostAdapterRegistry: registry,
            providerProbeTimeoutSeconds: 0.1
        )
        defer { app.shutdown() }

        await provider.ignoreCancellationUntilReleasedForNextProbe()
        let firstProbe = Task.detached { () -> String in
            do {
                _ = try node.probeProvider(
                    adapterID: ManagerNode.nativeSessionHostAdapterID,
                    mode: .connection
                )
                return "unexpected_success"
            } catch let error as ManagerProviderProbeError {
                return error.code
            } catch {
                return "unexpected_error"
            }
        }

        let holdDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await provider.isHoldingCancellationIgnoringProbe()),
              ContinuousClock.now < holdDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancellationIgnoringProbeIsHeld = await provider.isHoldingCancellationIgnoringProbe()
        let firstProbeCode = await firstProbe.value
        XCTAssertTrue(cancellationIgnoringProbeIsHeld)
        XCTAssertEqual(
            firstProbeCode,
            ManagerProviderProbeError.connectionFailed("").code
        )

        for _ in 0..<8 {
            XCTAssertThrowsError(
                try node.probeProvider(
                    adapterID: ManagerNode.nativeSessionHostAdapterID,
                    mode: .connection
                )
            ) { error in
                XCTAssertEqual(error as? ManagerProviderProbeError, .probeInProgress)
            }
        }
        var calls = await provider.calls()
        XCTAssertEqual(calls.probes, 1)

        await provider.releaseCancellationIgnoringProbe()
        let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        var recovered: ManagerOperatorProvider?
        while recovered == nil, ContinuousClock.now < recoveryDeadline {
            do {
                recovered = try node.probeProvider(
                    adapterID: ManagerNode.nativeSessionHostAdapterID,
                    mode: .connection
                )
            } catch ManagerProviderProbeError.probeInProgress {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                XCTFail("Unexpected provider recovery error: \(error)")
                break
            }
        }
        XCTAssertEqual(recovered?.health, "reachable")
        calls = await provider.calls()
        XCTAssertEqual(calls.probes, 2)
    }

#if SWIFT_PACKAGE
    func testLiveProviderProbeRouteUsesProductionRegistryAndConfiguration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelKey = environment["FORGE_LIVE_LMSTUDIO_MODEL"], !modelKey.isEmpty else {
            throw XCTSkip("Set FORGE_LIVE_LMSTUDIO_MODEL to run the production provider route test")
        }
        let baseURL = try XCTUnwrap(URL(
            string: environment["FORGE_LIVE_LMSTUDIO_BASE_URL"]
                ?? "http://127.0.0.1:1234"
        ))
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        try writeLiveManagerProviderConfiguration(
            baseURL: baseURL,
            modelKey: modelKey,
            paths: app.paths
        )
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        var node: ManagerNode? = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            node = nil
            app.shutdown()
        }
        _ = try XCTUnwrap(node).startService()
        try await Task.sleep(for: .milliseconds(150))

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths)
        )
        let connection = try await client.probeProvider(
            adapterID: ForgeNativeSessionHostPlugin.identifier,
            mode: .connection
        )
        XCTAssertEqual(connection.health, "reachable")
        XCTAssertEqual(connection.adapterID, ForgeNativeSessionHostPlugin.identifier)
        XCTAssertEqual(connection.providerID, "lmstudio")
        XCTAssertEqual(connection.modelKey, modelKey)
        XCTAssertEqual(connection.probeResultStorage, "memory_only")

        let contract = try await client.probeProvider(
            adapterID: ForgeNativeSessionHostPlugin.identifier,
            mode: .contract
        )
        XCTAssertEqual(contract.health, "contract_valid")
        XCTAssertEqual(contract.adapterID, ForgeNativeSessionHostPlugin.identifier)
        XCTAssertEqual(contract.providerID, "lmstudio")
        XCTAssertEqual(contract.modelKey, modelKey)
        XCTAssertEqual(contract.toolUseCapable, true)
        XCTAssertEqual(contract.lifecycleManagementEnabled, true)
        XCTAssertEqual(contract.lastProbeMode, ManagerProviderProbeMode.contract.rawValue)
        XCTAssertEqual(contract.probeResultStorage, "memory_only")
        XCTAssertEqual(contract.contractFingerprint?.count, 64)
        XCTAssertNil(contract.lastProbeError)
    }
#endif

    func testPIDFileHelpers() throws {
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        try ManagerPIDFile.write(paths: paths)
        let pid = ManagerPIDFile.read(paths: paths)
        XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(ManagerPIDFile.runningPID(paths: paths), pid)
        ManagerPIDFile.remove(paths: paths)
        XCTAssertNil(ManagerPIDFile.runningPID(paths: paths))
    }

    func testNormalizeSettingsPatch() throws {
        let first = home.appendingPathComponent("a-project", isDirectory: true)
        let second = home.appendingPathComponent("b-project", isDirectory: true)
        let alias = home.appendingPathComponent("project-alias", isDirectory: true)
        let regularFile = home.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        try Data("fixture".utf8).write(to: regularFile)
        let canonicalFirst = try XCTUnwrap(
            ManagerSettingsNormalizer.canonicalAllowedRoot(first.path)
        )
        let canonicalSecond = try XCTUnwrap(
            ManagerSettingsNormalizer.canonicalAllowedRoot(second.path)
        )

        let patch = ManagerNode.normalizeSettingsPatch([
            "dashboard": [
                "host": " 127.0.0.1 ",
                "port": "8899",
                "refresh_interval_sec": 1,
            ] as [String: Any],
            "manager": ["watchdog_interval_sec": 100] as [String: Any],
            "allowed_roots": [
                second.path,
                first.path,
                alias.path,
                first.appendingPathComponent(".").path,
                "/",
                "relative/project",
                regularFile.path,
                home.appendingPathComponent("missing").path,
            ],
        ])
        let dash = patch["dashboard"] as? [String: Any]
        XCTAssertEqual(dash?["host"] as? String, "127.0.0.1")
        XCTAssertEqual(dash?["port"] as? Int, 8899)
        XCTAssertEqual(dash?["refresh_interval_sec"] as? Int, 2)
        let mgr = patch["manager"] as? [String: Any]
        XCTAssertEqual(mgr?["watchdog_interval_sec"] as? Int, 60)
        XCTAssertEqual(
            patch["allowed_roots"] as? [String],
            [canonicalFirst, canonicalSecond].sorted()
        )

        let rejected = ManagerNode.normalizeSettingsPatch([
            "dashboard": ["host": "0.0.0.0"] as [String: Any],
        ])
        XCTAssertNil((rejected["dashboard"] as? [String: Any])?["host"])

        let clear = ManagerNode.normalizeSettingsPatch(["allowed_roots": [] as [String]])
        XCTAssertEqual(clear["allowed_roots"] as? [String], [])
    }

    func testAllowedRootsPersistAcrossManagerAndAppRestart() throws {
        let project = home.appendingPathComponent("restart-project", isDirectory: true)
        let alias = home.appendingPathComponent("restart-project-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let canonicalProject = try XCTUnwrap(
            ManagerSettingsNormalizer.canonicalAllowedRoot(project.path)
        )

        var firstApp: ForgeApp? = try ForgeApp.bootstrap(home: home)
        var firstManager: ManagerNode? = ManagerNode(app: try XCTUnwrap(firstApp))
        let firstSettings = try XCTUnwrap(firstManager).updateSettings(
            ManagerSettingsPatch(allowedRoots: [alias.path, "/"]),
            apply: false
        )
        XCTAssertEqual(firstSettings.allowedRoots, [canonicalProject])
        XCTAssertEqual(try XCTUnwrap(firstApp).config.model.allowedRoots, [canonicalProject])
        try XCTUnwrap(firstApp).shutdown()
        firstManager = nil
        firstApp = nil

        let secondApp = try ForgeApp.bootstrap(home: home)
        defer { secondApp.shutdown() }
        let secondManager = ManagerNode(app: secondApp)
        XCTAssertEqual(secondManager.settingsModel().allowedRoots, [canonicalProject])
        XCTAssertEqual(secondApp.config.model.allowedRoots, [canonicalProject])
    }

    func testDashboardHTMLHasManagerControls() throws {
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/start"))
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/stop"))
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/restart"))
        XCTAssertTrue(DashboardHTML.index.contains("/api/manager/settings"))
        XCTAssertTrue(DashboardHTML.index.contains("Shutdown manager"))
    }

    func testInstallerBinaryPathAndAllowlist() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let installer = ManagerInstaller(app: app)
        XCTAssertTrue(
            installer.installedBinaryURL.path.contains(".forge-conductor")
                || installer.installedBinaryURL.path.contains(home.lastPathComponent)
        )
        let report = installer.endpointProtectionReport()
        XCTAssertEqual(report["ok"] as? Bool, true)
        let allow = report["allowlist"] as? [String: Any]
        XCTAssertNotNil(allow?["crowdstrike_falcon"])
        XCTAssertNotNil(allow?["jamf_protect"])
        XCTAssertNotNil(allow?["macos_login_items"])
    }

    func testMinimalManagerAppBundleUsesCanonicalMarketingAndBuildVersions() throws {
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: TestManagerArtifactValidator(),
            artifactCopier: TestManagerArtifactCopier(),
            artifactReplacer: TestManagerArtifactReplacer(),
            privilegedApplicationIdentityValidator:
                TestManagerPrivilegedApplicationIdentityValidator()
        )
        try FileManager.default.createDirectory(
            at: installer.installedBinaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: installer.installedBinaryURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installer.installedBinaryURL.path
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: installer.installedRuntimeLauncherURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installer.installedRuntimeLauncherURL.path
        )

        let bundle = try installer.installAppBundle(from: installer.installedBinaryURL)
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: infoURL) as? [String: Any])

        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, ForgeApp.version)
        XCTAssertEqual(info["CFBundleVersion"] as? String, ForgeApp.buildVersion)
        XCTAssertEqual(
            try String(
                contentsOf: bundle.appendingPathComponent(
                    "Contents/Helpers/\(ManagerInstaller.runtimeLauncherName)"
                ),
                encoding: .utf8
            ),
            "#!/bin/sh\nexit 0\n"
        )
    }

    func testManagerArtifactStagingReplacesStaleBinaryFrameworkAndAppBundle() throws {
        let validator = TestManagerArtifactValidator()
        let fixture = try makeArtifactFixture(validator: validator)

        let stagedBinary = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable
        )

        try assertCurrentArtifacts(
            fixture,
            expectedInstalledBinary: "#!/bin/sh\necho embedded-manager\n"
        )
        XCTAssertEqual(stagedBinary, fixture.installer.installedBinaryURL)
        XCTAssertEqual(
            validator.operations,
            [
                .sign(.executable), .verify(.executable),
                .sign(.executable), .verify(.executable),
                .sign(.framework), .verify(.framework),
                .sign(.framework), .verify(.framework),
                .sign(.applicationBundle), .verify(.applicationBundle),
            ]
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingFromAppUsesValidatedEmbeddedManagerCLI() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let artifactValidator = TestManagerArtifactValidator()
        let fixture = try makeArtifactFixture(
            validator: artifactValidator,
            privilegedApplicationIdentityValidator: identityValidator
        )

        _ = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable,
            requiringPrivilegedApplication: true
        )

        try assertCurrentArtifacts(
            fixture,
            expectedInstalledBinary: "#!/bin/sh\necho embedded-manager\n"
        )
        XCTAssertEqual(identityValidator.validations.count, 3)
        XCTAssertEqual(identityValidator.validations[0].context, .invocation)
        XCTAssertEqual(
            identityValidator.validations[0].sourceExecutable,
            fixture.sourceExecutable.standardizedFileURL
        )
        XCTAssertEqual(identityValidator.validations[1].context, .invocation)
        XCTAssertEqual(
            identityValidator.validations[1].sourceExecutable,
            fixture.sourceManagerExecutable.standardizedFileURL
        )
        XCTAssertEqual(identityValidator.validations[2].context, .stagedCopy)
        XCTAssertTrue(
            identityValidator.validations[2].sourceExecutable.lastPathComponent
                .contains(".stage-")
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installedFramework.appendingPathComponent("revision.txt"),
                encoding: .utf8
            ),
            "current-framework"
        )
        XCTAssertEqual(
            artifactValidator.operations,
            [
                .sign(.executable), .verify(.executable),
                .sign(.executable), .verify(.executable),
                .sign(.framework), .verify(.framework),
                .sign(.framework), .verify(.framework),
                .sign(.applicationBundle), .verify(.applicationBundle),
            ]
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingDirectlyFromEmbeddedManagerDiscoversContainingApplication() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        let sourceApplication = fixture.sourceExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        _ = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceManagerExecutable,
            requiringPrivilegedApplication: true
        )

        try assertCurrentArtifacts(
            fixture,
            expectedInstalledBinary: "#!/bin/sh\necho embedded-manager\n"
        )
        XCTAssertEqual(identityValidator.validations.count, 2)
        XCTAssertEqual(
            identityValidator.validations[0].applicationBundle,
            sourceApplication.standardizedFileURL
        )
        XCTAssertEqual(
            identityValidator.validations[0].sourceExecutable,
            fixture.sourceManagerExecutable.standardizedFileURL
        )
        XCTAssertEqual(identityValidator.validations[0].context, .invocation)
        XCTAssertEqual(identityValidator.validations[1].context, .stagedCopy)
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingFromCLIDiscoversCompleteSiblingApplication() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        let sourceApplication = fixture.sourceExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceCLI = sourceApplication.deletingLastPathComponent()
            .appendingPathComponent(ManagerInstaller.preferredBinaryName)
        try FileManager.default.copyItem(at: fixture.sourceExecutable, to: sourceCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceCLI.path
        )

        _ = try fixture.installer.stageInstalledArtifacts(
            from: sourceCLI,
            requiringPrivilegedApplication: true
        )

        try assertCurrentArtifacts(fixture)
        XCTAssertEqual(identityValidator.validations.count, 2)
        XCTAssertEqual(
            identityValidator.validations.first?.applicationBundle,
            sourceApplication.standardizedFileURL
        )
        XCTAssertEqual(
            identityValidator.validations.first?.sourceExecutable,
            sourceCLI.standardizedFileURL
        )
        XCTAssertEqual(identityValidator.validations.first?.context, .invocation)
        XCTAssertTrue(
            identityValidator.validations.last?.applicationBundle.lastPathComponent
                .contains(".stage-") == true
        )
        XCTAssertTrue(
            identityValidator.validations.last?.sourceExecutable.lastPathComponent
                .contains(".stage-") == true
        )
        XCTAssertEqual(identityValidator.validations.last?.context, .stagedCopy)
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingRejectsFailedStagedExecutableValidation() throws {
        let forcedFailure = NSError(
            domain: "ManagerTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "forced staged identity failure"]
        )
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator(
            failure: forcedFailure,
            failingContext: .stagedCopy
        )
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                requiringPrivilegedApplication: true
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "forced staged identity failure")
        }

        XCTAssertEqual(
            identityValidator.validations.map(\.context),
            [.invocation, .invocation, .stagedCopy]
        )
        XCTAssertEqual(
            identityValidator.validations.first?.sourceExecutable,
            fixture.sourceExecutable.standardizedFileURL
        )
        XCTAssertEqual(
            identityValidator.validations[1].sourceExecutable,
            fixture.sourceManagerExecutable.standardizedFileURL
        )
        XCTAssertTrue(
            identityValidator.validations.last?.sourceExecutable.lastPathComponent
                .contains(".stage-") == true
        )
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testInstalledCLISymlinkReinstallsFromValidatedInstalledApplication() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        let sourceApplication = fixture.sourceExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceCLI = sourceApplication.deletingLastPathComponent()
            .appendingPathComponent(ManagerInstaller.preferredBinaryName)
        try FileManager.default.copyItem(at: fixture.sourceExecutable, to: sourceCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceCLI.path
        )

        _ = try fixture.installer.stageInstalledArtifacts(
            from: sourceCLI,
            requiringPrivilegedApplication: true
        )
        let decoySiblingApplication = fixture.installer.installedBinaryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(ManagerInstaller.appDisplayName).app",
                isDirectory: true
            )
        try FileManager.default.copyItem(
            at: fixture.installer.appBundleURL,
            to: decoySiblingApplication
        )
        let invocationLink = home.appendingPathComponent("restart-forge-conductor")
        try FileManager.default.createSymbolicLink(
            at: invocationLink,
            withDestinationURL: fixture.installer.installedBinaryURL
        )

        _ = try fixture.installer.stageInstalledArtifacts(
            from: invocationLink,
            requiringPrivilegedApplication: true
        )

        XCTAssertEqual(identityValidator.validations.count, 4)
        let installedSourceValidation = identityValidator.validations[2]
        XCTAssertEqual(installedSourceValidation.context, .stagedCopy)
        XCTAssertEqual(
            installedSourceValidation.applicationBundle,
            fixture.installer.appBundleURL.standardizedFileURL
        )
        XCTAssertEqual(
            installedSourceValidation.sourceExecutable,
            fixture.installer.installedBinaryURL.standardizedFileURL
        )
        XCTAssertEqual(identityValidator.validations[3].context, .stagedCopy)
        XCTAssertTrue(
            identityValidator.validations[3].applicationBundle.lastPathComponent
                .contains(".stage-")
        )
        try assertCurrentArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testInstallAppBundleDefaultPreservesCompletePrivilegedApplication() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        _ = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable,
            requiringPrivilegedApplication: true
        )
        let preservationMarker = fixture.installer.appBundleURL
            .appendingPathComponent("Contents/Resources/preserve-complete-app.txt")
        try "preserve".write(
            to: preservationMarker,
            atomically: true,
            encoding: .utf8
        )
        let validationCount = identityValidator.validations.count

        let installedApplication = try fixture.installer.installAppBundle()

        XCTAssertEqual(installedApplication, fixture.installer.appBundleURL)
        XCTAssertEqual(
            try String(contentsOf: preservationMarker, encoding: .utf8),
            "preserve"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.installer.appBundleURL.appendingPathComponent(
                    "Contents/MacOS/"
                        + ForgeFilesystemProtocolConstants.daemonExecutableName
                ).path
            )
        )
        XCTAssertEqual(identityValidator.validations.count, validationCount + 1)
        XCTAssertEqual(identityValidator.validations.last?.context, .stagedCopy)
        XCTAssertEqual(
            identityValidator.validations.last?.sourceExecutable,
            fixture.installer.installedBinaryURL.standardizedFileURL
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testInstallAppBundleDefaultDoesNotDowngradeLegacyPrivilegedApplication() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        _ = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable,
            requiringPrivilegedApplication: true
        )
        let installedEmbeddedManager = fixture.installer.appBundleURL.appendingPathComponent(
            ManagerInstaller.embeddedManagerRelativePath
        )
        try FileManager.default.removeItem(at: installedEmbeddedManager)
        let preservationMarker = fixture.installer.appBundleURL
            .appendingPathComponent("Contents/Resources/preserve-legacy-app.txt")
        try "preserve".write(
            to: preservationMarker,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try fixture.installer.installAppBundle()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Required regular executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ManagerInstaller.embeddedManagerRelativePath
                )
            )
        }

        XCTAssertEqual(
            try String(contentsOf: preservationMarker, encoding: .utf8),
            "preserve"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.installer.appBundleURL.appendingPathComponent(
                    "Contents/MacOS/"
                        + ForgeFilesystemProtocolConstants.daemonExecutableName
                ).path
            )
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingRejectsApplicationMissingPrivilegedDaemon() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        let daemon = fixture.sourceExecutable.deletingLastPathComponent()
            .appendingPathComponent(ForgeFilesystemProtocolConstants.daemonExecutableName)
        try FileManager.default.removeItem(at: daemon)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                requiringPrivilegedApplication: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cannot install the manager Login Item"))
            XCTAssertTrue(error.localizedDescription.contains("Required regular executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ForgeFilesystemProtocolConstants.daemonExecutableName
                )
            )
        }

        XCTAssertTrue(identityValidator.validations.isEmpty)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingRejectsApplicationMissingEmbeddedManagerCLI() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        try FileManager.default.removeItem(at: fixture.sourceManagerExecutable)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                requiringPrivilegedApplication: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cannot install the manager Login Item"))
            XCTAssertTrue(error.localizedDescription.contains("Required regular executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ManagerInstaller.embeddedManagerRelativePath
                )
            )
        }

        XCTAssertTrue(identityValidator.validations.isEmpty)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingRejectsSymlinkedEmbeddedManagerCLI() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        try FileManager.default.removeItem(at: fixture.sourceManagerExecutable)
        try FileManager.default.createSymbolicLink(
            at: fixture.sourceManagerExecutable,
            withDestinationURL: fixture.sourceExecutable
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                requiringPrivilegedApplication: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Required regular executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ManagerInstaller.embeddedManagerRelativePath
                )
            )
        }

        XCTAssertTrue(identityValidator.validations.isEmpty)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testArtifactStagingRejectsMissingRuntimeLauncherWithoutMutation() throws {
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator()
        )
        try FileManager.default.removeItem(at: fixture.sourceRuntimeLauncher)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Required regular executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(ManagerInstaller.runtimeLauncherName)
            )
        }

        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testArtifactStagingRejectsSymlinkedRuntimeLauncherWithoutMutation() throws {
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator()
        )
        try FileManager.default.removeItem(at: fixture.sourceRuntimeLauncher)
        try FileManager.default.createSymbolicLink(
            at: fixture.sourceRuntimeLauncher,
            withDestinationURL: fixture.sourceManagerExecutable
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Required regular executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(ManagerInstaller.runtimeLauncherName)
            )
        }

        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingRejectsApplicationMissingManagerFramework() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        let sourceFramework = fixture.sourceExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Frameworks/ForgeConductorCore.framework",
                isDirectory: true
            )
        try FileManager.default.removeItem(at: sourceFramework)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                requiringPrivilegedApplication: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Required directory"))
            XCTAssertTrue(
                error.localizedDescription.contains("ForgeConductorCore.framework")
            )
        }

        XCTAssertTrue(identityValidator.validations.isEmpty)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testLoginItemStagingRejectsMalformedLaunchDaemonPlist() throws {
        let identityValidator = TestManagerPrivilegedApplicationIdentityValidator()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            privilegedApplicationIdentityValidator: identityValidator
        )
        let sourceApplication = fixture.sourceExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let daemonPlist = sourceApplication.appendingPathComponent(
            "Contents/Library/LaunchDaemons/"
                + ForgeFilesystemProtocolConstants.daemonPlistName
        )
        try "<plist version=\"1.0\"><dict/></plist>".write(
            to: daemonPlist,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                requiringPrivilegedApplication: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cannot install the manager Login Item"))
            XCTAssertTrue(error.localizedDescription.contains("LaunchDaemon plist"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ForgeFilesystemProtocolConstants.serviceName
                )
            )
        }

        XCTAssertTrue(identityValidator.validations.isEmpty)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testPrivilegedApplicationIdentityRequiresExpectedProductSignatures() throws {
        let source = home.appendingPathComponent(ManagerInstaller.preferredBinaryName)
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let expectedTeam = ForgeFilesystemProtocolConstants.activeTeamIdentifier
        let expectedHashes = [
            ForgeFilesystemCodeIdentity.daemonArm64CodeDirectoryHashInfoPlistKey:
                String(repeating: "a", count: 40),
        ]
        func validInspection(
            identifier: String,
            teamIdentifier: String = ForgeFilesystemProtocolConstants.activeTeamIdentifier,
            sealedHashes: [String: String]? = nil
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: teamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }

        let signatureInspector = PathManagerCodeSignatureInspector(
            inspections: [
                source.path: validInspection(
                    identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                    sealedHashes: expectedHashes
                ),
                application.path: validInspection(
                    identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                    sealedHashes: expectedHashes
                ),
                daemon.path: validInspection(
                    identifier: ForgeFilesystemProtocolConstants.daemonIdentifier
                ),
            ]
        )
        let trusted = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: signatureInspector,
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: expectedHashes)
        )
        XCTAssertNoThrow(
            try trusted.validate(applicationBundle: application, invokedBy: source)
        )
        let appRequirement = try XCTUnwrap(
            ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                teamIdentifier: expectedTeam
            )
        )
        let managerRequirement = try XCTUnwrap(
            ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                teamIdentifier: expectedTeam
            )
        )
        let daemonRequirement = try XCTUnwrap(
            ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                teamIdentifier: expectedTeam
            )
        )
        XCTAssertEqual(
            signatureInspector.requirementsByPath[source.path],
            "(\(appRequirement)) or (\(managerRequirement))"
        )
        XCTAssertEqual(signatureInspector.requirementsByPath[application.path], appRequirement)
        XCTAssertEqual(signatureInspector.requirementsByPath[daemon.path], daemonRequirement)

        let wrongDaemon = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    source.path: validInspection(
                        identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                        sealedHashes: expectedHashes
                    ),
                    application.path: validInspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: expectedHashes
                    ),
                    daemon.path: validInspection(
                        identifier: "com.forge-conductor.untrusted-daemon",
                        teamIdentifier: expectedTeam
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: expectedHashes)
        )
        XCTAssertThrowsError(
            try wrongDaemon.validate(applicationBundle: application, invokedBy: source)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("privileged filesystem daemon"))
            XCTAssertTrue(error.localizedDescription.contains("untrusted signing identity"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ForgeFilesystemProtocolConstants.daemonIdentifier
                )
            )
        }
    }

    func testPrivilegedApplicationIdentityRejectsMissingCallerSealedDaemonHash() throws {
        let source = home.appendingPathComponent(ManagerInstaller.preferredBinaryName)
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let expectedHashes = [
            ForgeFilesystemCodeIdentity.daemonArm64CodeDirectoryHashInfoPlistKey:
                String(repeating: "a", count: 40),
        ]
        func inspection(
            identifier: String,
            sealedHashes: [String: String]?
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }
        let validator = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    source.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                        sealedHashes: nil
                    ),
                    application.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: expectedHashes
                    ),
                    daemon.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                        sealedHashes: nil
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: expectedHashes)
        )

        XCTAssertThrowsError(
            try validator.validate(applicationBundle: application, invokedBy: source)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("invoking manager executable"))
            XCTAssertTrue(error.localizedDescription.contains("does not seal"))
            XCTAssertTrue(error.localizedDescription.contains("CodeDirectory hash"))
        }
    }

    func testPrivilegedApplicationIdentityAcceptsAppOriginWithoutExecutableSeal() throws {
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let source = application.appendingPathComponent(
            "Contents/MacOS/\(ManagerInstaller.appDisplayName)"
        )
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let expectedHashes = [
            ForgeFilesystemCodeIdentity.daemonArm64CodeDirectoryHashInfoPlistKey:
                String(repeating: "a", count: 40),
        ]
        func inspection(
            identifier: String,
            sealedHashes: [String: String]?
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }
        let validator = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    source.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: nil
                    ),
                    application.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: expectedHashes
                    ),
                    daemon.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                        sealedHashes: nil
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: expectedHashes)
        )

        XCTAssertNoThrow(
            try validator.validate(applicationBundle: application, invokedBy: source)
        )
    }

    func testPrivilegedApplicationIdentityRejectsStandaloneAppIdentityInvocation() throws {
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let standalone = home.appendingPathComponent("standalone-app-identity")
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let expectedHashes = [
            ForgeFilesystemCodeIdentity.daemonArm64CodeDirectoryHashInfoPlistKey:
                String(repeating: "a", count: 40),
        ]
        func inspection(
            identifier: String,
            sealedHashes: [String: String]?
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }
        let validator = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    standalone.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: nil
                    ),
                    application.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: expectedHashes
                    ),
                    daemon.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                        sealedHashes: nil
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: expectedHashes)
        )

        XCTAssertThrowsError(
            try validator.validate(applicationBundle: application, invokedBy: standalone)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("app entry point"))
            XCTAssertTrue(error.localizedDescription.contains(standalone.path))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Contents/MacOS/\(ManagerInstaller.appDisplayName)"
                )
            )
        }
    }

    func testPrivilegedApplicationIdentityRejectsAppIdentityForStagedManager() throws {
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let stagedExecutable = home.appendingPathComponent(".forge-conductor.stage-copy")
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let daemonHashes = [
            ForgeFilesystemCodeIdentity.daemonArm64CodeDirectoryHashInfoPlistKey:
                String(repeating: "a", count: 40),
        ]
        func inspection(
            identifier: String,
            sealedHashes: [String: String]?
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }
        let validator = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    stagedExecutable.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: nil
                    ),
                    application.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: daemonHashes
                    ),
                    daemon.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                        sealedHashes: nil
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: daemonHashes)
        )
        XCTAssertThrowsError(
            try validator.validateStaged(
                applicationBundle: application,
                executable: stagedExecutable
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("staged executable"))
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ForgeFilesystemProtocolConstants.managerIdentifier
                )
            )
        }
    }

    func testPrivilegedApplicationIdentityRejectsStagedCLISealMismatch() throws {
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let stagedCLI = home.appendingPathComponent(".forge-conductor.stage-cli")
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let key = ForgeFilesystemCodeIdentity
            .daemonArm64CodeDirectoryHashInfoPlistKey
        let daemonHashes = [key: String(repeating: "a", count: 40)]
        let mismatchedHashes = [key: String(repeating: "b", count: 40)]
        func inspection(
            identifier: String,
            sealedHashes: [String: String]?
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }
        let validator = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    stagedCLI.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                        sealedHashes: mismatchedHashes
                    ),
                    application.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: daemonHashes
                    ),
                    daemon.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                        sealedHashes: nil
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: daemonHashes)
        )

        XCTAssertThrowsError(
            try validator.validateStaged(
                applicationBundle: application,
                executable: stagedCLI
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("staged manager executable"))
            XCTAssertTrue(error.localizedDescription.contains("do not match"))
        }
    }

    func testPrivilegedApplicationIdentityRejectsMismatchedAppSealedDaemonHash() throws {
        let source = home.appendingPathComponent(ManagerInstaller.preferredBinaryName)
        let application = home.appendingPathComponent(
            "\(ManagerInstaller.appDisplayName).app",
            isDirectory: true
        )
        let daemon = application.appendingPathComponent(
            "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
        )
        let key = ForgeFilesystemCodeIdentity
            .daemonArm64CodeDirectoryHashInfoPlistKey
        let expectedHashes = [key: String(repeating: "a", count: 40)]
        let mismatchedHashes = [key: String(repeating: "b", count: 40)]
        func inspection(
            identifier: String,
            sealedHashes: [String: String]?
        ) -> ManagerArtifactSignatureInspection {
            ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: identifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.activeTeamIdentifier,
                sealedDaemonCodeDirectoryHashes: sealedHashes,
                validationStatus: errSecSuccess
            )
        }
        let validator = SecurityManagerPrivilegedApplicationIdentityValidator(
            signatureInspector: PathManagerCodeSignatureInspector(
                inspections: [
                    source.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                        sealedHashes: expectedHashes
                    ),
                    application.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.appIdentifier,
                        sealedHashes: mismatchedHashes
                    ),
                    daemon.path: inspection(
                        identifier: ForgeFilesystemProtocolConstants.daemonIdentifier,
                        sealedHashes: nil
                    ),
                ]
            ),
            codeDirectoryHashInspector:
                TestManagerExecutableCodeDirectoryHashInspector(hashes: expectedHashes)
        )

        XCTAssertThrowsError(
            try validator.validate(applicationBundle: application, invokedBy: source)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Forge Conductor app"))
            XCTAssertTrue(error.localizedDescription.contains("do not match"))
            XCTAssertTrue(error.localizedDescription.contains(String(repeating: "a", count: 40)))
            XCTAssertTrue(error.localizedDescription.contains(String(repeating: "b", count: 40)))
        }
    }

    func testManagerArtifactCopyFailurePreservesExistingInstallation() throws {
        let copier = TestManagerArtifactCopier(failingCopy: 4)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            copier: copier
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(copier.copyCount, 4)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerRuntimeLauncherCopyFailurePreservesExistingInstallation() throws {
        let copier = TestManagerArtifactCopier(failingCopy: 2)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            copier: copier
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(copier.copyCount, 2)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactSigningFailurePreservesExistingInstallation() throws {
        let validator = TestManagerArtifactValidator(failingOperation: .sign(.framework))
        let fixture = try makeArtifactFixture(validator: validator)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(
            validator.operations,
            [
                .sign(.executable), .verify(.executable),
                .sign(.executable), .verify(.executable),
                .sign(.framework),
            ]
        )
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactAppVerificationFailurePreservesExistingInstallation() throws {
        let validator = TestManagerArtifactValidator(
            failingOperation: .verify(.applicationBundle)
        )
        let fixture = try makeArtifactFixture(validator: validator)

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(validator.operations.last, .verify(.applicationBundle))
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactCommitFailureRollsBackEarlierReplacements() throws {
        let replacer = TestManagerArtifactReplacer(failingReplacement: 4)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            replacer: replacer
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(from: fixture.sourceExecutable)
        ) { error in
            XCTAssertTrue(error is ManagerArtifactFixtureError)
        }

        XCTAssertEqual(replacer.replacementCount, 4)
        try assertStaleArtifacts(fixture)
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerArtifactTransactionCommitsCommandLinkWithArtifacts() throws {
        let replacer = TestManagerArtifactReplacer()
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            replacer: replacer
        )
        let commandLink = home
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("forge-conductor-swift")
        let priorTarget = home.appendingPathComponent("prior-success-target")
        try FileManager.default.createDirectory(
            at: commandLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "prior".write(to: priorTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: commandLink,
            withDestinationURL: priorTarget
        )

        _ = try fixture.installer.stageInstalledArtifacts(
            from: fixture.sourceExecutable,
            commandLink: commandLink
        )

        XCTAssertEqual(replacer.replacementCount, 6)
        try assertCurrentArtifacts(
            fixture,
            expectedInstalledBinary: "#!/bin/sh\necho embedded-manager\n"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: commandLink.path),
            fixture.installer.installedBinaryURL.path
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testManagerCommandLinkCommitFailureRollsBackEntireArtifactTransaction() throws {
        let replacer = TestManagerArtifactReplacer(failingReplacement: 6)
        let fixture = try makeArtifactFixture(
            validator: TestManagerArtifactValidator(),
            replacer: replacer
        )
        let commandDirectory = home.appendingPathComponent(".local/bin", isDirectory: true)
        let commandLink = commandDirectory.appendingPathComponent("forge-conductor-swift")
        let priorTarget = home.appendingPathComponent("prior-forge-conductor")
        try FileManager.default.createDirectory(
            at: commandDirectory,
            withIntermediateDirectories: true
        )
        try "prior".write(to: priorTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: commandLink,
            withDestinationURL: priorTarget
        )

        XCTAssertThrowsError(
            try fixture.installer.stageInstalledArtifacts(
                from: fixture.sourceExecutable,
                commandLink: commandLink
            )
        ) { error in
            XCTAssertTrue(
                error is ManagerArtifactFixtureError,
                "unexpected link-commit error: \(error)"
            )
        }

        XCTAssertEqual(replacer.replacementCount, 6)
        try assertStaleArtifacts(fixture)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: commandLink.path),
            priorTarget.path
        )
        try assertNoTransactionArtifactsRemain()
    }

    func testProductionSignatureValidatorPreservesValidMachOAndAppMetadata() throws {
        let validator = CodesignManagerArtifactValidator()
        let executable = try makeAdHocMachOFixture(
            name: "valid-tool-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.valid-tool"
        )
        let appFixture = try makeAdHocAppFixture(
            name: "ValidFixture-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.valid-app"
        )
        let frameworkFixture = try makeAdHocFrameworkFixture(
            name: "ValidFramework-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.valid-framework"
        )

        let executableBytes = try Data(contentsOf: executable)
        let executableBefore = try signatureMetadata(at: executable)
        let appBefore = try signatureMetadata(at: appFixture.bundle)
        let nestedBefore = try signatureMetadata(at: appFixture.nestedExecutable)
        let frameworkBefore = try signatureMetadata(at: frameworkFixture.bundle)
        let frameworkBinaryBefore = try signatureMetadata(at: frameworkFixture.executable)

        try validator.prepareAndSign(executable, kind: .executable)
        try validator.verify(executable, kind: .executable)
        try validator.prepareAndSign(appFixture.bundle, kind: .applicationBundle)
        try validator.verify(appFixture.bundle, kind: .applicationBundle)
        try validator.prepareAndSign(frameworkFixture.bundle, kind: .framework)
        try validator.verify(frameworkFixture.bundle, kind: .framework)

        XCTAssertEqual(try Data(contentsOf: executable), executableBytes)
        XCTAssertEqual(try signatureMetadata(at: executable), executableBefore)
        XCTAssertEqual(try signatureMetadata(at: appFixture.bundle), appBefore)
        XCTAssertEqual(
            try signatureMetadata(at: appFixture.nestedExecutable),
            nestedBefore
        )
        XCTAssertEqual(try signatureMetadata(at: frameworkFixture.bundle), frameworkBefore)
        XCTAssertEqual(
            try signatureMetadata(at: frameworkFixture.executable),
            frameworkBinaryBefore
        )
        XCTAssertTrue(executableBefore.flags.contains(.runtime))
        XCTAssertTrue(appBefore.flags.contains(.runtime))
        XCTAssertTrue(frameworkBefore.flags.contains(.runtime))
    }

    func testSecuritySignatureInspectorAppliesExplicitProductRequirement() throws {
        let executable = try makeAdHocMachOFixture(
            name: "requirement-fixture-\(UUID().uuidString)",
            identifier: ForgeFilesystemProtocolConstants.managerIdentifier
        )
        let inspector = SecurityManagerCodeSignatureInspector()
        XCTAssertEqual(
            try inspector.inspect(executable, kind: .executable).state,
            .valid
        )

        let requirement = try XCTUnwrap(
            ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: ForgeFilesystemProtocolConstants.managerIdentifier,
                teamIdentifier: ForgeFilesystemProtocolConstants.developmentTeamIdentifier
            )
        )
        let constrained = try inspector.inspect(
            executable,
            kind: .executable,
            requirement: requirement
        )
        XCTAssertEqual(constrained.state, .invalidAdHoc)
        XCTAssertNotEqual(constrained.validationStatus, errSecSuccess)
    }

    func testProductionSignatureValidatorRepairsUnsignedMachOWithStableRuntimeIdentity() throws {
        let validator = CodesignManagerArtifactValidator()
        let first = try makeUnsignedMachOFixture(name: ".unsigned-stage-\(UUID().uuidString)")
        let second = try makeUnsignedMachOFixture(name: ".unsigned-stage-\(UUID().uuidString)")

        try validator.prepareAndSign(first, kind: .executable)
        try validator.verify(first, kind: .executable)
        try validator.prepareAndSign(second, kind: .executable)
        try validator.verify(second, kind: .executable)

        let firstMetadata = try signatureMetadata(at: first)
        let secondMetadata = try signatureMetadata(at: second)
        XCTAssertEqual(firstMetadata.identifier, "com.forge-conductor.cli")
        XCTAssertEqual(secondMetadata.identifier, firstMetadata.identifier)
        XCTAssertTrue(firstMetadata.flags.contains(.adhoc))
        XCTAssertTrue(firstMetadata.flags.contains(.runtime))
        XCTAssertTrue(secondMetadata.flags.contains(.adhoc))
        XCTAssertTrue(secondMetadata.flags.contains(.runtime))
    }

    func testProductionSignatureValidatorRepairsInvalidAdHocAppWithoutChangingNestedIdentity() throws {
        let validator = CodesignManagerArtifactValidator()
        let entitlements = try makeTestEntitlements()
        let fixture = try makeAdHocAppFixture(
            name: "RepairFixture-\(UUID().uuidString)",
            identifier: "com.forge-conductor.tests.repair-app",
            entitlements: entitlements
        )
        let appBefore = try signatureMetadata(at: fixture.bundle)
        let nestedBefore = try signatureMetadata(at: fixture.nestedExecutable)
        try "changed after signing".write(
            to: fixture.resource,
            atomically: true,
            encoding: .utf8
        )

        let invalid = try SecurityManagerCodeSignatureInspector().inspect(
            fixture.bundle,
            kind: .applicationBundle
        )
        XCTAssertEqual(invalid.state, .invalidAdHoc)

        try validator.prepareAndSign(fixture.bundle, kind: .applicationBundle)
        try validator.verify(fixture.bundle, kind: .applicationBundle)

        let appAfter = try signatureMetadata(at: fixture.bundle)
        XCTAssertEqual(appAfter.identifier, appBefore.identifier)
        XCTAssertEqual(appAfter.entitlementsJSON, appBefore.entitlementsJSON)
        XCTAssertTrue(appAfter.flags.contains(.adhoc))
        XCTAssertTrue(appAfter.flags.contains(.runtime))
        XCTAssertEqual(
            try signatureMetadata(at: fixture.nestedExecutable),
            nestedBefore
        )
    }

    func testProductionSignatureValidatorRejectsInvalidCMSWithoutMutation() throws {
        let fixture = home.appendingPathComponent("invalid-cms-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: fixture)
        try invalidateMachOSlices(at: fixture)
        let before = try Data(contentsOf: fixture)
        let quarantine = Data("0081;fixture;ForgeConductorTests;".utf8)
        try setExtendedAttribute(
            named: "com.apple.quarantine",
            value: quarantine,
            at: fixture
        )
        XCTAssertEqual(
            try extendedAttribute(named: "com.apple.quarantine", at: fixture),
            quarantine
        )
        let inspection = try SecurityManagerCodeSignatureInspector().inspect(
            fixture,
            kind: .executable
        )
        XCTAssertEqual(inspection.state, .invalidCMS)

        XCTAssertThrowsError(
            try CodesignManagerArtifactValidator().prepareAndSign(
                fixture,
                kind: .executable
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid CMS/team signature"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture), before)
        XCTAssertEqual(
            try extendedAttribute(named: "com.apple.quarantine", at: fixture),
            quarantine
        )
        XCTAssertEqual(
            try SecurityManagerCodeSignatureInspector()
                .inspect(fixture, kind: .executable).state,
            .invalidCMS
        )
    }

    func testSignatureInspectionErrorsAndAmbiguousMetadataFailClosed() throws {
        let fixture = try makeUnsignedMachOFixture(name: "fail-closed-\(UUID().uuidString)")
        let before = try Data(contentsOf: fixture)
        let ambiguous = TestManagerCodeSignatureInspector(
            inspection: ManagerArtifactSignatureInspection(
                state: .indeterminate,
                identifier: nil,
                teamIdentifier: nil,
                sealedDaemonCodeDirectoryHashes: nil,
                validationStatus: errSecCSBadObjectFormat
            )
        )
        let validator = CodesignManagerArtifactValidator(signatureInspector: ambiguous)

        XCTAssertThrowsError(
            try validator.prepareAndSign(fixture, kind: .executable)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("indeterminate signature metadata"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture), before)
    }

    func testProductionSignatureValidatorPreservesValidTeamSignedAppWhenAvailable() throws {
        guard let source = try validTeamSignedAppFixture() else {
            throw XCTSkip("No valid local team-signed Forge app fixture is available")
        }
        let destination = home.appendingPathComponent("TeamFixture-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: source, to: destination)
        let before = try signatureMetadata(at: destination)
        guard let teamIdentifier = before.teamIdentifier, !teamIdentifier.isEmpty else {
            throw XCTSkip("The valid app fixture has no TeamIdentifier")
        }

        let validator = CodesignManagerArtifactValidator()
        try validator.prepareAndSign(destination, kind: .applicationBundle)
        try validator.verify(destination, kind: .applicationBundle)
        let after = try signatureMetadata(at: destination)

        XCTAssertEqual(after, before)
        XCTAssertEqual(after.teamIdentifier, teamIdentifier)
    }

    func testLoginAgentFallbackRejectsLoadSuccessWithoutLiveJobAndPositivePID() throws {
        let uid: uid_t = 501
        let userDomain = "gui/\(uid)"
        let jobTarget = "\(userDomain)/\(ManagerInstaller.launchAgentLabel)"
        let plistURL = home.appendingPathComponent("manager.plist")
        let readinessFailures = [
            missingLaunchctlJobResult(),
            launchctlResult(
                exitCode: 0,
                stdout: "\(jobTarget) = {\n\tstate = waiting\n"
                    + "\tprogram = \(home.path)/wrong-manager\n}"
            ),
        ]

        for readiness in readinessFailures {
            let runner = TestManagerLaunchctlRunner(results: [
                missingLaunchctlJobResult(),
                launchctlResult(exitCode: 5, stderr: "bootstrap unavailable"),
                launchctlResult(exitCode: 0),
                launchctlResult(exitCode: 0),
                readiness,
                readiness,
                launchctlResult(exitCode: 0),
                launchctlResult(exitCode: 0),
                launchctlResult(exitCode: 0),
                missingLaunchctlJobResult(),
            ])
            let paths = AppPaths(home: home)
            let installer = ManagerInstaller(
                paths: paths,
                config: ConfigStore(paths: paths),
                artifactValidator: TestManagerArtifactValidator(),
                launchctlRunner: runner
            )

            XCTAssertThrowsError(
                try installer.loadLoginAgent(
                    plistURL: plistURL,
                    uid: uid,
                    readinessAttempts: 2,
                    readinessDelaySec: 0
                )
            ) { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, "ManagerInstaller")
                XCTAssertEqual(nsError.code, 2)
                XCTAssertTrue(nsError.localizedDescription.contains("launchctl load failed"))
                XCTAssertTrue(nsError.localizedDescription.contains(jobTarget))
                XCTAssertTrue(nsError.localizedDescription.contains("positive pid"))
                XCTAssertTrue(
                    nsError.localizedDescription.contains("cleanup_exact_job_absent=true")
                )
            }
            XCTAssertEqual(
                runner.invocations,
                [
                    .init(arguments: ["print", jobTarget], timeoutSec: 5),
                    .init(
                        arguments: ["bootstrap", userDomain, plistURL.path],
                        timeoutSec: 15
                    ),
                    .init(
                        arguments: ["load", "-w", plistURL.path],
                        timeoutSec: 15
                    ),
                    .init(
                        arguments: ["kickstart", "-k", jobTarget],
                        timeoutSec: 10
                    ),
                    .init(arguments: ["print", jobTarget], timeoutSec: 5),
                    .init(arguments: ["print", jobTarget], timeoutSec: 5),
                    .init(arguments: ["bootout", jobTarget], timeoutSec: 10),
                    .init(arguments: ["disable", jobTarget], timeoutSec: 5),
                    .init(
                        arguments: ["unload", "-w", plistURL.path],
                        timeoutSec: 10
                    ),
                    .init(arguments: ["print", jobTarget], timeoutSec: 5),
                ]
            )
        }
    }

    func testLoginAgentRejectsPreexistingExactJobBeforeBootstrapAndCleansUp() throws {
        let uid: uid_t = 501
        let userDomain = "gui/\(uid)"
        let jobTarget = "\(userDomain)/\(ManagerInstaller.launchAgentLabel)"
        let plistURL = home.appendingPathComponent("manager.plist")
        let paths = AppPaths(home: home)
        let runner = TestManagerLaunchctlRunner(results: [
            launchctlResult(
                exitCode: 0,
                stdout: "\(jobTarget) = {\n\tstate = running\n\tpid = 9001\n"
                    + "\tprogram = \(paths.home.path)/stale-manager\n}"
            ),
            launchctlResult(exitCode: 0),
            launchctlResult(exitCode: 0),
            launchctlResult(exitCode: 0),
            missingLaunchctlJobResult(),
        ])
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: TestManagerArtifactValidator(),
            launchctlRunner: runner
        )

        XCTAssertThrowsError(
            try installer.loadLoginAgent(
                plistURL: plistURL,
                uid: uid,
                readinessAttempts: 1,
                readinessDelaySec: 0
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ManagerInstaller")
            XCTAssertEqual(nsError.code, 2)
            XCTAssertTrue(nsError.localizedDescription.contains("still present"))
            XCTAssertTrue(
                nsError.localizedDescription.contains("cleanup_exact_job_absent=true")
            )
        }
        XCTAssertEqual(
            runner.invocations,
            [
                .init(arguments: ["print", jobTarget], timeoutSec: 5),
                .init(arguments: ["bootout", jobTarget], timeoutSec: 10),
                .init(arguments: ["disable", jobTarget], timeoutSec: 5),
                .init(arguments: ["unload", "-w", plistURL.path], timeoutSec: 10),
                .init(arguments: ["print", jobTarget], timeoutSec: 5),
            ]
        )
    }

    func testLoginAgentRejectsPositivePIDForWrongProgramAndCleansUp() throws {
        let uid: uid_t = 501
        let userDomain = "gui/\(uid)"
        let jobTarget = "\(userDomain)/\(ManagerInstaller.launchAgentLabel)"
        let plistURL = home.appendingPathComponent("manager.plist")
        let paths = AppPaths(home: home)
        let wrongProgram = home.appendingPathComponent("wrong-manager").path
        try "fixture".write(to: plistURL, atomically: true, encoding: .utf8)
        let wrongReadiness = launchctlResult(
            exitCode: 0,
            stdout: "\(jobTarget) = {\n\tstate = running\n\tpid = 4321\n"
                + "\tprogram = \(wrongProgram)\n}"
        )
        let runner = TestManagerLaunchctlRunner(results: [
            missingLaunchctlJobResult(),
            launchctlResult(exitCode: 5, stderr: "bootstrap unavailable"),
            launchctlResult(exitCode: 0),
            launchctlResult(exitCode: 0),
            wrongReadiness,
            wrongReadiness,
            launchctlResult(exitCode: 0),
            launchctlResult(exitCode: 0),
            launchctlResult(exitCode: 0),
            missingLaunchctlJobResult(),
        ])
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: TestManagerArtifactValidator(),
            launchctlRunner: runner
        )

        XCTAssertThrowsError(
            try installer.loadLoginAgent(
                plistURL: plistURL,
                uid: uid,
                readinessAttempts: 2,
                readinessDelaySec: 0
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ManagerInstaller")
            XCTAssertEqual(nsError.code, 2)
            XCTAssertTrue(nsError.localizedDescription.contains("expected program"))
            XCTAssertTrue(nsError.localizedDescription.contains(wrongProgram))
        }
        XCTAssertEqual(
            Array(runner.invocations.suffix(4)),
            [
                .init(arguments: ["bootout", jobTarget], timeoutSec: 10),
                .init(arguments: ["disable", jobTarget], timeoutSec: 5),
                .init(arguments: ["unload", "-w", plistURL.path], timeoutSec: 10),
                .init(arguments: ["print", jobTarget], timeoutSec: 5),
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testLoginAgentFailureReportsWhenCleanupCannotProveJobAbsence() throws {
        let uid: uid_t = 501
        let userDomain = "gui/\(uid)"
        let jobTarget = "\(userDomain)/\(ManagerInstaller.launchAgentLabel)"
        let plistURL = home.appendingPathComponent("manager.plist")
        let paths = AppPaths(home: home)
        let retainedJob = launchctlResult(
            exitCode: 0,
            stdout: "\(jobTarget) = {\n\tstate = running\n\tpid = 9001\n"
                + "\tprogram = \(paths.home.path)/stale-manager\n}"
        )
        try "fixture".write(to: plistURL, atomically: true, encoding: .utf8)
        let runner = TestManagerLaunchctlRunner(results: [
            retainedJob,
            launchctlResult(exitCode: 5, stderr: "bootout denied"),
            launchctlResult(exitCode: 5, stderr: "disable denied"),
            launchctlResult(exitCode: 5, stderr: "unload denied"),
            retainedJob,
            retainedJob,
        ])
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: TestManagerArtifactValidator(),
            launchctlRunner: runner
        )

        XCTAssertThrowsError(
            try installer.loadLoginAgent(
                plistURL: plistURL,
                uid: uid,
                readinessAttempts: 2,
                readinessDelaySec: 0
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ManagerInstaller")
            XCTAssertEqual(nsError.code, 2)
            XCTAssertTrue(
                nsError.localizedDescription.contains("cleanup_exact_job_absent=false")
            )
            XCTAssertTrue(nsError.localizedDescription.contains("bootout_exit=5"))
            XCTAssertTrue(nsError.localizedDescription.contains("pid=9001"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertEqual(
            runner.invocations.filter { $0.arguments.first == "print" }.count,
            3
        )
    }

    func testLoginAgentFallbackAcceptsExactLiveJobWithPositivePID() throws {
        let uid: uid_t = 501
        let userDomain = "gui/\(uid)"
        let jobTarget = "\(userDomain)/\(ManagerInstaller.launchAgentLabel)"
        let plistURL = home.appendingPathComponent("manager.plist")
        let paths = AppPaths(home: home)
        let expectedProgram = paths.home
            .appendingPathComponent("\(ManagerInstaller.appDisplayName).app/Contents/MacOS")
            .appendingPathComponent(ManagerInstaller.appDisplayName)
            .path
        let runner = TestManagerLaunchctlRunner(results: [
            missingLaunchctlJobResult(),
            launchctlResult(exitCode: 5, stderr: "bootstrap unavailable"),
            launchctlResult(exitCode: 0),
            launchctlResult(exitCode: 64, stderr: "already running"),
            launchctlResult(
                exitCode: 0,
                stdout: "\(jobTarget) = {\n\tstate = waiting\n"
                    + "\tprogram = \(expectedProgram)\n}"
            ),
            launchctlResult(
                exitCode: 0,
                stdout: "\(jobTarget) = {\n\tstate = running\n\tpid = 4321\n"
                    + "\tprogram = \(expectedProgram)\n}"
            ),
        ])
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: TestManagerArtifactValidator(),
            launchctlRunner: runner
        )

        XCTAssertNoThrow(
            try installer.loadLoginAgent(
                plistURL: plistURL,
                uid: uid,
                readinessAttempts: 2,
                readinessDelaySec: 0
            )
        )
        XCTAssertEqual(runner.invocations.last?.arguments, ["print", jobTarget])
        XCTAssertEqual(
            runner.invocations.filter { $0.arguments.first == "print" }.count,
            3
        )
    }

    func testLaunchAgentLogRotationRetainsOnlyBoundedTailsInForgeHome() throws {
        let fm = FileManager.default
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(paths: paths, config: ConfigStore(paths: paths))
        let output = installer.launchAgentStandardOutputURL
        let error = installer.launchAgentStandardErrorURL
        let output1 = URL(fileURLWithPath: "\(output.path).1")
        let output2 = URL(fileURLWithPath: "\(output.path).2")
        let error1 = URL(fileURLWithPath: "\(error.path).1")

        try "0123456789ABCDEFGHIJ".write(to: output, atomically: true, encoding: .utf8)
        try "error-current".write(to: error, atomically: true, encoding: .utf8)
        try "previous-output".write(to: output1, atomically: true, encoding: .utf8)
        try "discarded-oldest".write(to: output2, atomically: true, encoding: .utf8)

        try installer.rotateLaunchAgentLogs(maxBytesPerFile: 8, retainedGenerations: 2)

        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(fm.fileExists(atPath: error.path))
        XCTAssertEqual(try String(contentsOf: output1, encoding: .utf8), "CDEFGHIJ")
        XCTAssertEqual(try String(contentsOf: output2, encoding: .utf8), "s-output")
        XCTAssertEqual(try String(contentsOf: error1, encoding: .utf8), "-current")
        XCTAssertLessThanOrEqual(try Data(contentsOf: output1).count, 8)
        XCTAssertLessThanOrEqual(try Data(contentsOf: output2).count, 8)
        XCTAssertLessThanOrEqual(try Data(contentsOf: error1).count, 8)
    }

    func testLaunchAgentLogRotationBoundsAndPrunesArchivesWithoutCurrentContent() throws {
        let fm = FileManager.default
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(paths: paths, config: ConfigStore(paths: paths))
        let output = installer.launchAgentStandardOutputURL
        let error = installer.launchAgentStandardErrorURL
        let output1 = URL(fileURLWithPath: "\(output.path).1")
        let output2 = URL(fileURLWithPath: "\(output.path).2")
        let output3 = URL(fileURLWithPath: "\(output.path).3")
        let output7 = URL(fileURLWithPath: "\(output.path).7")
        let error1 = URL(fileURLWithPath: "\(error.path).1")
        let error3 = URL(fileURLWithPath: "\(error.path).3")
        let previousOutput1 = "0123456789ABC"
        let previousOutput2 = "ABCDEFGHIJKL"
        let previousError1 = "error-archive-long"

        try previousOutput1.write(to: output1, atomically: true, encoding: .utf8)
        try previousOutput2.write(to: output2, atomically: true, encoding: .utf8)
        try "prune-three".write(to: output3, atomically: true, encoding: .utf8)
        try "prune-seven".write(to: output7, atomically: true, encoding: .utf8)
        try Data().write(to: error, options: .atomic)
        try previousError1.write(to: error1, atomically: true, encoding: .utf8)
        try "prune-error".write(to: error3, atomically: true, encoding: .utf8)

        try installer.rotateLaunchAgentLogs(maxBytesPerFile: 8, retainedGenerations: 2)

        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(fm.fileExists(atPath: error.path))
        XCTAssertEqual(
            try String(contentsOf: output1, encoding: .utf8),
            String(previousOutput1.suffix(8))
        )
        XCTAssertEqual(
            try String(contentsOf: output2, encoding: .utf8),
            String(previousOutput2.suffix(8))
        )
        XCTAssertEqual(
            try String(contentsOf: error1, encoding: .utf8),
            String(previousError1.suffix(8))
        )
        XCTAssertFalse(fm.fileExists(atPath: output3.path))
        XCTAssertFalse(fm.fileExists(atPath: output7.path))
        XCTAssertFalse(fm.fileExists(atPath: error3.path))
    }

    private struct SignatureMetadata: Equatable {
        var identifier: String?
        var teamIdentifier: String?
        var flags: SecCodeSignatureFlags
        var uniqueHash: Data?
        var entitlementsJSON: Data?
    }

    private struct AppSignatureFixture {
        var bundle: URL
        var executable: URL
        var nestedExecutable: URL
        var resource: URL
    }

    private struct FrameworkSignatureFixture {
        var bundle: URL
        var executable: URL
    }

    private struct StagedRelinkTransitionFixture {
        let projectID: ProjectID
        let expectedGeneration: ProjectGeneration
        let replacement: URL
        let preparation: ProjectRelinkIdentityPreparation
    }

    private func stageRelinkTransition(
        app: ForgeApp,
        root: URL,
        name: String
    ) throws -> StagedRelinkTransitionFixture {
        let original = root.appendingPathComponent(
            "\(name)-original",
            isDirectory: true
        )
        let replacement = root.appendingPathComponent(
            "\(name)-replacement",
            isDirectory: true
        )
        for directory in [original, replacement] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try writeGitRemote(
                "ssh://git@example.test/team/\(name).git",
                to: directory
            )
        }
        let registered = try ManagerNode(app: app).registerProject(path: original.path)
        let projectUUID = try XCTUnwrap(
            (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
        )
        let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
        let projectID = ProjectID(projectUUID)
        let expectedGeneration = ProjectGeneration(generation)
        let target = try app.projectMemory.identities.discoverTarget(
            path: replacement.path
        )
        let repositoryIdentity = try XCTUnwrap(
            try app.projectContexts.project(projectID)?.repositoryFingerprint
        )
        let preparation = try app.projectMemory.identities.prepareRelink(
            target: target,
            projectID: projectID.description,
            expectedGeneration: expectedGeneration,
            expectedRepositoryIdentity: repositoryIdentity
        )
        let receipt = try app.projectContexts.relinkProject(
            projectID: projectID,
            expectedGeneration: expectedGeneration,
            target: preparation.target,
            transitionOperationID: preparation.operationID
        )
        XCTAssertEqual(receipt.newGeneration.rawValue, generation + 1)
        let staged = try XCTUnwrap(try app.projectContexts.project(projectID))
        XCTAssertEqual(staged.lifecycleState, .maintenance)
        return StagedRelinkTransitionFixture(
            projectID: projectID,
            expectedGeneration: expectedGeneration,
            replacement: replacement.standardizedFileURL,
            preparation: preparation
        )
    }

    private func projectTransitionMetadata(
        for preparation: ProjectRelinkIdentityPreparation
    ) -> [String: String] {
        [
            "operation_id": preparation.operationID,
            "prior_generation": String(preparation.expectedGeneration.rawValue),
            "new_generation": String(preparation.expectedGeneration.rawValue + 1),
            "target_root_sha256": JSONSupport.sha256Hex(
                preparation.target.canonicalRoot.path
            ),
            "repository_identity_sha256": JSONSupport.sha256Hex(
                preparation.target.repositoryIdentity ?? ""
            ),
            "directory_device": String(preparation.target.directoryIdentity.device),
            "directory_inode": String(preparation.target.directoryIdentity.inode),
        ]
    }

    private func assertExternalProcessCannotUseMaintenanceGeneration(
        projectID: UUID,
        generation: UInt64,
        canonicalRoot: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let output = ManagerBoundedProcessOutput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "ForgeConductorTests.ManagerTests/testExternalProcessRelinkLockHolder",
            Bundle(for: ManagerTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        for key in ["XCTestSessionIdentifier", "XCTestConfigurationFilePath"] {
            environment.removeValue(forKey: key)
        }
        environment["FORGE_PROJECT_TRANSITION_CHILD_MODE"] =
            "assert-maintenance-fence"
        environment["FORGE_RELINK_CHILD_HOME"] = home.path
        environment["FORGE_RELINK_CHILD_PROJECT_ID"] =
            projectID.uuidString.lowercased()
        environment["FORGE_RELINK_CHILD_GENERATION"] = String(generation)
        environment["FORGE_PROJECT_TRANSITION_CHILD_ROOT"] = canonicalRoot.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output.pipe
        process.standardError = output.pipe
        try process.run()
        output.closeParentWriter()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let transcript = output.finish()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "External maintenance-fence probe failed: \(transcript)",
            file: file,
            line: line
        )
    }

    private func writeGitRemote(_ remote: String, to root: URL) throws {
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data(
            "[remote \"origin\"]\n\turl = \(remote)\n".utf8
        ).write(to: git.appendingPathComponent("config"), options: .atomic)
    }

    private func makeAdHocMachOFixture(name: String, identifier: String) throws -> URL {
        let destination = home.appendingPathComponent(name)
        try FileManager.default.copyItem(at: testHostExecutable(), to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        try clearExtendedAttributes(at: destination)
        try signAdHoc(destination, identifier: identifier)
        return destination
    }

    private func makeUnsignedMachOFixture(name: String) throws -> URL {
        let destination = home.appendingPathComponent(name)
        try FileManager.default.copyItem(at: testHostExecutable(), to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        try runRequired(
            executable: "/usr/bin/codesign",
            arguments: ["--remove-signature", destination.path]
        )
        let inspection = try SecurityManagerCodeSignatureInspector().inspect(
            destination,
            kind: .executable
        )
        XCTAssertEqual(inspection.state, .unsigned)
        return destination
    }

    private func makeAdHocAppFixture(
        name: String,
        identifier: String,
        entitlements: URL? = nil
    ) throws -> AppSignatureFixture {
        let bundle = home.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let executableName = "FixtureExecutable"
        let executable = macOS.appendingPathComponent(executableName)
        try FileManager.default.copyItem(at: testHostExecutable(), to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try clearExtendedAttributes(at: executable)
        try signAdHoc(executable, identifier: "\(identifier).executable")
        let nestedExecutable = helpers.appendingPathComponent("FixtureHelper")
        try FileManager.default.copyItem(at: testHostExecutable(), to: nestedExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nestedExecutable.path
        )
        try clearExtendedAttributes(at: nestedExecutable)
        try signAdHoc(nestedExecutable, identifier: "\(identifier).helper")

        let info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        let resource = resources.appendingPathComponent("payload.txt")
        try "original".write(to: resource, atomically: true, encoding: .utf8)

        try clearExtendedAttributes(at: bundle)
        try signAdHoc(bundle, identifier: identifier, entitlements: entitlements)
        return AppSignatureFixture(
            bundle: bundle,
            executable: executable,
            nestedExecutable: nestedExecutable,
            resource: resource
        )
    }

    private func makeAdHocFrameworkFixture(
        name: String,
        identifier: String
    ) throws -> FrameworkSignatureFixture {
        let frameworkName = name.replacingOccurrences(of: ".framework", with: "")
        let bundle = home.appendingPathComponent("\(frameworkName).framework", isDirectory: true)
        let versions = bundle.appendingPathComponent("Versions", isDirectory: true)
        let versionA = versions.appendingPathComponent("A", isDirectory: true)
        let resources = versionA.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let executable = versionA.appendingPathComponent(frameworkName)
        try FileManager.default.copyItem(at: testHostExecutable(), to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try clearExtendedAttributes(at: executable)
        try signAdHoc(executable, identifier: "\(identifier).binary")

        let info: [String: Any] = [
            "CFBundleExecutable": frameworkName,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": frameworkName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: resources.appendingPathComponent("Info.plist"), options: .atomic)
        try FileManager.default.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path,
            withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent(frameworkName).path,
            withDestinationPath: "Versions/Current/\(frameworkName)"
        )
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Resources").path,
            withDestinationPath: "Versions/Current/Resources"
        )

        try clearExtendedAttributes(at: bundle)
        try signAdHoc(bundle, identifier: identifier)
        return FrameworkSignatureFixture(bundle: bundle, executable: executable)
    }

    private func makeTestEntitlements() throws -> URL {
        let url = home.appendingPathComponent("fixture-entitlements-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.get-task-allow": true],
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private func signAdHoc(
        _ url: URL,
        identifier: String,
        entitlements: URL? = nil
    ) throws {
        var arguments = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            "--options", "runtime",
            "--identifier", identifier,
        ]
        if let entitlements {
            arguments.append(contentsOf: ["--entitlements", entitlements.path])
        }
        arguments.append(url.path)
        try runRequired(executable: "/usr/bin/codesign", arguments: arguments)
    }

    private func clearExtendedAttributes(at url: URL) throws {
        try runRequired(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", url.path]
        )
    }

    private func setExtendedAttribute(
        named name: String,
        value: Data,
        at url: URL
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            setxattr(
                url.path,
                name,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func extendedAttribute(named name: String, at url: URL) throws -> Data? {
        errno = 0
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var value = Data(count: size)
        let bytesRead = value.withUnsafeMutableBytes { bytes in
            getxattr(
                url.path,
                name,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        guard bytesRead == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return value
    }

    private func runRequired(executable: String, arguments: [String]) throws {
        let result: ProcessResult
        do {
            result = try ProcessRunner().run(
                executable: executable,
                arguments: arguments,
                timeoutSec: 60
            )
        } catch {
            throw NSError(
                domain: "ManagerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(executable) \(arguments.joined(separator: " ")) threw: \(error)"]
            )
        }
        guard result.exitCode == 0, !result.timedOut else {
            throw NSError(
                domain: "ManagerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(executable) \(arguments.joined(separator: " ")) failed "
                    + "(exit \(result.exitCode)): \(result.stderr)"]
            )
        }
    }

    private func testHostExecutable() throws -> URL {
        let url = URL(fileURLWithPath: "/usr/bin/true").resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(
                domain: "ManagerTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Mach-O fixture source is not executable: \(url.path)"]
            )
        }
        return url
    }

    private func signatureMetadata(at url: URL) throws -> SignatureMetadata {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url.standardizedFileURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw NSError(
                domain: "ManagerTests",
                code: Int(createStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "SecStaticCodeCreateWithPath failed for \(url.path): \(createStatus)"]
            )
        }

        var rawInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard infoStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any],
              let flagsNumber = information[kSecCodeInfoFlags] as? NSNumber else {
            throw NSError(
                domain: "ManagerTests",
                code: Int(infoStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "SecCodeCopySigningInformation failed for \(url.path): \(infoStatus)"]
            )
        }

        let entitlementsJSON: Data?
        if let entitlements = information[kSecCodeInfoEntitlementsDict] as? [String: Any],
           JSONSerialization.isValidJSONObject(entitlements) {
            entitlementsJSON = try JSONSerialization.data(
                withJSONObject: entitlements,
                options: [.sortedKeys]
            )
        } else {
            entitlementsJSON = nil
        }

        return SignatureMetadata(
            identifier: information[kSecCodeInfoIdentifier] as? String,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
            flags: SecCodeSignatureFlags(rawValue: flagsNumber.uint32Value),
            uniqueHash: information[kSecCodeInfoUnique] as? Data,
            entitlementsJSON: entitlementsJSON
        )
    }

    private func invalidateMachOSlices(at url: URL) throws {
        var data = try Data(contentsOf: url)

        func bigEndianUInt32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else {
                throw NSError(
                    domain: "ManagerTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Malformed Mach-O fixture"]
                )
            }
            return data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }

        let magic = try bigEndianUInt32(at: 0)
        var sliceOffsets: [Int] = []
        switch magic {
        case 0xCAFEBABE:
            let count = Int(try bigEndianUInt32(at: 4))
            for index in 0..<count {
                let entry = 8 + index * 20
                sliceOffsets.append(Int(try bigEndianUInt32(at: entry + 8)))
            }
        case 0xCAFEBABF:
            let count = Int(try bigEndianUInt32(at: 4))
            for index in 0..<count {
                let entry = 8 + index * 32
                let high = UInt64(try bigEndianUInt32(at: entry + 8))
                let low = UInt64(try bigEndianUInt32(at: entry + 12))
                sliceOffsets.append(Int((high << 32) | low))
            }
        default:
            sliceOffsets = [0]
        }

        for sliceOffset in sliceOffsets {
            let mutationOffset = sliceOffset + 1_024
            guard mutationOffset < data.count else {
                throw NSError(
                    domain: "ManagerTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Mach-O fixture is too small to invalidate safely"]
                )
            }
            data[mutationOffset] ^= 0x01
        }
        try data.write(to: url)
    }

    private func validTeamSignedAppFixture() throws -> URL? {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["FORGE_TEST_TEAM_SIGNED_APP"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    ".build/xcode/Build/Products/Debug/Forge Conductor.app",
                    isDirectory: true
                )
        )
        candidates.append(
            URL(fileURLWithPath: "/Applications/Forge Conductor.app", isDirectory: true)
        )

        let inspector = SecurityManagerCodeSignatureInspector()
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard let metadata = try? signatureMetadata(at: candidate),
                  let teamIdentifier = metadata.teamIdentifier,
                  !teamIdentifier.isEmpty,
                  let inspection = try? inspector.inspect(candidate, kind: .applicationBundle),
                  inspection.state == .valid else {
                continue
            }
            return candidate
        }
        return nil
    }

    private struct ArtifactFixture {
        let installer: ManagerInstaller
        let sourceExecutable: URL
        let sourceManagerExecutable: URL
        let sourceRuntimeLauncher: URL
        let installedFramework: URL
        let mirroredFramework: URL
    }

    private func makeArtifactFixture(
        validator: any ManagerArtifactValidating,
        copier: any ManagerArtifactCopying = TestManagerArtifactCopier(),
        replacer: any ManagerArtifactReplacing = TestManagerArtifactReplacer(),
        privilegedApplicationIdentityValidator:
            any ManagerPrivilegedApplicationIdentityValidating =
                TestManagerPrivilegedApplicationIdentityValidator()
    ) throws -> ArtifactFixture {
        let fm = FileManager.default
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let installer = ManagerInstaller(
            paths: paths,
            config: ConfigStore(paths: paths),
            artifactValidator: validator,
            artifactCopier: copier,
            artifactReplacer: replacer,
            privilegedApplicationIdentityValidator:
                privilegedApplicationIdentityValidator
        )

        let sourceBundle = home
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent("\(ManagerInstaller.appDisplayName).app", isDirectory: true)
        let sourceContents = sourceBundle.appendingPathComponent("Contents", isDirectory: true)
        let sourceMacOS = sourceContents.appendingPathComponent("MacOS", isDirectory: true)
        let sourceHelpers = sourceContents.appendingPathComponent("Helpers", isDirectory: true)
        let sourceResources = sourceContents.appendingPathComponent("Resources", isDirectory: true)
        let sourceLaunchDaemons = sourceContents
            .appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
        let sourceFramework = sourceContents
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        try fm.createDirectory(at: sourceMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceHelpers, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceResources, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceLaunchDaemons, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceFramework, withIntermediateDirectories: true)

        let sourceExecutable = sourceMacOS.appendingPathComponent(ManagerInstaller.appDisplayName)
        try "#!/bin/sh\necho current\n".write(
            to: sourceExecutable,
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceExecutable.path)
        let sourceManagerExecutable = sourceHelpers.appendingPathComponent(
            ManagerInstaller.preferredBinaryName
        )
        try "#!/bin/sh\necho embedded-manager\n".write(
            to: sourceManagerExecutable,
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceManagerExecutable.path
        )
        let sourceRuntimeLauncher = sourceHelpers.appendingPathComponent(
            ManagerInstaller.runtimeLauncherName
        )
        try "#!/bin/sh\necho runtime-launcher\n".write(
            to: sourceRuntimeLauncher,
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceRuntimeLauncher.path
        )
        let daemonExecutable = sourceMacOS.appendingPathComponent(
            ForgeFilesystemProtocolConstants.daemonExecutableName
        )
        try "#!/bin/sh\necho daemon\n".write(
            to: daemonExecutable,
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemonExecutable.path)
        try "current-framework".write(
            to: sourceFramework.appendingPathComponent("revision.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "current-resource".write(
            to: sourceResources.appendingPathComponent("revision.txt"),
            atomically: true,
            encoding: .utf8
        )
        let appInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.forge-conductor.app</string>
        <key>CFBundleExecutable</key><string>Forge Conductor</string>
        </dict></plist>
        """
        try appInfo.write(
            to: sourceContents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        let daemonInfo = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>com.forge-conductor.filesystem-daemon</string>
        <key>BundleProgram</key><string>Contents/MacOS/forge-filesystem-daemon</string>
        <key>MachServices</key><dict>
        <key>com.forge-conductor.filesystem-daemon</key><true/>
        </dict>
        <key>UserName</key><string>root</string>
        </dict></plist>
        """
        try daemonInfo.write(
            to: sourceLaunchDaemons.appendingPathComponent(
                ForgeFilesystemProtocolConstants.daemonPlistName
            ),
            atomically: true,
            encoding: .utf8
        )

        let installedFramework = installer.installedBinaryURL.deletingLastPathComponent()
            .appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        let mirroredFramework = home
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("ForgeConductorCore.framework", isDirectory: true)
        let staleAppMacOS = installer.appBundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
        let staleAppResources = installer.appBundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(
            at: installer.installedBinaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: installedFramework, withIntermediateDirectories: true)
        try fm.createDirectory(at: mirroredFramework, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleAppMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleAppResources, withIntermediateDirectories: true)
        try "stale-binary".write(
            to: installer.installedBinaryURL,
            atomically: true,
            encoding: .utf8
        )
        try "stale-runtime-launcher".write(
            to: installer.installedRuntimeLauncherURL,
            atomically: true,
            encoding: .utf8
        )
        try "stale-framework".write(
            to: installedFramework.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "stale-framework".write(
            to: mirroredFramework.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "stale-app".write(
            to: staleAppMacOS.appendingPathComponent(ManagerInstaller.appDisplayName),
            atomically: true,
            encoding: .utf8
        )
        try "stale-resource".write(
            to: staleAppResources.appendingPathComponent("stale.txt"),
            atomically: true,
            encoding: .utf8
        )

        return ArtifactFixture(
            installer: installer,
            sourceExecutable: sourceExecutable,
            sourceManagerExecutable: sourceManagerExecutable,
            sourceRuntimeLauncher: sourceRuntimeLauncher,
            installedFramework: installedFramework,
            mirroredFramework: mirroredFramework
        )
    }

    private func assertCurrentArtifacts(
        _ fixture: ArtifactFixture,
        expectedInstalledBinary: String = "#!/bin/sh\necho current\n",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fm = FileManager.default
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.installedBinaryURL, encoding: .utf8),
            expectedInstalledBinary,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.installedRuntimeLauncherURL,
                encoding: .utf8
            ),
            "#!/bin/sh\necho runtime-launcher\n",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL.appendingPathComponent(
                    "Contents/Helpers/\(ManagerInstaller.runtimeLauncherName)"
                ),
                encoding: .utf8
            ),
            "#!/bin/sh\necho runtime-launcher\n",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installedFramework.appendingPathComponent("revision.txt"),
                encoding: .utf8
            ),
            "current-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.mirroredFramework.appendingPathComponent("revision.txt"),
                encoding: .utf8
            ),
            "current-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.appExecutableURL, encoding: .utf8),
            "#!/bin/sh\necho current\n",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent("Contents/Frameworks/ForgeConductorCore.framework/revision.txt"),
                encoding: .utf8
            ),
            "current-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent("Contents/Resources/revision.txt"),
                encoding: .utf8
            ),
            "current-resource",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent(
                        "Contents/MacOS/\(ForgeFilesystemProtocolConstants.daemonExecutableName)"
                    ),
                encoding: .utf8
            ),
            "#!/bin/sh\necho daemon\n",
            file: file,
            line: line
        )
        XCTAssertTrue(
            fm.fileExists(
                atPath: fixture.installer.appBundleURL
                    .appendingPathComponent(
                        "Contents/Library/LaunchDaemons/"
                            + ForgeFilesystemProtocolConstants.daemonPlistName
                    ).path
            ),
            file: file,
            line: line
        )
        XCTAssertFalse(
            fm.fileExists(atPath: fixture.installedFramework.appendingPathComponent("stale.txt").path),
            file: file,
            line: line
        )
        XCTAssertFalse(
            fm.fileExists(atPath: fixture.mirroredFramework.appendingPathComponent("stale.txt").path),
            file: file,
            line: line
        )
    }

    private func assertStaleArtifacts(
        _ fixture: ArtifactFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.installedBinaryURL, encoding: .utf8),
            "stale-binary",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.installedRuntimeLauncherURL,
                encoding: .utf8
            ),
            "stale-runtime-launcher",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installedFramework.appendingPathComponent("stale.txt"),
                encoding: .utf8
            ),
            "stale-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.mirroredFramework.appendingPathComponent("stale.txt"),
                encoding: .utf8
            ),
            "stale-framework",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.installer.appExecutableURL, encoding: .utf8),
            "stale-app",
            file: file,
            line: line
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.installer.appBundleURL
                    .appendingPathComponent("Contents/Resources/stale.txt"),
                encoding: .utf8
            ),
            "stale-resource",
            file: file,
            line: line
        )
    }

    private func assertNoTransactionArtifactsRemain(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: home,
            includingPropertiesForKeys: nil,
            options: []
        )
        let leftovers = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent.contains(".stage-")
                || $0.lastPathComponent.contains(".backup-")
        }
        XCTAssertTrue(
            leftovers.isEmpty,
            "transaction artifacts remain: \(leftovers.map(\.path))",
            file: file,
            line: line
        )
    }

    private func retainFilesystemAuthority(
        paths: AppPaths,
        projectID: ProjectID,
        generation: ProjectGeneration = .initial,
        root: URL
    ) throws -> String {
        var information = stat()
        guard root.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let transactionID = UUID().uuidString.lowercased()
        let request = ForgeFilesystemMutationRequest(
            requestID: UUID().uuidString.lowercased(),
            transactionID: transactionID,
            projectID: projectID.description,
            projectGeneration: generation.rawValue,
            rootID: "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))",
            rootIdentity: ForgeFilesystemIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                mode: UInt32(information.st_mode),
                owner: UInt32(information.st_uid),
                group: UInt32(information.st_gid),
                linkCount: UInt64(information.st_nlink)
            ),
            relativePathComponents: ["pending.txt"],
            access: .deleteLeaf,
            contract: .namespaceVersionExact,
            expectedLeafIdentity: ForgeFilesystemIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino) + 1,
                mode: UInt32(S_IFREG | 0o600),
                owner: UInt32(information.st_uid),
                group: UInt32(information.st_gid),
                linkCount: 1
            )
        )
        try SecureFilesystemRecoveryLedger(paths: paths).retain(
            SecureFilesystemRecoveryRecord(
                request: request,
                originatingClientID: ClientID("registration-fence"),
                rootPath: root.path,
                createdAtMilliseconds: 1
            )
        )
        return transactionID
    }

    private static func availableLoopbackPort(excluding: Set<Int> = []) throws -> Int {
        for _ in 0..<8 {
            let occupied = try makeOccupiedLoopbackPort()
            Darwin.close(occupied.descriptor)
            if !excluding.contains(occupied.port) {
                return occupied.port
            }
        }
        throw NSError(
            domain: "ManagerTests.LoopbackPort",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate a distinct loopback port"]
        )
    }

    private static func startExternalConfigLockHolder(
        paths: AppPaths,
        holdSeconds: TimeInterval
    ) throws -> ExternalConfigLockHolder {
        try FileManager.default.createDirectory(
            at: paths.configMigrationsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let readyURL = paths.configMigrationsDir.appendingPathComponent(
            ".external-lock-ready-\(UUID().uuidString.lowercased())"
        )
        let script = """
        import fcntl
        import os
        import sys
        import time

        lock_path, ready_path, duration = sys.argv[1], sys.argv[2], float(sys.argv[3])
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.lockf(descriptor, fcntl.LOCK_EX)
        ready = os.open(ready_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.write(ready, b"ready")
        os.fsync(ready)
        os.close(ready)
        time.sleep(duration)
        fcntl.lockf(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            script,
            paths.configMigrationLock.path,
            readyURL.path,
            String(holdSeconds),
        ]
        try process.run()

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: readyURL.path),
              process.isRunning,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            throw NSError(
                domain: "ManagerTests.ExternalConfigLockHolder",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "External configuration lock was not acquired"]
            )
        }
        return ExternalConfigLockHolder(process: process, readyURL: readyURL)
    }

    private static func finishExternalConfigLockHolder(_ holder: ExternalConfigLockHolder) {
        if holder.process.isRunning {
            holder.process.terminate()
        }
        holder.process.waitUntilExit()
        try? FileManager.default.removeItem(at: holder.readyURL)
    }

    private static func makeOccupiedLoopbackPort(
        excluding: Set<Int> = []
    ) throws -> (descriptor: Int32, port: Int) {
        for _ in 0..<8 {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw NSError(domain: "ManagerTests.LoopbackPort", code: Int(errno))
            }

            do {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = 0
                address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
                guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
                    throw NSError(domain: "ManagerTests.LoopbackPort", code: Int(errno))
                }

                var selected = sockaddr_in()
                var selectedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &selected) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(descriptor, $0, &selectedLength)
                    }
                }
                guard named == 0 else {
                    throw NSError(domain: "ManagerTests.LoopbackPort", code: Int(errno))
                }
                let port = Int(UInt16(bigEndian: selected.sin_port))
                if excluding.contains(port) {
                    Darwin.close(descriptor)
                    continue
                }
                return (descriptor, port)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }
        throw NSError(
            domain: "ManagerTests.LoopbackPort",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not reserve a distinct loopback port"]
        )
    }
}
