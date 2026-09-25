import Darwin
import XCTest
@testable import ForgeConductorCore

private final class DesktopPluginCommandFixture: DesktopProviderPluginCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executable: String
        var arguments: [String]
        var timeoutSeconds: TimeInterval
        var maximumOutputBytes: Int
    }

    private let lock = NSLock()
    private let available: Set<String>
    private let result: DesktopProviderPluginCommandResult
    private let removalResult: DesktopProviderPluginCommandResult?
    private let deactivateAfterRemovalAttempt: Bool
    private let codexMarketplace: String
    private let initialInventoryEnabled: Bool
    private let resultForInvocation: @Sendable (Invocation) -> DesktopProviderPluginCommandResult?
    private let onInvocation: @Sendable (Invocation) -> Void
    private var storedInvocations: [Invocation] = []
    private var deactivatedExecutables: Set<String> = []

    init(
        available: Set<String> = [],
        result: DesktopProviderPluginCommandResult = .init(exitCode: 0),
        removalResult: DesktopProviderPluginCommandResult? = nil,
        deactivateAfterRemovalAttempt: Bool = false,
        codexMarketplace: String = "personal",
        initialInventoryEnabled: Bool = true,
        resultForInvocation: @escaping @Sendable (Invocation) -> DesktopProviderPluginCommandResult? = { _ in nil },
        onInvocation: @escaping @Sendable (Invocation) -> Void = { _ in }
    ) {
        self.available = available
        self.result = result
        self.removalResult = removalResult
        self.deactivateAfterRemovalAttempt = deactivateAfterRemovalAttempt
        self.codexMarketplace = codexMarketplace
        self.initialInventoryEnabled = initialInventoryEnabled
        self.resultForInvocation = resultForInvocation
        self.onInvocation = onInvocation
    }

    func executable(named name: String) -> URL? {
        available.contains(name) ? URL(fileURLWithPath: "/usr/bin/\(name)") : nil
    }

    func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> DesktopProviderPluginCommandResult {
        let invocation = Invocation(
            executable: executable.path,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            maximumOutputBytes: maximumOutputBytes
        )
        lock.lock()
        storedInvocations.append(invocation)
        lock.unlock()
        onInvocation(invocation)
        if let scripted = resultForInvocation(invocation) {
            return scripted
        }
        let isRemoval = Self.isRemovalCommand(arguments, executable: executable.lastPathComponent)
        let effectiveResult = isRemoval ? (removalResult ?? result) : result
        if isRemoval,
           (deactivateAfterRemovalAttempt
               || (effectiveResult.exitCode == 0 && !effectiveResult.timedOut)) {
            lock.lock()
            deactivatedExecutables.insert(executable.lastPathComponent)
            lock.unlock()
        }
        guard effectiveResult.stdout.isEmpty,
              arguments == ["plugin", "list", "--json"] else {
            return effectiveResult
        }
        var synthesized = effectiveResult
        lock.lock()
        let deactivated = deactivatedExecutables.contains(executable.lastPathComponent)
        lock.unlock()
        if executable.lastPathComponent == "claude" {
            synthesized.stdout = deactivated ? "[]" : """
                [{"id":"forge-conductor@forge-conductor","name":"forge-conductor","marketplaceName":"forge-conductor","version":"1.2.3","source":"forge-conductor","installed":true,"enabled":true}]
                """
        } else if executable.lastPathComponent == "codex" {
            synthesized.stdout = deactivated ? "{\"installed\":[],\"available\":[]}" : """
                {"installed":[{"pluginId":"forge-conductor@\(codexMarketplace)","name":"forge-conductor","marketplaceName":"\(codexMarketplace)","installed":true,"enabled":\(initialInventoryEnabled)}],"available":[]}
                """
        } else if executable.lastPathComponent == "grok" {
            synthesized.stdout = deactivated ? """
                [{"id":"forge-conductor","name":"forge-conductor","installed":true,"enabled":false}]
                """ : """
                [{"id":"forge-conductor","name":"forge-conductor","installed":true,"enabled":true}]
                """
        }
        return synthesized
    }

    private static func isRemovalCommand(_ arguments: [String], executable: String) -> Bool {
        switch executable {
        case "claude": arguments.starts(with: ["plugin", "uninstall"])
        case "codex": arguments.starts(with: ["plugin", "remove"])
        case "grok": arguments == ["plugin", "disable", "forge-conductor"]
        default: false
        }
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocations
    }
}

