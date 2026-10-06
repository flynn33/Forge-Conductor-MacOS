import Foundation

public enum XcodeDiscoveryQuery: String, Sendable, CaseIterable {
    case version, sdks, schemes, destinations
    case buildSettings = "build_settings"
    case testPlans = "test_plans"
}

public enum XcodeNativeAction: String, Sendable, CaseIterable {
    case build, test, analyze, archive
    case buildForTesting = "build-for-testing"
    case testWithoutBuilding = "test-without-building"

    var executesTests: Bool { self == .test || self == .testWithoutBuilding }
    var acceptsTestSelection: Bool { executesTests || self == .buildForTesting }
}

public enum XcodeResultQuery: String, Sendable, CaseIterable {
    case buildResults = "build_results"
    case testSummary = "test_summary"
    case tests, insights
}

public enum XcodeSimulatorQuery: String, Sendable, CaseIterable {
    case devices, runtimes, devicetypes
}

/// One native argument vector. The existing execution service owns its process,
/// deadline, durable project identity, output budget, and cancellation boundary.
struct XcodeCLICommand: Sendable, Equatable {
    let arguments: [String]
    let workingDirectory: URL
    let timeoutSeconds: Int
    let maximumInlineOutputBytes: Int
    let replayClass: RuntimeReplayClass
    let idempotencyKey: String?
    let resultBundlePath: String?
    let derivedDataPath: String?
}
