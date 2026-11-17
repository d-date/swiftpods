# Distribution Package Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `swiftpods package --version <v>` builds the pods of a Podfile.swift into xcframework and
resource-bundle zips and writes the whole distribution `Package.swift`, reproducing
google-mlkit-swiftpm's pipeline without ML Kit-specific lists.

**Architecture:** New code lives in `Sources/PodsInstaller/Distribution/` (same pattern as
`SwiftPackages/`), split into pure, unit-tested pieces (narrowing, layout derivation, Info.plist,
Mach-O rewriting, manifest rendering) and one orchestrator (`DistributionBuilder`) that runs
`Installer`, `xcodebuild`, `lipo`, `libtool`, `zip`, then link verification. Project 1's
`PackageUnifier` gains unsafe overrides and keeps the tagged versions needed for narrowing.

**Tech Stack:** Swift 6.4, swift-subprocess via `PodsCore.Shell`, ArgumentParser, Swift Testing,
`xcrun` tools (`xcodebuild`, `lipo`, `libtool`, `clang`), `/usr/bin/zip`, CryptoKit SHA-256.

**Spec:** `docs/superpowers/specs/2026-11-17-distribution-package-generation-design.md`

## Global Constraints

* No ML Kit names anywhere under `Sources/` (anti-goal "Any ML Kit name hard-coded in swiftpods").
* No `NSString` casts; code comments in English; Swift 6.4 language mode, strict concurrency.
* External commands only through `PodsCore.Shell` (swift-subprocess).
* Podfiles that declare no package and no `distribution` behave exactly as before.
* Generated `Package.swift`: `// swift-tools-version: 5.9`, a header comment saying it is generated
  by swiftpods and must not be edited by hand, byte-identical for identical inputs.
* Binary target URL: `<distribution url>/releases/download/<version>/<file>`; file names
  `<Name>.xcframework.zip`, `<Name>.bundle.zip`.
* Default `CFBundleIdentifier`: `org.cocoapods.<Module>`.
* `LC_BUILD_VERSION` platform numbers: 2 = iOS, 7 = iOS Simulator. The rewrite runs before the
  object → `ar` conversion.
* Tests: `swift test` (default), `SWIFTPODS_XCODEBUILD=1` (xcodebuild e2e), `SWIFTPODS_MLKIT=1`
  (network, ML Kit). Unit tests that need `clang`/`lipo`/`libtool` run by default but are skipped
  when `xcrun --find clang` fails.
* Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus

1. A package whose allowed versions have a gap (a disallowed tag between two allowed ones): the
   closed range must stop before the gap on the side of the pin — Task 3 `narrowsToRunContainingPin`.
2. A prebuilt framework whose binary is a fat file with `arm64` + `x86_64` device/simulator mixes
   (ML Kit: device `arm64`, simulator `x86_64` only): the injected simulator `arm64` must come from
   the device `arm64`, and the existing `x86_64` must be kept — Task 6 `injectsSimulatorArm64KeepingX86`.
3. An `ar` archive with duplicate member names: the in-place platform rewrite must keep every
   member — Task 5 `rewritesArchiveWithDuplicateMembers`.
4. A declared pod with no binary target in its closure (only Swift-package-unified pods): no empty
   product is generated; it is reported as a warning — Task 4 `skipsProductWithoutBinaryTargets`.
5. Resource bundle names that collide between a podspec key and a nested framework bundle with the
   same name: one zip, no error — Task 7 `deduplicatesBundlesByName`.

---

### Task 1: Declare unsafe overrides and distribution settings

**Files:**
- Modify: `Sources/SwiftPodsDescription/Podfile.swift` (SwiftPackage, Podfile init/json)
- Modify: `Sources/PodsPodfile/Podfile.swift` (SwiftPackageDependency, Podfile)
- Modify: `Sources/PodsPodfile/PodfileJSON.swift`
- Test: `Tests/PodsManifestTests/SwiftManifestTests.swift`, `Tests/PodsPodfileTests/PodfileTests.swift`