final class DesktopProviderPluginInstallerTests: XCTestCase {
    private var root: URL!
    private var userHome: URL!
    private var forgeHome: URL!
    private var forgeOwnedRoot: URL!
    private var grokHome: URL!
    private var executable: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desktop plugin fixture \(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        userHome = root.appendingPathComponent("user", isDirectory: true)
        forgeHome = root.appendingPathComponent("forge-home", isDirectory: true)
        forgeOwnedRoot = forgeHome.appendingPathComponent("desktop-provider-plugins", isDirectory: true)
        grokHome = userHome.appendingPathComponent("custom-grok-home", isDirectory: true)
        let binaryDirectory = root.appendingPathComponent("signed app", isDirectory: true)
        executable = binaryDirectory.appendingPathComponent("Forge Conductor")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try OwnerOnlyAtomicFile.write(Data("#!/bin/sh\nexit 0\n".utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testNativeCommandDiscoveryUsesPATHThenCanonicalGUIFallbacks() throws {
        let pathExecutable = root.appendingPathComponent("path-bin/codex")
        try FileManager.default.createDirectory(
            at: pathExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try OwnerOnlyAtomicFile.write(Data("#!/bin/sh\nexit 0\n".utf8), to: pathExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: pathExecutable.path
        )
        let grokFallback = userHome.appendingPathComponent(".grok/bin/grok")
        try FileManager.default.createDirectory(
            at: grokFallback.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try OwnerOnlyAtomicFile.write(Data("#!/bin/sh\nexit 0\n".utf8), to: grokFallback)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: grokFallback.path
        )

        XCTAssertEqual(
            DesktopProviderPluginNativeCommandRunner.discoverExecutable(
                named: "codex",
                pathCandidate: pathExecutable.path,
                homeDirectory: userHome,
                fileManager: .default
            )?.path,
            pathExecutable.path
        )
        XCTAssertEqual(
            DesktopProviderPluginNativeCommandRunner.discoverExecutable(
                named: "grok",
                pathCandidate: nil,
                homeDirectory: userHome,
                fileManager: .default
            )?.path,
            grokFallback.path
        )
        XCTAssertNil(DesktopProviderPluginNativeCommandRunner.discoverExecutable(
            named: "unsupported-host",
            pathCandidate: pathExecutable.path,
            homeDirectory: userHome,
            fileManager: .default
        ))
    }

    func testClaudePackageSettingsAndCommandsHaveExactSupportedShape() throws {
        let settingsURL = userHome.appendingPathComponent(".claude/settings.json")
        try writeJSON([
            "theme": "dark",
            "extraKnownMarketplaces": [
                "company": [
                    "source": ["source": "directory", "path": "/company/plugins"],
                    "autoUpdate": true,
                ],
            ],
            "enabledPlugins": ["company-tool@company": false],
        ], to: settingsURL)
        let runner = DesktopPluginCommandFixture(available: ["claude"])
        let installer = makeInstaller(runner: runner)

        let status = try installer.install(request(.claudeCodeDesktop, mcp: true))

        XCTAssertEqual(status.disposition, .installed)
        XCTAssertTrue(status.packageVerified)
        XCTAssertTrue(status.configurationVerified)
        XCTAssertTrue(status.deploymentVerified)
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.warnings, [.hookTrustReviewRequired])
        let marketplaceRoot = URL(fileURLWithPath: status.packagePath, isDirectory: true)
        XCTAssertEqual(
            try relativeFiles(at: marketplaceRoot),
            [
                ".forge-conductor-owner.json",
                ".claude-plugin/marketplace.json",
                "plugins/forge-conductor/.claude-plugin/plugin.json",
                "plugins/forge-conductor/.mcp.json",
                "plugins/forge-conductor/hooks/hooks.json",
                "plugins/forge-conductor/skills/forge-run/SKILL.md",
            ]
        )

        let catalog = try json(at: marketplaceRoot.appendingPathComponent(".claude-plugin/marketplace.json"))
        XCTAssertEqual(catalog["name"] as? String, "forge-conductor")
        let catalogPlugins = try XCTUnwrap(catalog["plugins"] as? [[String: Any]])
        XCTAssertEqual(catalogPlugins.count, 1)
        XCTAssertEqual(catalogPlugins[0]["source"] as? String, "./plugins/forge-conductor")

        let pluginRoot = marketplaceRoot.appendingPathComponent("plugins/forge-conductor", isDirectory: true)
        let manifest = try json(at: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        XCTAssertEqual(manifest["hooks"] as? String, "./hooks/hooks.json")
        XCTAssertEqual(manifest["mcpServers"] as? String, "./.mcp.json")
        let mcp = try json(at: pluginRoot.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["forge-conductor"]?["command"] as? String, executable.path)
        XCTAssertEqual(
            servers["forge-conductor"]?["args"] as? [String],
            ["serve", "--home", forgeHome.path, "--desktop-provider", "claude-desktop"]
        )
        try assertHooks(
            at: pluginRoot,
            providerID: "claude-desktop",
            expectedEvents: [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                "PostToolUse", "PostToolUseFailure", "Stop", "SessionEnd",
            ]
        )

        let settings = try json(at: settingsURL)
        XCTAssertEqual(settings["theme"] as? String, "dark")
        let marketplaces = try XCTUnwrap(settings["extraKnownMarketplaces"] as? [String: Any])
        XCTAssertNotNil(marketplaces["company"])
        let forgeMarketplace = try XCTUnwrap(marketplaces["forge-conductor"] as? [String: Any])
        let forgeSource = try XCTUnwrap(forgeMarketplace["source"] as? [String: Any])
        XCTAssertEqual(forgeSource["source"] as? String, "directory")
        XCTAssertEqual(forgeSource["path"] as? String, marketplaceRoot.path)
        let enabled = try XCTUnwrap(settings["enabledPlugins"] as? [String: Any])
        XCTAssertEqual(enabled["company-tool@company"] as? Bool, false)
        XCTAssertEqual(enabled["forge-conductor@forge-conductor"] as? Bool, true)

        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["plugin", "validate", marketplaceRoot.path],
            ["plugin", "marketplace", "add", marketplaceRoot.path],
            ["plugin", "install", "forge-conductor@forge-conductor", "--scope", "user"],
            ["plugin", "list", "--json"],
        ])
        XCTAssertTrue(runner.invocations.allSatisfy { $0.timeoutSeconds == 15 && $0.maximumOutputBytes == 32 * 1_024 })
    }

    func testCodexCompatibilityPackageMCPOnAndOffPreservesForeignMarketplaceEntry() throws {
        let marketplaceURL = userHome.appendingPathComponent(".agents/plugins/marketplace.json")
        try writeJSON([
            "name": "personal",
            "interface": ["displayName": "My Personal Plugins", "accent": "orange"],
            "plugins": [[
                "name": "foreign-tool",
                "source": ["source": "local", "path": "./plugins/foreign-tool"],
                "policy": ["installation": "AVAILABLE", "authentication": "ON_USE"],
                "category": "Productivity",
            ]],
        ], to: marketplaceURL)
        let runner = DesktopPluginCommandFixture(available: ["codex"])
        let installer = makeInstaller(runner: runner)

        let enabled = try installer.install(request(.codexDesktop, mcp: true))
        let pluginRoot = URL(fileURLWithPath: enabled.packagePath, isDirectory: true)
        XCTAssertEqual(enabled.disposition, .installed)
        XCTAssertTrue(enabled.deploymentVerified)
        XCTAssertEqual(enabled.warnings, [.hookTrustReviewRequired])
        XCTAssertEqual(
            try relativeFiles(at: pluginRoot),
            [
                ".codex-plugin/plugin.json",
                ".forge-conductor-owner.json",
                ".mcp.json",
                "bin/forge-conductor",
                "hooks/hooks.json",
                "skills/forge-run/SKILL.md",
            ]
        )
        let compatibility = try json(at: pluginRoot.appendingPathComponent(".codex-plugin/plugin.json"))
        XCTAssertEqual(compatibility["mcpServers"] as? String, "./.mcp.json")
        XCTAssertEqual(compatibility["hooks"] as? String, "./hooks/hooks.json")
        let mcp = try json(at: pluginRoot.appendingPathComponent(".mcp.json"))
        XCTAssertNil(mcp["$schema"])
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: [String: Any]])
        XCTAssertNil(servers["forge-conductor"]?["type"])
        XCTAssertEqual(
            servers["forge-conductor"]?["command"] as? String,
            executable.path
        )
        XCTAssertEqual(
            servers["forge-conductor"]?["args"] as? [String],
            ["serve", "--home", forgeHome.path, "--desktop-provider", "codex-desktop"]
        )
        let embeddedBridge = pluginRoot.appendingPathComponent("bin/forge-conductor")
        XCTAssertEqual(try Data(contentsOf: embeddedBridge), try Data(contentsOf: executable))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: embeddedBridge.path))
        try assertHooks(
            at: pluginRoot,
            providerID: "codex-desktop",
            expectedEvents: [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                "PostToolUse", "Stop", "SessionEnd",
            ]
        )

        var catalog = try json(at: marketplaceURL)
        var plugins = try XCTUnwrap(catalog["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.map { $0["name"] as? String }, ["foreign-tool", "forge-conductor"])
        XCTAssertEqual((catalog["interface"] as? [String: Any])?["accent"] as? String, "orange")
        let ownSource = try XCTUnwrap(plugins[1]["source"] as? [String: Any])
        XCTAssertEqual(ownSource["path"] as? String, "./plugins/forge-conductor")
        let ownPolicy = try XCTUnwrap(plugins[1]["policy"] as? [String: Any])
        XCTAssertEqual(ownPolicy["installation"] as? String, "INSTALLED_BY_DEFAULT")

        let disabled = try installer.install(request(.codexDesktop, mcp: false))
        XCTAssertEqual(disabled.disposition, .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent(".mcp.json").path))
        let disabledCompatibility = try json(at: pluginRoot.appendingPathComponent(".codex-plugin/plugin.json"))
        XCTAssertNil(disabledCompatibility["mcpServers"])
        XCTAssertEqual(disabledCompatibility["hooks"] as? String, "./hooks/hooks.json")
        catalog = try json(at: marketplaceURL)
        plugins = try XCTUnwrap(catalog["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.map { $0["name"] as? String }, ["foreign-tool", "forge-conductor"])
        XCTAssertEqual(runner.invocations.suffix(3).map(\.arguments), [
            ["plugin", "list", "--json"],
            ["plugin", "add", "forge-conductor@personal"],
            ["plugin", "list", "--json"],
        ])
    }

    func testCodexCompatibilityMCPManifestUsesSignedExecutableWithoutPortableSchema() throws {
        let installer = makeInstaller(
            runner: DesktopPluginCommandFixture(available: ["codex"])
        )

        let status = try installer.install(request(.codexDesktop, mcp: true))

        let pluginRoot = URL(fileURLWithPath: status.packagePath, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("plugin.json").path))
        let mcp = try json(at: pluginRoot.appendingPathComponent(".mcp.json"))
        XCTAssertEqual(Set(mcp.keys), ["mcpServers"])
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(
            servers["forge-conductor"]?["command"] as? String,
            executable.path
        )
    }

    func testCodexPackageFromXcodeAppEmbedsLaunchableFrameworkRuntimeClosure() throws {
        let app = root.appendingPathComponent("Forge Conductor.app", isDirectory: true)
        let appExecutable = app.appendingPathComponent("Contents/MacOS/Forge Conductor")
        let helper = app.appendingPathComponent("Contents/Helpers/forge-conductor")
        let runtimeLauncher = app.appendingPathComponent("Contents/Helpers/forge-runtime-launcher")
        let frameworkVersion = app.appendingPathComponent(
            "Contents/Frameworks/ForgeConductorCore.framework/Versions/A",
            isDirectory: true
        )
        let frameworkBinary = frameworkVersion.appendingPathComponent("ForgeConductorCore")
        let frameworkInfo = frameworkVersion.appendingPathComponent("Resources/Info.plist")
        let frameworkSignature = frameworkVersion.appendingPathComponent("_CodeSignature/CodeResources")
        for (url, contents) in [
            (appExecutable, "app-main"),
            (helper, "cli-helper"),
            (runtimeLauncher, "runtime-launcher"),
            (frameworkBinary, "core-binary"),
            (frameworkInfo, "core-info"),
            (frameworkSignature, "core-signature"),
        ] {
            try OwnerOnlyAtomicFile.write(Data(contents.utf8), to: url)
        }
        for url in [appExecutable, helper, runtimeLauncher, frameworkBinary] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
        let installer = makeInstaller(
            runner: DesktopPluginCommandFixture(available: ["codex"])
        )
        let appRequest = DesktopProviderPluginRequest(
            host: .codexDesktop,
            forgeExecutable: appExecutable,
            includeMCP: true,
            pluginVersion: "1.2.3"
        )

        let status = try installer.install(appRequest)

        let pluginRoot = URL(fileURLWithPath: status.packagePath, isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: pluginRoot.appendingPathComponent("bin/forge-conductor")),
            Data("cli-helper".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: pluginRoot.appendingPathComponent("bin/forge-runtime-launcher")),
            Data("runtime-launcher".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: pluginRoot.appendingPathComponent(
                "Frameworks/ForgeConductorCore.framework/Versions/A/ForgeConductorCore"
            )),
            Data("core-binary".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: pluginRoot.appendingPathComponent(
                "Frameworks/ForgeConductorCore.framework/Versions/A/Resources/Info.plist"
            )),
            Data("core-info".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: pluginRoot.appendingPathComponent(
                "Frameworks/ForgeConductorCore.framework/Versions/A/_CodeSignature/CodeResources"
            )),
            Data("core-signature".utf8)
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: pluginRoot.appendingPathComponent("bin/forge-conductor").path
        ))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: pluginRoot.appendingPathComponent("bin/forge-runtime-launcher").path
        ))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: pluginRoot.appendingPathComponent(
                "Frameworks/ForgeConductorCore.framework/Versions/A/ForgeConductorCore"
            ).path
        ))
        let mcp = try json(at: pluginRoot.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["forge-conductor"]?["command"] as? String, helper.path)
    }

    func testGrokDirectPluginUsesDocumentedPackageAndEnableCommands() throws {
        let runner = DesktopPluginCommandFixture(available: ["grok"])
        let installer = makeInstaller(runner: runner)

        let status = try installer.install(request(.grokBuild, mcp: true))

        XCTAssertEqual(status.disposition, .installed)
        XCTAssertTrue(status.isReady)
        XCTAssertTrue(status.warnings.isEmpty)
        let pluginRoot = URL(fileURLWithPath: status.packagePath, isDirectory: true)
        XCTAssertEqual(pluginRoot.path, grokHome.appendingPathComponent("plugins/forge-conductor").path)
        XCTAssertEqual(
            try relativeFiles(at: pluginRoot),
            [
                ".forge-conductor-owner.json",
                ".mcp.json",
                "hooks/hooks.json",
                "plugin.json",
                "skills/forge-run/SKILL.md",
            ]
        )
        let manifest = try json(at: pluginRoot.appendingPathComponent("plugin.json"))
        XCTAssertEqual(Set(manifest.keys), ["description", "name", "version"])
        let mcp = try json(at: pluginRoot.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["forge-conductor"]?["command"] as? String, executable.path)
        XCTAssertEqual(
            servers["forge-conductor"]?["args"] as? [String],
            ["serve", "--home", forgeHome.path, "--desktop-provider", "grok-build"]
        )
        try assertHooks(
            at: pluginRoot,
            providerID: "grok-build",
            expectedEvents: [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PostToolUseFailure", "PermissionDenied", "Stop", "StopFailure",
                "Notification", "SubagentStart", "SubagentStop", "PreCompact",
                "PostCompact", "SessionEnd",
            ]
        )
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["plugin", "validate", pluginRoot.path],
            ["plugin", "enable", "forge-conductor"],
            ["plugin", "list", "--json"],
        ])
        XCTAssertFalse(runner.invocations.flatMap(\.arguments).contains("--always-approve"))
    }

    func testIdempotentReinstallPreservesReceiptAndPerformsOnlyLiveInventoryCheck() throws {
        let runner = DesktopPluginCommandFixture(available: ["codex"])
        let installer = makeInstaller(runner: runner)
        let installRequest = request(.codexDesktop, mcp: true)
        _ = try installer.install(installRequest)
        let receiptURL = forgeOwnedRoot.appendingPathComponent("receipts/codex-desktop.json")
        let firstReceipt = try Data(contentsOf: receiptURL)
        let firstCommandCount = runner.invocations.count

        let second = try installer.install(installRequest)

        XCTAssertEqual(second.disposition, .unchanged)
        XCTAssertEqual(try Data(contentsOf: receiptURL), firstReceipt)
        XCTAssertEqual(runner.invocations.count, firstCommandCount + 1)
        XCTAssertEqual(runner.invocations.last?.arguments, ["plugin", "list", "--json"])
    }

    func testAwaitingUserActionInstallRetriesActivationWithoutRewritingPackage() throws {
        let installRequest = request(.codexDesktop, mcp: true)
        let unavailableInstaller = makeInstaller(runner: DesktopPluginCommandFixture())
        let awaiting = try unavailableInstaller.install(installRequest)
        let originalInstalledAt = try XCTUnwrap(awaiting.receipt?.installedAt)
        enum UnexpectedPackageCommit: Error { case attempted }
        let availableRunner = DesktopPluginCommandFixture(available: ["codex"])
        let repairInstaller = makeInstaller(runner: availableRunner) { _ in
            throw UnexpectedPackageCommit.attempted
        }

        let repaired = try repairInstaller.install(installRequest)

        XCTAssertEqual(awaiting.disposition, .awaitingUserAction)
        XCTAssertEqual(repaired.disposition, .installed)
        XCTAssertTrue(repaired.isReady)
        XCTAssertEqual(repaired.receipt?.installedAt, originalInstalledAt)
        XCTAssertEqual(availableRunner.invocations.map(\.arguments), [
            ["plugin", "list", "--json"],
            ["plugin", "add", "forge-conductor@personal"],
            ["plugin", "list", "--json"],
        ])
    }

    func testActivationFailsWhenValidateFailsDespiteStaleEnabledInventory() throws {
        let runner = DesktopPluginCommandFixture(
            available: ["claude"],
            resultForInvocation: { invocation in
                guard invocation.arguments.starts(with: ["plugin", "validate"]) else {
                    return nil
                }
                return .init(exitCode: 1, stderr: "Plugin validation failed")
            }
        )

        let status = try makeInstaller(runner: runner).install(
            request(.claudeCodeDesktop)
        )

        XCTAssertEqual(status.disposition, .awaitingUserAction)
        XCTAssertFalse(status.deploymentVerified)
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["plugin", "validate", status.packagePath],
        ])
        XCTAssertEqual(status.receipt?.commandAttempts.first?.exitCode, 1)
    }

    func testActivationFailsWhenAddMutationFailsDespiteStaleEnabledInventory() throws {
        let runner = DesktopPluginCommandFixture(
            available: ["codex"],
            resultForInvocation: { invocation in
                guard invocation.arguments.starts(with: ["plugin", "add"]) else {
                    return nil
                }
                return .init(exitCode: 1, stderr: "Plugin installation failed")
            }
        )

        let status = try makeInstaller(runner: runner).install(request(.codexDesktop))

        XCTAssertEqual(status.disposition, .awaitingUserAction)
        XCTAssertFalse(status.deploymentVerified)
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["plugin", "add", "forge-conductor@personal"],
        ])
        XCTAssertEqual(status.receipt?.commandAttempts.first?.exitCode, 1)
    }

    func testActivationRejectsTimedOutOrTruncatedRequiredMutations() throws {
        let timedOut = DesktopPluginCommandFixture(
            available: ["grok"],
            resultForInvocation: { invocation in
                guard invocation.arguments == ["plugin", "enable", "forge-conductor"] else {
                    return nil
                }
                return .init(
                    exitCode: 0,
                    stdout: "already enabled",
                    timedOut: true
                )
            }
        )
        let timedOutStatus = try makeInstaller(runner: timedOut).install(
            request(.grokBuild)
        )
        XCTAssertEqual(timedOutStatus.disposition, .awaitingUserAction)
        XCTAssertFalse(timedOutStatus.deploymentVerified)
        XCTAssertEqual(timedOut.invocations.map(\.arguments), [
            ["plugin", "validate", timedOutStatus.packagePath],
            ["plugin", "enable", "forge-conductor"],
        ])

        let truncated = DesktopPluginCommandFixture(
            available: ["codex"],
            resultForInvocation: { invocation in
                guard invocation.arguments.starts(with: ["plugin", "add"]) else {
                    return nil
                }
                return .init(
                    exitCode: 0,
                    stdout: "plugin output",
                    stdoutTruncated: true
                )
            }
        )
        let truncatedStatus = try makeInstaller(runner: truncated).install(
            request(.codexDesktop)
        )
        XCTAssertEqual(truncatedStatus.disposition, .awaitingUserAction)
        XCTAssertFalse(truncatedStatus.deploymentVerified)
        XCTAssertEqual(truncated.invocations.map(\.arguments), [
            ["plugin", "add", "forge-conductor@personal"],
        ])
    }

    func testActivationAcceptsOnlyRecognizedIdempotentOutcomeBeforeInventory() throws {
        let runner = DesktopPluginCommandFixture(
            available: ["codex"],
            resultForInvocation: { invocation in
                guard invocation.arguments.starts(with: ["plugin", "add"]) else {
                    return nil
                }
                return .init(
                    exitCode: 1,
                    stderr: "Plugin forge-conductor@personal is already added."
                )
            }
        )

        let status = try makeInstaller(runner: runner).install(request(.codexDesktop))

        XCTAssertEqual(status.disposition, .installed)
        XCTAssertTrue(status.deploymentVerified)
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["plugin", "add", "forge-conductor@personal"],
            ["plugin", "list", "--json"],
        ])
        XCTAssertEqual(status.receipt?.commandAttempts.first?.exitCode, 1)
    }

    func testStatusAndAdapterRejectStalePackageDespiteVerifiedReceipt() async throws {
        let runner = DesktopPluginCommandFixture(available: ["codex"])
        let installer = makeInstaller(runner: runner)
        let installRequest = request(.codexDesktop, mcp: true)
        let installed = try installer.install(installRequest)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: installed.packagePath, isDirectory: true)
                .appendingPathComponent("skills/forge-run/SKILL.md")
        )

        let status = try installer.status(for: installRequest)
        let adapter = DesktopHostProviderIntegrationAdapter(
            providerID: .codexDesktop,
            host: .codexDesktop,
            installer: installer,
            forgeExecutable: executable,
            pluginVersion: "1.2.3"
        )
        let inspection = try await adapter.inspect(operationID: "stale-package-inspection")

        XCTAssertFalse(status.packageVerified)
        XCTAssertFalse(status.deploymentVerified)
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.detail.contains("run repair"))
        XCTAssertEqual(inspection.state, .requiresProvisioning)
        XCTAssertNil(inspection.receipt)
    }

    func testStatusAndAdapterFailClosedWhenLiveHostInventoryDisablesOrRemovesPlugin() async throws {
        let readyClaude = makeInstaller(runner: DesktopPluginCommandFixture(available: ["claude"]))
        let claudeRequest = request(.claudeCodeDesktop, mcp: true)
        _ = try readyClaude.install(claudeRequest)
        let disabledClaude = makeInstaller(runner: DesktopPluginCommandFixture(
            available: ["claude"],
            result: .init(
                exitCode: 0,
                stdout: """
                [{"id":"forge-conductor@forge-conductor","name":"forge-conductor","marketplaceName":"forge-conductor","version":"1.2.3","source":"forge-conductor","installed":true,"enabled":false}]
                """
            )
        ))
        let disabledClaudeStatus = try disabledClaude.status(for: claudeRequest)
        XCTAssertEqual(disabledClaudeStatus.disposition, .awaitingUserAction)
        XCTAssertFalse(disabledClaudeStatus.deploymentVerified)
        XCTAssertFalse(disabledClaudeStatus.isReady)

        let readyCodex = makeInstaller(runner: DesktopPluginCommandFixture(available: ["codex"]))
        let codexRequest = request(.codexDesktop, mcp: true)
        _ = try readyCodex.install(codexRequest)
        let disabledCodex = makeInstaller(runner: DesktopPluginCommandFixture(
            available: ["codex"],
            result: .init(
                exitCode: 0,
                stdout: """
                {"installed":[{"pluginId":"forge-conductor@personal","name":"forge-conductor","marketplaceName":"personal","installed":true,"enabled":false}],"available":[]}
                """
            )
        ))

        let disabledStatus = try disabledCodex.status(for: codexRequest)
        let disabledAdapter = DesktopHostProviderIntegrationAdapter(
            providerID: .codexDesktop,
            host: .codexDesktop,
            installer: disabledCodex,
            forgeExecutable: executable,
            pluginVersion: "1.2.3"
        )
        let disabledInspection = try await disabledAdapter.inspect(
            operationID: "disabled-live-codex"
        )

        XCTAssertEqual(disabledStatus.disposition, .awaitingUserAction)
        XCTAssertFalse(disabledStatus.deploymentVerified)
        XCTAssertFalse(disabledStatus.isReady)
        XCTAssertTrue(disabledStatus.detail.contains("installed and enabled"))
        XCTAssertEqual(disabledInspection.state, .requiresProvisioning)
        XCTAssertNil(disabledInspection.receipt)

        let readyGrok = makeInstaller(runner: DesktopPluginCommandFixture(available: ["grok"]))
        let grokRequest = request(.grokBuild, mcp: true)
        _ = try readyGrok.install(grokRequest)
        let removedGrok = makeInstaller(runner: DesktopPluginCommandFixture(
            available: ["grok"],
            result: .init(exitCode: 0, stdout: "[]")
        ))

        let removedStatus = try removedGrok.status(for: grokRequest)

        XCTAssertEqual(removedStatus.disposition, .awaitingUserAction)
        XCTAssertFalse(removedStatus.deploymentVerified)
        XCTAssertFalse(removedStatus.isReady)
    }

    func testAdapterProvisionDoesNotReportReadyWhenPackageDriftsDuringActivation() async throws {
        let expectedSkill = forgeOwnedRoot
            .appendingPathComponent("claude-marketplace", isDirectory: true)
            .appendingPathComponent(
                "plugins/forge-conductor/skills/forge-run/SKILL.md"
            )
        let runner = DesktopPluginCommandFixture(
            available: ["claude"],
            onInvocation: { invocation in
                if invocation.arguments == ["plugin", "list", "--json"] {
                    try? FileManager.default.removeItem(at: expectedSkill)
                }
            }
        )
        let installer = makeInstaller(runner: runner)
        let adapter = DesktopHostProviderIntegrationAdapter(
            providerID: .claudeDesktop,
            host: .claudeCodeDesktop,
            installer: installer,
            forgeExecutable: executable,
            pluginVersion: "1.2.3"
        )

        let result = try await adapter.provision(.init(
            operationID: "drift-during-provision",
            kind: .activate,
            existingReceipt: nil
        ))

        XCTAssertEqual(result.state, .awaitingUserAction)
        XCTAssertEqual(result.receipt?.metadata["deployment_verified"], "false")
    }

    func testCommitFailureRollsBackPriorPackageConfigurationAndReceipt() throws {
        let runner = DesktopPluginCommandFixture(available: ["codex"])
        let firstInstaller = makeInstaller(runner: runner)
        _ = try firstInstaller.install(request(.codexDesktop, mcp: true, version: "1.0.0"))
        let pluginManifest = userHome.appendingPathComponent("plugins/forge-conductor/.codex-plugin/plugin.json")
        let marketplace = userHome.appendingPathComponent(".agents/plugins/marketplace.json")
        let receipt = forgeOwnedRoot.appendingPathComponent("receipts/codex-desktop.json")
        let originalManifest = try Data(contentsOf: pluginManifest)
        let originalMarketplace = try Data(contentsOf: marketplace)
        let originalReceipt = try Data(contentsOf: receipt)
        enum Injected: Error { case failure }
        let failing = makeInstaller(runner: runner, fault: { _ in throw Injected.failure })

        XCTAssertThrowsError(
            try failing.install(self.request(.codexDesktop, mcp: false, version: "2.0.0"))
        )
        XCTAssertEqual(try Data(contentsOf: pluginManifest), originalManifest)
        XCTAssertEqual(try Data(contentsOf: marketplace), originalMarketplace)
        XCTAssertEqual(try Data(contentsOf: receipt), originalReceipt)
    }

    func testMalformedForeignConfigurationIsPreservedAndPackageIsNotCommitted() throws {
        let settings = userHome.appendingPathComponent(".claude/settings.json")
        let malformed = Data("{ this is not json".utf8)
        try OwnerOnlyAtomicFile.write(malformed, to: settings)
        let installer = makeInstaller(runner: DesktopPluginCommandFixture(available: ["claude"]))

        XCTAssertThrowsError(try installer.install(request(.claudeCodeDesktop))) { error in
            guard let installerError = error as? DesktopProviderPluginInstallerError,
                  case .malformedJSON = installerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: settings), malformed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: forgeOwnedRoot.appendingPathComponent("claude-marketplace").path
        ))
    }

    func testSymlinkedHostPluginDirectoryIsRefusedWithoutFollowingIt() throws {
        let external = root.appendingPathComponent("external", isDirectory: true)
        let grokDirectory: URL = grokHome
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: grokDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: grokDirectory.appendingPathComponent("plugins"),
            withDestinationURL: external
        )
        let installer = makeInstaller(runner: DesktopPluginCommandFixture())

        XCTAssertThrowsError(try installer.install(request(.grokBuild))) { error in
            guard let installerError = error as? DesktopProviderPluginInstallerError,
                  case .symlinkRefused = installerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testMissingHostCLILeavesHonestAwaitingUserActionStatus() throws {
        let installer = makeInstaller(runner: DesktopPluginCommandFixture())

        let status = try installer.install(request(.grokBuild, mcp: false))

        XCTAssertEqual(status.disposition, .awaitingUserAction)
        XCTAssertTrue(status.packageVerified)
        XCTAssertTrue(status.configurationVerified)
        XCTAssertFalse(status.commandLineHostAvailable)
        XCTAssertFalse(status.deploymentVerified)
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.receipt?.commandAttempts, [])
        XCTAssertTrue(status.detail.contains("Enable forge-conductor"))
    }

    func testReceiptsRemainOwnerOnlyAndBounded() throws {
        let runner = DesktopPluginCommandFixture(available: ["claude"])
        let installer = makeInstaller(runner: runner)
        let status = try installer.install(request(.claudeCodeDesktop))
        let receiptURL = forgeOwnedRoot.appendingPathComponent("receipts/claude-code-desktop.json")
        let receiptData = try Data(contentsOf: receiptURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)

        XCTAssertLessThanOrEqual(receiptData.count, 64 * 1_024)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertLessThanOrEqual(status.receipt?.files.count ?? .max, DesktopProviderPluginReceipt.maximumFiles)
        XCTAssertLessThanOrEqual(
            status.receipt?.commandAttempts.count ?? .max,
            DesktopProviderPluginReceipt.maximumCommandAttempts
        )
        XCTAssertLessThanOrEqual(status.receipt?.detail.count ?? .max, 512)
    }

    func testRemoveDeletesOnlyForgeOwnedArtifactsForEveryHost() throws {
        let settingsURL = userHome.appendingPathComponent(".claude/settings.json")
        try writeJSON([
            "extraKnownMarketplaces": [
                "company": [
                    "source": ["source": "directory", "path": "/company/plugins"],
                    "autoUpdate": true,
                ],
            ],
            "enabledPlugins": ["company-tool@company": true],
        ], to: settingsURL)
        let marketplaceURL = userHome.appendingPathComponent(".agents/plugins/marketplace.json")
        try writeJSON([
            "name": "personal",
            "plugins": [[
                "name": "foreign-tool",
                "source": ["source": "local", "path": "./plugins/foreign-tool"],
                "policy": ["installation": "AVAILABLE", "authentication": "ON_INSTALL"],
                "category": "Productivity",
            ]],
        ], to: marketplaceURL)
        let runner = DesktopPluginCommandFixture(available: ["claude", "codex", "grok"])
        let installer = makeInstaller(runner: runner)
        let requests = [
            request(.claudeCodeDesktop),
            request(.codexDesktop),
            request(.grokBuild),
        ]
        let installed = try requests.map { try installer.install($0) }

        let removed = try requests.map { try installer.remove($0) }

        XCTAssertTrue(removed.allSatisfy {
            $0.disposition == .removed && !$0.packageVerified && $0.configurationVerified
                && $0.deploymentVerified && $0.receipt == nil && $0.warnings.isEmpty
        })
        for status in installed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: status.packagePath))
        }
        let receiptsDirectory = forgeOwnedRoot.appendingPathComponent("receipts", isDirectory: true)
        let remainingReceipts = FileManager.default.fileExists(atPath: receiptsDirectory.path)
            ? try FileManager.default.contentsOfDirectory(atPath: receiptsDirectory.path)
            : []
        XCTAssertTrue(remainingReceipts.isEmpty)

        let settings = try json(at: settingsURL)
        let marketplaces = try XCTUnwrap(settings["extraKnownMarketplaces"] as? [String: Any])
        XCTAssertEqual(Set(marketplaces.keys), ["company"])
        let enabled = try XCTUnwrap(settings["enabledPlugins"] as? [String: Any])
        XCTAssertEqual(Set(enabled.keys), ["company-tool@company"])
        let catalog = try json(at: marketplaceURL)
        let plugins = try XCTUnwrap(catalog["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.map { $0["name"] as? String }, ["foreign-tool"])
        XCTAssertEqual(
            runner.invocations.suffix(9).map(\.arguments),
            [
                ["plugin", "list", "--json"],
                [
                    "plugin", "uninstall", "forge-conductor@forge-conductor",
                    "--scope", "user", "--json",
                ],
                ["plugin", "list", "--json"],
                ["plugin", "list", "--json"],
                ["plugin", "remove", "forge-conductor@personal", "--json"],
                ["plugin", "list", "--json"],
                ["plugin", "list", "--json"],
                ["plugin", "disable", "forge-conductor"],
                ["plugin", "list", "--json"],
            ]
        )

        let second = try installer.remove(request(.grokBuild))
        XCTAssertEqual(second.disposition, .removed)
        XCTAssertTrue(second.configurationVerified)
    }

    func testRemoveAwaitsVerifiedHostActionAndPreservesOwnedArtifacts() throws {
        let installRunner = DesktopPluginCommandFixture(available: ["codex"])
        let installRequest = request(.codexDesktop)
        let installer = makeInstaller(runner: installRunner)
        let installed = try installer.install(installRequest)
        let marketplaceURL = userHome.appendingPathComponent(
            ".agents/plugins/marketplace.json"
        )
        let receiptURL = forgeOwnedRoot.appendingPathComponent(
            "receipts/codex-desktop.json"
        )
        let originalMarketplace = try Data(contentsOf: marketplaceURL)
        let originalReceipt = try Data(contentsOf: receiptURL)
        let stillInstalled = DesktopPluginCommandFixture(
            available: ["codex"],
            result: .init(
                exitCode: 0,
                stdout: """
                {"installed":[{"pluginId":"forge-conductor@personal","name":"forge-conductor","marketplaceName":"personal","installed":true,"enabled":true}],"available":[]}
                """
            )
        )

        let status = try makeInstaller(runner: stillInstalled).remove(installRequest)

        XCTAssertEqual(status.disposition, .awaitingUserAction)
        XCTAssertFalse(status.deploymentVerified)
        XCTAssertTrue(status.detail.contains("No Forge-owned files were deleted"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.packagePath))
        XCTAssertEqual(try Data(contentsOf: marketplaceURL), originalMarketplace)
        XCTAssertEqual(try Data(contentsOf: receiptURL), originalReceipt)
        XCTAssertEqual(stillInstalled.invocations.map(\.arguments), [
            ["plugin", "list", "--json"],
            ["plugin", "remove", "forge-conductor@personal", "--json"],
            ["plugin", "list", "--json"],
        ])
    }

    func testRemoveWithoutCLIRequiresVerifiableHostActionAndPreservesOwnedArtifacts() throws {
        let runner = DesktopPluginCommandFixture()
        let installer = makeInstaller(runner: runner)
        let installRequest = request(.claudeCodeDesktop)
        let installed = try installer.install(installRequest)
        XCTAssertEqual(installed.disposition, .awaitingUserAction)
        XCTAssertEqual(installed.receipt?.commandAttempts, [])

        let removed = try installer.remove(installRequest)

        XCTAssertEqual(removed.disposition, .awaitingUserAction)
        XCTAssertFalse(removed.deploymentVerified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.packagePath))
        XCTAssertNotNil(removed.receipt)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testRemoveInspectsLiveHostEvenWhenInstallReceiptHasNoCLICommands() throws {
        let installRequest = request(.codexDesktop)
        let installed = try makeInstaller(runner: DesktopPluginCommandFixture()).install(installRequest)
        XCTAssertEqual(installed.disposition, .awaitingUserAction)
        XCTAssertEqual(installed.receipt?.commandAttempts, [])
        let liveRunner = DesktopPluginCommandFixture(available: ["codex"])

        let removed = try makeInstaller(runner: liveRunner).remove(installRequest)

        XCTAssertEqual(removed.disposition, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.packagePath))
        XCTAssertEqual(liveRunner.invocations.map(\.arguments), [
            ["plugin", "list", "--json"],
            ["plugin", "remove", "forge-conductor@personal", "--json"],
            ["plugin", "list", "--json"],
        ])
    }

    func testRemoveAcceptsCleanInventoryAfterNonzeroAlreadyAbsentMutation() throws {
        let installRequest = request(.codexDesktop)
        let installRunner = DesktopPluginCommandFixture(available: ["codex"])
        let installed = try makeInstaller(runner: installRunner).install(installRequest)
        let retryRunner = DesktopPluginCommandFixture(
            available: ["codex"],
            removalResult: .init(exitCode: 1),
            deactivateAfterRemovalAttempt: true
        )

        let removed = try makeInstaller(runner: retryRunner).remove(installRequest)

        XCTAssertEqual(removed.disposition, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.packagePath))
        XCTAssertEqual(retryRunner.invocations.map(\.arguments), [
            ["plugin", "list", "--json"],
            ["plugin", "remove", "forge-conductor@personal", "--json"],
            ["plugin", "list", "--json"],
        ])
    }

    func testRemoveUnregistersDisabledInstalledCodexPlugin() throws {
        let installRequest = request(.codexDesktop)
        let installed = try makeInstaller(
            runner: DesktopPluginCommandFixture(available: ["codex"])
        ).install(installRequest)
        let disabledRunner = DesktopPluginCommandFixture(
            available: ["codex"],
            initialInventoryEnabled: false
        )

        let removed = try makeInstaller(runner: disabledRunner).remove(installRequest)

        XCTAssertEqual(removed.disposition, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.packagePath))
        XCTAssertEqual(disabledRunner.invocations.map(\.arguments), [
            ["plugin", "list", "--json"],
            ["plugin", "remove", "forge-conductor@personal", "--json"],
            ["plugin", "list", "--json"],
        ])
    }

    func testCodexRemovalUsesOriginalNonPersonalMarketplaceSelector() throws {
        let marketplaceURL = userHome.appendingPathComponent(".agents/plugins/marketplace.json")
        try writeJSON([
            "name": "company-local",
            "plugins": [],
        ], to: marketplaceURL)
        let runner = DesktopPluginCommandFixture(
            available: ["codex"],
            codexMarketplace: "company-local"
        )
        let installer = makeInstaller(runner: runner)
        let installRequest = request(.codexDesktop)
        _ = try installer.install(installRequest)

        let removed = try installer.remove(installRequest)

        XCTAssertEqual(removed.disposition, .removed)
        XCTAssertTrue(runner.invocations.map(\.arguments).contains([
            "plugin", "remove", "forge-conductor@company-local", "--json",
        ]))
    }

    func testRemoveRefusesConfigOnlyRegistrationsWithoutPackageOrReceiptOwnership() throws {
        let claudeSettings = userHome.appendingPathComponent(".claude/settings.json")
        let claudeMarketplace = forgeOwnedRoot.appendingPathComponent(
            "claude-marketplace",
            isDirectory: true
        )
        try writeJSON([
            "extraKnownMarketplaces": [
                "forge-conductor": [
                    "source": ["source": "directory", "path": claudeMarketplace.path],
                    "autoUpdate": false,
                ],
            ],
            "enabledPlugins": ["forge-conductor@forge-conductor": true],
        ], to: claudeSettings)
        let codexMarketplace = userHome.appendingPathComponent(
            ".agents/plugins/marketplace.json"
        )
        try writeJSON([
            "name": "personal",
            "plugins": [[
                "name": "forge-conductor",
                "source": [
                    "source": "local",
                    "path": "./plugins/forge-conductor",
                ],
                "policy": [
                    "installation": "INSTALLED_BY_DEFAULT",
                    "authentication": "ON_INSTALL",
                ],
                "category": "Developer Tools",
            ]],
        ], to: codexMarketplace)
        let originalClaudeSettings = try Data(contentsOf: claudeSettings)
        let originalCodexMarketplace = try Data(contentsOf: codexMarketplace)
        let installer = makeInstaller(runner: DesktopPluginCommandFixture())

        XCTAssertThrowsError(try installer.remove(request(.claudeCodeDesktop))) { error in
            guard let typed = error as? DesktopProviderPluginInstallerError,
                  case .unownedConflict = typed else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try installer.remove(request(.codexDesktop))) { error in
            guard let typed = error as? DesktopProviderPluginInstallerError,
                  case .unownedConflict = typed else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: claudeSettings), originalClaudeSettings)
        XCTAssertEqual(try Data(contentsOf: codexMarketplace), originalCodexMarketplace)
    }

    func testRemoveFailureRestoresPackageConfigurationAndReceipt() throws {
        let runner = DesktopPluginCommandFixture(available: ["codex"])
        let installRequest = request(.codexDesktop)
        let installer = makeInstaller(runner: runner)
        let installed = try installer.install(installRequest)
        let marketplaceURL = userHome.appendingPathComponent(".agents/plugins/marketplace.json")
        let receiptURL = forgeOwnedRoot.appendingPathComponent("receipts/codex-desktop.json")
        let originalMarketplace = try Data(contentsOf: marketplaceURL)
        let originalReceipt = try Data(contentsOf: receiptURL)
        enum Injected: Error { case failure }
        let failing = makeInstaller(runner: runner) { point in
            if case .packageRemovedBeforeConfiguration = point { throw Injected.failure }
        }

        XCTAssertThrowsError(try failing.remove(installRequest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.packagePath))
        XCTAssertEqual(try Data(contentsOf: marketplaceURL), originalMarketplace)
        XCTAssertEqual(try Data(contentsOf: receiptURL), originalReceipt)
    }

    func testUnownedCodexPluginConflictIsRefused() throws {
        let pluginRoot = userHome.appendingPathComponent("plugins/forge-conductor", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        try OwnerOnlyAtomicFile.write(Data("foreign".utf8), to: pluginRoot.appendingPathComponent("plugin.json"))
        let installer = makeInstaller(runner: DesktopPluginCommandFixture())

        XCTAssertThrowsError(try installer.install(request(.codexDesktop))) { error in
            guard let installerError = error as? DesktopProviderPluginInstallerError,
                  case .unownedConflict = installerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: pluginRoot.appendingPathComponent("plugin.json")), Data("foreign".utf8))
    }

    private func makeInstaller(
        runner: DesktopPluginCommandFixture,
        fault: @escaping DesktopProviderPluginInstaller.CommitFaultInjector = { _ in }
    ) -> DesktopProviderPluginInstaller {
        DesktopProviderPluginInstaller(
            roots: .init(
                forgeOwnedRoot: forgeOwnedRoot,
                userHome: userHome,
                grokHome: grokHome,
                forgeHome: forgeHome
            ),
            commandRunner: runner,
            clock: { Date(timeIntervalSince1970: 1_700_000_000.125) },
            commitFaultInjector: fault
        )
    }

    private func request(
        _ host: DesktopProviderPluginHost,
        mcp: Bool = true,
        version: String = "1.2.3"
    ) -> DesktopProviderPluginRequest {
        .init(host: host, forgeExecutable: executable, includeMCP: mcp, pluginVersion: version)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try OwnerOnlyAtomicFile.write(data, to: url)
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func relativeFiles(at root: URL) throws -> Set<String> {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ))
        var result: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let path = url.resolvingSymlinksInPath().path
                XCTAssertTrue(path.hasPrefix(prefix))
                result.insert(String(path.dropFirst(prefix.count)))
            }
        }
        return result
    }

    private func assertHooks(
        at pluginRoot: URL,
        providerID: String,
        expectedEvents: Set<String>
    ) throws {
        let hookDocument = try json(at: pluginRoot.appendingPathComponent("hooks/hooks.json"))
        let hooks = try XCTUnwrap(hookDocument["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), expectedEvents)
        XCTAssertNil(hooks["Interrupt"], "Claude-compatible packs intentionally omit unsupported Interrupt")
        for event in expectedEvents {
            let matchers = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let commands = try XCTUnwrap(matchers.first?["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(commands.first?["command"] as? String)
            XCTAssertEqual(
                command,
                "'\(executable.path)' provider-hook \(providerID) \(event) --home '\(forgeHome.path)'"
            )
            XCTAssertEqual(commands.first?["type"] as? String, "command")
            XCTAssertEqual(commands.first?["timeout"] as? Int, 10)
            XCTAssertFalse(command.contains("always-approve"))
        }
    }
}
