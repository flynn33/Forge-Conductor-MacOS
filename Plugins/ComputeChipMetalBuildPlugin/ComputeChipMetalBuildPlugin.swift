import Foundation
import PackagePlugin

/// Compiles the local chip shaders during SwiftPM builds, never at application runtime.
@main
struct ComputeChipMetalBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let source = context.package.directoryURL
            .appendingPathComponent("Sources/ForgeConductorApp/Metal/ComputeChipShaders.metal")
        let library = context.pluginWorkDirectoryURL.appendingPathComponent("ComputeChipShaders.metallib")
        return [.buildCommand(
            displayName: "Compile Compute Cores Metal shaders",
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--sdk", "macosx", "metal", "-mmacosx-version-min=26.0",
                        source.path, "-o", library.path],
            inputFiles: [source],
            outputFiles: [library]
        )]
    }
}