**Interfaces:**
- Produces (SwiftPodsDescription): every `SwiftPackage.package(url:…)` overload gains a trailing
  `overridingPodRequirements: PodRequirementOverride? = nil`; `public enum PodRequirementOverride { case unsafe(reason: String) }`;
  `Podfile.init(…, distribution: Distribution? = nil, …)` (parameter after `packages:`);
  `public struct Distribution { public init(name: String, url: String) }`.
- Produces (JSON): package object key `"unsafe_override": {"reason": "<text>"}`; root key
  `"distribution": {"name": "...", "url": "..."}`.
- Produces (PodsPodfile): `SwiftPackageDependency.unsafeOverrideReason: String?` (init parameter
  with default `nil`; not part of `Hashable` identity semantics beyond synthesized),
  `Podfile.distribution: DistributionSettings?` with `public struct DistributionSettings: Sendable, Equatable { public let name: String; public let url: String }`.

- [ ] **Step 1: Failing tests**

```swift
// SwiftManifestTests
@Test func swiftPodfileDeclaresUnsafeOverrideAndDistribution() async throws {
    // Podfile.swift with:
    //   distribution: .init(name: "Kit", url: "https://github.com/o/kit"),
    //   packages: [.package(url: "https://github.com/google/gtm-session-fetcher.git", "3.5.0"..<"6.0.0",
    //                       overridingPodRequirements: .unsafe(reason: "ABI checked in #124"))]
    let podfile = try await evaluate(source)
    #expect(podfile.distribution == DistributionSettings(name: "Kit", url: "https://github.com/o/kit"))
    #expect(podfile.swiftPackages.first?.unsafeOverrideReason == "ABI checked in #124")
}
// PodfileTests
@Test func jsonPodfileReadsUnsafeOverrideAndDistribution()   // same assertions from Podfile.json
@Test func packageWithoutOverrideHasNoReason()               // unsafeOverrideReason == nil, distribution == nil
```

- [ ] **Step 2:** `swift test --filter "UnsafeOverride|Distribution|WithoutOverride"` → FAIL (no such API).
- [ ] **Step 3:** Implement the API and JSON round trip above. The Ruby DSL gets nothing.
- [ ] **Step 4:** Same filter → PASS; `swift test` green.
- [ ] **Step 5:** Commit "Let Podfile.swift declare unsafe package overrides and distribution settings".

### Task 2: Install honours unsafe overrides and keeps tagged versions

**Files:**
- Modify: `Sources/PodsInstaller/SwiftPackages/PackageUnifier.swift`
- Modify: `Sources/PodsInstaller/Analyzer.swift` (`resolveSwiftPackages`)
- Test: `Tests/PodsInstallerTests/PackageUnifierTests.swift`, `Tests/PodsInstallerTests/SwiftPackageTests.swift`

