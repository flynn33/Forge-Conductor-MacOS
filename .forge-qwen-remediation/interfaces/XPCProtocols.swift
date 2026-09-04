import Foundation

// Shared XPC value types must remain NSSecureCoding-compatible or use a
// versioned Data envelope decoded with strict size/schema checks.

@objc public protocol ForgeRuntimeXPCProtocol {
    func capabilities(withReply reply: @escaping (Data?, Error?) -> Void)
    func startJob(request: Data, withReply reply: @escaping (Data?, Error?) -> Void)
    func cancelJob(jobID: String, leaseEpoch: Int64, withReply reply: @escaping (Data?, Error?) -> Void)
    func jobStatus(jobID: String, withReply reply: @escaping (Data?, Error?) -> Void)
}

public struct HardenedRuntimeRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let jobID: String
    public let projectID: String
    public let projectGeneration: Int64
    public let leaseEpoch: Int64
    public let executableBookmarkID: String?
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectoryBookmarkID: String
    public let environment: [String: String]
    public let timeoutSeconds: Int
    public let maximumOutputBytes: Int
    public let networkPolicy: NetworkPolicy

    public enum NetworkPolicy: String, Codable, Sendable {
        case denied
        case loopbackOnly
        case allowed
    }
}

public struct HardenedRuntimeReceipt: Codable, Sendable {
    public let schemaVersion: Int
    public let jobID: String
    public let projectID: String
    public let projectGeneration: Int64
    public let leaseEpoch: Int64
    public let startedAt: String
    public let endedAt: String
    public let exitCode: Int32?
    public let terminationReason: String
    public let stdoutBytes: Int
    public let stderrBytes: Int
    public let stdoutSHA256: String
    public let stderrSHA256: String
    public let descendantsTerminated: Bool
    public let receiptSHA256: String
}
