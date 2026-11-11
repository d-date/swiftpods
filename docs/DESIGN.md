# SwiftPods Design

SwiftPods is a re-implementation of [CocoaPods](https://cocoapods.org) in Swift.
The goals are:

1. **Compatibility** — existing `Podfile`, `*.podspec`, `Podfile.lock` and the
   CocoaPods trunk (CDN) keep working, so a project can switch tools without edits.
2. **Maintainability** — small modules with one responsibility each, value types,
   strict Swift 6 concurrency checking and unit tests for every module.
3. **Swift-native manifests** — `Podfile.swift` / `*.podspec.swift` written with a
   typed, autocompletable API, as an alternative to the Ruby DSL.

## Toolchain

* `swift-tools-version: 6.4`, Swift 6 language mode.
* Upcoming features: `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`,
  `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`.
* Tests use Swift Testing (`import Testing`).

## Module map

```
SwiftPodsCLI ─▶ PodsInstaller ─┬─▶ PodsResolver ─▶ PodsSources ─▶ PodsSpec ─▶ PodsDSL ─▶ PodsCore
                               ├─▶ PodsDownloader                        ▲
                               ├─▶ PodsLockfile (Yams)                   │
                               ├─▶ PodsPodfile ─▶ PodsManifest ──────────┘
                               └─▶ XcodeProj
SwiftPodsDescription  (standalone; the API imported by Podfile.swift / podspec.swift)
```

| Module | Responsibility |
| --- | --- |
| `PodsCore` | `Version`, `Requirement`, `Dependency`, `Platform`, async `Shell` (on swift-subprocess), `UI`, `String` path helpers |
| `PodsDSL` | Tokenizer, parser and evaluator for the Ruby subset used by Podfiles/podspecs |
| `SwiftPodsDescription` | Public manifest API for Swift manifests (no dependencies) |
| `PodsManifest` | Compiles and runs Swift manifests, returning their JSON |
| `PodsSpec` | `Specification` model (podspec JSON is the canonical form), subspecs, per-platform consumers |
| `PodsPodfile` | `Podfile` model built from Ruby `Podfile` or `Podfile.swift` |
| `PodsLockfile` | `Podfile.lock` / `Pods/Manifest.lock` |
| `PodsSources` | Spec sources: CDN trunk, git spec repos, external (`:path`, `:git`, `:podspec`) |
| `PodsResolver` | Backtracking dependency resolver |
| `PodsDownloader` | Fetches pod sources (git/http/path) into a content cache |
| `PodsInstaller` | Sandbox (`Pods/`), `Pods.xcodeproj` generation, xcconfigs, user project/workspace integration |
| `SwiftPodsCLI` | `swiftpods` command (`init`, `install`, `update`, `outdated`, `deintegrate`, `spec`) |

## Concurrency model

* All models are immutable `Sendable` value types.
* Shared mutable state lives in `actor`s (spec caches, CDN index cache, download cache)
  or behind `Synchronization.Mutex` (`UI`).
* Network and process work is `async`; independent work (fetching podspecs,
  downloading pods) is parallelised with `TaskGroup` and bounded concurrency.
* XcodeProj objects are not `Sendable`; project generation runs as a single
  synchronous step that never escapes its isolation domain.

## Swift manifests

### Authoring

Swift manifests use the same style as SwiftPM's `Package.swift`: a single initializer
with labelled arguments, arrays, and static factory methods. `Podfile` and `PodSpec` are
classes, so — like `Package` — they can be modified after creation.

```swift
// Podfile.swift
import SwiftPodsDescription

let podfile = Podfile(
    sources: [.trunk],
    platform: .iOS(.v15),
    useFrameworks: .static,
    targets: [
        .target(
            name: "App",
            dependencies: [
                .pod(name: "Alamofire", from: "5.9.0"),
                .pod(name: "MyKit", path: "../MyKit"),
                .pod(name: "Nuke", git: "https://github.com/kean/Nuke.git", tag: "12.0.0"),
                .pod(name: "FLEX", "~> 5.0", configurations: ["Debug"]),
            ],
            targets: [
                .target(name: "AppTests", inherit: .searchPaths),
            ]
        ),
    ]
)
```

```swift
// MyKit.podspec.swift
import SwiftPodsDescription

let podspec = PodSpec(
    name: "MyKit",
    version: "1.0.0",
    summary: "My kit",
    license: .mit(file: "LICENSE"),
    authors: ["Jane": "jane@example.com"],
    source: .git(url: "https://example.com/MyKit.git", tag: "1.0.0"),
    platforms: [.iOS(.v15), .macOS(.v13)],
    swiftVersions: ["5.9"],
    sourceFiles: ["Sources/**/*.swift"],
    dependencies: [.pod(name: "Alamofire", from: "5.9.0")],
    platformSpecific: [.iOS(.init(frameworks: ["UIKit"]))],
    subspecs: [.subspec(name: "Core", sourceFiles: ["Sources/Core/**/*.swift"])],
    testSpecs: [.testSpec(sourceFiles: ["Tests/**/*.swift"])]
)
```

Version requirements accept both SwiftPM style (`from:`, `exact:`, `"1.0.0"..<"2.0.0"`,
`.upToNextMinor(from:)`) and CocoaPods requirement strings (`"~> 5.0"`).

| Ruby DSL | Swift manifest |
| --- | --- |
| `source 'URL'` | `sources: [.trunk, "URL"]` |
| `platform :ios, '15.0'` | `platform: .iOS(.v15)` / `.iOS("15.0")` |
| `use_frameworks! :linkage => :static` | `useFrameworks: .static` |
| `target 'App' do ... end` | `.target(name: "App", dependencies: [...], targets: [...])` |
| `abstract_target 'Shared'` | `.abstractTarget(name: "Shared", targets: [...])` |
| `inherit! :search_paths` | `inherit: .searchPaths` |
| `pod 'A', '~> 1.0'` | `.pod(name: "A", "~> 1.0")` or `.pod(name: "A", from: "1.0.0")` |
| `pod 'A', :path => '../A'` | `.pod(name: "A", path: "../A")` |
| `s.ios.frameworks = 'UIKit'` | `platformSpecific: [.iOS(.init(frameworks: ["UIKit"]))]` |
| `s.subspec 'Core' do ... end` | `subspecs: [.subspec(name: "Core", ...)]` |

### Evaluation

Like SwiftPM's `Package.swift`, a manifest is compiled and executed:

1. The `SwiftPodsDescription` sources are embedded into the `swiftpods` binary at
   build time by a build-tool plugin (single source of truth, nothing extra to install).
2. `PodsManifest` writes `description sources + #sourceLocation(file: "Podfile.swift", line: 1) + user file`
   into a temporary directory (stripping `import SwiftPodsDescription`), so compiler
   diagnostics point at the user's file and line.
3. `swiftc` builds the program; running it prints the manifest as JSON.
   The executable is cached by a hash of (manifest contents, API version).
4. The JSON is decoded into the same internal models used for Ruby manifests:
   the podspec JSON format for specs and the Podfile JSON schema for Podfiles.

When both `Podfile.swift` and `Podfile` exist, `Podfile.swift` wins.
`swiftpods spec json MyKit.podspec.swift` converts a Swift podspec into the
`.podspec.json` that trunk accepts.

For editor support, `SwiftPodsDescription` is also a library product, so a manifest
can be opened inside a package that depends on it.

## Ruby compatibility

`PodsDSL` implements the subset of Ruby needed for real-world manifests: literals
(strings with interpolation, symbols, numbers, arrays, hashes, ranges), local variables,
method calls with or without parentheses, blocks (`do |x| … end`, `{ |x| … }`),
`if/unless/else`, `.each`, string helpers and constants such as `ENV`. Unsupported
constructs fail with a clear error pointing at the file and line, rather than being
silently ignored. Hooks (`post_install`) are parsed and reported as unsupported.

## Installation pipeline

Implemented by `Installer` in `PodsInstaller`:

1. Load Podfile (Swift or Ruby) and `Podfile.lock`.
2. Fetch external sources (`:path`, `:git`, `:podspec`) and read their specs.
3. Resolve dependencies (locked versions are preferred unless `update` is requested).
4. Download pods into `Pods/<Name>` (in parallel; cached by name/version/checksum).
5. Generate `Pods/Pods.xcodeproj`: a static library / framework target per pod and an
   aggregate `Pods-<Target>` target per user target, plus xcconfigs and support files.
6. Integrate the user project: base xcconfigs, `[CP]` build phases, link the aggregate
   product and create/update `<Project>.xcworkspace`.
7. Write `Podfile.lock` and `Pods/Manifest.lock`.

### Generated project details

* **Pod targets** — one per pod and platform (`Alamofire`, or `Alamofire-iOS` / `Alamofire-macOS`
  when needed); static libraries by default, frameworks with `use_frameworks!`.
* **Headers** (static libraries) — symlinked into `Pods/Headers/{Public,Private}/<Pod>/<header_dir>`.
  A module map + umbrella header are generated in `Headers/Public/<Pod>` unless the pod provides
  one (`module_map`, or a `module.modulemap` next to its public headers).
* **Swift static libraries** — a `[CP] Copy generated compatibility header` phase writes
  `<Module>.modulemap` (exposing `<Module>-Swift.h`) next to the product, so Objective-C
  dependents can `@import` them; dependents receive `-fmodule-map-file`.
* **Resource bundles** — separate bundle targets. Frameworks embed them; static libraries rely on
  the aggregate `[CP] Copy Pods Resources` script.
* **Vendored xcframeworks** — a `[CP] Copy XCFrameworks` phase copies the slice for the current
  platform into `${PODS_XCFRAMEWORKS_BUILD_DIR}/<Pod>`. Binary-only pods become
  `PBXAggregateTarget`s that other targets depend on.
* **Aggregate targets** (`Pods-<Target>`) — depend on every pod target of the user target; their
  xcconfigs are the base configurations of the user target and carry search paths, linker flags
  and `PODS_ROOT`. Inside `Pods.xcodeproj` the aggregate overrides `PODS_ROOT = ${SRCROOT}`.
* **User project** — base configurations, the aggregate product in the Frameworks phase, and the
  `[CP] Check Pods Manifest.lock`, `[CP] Embed Pods Frameworks` and `[CP] Copy Pods Resources`
  phases (the last two only when needed). A workspace referencing the user project(s) and
  `Pods/Pods.xcodeproj` is created or updated.
