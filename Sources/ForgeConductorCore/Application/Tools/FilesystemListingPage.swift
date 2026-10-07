import Darwin
import Foundation

/// Opt-in, per-call directory continuation. Tokens describe a query; they grant no access.
enum FilesystemListingPage {
    static let maximumEntries = 1_000
    static let maximumCursorBytes = 8_192
    static let maximumDecodedCursorBytes = 6_144
    static let maximumScannedNames = 100_000
    static let maximumScanSeconds: TimeInterval = 15
    static let ordering = "raw_filename_bytes_v1"

    static func usesPagedMode(arguments: [String: Any]) -> Bool {
        ["limit", "cursor", "maximum_bytes"].contains { arguments.keys.contains($0) }
    }

    static func responseBudget(arguments: [String: Any], scope: ToolAuthorizationScope?) -> Int {
        let supplied = JSONSupport.exactInteger(arguments["maximum_bytes"])
        let requested = supplied.flatMap { (1...65_536).contains($0) ? $0 : nil } ?? 16_384
        return min(requested, scope?.maximumInlineOutputBytes ?? 16_384)
    }

    /// The transport owns the actual correlation ID and required notice. A page
    /// cannot be reduced here without regenerating its continuation token.
    static func finalMCPResponse(id: Any?, result: ToolResult, additiveNotice: String?,
                                 budget: Int) -> [String: Any] {
        let response = MCPToolResponse.object(id: id, result: result, additiveNotice: additiveNotice)
        if budget > 0, let frame = try? MCPStdioTransport.encode(response), frame.count <= budget {
            return response
        }
        // An impossible ID/notice budget cannot contain even the correlated
        // error. Preserve both instead of claiming that error is below the bound.
        return MCPToolResponse.object(id: id, result: Failure.outputBudget.result,
                                      additiveNotice: additiveNotice)
    }

    struct Arguments {
        let path: String
        let limit: Int
        let maximumBytes: Int
        let cursor: Cursor?
        let deadlineMilliseconds: Int?

        init(_ values: [String: Any]) throws {
            guard Set(values.keys).isSubset(of: ["path", "limit", "cursor", "maximum_bytes", "deadline_ms"]) else {
                throw Failure.invalidArgument("fields")
            }
            if let value = values["path"] {
                guard let text = value as? String, !text.utf8.contains(0) else {
                    throw Failure.invalidArgument("path")
                }
                path = text
            } else { path = FileManager.default.currentDirectoryPath }
            limit = try Self.integer(values, "limit", defaultValue: 100, range: 1...maximumEntries)
            maximumBytes = try Self.integer(values, "maximum_bytes", defaultValue: 16_384, range: 1...65_536)
            deadlineMilliseconds = values["deadline_ms"] == nil ? nil
                : try Self.integer(values, "deadline_ms", defaultValue: 1,
                                   range: 1...ToolRouter.maximumRequestedDeadlineMilliseconds)
            if let supplied = values["cursor"] {
                guard let token = supplied as? String else { throw Failure.invalidCursor }
                cursor = try Cursor(token)
            } else { cursor = nil }
        }

        private static func integer(_ values: [String: Any], _ name: String,
                                    defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
            guard let supplied = values[name] else { return defaultValue }
            guard let value = JSONSupport.exactInteger(supplied), range.contains(value) else {
                throw Failure.invalidArgument(name)
            }
            return value
        }
    }

    struct Cursor: Equatable {
        let scopeFingerprint: String
        let directoryFingerprint: String
        let lastName: Data

        init(scopeFingerprint: String, directoryFingerprint: String, lastName: Data) throws {
            guard Self.isDigest(scopeFingerprint), Self.isDigest(directoryFingerprint),
                  Self.isName(lastName) else { throw Failure.invalidCursor }
            self.scopeFingerprint = scopeFingerprint
            self.directoryFingerprint = directoryFingerprint
            self.lastName = lastName
        }

        init(_ token: String) throws {
            guard !token.isEmpty, token.utf8.count <= maximumCursorBytes,
                  token.utf8.allSatisfy({ Self.isBase64URLByte($0) }),
                  token.utf8.count % 4 != 1 else { throw Failure.invalidCursor }
            let encoded = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded + padding),
                  data.count <= maximumDecodedCursorBytes,
                  Self.base64URL(data) == token,
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(values.keys) == ["version", "scope", "directory", "last_name"],
                  JSONSupport.exactInteger(values["version"]) == 1,
                  let scope = values["scope"] as? String,
                  let directory = values["directory"] as? String,
                  let encodedName = values["last_name"] as? String,
                  encodedName.utf8.count <= ((Int(PATH_MAX) + 2) / 3) * 4,
                  let name = Data(base64Encoded: encodedName), name.base64EncodedString() == encodedName else {
                throw Failure.invalidCursor
            }
            try self.init(scopeFingerprint: scope, directoryFingerprint: directory, lastName: name)
            // Canonical re-encoding also rejects duplicate fields, alternate
            // numeric spellings and extra JSON whitespace without lossy decoding.
            guard try self.data() == data else { throw Failure.invalidCursor }
        }

