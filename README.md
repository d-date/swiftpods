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

## Compatibility

See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for what is supported. Verified end to end
(install → `xcodebuild` → launch on the simulator) with, among others: Alamofire, SnapKit,
SDWebImage, Kingfisher, Moya, and FirebaseAnalytics (vendored xcframeworks, mixed
Swift/Objective-C static libraries), both as static libraries and with `use_frameworks!`.

## Documentation

* [Design](docs/DESIGN.md) — modules, concurrency model, manifest evaluation, install pipeline
* [Compatibility](docs/COMPATIBILITY.md) — supported features and known differences
* [Contributing](CONTRIBUTING.md) — development setup, tests and conventions

## License

MIT — see [LICENSE](LICENSE).
