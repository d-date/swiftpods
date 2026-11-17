# Distribution package generation — design

Status: draft (2026-11-17). Project 2 of 4 in the ML Kit generalization roadmap
(project 1: `2026-11-13-pod-swiftpm-unified-resolution-design.md`).

## Intent

`d-date/google-mlkit-swiftpm` turns CocoaPods-only, prebuilt ML Kit into a SwiftPM package:
`pod install` → `xcodebuild` per SDK → xcframeworks → post-processing → zips → a hand-maintained
`Package.swift` with binary targets. The pipeline is a Makefile plus ~20 Ruby scripts with ML Kit
lists hard-coded (31 prebuilt frameworks, 2 source pods, Info.plist templates, product closures,
dependency bound overrides).

This project makes swiftpods do that generically: from a Podfile.swift, produce the distribution
artifacts (xcframework zips, resource bundle zips) and the **whole** `Package.swift`. Releasing
(tag, GitHub Release, upload) is project 3 and out of scope here.

Why it matters: ML Kit binaries are prebuilt. Linking a dependency outside what they were built
against, missing a framework from a product, or a broken binary shape crashes at runtime or fails
App Store validation. Today those rules live in people's heads and scripts; each one was learned
from an incident (#106, #109, #110, #124, ITMS-91065, "Invalid model path.", missing Info.plist).

## Success criteria

* For google-mlkit-swiftpm, the generated `Package.swift` keeps the same package URL, the same 19
  library product names and the same binary target names and release asset file names as the
  current one (9.0.3). Known, accepted difference: `MLKitLanguageID`, `MLKitTranslate` and
  `MLKitSmartReply` no longer list `MLKitXenoCommon` (the ML Kit 9.0 pod graph does not reach it
  from them; per-product link verification must pass without it).
* The repo's Example app builds against the generated package.
* Every generated product links on its own (per-product link verification passes).
* The repo's Makefile and Ruby scripts are no longer needed for building artifacts and
  `Package.swift` (release scripts go in project 3).

## Goals

1. A command that builds the pods and produces, in one output directory:
   `<Module>.xcframework.zip` for every binary target, `<Bundle>.bundle.zip` for every resource
   bundle, and `Package.swift` plus the `Common` target's source file.
2. Products and targets derived automatically from the Podfile's pod declarations (decided by the
   user for google-mlkit-swiftpm). An explicit override is possible for other projects but ML Kit
   does not use it.
3. Dependency ranges in the generated `Package.swift` that consumers' SwiftPM cannot resolve to a
   version the pods do not accept (narrowing, below), except where the Podfile declares an unsafe
   override, which is then flagged with `#warning`.
4. The ML Kit binary fixes, generalized (no per-module lists): Info.plist generation, arm64
   simulator slice injection, object-file → `ar` conversion, source pods as library xcframeworks.
5. Per-product link verification run by the command after generation.

## Non-goals

* Tagging, GitHub Releases, uploading, CI workflows (project 3). The command only needs the
  release download URL pattern to write binary target URLs.
* Checking at runtime that ML Kit APIs still work with an unsafe override: that stays in
  google-mlkit-swiftpm (decided by the user).
* Shipping resource bundles inside the SwiftPM package. They stay separate zips the consumer adds
  to the app (decided by the user: keep the current scheme).
* Platforms other than iOS (ML Kit is iOS only). The design should not preclude them, nothing more.
* Pinning the consuming app's SwiftPM dependencies (project 4).

## Anti-goals

* A generated package that resolves, builds, then crashes because a consumer picked a dependency
  version between the min and max that no pod version accepts.
