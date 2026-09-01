// Exercises the shipped command adapter as a child process instead of calling
// implementation helpers directly.

import Foundation
import XCTest
@testable import ForgeConductorCore

final class CLIContractTests: XCTestCase {
    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private var home: URL!
    private var executable: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-cli-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        executable = try locateBuiltCLI()
    }

    override func tearDownWithError() throws {
        if let executable, let home {
            _ = try? run(
                executable,
                arguments: ["manager", "stop", "--home", home.path],
                timeout: 10
            )
        }
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
    }

    func testHelpVersionStatusAndInvalidCommandsPreserveCLIContract() throws {
        let help = try run(executable, arguments: ["help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("Forge-Conductor 0.9.0"))
        XCTAssertTrue(help.stdout.contains("serve"))
        XCTAssertTrue(help.stdout.contains("manager"))
        XCTAssertTrue(help.stdout.contains("install"))

        let version = try run(executable, arguments: ["--version"])
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0.9.0")

        let status = try run(
            executable,
            arguments: ["status", "--home", home.path]
        )
        XCTAssertEqual(status.status, 0, status.stderr)
        let statusObject = try JSONSupport.object(from: Data(status.stdout.utf8))
        XCTAssertEqual(statusObject["version"] as? String, "0.9.0")
        XCTAssertEqual(statusObject["manager_running"] as? Bool, false)

        let managerHelp = try run(executable, arguments: ["manager", "--help"])
        XCTAssertEqual(managerHelp.status, 0)
        XCTAssertTrue(managerHelp.stdout.contains("manager <subcommand>"))
        XCTAssertTrue(managerHelp.stdout.contains("restart"))

        let invalid = try run(executable, arguments: ["not-a-command"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertTrue(invalid.stderr.contains("Unknown command: not-a-command"))

        let invalidManager = try run(
            executable,
            arguments: ["manager", "not-a-subcommand"]
        )
        XCTAssertEqual(invalidManager.status, 2)
        XCTAssertTrue(
            invalidManager.stderr.contains("Unknown manager subcommand: not-a-subcommand")
        )
    }

    func testManagerStartStatusRestartAndStopUsePersistentProductBoundary() throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 40_000...49_000)
        try app.config.update(
            [
                "dashboard": [
                    "host": "127.0.0.1",
                    "port": port,
                ] as [String: Any],
            ],
            save: true
        )
        XCTAssertTrue(app.shutdown().completed)

        let start = try run(
            executable,
            arguments: ["manager", "start", "--home", home.path],
            timeout: 15
        )
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertTrue(start.stdout.contains("Manager started"))

        let firstStatus = try managerStatus()
        XCTAssertEqual(firstStatus["manager_running"] as? Bool, true)
        let firstPID = try XCTUnwrap(firstStatus["pid"] as? Int)
        let firstDashboard = try XCTUnwrap(firstStatus["dashboard"] as? [String: Any])
        XCTAssertEqual(firstDashboard["port"] as? Int, port)
        XCTAssertNotNil(firstStatus["live"] as? [String: Any])

        let restart = try run(
            executable,
            arguments: ["manager", "restart", "--home", home.path],
            timeout: 20
        )
        XCTAssertEqual(restart.status, 0, restart.stderr)
        XCTAssertTrue(restart.stdout.contains("Manager stopped"))
        XCTAssertTrue(restart.stdout.contains("Manager started"))

        let secondStatus = try managerStatus()
        XCTAssertEqual(secondStatus["manager_running"] as? Bool, true)
        let secondPID = try XCTUnwrap(secondStatus["pid"] as? Int)
        XCTAssertNotEqual(secondPID, firstPID)
        XCTAssertNotNil(secondStatus["live"] as? [String: Any])

        let stop = try run(
            executable,
            arguments: ["manager", "stop", "--home", home.path],
            timeout: 15
        )
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertTrue(stop.stdout.contains("Manager stopped"))

        let stoppedStatus = try managerStatus()
        XCTAssertEqual(stoppedStatus["manager_running"] as? Bool, false)
        XCTAssertTrue(
            stoppedStatus["pid"] == nil || stoppedStatus["pid"] is NSNull,
            "A stopped manager must expose no numeric process identifier"
        )
    }

    private func managerStatus() throws -> [String: Any] {
        let result = try run(
            executable,
            arguments: ["manager", "status", "--home", home.path],
            timeout: 10
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        return try JSONSupport.object(from: Data(result.stdout.utf8))
    }

    private func locateBuiltCLI() throws -> URL {
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
        let sibling = productsDirectory.appendingPathComponent("forge-conductor")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        let repositoryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let defaultProduct = repositoryRoot.appendingPathComponent(
            ".build/debug/forge-conductor"
        )
        if FileManager.default.isExecutableFile(atPath: defaultProduct.path) {
            return defaultProduct
        }
        throw XCTSkip("Build the forge-conductor product before running CLI contract tests")
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 10
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        var environment = ProcessInfo.processInfo.environment
        environment["FORGE_CONDUCTOR_HOME"] = home.path
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            XCTFail("CLI command timed out: \(arguments.joined(separator: " "))")
        }

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}
