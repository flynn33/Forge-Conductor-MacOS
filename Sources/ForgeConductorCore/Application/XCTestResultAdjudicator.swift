import Foundation

/// Semantic inspection of xcresulttool test-results schema 0.1.0. These values
/// are evidence, never approval authority: only the manager's trusted job path
/// may combine them with execution provenance and issue an approval.
public enum XCTestResultAdjudicator {
    public struct Report: Codable, Sendable, Equatable {
        public let passed: Bool
        public let cases: [CaseResult]
        public let failures: [String]
        public let startedAt: Date
        public let finishedAt: Date
    }

    public struct CaseResult: Codable, Sendable, Equatable {
        public let identifier: String
        public let result: String
    }

    public static func adjudicate(
        summary: Data,
        tests: Data,
        requiredCases: Set<String>,
        minimumCaseCount: Int
    ) throws -> Report {
        guard !requiredCases.isEmpty, requiredCases.count <= 10_000,
              requiredCases.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }),
              (requiredCases.count...10_000).contains(minimumCaseCount),
              summary.count <= 4 * 1_048_576, tests.count <= 16 * 1_048_576 else {
            throw AutonomyError.invalidRequest("native test policy or result exceeds its bounds")
        }
        let decoder = JSONDecoder()
        let overview = try decoder.decode(Summary.self, from: summary)
        let tree = try decoder.decode(Tests.self, from: tests)
        guard overview.startTime.isFinite, overview.finishTime.isFinite,
              overview.startTime > 0, overview.finishTime >= overview.startTime,
              !overview.environmentDescription.isEmpty,
              !tree.devices.isEmpty, !tree.testPlanConfigurations.isEmpty else {
            throw AutonomyError.invalidRequest("native test environment or timing is missing")
        }
        var cases: [CaseResult] = []
        var failures: [String] = []
        var nodeCount = 0
        func walk(_ nodes: [Node], depth: Int) throws {
            guard depth <= 32 else {
                throw AutonomyError.invalidRequest("native test result nesting exceeds its bound")
            }
            for node in nodes {
                nodeCount += 1
                guard nodeCount <= 50_000, node.name.utf8.count <= 2_048 else {
                    throw AutonomyError.invalidRequest("native test result tree exceeds its bound")
                }
                if let result = node.result, result != "Passed" {
                    failures.append("Non-passing test node: \(node.name)")
                }
                if node.nodeType == "Test Case" {
                    guard let identifier = node.nodeIdentifier, !identifier.isEmpty,
                          identifier.utf8.count <= 2_048, let result = node.result,
                          cases.count < 10_000 else {
                        throw AutonomyError.invalidRequest("native test case identity or result is missing")
                    }
                    cases.append(CaseResult(identifier: identifier, result: result))
                }
                if node.nodeType == "Failure Message" {
                    failures.append("Test result contains a failure message")
                }
                try walk(node.children ?? [], depth: depth + 1)
            }
        }
        try walk(tree.testNodes, depth: 0)
        let identities = Set(cases.map(\.identifier))
        guard identities.count == cases.count else {
            throw AutonomyError.invalidRequest("native test result repeats a case identity")
        }
        if overview.result != "Passed" || overview.failedTests != 0
            || overview.skippedTests != 0 || overview.expectedFailures != 0
            || !overview.testFailures.isEmpty {
            failures.append("Native test summary reports failure, skip, or unexpected result")
        }
        if overview.totalTestCount != cases.count || overview.passedTests != cases.count
            || cases.count < minimumCaseCount {
            failures.append("Native test counts do not match the required completed cases")
        }
        if !requiredCases.isSubset(of: identities) {
            failures.append("Required native test case identities are missing")
        }
        return Report(
            passed: failures.isEmpty,
            cases: cases.sorted { $0.identifier < $1.identifier },
            failures: Array(failures.prefix(256)),
            startedAt: Date(timeIntervalSince1970: overview.startTime),
            finishedAt: Date(timeIntervalSince1970: overview.finishTime)
        )
    }

    private struct Summary: Decodable {
        let startTime: Double
        let finishTime: Double
        let environmentDescription: String
        let result: String
        let totalTestCount: Int
        let passedTests: Int
        let failedTests: Int
        let skippedTests: Int
        let expectedFailures: Int
        let testFailures: [TestFailure]
    }

    private struct TestFailure: Decodable {
        let failureText: String
    }

    private struct Tests: Decodable {
        let devices: [Device]
        let testPlanConfigurations: [Configuration]
        let testNodes: [Node]
    }

    private struct Device: Decodable {
        let deviceId: String
        let architecture: String
        let osVersion: String
    }

    private struct Configuration: Decodable {
        let configurationId: String
    }

    private struct Node: Decodable {
        let nodeType: String
        let name: String
        let nodeIdentifier: String?
        let result: String?
        let children: [Node]?
    }
}