**Interfaces:**
- Consumes: `SwiftPackageDependency.unsafeOverrideReason` (Task 1).
- Produces: `PackageUnifier.PackageCandidate.unsafeOverrideReason: String?`;
  `Unification.taggedVersions: [Version]` (ascending, every non-pre-release tagged version of the
  package), `Unification.podAcceptedVersions: [Version]` (ascending, commit-matched versions that
  satisfy the pod requirements and the Podfile requirement — today's `allowedVersions` computation),
  `Unification.unsafeOverrideReason: String?`. For an overridden package `allowedVersions` =
  tagged versions satisfying the Podfile requirement (commit match not required) and
  `allowedCommits` = their commits; otherwise unchanged (`allowedVersions == podAcceptedVersions`).

Behaviour: an overridden package never raises the "No version … satisfies" conflict; after the
second resolution, if the pinned version is not in `podAcceptedVersions`, `ui.warn` once:
`Swift package <url> <version> is outside the versions pod '<pod>' accepts (<pod requirements>); allowed by an unsafe override in Podfile.swift: <reason>. ABI compatibility is not verified.`
If it is inside, no warning.

- [ ] **Step 1: Failing tests**

```swift
// PackageUnifierTests
@Test func overrideAllowsVersionsOutsidePodRange() throws {
    // package tags 1.0.0(c1) 2.0.0(c2); pod versions 1.0.0(c1); pod requirement "< 2.0"; podfile range 1.0.0..<3.0.0, override reason "r"
    let u = try PackageUnifier.unify(pods: [pod], packages: [package]).first!
    #expect(u.allowedVersions == [Version(1,0,0), Version(2,0,0)])
    #expect(u.podAcceptedVersions == [Version(1,0,0)])
    #expect(u.taggedVersions == [Version(1,0,0), Version(2,0,0)])
}
@Test func overrideWithNoCommitMatchIsNotAConflict()   // pod accepts nothing in range → no throw, podAcceptedVersions == []
// SwiftPackageTests (fixture: Lib 1.0.0 and 2.0.0 tagged; binary pod requires Lib < 2.0)
@Test func unsafeOverrideInstallsAndWarns() async throws {
    // packages: [(libURL, [">= 1.0.0", "< 3.0.0"], override "checked")], update: .all
    // expect: install succeeds, Podfile.lock SWIFT PACKAGES version == 2.0.0,
    //         ui.warnings contains one entry with libURL, "2.0.0", "checked", "ABI compatibility is not verified"
}
@Test func unsafeOverrideInsidePodRangeDoesNotWarn()   // pin stays 1.0.0 → ui.warnings has no override warning
```
(`writePodfile` gains an optional override reason per package.)

- [ ] **Step 2:** `swift test --filter "Override"` → FAIL.
- [ ] **Step 3:** Implement in `PackageUnifier.unify` and `Analyzer.resolveSwiftPackages` (pass the
  reason into `PackageCandidate`; warn after `verify`).
- [ ] **Step 4:** Filter → PASS; `swift test` green; `mlkitRejectsGTM4` semantics unchanged (no override → still an error).
- [ ] **Step 5:** Commit "Allow unsafe overrides of pod requirements for Swift packages".

### Task 3: Narrow distribution requirements to a contiguous run

**Files:**
- Create: `Sources/PodsInstaller/Distribution/DistributionRequirement.swift`
- Test: `Tests/PodsInstallerTests/DistributionRequirementTests.swift`

**Interfaces:**
- Consumes: `Unification` (Task 2).
- Produces:
```swift
enum DistributionRequirement: Equatable, Sendable {
    case exact(Version)
    case closedRange(Version, Version)
    /// Declared range of an overridden package, rendered as written, plus the `#warning` text.
    case unsafe(lower: Version, upper: Version, warning: String)
    static func narrowed(allowed: [Version], tagged: [Version], pinned: Version) throws(PodsError) -> DistributionRequirement
    static func forUnification(_ u: PackageUnifier.Unification, pinned: Version, declared: Requirement?) throws(PodsError) -> DistributionRequirement
}
```
`narrowed`: walk `tagged` (ascending); the run is the maximal sequence of consecutive tagged
versions that are all in `allowed` and contains `pinned`; one element → `.exact`, else
`.closedRange(first, last)`. `pinned` not in `allowed` → throw. `forUnification` returns `.unsafe`
for an overridden unification (bounds from the declared requirement's range, warning text:
`<identity> <lower>..<<upper> is outside the versions the pods accept (<pod root> accepts <podAccepted lowest>...<highest>); ABI compatibility is unsafe and not verified by swiftpods. Reason: <reason>`), else `narrowed`.

- [ ] **Step 1: Failing tests**

```swift
@Test func singleAllowedVersionIsExact()            // allowed [2.30910.0], tagged [2.30909.0, 2.30910.0, 2.30910.1], pinned 2.30910.0 → .exact(2.30910.0)
@Test func narrowsToRunContainingPin()              // tagged 1.0.0..1.0.5, allowed {1.0.0,1.0.1,1.0.3,1.0.4}, pinned 1.0.4 → .closedRange(1.0.3, 1.0.4)
@Test func runSpansAllowedTail()                    // tagged 8.0.0,8.1.0,8.1.4,8.1.5 all allowed, pinned 8.1.5 → .closedRange(8.0.0, 8.1.5)
@Test func pinOutsideAllowedThrows()
@Test func overriddenUnificationIsUnsafe()          // reason "r", declared 3.5.0..<6.0.0 → .unsafe(lower: 3.5.0, upper: 6.0.0, warning contains "unsafe" and "Reason: r")
```

- [ ] **Step 2:** `swift test --filter DistributionRequirementTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit "Narrow distribution requirements to the run of allowed versions".

