import Darwin
import Foundation

/// A bounded, protected native store. Its public snapshots never contain a bearer.
public final class NativeTaskCredentialFileStore: @unchecked Sendable {
    public static let maximumFileBytes = 1_048_576
    public static let maximumTasks = 1_024
    public let directoryURL: URL
    private let home: URL

    public init(paths: AppPaths) {
        home = paths.home.standardizedFileURL
        directoryURL = paths.nativeValidationDir.appendingPathComponent("task-attachments", isDirectory: true)
    }

    public func fileURL(taskID: UUID) -> URL { directoryURL.appendingPathComponent(Self.name(taskID)) }

    public func credential(taskID: UUID, managerEndpoint: URL, now: Date = Date()) throws -> NativeTaskCapabilityCredential {
        try attachment(taskID: taskID, managerEndpoint: managerEndpoint, now: now).credential
    }

    /// The stable source namespace must accompany every native source request. Callers retain
    /// the original JSON-RPC request ID when retrying; a new protocol session does not replace it.
    public func attachment(taskID: UUID, managerEndpoint: URL, now: Date = Date()) throws -> NativeTaskHTTPAttachment {
        try locked { directory in
            let record = try requireRecord(taskID, directory: directory)
            guard record.endpoint == managerEndpoint.absoluteString, record.pending == nil,
                  let value = record.activeCredential, let response = record.response else {
                throw NativeTaskOperatorError.credentialInactive
            }
            let result = try Self.result(response)
            guard result.current.state == .active, let expiry = ISO8601.date(from: result.current.expiresAt), expiry > now else {
                throw NativeTaskOperatorError.credentialInactive
            }
            guard let namespace = UUID(uuidString: record.sourceSessionID) else { throw NativeTaskOperatorError.invalidCredentialFile }
            return NativeTaskHTTPAttachment(endpoint: managerEndpoint,
                credential: try NativeTaskCapabilityCredential(authorizationValue: value), sourceSessionID: namespace)
        }
    }

    public func snapshot(taskID: UUID) throws -> NativeTaskCredentialSnapshot {
        try locked { directory in try snapshot(requireRecord(taskID, directory: directory)) }
    }

    func stage(_ command: NativeTaskOperatorCommand, candidate: NativeTaskCapabilityCredential?, endpoint: URL) throws -> NativeTaskCredentialSnapshot {
        try NativeTaskOperatorEndpoint.validate(endpoint)
        return try locked { directory in
            var record: Record
            if command.action == "prepare" {
                guard try readRecord(command.taskID, directory: directory) == nil else { throw NativeTaskOperatorError.credentialConflict }
                try checkCapacity(directory)
                record = Record(taskID: command.taskID, capabilityID: command.capabilityID, endpoint: endpoint.absoluteString)
            } else {
                record = try requireRecord(command.taskID, directory: directory)
                guard record.endpoint == endpoint.absoluteString, record.pending == nil,
                      let response = record.response else { throw NativeTaskOperatorError.credentialConflict }
                let current = try Self.result(response).current
                guard current.state != .revoked, current.capabilityID == command.capabilityID,
                      current.projectID == command.projectID, current.projectGeneration == command.projectGeneration,
                      current.epoch == command.expectedEpoch else { throw NativeTaskOperatorError.credentialConflict }
            }
            guard (command.action == "revoke") == (candidate == nil),
                  candidate.map({ $0.capabilityID == command.capabilityID && $0.epoch == command.resultEpoch && $0.verifier.sha256 == command.verifierSHA256 }) ?? true else {
                throw NativeTaskOperatorError.credentialConflict
            }
            record.pending = Pending(action: command.action, request: command.data, candidate: candidate?.authorizationValue)
            try advance(&record)
            try write(record, directory: directory)
            return try snapshot(record)
        }
    }

    func pending(taskID: UUID, endpoint: URL) throws -> NativeTaskOperatorCommand {
        try locked { directory in
            let record = try requireRecord(taskID, directory: directory)
            guard record.endpoint == endpoint.absoluteString else { throw NativeTaskOperatorError.credentialConflict }
            guard let pending = record.pending else { throw NativeTaskOperatorError.noPendingRequest }
            return try NativeTaskOperatorCommand(action: pending.action, data: pending.request)
        }
    }

    func complete(_ command: NativeTaskOperatorCommand, result: NativeTaskCapabilityCommandResult, endpoint: URL) throws -> NativeTaskCredentialSnapshot {
        try command.validate(result)
        return try locked { directory in
            var record = try requireRecord(command.taskID, directory: directory)
            guard record.endpoint == endpoint.absoluteString, let pending = record.pending,
                  pending.action == command.action, pending.request == command.data else {
                throw NativeTaskOperatorError.credentialConflict
            }
            if let prior = try record.response.map(Self.result) {
                guard result.current.originalCallerBindingID == prior.current.originalCallerBindingID,
                      result.current.sourceBindingID == prior.current.sourceBindingID,
                      result.current.approvalSHA256 == prior.current.approvalSHA256,
                      result.current.scopeSHA256 == prior.current.scopeSHA256,
                      result.receipt.documentSHA256 == prior.receipt.documentSHA256 else { throw NativeTaskOperatorError.invalidResponse }
            }
            // A historical replay proves the old command, but cannot make its old secret current.
            if result.current.epoch == result.receipt.resultEpoch && result.current.state == .active {
                guard let candidate = pending.candidate else { throw NativeTaskOperatorError.invalidResponse }
                record.activeCredential = candidate
            } else {
                record.activeCredential = nil
            }
            record.response = try NativeTaskOperatorResponse.data(result)
            record.pending = nil
            try advance(&record)
            try write(record, directory: directory)
            return try snapshot(record)
        }
    }

