import ArgumentParser
import Foundation
import PodsCore
import PodsInstaller
import PodsManifest
import PodsPodfile
import PodsSources
import PodsSpec

@main
struct SwiftPods: AsyncParsableCommand {
    static let version = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "swiftpods",
        abstract: "A CocoaPods-compatible dependency manager written in Swift.",
        version: version,
        subcommands: [
            Install.self, Update.self, Outdated.self, Deintegrate.self, Init.self, Package.self,
            SpecCommand.self, RepoCommand.self, CacheCommand.self,
        ],
        defaultSubcommand: Install.self
    )
}

/// Options shared by commands that operate on a project.
struct ProjectOptions: ParsableArguments {
    @Option(name: .long, help: "The directory containing the Podfile.")
    var projectDirectory: String?

    @Flag(name: .long, help: "Show more debugging information.")
    var verbose = false

    @Flag(name: .long, help: "Show nothing but errors.")
    var silent = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Colorize output.")
    var ansi = isatty(STDOUT_FILENO) != 0

    var directory: URL {
        URL(fileURLWithPath: projectDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    }

    var ui: UI {
        UI(verbosity: silent ? .silent : (verbose ? .verbose : .normal), usesColor: ansi)
    }

    func context() throws -> InstallerContext {
        try InstallerContext(projectDirectory: directory, ui: ui)
    }
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install the pods listed in Podfile.lock, resolving new ones.")

    @OptionGroup var options: ProjectOptions

    @Flag(name: .long, help: "Update spec repositories before installing.")
    var repoUpdate = false

    @Flag(name: .long, help: "Fail if Podfile.lock would change (for CI).")
    var deployment = false

    @Flag(name: .long, help: "Only generate Pods/, don't touch the user project.")
    var noIntegrate = false

    func run() async throws {
        let ui = options.ui
        try await PodsCLI.run(ui) {
            try await Installer(context: options.context(), options: InstallOptions(
                update: .none, repoUpdate: repoUpdate, integrate: !noIntegrate, deployment: deployment
            )).install()
        }
    }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Update pods to the newest versions allowed by the Podfile.")

    @OptionGroup var options: ProjectOptions

    @Argument(help: "Pods to update. Updates every pod when omitted.")
    var pods: [String] = []

    @Flag(name: .long, inversion: .prefixedNo, help: "Update spec repositories first.")
    var repoUpdate = true

    func run() async throws {
        try await PodsCLI.run(options.ui) {
            try await Installer(context: options.context(), options: InstallOptions(
                update: pods.isEmpty ? .all : .pods(Set(pods)), repoUpdate: repoUpdate
            )).install()
        }
    }
}

struct Outdated: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show pods with newer versions available.")

    @OptionGroup var options: ProjectOptions

    func run() async throws {
        let ui = options.ui
        try await PodsCLI.run(ui) {
            let entries = try await OutdatedChecker(context: options.context()).check()
            if entries.isEmpty {
                ui.message("No pod updates are available.", style: .success)
                return
            }
            ui.message("The following pod updates are available:")
            for entry in entries {
                ui.message("- \(entry.name) \(entry.current) -> \(entry.allowed.map(\.rawValue) ?? "(unused)") (latest version \(entry.latest.map(\.rawValue) ?? "?"))")
            }
        }
    }
}

struct Deintegrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove Pods integration from the Xcode projects.")

    @OptionGroup var options: ProjectOptions

    func run() async throws {
        try await PodsCLI.run(options.ui) {
            try Deintegrator(projectDirectory: options.directory, ui: options.ui).deintegrate()
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a Podfile for the project in the current directory.")

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case ruby, swift
    }

    @OptionGroup var options: ProjectOptions

    @Option(help: "Podfile format: `ruby` (Podfile) or `swift` (Podfile.swift).")
    var format: Format = .ruby

    func run() async throws {
        try await PodsCLI.run(options.ui) {
            let url = try PodfileTemplate.create(in: options.directory, swift: format == .swift)
            options.ui.message("Created \(url.lastPathComponent)", style: .success)
        }
    }
}

