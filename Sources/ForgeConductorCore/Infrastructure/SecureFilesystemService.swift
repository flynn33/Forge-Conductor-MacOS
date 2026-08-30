import Darwin
import Foundation
import ForgeFilesystemProtocol
import ServiceManagement

public enum SecureFilesystemServiceStatus: String, Sendable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
}

public enum SecureFilesystemServiceLifecycleError: LocalizedError {
    case superseded

    public var errorDescription: String? {
        switch self {
        case .superseded:
            "The protected filesystem service update was superseded by a newer operator action"
        }
    }
}

protocol SecureFilesystemServiceRegistering: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func unregister(completionHandler: @Sendable @escaping (Error?) -> Void)
}

extension SMAppService: SecureFilesystemServiceRegistering {}

@MainActor
public final class SecureFilesystemServiceController {
    private var lifecycleGeneration: UInt64 = 0
    private let registeredService: any SecureFilesystemServiceRegistering

    public init() {
        registeredService = SMAppService.daemon(
            plistName: ForgeFilesystemProtocolConstants.daemonPlistName
        )
    }

    init(service: any SecureFilesystemServiceRegistering) {
        registeredService = service
    }

    public func status() -> SecureFilesystemServiceStatus {
        Self.status(of: registeredService)
    }

    @discardableResult
    public func register() throws -> SecureFilesystemServiceStatus {
        lifecycleGeneration &+= 1
        try registeredService.register()
        return status()
    }

    @discardableResult
    public func unregister() throws -> SecureFilesystemServiceStatus {
        lifecycleGeneration &+= 1
        try registeredService.unregister()
        return status()
    }