### Task 4: Derive products, targets and Common from the pod graph

**Files:**
- Create: `Sources/PodsInstaller/Distribution/DistributionLayout.swift`
- Test: `Tests/PodsInstallerTests/DistributionLayoutTests.swift`

**Interfaces:**
- Produces:
```swift
struct DistributionLayout: Equatable, Sendable {
    struct Product: Equatable, Sendable { let name: String; let targets: [String] }   // targets exclude Common members, end with "Common"
    let products: [Product]                  // Podfile declaration order
    let commonTargets: [String]              // binary targets every product needs, sorted
    let binaryTargets: [String]              // sorted; every pod that is neither unified nor an umbrella without own binary
    let unifiedPackageURLs: [String]         // packages Common depends on, sorted
    let warnings: [String]
    /// `declared`: the pod dependency names of the distribution target, in order (may be subspecs).
    /// `dependencies`: pod or subspec name → pod or subspec names it depends on (from the resolved specs).
    /// `podsWithBinary`: roots that produce a binary (vendored framework or compiled sources).
    /// `unified`: pod root → package URL.
    static func derive(declared: [String], dependencies: [String: [String]], podsWithBinary: Set<String>,
                       unified: [String: String]) -> DistributionLayout
}
```
Rules (from the spec): product of a declared subspec `A/B` = the roots `A/B` depends on directly
outside root `A`, restricted to `podsWithBinary`; exactly one → that root; several → the first in
sorted order plus a warning naming the others; none (and `A` itself has a binary) → `A`. Product of
a declared root pod = itself. Closure = transitive roots through `dependencies` (subspec edges
included), ∩ `podsWithBinary`. `commonTargets` = intersection of all product closures (the product
pod itself included). Product targets = `[product] + (closure − {product} − common, sorted) + ["Common"]`.
`unifiedPackageURLs` = packages of unified pods reachable from any declared dependency.

- [ ] **Step 1: Failing tests** — a fixture shaped like ML Kit 9.0's Podfile.lock (copy the
`PODS:` edges for GoogleMLKit/{BarcodeScanning, DigitalInkRecognition, LanguageID, PoseDetectionAccurate},
MLKitCommon, MLKitVision, MLImage, MLKitXenoCommon, MLKitPoseDetectionCommon, MLKitMDD,
MLKitNaturalLanguage, GoogleToolboxForMac, SSZipArchive, GoogleUtilities, nanopb from
google-mlkit-swiftpm's Podfile.lock into the test as a dictionary literal — test data, not Sources):

```swift
@Test func derivesMLKitShapedProducts() {
    let layout = DistributionLayout.derive(declared: declared, dependencies: deps, podsWithBinary: binaries,
                                           unified: ["GoogleUtilities": gulURL, "nanopb": nanopbURL])
    #expect(layout.products.map(\.name) == ["MLKitBarcodeScanning", "MLKitDigitalInkRecognition", "MLKitLanguageID", "MLKitPoseDetectionAccurate"])
    #expect(layout.commonTargets == ["GoogleToolboxForMac", "MLKitCommon"])
    #expect(layout.products[3].targets == ["MLKitPoseDetectionAccurate", "MLImage", "MLKitPoseDetectionCommon", "MLKitVision", "MLKitXenoCommon", "Common"])
    #expect(!layout.products[2].targets.contains("MLKitXenoCommon"))
    #expect(layout.unifiedPackageURLs == [gulURL, nanopbURL].sorted())
}
@Test func skipsProductWithoutBinaryTargets()   // declared pod whose closure is only unified pods → no product, one warning naming it
@Test func severalDirectBinaryDependenciesWarn() // subspec depending on two binary roots → first sorted, warning lists the other
```

