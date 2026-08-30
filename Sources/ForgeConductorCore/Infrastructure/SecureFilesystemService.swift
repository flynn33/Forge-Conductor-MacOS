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

final class XPCSecureFilesystemServiceTransport: SecureFilesystemServiceTransport,
    @unchecked Sendable
{
    func serviceStatus() -> SecureFilesystemServiceStatus {
        SecureFilesystemServiceController.registrationStatus()
    }

    func deleteLeaf(
        request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        timeout: TimeInterval
    ) -> ForgeFilesystemResponse {
        guard let expectedExecutableSHA256 = Self.expectedDaemonExecutableSHA256(
            in: Bundle.main.bundleURL
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
        connection.setCodeSigningRequirement(
            ForgeFilesystemProtocolConstants.requiredDaemonCodeSigningRequirement
        )
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var response: ForgeFilesystemResponse?
        var connectionError: Error?
        var requestSubmitted = false
        var completed = false
        connection.interruptionHandler = { semaphore.signal() }
        connection.invalidationHandler = { semaphore.signal() }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            lock.lock()
            if !completed {
                connectionError = error
                completed = true
            }
            lock.unlock()
            semaphore.signal()
        }) as? ForgeFilesystemServiceXPC else {
            connection.invalidate()
            return ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.helperUnavailable,
                message: "Secure filesystem service proxy is unavailable"
            )
        }
        proxy.serviceInfo { information in
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            guard information.matchesExpectedService(
                executableSHA256: expectedExecutableSHA256
            ) else {
                response = ForgeFilesystemResponse(
                    ok: false,
                    code: ForgeFilesystemErrorCode.helperIdentityMismatch,
                    message: "Secure filesystem service version or runtime identity does not match"
                )
                completed = true
                lock.unlock()
                semaphore.signal()
                return
            }
            requestSubmitted = true
            proxy.deleteLeaf(request, authorizedRoot: authorizedRoot) { value in
                lock.lock()
                if !completed {
                    response = value
                    completed = true
                }
                lock.unlock()
                semaphore.signal()
            }
            lock.unlock()
        }
        let boundedTimeout = max(0.001, min(60, timeout))
        let waitResult = semaphore.wait(timeout: .now() + boundedTimeout)
        lock.lock()
        if !completed { completed = true }
        let returnedResponse = response
        let returnedError = connectionError
        let submitted = requestSubmitted
        lock.unlock()
        connection.invalidate()
        if let returnedResponse { return returnedResponse }
        if let returnedError {
            let description = returnedError.localizedDescription.lowercased()
            let identityFailure = description.contains("code sign")
                || description.contains("requirement")
            return Self.failure(
                request: submitted ? request : nil,
                code: identityFailure
                    ? ForgeFilesystemErrorCode.helperIdentityMismatch
                    : ForgeFilesystemErrorCode.helperUnavailable,
                message: identityFailure
                    ? "Secure filesystem service identity validation failed"
                    : "Secure filesystem service connection failed"
            )
        }
        return Self.failure(
            request: submitted ? request : nil,
            code: ForgeFilesystemErrorCode.helperUnavailable,
            message: waitResult == .timedOut
                ? "Secure filesystem service request timed out"
                : "Secure filesystem service did not return a result"
        )
    }

    private static func failure(
        request: ForgeFilesystemMutationRequest?,
        code: String,
        message: String
    ) -> ForgeFilesystemResponse {
        guard let request else {
            return ForgeFilesystemResponse(ok: false, code: code, message: message)
        }
        return uncertainFailure(for: request, code: code, message: message)
    }

    static func expectedDaemonExecutableSHA256(in bundleURL: URL) -> String? {
        let executable = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(ForgeFilesystemProtocolConstants.daemonExecutableName)
        return ForgeFilesystemExecutableIdentity.sha256(ofRegularFileAt: executable)
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