    /// Replaces a previously registered daemon after an app or helper update.
    /// ServiceManagement documents that an updated daemon executable should be
    /// unregistered before re-registration, and its synchronous unregister does
    /// not wait for the old process to be reaped. The completion-handler form is
    /// therefore the only safe transition point for registering the replacement.
    @discardableResult
    public func reinstall() async throws -> SecureFilesystemServiceStatus {
        lifecycleGeneration &+= 1
        let operationGeneration = lifecycleGeneration
        switch registeredService.status {
        case .enabled, .requiresApproval:
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                registeredService.unregister { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        try Task.checkCancellation()
        guard lifecycleGeneration == operationGeneration else {
            throw SecureFilesystemServiceLifecycleError.superseded
        }
        try registeredService.register()
        return Self.status(of: registeredService)
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    nonisolated static func registrationStatus() -> SecureFilesystemServiceStatus {
        status(of: SMAppService.daemon(
            plistName: ForgeFilesystemProtocolConstants.daemonPlistName
        ))
    }

    private nonisolated static func status(
        of service: any SecureFilesystemServiceRegistering
    ) -> SecureFilesystemServiceStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

protocol SecureFilesystemServiceTransport: Sendable {
    func serviceStatus() -> SecureFilesystemServiceStatus
    func deleteLeaf(
        request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse
}

struct SecureFilesystemHandshakeStateMachine {
    enum Phase: Equatable {
        case awaitingIdentity
        case dispatchAuthorized
        case requestSubmitted
        case finished
    }

    enum ServiceInfoDisposition: Equatable {
        case prepareDispatch
        case finishWithoutDispatch
        case ignore
    }

    private(set) var phase: Phase = .awaitingIdentity
    private(set) var terminalResponse: ForgeFilesystemResponse?
    private let transactionID: String

    init(request: ForgeFilesystemMutationRequest) {
        transactionID = request.transactionID
    }

    mutating func receiveServiceInfo<S: Sequence>(
        _ information: ForgeFilesystemServiceInfo,
        allowedCodeDirectoryHashes: S
    ) -> ServiceInfoDisposition where S.Element == String {
        guard phase == .awaitingIdentity else { return .ignore }
        guard information.matchesExpectedService(
            allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
        ) else {
            terminalResponse = ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "Secure filesystem service version or runtime identity does not match"
            )
            phase = .finished
            return .finishWithoutDispatch
        }
        phase = .dispatchAuthorized
        return .prepareDispatch
    }

    /// Transitions to submitted and synchronously invokes the supplied dispatch
    /// operation. The coordinator holds its lifecycle lock across this method,
    /// so timeout completion cannot interleave between the transition and send.
    mutating func dispatchIfAuthorized(_ dispatch: () -> Void) -> Bool {
        guard phase == .dispatchAuthorized else { return false }
        phase = .requestSubmitted
        dispatch()
        return true
    }

    @discardableResult
    mutating func completeReply(_ response: ForgeFilesystemResponse) -> Bool {
        guard phase == .requestSubmitted else { return false }
        terminalResponse = response
        phase = .finished
        return true
    }

    /// A lost connection or timeout before submission carries no recovery ID.
    /// Once submission begins, the original transaction ID is retained because
    /// the daemon may have durably recorded or committed the request.
    @discardableResult
    mutating func completeWithoutReply(code: String, message: String) -> Bool {
        guard phase != .finished else { return false }
        let recoveryTransactionID = phase == .requestSubmitted ? transactionID : nil
        terminalResponse = ForgeFilesystemResponse(
            ok: false,
            code: code,
            message: message,
            recoveryTransactionID: recoveryTransactionID
        )
        phase = .finished
        return true
    }
}

private final class SecureFilesystemHandshakeCoordinator: @unchecked Sendable {
    // The XPC reply is asynchronous, but use a recursive lock so an unusual
    // synchronous error callback cannot deadlock the lifecycle coordinator.
    private let lock = NSRecursiveLock()
    private let completionSignal = DispatchSemaphore(value: 0)
    private var machine: SecureFilesystemHandshakeStateMachine

    init(request: ForgeFilesystemMutationRequest) {
        machine = SecureFilesystemHandshakeStateMachine(request: request)
    }

    func receiveServiceInfo(
        _ information: ForgeFilesystemServiceInfo,
        allowedCodeDirectoryHashes: [String]
    ) -> SecureFilesystemHandshakeStateMachine.ServiceInfoDisposition {
        lock.lock()
        let disposition = machine.receiveServiceInfo(
            information,
            allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
        )
        lock.unlock()
        if disposition == .finishWithoutDispatch { completionSignal.signal() }
        return disposition
    }

    func dispatchIfAuthorized(_ dispatch: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return machine.dispatchIfAuthorized(dispatch)
    }

    func completeReply(_ response: ForgeFilesystemResponse) {
        lock.lock()
        let didFinish = machine.completeReply(response)
        lock.unlock()
        if didFinish { completionSignal.signal() }
    }

    func completeWithoutReply(code: String, message: String) {
        lock.lock()
        let didFinish = machine.completeWithoutReply(code: code, message: message)
        lock.unlock()
        if didFinish { completionSignal.signal() }
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        completionSignal.wait(timeout: .now() + timeout)
    }

    var terminalResponse: ForgeFilesystemResponse? {
        lock.lock()
        defer { lock.unlock() }
        return machine.terminalResponse
    }
}

final class XPCSecureFilesystemServiceTransport: SecureFilesystemServiceTransport,
    @unchecked Sendable
{
    func serviceStatus() -> SecureFilesystemServiceStatus {
        let reportedStatus = SecureFilesystemServiceController.registrationStatus()
        return Self.transportStatus(
            reportedStatus: reportedStatus,
            securedInfoDictionary: ForgeFilesystemCodeIdentity.currentSecuredInfoDictionary()
        )
    }

    static func transportStatus(
        reportedStatus: SecureFilesystemServiceStatus,
        securedInfoDictionary: [String: Any]?
    ) -> SecureFilesystemServiceStatus {
        guard reportedStatus == .notFound,
              let securedInfoDictionary,
              ForgeFilesystemCodeIdentity.daemonCodeDirectoryHashes(
                  inSecuredInfoDictionary: securedInfoDictionary
              ) != nil else {
            return reportedStatus
        }
        // A separately signed CLI cannot reliably observe the app-owned
        // SMAppService registration. Permit an authenticated XPC probe only
        // when the caller's sealed identity metadata contains a valid hash set.
        return .enabled
    }

    func deleteLeaf(
        request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        guard let securedInfo = ForgeFilesystemCodeIdentity.currentSecuredInfoDictionary(),
              let allowedCodeDirectoryHashes = ForgeFilesystemCodeIdentity
                  .daemonCodeDirectoryHashes(inSecuredInfoDictionary: securedInfo),
              let signingRequirement = ForgeFilesystemProtocolConstants
                  .requiredDaemonCodeSigningRequirement(
                      codeDirectoryHashes: allowedCodeDirectoryHashes
                  ) else {
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                message: "The packaged secure filesystem service identity is unavailable"
            )
        }
        let connection = NSXPCConnection(
            machServiceName: ForgeFilesystemProtocolConstants.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ForgeFilesystemServiceXPC.self
        )
        connection.setCodeSigningRequirement(signingRequirement)
        let coordinator = SecureFilesystemHandshakeCoordinator(request: request)
        connection.interruptionHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was interrupted"
            )
        }
        connection.invalidationHandler = {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service connection was invalidated"
            )
        }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let description = error.localizedDescription.lowercased()
            let identityFailure = description.contains("code sign")
                || description.contains("requirement")
            coordinator.completeWithoutReply(
                code: identityFailure
                    ? ForgeFilesystemErrorCode.helperIdentityMismatch
                    : ForgeFilesystemErrorCode.helperUnavailable,
                message: identityFailure
                    ? "Secure filesystem service identity validation failed"
                    : "Secure filesystem service connection failed"
            )
        }) as? ForgeFilesystemServiceXPC else {
            connection.invalidate()
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service proxy is unavailable"
            )
        }
        proxy.serviceInfo { information in
            let disposition = coordinator.receiveServiceInfo(
                information,
                allowedCodeDirectoryHashes: allowedCodeDirectoryHashes
            )
            guard disposition == .prepareDispatch else { return }
            _ = coordinator.dispatchIfAuthorized {
                proxy.deleteLeaf(request, authorizedRoot: authorizedRoot) { value in
                    coordinator.completeReply(value)
                }
            }
        }
        let boundedTimeout = max(0.001, min(60, timeout))
        let waitResult = coordinator.wait(timeout: boundedTimeout)
        if waitResult == .timedOut {
            coordinator.completeWithoutReply(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service request timed out"
            )
        }
        let returnedResponse = coordinator.terminalResponse
        connection.invalidate()
        if let returnedResponse { return returnedResponse }
        return ForgeFilesystemResponse(
            ok: false,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: "Secure filesystem service did not return a result"
        )
    }

    /// Once a request has been submitted to XPC, losing the reply does not prove
    /// that the daemon failed before capture or commit. Preserve the caller's
    /// transaction identity so retry/recovery can query the same durable record.
    static func uncertainFailure(
        for request: ForgeFilesystemMutationRequest,
        code: String,
        message: String
    ) -> ForgeFilesystemResponse {
        ForgeFilesystemResponse(
            ok: false,
            code: code,
            message: message,
            recoveryTransactionID: request.transactionID
        )
    }
}