    private struct Pending: Codable { let action: String; let request: Data; let candidate: String? }
    private struct Record: Codable {
        let schemaVersion: Int
        var revision: Int64
        let taskID: UUID
        let capabilityID: UUID
        let sourceSessionID: String
        let endpoint: String
        var activeCredential: String?
        var pending: Pending?
        var response: Data?
        init(taskID: UUID, capabilityID: UUID, endpoint: String) {
            schemaVersion = 1; revision = 0; self.taskID = taskID; self.capabilityID = capabilityID; self.endpoint = endpoint
            sourceSessionID = UUID().uuidString.lowercased()
        }
    }

    private static func result(_ data: Data) throws -> NativeTaskCapabilityCommandResult {
        try NativeTaskOperatorResponse.decode(data)
    }
    private static func name(_ taskID: UUID) -> String { taskID.uuidString.lowercased() + ".json" }
    private func advance(_ record: inout Record) throws {
        guard record.revision < Int64.max else { throw NativeTaskOperatorError.credentialConflict }
        record.revision += 1
    }
    private func snapshot(_ record: Record) throws -> NativeTaskCredentialSnapshot {
        let result = try record.response.map(Self.result)
        let state: String
        if let pending = record.pending { state = pending.action + "_pending" }
        else if result?.current.state == .revoked { state = "revoked" }
        else if record.activeCredential == nil { state = "superseded" }
        else { state = "active" }
        return NativeTaskCredentialSnapshot(taskID: record.taskID, capabilityID: record.capabilityID,
            credentialFile: fileURL(taskID: record.taskID), endpoint: URL(string: record.endpoint)!,
            localState: state, result: result)
    }

    private func validate(_ record: Record, taskID: UUID) throws {
        guard record.schemaVersion == 1, record.revision > 0, record.taskID == taskID,
              let namespace = UUID(uuidString: record.sourceSessionID), namespace.uuidString.lowercased() == record.sourceSessionID,
              let endpoint = URL(string: record.endpoint) else { throw NativeTaskOperatorError.invalidCredentialFile }
        try NativeTaskOperatorEndpoint.validate(endpoint)
        let result = try record.response.map(Self.result)
        if let result {
            guard result.current.taskID == taskID, result.current.capabilityID == record.capabilityID else { throw NativeTaskOperatorError.invalidCredentialFile }
        }
        if let value = record.activeCredential {
            let credential = try NativeTaskCapabilityCredential(authorizationValue: value)
            guard let result, result.current.state != .revoked, credential.capabilityID == record.capabilityID,
                  credential.epoch == result.current.epoch, credential.epoch == result.receipt.resultEpoch,
                  credential.verifier.sha256 == result.receipt.verifierSHA256 else { throw NativeTaskOperatorError.invalidCredentialFile }
        }
        if let pending = record.pending {
            let command = try NativeTaskOperatorCommand(action: pending.action, data: pending.request)
            guard command.taskID == taskID, command.capabilityID == record.capabilityID else { throw NativeTaskOperatorError.invalidCredentialFile }
            if let candidate = pending.candidate {
                let value = try NativeTaskCapabilityCredential(authorizationValue: candidate)
                guard command.action != "revoke", value.epoch == command.resultEpoch,
                      value.capabilityID == record.capabilityID, value.verifier.sha256 == command.verifierSHA256 else { throw NativeTaskOperatorError.invalidCredentialFile }
            } else if command.action != "revoke" { throw NativeTaskOperatorError.invalidCredentialFile }
            if command.action == "prepare" {
                guard result == nil, record.activeCredential == nil else { throw NativeTaskOperatorError.invalidCredentialFile }
            } else {
                guard let result, result.current.epoch == command.expectedEpoch,
                      result.current.projectID == command.projectID, result.current.projectGeneration == command.projectGeneration else { throw NativeTaskOperatorError.invalidCredentialFile }
            }
        } else if result == nil { throw NativeTaskOperatorError.invalidCredentialFile }
    }