        func encoded() throws -> String {
            let data = try self.data()
            guard data.count <= maximumDecodedCursorBytes else { throw Failure.invalidCursor }
            let token = Self.base64URL(data)
            guard token.utf8.count <= maximumCursorBytes else { throw Failure.invalidCursor }
            return token
        }

        private func data() throws -> Data {
            try JSONSupport.data(from: ["version": 1, "scope": scopeFingerprint,
                                        "directory": directoryFingerprint,
                                        "last_name": lastName.base64EncodedString()])
        }

        private static func isDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        private static func isName(_ value: Data) -> Bool {
            !value.isEmpty && value.count < Int(PATH_MAX) && !value.contains(0) && !value.contains(47)
                && value != Data([46]) && value != Data([46, 46])
        }

        private static func isBase64URLByte(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }

        private static func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }

    /// A max heap retains only the smallest capacity raw names beyond the cursor.
    /// Data equality preserves distinct canonically equivalent UTF-8 filenames.
    struct NameSelector {
        let capacity: Int
        let after: Data?
        private(set) var names: [Data] = []
        private var membership: Set<Data> = []

        init(capacity: Int, after: Data?) {
            self.capacity = max(1, min(maximumEntries + 1, capacity))
            self.after = after
            names.reserveCapacity(self.capacity)
        }

        mutating func consider(_ name: Data) {
            if let after, !after.lexicographicallyPrecedes(name) { return }
            guard !membership.contains(name) else { return }
            if names.count < capacity {
                names.append(name); membership.insert(name)
                var child = names.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard names[parent].lexicographicallyPrecedes(names[child]) else { break }
                    names.swapAt(parent, child); child = parent
                }
            } else if name.lexicographicallyPrecedes(names[0]) {
                membership.remove(names[0]); membership.insert(name); names[0] = name
                var parent = 0
                while parent * 2 + 1 < names.count {
                    let left = parent * 2 + 1, right = left + 1
                    let child = right < names.count && names[left].lexicographicallyPrecedes(names[right]) ? right : left
                    guard names[parent].lexicographicallyPrecedes(names[child]) else { break }
                    names.swapAt(parent, child); parent = child
                }
            }
        }

        var ordered: [Data] { names.sorted { $0.lexicographicallyPrecedes($1) } }
    }

    enum Observation: Sendable { case opened(Int32), entry(Int), scanned }
    struct ScanPolicy: Sendable {
        let maximumNames: Int
        let maximumSeconds: TimeInterval
        let observe: (@Sendable (Observation) throws -> Void)?
        let didClose: (@Sendable (Int32) -> Void)?

        init(maximumNames: Int = maximumScannedNames, maximumSeconds: TimeInterval = maximumScanSeconds,
             didClose: (@Sendable (Int32) -> Void)? = nil,
             observe: (@Sendable (Observation) throws -> Void)? = nil) {
            self.maximumNames = max(0, min(maximumScannedNames, maximumNames))
            self.maximumSeconds = maximumSeconds.isFinite ? max(0, min(maximumScanSeconds, maximumSeconds)) : maximumScanSeconds
            self.observe = observe
            self.didClose = didClose
        }
    }

    static func list(arguments: [String: Any], context: ToolInvocationContext?, clientID: ClientID,
                     app: ForgeApp, cancellation: ToolCallCancellation?,
                     policy: ScanPolicy = ScanPolicy()) throws -> ToolResult {
        do {
            let parsed = try Arguments(arguments)
            guard !Thread.isMainThread else { throw Failure.workerRequired }
            guard let context, context.clientID == clientID else { throw Failure.contextRequired }
            let control = cancellation ?? ToolCallCancellation(timeoutSeconds: maximumScanSeconds)
            if let milliseconds = parsed.deadlineMilliseconds { try control.tightenDeadline(milliseconds: milliseconds) }
            try control.checkCancellation()
            try validateContext(context, app: app, cancellation: control)
            let path = try canonicalDispatchPath(parsed.path)
            let scope = try scopeFingerprint(context: context, path: path)
            if let cursor = parsed.cursor, cursor.scopeFingerprint != scope { throw Failure.cursorScope }
            let scanEnd = DispatchTime.now().uptimeNanoseconds
                + UInt64((policy.maximumSeconds * 1_000_000_000).rounded(.down))
            func check() throws {
                try control.checkCancellation()
                guard DispatchTime.now().uptimeNanoseconds < scanEnd else { throw Failure.scanDeadline }
            }
            try check()
            let directory = try ReadableDirectory(path: path, cancellation: control)
            defer { let status = directory.close(); policy.didClose?(status) }
            let before = try DirectoryVersion(descriptor: directory.descriptor)
            let directoryFingerprint = try before.fingerprint()
            if let cursor = parsed.cursor, cursor.directoryFingerprint != directoryFingerprint { throw Failure.directoryChanged }
            try policy.observe?(.opened(directory.descriptor))
            var selector = NameSelector(capacity: parsed.limit + 1, after: parsed.cursor?.lastName)
            var scanned = 0
            while true {
                try check()
                guard let name = try directory.nextName() else { break }
                if name == Data([46]) || name == Data([46, 46]) { continue }
                guard scanned < policy.maximumNames else { throw Failure.scanLimit }
                scanned += 1
                selector.consider(name)
                try policy.observe?(.entry(scanned))
            }
            try check()
            try policy.observe?(.scanned)
            let selected = selector.ordered
            let names = try selected.prefix(parsed.limit).map(displayName)
            let budget = min(parsed.maximumBytes, context.authorizationScope.maximumInlineOutputBytes)
            func candidate(_ count: Int) throws -> ToolResult? {
                try check()
                let hasMore = count < selected.count
                let next: Any = hasMore && count > 0
                    ? try Cursor(scopeFingerprint: scope, directoryFingerprint: directoryFingerprint,
                                 lastName: selected[count - 1]).encoded() : NSNull()
                let result = ToolResult.success(["path": path, "entries": Array(names.prefix(count)),
                    "truncated": hasMore, "maximum_entries": maximumEntries,
                    "returned_entries": count, "effective_limit": parsed.limit,
                    "has_more": hasMore, "next_cursor": next, "ordering": ordering])
                let frame = try MCPStdioTransport.encode(MCPToolResponse.object(
                    id: String(repeating: "x", count: 128), result: result))
                return budget > 0 && frame.count <= budget ? result : nil
            }
            let result: ToolResult
            if let complete = try candidate(names.count) { result = complete }
            else {
                guard !names.isEmpty, let first = try candidate(1) else { throw Failure.outputBudget }
                var fitting = first, lower = 2, upper = names.count - 1
                // Cursor lengths can vary with names. This conservative search
                // guarantees a fitting prefix; maximal utilization is not promised.
                while lower <= upper {
                    let count = lower + (upper - lower) / 2
                    if let page = try candidate(count) { fitting = page; lower = count + 1 }
                    else { upper = count - 1 }
                }
                result = fitting
            }
            try check()
            guard try DirectoryVersion(descriptor: directory.descriptor) == before else { throw Failure.directoryChanged }
            let reopened: Int32
            do { reopened = try openReadableDescriptor(path: path, cancellation: control) }
            catch is CancellationError { throw CancellationError() }
            catch let error as ToolCallDeadlineExceeded { throw error }
            catch { throw Failure.directoryChanged }
            defer { Darwin.close(reopened) }
            guard try DirectoryVersion(descriptor: reopened) == before else { throw Failure.directoryChanged }
            try validateContext(context, app: app, cancellation: control)
            try check()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch let failure as Failure { return failure.result }
        catch {
            let value = error as NSError
            var failure = ToolResult.failure(code: "listing_read_failed", message: "Directory listing could not be read")
            failure.payload["error_domain"] = value.domain
            failure.payload["error_numeric_code"] = value.code
            return failure
        }
    }

    static func scopeFingerprint(context: ToolInvocationContext, path: String) throws -> String {
        JSONSupport.sha256Hex(try JSONSupport.data(from: ["version": 1, "ordering": ordering,
            "project": context.projectID.description, "generation": String(context.projectGeneration.rawValue),
            "client": context.clientID.rawValue, "path": path]))
    }

    static func displayName(_ bytes: Data) throws -> String {
        guard let name = String(data: bytes, encoding: .utf8) else { throw Failure.nameEncoding }
        return name
    }

    private static func validateContext(_ context: ToolInvocationContext, app: ForgeApp,
                                        cancellation: ToolCallCancellation) throws {
        do { try app.projectContexts.validate(context, cancellation: cancellation) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ToolCallDeadlineExceeded { throw error }
        catch { throw Failure.contextStale }
    }

    private static func canonicalDispatchPath(_ path: String) throws -> String {
        var value = ToolArgHelpers.resolvePath(path).standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where value == alias || value.hasPrefix(alias + "/") {
            value = "/private" + value; break
        }
        let components = value.split(separator: "/")
        guard value.hasPrefix("/"), !value.utf8.contains(0), value.utf8.count < Int(PATH_MAX),
              components.count <= 256, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw Failure.invalidArgument("path")
        }
        return value
    }

    private static func openReadableDescriptor(path: String, cancellation: ToolCallCancellation) throws -> Int32 {
        try cancellation.checkCancellation()
        if path == "/" {
            let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard descriptor >= 0 else { throw posixError(errno) }
            return descriptor
        }
        let components = path.split(separator: "/").map(String.init)
        var parent = Darwin.open("/", O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { throw posixError(errno) }
        defer { Darwin.close(parent) }
        for component in components.dropLast() {
            try cancellation.checkCancellation()
            let next = Darwin.openat(parent, component, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH)
            guard next >= 0 else { throw posixError(errno) }
            Darwin.close(parent); parent = next
        }
        try cancellation.checkCancellation()
        let descriptor = Darwin.openat(parent, components.last!, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH)
        guard descriptor >= 0 else { throw posixError(errno) }
        return descriptor
    }

    private final class ReadableDirectory {
        let descriptor: Int32
        private var directory: UnsafeMutablePointer<DIR>?

        init(path: String, cancellation: ToolCallCancellation) throws {
            let descriptor = try openReadableDescriptor(path: path, cancellation: cancellation)
            guard let directory = Darwin.fdopendir(descriptor) else {
                let code = errno; Darwin.close(descriptor); throw posixError(code)
            }
            self.descriptor = descriptor; self.directory = directory
        }
        deinit { close() }

        @discardableResult
        func close() -> Int32 {
            guard let directory else { return 0 }
            self.directory = nil
            return Darwin.closedir(directory)
        }

        func nextName() throws -> Data? {
            guard let directory else { throw posixError(EBADF) }
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw posixError(errno) }
                return nil
            }
            let length = Int(entry.pointee.d_namlen)
            return try withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                guard length > 0, length < bytes.count, bytes[length] == 0 else { throw Failure.nameEncoding }
                let name = Data(bytes.prefix(length))
                guard !name.contains(0), !name.contains(47) else { throw Failure.nameEncoding }
                return name // Copy before the next readdir invalidates its storage.
            }
        }
    }

    struct DirectoryVersion: Equatable {
        let device: Int64
        let inode: UInt64
        let mode: UInt16
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(descriptor: Int32) throws {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0 else { throw posixError(errno) }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw posixError(ENOTDIR) }
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); mode = value.st_mode
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }

        func fingerprint() throws -> String {
            // Metadata fences are not an atomic content snapshot or an admission
            // vnode identity. A replacement before this first open is unobserved.
            JSONSupport.sha256Hex(try JSONSupport.data(from: ["device": String(device), "inode": String(inode),
                "mode": String(mode), "mtime_seconds": String(modifiedSeconds), "mtime_nanoseconds": String(modifiedNanoseconds),
                "ctime_seconds": String(changedSeconds), "ctime_nanoseconds": String(changedNanoseconds)]))
        }
    }

    private static func posixError(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

    enum Failure: Error {
        case invalidArgument(String), invalidCursor, cursorScope, directoryChanged, scanLimit, scanDeadline
        case nameEncoding, outputBudget, contextRequired, contextStale, workerRequired

        var result: ToolResult {
            let code: String, message: String
            switch self {
            case .invalidArgument(let field): code = "listing_invalid_argument"; message = "Invalid listing field: \(field)"
            case .invalidCursor: code = "listing_invalid_cursor"; message = "The listing cursor is not canonical version 1"
            case .cursorScope: code = "listing_cursor_scope_mismatch"; message = "The listing cursor belongs to a different invocation or path"
            case .directoryChanged: code = "directory_changed"; message = "The directory changed; restart its listing"
            case .scanLimit: code = "listing_scan_limit"; message = "The listing scan exceeds its bounded entry quota"
            case .scanDeadline: code = "listing_scan_deadline"; message = "The listing scan exceeded its finite deadline"
            case .nameEncoding: code = "listing_name_encoding_unsupported"; message = "A directory filename cannot be represented as UTF-8 text"
            case .outputBudget: code = "listing_output_budget"; message = "The listing response cannot fit the inline budget"
            case .contextRequired: code = "project_context_required"; message = "Attach an active project before listing with continuation"
            case .contextStale: code = "project_context_stale"; message = "Project authorization changed during the listing"
            case .workerRequired: code = "listing_worker_required"; message = "Directory continuation must run on a worker thread"
            }
            return .failure(code: code, message: message, retryable: code == "directory_changed")
        }
    }
}
