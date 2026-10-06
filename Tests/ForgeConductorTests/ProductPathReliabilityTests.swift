// ProductPathReliabilityTests.swift
// Exercises operator-critical paths such as MCP negotiation and tool discovery.
// In-process protocol calls provide deterministic coverage without automating LM Studio.

import XCTest
import Foundation
import Darwin
import Security
import ForgeFilesystemProtocol
@testable import ForgeConductorCore

/// G1/G7: product reliability — MCP negotiate + tools surface without LM Studio UI.
final class ProductPathReliabilityTests: XCTestCase {
    func testNativeCandidateBundlesPreserveIdentityAndRejectVersionDrift() throws {
        let fixture = try nativeCandidateFixture()
        for name in ["Debug", "Release"] {
            let app = fixture.appendingPathComponent(name + "/Forge Conductor.app")
            let info = try nativeCandidateInfo(app)
            XCTAssertEqual(info["CFBundleShortVersionString"] as? String, ForgeApp.version)
            XCTAssertEqual(info["CFBundleVersion"] as? String, ForgeFilesystemProtocolConstants.productBuildVersion)
            let roles = [
                ("", ForgeFilesystemProtocolConstants.appIdentifier),
                ("Contents/Frameworks/ForgeConductorCore.framework", ForgeFilesystemProtocolConstants.coreFrameworkIdentifier),
                ("Contents/Helpers/forge-conductor", ForgeFilesystemProtocolConstants.managerIdentifier),
                ("Contents/Helpers/forge-runtime-launcher", ForgeFilesystemProtocolConstants.runtimeLauncherIdentifier),
                ("Contents/MacOS/forge-filesystem-daemon", ForgeFilesystemProtocolConstants.daemonIdentifier),
            ]
            for (relative, identifier) in roles {
                let path = relative.isEmpty ? app : app.appendingPathComponent(relative)
                let requirement = try NativeCandidateSigningPolicy.requirement(configuration: name, identifier: identifier)
                let result = try ProcessRunner(inheritEnvironment: false).run(
                    executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--all-architectures", "-R=" + requirement, path.path],
                    timeoutSec: 10, maximumOutputBytes: 64 * 1_024
                )
                XCTAssertEqual(result.exitCode, 0, "\(name)/\(relative): \(result.stderr)")
                XCTAssertFalse(result.timedOut || result.stderrTruncated || result.stdoutTruncated)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/PlugIns").path),
                           "Ordinary candidates cannot contain test bundles")
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Helpers/ForgeFilesystemAdversary").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Helpers/ForgeFilesystemQualificationHarness").path))
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let intact = try NativeArtifactVersionChecker.check(repository: repository, app: app)
            XCTAssertEqual(intact.version, ForgeApp.version)
            XCTAssertEqual(intact.build, ForgeFilesystemProtocolConstants.productBuildVersion)
            let drift = FileManager.default.temporaryDirectory.appendingPathComponent("forge-identity-drift-\(UUID().uuidString)")
                .appendingPathComponent(name + "/Forge Conductor.app")
            try FileManager.default.createDirectory(at: drift.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: drift.deletingLastPathComponent().deletingLastPathComponent()) }
            var changed = info
            changed["CFBundleVersion"] = try XCTUnwrap(info["CFBundleVersion"] as? String) + "9"
            try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0)
                .write(to: drift.appendingPathComponent("Contents/Info.plist"))
            XCTAssertThrowsError(try NativeArtifactVersionChecker.check(repository: repository, app: drift)) { error in
                XCTAssertTrue(error.localizedDescription.contains("CFBundleVersion"))
                XCTAssertTrue(error.localizedDescription.contains(drift.path), "Failure must identify the component and configuration")
            }
        }
    }

    func testNativeCandidateSigningRequirementsKeepExactRolesAndDistinctCertificateClasses() throws {
        for identifier in [
            ForgeFilesystemProtocolConstants.appIdentifier,
            ForgeFilesystemProtocolConstants.managerIdentifier,
            ForgeFilesystemProtocolConstants.daemonIdentifier,
            ForgeFilesystemProtocolConstants.runtimeLauncherIdentifier,
            ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
        ] {
            let debug = try NativeCandidateSigningPolicy.requirement(configuration: "Debug", identifier: identifier)
            let release = try NativeCandidateSigningPolicy.requirement(configuration: "Release", identifier: identifier)
            for (text, team) in [(debug, ForgeFilesystemProtocolConstants.developmentTeamIdentifier),
                                 (release, ForgeFilesystemProtocolConstants.ownerDistributionTeamIdentifier)] {
                XCTAssertTrue(text.contains("anchor apple generic"))
                XCTAssertTrue(text.contains("identifier \"\(identifier)\""))
                XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"\(team)\""))
                var parsed: SecRequirement?
                XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &parsed), errSecSuccess)
                XCTAssertNotNil(parsed, "The exact native requirement must parse")
                XCTAssertFalse(text.contains(" or "), "A configuration must not accept either certificate class")
            }
            XCTAssertTrue(debug.contains("certificate leaf[field.1.2.840.113635.100.6.1.12] exists"))
            XCTAssertFalse(debug.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
            XCTAssertTrue(release.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
            XCTAssertFalse(release.contains("certificate leaf[field.1.2.840.113635.100.6.1.12] exists"))
            XCTAssertNotEqual(debug, release)
            #if DEBUG || FORGE_DEVELOPMENT_SIGNING
            XCTAssertEqual(debug, ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: identifier, teamIdentifier: ForgeFilesystemProtocolConstants.developmentTeamIdentifier))
            #else
            XCTAssertEqual(release, ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement(
                identifier: identifier, teamIdentifier: ForgeFilesystemProtocolConstants.ownerDistributionTeamIdentifier))
            #endif
        }
    }

    func testNativeCandidateSigningRequirementsRejectUnknownConfigurationsAndRoles() throws {
        for configuration in ["DevelopmentRelease", "release", "", "Debug|Release"] {
            XCTAssertThrowsError(try NativeCandidateSigningPolicy.requirement(
                configuration: configuration, identifier: ForgeFilesystemProtocolConstants.appIdentifier))
        }
        for identifier in ["com.forge-conductor.unknown", "", "com.forge-conductor.app\" or anchor apple generic"] {
            XCTAssertThrowsError(try NativeCandidateSigningPolicy.requirement(configuration: "Debug", identifier: identifier))
            XCTAssertThrowsError(try NativeCandidateSigningPolicy.requirement(configuration: "Release", identifier: identifier))
        }
    }

    func testNativeArtifactVersionGuardDistinguishesSourcePlaceholdersFromBuiltIdentity() throws {
        let fixture = try makeNativeVersionMetadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receipt = try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)
        XCTAssertEqual(receipt.version, ForgeApp.version)
        XCTAssertEqual(receipt.build, ForgeFilesystemProtocolConstants.productBuildVersion)
        XCTAssertEqual(receipt.declarationCounts, ["MARKETING_VERSION": 2, "CURRENT_PROJECT_VERSION": 2])
        let builtInfo = fixture.app.appendingPathComponent("Contents/Info.plist")
        for (key, changedValue) in [
            ("CFBundleVersion", ForgeFilesystemProtocolConstants.productBuildVersion + "9"),
            ("CFBundleShortVersionString", "999.0.0"),
            ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)"),
        ] {
            var info = fixture.info
            info[key] = changedValue
            try writeNativeVersionPlist(info, to: builtInfo)
            XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains(key))
                XCTAssertTrue(error.localizedDescription.contains(builtInfo.path))
            }
        }
        try writeNativeVersionPlist(fixture.info, to: builtInfo)
        let sourceInfo = fixture.root.appendingPathComponent("Sources/ForgeConductorApp/Resources/Info.plist")
        try writeNativeVersionPlist(["CFBundleVersion": "wrong"], to: sourceInfo)
        XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("CFBundleVersion"))
            XCTAssertTrue(error.localizedDescription.contains(sourceInfo.path))
        }
    }

    func testNativeArtifactVersionGuardRejectsAmbiguousAuthorityAndAnyXcodeDrift() throws {
        let fixture = try makeNativeVersionMetadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift")
        let validSource = try String(contentsOf: source, encoding: .utf8)
        for malformed in [
            validSource + "\npublic static let productVersion = \"1.2.3\"\n",
            validSource + "\npublic static let productBuildVersion = \"1\"\n",
            validSource.replacingOccurrences(of: ForgeApp.version, with: "01.2.3"),
            validSource.replacingOccurrences(of: "productBuildVersion = \"\(ForgeFilesystemProtocolConstants.productBuildVersion)\"", with: "productBuildVersion = \"0\""),
        ] {
            try Data(malformed.utf8).write(to: source)
            XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil))
        }
        try Data(validSource.utf8).write(to: source)
        XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: "wrong")) { error in
            XCTAssertTrue(error.localizedDescription.contains("FORGE_BUILD_NUMBER"))
        }
        let project = fixture.root.appendingPathComponent("ForgeConductor.xcodeproj/project.pbxproj")
        let validProject = try String(contentsOf: project, encoding: .utf8)
        for (key, wrong) in [("MARKETING_VERSION", "999.0.0"), ("CURRENT_PROJECT_VERSION", "999")] {
            try Data((validProject + "\n\(key) = \(wrong);\n").utf8).write(to: project)
            XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains(key))
                XCTAssertTrue(error.localizedDescription.contains(project.path))
            }
        }
        try Data(validProject.utf8).write(to: project)
        try Data("999\n".utf8).write(to: fixture.root.appendingPathComponent("BUILD_NUMBER"))
        XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("BUILD_NUMBER"))
        }
    }

    func testNativeArtifactVersionGuardRejectsMalformedMissingAndOversizedMetadata() throws {
        let fixture = try makeNativeVersionMetadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builtInfo = fixture.app.appendingPathComponent("Contents/Info.plist")
        for malformed in [Data("not a plist".utf8), try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": ForgeFilesystemProtocolConstants.productBuildVersion], format: .xml, options: 0)] {
            try malformed.write(to: builtInfo)
            XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains(builtInfo.path))
            }
        }
        try writeNativeVersionPlist(fixture.info, to: builtInfo)
        let source = fixture.root.appendingPathComponent("Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift")
        try Data([0xff]).write(to: source)
        XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("UTF-8"))
        }
        try Data(repeating: 0x61, count: NativeArtifactVersionChecker.maximumMetadataBytes + 1).write(to: source)
        XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("4 MiB"))
        }
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try NativeArtifactVersionChecker.checkMetadata(repository: fixture.root, app: fixture.app, buildOverride: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains(source.path))
        }
    }

    func testNativeArtifactVersionGuardRequiresTheCanonicalRepositoryRoot() throws {
        let fixture = try makeNativeVersionMetadataFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertNoThrow(try NativeArtifactVersionChecker.check(repository: repository, app: fixture.app, buildOverride: nil))
        XCTAssertThrowsError(try NativeArtifactVersionChecker.check(repository: repository.appendingPathComponent("Sources"), app: fixture.app, buildOverride: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("repository root"))
        }
        XCTAssertThrowsError(try NativeArtifactVersionChecker.check(repository: fixture.root, app: fixture.app, buildOverride: nil))
    }

    private func makeNativeVersionMetadataFixture() throws -> (root: URL, app: URL, info: [String: Any]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-native-versions-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Debug/Forge Conductor.app", isDirectory: true)
        let version = ForgeApp.version
        let build = ForgeFilesystemProtocolConstants.productBuildVersion
        let metadata = [
            "Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift": "public static let productVersion = \"\(version)\"\npublic static let productBuildVersion = \"\(build)\"\n",
            "ForgeConductor.xcodeproj/project.pbxproj": "MARKETING_VERSION = \(version);\nCURRENT_PROJECT_VERSION = \(build);\nMARKETING_VERSION = \"\(version)\";\nCURRENT_PROJECT_VERSION = \"\(build)\";\n",
            "VERSION": version + "\n",
            "BUILD_NUMBER": build + "\n",
        ]
        for (relative, text) in metadata {
            let path = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }
        try writeNativeVersionPlist(["CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)"],
                                    to: root.appendingPathComponent("Sources/ForgeConductorApp/Resources/Info.plist"))
        try writeNativeVersionPlist(["CFBundleIdentifier": ForgeFilesystemProtocolConstants.managerIdentifier],
                                    to: root.appendingPathComponent("Sources/ForgeConductorCLI/Info.plist"))
        let info: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleVersion": build]
        try writeNativeVersionPlist(info, to: app.appendingPathComponent("Contents/Info.plist"))
        return (root, app, info)
    }

    private func writeNativeVersionPlist(_ info: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path)
    }

    func testNativeSameVersionPeerReportsDifferentRunningExecutable() throws {
        let fixture = try nativeCandidateFixture()
        let candidate = fixture.appendingPathComponent("Debug/Forge Conductor.app")
        let older = fixture.appendingPathComponent("Older/Forge Conductor.app")
        XCTAssertEqual(try nativeCandidateInfo(candidate)["CFBundleShortVersionString"] as? String,
                       try nativeCandidateInfo(older)["CFBundleShortVersionString"] as? String)
        let currentCore = candidate.appendingPathComponent("Contents/Frameworks/ForgeConductorCore.framework")
        let olderCore = older.appendingPathComponent("Contents/Frameworks/ForgeConductorCore.framework")
        XCTAssertNotEqual(try nativeStaticCodeHash(currentCore), try nativeStaticCodeHash(olderCore),
                          "The older fixture must actually carry different code")
        let binary = older.appendingPathComponent("Contents/Helpers/forge-conductor")
        let version = try ProcessRunner(inheritEnvironment: false).run(
            executable: binary.path, arguments: ["version"], timeoutSec: 10, maximumOutputBytes: 4_096
        )
        XCTAssertEqual(version.exitCode, 0, version.stderr)
        XCTAssertEqual(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), ForgeApp.version)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-peer-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let input = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", "--home", home.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "TMPDIR": home.path,
                               "LLVM_PROFILE_FILE": home.appendingPathComponent("peer.profraw").path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(2)
            while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { process.terminate() }
            let finalDeadline = ContinuousClock.now + .seconds(1)
            while process.isRunning && ContinuousClock.now < finalDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            let reapDeadline = ContinuousClock.now + .seconds(1)
            while process.isRunning && ContinuousClock.now < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertFalse(process.isRunning, "The owned peer process must be stopped before fixture cleanup")
        }
        var running: SecCode?
        let deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning && ContinuousClock.now < deadline {
            if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process.processIdentifier] as CFDictionary, [], &running) == errSecSuccess { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let observed = try XCTUnwrap(running, "The exact owned older process must be observable")
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(observed, [], &staticCode), errSecSuccess)
        var path: CFURL?
        XCTAssertEqual(SecCodeCopyPath(try XCTUnwrap(staticCode), [], &path), errSecSuccess)
        let executable = try XCTUnwrap(path) as URL
        XCTAssertEqual(executable.resolvingSymlinksInPath().path, binary.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(executable.resolvingSymlinksInPath().path,
                          candidate.appendingPathComponent("Contents/Helpers/forge-conductor").resolvingSymlinksInPath().path,
                          "Same version is insufficient: the running peer does not belong to the qualified candidate")
    }

    private func nativeCandidateFixture() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FORGE_NATIVE_CANDIDATE_FIXTURE"] else {
            throw XCTSkip("Native candidate qualification requires prepared signed bundles and an older same-version peer")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(root.path.hasPrefix("/"))
        return root
    }

    private func nativeCandidateInfo(_ app: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil
        ) as? [String: Any])
    }

    private func nativeStaticCodeHash(_ path: URL) throws -> Data {
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(path as CFURL, [], &code), errSecSuccess)
        let value = try XCTUnwrap(code)
        XCTAssertEqual(SecStaticCodeCheckValidity(value, SecCSFlags(rawValue: kSecCSStrictValidate), nil), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(value, SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        return try XCTUnwrap((info as? [CFString: Any])?[kSecCodeInfoUnique] as? Data)
    }

    func testRemoteSettingsCommitReplacesEveryAppModelManagerEndpointBeforeRefresh() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeConductorApp/AppModel.swift"
            ),
            encoding: .utf8
        )

        let response = try XCTUnwrap(
            source.range(of: "let settings = try await client.updateSettings(patch, apply: true)")
        )
        let modelApply = try XCTUnwrap(
            source.range(of: "self.apply(settings: settings)", range: response.upperBound..<source.endIndex)
        )
        let managerReplacement = try XCTUnwrap(
            source.range(
                of: "self.remoteManager = ManagerDashboardClient(",
                range: modelApply.upperBound..<source.endIndex
            )
        )
        let operatorReplacement = try XCTUnwrap(
            source.range(
                of: "self.operatorManagerClient.replace(",
                range: managerReplacement.upperBound..<source.endIndex
            )
        )
        let refresh = try XCTUnwrap(
            source.range(
                of: "self.refreshRemoteManagerStatus()",
                range: operatorReplacement.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(response.lowerBound, modelApply.lowerBound)
        XCTAssertLessThan(modelApply.lowerBound, managerReplacement.lowerBound)
        XCTAssertLessThan(managerReplacement.lowerBound, operatorReplacement.lowerBound)
        XCTAssertLessThan(operatorReplacement.lowerBound, refresh.lowerBound)
        let transition = source[response.lowerBound..<refresh.upperBound]
        XCTAssertTrue(transition.contains("host: settings.dashboardHost"))
        XCTAssertTrue(transition.contains("port: settings.dashboardPort"))
        XCTAssertFalse(
            transition.contains("catch") || transition.contains("transport"),
            "The app must switch only after decoding committed settings, never infer success from disconnect"
        )
    }

    func testProtectedServiceSettingsUseOperationalHealthWithoutChangingRawStatus() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeConductorApp/AppModel.swift"
            ),
            encoding: .utf8
        )
        let service = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeConductorCore/Infrastructure/SecureFilesystemService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appModel.contains("await service.operationalHealth("))
        XCTAssertTrue(appModel.contains("paths: paths"))
        XCTAssertTrue(appModel.contains("reconcile: reconcile"))
        XCTAssertTrue(appModel.contains("beginSecureFilesystemServiceOperation(operation)"))
        XCTAssertTrue(appModel.contains("private var secureFilesystemOperationTask"))
        XCTAssertTrue(
            appModel.contains("secureFilesystemServiceStatus = health.registrationStatus")
        )
        XCTAssertTrue(appModel.contains(#"case .notRegistered: "Not enabled""#))
        XCTAssertTrue(appModel.contains(#"case .notFound: "Not packaged or invalid""#))
        XCTAssertFalse(appModel.contains("Not packaged in this build"))
        XCTAssertTrue(service.contains("public func status()"))
        XCTAssertTrue(service.contains("public func presentedStatus() async"))
        XCTAssertTrue(service.contains("packageObservation == .present"))
        XCTAssertTrue(service.contains("static func registrationStatus()"))
        XCTAssertTrue(service.contains("reconcile: Bool = false"))
        XCTAssertTrue(service.contains("public func unregister() async throws"))
        XCTAssertFalse(service.contains("try registeredService.unregister()"))
        XCTAssertTrue(service.contains("intent: .enable"))
        XCTAssertTrue(service.contains("intent: .disable"))
        XCTAssertTrue(service.contains("intent: .update"))
        XCTAssertTrue(service.contains("phase: .registering"))
        XCTAssertTrue(service.contains("phase: .unregistering"))
        XCTAssertTrue(service.contains("prepareRecovery()"))
        XCTAssertTrue(service.contains("attemptID: UUID().uuidString.lowercased()"))
        XCTAssertTrue(service.contains("static let maximumAttempts = 8"))
        XCTAssertTrue(service.contains(
            "private var internallyReconciledAttemptID: String?"
        ))
        XCTAssertTrue(service.contains(
            "public struct SecureFilesystemServiceLifecycleObservationContext"
        ))
        XCTAssertTrue(service.contains(
            "public struct SecureFilesystemServiceLifecycleObservationGate"
        ))
        XCTAssertTrue(service.contains("let stateObserver = lifecycleStateObserver"))
        XCTAssertTrue(service.contains("state: .settled"))
    }

    func testProtectedServiceSettingsUseOneOperationGateForEveryConflictingControl() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appModel = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeConductorApp/AppModel.swift"
            ),
            encoding: .utf8
        )
        let view = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeConductorApp/Views/ManagerSettingsView.swift"
            ),
            encoding: .utf8
        )
        let appDelegate = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeConductorApp/ForgeConductorApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appModel.contains(
            "@Published public private(set) var secureFilesystemSettingsOperationState"
        ))
        XCTAssertTrue(appModel.contains(
            "@Published public private(set) var secureFilesystemServiceLifecycleState"
        ))
        XCTAssertFalse(appModel.contains(
            "@Published public private(set) var isUpdatingSecureFilesystemService"
        ))
        XCTAssertFalse(appModel.contains(
            "@Published public private(set) var isReconcilingSecureFilesystemRecovery"
        ))
        XCTAssertTrue(appModel.contains(
            "let operation: SecureFilesystemSettingsOperation = reconcile ? .reconcile : .refresh"
        ))
        for operation in [
            "bootstrap", "enable", "update", "disable", "lifecycleRecovery", "approval",
        ] {
            XCTAssertTrue(
                appModel.contains("beginSecureFilesystemServiceOperation(.\(operation))"),
                "\(operation) must acquire the shared operation gate"
            )
        }
        XCTAssertTrue(appModel.contains("cancelledTask?.cancel()"))
        XCTAssertTrue(appModel.contains("nextState.cancel()"))
        XCTAssertTrue(appModel.contains("cancelledOperation?.mayAwaitServiceUnregister"))
        XCTAssertTrue(appModel.contains("secureFilesystemServiceLifecycleState = .cancelled"))
        XCTAssertTrue(appModel.contains("configureLifecycleFence(paths: paths)"))
        XCTAssertTrue(appModel.contains(
            "recoverInterruptedLifecycle(\n                        lifecycleObservationContext: observationContext"
        ))
        XCTAssertTrue(appModel.contains(
            "secureFilesystemService.setLifecycleStateObserver"
        ))
        XCTAssertTrue(appModel.contains(
            "private var secureFilesystemLifecycleObservationGate"
        ))
        XCTAssertTrue(appModel.contains(
            "beginSecureFilesystemLifecycleObservation()"
        ))
        XCTAssertTrue(appModel.contains(
            "applySecureFilesystemLifecycleObservation(observation)"
        ))
        XCTAssertTrue(appModel.contains(
            "lifecycleObservationContext: observationContext"
        ))
        XCTAssertTrue(appModel.contains(
            "secureFilesystemServiceLifecycleState.recoveryActionLabel"
        ))
        XCTAssertTrue(view.contains(
            "model.secureFilesystemServiceLifecycleRecoveryActionLabel"
        ))
        XCTAssertFalse(view.contains("Retry pending stop"))
        XCTAssertFalse(view.contains("pending macOS stop"))
        XCTAssertEqual(
            appModel.components(separatedBy: "reconcile: true").count - 1,
            1,
            "only the explicit Reconcile action may request mutating debt reconciliation"
        )
        XCTAssertTrue(appModel.contains(
            "bootstrapSecureFilesystemService(paths: forgeApp.paths)"
        ))
        XCTAssertFalse(appModel.contains(
            "refreshSecureFilesystemServiceStatus(reconcile: true)\n            refreshLMStudioPluginStatus()"
        ))
        XCTAssertTrue(appModel.contains(
            "ownsSecureFilesystemServiceOperation(operation, generation: generation)"
        ))
        XCTAssertTrue(appDelegate.contains(
            "model.cancelSecureFilesystemServiceOperation()"
        ))

        let sectionStart = try XCTUnwrap(
            view.range(of: "private var filesystemContent: some View {")
        )
        let sectionEnd = try XCTUnwrap(
            view.range(of: "private var maintenanceContent: some View {", range: sectionStart.upperBound..<view.endIndex)
        )
        let section = view[sectionStart.lowerBound..<sectionEnd.lowerBound]
        let firstControl = try XCTUnwrap(section.range(of: #"Button("Enable")"#))
        for identifier in [
            "settings-filesystem-service-status",
            "settings-filesystem-service-operational-health",
            "settings-filesystem-recovery-debt",
            "settings-filesystem-operation-status",
            "settings-filesystem-lifecycle-fence-status",
        ] {
            let status = try XCTUnwrap(section.range(of: identifier))
            XCTAssertLessThan(
                status.lowerBound,
                firstControl.lowerBound,
                "read-only status \(identifier) must remain visible above gated controls"
            )
        }
        for control in ["enable", "update", "disable", "approval", "refresh", "reconcile"] {
            XCTAssertTrue(
                section.contains(
                    ".disabled(!model.secureFilesystemSettingsControlAvailability.\(control))"
                ),
                "\(control) must derive availability from the shared operation gate"
            )
        }
        XCTAssertTrue(section.contains("settings-filesystem-operation-progress"))
        XCTAssertTrue(section.contains("settings-filesystem-lifecycle-fence-warning"))
        XCTAssertTrue(section.contains("settings-filesystem-lifecycle-recovery"))
        XCTAssertTrue(section.contains("recoverSecureFilesystemServiceLifecycle()"))
        XCTAssertTrue(section.contains(
            "!model.secureFilesystemSettingsControlAvailability.lifecycleRecovery"
        ))
        XCTAssertTrue(section.contains(
            ".accessibilityLabel(model.secureFilesystemServiceOperationStatusLabel)"
        ))
    }

    func testNestedLifecycleFixtureUsesContinuouslyDrainedCappedPipes() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tests = try String(
            contentsOf: repository.appendingPathComponent(
                "Tests/ForgeConductorTests/SecureFilesystemMutationTests.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(tests.contains(
            "SecureFilesystemLifecycleBoundedPipeCapture"
        ))
        XCTAssertTrue(tests.contains("maximumBytes: 64 * 1_024"))
        XCTAssertTrue(tests.contains("read(upToCount: 8_192)"))
        XCTAssertTrue(tests.contains("stdout_truncated="))
        XCTAssertTrue(tests.contains("stderr_truncated="))
        XCTAssertFalse(tests.contains("readDataToEndOfFile()"))
    }

    func testPrivilegedDaemonUsesDistinctCaptureIdentityAndPhaseReceipts() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeFilesystemDaemon/PrivilegedLeafDeleteEngine.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            #"capturedIdentityName = "captured-identity.json""#
        ))
        XCTAssertTrue(source.contains(
            #"capturedIdentityPendingName = "captured-identity.json.pending""#
        ))
        XCTAssertTrue(source.contains(#"case .captured: "captured.json""#))
        XCTAssertFalse(source.contains(#"capturedIdentityName = "captured.json""#))
    }

    func testPrivilegedDaemonBindsPersistedDigestAndLegacyRollbackIdentity() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/ForgeFilesystemDaemon/PrivilegedLeafDeleteEngine.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("hasValidPersistedRequestShape"))
        XCTAssertTrue(source.contains("reconstructed.requestDigestSHA256 == requestDigestSHA256"))
        XCTAssertTrue(source.contains("isLegacyProtocolFourRecord"))
        XCTAssertTrue(source.contains("expectedLeafIdentity?.matches"))
        XCTAssertTrue(source.contains("restoration cannot be proven"))
        XCTAssertTrue(source.contains("static let legacyProtocolFourSchema = 2"))
        XCTAssertTrue(source.contains("static let protocolFiveDeleteSchema = 3"))
        XCTAssertTrue(source.contains("static let currentSchema = 4"))
        XCTAssertTrue(source.contains("requestProtocolVersion = request.protocolVersion"))
        XCTAssertTrue(source.contains("requestDigestCanonicalizationVersion"))
        XCTAssertTrue(source.contains("reconcileCapturedIdentityPublication"))
        XCTAssertTrue(source.contains(
            "A pending captured filesystem identity receipt is invalid"
        ))
    }

    func testXcodeRuntimeLauncherEmbedsDeclaredProductIdentity() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        for configurationID in [
            "F0A700000000000000000010",
            "F0A700000000000000000011",
        ] {
            let start = try XCTUnwrap(project.range(of: "\(configurationID) /*"))
            let end = try XCTUnwrap(
                project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
            )
            let configuration = project[start.lowerBound..<end.upperBound]
            XCTAssertTrue(
                configuration.contains("CREATE_INFOPLIST_SECTION_IN_BINARY = YES;"),
                "runtime helper must embed the declared bundle identifier"
            )
            XCTAssertTrue(
                configuration.contains(
                    #"PRODUCT_BUNDLE_IDENTIFIER = "com.forge-conductor.runtime-launcher";"#
                ),
                "runtime helper must retain its exact product identity"
            )
        }
    }

    func testXcodeUnitTargetIncludesCurrentRuntimeQualificationSources() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        for source in [
            "CLIContractTests.swift",
            "LiveLMStudioManagedAutonomyTests.swift",
            "RuntimeCancelQualificationTests.swift",
            "LMStudioContractFixtureServer.swift",
            "LMStudioContractFixtureTests.swift",
        ] {
            XCTAssertEqual(
                project.components(separatedBy: "\(source) in Sources").count - 1,
                2,
                "\(source) must have one build-file declaration and one unit-test sources-phase entry"
            )
        }
    }

    func testXcodeAppContractTestsRemainHostedAndSeparatedFromCoreLogicTests() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let mainScheme = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/xcshareddata/xcschemes/ForgeConductor.xcscheme"
            ),
            encoding: .utf8
        )
        let appTestScheme = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/xcshareddata/xcschemes/ForgeConductorAppTests.xcscheme"
            ),
            encoding: .utf8
        )

        func object(_ identifier: String) throws -> Substring {
            let start = try XCTUnwrap(project.range(of: "\n\t\t\(identifier) /*"))
            let end = try XCTUnwrap(
                project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
            )
            return project[start.lowerBound..<end.upperBound]
        }

        XCTAssertEqual(
            project.components(
                separatedBy: "OperatorProjectContractTests.swift in Sources"
            ).count - 1,
            2,
            "the app contract must have one build-file declaration and one app-test phase entry"
        )

        let appTestSources = try object("1420E9C7330D4AB38BB472BD")
        XCTAssertTrue(appTestSources.contains("OperatorProjectContractTests.swift in Sources"))
        let coreTestSources = try object("00012A1DBBFF4A2B84B0D26C")
        XCTAssertFalse(
            coreTestSources.contains("OperatorProjectContractTests.swift"),
            "app-module tests must not convert the unhosted core test bundle into an app host"
        )

        let appTestTarget = try object("DBD99DD4E877449D8703E483")
        XCTAssertTrue(appTestTarget.contains("name = ForgeConductorAppTests;"))
        XCTAssertTrue(appTestTarget.contains(
            #"productType = "com.apple.product-type.bundle.unit-test";"#
        ))
        XCTAssertTrue(appTestTarget.contains(
            "buildConfigurationList = D43C581B12424333B25FAB62"
        ))
        XCTAssertTrue(appTestTarget.contains("1420E9C7330D4AB38BB472BD /* Sources */"))
        XCTAssertTrue(appTestTarget.contains("A91A75214D50435DB3067471 /* Frameworks */"))
        XCTAssertTrue(appTestTarget.contains("72E2A331BE024299AC34EC3B"))
        XCTAssertTrue(appTestTarget.contains("9189A1D436164BEF83F8B15B"))
        XCTAssertTrue(
            try object("A91A75214D50435DB3067471")
                .contains("6F2D0652CF4E442B9F0CE2EB /* ForgeConductorCore.framework in Frameworks */")
        )
        XCTAssertTrue(
            try object("72E2A331BE024299AC34EC3B")
                .contains("target = D574F9BCA1204936B158984B")
        )
        XCTAssertTrue(
            try object("9189A1D436164BEF83F8B15B")
                .contains("target = C596F91D22BA465F8D8290A1")
        )
        XCTAssertTrue(project.contains(
            """
					DBD99DD4E877449D8703E483 = {
						ProvisioningStyle = Automatic;
						TestTargetID = D574F9BCA1204936B158984B;
					};
"""
        ))

        for configurationID in [
            "42A19CA963294173ADE17124",
            "0F1392D0CC8F4D3DB7B395A6",
        ] {
            let configuration = try object(configurationID)
            XCTAssertTrue(configuration.contains(#"BUNDLE_LOADER = "$(TEST_HOST)";"#))
            XCTAssertTrue(configuration.contains(
                #"TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Forge Conductor.app/Contents/MacOS/Forge Conductor";"#
            ))
            XCTAssertTrue(configuration.contains(#"CODE_SIGN_IDENTITY = "Apple Development";"#))
            XCTAssertTrue(configuration.contains("CODE_SIGN_STYLE = Automatic;"))
            XCTAssertTrue(configuration.contains("DEVELOPMENT_TEAM = 9AQ2C2838M;"))
            XCTAssertTrue(configuration.contains("TEST_TARGET_NAME = ForgeConductor;"))
            XCTAssertTrue(configuration.contains(
                #"SWIFT_INCLUDE_PATHS = "$(CONFIGURATION_TEMP_DIR)/ForgeConductor.build/Objects-normal/$(CURRENT_ARCH)";"#
            ))
        }

        for configurationID in [
            "89F432F3B43F4B81ADBFD41A",
            "949B044302214128BBAA3EE8",
        ] {
            let configuration = try object(configurationID)
            XCTAssertTrue(
                configuration.contains("DEFINES_MODULE = YES;"),
                "the hosted tests require the app target to publish its Swift module"
            )
        }

        for configurationID in [
            "B8CD77AA9F924CC09529D817",
            "000293C386CD4B1A99C9F861",
        ] {
            let configuration = try object(configurationID)
            XCTAssertTrue(configuration.contains("BUNDLE_LOADER = \"\";"))
            XCTAssertTrue(configuration.contains("TEST_HOST = \"\";"))
        }

        XCTAssertFalse(
            mainScheme.contains("DBD99DD4E877449D8703E483"),
            "hosted-test isolation must not alter the existing main scheme's coverage"
        )
        XCTAssertFalse(mainScheme.contains("FORGE_CONDUCTOR_HOME"))
        XCTAssertFalse(mainScheme.contains("FORGE_SKIP_PS"))
        XCTAssertTrue(mainScheme.contains("8897BF3640FD4CBEA73213FC"))
        XCTAssertTrue(mainScheme.contains("7AEAA3E3769249359E346C15"))

        XCTAssertEqual(
            appTestScheme.components(separatedBy: "DBD99DD4E877449D8703E483").count - 1,
            1,
            "the hosted app-test target must appear exactly once in its dedicated scheme"
        )
        XCTAssertEqual(
            appTestScheme.components(separatedBy: "<TestableReference").count - 1,
            1,
            "the dedicated scheme must run only the hosted app-test target"
        )
        let blueprint = try XCTUnwrap(
            appTestScheme.range(of: #"BlueprintIdentifier = "DBD99DD4E877449D8703E483""#)
        )
        let testableStart = try XCTUnwrap(
            appTestScheme.range(
                of: "<TestableReference",
                options: .backwards,
                range: appTestScheme.startIndex..<blueprint.lowerBound
            )
        )
        let testableEnd = try XCTUnwrap(
            appTestScheme.range(
                of: "</TestableReference>",
                range: blueprint.upperBound..<appTestScheme.endIndex
            )
        )
        let testable = appTestScheme[testableStart.lowerBound..<testableEnd.upperBound]
        XCTAssertTrue(testable.contains(#"parallelizable = "NO""#))
        XCTAssertTrue(appTestScheme.contains(#"shouldUseLaunchSchemeArgsEnv = "NO""#))
        XCTAssertTrue(appTestScheme.contains(#"argument = "--uitesting""#))
        XCTAssertTrue(appTestScheme.contains(#"key = "FORGE_CONDUCTOR_HOME""#))
        XCTAssertTrue(appTestScheme.contains(
            #"value = "$(TARGET_TEMP_DIR)/ForgeConductorAppTests-home""#
        ))
        XCTAssertFalse(appTestScheme.contains("FORGE_SKIP_PS"))
    }

    func testXcodeFilesystemIdentityBuildGraphRetainsSigningBeforeSealingControls() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        func object(_ identifier: String) throws -> Substring {
            let start = try XCTUnwrap(project.range(of: "\n\t\t\(identifier) /*"))
            let end = try XCTUnwrap(
                project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
            )
            return project[start.lowerBound..<end.upperBound]
        }

        for configurationID in [
            "89F432F3B43F4B81ADBFD41A", // app Debug
            "949B044302214128BBAA3EE8", // app Release
            "D82F296A8E4141ECB3B96E83", // CLI Debug
            "462BB7BBB61F4979BE23EEDD", // CLI Release
        ] {
            XCTAssertTrue(
                try object(configurationID).contains(
                    "EAGER_COMPILATION_ALLOW_SCRIPTS = NO;"
                ),
                "caller configuration \(configurationID) must wait for dependency signing"
            )
        }

        for configurationID in [
            "D82F296A8E4141ECB3B96E83", // CLI Debug
            "462BB7BBB61F4979BE23EEDD", // CLI Release
        ] {
            let configuration = try object(configurationID)
            XCTAssertTrue(
                configuration.contains(#""@executable_path/../Frameworks","#),
                "embedded CLI must resolve the app framework from Contents/Helpers"
            )
            XCTAssertTrue(
                configuration.contains(#""@executable_path","#),
                "standalone and installed CLI must resolve a sibling framework"
            )
        }

        for configurationID in [
            "E2F500000000000000000035", // protocol Debug
            "E2F500000000000000000036", // protocol Release
            "E2F500000000000000000037", // daemon Debug
            "E2F500000000000000000038", // daemon Release
        ] {
            XCTAssertTrue(
                try object(configurationID).contains("ENABLE_CODE_COVERAGE = NO;"),
                "filesystem configuration \(configurationID) must retain scheme-consistent output"
            )
        }

        let appTarget = try object("D574F9BCA1204936B158984B")
        XCTAssertTrue(
            appTarget.contains(
                "E2F500000000000000000045 /* Seal Filesystem Daemon Identity */"
            )
        )
        XCTAssertTrue(
            appTarget.contains("E2F50000000000000000004B /* Embed Manager CLI */")
        )
        XCTAssertTrue(
            appTarget.contains("E2F500000000000000000034 /* PBXTargetDependency */")
        )
        XCTAssertTrue(
            appTarget.contains("E2F50000000000000000004C /* PBXTargetDependency */")
        )
        XCTAssertTrue(
            try object("E2F500000000000000000034").contains(
                "target = E2F500000000000000000026 /* ForgeFilesystemDaemon */;"
            ),
            "app must depend directly on the daemon before sealing and embedding it"
        )
        XCTAssertTrue(
            try object("E2F50000000000000000004C").contains(
                "target = 05C234606560407787702A3C /* forge-conductor */;"
            ),
            "app must depend directly on the signed manager CLI before embedding it"
        )

        let cliTarget = try object("05C234606560407787702A3C")
        XCTAssertTrue(
            cliTarget.contains(
                "E2F500000000000000000046 /* Seal Filesystem Daemon Identity */"
            )
        )
        XCTAssertTrue(
            cliTarget.contains("E2F500000000000000000048 /* PBXTargetDependency */")
        )
        XCTAssertTrue(
            try object("E2F500000000000000000048").contains(
                "target = E2F500000000000000000026 /* ForgeFilesystemDaemon */;"
            ),
            "CLI must depend directly on the daemon before sealing its identity"
        )

        for phaseID in ["E2F500000000000000000045", "E2F500000000000000000046"] {
            let sealPhase = try object(phaseID)
            XCTAssertTrue(sealPhase.contains("$(FORGE_FILESYSTEM_DAEMON_PRODUCT)"),
                          "sandbox input must name the selected signed daemon product")
            XCTAssertTrue(sealPhase.contains("${FORGE_FILESYSTEM_DAEMON_PRODUCT}"),
                          "seal command must consume the same declared signed dependency")
        }
        for configurationID in ["63739DAB5B654C0B846F75C1", "CEFEFE9428CD4B5F869BE9F3"] {
            let configuration = try object(configurationID)
            XCTAssertTrue(configuration.contains("$(FORGE_FILESYSTEM_DAEMON_PRODUCT_$(DEPLOYMENT_LOCATION))"))
            XCTAssertTrue(configuration.contains("FORGE_FILESYSTEM_DAEMON_PRODUCT_NO = \"$(BUILT_PRODUCTS_DIR)/forge-filesystem-daemon\";"))
            XCTAssertTrue(configuration.contains("FORGE_FILESYSTEM_DAEMON_PRODUCT_YES = \"$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)/forge-filesystem-daemon\";"),
                          "Archive must seal the direct product without following a build-products alias")
        }
        let cliSealPhase = try object("E2F500000000000000000046")
        XCTAssertFalse(
            cliSealPhase.contains(
                "$(BUILT_PRODUCTS_DIR)/Forge Conductor.app/Contents/MacOS/"
                    + "forge-filesystem-daemon"
            ),
            "CLI seal must not introduce an app dependency cycle"
        )

        let embedManagerCLI = try object("E2F50000000000000000004B")
        XCTAssertTrue(embedManagerCLI.contains("dstPath = Contents/Helpers;"))
        XCTAssertTrue(
            embedManagerCLI.contains(
                "E2F500000000000000000049 /* forge-conductor in Embed Manager CLI */"
            )
        )
        let embeddedCLIBuildFile = try XCTUnwrap(
            project.split(separator: "\n").first(where: {
                $0.contains(
                    "E2F500000000000000000049 /* forge-conductor in Embed Manager CLI */"
                )
            })
        )
        XCTAssertTrue(
            embeddedCLIBuildFile.contains(
                "fileRef = FAD7DC3FA3A1480E9B4955B1 /* forge-conductor */;"
            )
        )
        XCTAssertTrue(
            embeddedCLIBuildFile.contains("ATTRIBUTES = (CodeSignOnCopy, );"),
            "embedded manager CLI must be re-signed as nested app code"
        )
    }

    func testFilesystemIdentitySealUsesSandboxWritableAtomicStaging() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent(
                "script/seal_filesystem_daemon_identity.sh"
            ),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            script.contains(#"temporary_directory=${TEMP_DIR:-$sealed_directory}"#),
            "Xcode user-script sandboxing only grants temporary writes beneath TEMP_DIR"
        )
        XCTAssertTrue(
            script.contains(
                #""${temporary_directory}/$(/usr/bin/basename "$sealed_plist").XXXXXX""#
            ),
            "the identity seal must not create an undeclared sibling of the final plist"
        )
        XCTAssertTrue(
            script.contains(#"sealed_device=$(/usr/bin/stat -f '%d' "$sealed_directory")"#)
        )
        XCTAssertTrue(
            script.contains(#"temporary_device=$(/usr/bin/stat -f '%d' "$temporary_directory")"#)
        )
        XCTAssertTrue(
            script.contains(#"if [[ "$sealed_device" != "$temporary_device" ]]"#),
            "the final move must fail closed rather than degrade to a cross-filesystem copy"
        )
        XCTAssertTrue(
            script.contains(#"/bin/mv -f "$temporary_plist" "$sealed_plist""#),
            "the fully validated plist must replace the declared output atomically"
        )
        XCTAssertFalse(
            script.contains(#"temporary_plist="${sealed_plist}.tmp.$$""#),
            "an undeclared DerivedSources sibling is denied by Xcode's script sandbox"
        )
        XCTAssertTrue(project.contains("ENABLE_USER_SCRIPT_SANDBOXING = YES;"))
        XCTAssertFalse(
            project.contains("ENABLE_USER_SCRIPT_SANDBOXING = NO;"),
            "the identity seal fix must not weaken Xcode user-script sandboxing"
        )
    }

    func testXcodeShippedTargetsSeparateDevelopmentAndDistributionSigningPolicies() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )

        func configuration(_ identifier: String) throws -> Substring {
            let start = try XCTUnwrap(project.range(of: "\n\t\t\(identifier) /*"))
            let end = try XCTUnwrap(
                project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
            )
            return project[start.lowerBound..<end.upperBound]
        }

        let debugConfigurations = [
            "89F432F3B43F4B81ADBFD41A", // app
            "D82F296A8E4141ECB3B96E83", // manager CLI
            "E27D3E6391AA4ECF80942FF0", // core framework
            "F0A700000000000000000010", // runtime launcher
            "E2F500000000000000000037", // filesystem daemon
        ]
        let releaseConfigurations = [
            "949B044302214128BBAA3EE8", // app
            "462BB7BBB61F4979BE23EEDD", // manager CLI
            "A3DBA24BE10849FEB69442E8", // core framework
            "F0A700000000000000000011", // runtime launcher
            "E2F500000000000000000038", // filesystem daemon
        ]

        for identifier in debugConfigurations {
            let settings = try configuration(identifier)
            XCTAssertTrue(
                settings.contains(#"CODE_SIGN_IDENTITY = "Apple Development";"#),
                "Debug shipped target \(identifier) must use development signing"
            )
            XCTAssertFalse(
                settings.contains(#"CODE_SIGN_IDENTITY = "Developer ID Application";"#)
            )
            XCTAssertTrue(settings.contains("CODE_SIGN_STYLE = Automatic;"))
            XCTAssertTrue(settings.contains("DEVELOPMENT_TEAM = 9AQ2C2838M;"))
        }

        let debugManagerSettings = try configuration("D82F296A8E4141ECB3B96E83")
        XCTAssertTrue(
            debugManagerSettings.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES;"),
            "Debug manager CLI must permit owner-authorized native LLDB debugging"
        )
        XCTAssertTrue(debugManagerSettings.contains("ENABLE_HARDENED_RUNTIME = YES;"),
                      "Debugging must retain the manager CLI hardened runtime")

        for identifier in releaseConfigurations {
            let settings = try configuration(identifier)
            XCTAssertTrue(
                settings.contains(#"CODE_SIGN_IDENTITY = "Developer ID Application";"#),
                "Distribution target \(identifier) must be signed before daemon hashes are sealed"
            )
            XCTAssertTrue(
                settings.contains("DEVELOPMENT_TEAM = 9AQ2C2838M;"),
                "Release shipped target \(identifier) must use James Daley's team"
            )
            XCTAssertTrue(
                settings.contains("CODE_SIGN_STYLE = Manual;"),
                "Distribution target \(identifier) must retain its exact Developer ID identity"
            )
            XCTAssertFalse(
                settings.contains(#"CODE_SIGN_IDENTITY = "Apple Development";"#)
            )
            XCTAssertFalse(
                settings.contains("CODE_SIGN_IDENTITY[sdk=macosx*]"),
                "SDK-specific signing must not override the Release identity"
            )
            XCTAssertTrue(
                settings.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;"),
                "Release shipped target \(identifier) must not inherit development-only entitlements"
            )
            XCTAssertFalse(
                settings.contains("ENABLE_TESTABILITY = YES;"),
                "Release shipped target \(identifier) must not export testable internals"
            )
        }
        let releaseProjectSettings = try configuration("CEFEFE9428CD4B5F869BE9F3")
        XCTAssertFalse(releaseProjectSettings.contains("FORGE_DEVELOPMENT_SIGNING"),
                       "Developer ID export changes signatures, not compiled peer policy")
        XCTAssertFalse(releaseProjectSettings.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS"),
                       "Release must inherit the distribution policy without development conditions")
        let debugProjectSettings = try configuration("63739DAB5B654C0B846F75C1")
        XCTAssertTrue(debugProjectSettings.contains(
            #"SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";"#
        ), "Ordinary Debug execution must retain its matching Apple Development peer policy")
        XCTAssertFalse(
            project.contains(#"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";"#),
            "An SDK-specific ad hoc override must not replace team signing"
        )
    }

    func testXcodeReleaseArchiveKeepsManagerCLIEmbeddedWithoutInstallingItSeparately() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent(
                "ForgeConductor.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(project.range(of: "\n\t\t462BB7BBB61F4979BE23EEDD /* Release */"))
        let end = try XCTUnwrap(
            project.range(of: "\n\t\t};", range: start.lowerBound..<project.endIndex)
        )
        let cliRelease = project[start.lowerBound..<end.upperBound]
        XCTAssertTrue(cliRelease.contains("SKIP_INSTALL = YES;"))
        XCTAssertTrue(project.contains("/* forge-conductor in Embed Manager CLI */"))
        XCTAssertTrue(project.contains("dstPath = Contents/Helpers;"))
    }

    func testPrivilegedFilesystemBundleCheckerRetainsExactOptionalCLISealContract() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checker = try String(
            contentsOf: repository.appendingPathComponent(
                ".forge-codex/scripts/check_privileged_filesystem_bundle.sh"
            ),
            encoding: .utf8
        )

        for requiredFragment in [
            #"[Debug|DevelopmentRelease|Release]"#,
            #"Debug|DevelopmentRelease)"#,
            #"CLI_EXECUTABLE="${3:-}""#,
            #"APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Forge Conductor""#,
            #"EMBEDDED_CLI="$APP_BUNDLE/Contents/Helpers/forge-conductor""#,
            #"RUNTIME_LAUNCHER="$APP_BUNDLE/Contents/Helpers/forge-runtime-launcher""#,
            #"CORE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/ForgeConductorCore.framework""#,
            #"identifier \"com.forge-conductor.cli\""#,
            #"identifier \"com.forge-conductor.runtime-launcher\""#,
            #"identifier \"com.forge-conductor.core\""#,
            #"certificate leaf[subject.OU] = \"$TEAM_IDENTIFIER\""#,
            #"--strict --all-architectures"#,
            #"[[ -f "$executable" ]]"#,
            #"[[ ! -L "$executable" ]]"#,
            #"[[ -x "$executable" ]]"#,
            #"[[ -f "$APP_EXECUTABLE" ]]"#,
            #"[[ ! -L "$APP_EXECUTABLE" ]]"#,
            #"[[ -x "$APP_EXECUTABLE" ]]"#,
            #"supported_architectures "app main executable" "$APP_EXECUTABLE""#,
            #"--deep --strict --all-architectures"#,
            #""-R=$APP_REQUIREMENT" "$APP_BUNDLE""#,
            #""-R=$RUNTIME_LAUNCHER_REQUIREMENT" "$RUNTIME_LAUNCHER""#,
            #""-R=$CORE_FRAMEWORK_REQUIREMENT" "$CORE_FRAMEWORK""#,
            #"supported_architectures "$role" "$executable""#,
            #"supported_architectures "embedded filesystem daemon" "$DAEMON""#,
            #"supported_architectures "runtime launcher" "$RUNTIME_LAUNCHER""#,
            #"require_cli_runpaths "$role" "$executable""#,
            #"/usr/bin/otool -l "$executable""#,
            #""@executable_path/../Frameworks""#,
            #""@executable_path""#,
            #"/usr/bin/plutil -p "$APP_INFO_PLIST""#,
            #"/usr/bin/plutil -p "$executable""#,
            #"CFBundleShortVersionString"#,
            #"/usr/bin/env -i PATH=/usr/bin:/bin"#,
            #""$executable" version"#,
            #""standalone manager CLI" "$CLI_EXECUTABLE""#,
            #""embedded manager CLI" "$EMBEDDED_CLI""#,
            #"--arch "$architecture" "$DAEMON""#,
            #"ForgeFilesystemDaemonCDHashArm64"#,
            #"ForgeFilesystemDaemonCDHashX86_64"#,
            #"reject_unknown_daemon_seal_keys"#,
            #"require_matching_daemon_seal"#,
            #"require_absent_daemon_seal"#,
            #"[[ "$actual_hash" == "$expected_hash" ]]"#,
        ] {
            XCTAssertTrue(
                checker.contains(requiredFragment),
                "bundle checker is missing the exact-pair contract: \(requiredFragment)"
            )
        }

        XCTAssertTrue(
            checker.contains(
                "/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \\\n"
                    + "  \"-R=$APP_REQUIREMENT\" \"$APP_BUNDLE\""
            ),
            "app explicit-requirement verification must cover every architecture"
        )
        XCTAssertTrue(
            checker.contains(
                "/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \\\n"
                    + "  \"-R=$RUNTIME_LAUNCHER_REQUIREMENT\" \"$RUNTIME_LAUNCHER\""
            ),
            "runtime launcher explicit-requirement verification must cover every architecture"
        )
        XCTAssertTrue(
            checker.contains(
                "/usr/bin/codesign --verify --strict --all-architectures --verbose=4 \\\n"
                    + "  \"-R=$CORE_FRAMEWORK_REQUIREMENT\" \"$CORE_FRAMEWORK\""
            ),
            "core framework explicit-requirement verification must cover every architecture"
        )

        let cliSignatureCheck = try XCTUnwrap(
            checker.range(of: #""-R=$CLI_REQUIREMENT" "$executable""#)
        )
        let cliInfoInspection = try XCTUnwrap(
            checker.range(of: #"/usr/bin/plutil -p "$executable""#)
        )
        XCTAssertLessThan(
            cliSignatureCheck.lowerBound,
            cliInfoInspection.lowerBound,
            "CLI signature and exact identity must be accepted before trusting its embedded plist"
        )

        let embeddedCLIValidation = try XCTUnwrap(
            checker.range(of: #""embedded manager CLI" "$EMBEDDED_CLI""#)
        )
        let optionalStandaloneCLIValidation = try XCTUnwrap(
            checker.range(of: #"[[ -n "$CLI_EXECUTABLE" ]]"#)
        )
        XCTAssertLessThan(
            embeddedCLIValidation.lowerBound,
            optionalStandaloneCLIValidation.lowerBound,
            "the app-embedded manager CLI must be validated even without an external CLI argument"
        )
    }

    func testProjectBuildEntrypointStagesRuntimeLauncherBeforeBundleSigning() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entrypoint = try String(
            contentsOf: repository.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )

        let requiredFragments = [
            #"CLI_PRODUCT="forge-conductor""#,
            #"RUNTIME_HELPER_PRODUCT="forge-runtime-launcher""#,
            #"DEVELOPMENT_SIGNING="${FORGE_DEVELOPMENT_SIGNING:-0}""#,
            #"APP_HELPERS="$APP_CONTENTS/Helpers""#,
            #"CLI_EXECUTABLE="$APP_HELPERS/$CLI_PRODUCT""#,
            #"RUNTIME_HELPER="$APP_HELPERS/$RUNTIME_HELPER_PRODUCT""#,
            #"SWIFT_BUILD_ARGUMENTS=(--configuration "$BINARY_CONFIGURATION")"#,
            #"SWIFT_BUILD_ARGUMENTS+=(-Xswiftc -DFORGE_DEVELOPMENT_SIGNING)"#,
            #"swift build "${SWIFT_BUILD_ARGUMENTS[@]}" --product "$CLI_PRODUCT""#,
            #"swift build "${SWIFT_BUILD_ARGUMENTS[@]}" --product "$RUNTIME_HELPER_PRODUCT""#,
            #"cp "$BUILD_CLI_EXECUTABLE" "$CLI_EXECUTABLE""#,
            #"cp "$BUILD_RUNTIME_HELPER" "$RUNTIME_HELPER""#,
            #"chmod 0755 "$APP_BINARY" "$CLI_EXECUTABLE" "$RUNTIME_HELPER""#,
            #"/usr/bin/codesign --verify --strict --all-architectures --verbose=4 "$CLI_EXECUTABLE""#,
            #"/usr/bin/codesign --verify --strict --all-architectures --verbose=4 "$RUNTIME_HELPER""#,
            #"/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=4 "$APP_BUNDLE""#,
            #"EXPECTED_TEAM_IDENTIFIER="9AQ2C2838M""#,
            #"certificate leaf[field.1.2.840.113635.100.6.1.12] exists"#,
        ]
        for fragment in requiredFragments {
            XCTAssertTrue(entrypoint.contains(fragment), "missing build-entrypoint contract: \(fragment)")
        }
        XCTAssertFalse(
            entrypoint.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
            "Developer ID packaging belongs to the canonical Xcode archive/export path"
        )

        let cliSigning = try XCTUnwrap(
            entrypoint.range(of: #"--identifier "$CLI_IDENTIFIER""#)
        )
        let helperSigning = try XCTUnwrap(
            entrypoint.range(of: #"--identifier "$RUNTIME_HELPER_IDENTIFIER""#)
        )
        let bundleSigning = try XCTUnwrap(
            entrypoint.range(of: #"--identifier "$BUNDLE_ID""#)
        )
        let strictVerification = try XCTUnwrap(
            entrypoint.range(
                of: #"/usr/bin/codesign --verify --deep --strict --all-architectures"#
            )
        )
        XCTAssertLessThan(cliSigning.lowerBound, helperSigning.lowerBound)
        XCTAssertLessThan(helperSigning.lowerBound, bundleSigning.lowerBound)
        XCTAssertLessThan(bundleSigning.lowerBound, strictVerification.lowerBound)
    }

    func testInProcessMCPHandshakeToolsList() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-product-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let app = try ForgeApp.bootstrap(home: tmp)
        defer { app.shutdown() }
        let server = MCPServer(app: app)

        let initMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "product-test", "version": "1"] as [String: Any],
            ] as [String: Any],
        ]
        let initResp = server.handle(initMsg)
        XCTAssertNotNil(initResp)
        let result = initResp?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-11-25")
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "forge-conductor")

        let listMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:] as [String: Any],
        ]
        let listResp = server.handle(listMsg)
        let listResult = listResp?["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(tools.count, 20, "product must expose full tool surface")
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("forge_status"))
        XCTAssertTrue(names.contains("get_forge_status"))
        XCTAssertTrue(names.contains("agent_list"))
        XCTAssertTrue(names.contains("shell_exec"))
        XCTAssertTrue(MCPServeVerifier.requiredProductTools.isSubset(of: names))
    }

    func testForgeStatusToolCall() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let app = try ForgeApp.bootstrap(home: tmp)
        defer { app.shutdown() }
        let server = MCPServer(app: app)
        let call: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "forge_status",
                "arguments": [:] as [String: Any],
            ] as [String: Any],
        ]
        let resp = server.handle(call)
        let result = resp?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        let isError = result?["isError"] as? Bool ?? true
        XCTAssertFalse(isError)
    }

    func testRealtimeEngineMeasuredProgress() {
        let engine = RealtimeMetricsEngine()
        engine.start(targetHz: 30)
        defer { engine.stop() }
        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertGreaterThan(engine.latestSystem.ts, 0)
        // After ~0.35s at 30Hz should have samples; measured Hz may still be settling.
        XCTAssertTrue(engine.isRunning)
    }

    func testPortGuardReportsFreeOnUnusedPort() {
        // Ephemeral high port almost certainly free
        let state = DashboardPortGuard.inspect(host: "127.0.0.1", port: 59_873)
        switch state {
        case .free, .unknown:
            break // unknown acceptable if lsof missing
        default:
            XCTFail("expected free/unknown for unused port, got \(state)")
        }
    }

    func testDiagnosticsCaptureDeploySmokeFailurePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diag-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(home: tmp)
        try paths.ensureLayout()
        let log = DiagnosticLog(paths: paths)
        let deploy = LMStudioDeployService(paths: paths, diagnostics: log)
        // Prefer a missing binary via explicit preferred that doesn't exist — resolve with bogus path
        do {
            _ = try deploy.deploy(
                preferredBinary: URL(fileURLWithPath: "/tmp/definitely-not-forge-\(UUID().uuidString)")
            )
            XCTFail("expected deploy to fail for missing binary")
        } catch {
            // expected
        }
        let recent = log.recent(limit: 50)
        let events = Set(recent.map(\.event))
        XCTAssertTrue(events.contains("deploy_begin") || events.contains("deploy_binary_missing") || events.contains("deploy_smoke_pre_failed") || events.contains("deploy_failed") || !recent.isEmpty)
    }

    func testProcessVerifierRejectsMissingContinuityTool() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools.subtracting(["context_get"]))
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("context_get"), result.detail)
    }

    func testProcessVerifierRejectsMissingMemoryTool() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools.subtracting(["memory_search"]))
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("memory_search"), result.detail)
    }

    func testProcessVerifierRejectsNonNDJSONPrefix() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            prefix: "Content-Length: 10\n"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 1
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("ndjson=false"), result.detail)
    }

    func testProcessVerifierTimeoutIsBoundedForSilentChild() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let binary = tmp.appendingPathComponent("silent-server")
        try Data("#!/bin/sh\ncat >/dev/null\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let started = Date()
        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testProcessVerifierRejectsValidHandshakeWithNonzeroNaturalExit() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            postOutputScript: "exit 9"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.terminationInterventionRequired)
        XCTAssertEqual(result.terminationReason, "exit")
        XCTAssertEqual(result.terminationStatus, 9)
    }

    func testProcessVerifierRejectsValidHandshakeWhenCleanupIntervenes() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            postOutputScript: "exec /bin/sleep 30"
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.terminationInterventionRequired)
        XCTAssertEqual(result.terminationReason, "uncaught_signal")
        XCTAssertEqual(result.terminationStatus, SIGTERM)
        XCTAssertTrue(result.detail.contains("intervention=true"), result.detail)
    }

    func testProcessVerifierRejectsHandshakeEmittedOnlyAfterEOF() throws {
        let tmp = try makeVerifierTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var names = Array(MCPServeVerifier.requiredProductTools)
        while names.count < MCPServeVerifier.minimumToolCount {
            names.append("fixture_tool_\(names.count)")
        }
        let binary = try makeVerifierExecutable(
            in: tmp,
            serverName: "forge-conductor",
            toolNames: names,
            deferOutputUntilEOF: true
        )

        let result = try MCPServeVerifier.verify(
            binary: binary,
            home: tmp.appendingPathComponent("home", isDirectory: true),
            timeoutSec: 0.2
        )
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.terminationInterventionRequired)
        XCTAssertEqual(result.terminationReason, "exit")
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.detail.contains("handshake_before_eof=false"), result.detail)
    }

    private func makeVerifierTemp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeVerifierExecutable(
        in directory: URL,
        serverName: String,
        toolNames: [String],
        prefix: String = "",
        postOutputScript: String = "",
        deferOutputUntilEOF: Bool = false
    ) throws -> URL {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "protocolVersion": "2025-11-25",
                "serverInfo": ["name": serverName, "version": ForgeApp.version],
            ] as [String: Any],
        ]
        let descriptors: [[String: Any]] = toolNames.map { name in
            [
                "name": name,
                "description": "Fixture tool \(name)",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ]
        }
        let tools: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["tools": descriptors],
        ]
        let output = prefix
            + (try JSONSupport.string(from: initialize)) + "\n"
            + (try JSONSupport.string(from: tools)) + "\n"
        let shellQuoted = output.replacingOccurrences(of: "'", with: "'\"'\"'")
        let responseScript = "printf '%s' '\(shellQuoted)'"
        let script = deferOutputUntilEOF
            ? "#!/bin/sh\ncat >/dev/null\n\(responseScript)\n\(postOutputScript)\n"
            : "#!/bin/sh\n\(responseScript)\ncat >/dev/null\n\(postOutputScript)\n"
        let binary = directory.appendingPathComponent("fixture-server")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }
}

