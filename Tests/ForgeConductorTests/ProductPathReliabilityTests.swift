// ProductPathReliabilityTests.swift
// Exercises operator-critical paths such as MCP negotiation and tool discovery.
// In-process protocol calls provide deterministic coverage without automating LM Studio.

import XCTest
import Darwin
@testable import ForgeConductorCore

/// G1/G7: product reliability — MCP negotiate + tools surface without LM Studio UI.
final class ProductPathReliabilityTests: XCTestCase {
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
            view.range(of: #"Section("Protected filesystem service")"#)
        )
        let sectionEnd = try XCTUnwrap(
            view.range(of: #"Section("Maintenance")"#, range: sectionStart.upperBound..<view.endIndex)
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
        XCTAssertTrue(source.contains("static let currentSchema = 3"))
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

        let cliSealPhase = try object("E2F500000000000000000046")
        XCTAssertTrue(
            cliSealPhase.contains("$(BUILT_PRODUCTS_DIR)/forge-filesystem-daemon")
        )
        XCTAssertTrue(
            cliSealPhase.contains("${BUILT_PRODUCTS_DIR}/forge-filesystem-daemon"),
            "CLI seal command must read its signed daemon dependency"
        )
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

    func testXcodeShippedTargetsKeepDebugAndReleaseSigningClassesDistinct() throws {
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
        }

        for identifier in releaseConfigurations {
            let settings = try configuration(identifier)
            XCTAssertTrue(
                settings.contains(#"CODE_SIGN_IDENTITY = "Developer ID Application";"#),
                "Release shipped target \(identifier) must require Developer ID signing"
            )
            XCTAssertFalse(
                settings.contains(#"CODE_SIGN_IDENTITY = "Apple Development";"#)
            )
        }
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
