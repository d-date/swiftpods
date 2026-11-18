# SwiftPods

A [CocoaPods](https://cocoapods.org)-compatible dependency manager for Apple platforms, written in Swift.

SwiftPods reads your existing `Podfile`, `*.podspec` files and `Podfile.lock`, installs pods
from the CocoaPods trunk (CDN) or your own spec repositories, generates `Pods/Pods.xcodeproj`
and integrates it into your project — without Ruby. It also lets you write manifests in Swift,
with the same syntax as SwiftPM's `Package.swift`.

```console
$ swiftpods install
Analyzing dependencies
Downloading dependencies
Installing Alamofire (5.12.2)
Installing SDWebImage (5.21.7)
Generating Pods project
Integrating client project
Pod installation complete! There are 2 dependencies from the Podfile and 2 total pods installed.
```

## Why

* **No Ruby toolchain** — a single native binary; no Bundler, gem versions or Ruby upgrades.
* **Drop-in compatible** — same `Podfile`, `Podfile.lock` (byte-for-byte), `Pods/` layout and
  `[CP]` build phases, so a team can switch tools without touching the project.
* **Swift manifests** — optionally write `Podfile.swift` / `MyKit.podspec.swift` with type checking
  and autocompletion.
* **Maintainable** — small Swift 6 modules with strict concurrency checking and a test suite.

## Installation

Requires macOS 15+ and Xcode with Swift 6.4.

```console
$ git clone https://github.com/d-date/swiftpods.git
$ cd swiftpods
$ swift build -c release
$ cp .build/release/swiftpods /usr/local/bin/
```

## Usage

| Command | Description |
| --- | --- |
| `swiftpods init [--format ruby\|swift]` | Create a `Podfile` (or `Podfile.swift`) for the project in the current directory |
| `swiftpods install [--repo-update] [--deployment]` | Install pods, keeping the versions in `Podfile.lock` |
| `swiftpods update [POD...]` | Update all pods, or only the given ones |
| `swiftpods outdated` | List pods with newer versions |
| `swiftpods deintegrate` | Remove the integration from your Xcode project(s) |
| `swiftpods package --version <v> [--output <dir>] [--skip-verification]` | Build the pods into xcframeworks and generate a distribution `Package.swift` (see [Distributing pods as a Swift package](#distributing-pods-as-a-swift-package)) |
| `swiftpods spec json <file>` | Convert a Ruby or Swift podspec to podspec JSON (the format trunk accepts) |
| `swiftpods spec lint <file>` | Validate a podspec's attributes |
| `swiftpods spec cat <pod>` | Print a published podspec |
| `swiftpods repo update` | Update the spec repositories used by the Podfile |
| `swiftpods cache clean` | Remove downloaded pods, cached specs and compiled manifests |

After installing, open the generated `.xcworkspace`, as with CocoaPods.

### Podfile (Ruby)

Existing Podfiles work as they are:

```ruby
platform :ios, '16.0'
use_frameworks!

target 'App' do
  pod 'Alamofire', '~> 5.9'
  pod 'MyKit', :path => '../MyKit'

  target 'AppTests' do
    inherit! :search_paths
  end
end
```

SwiftPods evaluates Podfiles with a built-in interpreter for the subset of Ruby that manifests
use (method calls, blocks, `def`, `if`/`unless`, string interpolation, heredocs, `ENV`, …).
`post_install` / `pre_install` hooks and CocoaPods plugins cannot run and are reported as warnings.

### Podfile.swift

```swift
import SwiftPodsDescription

let podfile = Podfile(
    sources: [.trunk],
    platform: .iOS(.v16),
    useFrameworks: .dynamic,
    targets: [
        .target(
            name: "App",
            dependencies: [
                .pod(name: "Alamofire", from: "5.9.0"),          // >= 5.9.0, < 6.0.0
                .pod(name: "Kingfisher", "~> 8.0"),              // CocoaPods requirement
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

When both exist, `Podfile.swift` takes precedence over `Podfile`. Like `Package.swift`, the
manifest is compiled and run, so you can use any Swift code to build it.

#### SwiftPM packages

`Podfile.swift` can also declare SwiftPM packages, resolved together with the pods:

```swift
let podfile = Podfile(
    platform: .iOS(.v16),
    packages: [
        .package(url: "https://github.com/google/GoogleUtilities.git", "8.0.0"..<"9.0.0"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .pod(name: "GoogleMLKit/BarcodeScanning", from: "7.0.0"),
                .product(name: "GULLogger", package: "GoogleUtilities"),
            ]
        ),
    ]
)
```

When a pod is the same library as a resolved package (its version tags point at the same git
commits), SwiftPods uses the package instead of building the pod, so the library is linked only
once. The package is restricted to the versions tagged at the same commit as a version the pods
accept, and SwiftPM picks the version. The packages are added to `Pods/Pods.xcodeproj` as package
references pinned to the exact resolved versions, their products are linked through the
`Pods-<Target>` targets, the pins are written to
`Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and
`Podfile.lock` records them under `SWIFT PACKAGES:`. `swiftpods install` keeps the pinned versions of
`Podfile.lock` (those under `Pods/` only when there is no `Podfile.lock`); `swiftpods update` moves them, and
`swiftpods update <names>` only moves the packages the named pods are unified with or that are
named by identity. Every library product of a unified package is linked. Your own `.xcodeproj`,
`Package.swift` and workspace `Package.resolved` are not written to. Not supported yet: package
products with dynamic frameworks (`use_frameworks!` without `:linkage => :static`), several pods
that are the same package (monorepos), and pods from external sources (`:git`, `:path`,
`:podspec`) built from the repository of a package.

### Podspecs in Swift

```swift
// MyKit.podspec.swift
import SwiftPodsDescription

let podspec = PodSpec(
    name: "MyKit",
    version: "1.0.0",
    summary: "My kit",
    homepage: "https://example.com/MyKit",
    license: .mit(),
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

`swiftpods spec json MyKit.podspec.swift > MyKit.podspec.json` produces a spec you can publish to trunk.

### Distributing pods as a Swift package

`swiftpods package` turns CocoaPods-only pods (prebuilt ones included) into a SwiftPM package of binary
targets, as [google-mlkit-swiftpm](https://github.com/d-date/google-mlkit-swiftpm) does for Google ML Kit.
The Podfile.swift needs `distribution:`, one target, `integrateTargets: false` and static frameworks:

```swift
let podfile = Podfile(
    platform: .iOS("15.5"),
    useFrameworks: .static,
    installationOptions: .init(integrateTargets: false),
    packages: [
        .package(url: "https://github.com/google/GoogleUtilities.git", from: "8.1.0"),
        .package(url: "https://github.com/google/gtm-session-fetcher.git", "3.5.0"..<"6.0.0",
                 overridingPodRequirements: .unsafe(reason: "ABI checked by hand for Firebase 13")),
    ],
    distribution: .init(name: "GoogleMLKitSwiftPM", url: "https://github.com/d-date/google-mlkit-swiftpm"),
    targets: [
        .target(name: "MLKit", dependencies: [
            .pod(name: "GoogleMLKit/BarcodeScanning", "~> 9.0.0"),
            .pod(name: "GoogleMLKit/FaceDetection", "~> 9.0.0"),
        ]),
    ]
)
```

```sh
swiftpods package --version 9.0.3
```

* **Products and targets** are derived from the pod graph: one library product per declared pod (for a
  subspec of an umbrella pod such as `GoogleMLKit/BarcodeScanning`, the pod it depends on:
  `MLKitBarcodeScanning`), listing the binary targets of that pod's transitive closure. Binary targets
  every product needs go into a `Common` source target (`@_exported import` of each prebuilt framework; source pods become
  library xcframeworks without a module map and are only linked), together with the
  products of the Swift packages the pods are unified with that hold the code of the activated subspecs
  (the products named with `.product(name:package:)` in the target instead, when there are any for that
  package; products of other declared packages only when named that way). `Common` also links the
  system frameworks and libraries the binary pods' activated specs declare (`frameworks`,
  `weak_frameworks`, `libraries`; SwiftPM cannot weak-link, so weak frameworks are linked normally).
* **Dependency ranges**: a package a pod is unified with is narrowed to the versions the pods accept: the
  longest run of consecutive tagged versions, all accepted, around the resolved one (`"lo"..."hi"`, or
  `exact:` for a single version). New upstream releases come in with the next `swiftpods package`.
  Other declared packages keep their declared range.
* **Unsafe overrides**: `overridingPodRequirements: .unsafe(reason:)` replaces the pods' requirement on a
  package with the declared range, for when you have checked by hand that a wider range works.
  `install` and `package` print a warning instead of failing, and the generated `Package.swift` keeps the
  declared range and starts with a `#warning` naming the package. `swift package resolve` prints that
  warning to consumers when it evaluates the manifest (also for a dependency); `xcodebuild
  -resolvePackageDependencies` does not print it (Xcode 27.2), and whether the Xcode UI shows it was not
  checked. Do not rely on consumers seeing it.
* **Outputs**, in `build/distribution` next to the Podfile or `--output`: `<Module>.xcframework.zip` for
  every binary target (and the unzipped xcframework), `<Bundle>.bundle.zip` for every resource bundle
  (as built by `xcodebuild` for source pods; a declared bundle that is not found is reported),
  `Package.swift` and `Sources/Common/export.swift`. The last two are also written next to the Podfile.
  Xcframeworks, bundles and their zips left in the output directory by an earlier run are removed first,
  and the command lists the files it wrote.
  Binary target URLs are `<distribution url>/releases/download/<version>/<Module>.xcframework.zip`; upload
  the zips there. Resource bundles are not part of the package: consumers add the unzipped bundles to
  their app.
* **Binary fixes**: prebuilt frameworks get an `Info.plist` when they lack one, an arm64 simulator slice
  is made from the device slice when missing, objects without a platform are given one, object-file
  binaries become `ar` archives, and source pods become library xcframeworks (`lib<Module>.a`).
* **Verification**: every product is linked on its own into an iOS executable for the simulator and
  the device, importing the product's module and linking with `-ObjC -all_load` (as consumers of static
  archives must), so a product that only links thanks to another product's targets fails the command. `--skip-verification` skips it.
* Not supported yet: platforms other than iOS, Swift source pods, pods with both sources and vendored
  frameworks, and dynamic prebuilt frameworks.

## Compatibility

See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for what is supported. Verified end to end
(install → `xcodebuild` → launch on the simulator) with, among others: Alamofire, SnapKit,
SDWebImage, Kingfisher, Moya, and FirebaseAnalytics (vendored xcframeworks, mixed
Swift/Objective-C static libraries), both as static libraries and with `use_frameworks!`.
The full Google ML Kit pod set (39 pods, `integrate_targets: false`) produces a `Podfile.lock`
identical to CocoaPods 1.17 and a `Pods.xcodeproj` that builds for device and simulator.

## Documentation

* [Design](docs/DESIGN.md) — modules, concurrency model, manifest evaluation, install pipeline
* [Compatibility](docs/COMPATIBILITY.md) — supported features and known differences
* [Contributing](CONTRIBUTING.md) — development setup, tests and conventions

## License

MIT — see [LICENSE](LICENSE).