- [ ] **Step 2:** `swift test --filter DistributionLayoutTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit "Derive distribution products from the pod graph".

### Task 5: Mach-O inspection and in-place platform rewrite

**Files:**
- Create: `Sources/PodsInstaller/Distribution/MachO.swift`
- Test: `Tests/PodsInstallerTests/MachOTests.swift`

**Interfaces:**
- Produces:
```swift
enum MachO {
    enum Kind: Equatable, Sendable { case archive, object, image, fat, unknown }
    static func kind(of file: URL) throws -> Kind
    /// Rewrites the platform of every LC_BUILD_VERSION in a thin Mach-O or in every member of a thin
    /// `ar` archive, in place, keeping the archive layout. Throws `PodsError` when a file or member has
    /// no LC_BUILD_VERSION (it cannot be added in place).
    static func rewritePlatform(of file: URL, to platform: UInt32) throws
    static func platforms(of file: URL) throws -> Set<UInt32>   // for tests and verification
}
```
Reference implementation: google-mlkit-swiftpm `scripts/patch_macho_platform.rb` (BSD `ar` with
`#1/<len>` extended names; members padded to even sizes; 64- and 32-bit magics; both endiannesses).
Use `Data` and explicit little/big-endian reads; no Foundation string bridging.

- [ ] **Step 1: Failing tests** (fixtures built in a temp dir with `xcrun clang -c -target arm64-apple-ios15.0` and `xcrun libtool -static`; skip when `xcrun --find clang` fails)

```swift
@Test func detectsKinds()                          // .o → .object, libtool .a → .archive, lipo -create → .fat
@Test func rewritesObjectPlatform()                // platforms == [2] → rewrite to 7 → [7]
@Test func rewritesArchiveWithDuplicateMembers() { // archive with two members both named "globals.o" (different dirs)
    try MachO.rewritePlatform(of: archive, to: 7)
    #expect(try MachO.platforms(of: archive) == [7])
    // `ar -t` lists the same member names in the same order as before; `nm` symbol list unchanged
}
@Test func missingBuildVersionThrows()             // object built with -mmacosx-version-min old enough to emit LC_VERSION_MIN only, or a stripped stub; error message names the file
```