struct Package: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build the pods into xcframeworks and generate the distribution Package.swift.")

    @OptionGroup var options: ProjectOptions

    @Option(name: .customLong("version"), help: "The distribution version, used in the binary target URLs.")
    var version: String

    @Option(help: "Where to write the zips and a copy of Package.swift (default: build/distribution next to the Podfile).")
    var output: String?

    @Flag(name: .long, help: "Don't check that every product links on its own.")
    var skipVerification = false

    func run() async throws {
        try await PodsCLI.run(options.ui) {
            let outputDirectory = output.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            try await DistributionBuilder(context: options.context(), options: DistributionOptions(
                version: version, outputDirectory: outputDirectory, verify: !skipVerification
            )).build()
        }
    }
}

// MARK: - spec

struct SpecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spec",
        abstract: "Work with podspecs.",
        subcommands: [JSON.self, Lint.self, Cat.self]
    )

    /// `swiftpods spec json Foo.podspec[.swift]`: prints the podspec as trunk JSON.
    struct JSON: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Convert a Ruby or Swift podspec to podspec JSON.")

        @Argument(help: "Path to a .podspec, .podspec.swift or .podspec.json file.")
        var path: String

        func run() async throws {
            let ui = UI()
            try await PodsCLI.run(ui) {
                let spec = try await PodsCLI.loader.load(URL(fileURLWithPath: path))
                print(spec.json.serialized())
            }
        }
    }

    /// `swiftpods spec lint`: validates a podspec without building it.
    struct Lint: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate a podspec's attributes (does not build).")

        @Argument(help: "Path to a podspec.")
        var path: String

        func run() async throws {
            let ui = UI()
            try await PodsCLI.run(ui) {
                let spec = try await PodsCLI.loader.load(URL(fileURLWithPath: path))
                let issues = SpecLinter.lint(spec)
                for issue in issues { ui.message("- \(issue)", style: .warning) }
                if issues.isEmpty {
                    ui.message("\(spec.name) passed validation.", style: .success)
                } else {
                    throw PodsError("\(spec.name) did not pass validation (\(issues.count) issue\(issues.count == 1 ? "" : "s")).")
                }
            }
        }
    }

    /// `swiftpods spec cat Alamofire`: prints a published podspec.
    struct Cat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the podspec of a published pod.")

        @Argument(help: "Pod name.")
        var name: String

        @Option(help: "Version (defaults to the newest release).")
        var version: String?

        func run() async throws {
            let ui = UI()
            try await PodsCLI.run(ui) {
                let sources = SourcesManager(urls: ["https://cdn.cocoapods.org/"])
                let candidates = try await sources.candidates(for: name)
                let chosen = version.flatMap(Version.init).flatMap { v in candidates.first { $0.version == v } }
                    ?? candidates.first { !$0.version.isPreRelease } ?? candidates.first
                guard let chosen else { throw PodsError("Unable to find a pod named `\(name)`.") }
                print(try await chosen.source.specification(of: name, version: chosen.version).json.serialized())
            }
        }
    }
}

// MARK: - repo / cache

struct RepoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "repo", abstract: "Manage spec repositories.", subcommands: [UpdateRepos.self])

    struct UpdateRepos: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "update", abstract: "Update the spec repositories used by the Podfile.")

        @OptionGroup var options: ProjectOptions

        func run() async throws {
            try await PodsCLI.run(options.ui) {
                let context = try options.context()
                let podfile = try await PodfileLoader().load(context.podfileURL)
                try await SourcesManager(urls: podfile.effectiveSources).update()
                options.ui.message("Spec repositories updated.", style: .success)
            }
        }
    }
}

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cache", abstract: "Manage the download cache.", subcommands: [Clean.self])

    struct Clean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove cached downloads, specs and compiled manifests.")

        func run() async throws {
            let root = CacheLocations.root
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            print("Removed \(root.path)")
        }
    }
}

/// Shared helpers for commands.
enum PodsCLI {
    /// Prints errors CocoaPods-style (`[!] message`) instead of a stack trace.
    static let loader = SpecLoader(swiftEvaluator: SwiftManifestEvaluator(cacheDirectory: CacheLocations.root.appendingPathComponent("Manifests")))

    static func run(_ ui: UI, _ body: () async throws -> Void) async throws {
        // ArgumentParser's own exits (help, version, validation) pass through untouched.
        do {
            try await body()
        } catch let error as ExitCode {
            throw error
        } catch {
            ui.message("[!] \(error)", style: .error)
            throw ExitCode.failure
        }
    }
}