private enum NativeCandidateSigningPolicy {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static func requirement(configuration: String, identifier: String) throws -> String {
        let knownRoles: Set<String> = [
            ForgeFilesystemProtocolConstants.appIdentifier,
            ForgeFilesystemProtocolConstants.managerIdentifier,
            ForgeFilesystemProtocolConstants.daemonIdentifier,
            ForgeFilesystemProtocolConstants.runtimeLauncherIdentifier,
            ForgeFilesystemProtocolConstants.coreFrameworkIdentifier,
        ]
        guard knownRoles.contains(identifier) else {
            throw Failure(detail: "Unknown native candidate product role: \(identifier)")
        }
        let team: String
        let certificate: String
        switch configuration {
        case "Debug":
            team = ForgeFilesystemProtocolConstants.developmentTeamIdentifier
            certificate = "certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        case "Release":
            team = ForgeFilesystemProtocolConstants.ownerDistributionTeamIdentifier
            certificate = "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        default:
            throw Failure(detail: "Unknown canonical native candidate configuration: \(configuration)")
        }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\" and \(certificate)"
    }
}

private enum NativeArtifactVersionChecker {
    static let maximumMetadataBytes = 4 * 1_024 * 1_024

    struct Receipt {
        let version: String
        let build: String
        let declarationCounts: [String: Int]
    }

    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static func check(
        repository: URL, app: URL,
        buildOverride: String? = ProcessInfo.processInfo.environment["FORGE_BUILD_NUMBER"]
    ) throws -> Receipt {
        let root = repository.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Failure(detail: "\(root.path): repository directory does not exist")
        }
        let result = try ProcessRunner(inheritEnvironment: false).run(
            executable: "/usr/bin/git", arguments: ["rev-parse", "--show-toplevel"], currentDirectory: root.path,
            timeoutSec: 2, maximumOutputBytes: 4_096
        )
        guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated else {
            throw Failure(detail: "\(root.path): bounded repository root discovery failed (exit \(result.exitCode))")
        }
        let discovered = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !discovered.isEmpty,
              URL(fileURLWithPath: discovered).standardizedFileURL.resolvingSymlinksInPath() == root else {
            throw Failure(detail: "\(root.path): pass the repository root, not a nested directory")
        }
        return try checkMetadata(repository: root, app: app, buildOverride: buildOverride)
    }

    // Parser fixtures exercise the same metadata checks without creating another Git repository.
    static func checkMetadata(repository: URL, app: URL, buildOverride: String?) throws -> Receipt {
        let source = repository.appendingPathComponent("Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift")
        let text = try readText(source)
        let versions = try captures(#"public\s+static\s+let\s+productVersion\s*=\s*"([^"\n]+)""#, in: text)
        let builds = try captures(#"public\s+static\s+let\s+productBuildVersion\s*=\s*"([^"\n]+)""#, in: text)
        guard versions.count == 1, builds.count == 1 else {
            throw Failure(detail: "\(source.path): expected exactly one canonical product version and build constant")
        }
        let version = versions[0]
        let build = builds[0]
        guard try matches(#"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, version) else {
            throw Failure(detail: "\(source.path): marketing version must be an unambiguous numeric MAJOR.MINOR.PATCH")
        }
        guard try matches(#"^[1-9][0-9]*$"#, build) else {
            throw Failure(detail: "\(source.path): build must be a positive integer")
        }
        guard version == ForgeApp.version, build == ForgeFilesystemProtocolConstants.productBuildVersion else {
            throw Failure(detail: "\(source.path): canonical identity differs from the compiled test product")
        }
        if let buildOverride, buildOverride != build {
            throw Failure(detail: "FORGE_BUILD_NUMBER disagrees with canonical build \(build)")
        }
        for (relative, expected) in [("VERSION", version), ("BUILD_NUMBER", build)] {
            let path = repository.appendingPathComponent(relative)
            guard try readText(path).trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
                throw Failure(detail: "\(path.path): identity differs from canonical \(expected)")
            }
        }
        let project = repository.appendingPathComponent("ForgeConductor.xcodeproj/project.pbxproj")
        let projectText = try readText(project)
        var counts: [String: Int] = [:]
        for (key, expected) in [("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)] {
            let values = try captures("\\b" + key + #"\s*=\s*([^;\n]+);"#, in: projectText)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard values.count >= 2 else {
                throw Failure(detail: "\(project.path): expected Debug/Release literal declarations for \(key)")
            }
            guard values.allSatisfy({ $0 == expected }) else {
                throw Failure(detail: "\(project.path): \(key) differs from canonical \(expected)")
            }
            counts[key] = values.count
        }
        for relative in ["Sources/ForgeConductorApp/Resources/Info.plist", "Sources/ForgeConductorCLI/Info.plist"] {
            let path = repository.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: path.path) {
                try checkPlist(path, version: version, build: build, source: true)
            }
        }
        try checkPlist(app.standardizedFileURL.appendingPathComponent("Contents/Info.plist"), version: version, build: build, source: false)
        return Receipt(version: version, build: build, declarationCounts: counts)
    }

    private static func checkPlist(_ path: URL, version: String, build: String, source: Bool) throws {
        let data = try readData(path)
        let info: [String: Any]
        do {
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw Failure(detail: "\(path.path): Info.plist must contain a dictionary")
            }
            info = dictionary
        } catch {
            throw Failure(detail: "\(path.path): invalid Info.plist (\(error.localizedDescription))")
        }
        for (key, expected, placeholder) in [
            ("CFBundleShortVersionString", version, "$(MARKETING_VERSION)"),
            ("CFBundleVersion", build, "$(CURRENT_PROJECT_VERSION)"),
        ] {
            if source && info[key] == nil { continue }
            guard let value = info[key] as? String,
                  value == expected || (source && value == placeholder) else {
                throw Failure(detail: "\(path.path): \(key) does not match canonical identity \(expected)")
            }
        }
    }

    private static func readText(_ path: URL) throws -> String {
        guard let value = String(data: try readData(path), encoding: .utf8) else {
            throw Failure(detail: "\(path.path): metadata must be UTF-8")
        }
        return value
    }

    private static func readData(_ path: URL) throws -> Data {
        guard (try? path.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw Failure(detail: "\(path.path): missing required metadata file")
        }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumMetadataBytes {
            let remaining = maximumMetadataBytes + 1 - data.count
            guard let next = try handle.read(upToCount: min(64 * 1_024, remaining)), !next.isEmpty else { return data }
            data.append(next)
        }
        throw Failure(detail: "\(path.path): metadata exceeds 4 MiB")
    }

    private static func captures(_ pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func matches(_ pattern: String, _ value: String) throws -> Bool {
        let expression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: fullRange)?.range == fullRange
    }
}