- [ ] **Step 2:** `swift test --filter MachOTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit "Rewrite Mach-O build platforms in place".

### Task 6: Assemble xcframeworks (prebuilt and source)

**Files:**
- Create: `Sources/PodsInstaller/Distribution/XCFrameworkAssembler.swift`
- Create: `Sources/PodsInstaller/Distribution/FrameworkInfoPlist.swift`
- Test: `Tests/PodsInstallerTests/XCFrameworkAssemblerTests.swift`

**Interfaces:**
- Consumes: `MachO` (Task 5).
- Produces:
```swift
enum FrameworkInfoPlist {
    /// Keys from the spec: CFBundleExecutable, CFBundleName, CFBundleIdentifier (org.cocoapods.<module>),
    /// CFBundlePackageType FMWK, CFBundleShortVersionString (release part of podVersion: "1.0.0-beta8" → "1.0.0"),
    /// CFBundleVersion "1", CFBundleSupportedPlatforms [platformName], MinimumOSVersion.
    static func make(module: String, podVersion: Version, platformName: String, minimumOS: String) -> Data
}
struct XCFrameworkAssembler {
    let shell: Shell
    let workDirectory: URL
    /// A prebuilt `.framework` (device and simulator slices fat in one binary, as vendored by pods):
    /// adds Info.plist when missing, splits per SDK, injects simulator arm64 from device arm64 when absent,
    /// converts object binaries to `ar`, then `xcodebuild -create-xcframework -framework … -framework …`.
    func assemblePrebuilt(framework: URL, podVersion: Version, minimumOS: String, output: URL) async throws -> URL
    /// A source pod built per SDK into `<build>/Release-<sdk>/<target>/<Module>.framework` (static):
    /// library xcframework from `lib<Module>.a` + `Headers` of each SDK.
    func assembleSource(module: String, deviceFramework: URL, simulatorFramework: URL, output: URL) async throws -> URL
}
```
Slice split: device slice = archs whose platform is 2, simulator = archs whose platform is 7 or
`x86_64`/`i386` (ML Kit simulator slices are x86_64). Object → `ar`: `xcrun libtool -static -o <out> <object>`
per arch, then `lipo -create`.

- [ ] **Step 1: Failing tests** (clang/lipo fixtures; skip without `xcrun`)

```swift
@Test func injectsSimulatorArm64KeepingX86() async throws {
    // fat framework binary: arm64 (platform 2, object file) + x86_64 (platform 7)
    let xcf = try await assembler.assemblePrebuilt(framework: fw, podVersion: Version(1,2,3), minimumOS: "15.0", output: out)
    // Info.plist AvailableLibraries: one ios slice [arm64], one ios-simulator slice [arm64, x86_64]
    // simulator binary: MachO.kind == .archive (ar), platforms == [7]
    // framework Info.plist exists with CFBundleIdentifier "org.cocoapods.Fixture", CFBundleShortVersionString "1.2.3"
}
@Test func keepsExistingInfoPlist()
@Test func betaVersionUsesReleasePart()   // FrameworkInfoPlist.make(podVersion: 1.0.0-beta8) → "1.0.0"
@Test func sourcePodBecomesLibraryXCFramework() async throws // AvailableLibraries LibraryPath == "libFixture.a", HeadersPath == "Headers", no .framework inside
```

- [ ] **Step 2:** `swift test --filter XCFrameworkAssemblerTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit "Assemble xcframeworks from prebuilt and source pods".

### Task 7: Render Package.swift and collect resource bundles

**Files:**
- Create: `Sources/PodsInstaller/Distribution/DistributionManifest.swift`
- Create: `Sources/PodsInstaller/Distribution/ResourceBundles.swift`
- Test: `Tests/PodsInstallerTests/DistributionManifestTests.swift`, `Tests/PodsInstallerTests/Fixtures/Distribution/Package.swift.golden`

**Interfaces:**
- Consumes: `DistributionLayout` (Task 4), `DistributionRequirement` (Task 3), `DistributionSettings` (Task 1).
- Produces:
```swift
struct DistributionManifest {
    struct Dependency: Equatable, Sendable { let url: String; let requirement: DistributionRequirement; let products: [String] }
    static func render(settings: DistributionSettings, version: String, platform: Platform,
                       layout: DistributionLayout, checksums: [String: String],   // target name → sha256
                       dependencies: [Dependency]) -> String
    /// Sources/Common/export.swift: one `@_exported import <M>` per Common binary target, sorted.
    static func renderCommonExports(layout: DistributionLayout) -> String
}
enum ResourceBundles {
    /// `Pods/<pod>/<resource_bundles dirs>` of the pods with binaries plus `*.bundle` directories nested
    /// up to two levels inside their vendored frameworks; deduplicated by bundle name (first wins, sorted by pod).
    static func collect(pods: [InstalledPod], podsWithBinary: Set<String>) -> [(name: String, directory: URL)]
}
```
Rendering: `platforms: [.iOS("<deployment target>")]` (string form, any version); requirements
`exact: "x"`, `"a"..."b"`, `"a"..<"b"`; one `#warning("<text>")` line after `import PackageDescription`
per `.unsafe` dependency, sorted by URL; `Common` is `.target(name: "Common", dependencies: [<common binaries>, .product(name:, package: <identity>)…])`.

