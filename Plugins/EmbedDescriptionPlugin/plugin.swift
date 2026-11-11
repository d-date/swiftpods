import PackagePlugin

/// Embeds the `SwiftPodsDescription` sources into `PodsManifest` as a string, so the
/// `swiftpods` binary can compile Swift manifests without shipping extra files.
@main
struct EmbedDescriptionPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        guard let description = try context.package.targets(named: ["SwiftPodsDescription"]).first as? SourceModuleTarget else {
            Diagnostics.error("SwiftPodsDescription target not found")
            return []
        }
        let inputs = description.sourceFiles(withSuffix: "swift").map(\.url).sorted { $0.path < $1.path }
        let output = context.pluginWorkDirectoryURL.appending(path: "EmbeddedDescription.swift")
        return [
            .buildCommand(
                displayName: "Embedding SwiftPodsDescription sources",
                executable: try context.tool(named: "EmbedSources").url,
                arguments: [output.path] + inputs.map(\.path),
                inputFiles: inputs,
                outputFiles: [output]
            ),
        ]
    }
}
