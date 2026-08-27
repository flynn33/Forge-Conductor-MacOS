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
        .library(name: "ForgeConductorCore", targets: ["ForgeConductorCore"]),
        .library(name: "ForgeNativeSessionHostPlugin", targets: ["ForgeNativeSessionHostPlugin"]),
        .executable(name: "forge-conductor", targets: ["ForgeConductorCLI"]),
        .executable(name: "forge-runtime-launcher", targets: ["ForgeRuntimeLauncher"]),
        .executable(name: "forge-conductor-app", targets: ["ForgeConductorApp"]),
    ],
    targets: [
        .target(
            name: "ForgeConductorCore",
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
            path: "Sources/ForgeConductorCLI"
        ),
        .executableTarget(
            name: "ForgeRuntimeLauncher",
            path: "Sources/ForgeRuntimeLauncher"
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
            dependencies: ["ForgeConductorCore", "ForgeConductorCLI", "ForgeNativeSessionHostPlugin", "ForgeRuntimeLauncher"],
            path: "Tests/ForgeConductorTests",
            resources: [
                .process("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
