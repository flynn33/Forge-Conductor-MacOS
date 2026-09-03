// swift-tools-version: 6.2
import PackageDescription

// The package mirrors the Xcode targets so every product can be compiled and
// tested from either toolchain. Keeping Core as a library and the app/CLI as
// thin executable modules enforces a single inward dependency direction and
// lets future connectors arrive as isolated Core modules instead of becoming
// coupled to a user-interface entry point.
let package = Package(
    name: "ForgeConductor",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ForgeFilesystemProtocol", targets: ["ForgeFilesystemProtocol"]),
        .library(name: "ForgeConductorCore", targets: ["ForgeConductorCore"]),
        .library(name: "ForgeNativeSessionHostPlugin", targets: ["ForgeNativeSessionHostPlugin"]),
        .executable(name: "forge-conductor", targets: ["ForgeConductorCLI"]),
        .executable(name: "forge-runtime-launcher", targets: ["ForgeRuntimeLauncher"]),
        .executable(name: "forge-filesystem-daemon", targets: ["ForgeFilesystemDaemon"]),
        .executable(name: "forge-conductor-app", targets: ["ForgeConductorApp"]),
    ],
    targets: [
        .target(
            name: "ForgeFilesystemProtocol",
            path: "Sources/ForgeFilesystemProtocol"
        ),
        .target(
            name: "ForgeConductorCore",
            dependencies: ["ForgeFilesystemProtocol"],
            path: "Sources/ForgeConductorCore",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "ForgeConductorCLI",
            dependencies: [
                "ForgeConductorCore",
                "ForgeNativeSessionHostPlugin",
                "ForgeRuntimeLauncher",
            ],
            path: "Sources/ForgeConductorCLI",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "ForgeRuntimeLauncher",
            path: "Sources/ForgeRuntimeLauncher"
        ),
        .executableTarget(
            name: "ForgeFilesystemDaemon",
            dependencies: ["ForgeFilesystemProtocol"],
            path: "Sources/ForgeFilesystemDaemon"
        ),
        .target(
            name: "ForgeFilesystemQualificationSupport",
            dependencies: ["ForgeFilesystemProtocol"],
            path: "Sources/ForgeFilesystemQualificationSupport"
        ),
        .executableTarget(
            name: "ForgeFilesystemQualificationHarness",
            dependencies: ["ForgeFilesystemQualificationSupport"],
            path: "Sources/ForgeFilesystemQualificationHarness"
        ),
        .executableTarget(
            name: "ForgeFilesystemAdversary",
            dependencies: ["ForgeFilesystemQualificationSupport"],
            path: "Sources/ForgeFilesystemAdversary"
        ),
        .target(
            name: "ForgeNativeSessionHostPlugin",
            dependencies: ["ForgeConductorCore"],
            path: "Sources/ForgeNativeSessionHostPlugin"
        ),
        .executableTarget(
            name: "ForgeConductorApp",
            dependencies: [
                "ForgeConductorCore",
                "ForgeNativeSessionHostPlugin",
                "ForgeRuntimeLauncher",
            ],
            path: "Sources/ForgeConductorApp",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "ForgeConductorTests",
            dependencies: [
                "ForgeFilesystemProtocol",
                "ForgeConductorCore",
                "ForgeConductorCLI",
                "ForgeConductorApp",
                "ForgeNativeSessionHostPlugin",
                "ForgeRuntimeLauncher",
            ],
            path: "Tests/ForgeConductorTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "ForgeFilesystemQualificationSupportTests",
            dependencies: ["ForgeFilesystemQualificationSupport"],
            path: "Tests/ForgeFilesystemQualificationSupportTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