    private func requireRecord(_ taskID: UUID, directory: Int32) throws -> Record {
        guard let record = try readRecord(taskID, directory: directory) else { throw NativeTaskOperatorError.invalidCredentialFile }
        return record
    }
    private func readRecord(_ taskID: UUID, directory: Int32) throws -> Record? {
        let fd = openat(directory, Self.name(taskID), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        defer { close(fd) }
        try checkFile(fd, maximumBytes: Self.maximumFileBytes)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count <= Self.maximumFileBytes - count else { throw NativeTaskOperatorError.invalidCredentialFile }
            data.append(buffer, count: count)
        }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            // Reject duplicate/unknown keys and noncanonical encodings in our own private format.
            guard try encode(record) == data else { throw NativeTaskOperatorError.invalidCredentialFile }
            try validate(record, taskID: taskID)
            return record
        } catch { throw NativeTaskOperatorError.invalidCredentialFile }
    }
    private func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumFileBytes else { throw NativeTaskOperatorError.invalidCredentialFile }
        return data
    }
    private func write(_ record: Record, directory: Int32) throws {
        try validate(record, taskID: record.taskID)
        let data = try encode(record), name = Self.name(record.taskID), temporary = "." + name + ".pending"
        // One fixed temporary per task bounds crash residue. Never follow or silently repair an invalid object.
        let prior = openat(directory, temporary, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if prior >= 0 {
            defer { close(prior) }
            try checkFile(prior, maximumBytes: Self.maximumFileBytes)
            guard unlinkat(directory, temporary, 0) == 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        } else if errno != ENOENT { throw NativeTaskOperatorError.invalidCredentialFile }
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else {
            throw NativeTaskOperatorError.invalidCredentialFile
        }
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        // The installation already exists. Reject aliases rather than placing secrets under a redirected root.
        guard home.path == home.resolvingSymlinksInPath().path else { throw NativeTaskOperatorError.invalidCredentialFile }
        let root = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        defer { close(root) }
        try checkDirectory(root, exactMode: false)
        let validation = try childDirectory("native-validation", parent: root, exactMode: false)
        defer { close(validation) }
        let directory = try childDirectory("task-attachments", parent: validation, exactMode: true)
        defer { close(directory) }
        let lock = openat(directory, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard lock >= 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        defer { close(lock) }
        try checkFile(lock, maximumBytes: 0)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NativeTaskOperatorError.credentialConflict }
        defer { _ = flock(lock, LOCK_UN) }
        return try body(directory)
    }
    private func childDirectory(_ name: String, parent: Int32, exactMode: Bool) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) == 0 {
            guard fsync(parent) == 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        } else if errno != EEXIST { throw NativeTaskOperatorError.invalidCredentialFile }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeTaskOperatorError.invalidCredentialFile }
        do { try checkDirectory(fd, exactMode: exactMode); return fd }
        catch { close(fd); throw error }
    }
    private func checkDirectory(_ fd: Int32, exactMode: Bool) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(),
              value.st_mode & 0o022 == 0, !exactMode || value.st_mode & 0o777 == 0o700 else { throw NativeTaskOperatorError.invalidCredentialFile }
        if exactMode { try checkNoACL(fd) }
    }
    private func checkFile(_ fd: Int32, maximumBytes: Int) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
              value.st_mode & 0o777 == 0o600, value.st_nlink == 1, value.st_size >= 0,
              value.st_size <= off_t(maximumBytes) else { throw NativeTaskOperatorError.invalidCredentialFile }
        try checkNoACL(fd)
    }
    private func checkNoACL(_ fd: Int32) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // On Darwin an existing, fstat-validated descriptor with no extended ACL
            // returns nil/ENOENT, including after an explicitly empty ACL is installed.
            guard errno == ENOENT else { throw NativeTaskOperatorError.invalidCredentialFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        // Darwin returns zero for a present entry and EINVAL for an exhausted ACL.
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw NativeTaskOperatorError.invalidCredentialFile }
    }
    private func checkCapacity(_ directory: Int32) throws {
        guard let stream = fdopendir(dup(directory)) else { throw NativeTaskOperatorError.invalidCredentialFile }
        defer { closedir(stream) }
        var entries = 0, tasks = 0
        while let entry = readdir(stream) {
            entries += 1
            guard entries <= (Self.maximumTasks * 2) + 4 else { throw NativeTaskOperatorError.credentialConflict }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name.hasSuffix(".json") { tasks += 1 }
        }
        guard tasks < Self.maximumTasks else { throw NativeTaskOperatorError.credentialConflict }
    }
}

/// Native attachment material has no automatic encoding or status export.
/// The source-session UUID is a replay namespace; the credential alone carries authority.
public struct NativeTaskHTTPAttachment: Sendable {
    public let endpoint: URL
    public let credential: NativeTaskCapabilityCredential
    public let sourceSessionID: UUID
}

public struct NativeTaskCredentialSnapshot: Sendable {
    public let taskID: UUID
    public let capabilityID: UUID
    public let credentialFile: URL
    public let endpoint: URL
    public let localState: String
    public let result: NativeTaskCapabilityCommandResult?
    public var wireObject: [String: Any] {
        var value: [String: Any] = ["task_id": taskID.uuidString.lowercased(), "capability_id": capabilityID.uuidString.lowercased(),
            "credential_file": credentialFile.path, "endpoint": endpoint.absoluteString, "local_state": localState]
        if let result { value["receipt"] = result.receipt.wireObject; value["current"] = result.current.wireObject }
        return value
    }
}