- [ ] **Step 1: Failing tests**

```swift
@Test func rendersGoldenManifest()            // fixed inputs (2 products, 1 exact, 1 closed, 1 unsafe dependency) == golden file byte for byte
@Test func renderingIsDeterministic()         // render twice with dictionary inputs built in different orders → equal
@Test func warningPerUnsafeDependency()       // count of "#warning(" == number of .unsafe dependencies; warning text escaped as a Swift string literal
@Test func deduplicatesBundlesByName()        // podspec bundle "A" and nested "A.bundle" → one entry
@Test func commonExportsSorted()
```
Generated golden must also pass `swift package dump-package` in a temp dir with a stub
`Sources/Common/export.swift` (part of `rendersGoldenManifest`, skipped without `swift`).

- [ ] **Step 2:** `swift test --filter DistributionManifestTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit "Render the distribution Package.swift".

### Task 8: Build, zip and write the distribution (`swiftpods package`)

**Files:**
- Create: `Sources/PodsInstaller/Distribution/DistributionBuilder.swift`
- Modify: `Sources/SwiftPodsCLI/SwiftPods.swift` (new `Package` subcommand)
- Test: `Tests/PodsInstallerTests/DistributionBuilderTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7; `Installer.install() -> InstallationPlan`; `Analysis.unifications`, `.swiftPackages`.
- Produces:
```swift
public struct DistributionOptions: Sendable {
    public init(version: String, outputDirectory: URL?, verify: Bool = true)
}
public struct DistributionBuilder {
    public init(context: InstallerContext, options: DistributionOptions)
    /// Returns the output directory.
    @discardableResult public func build() async throws -> URL
}
```
CLI: `swiftpods package --version <v> [--output <dir>] [--skip-verification] [--project-directory]`
(abstract: "Build the pods into xcframeworks and generate the distribution Package.swift."). Rename
nothing; the `--version` clash with ArgumentParser's built-in is avoided by declaring the option as
`@Option(name: .customLong("version"))` on a subcommand (built-in `--version` is root-only); verify.

Steps of `build()`: require `podfile.distribution` (error: "Podfile.swift has no `distribution`.")
and `integrate_targets: false`; `Installer.install()` (needs the analysis: make `Installer` return
both plan and analysis via a new internal method rather than changing the public API); per SDK
`xcodebuild -project Pods/Pods.xcodeproj -alltargets -configuration Release -sdk <sdk> ONLY_ACTIVE_ARCH=NO
ENABLE_TESTABILITY=NO CLANG_ENABLE_MODULE_DEBUGGING=NO SYMROOT=<work>/build <PLATFORM>_DEPLOYMENT_TARGET=<podfile platform>`;
assemble each binary target; collect bundles; `zip -qry <Name>.<ext>.zip <Name>.<ext>` from the parent
directory; SHA-256 per xcframework zip; render; write `Package.swift` and `Sources/Common/export.swift`
next to the Podfile and a copy of `Package.swift` into the output dir (default `<podfile dir>/build/distribution`);
then Task 9's verification unless `verify == false`.

- [ ] **Step 1: Failing tests**