* A product that only links because some other product pulled in what it needed (#110).
* Any ML Kit name hard-coded in swiftpods.
* Silently widening a range beyond what the pods accept.

## Decisions made with the user

### Unsafe overrides of pod requirements

* A Swift package declared in Podfile.swift may opt out of the pod-derived range. The first user:
  gtm-session-fetcher `"3.5.0"..<"6.0.0"`, while ML Kit's pods require `< 4.0` (widened by a human
  after checking the ABI, for Firebase 13: google-mlkit-swiftpm #124/#125).
* For such a package, the generated `Package.swift` uses the declared range and emits a `#warning`
  that says the range is outside what the pods accept and ABI compatibility is unsafe/unverified.
  Verified in a spike: a manifest-level `#warning` is printed to consumers by
  `swift package resolve` (also when the package is a dependency), on manifest (re)evaluation only.
  Whether Xcode shows it in its UI was not checked — check during implementation and record the
  result in docs.
* The second user, nanopb: ML Kit's pod nanopb 3.30910.0 points at the same commit as SwiftPM tag
  `2.30910.0` only (`2.30910.1` is a Firebase fork commit), so strict narrowing gives
  `exact: "2.30910.0"`, while Firebase 13.1.1 requires `"2.30910.1"..<"2.30911.0"`. The ML Kit
  Podfile.swift declares nanopb `"2.30910.0"..<"2.30911.0"` as an unsafe override too (decided by
  the user), so the Example app (ML Kit + Firebase 13.1.1) keeps resolving. GoogleUtilities,
  GoogleDataTransport and promises need no override: Firebase's lower bounds fall inside their
  allowed runs.
* Whether ML Kit APIs actually work with the widened range is verified in google-mlkit-swiftpm,
  not by swiftpods.
* In `install` (project 1), an overridden package is resolved within its declared range instead
  of the narrowed range, and swiftpods prints a warning naming the package, the pods' range and the
  declared range, instead of failing. Packages without an override keep project 1's strict
  behaviour.

### Contiguous range narrowing

A `Package.swift` requirement is one interval, so a range from the lowest to the highest allowed
version can contain versions no pod version accepts (no tag at a commit a matching pod version
points at). The user chose to narrow instead of warn:

* Take the allowed versions (project 1's `PackageUnifier` computes them from tags and pod
  versions), sorted, and all tagged release versions of the package in between. The range is the
  maximal run of consecutive allowed versions — no disallowed tagged version inside — that contains
  the pinned version, written as a closed range `"lo"..."hi"`.
* A run of one version is written as `exact:`.
* Overridden packages are not narrowed (declared range + `#warning`).
* A closed upper bound means new upstream releases are never picked up automatically; they come in
  with the next generation. (This is the safe reading of "the pods accept it" at generation time.)

### Products and targets (auto-derived)

Verified against the current repo: this reproduces all 19 product names and 16 of the 19 target
lists exactly (the 3 differences are the `MLKitXenoCommon` entries above).

* One product per pod declared in the Podfile's target. For a declared subspec of an umbrella pod
  (`GoogleMLKit/BarcodeScanning`), the product is the pod the subspec depends on directly outside its
  own root (`MLKitBarcodeScanning`); for a declared non-umbrella pod, the pod itself. The rule for
  "umbrella" and for a subspec that directly depends on several pods is the builder's call; ML Kit
  has exactly one such pod per declared subspec (`MLKit*`).
* A product's targets: the binary targets in the transitive pod closure of its pod, minus those
  moved to `Common`, plus `Common`.
* `Common`: a source target (`@_exported import` of its members, as today's
  `Sources/Common/export.swift` with `@_exported import MLKitCommon`) depending on the binary targets
  every product needs and on the library products of the unified Swift packages. For ML Kit that is
  `MLKitCommon`, `GoogleToolboxForMac` and the 5 packages. How "every product needs" is computed
  (intersection of closures, or closure of a shared umbrella subspec such as `GoogleMLKit/MLKitCore`)
  is the builder's call as long as ML Kit's result is `MLKitCommon` + `GoogleToolboxForMac`.
* Pods unified with Swift packages (project 1) are not binary targets; they become
  `dependencies:` entries.

### Binary fixes (generalized from the ML Kit scripts)

All decided by inspecting files, not by names:

* **Prebuilt frameworks** (`vendored_frameworks`) without an `Info.plist` (all 31 in ML Kit 9.0
  ship none) get a generated one: `CFBundleExecutable`, `CFBundleName`, `CFBundleIdentifier`,
  `CFBundlePackageType` = `FMWK`, `CFBundleShortVersionString` = pod version, `CFBundleVersion`,
  `CFBundleSupportedPlatforms`, `MinimumOSVersion`. Without one, a SwiftPM consumer crashes at
  launch ("The bundle doesn't contain…"). Replaces `Resources/*-Info.plist`.
* **arm64 simulator slice**: if a prebuilt binary has a device arm64 slice but no simulator arm64
  slice, create it by rewriting `LC_BUILD_VERSION`'s platform (2 → 7) in place, in thin Mach-O files
  and in every member of thin `ar` archives, keeping archive member layout (ML Kit archives have
  duplicate member names such as three `globals.o` in MLKitCommon, which an extract/repack loses).
  Must run before the `ar` conversion. Reference: `scripts/patch_macho_platform.rb`,
  `scripts/postprocess_xcframeworks.rb`.
* **Object-file binaries → `ar` archives**: a framework binary that is a bare `MH_OBJECT` is treated
  by Xcode as dynamic and relinked with dead-stripping, which dropped MLKitTextRecognitionCommon's
  ~60 MB OCR model ("Invalid model path."). Convert to an `ar` archive.
* **Source-built pods** become library xcframeworks (`lib<Name>.a` + headers), not framework
  bundles: Xcode embeds a stub for every static framework bundle, and embedded copies of "commonly
  used third-party SDKs" are rejected with ITMS-91065 (missing signature). ML Kit: GoogleToolboxForMac,
  SSZipArchive.
* **Resource bundles**: every `resource_bundles` entry of the pods (`Pods/<pod>/Resources/<Name>/`)
  plus bundles nested in prebuilt frameworks, each zipped as `<Name>.bundle.zip`, deduplicated by
  name (ML Kit SmartReply nests `PredictOnDevice_resource` while its podspec key is
  `PredictOnDeviceResource`; both names ship today — keep shipping both).

### Build

* `install` (with `integrate_targets: false`), then `xcodebuild -project Pods/Pods.xcodeproj
  -alltargets -configuration Release` once per SDK (iphoneos, iphonesimulator) with
  `ONLY_ACTIVE_ARCH=NO`, `ENABLE_TESTABILITY=NO`, `CLANG_ENABLE_MODULE_DEBUGGING=NO`, a `SYMROOT`
  (required with Swift packages, see COMPATIBILITY.md) and the deployment target from the Podfile's
  `platform`. Run with swift-subprocess like the rest of swiftpods.

## My calls (not discussed with the user; flag if wrong)

* **Command**: `swiftpods package` (name provisional), inputs Podfile.swift + Podfile.lock,
  options `--version <distribution version>` (required) and `--output <dir>`. The distribution
  version (9.0.3) is separate from the ML Kit version (9.0.0) and chosen by a human per release
  (9.0.3 re-released identical binaries only to ship a range fix), so it is a command-line input, not
  a Podfile field.
* **Distribution settings in Podfile.swift**, Package.swift-style:
  `distribution: .init(name: "GoogleMLKitSwiftPM", url: "https://github.com/d-date/google-mlkit-swiftpm")`.
  Binary target URLs are `<url>/releases/download/<version>/<file>`. JSON Podfile equivalent: a
  `distribution` key. Not available in the Ruby Podfile DSL.
* **Override syntax**: `.package(url: …, "3.5.0"..<"6.0.0", overridingPodRequirements: .unsafe(reason: "…"))`.
  The reason is included in the `#warning` and in `install`'s warning.
* **Output layout**: zips and a copy of the manifest in `--output` (default `build/distribution`);
  `Package.swift` and `Sources/Common/export.swift` are written to the Podfile's directory, since
  the package must stay at the repo root (same URL). Stale files are not deleted outside these paths.
* **Generated Package.swift**: `swift-tools-version` 5.9 (what ML Kit consumers use today; the
  generated manifest needs nothing newer), `platforms` from the Podfile's `platform`, products in
  Podfile declaration order, deterministic output (same inputs → byte-identical file), a header
  comment saying it is generated by swiftpods and should not be edited by hand.
* **Info.plist `CFBundleIdentifier`**: `org.cocoapods.<Module>` by default (the identifiers in the
  current templates, e.g. `com.google.firebase.mlkit.vision`, come from old ML Kit builds and are not
  derivable). Checked 2026-11-17 against the ML Kit 9.0 binaries: none contains its template's
  identifier, and none references `bundleWithIdentifier:`; they find resources with
  `bundleForClass:` / `mainBundle` (+ `pathForResource:ofType:` / `URLForResource:withExtension:`),
  which do not depend on `CFBundleIdentifier`. Remaining risk is covered by the runtime check in
  google-mlkit-swiftpm (including text recognition, which loads a model) before the first release
  built this way (project 3); if it fails, add an identifier override.
* **Per-product link verification**: for each product, a scratch app package depending on only that
  product, using local binary targets (`path:` to the produced xcframeworks) so it runs before any
  upload, built for the iOS simulator and device with `xcodebuild`. Fails the command on undefined
  symbols. `--skip-verification` for quick iterations.
* **Which library products of a unified package `Common` links**: project 1 links all of them; the
  current ML Kit manifest lists 8 GoogleUtilities products. Linking all is acceptable if link
  verification passes; matching subspecs to products is the builder's call.

* **Product target lists** omit the members of `Common` (they come through `Common`); today's
  manifest also lists `MLKitCommon`/`GoogleToolboxForMac` explicitly in `MLKitLanguageID`,
  `MLKitTranslate` and `MLKitSmartReply`. The ML Kit acceptance test compares target lists as sets,
  with `Common`'s members removed from both sides, so the only accepted difference stays
  `MLKitXenoCommon`.
* **google-mlkit-swiftpm itself is not changed in this project.** Committing a Podfile.swift with
  `distribution:` and the overrides, replacing its `Package.swift` and `Sources/Common/export.swift`,
  and removing the Makefile, Ruby scripts, `Resources/*-Info.plist` and the `xcframework-maker`
  submodule happen with project 3 (release and CI), as a PR the user reviews. Here the ML Kit
  acceptance test writes its own Podfile.swift into a temp dir, as in project 1.
* **Artifacts are built once.** Project 3's first stage is this command; its second stage uploads
  exactly the zips this command wrote, with the checksums already in `Package.swift`. So builds and
  zips need not be reproducible byte for byte; "deterministic output" means rendering the same data
  gives the same `Package.swift`.

## Open points for the builder

* The Podfile says `platform :ios, '15.5'` but the current manifest says `.iOS(.v15)` and the
  Makefile builds with deployment target 15.0. Generated `platforms` follow the Podfile; check what
  ML Kit 9's pods require and adjust google-mlkit-swiftpm's Podfile.swift, not swiftpods.
* Xcode UI display of manifest `#warning` (see above).

## Testing

* Unit tests (default `swift test`): narrowing (runs, single version → `exact:`, overridden package
  untouched), product/target derivation from a lockfile fixture, Info.plist generation, Mach-O
  platform rewrite on clang-built thin objects and `ar` archives with duplicate member names,
  object → `ar` conversion, Package.swift rendering (golden file), override parsing in Podfile.swift
  and JSON, `install` warning instead of error for an overridden package.
* Opt-in (`SWIFTPODS_XCODEBUILD=1`): a small fixture distribution end to end, including per-product
  link verification.
* Opt-in ML Kit acceptance (`SWIFTPODS_MLKIT=1`): generate for google-mlkit-swiftpm and compare with
  the current `Package.swift` (names, URLs, target lists modulo the 3 accepted differences), then
  build the Example app against the generated package with local binary targets.

## References in google-mlkit-swiftpm

`Makefile`, `scripts/postprocess_xcframeworks.rb`, `scripts/patch_macho_platform.rb`,
`scripts/check_product_closure.rb`, `scripts/update_package_dependencies.rb`
(`UPPER_BOUND_OVERRIDES`), `scripts/update_checksums.rb`, `Resources/*-Info.plist`,
`Sources/Common/export.swift`, `.github/workflows/build-mlkit.yml`, `AUTOMATION.md`.