final class SecureFilesystemMutationClient: @unchecked Sendable {
    private let transport: any SecureFilesystemServiceTransport

    init(transport: any SecureFilesystemServiceTransport = XPCSecureFilesystemServiceTransport()) {
        self.transport = transport
    }

    func deleteLeaf(
        at url: URL,
        context: ToolInvocationContext?,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult {
        guard let context else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Protected filesystem mutation requires a durable project context"
            )
        }
        switch transport.serviceStatus() {
        case .enabled:
            break
        case .requiresApproval:
            return .failure(
                code: ForgeFilesystemErrorCode.helperNotApproved,
                message: "Secure filesystem service requires approval in System Settings",
                retryable: true
            )
        case .notRegistered, .notFound:
            return .failure(
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service is unavailable",
                retryable: true
            )
        }
        try cancellation?.checkCancellation()
        let requestedTarget = url.standardizedFileURL
        guard let target = Self.canonicalizedLeafPath(requestedTarget) else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Filesystem leaf parent cannot be canonicalized"
            )
        }
        let writableRoots = context.authorizationScope.writableRoots.compactMap { declaredRoot in
            Self.canonicalExistingDirectory(declaredRoot)
        }
        .filter { Self.contains(target, root: $0) }
        .sorted { $0.pathComponents.count > $1.pathComponents.count }
        guard let root = writableRoots.first,
              target != root else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "No authorized writable project root contains the requested leaf"
            )
        }
        let relativeComponents = Array(
            target.pathComponents.dropFirst(root.pathComponents.count)
        )
        let rootDescriptor = Self.openPinnedDirectory(root)
        guard rootDescriptor >= 0 else {
            let rootOpenError = errno
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Authorized project root cannot be opened: \(String(cString: strerror(rootOpenError)))"
            )
        }
        let rootHandle = FileHandle(fileDescriptor: rootDescriptor, closeOnDealloc: true)
        defer { try? rootHandle.close() }
        var rootInformation = stat()
        guard Darwin.fstat(rootDescriptor, &rootInformation) == 0 else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Authorized project root identity cannot be read"
            )
        }
        var leafInformation = stat()
        guard Darwin.lstat(target.path, &leafInformation) == 0 else {
            return .failure(code: "not_found", message: "Filesystem leaf does not exist")
        }
        guard leafInformation.st_mode & S_IFMT != S_IFDIR else {
            return .failure(
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "Directory deletion is disabled until privileged recursive recovery is qualified"
            )
        }
        let requestID = cancellation?.requestID ?? UUID()
        let request = ForgeFilesystemMutationRequest(
            requestID: requestID.uuidString.lowercased(),
            transactionID: UUID().uuidString.lowercased(),
            projectID: context.projectID.description,
            projectGeneration: context.projectGeneration.rawValue,
            rootID: "\(UInt64(rootInformation.st_dev)):\(UInt64(rootInformation.st_ino))",
            rootIdentity: Self.identity(rootInformation),
            relativePathComponents: relativeComponents,
            access: .deleteLeaf,
            expectedLeafIdentity: Self.identity(leafInformation)
        )
        if let errorCode = request.validationError() {
            return .failure(
                code: errorCode,
                message: "Protected filesystem request is invalid"
            )
        }
        let timeout = min(
            60,
            max(0.001, cancellation?.remainingTimeInterval ?? 60)
        )
        let response = transport.deleteLeaf(
            request: request,
            authorizedRoot: rootHandle,
            timeout: timeout
        )
        if response.ok {
            return .success([
                "path": target.path,
                "deleted": true,
                "deleted_entries": 1,
                "committed": response.committed,
                "durability_confirmed": response.durabilityConfirmed,
                "filesystem_transaction_id": request.transactionID,
            ])
        }
        var result = ToolResult.failure(
            code: response.code,
            message: response.message,
            retryable: response.code == ForgeFilesystemErrorCode.helperUnavailable
                || response.code == ForgeFilesystemErrorCode.helperNotApproved
        )
        if let recoveryTransactionID = response.recoveryTransactionID {
            result.payload["recovery_required"] = true
            result.payload["filesystem_transaction_id"] = recoveryTransactionID
        }
        result.payload["committed"] = response.committed
        result.payload["durability_confirmed"] = response.durabilityConfirmed
        return result
    }

    private static func identity(_ information: stat) -> ForgeFilesystemIdentity {
        ForgeFilesystemIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            mode: UInt32(information.st_mode),
            owner: UInt32(information.st_uid),
            group: UInt32(information.st_gid),
            linkCount: UInt64(information.st_nlink)
        )
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func canonicalizedLeafPath(_ url: URL) -> URL? {
        guard !url.lastPathComponent.isEmpty,
              let parent = canonicalExistingDirectory(url.deletingLastPathComponent()) else {
            return nil
        }
        return parent.appendingPathComponent(url.lastPathComponent)
    }

    private static func canonicalExistingDirectory(_ url: URL) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                Darwin.realpath(source, destination.baseAddress) != nil
            }
        }
        guard resolved else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private static func openPinnedDirectory(_ url: URL) -> Int32 {
        let rootDescriptor = Darwin.open(
            "/",
            O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard rootDescriptor >= 0 else { return -1 }
        var currentDescriptor = rootDescriptor
        for componentSlice in url.path.split(separator: "/") {
            let component = String(componentSlice)
            guard !component.isEmpty, component != ".", component != ".." else {
                Darwin.close(currentDescriptor)
                errno = EINVAL
                return -1
            }
            let nextDescriptor = component.withCString { componentPointer in
                Darwin.openat(
                    currentDescriptor,
                    componentPointer,
                    O_SEARCH | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
                )
            }
            guard nextDescriptor >= 0 else {
                let openError = errno
                Darwin.close(currentDescriptor)
                errno = openError
                return -1
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }
}