```swift
@Test func requiresDistributionSettings() async throws   // Podfile.swift without distribution → PodsError mentioning `distribution`
@Test(.enabled(if: env SWIFTPODS_XCODEBUILD == "1"))
func buildsFixtureDistribution() async throws {
    // fixture: one prebuilt vendored framework pod (clang-built, device arm64 + sim x86_64, no Info.plist)
    // depending on one source pod; distribution name "Fixture"
    // expect: build/distribution contains Prebuilt.xcframework.zip, Source.xcframework.zip, Package.swift;
    //         Package.swift checksum for Prebuilt == sha256 of the zip; root Package.swift == output copy;
    //         Sources/Common/export.swift exists
}
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement builder and CLI.
- [ ] **Step 4:** PASS (both with and without `SWIFTPODS_XCODEBUILD=1`); `swift run swiftpods package --help` shows the options.
- [ ] **Step 5:** Commit "Add swiftpods package to build distribution artifacts".

### Task 9: Per-product link verification

**Files:**
- Create: `Sources/PodsInstaller/Distribution/ProductLinkVerifier.swift`
- Modify: `Sources/PodsInstaller/Distribution/DistributionBuilder.swift`
- Test: `Tests/PodsInstallerTests/DistributionBuilderTests.swift`

**Interfaces:**
- Produces: `struct ProductLinkVerifier { func verify(products: [String], packageDirectory: URL) async throws }`.
  For each product: a scratch dir with a copy of the rendered manifest whose binary targets use
  `path: "<output>/<Name>.xcframework"` (unzipped xcframeworks), plus an iOS app (Xcode project or
  SwiftPM `executableTarget` built with `xcodebuild -scheme`, builder's call) depending on that one
  product, linked with `-ObjC -all_load` as google-mlkit-swiftpm's README tells consumers; build for
  `generic/platform=iOS Simulator` and `generic/platform=iOS`. Failure → `PodsError` naming the
  product and the first undefined symbols from the log.

- [ ] **Step 1: Failing test** (`SWIFTPODS_XCODEBUILD=1`)

```swift
@Test func detectsProductMissingATarget() async throws {
    // fixture distribution where product B needs binary X; remove X from B's targets in the manifest copy
    // → verify throws, message contains "B" and "Undefined symbols"
}
```
and extend `buildsFixtureDistribution` to run verification.

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; wire into `build()`.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit "Verify every distribution product links on its own".

### Task 10: ML Kit acceptance and documentation

**Files:**
- Create: `Tests/PodsInstallerTests/MLKitDistributionTests.swift`
- Modify: `README.md`, `docs/COMPATIBILITY.md`

- [ ] **Step 1: Acceptance test** (`SWIFTPODS_MLKIT=1 SWIFTPODS_XCODEBUILD=1`, reuse `SWIFTPODS_MLKIT_CACHE`):
  write a Podfile.swift equal to the ML Kit one used by `MLKitAcceptanceTests` plus
  `distribution: .init(name: "GoogleMLKitSwiftPM", url: "https://github.com/d-date/google-mlkit-swiftpm")`,
  gtm-session-fetcher `"3.5.0"..<"6.0.0"` and nanopb `"2.30910.0"..<"2.30911.0"` both
  `overridingPodRequirements: .unsafe(reason: …)`; run `DistributionBuilder` with version `9.0.3`.
  Compare with google-mlkit-swiftpm's `Package.swift` at tag `9.0.3` (fetched with `git` into the temp dir):
  same product names (19), same binary target names, same release asset file names and URL prefix;
  per product, target sets equal after removing `Common`'s members from both sides, except
  `MLKitXenoCommon` missing from `MLKitLanguageID`, `MLKitTranslate`, `MLKitSmartReply`; exactly two
  `#warning` lines (gtm-session-fetcher, nanopb); link verification passed. Record in the test's doc
  comment whether the Example app at that tag builds against the generated package with local
  binary targets (manual check, result written down; automate only if it fits in the test).
- [ ] **Step 2:** Run it; fix generalized code (never add ML Kit names to `Sources/`) until green.
- [ ] **Step 3:** Check in Xcode whether a manifest `#warning` is shown for a package dependency;
  document the result.
- [ ] **Step 4:** Docs: README section "Distributing pods as a Swift package" (command, `distribution:`,
  unsafe overrides, narrowing, outputs, resource bundles are separate zips); COMPATIBILITY.md rows
  for `swiftpods package` and the override.
- [ ] **Step 5:** `swift test` green; commit "Add ML Kit distribution acceptance test and document swiftpods package".
