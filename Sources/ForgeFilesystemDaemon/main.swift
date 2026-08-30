import Darwin
import Foundation
import ForgeFilesystemProtocol

private let daemonCodeDirectoryHash: String = {
    guard let hash = ForgeFilesystemCodeIdentity.currentCodeDirectoryHash() else {
        FileHandle.standardError.write(Data("filesystem service code identity unavailable\n".utf8))
        exit(EXIT_FAILURE)
    }
    return hash
}()

private final class FilesystemService: NSObject, ForgeFilesystemServiceXPC {
    private let deleteEngine = PrivilegedLeafDeleteEngine()
    private let requesterUID: uid_t

    init(requesterUID: uid_t) {
        self.requesterUID = requesterUID
        super.init()
    }

    func serviceInfo(withReply reply: @escaping (ForgeFilesystemServiceInfo) -> Void) {
        reply(ForgeFilesystemServiceInfo(
            effectiveUserIdentifier: UInt32(geteuid()),
            codeDirectoryHash: daemonCodeDirectoryHash
        ))
    }

    func status(withReply reply: @escaping (ForgeFilesystemResponse) -> Void) {
        guard geteuid() == 0 else {
            reply(ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The filesystem service is not running with its required identity"
            ))
            return
        }
        reply(ForgeFilesystemResponse(
            ok: true,
            code: "ok",
            message: "Secure filesystem service is available",
            committed: false,
            durabilityConfirmed: true
        ))
    }

    func deleteLeaf(
        _ request: ForgeFilesystemMutationRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemResponse) -> Void
    ) {
        reply(withAuthorizedRoot(
            authorizedRoot,
            unavailable: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The authorized root descriptor is unavailable"
            )
        ) { descriptor in
            deleteEngine.deleteLeaf(
                request,
                authorizedRootDescriptor: descriptor,
                requesterUID: requesterUID
            )
        })
    }

    func queryTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemTransactionStatus) -> Void
    ) {
        reply(withAuthorizedRoot(
            authorizedRoot,
            unavailable: ForgeFilesystemTransactionStatus(
                transactionID: nil,
                disposition: .unavailable,
                code: ForgeFilesystemErrorCode.transactionUnavailable,
                message: "The filesystem transaction is unavailable",
                terminal: false,
                committed: false,
                durabilityConfirmed: false,
                recoveryRequired: false,
                acknowledgementRequired: false
            )
        ) { descriptor in
            deleteEngine.queryTransaction(
                request,
                authorizedRootDescriptor: descriptor,
                requesterUID: requesterUID
            )
        })
    }

    func resumeTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemResponse) -> Void
    ) {
        reply(withAuthorizedRoot(
            authorizedRoot,
            unavailable: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The authorized root descriptor is unavailable"
            )
        ) { descriptor in
            deleteEngine.resumeTransaction(
                request,
                authorizedRootDescriptor: descriptor,
                requesterUID: requesterUID
            )
        })
    }

    func acknowledgeTransaction(
        _ request: ForgeFilesystemTransactionControlRequest,
        authorizedRoot: FileHandle,
        withReply reply: @escaping (ForgeFilesystemResponse) -> Void
    ) {
        reply(withAuthorizedRoot(
            authorizedRoot,
            unavailable: ForgeFilesystemResponse(
                ok: false,
                code: ForgeFilesystemErrorCode.capabilityUnavailable,
                message: "The authorized root descriptor is unavailable"
            )
        ) { descriptor in
            deleteEngine.acknowledgeTransaction(
                request,
                authorizedRootDescriptor: descriptor,
                requesterUID: requesterUID
            )
        })
    }

    private func withAuthorizedRoot<Value>(
        _ authorizedRoot: FileHandle,
        unavailable: @autoclosure () -> Value,
        operation: (Int32) -> Value
    ) -> Value {
        let descriptor = authorizedRoot.fileDescriptor
        let duplicatedDescriptor = Darwin.dup(descriptor)
        try? authorizedRoot.close()
        guard duplicatedDescriptor >= 0,
              Darwin.fcntl(duplicatedDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            if duplicatedDescriptor >= 0 { _ = Darwin.close(duplicatedDescriptor) }
            return unavailable()
        }
        defer { _ = Darwin.close(duplicatedDescriptor) }
        return operation(duplicatedDescriptor)
    }
}

private final class FilesystemListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let requesterUID = connection.effectiveUserIdentifier
        guard geteuid() == 0,
              ForgeFilesystemRequesterPolicy.isValidRequesterUID(UInt32(requesterUID)),
              getpwuid(requesterUID) != nil else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: ForgeFilesystemServiceXPC.self)
        connection.exportedObject = FilesystemService(requesterUID: requesterUID)
        connection.activate()
        return true
    }
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("filesystem service requires root\n".utf8))
    exit(EXIT_FAILURE)
}

private let listener = NSXPCListener(
    machServiceName: ForgeFilesystemProtocolConstants.serviceName
)
private let delegate = FilesystemListenerDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(
    ForgeFilesystemProtocolConstants.requiredClientCodeSigningRequirement
)
listener.activate()
dispatchMain()
