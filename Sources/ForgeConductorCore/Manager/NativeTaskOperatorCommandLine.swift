import Foundation

/// The CLI attaches to the existing manager and never opens its control-plane database.
public enum NativeTaskOperatorCommandLine {
    public static let usage = """
    forge-conductor manager task prepare --request /absolute/approval.json [--home PATH]
    forge-conductor manager task reconcile --task UUID [--home PATH]
    forge-conductor manager task rotate --task UUID --expected-epoch N --expires-at UTC [--home PATH]
    forge-conductor manager task revoke --task UUID --expected-epoch N [--reason TEXT] [--home PATH]
    Credentials remain in the installation's protected native task store. Output contains only safe task receipts and paths.
    """

    public static func run(arguments: [String]) async throws -> Data {
        let options = try Options(arguments)
        let paths = AppPaths(home: options.home)
        let configuration = try OwnerOnlyAtomicFile.read(from: paths.configJSON, maximumBytes: 1_048_576)
        let object = try JSONSupport.object(from: configuration)
        let dashboard = object["dashboard"] as? [String: Any] ?? [:]
        let host = dashboard["host"] as? String ?? "127.0.0.1"
        let port: Int
        if dashboard["port"] == nil { port = 7788 }
        else if let value = JSONSupport.exactInteger(dashboard["port"]) { port = value }
        else { throw NativeTaskOperatorError.invalidRequest("manager_endpoint") }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port; components.path = "/mcp/continuity"
        guard let endpoint = components.url else { throw NativeTaskOperatorError.invalidRequest("manager_endpoint") }
        try NativeTaskOperatorEndpoint.validate(endpoint)
        let client = try NativeTaskOperatorClient(store: NativeTaskCredentialFileStore(paths: paths),
            transport: ManagerDashboardClient(host: host, port: port, credentials: ManagerControlCredentialStore(paths: paths)), endpoint: endpoint)
        return try await execute(options, client: client)
    }

    static func execute(_ options: Options, client: NativeTaskOperatorClient) async throws -> Data {
        do {
            let result: NativeTaskCredentialSnapshot
            switch options.action {
            case "prepare":
                let data = try OwnerOnlyAtomicFile.read(from: URL(fileURLWithPath: options.values["--request"]!),
                    maximumBytes: NativeContinuityTaskPreparationRequest.maximumBodyBytes)
                result = try await client.prepare(NativeContinuityTaskPreparationInput(data: data))
            case "reconcile": result = try await client.reconcile(taskID: options.taskID!)
            case "rotate": result = try await client.rotate(taskID: options.taskID!, expectedEpoch: options.epoch!, expiresAt: options.values["--expires-at"]!)
            case "revoke": result = try await client.revoke(taskID: options.taskID!, expectedEpoch: options.epoch!, reason: options.values["--reason"])
            default: throw NativeTaskOperatorError.invalidRequest("command")
            }
            var object = result.wireObject; object["ok"] = true
            return try ForgeJSONCanonicalizationV1.data(from: object)
        } catch let pending as NativeTaskOperatorPendingCommand {
            var object = pending.snapshot.wireObject
            object["ok"] = false; object["code"] = "reconciliation_required"
            object["next_action"] = "manager task reconcile --task " + pending.snapshot.taskID.uuidString.lowercased()
            return try ForgeJSONCanonicalizationV1.data(from: object)
        }
    }

    struct Options: Sendable {
        let action: String
        let values: [String: String]
        let taskID: UUID?
        let epoch: Int64?
        var home: URL? { values["--home"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
        init(_ arguments: [String]) throws {
            guard let action = arguments.first, ["prepare", "reconcile", "rotate", "revoke"].contains(action),
                  arguments.count <= 13, arguments.count % 2 == 1 else { throw NativeTaskOperatorError.invalidRequest("command") }
            self.action = action
            let required: Set<String>
            switch action {
            case "prepare": required = ["--request"]
            case "reconcile": required = ["--task"]
            case "rotate": required = ["--task", "--expected-epoch", "--expires-at"]
            default: required = ["--task", "--expected-epoch"]
            }
            let allowed = required.union(["--home"]).union(action == "revoke" ? ["--reason"] : [])
            var values: [String: String] = [:]
            for index in stride(from: 1, to: arguments.count, by: 2) {
                let key = arguments[index], value = arguments[index + 1]
                guard allowed.contains(key), values[key] == nil, !value.isEmpty, value.utf8.count <= 4_096,
                      !value.contains("\0") else { throw NativeTaskOperatorError.invalidRequest("options") }
                values[key] = value
            }
            guard required.isSubset(of: Set(values.keys)) else { throw NativeTaskOperatorError.invalidRequest("options") }
            for key in ["--request", "--home"] {
                if let value = values[key], !(value as NSString).isAbsolutePath { throw NativeTaskOperatorError.invalidRequest("path") }
            }
            if let value = values["--task"] {
                guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { throw NativeTaskOperatorError.invalidRequest("task") }
                taskID = id
            } else { taskID = nil }
            if let value = values["--expected-epoch"] {
                guard let epoch = Int64(value), epoch > 0, epoch < Int64.max, String(epoch) == value else { throw NativeTaskOperatorError.invalidRequest("expected_epoch") }
                self.epoch = epoch
            } else { epoch = nil }
            if let value = values["--expires-at"] { _ = try NativeTaskOperatorWire.date(["expires_at": value], "expires_at") }
            if let value = values["--reason"] { _ = try NativeTaskOperatorWire.string(["reason": value], "reason", maximum: 512) }
            self.values = values
        }
    }
}
