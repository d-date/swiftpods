# Contributing to SwiftPods

## Setup

```console
$ swift build
$ swift test                        # unit + offline integration tests (~10 s)
$ SWIFTPODS_XCODEBUILD=1 swift test # also builds generated workspaces with xcodebuild (slow)
```

Requirements: macOS 15+, Xcode with Swift 6.4. Tests never touch the network; end-to-end
checks against trunk are done manually (see below).

## Where things live

Read [docs/DESIGN.md](docs/DESIGN.md) first. In short:

| I want to… | Look at |
| --- | --- |
| Support another Ruby construct in Podfiles/podspecs | `Sources/PodsDSL` (`Lexer` → `Parser` → `Interpreter`/`Builtins`) |
| Support a new Podfile directive | `RubyPodfileEvaluator` (Ruby), `SwiftPodsDescription/Podfile.swift` (Swift), `PodfileJSON` (shared model) |
| Support a new podspec attribute | `Consumer` (reading), `RubySpecBuilder` (Ruby aliases), `SwiftPodsDescription/PodSpec.swift` |
| Change version resolution | `Sources/PodsResolver/Resolver.swift` |
| Change generated build settings | `Sources/PodsInstaller/XCConfig.swift` |
| Change the generated project | `Sources/PodsInstaller/PodsProjectGenerator.swift` |
| Change user project integration | `Sources/PodsInstaller/UserProjectIntegrator.swift` |
| Add a command | `Sources/SwiftPodsCLI/SwiftPods.swift` |

Every Podfile format (Ruby, JSON, Swift) is converted to the same JSON shape
(CocoaPods' `Podfile#to_hash`), and every podspec format to podspec JSON. New features therefore
usually need: the DSL entry point(s), the JSON reader, and a test for each format.

## Conventions

* Swift 6 language mode with strict concurrency. Models are `Sendable` value types; shared
  mutable state goes in an `actor` or behind `Mutex`. Avoid `@unchecked Sendable` and
  `nonisolated(unsafe)` (the only exception is the manifest registry in `SwiftPodsDescription`,
  which runs in a single-threaded manifest program).
* `InternalImportsByDefault` is on: use `public import` only when a module's types appear in
  public API.
* `SwiftPodsDescription` must only depend on the standard library — it is compiled together
  with user manifests. Keep its API in the style of `Package.swift` (labelled initializers,
  arrays, static factory methods); don't add result builders.
* Comments explain *why*; code is in English.
* Match CocoaPods' observable behaviour (file names, build phase names, lockfile format) unless
  [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) says otherwise — and update that file when you
  change what is supported.

## Tests

* Use Swift Testing (`@Test`, `#expect`, `#require`), with parameterised tests for tables of cases.
* Bug fixes start with a failing test that reproduces the bug.
* Prefer real dependencies over mocks: the installer tests create a real Xcode project
  (`FixtureProject`) and real local pods. Network access is replaced by in-memory sources
  (`MemorySource`, `FakeCDN`).

## Manual end-to-end check

```console
$ swift build
$ cd /path/to/an/app       # with a Podfile
$ SWIFTPODS_CACHE_DIR=/tmp/swiftpods-cache /path/to/swiftpods/.build/debug/swiftpods install
$ xcodebuild -workspace App.xcworkspace -scheme App -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Good pods to try: `Alamofire` (Swift), `SDWebImage` (Objective-C, subspecs), `Moya` (dependencies,
directory patterns), `Kingfisher` (resource bundles), `FirebaseAnalytics` (vendored xcframeworks,
Swift ↔ Objective-C static libraries) — each with and without `use_frameworks!`.
