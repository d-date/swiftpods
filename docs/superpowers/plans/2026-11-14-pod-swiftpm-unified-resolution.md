# Pod と SwiftPM の混在解決 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Podfile.swift に SwiftPM パッケージを宣言できるようにし、pod と同じコミット系列のライブラリを SwiftPM に一本化しつつ、prebuilt pod の要求範囲を SwiftPM 側で必ず守らせる。

**Architecture:** pod の解決はこれまでどおり行い、その後に SwiftPM 側を2回解決する。1回目は宣言どおりの範囲で解決し、間接依存を含めたパッケージ一覧を得る。その一覧と pod の source タグを git コミットで突き合わせ、許可するバージョンを厳格に計算する。2回目は計算した範囲で解決し、結果を検証する。一本化した pod は `Pods.xcodeproj` から外し、代わりに `XCRemoteSwiftPackageReference` と product 依存を `Pods.xcodeproj` に入れる。`Package.resolved` は `Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` に書き、結果は Podfile.lock の `SWIFT PACKAGES:` に記録する。

**Tech Stack:** Swift 6.4（strict concurrency）、swift-testing、XcodeProj 9、Yams、swift-subprocess（`Shell`）、`git ls-remote`、`swift package resolve` / `show-dependencies` / `dump-package`。

**Spec:** `docs/superpowers/specs/2026-11-13-pod-swiftpm-unified-resolution-design.md`

## Global Constraints

- Swift 6.4。Swift Concurrency を活用する。`as NSString` のキャストは禁止。外部コマンドは必ず `Shell`（swift-subprocess）経由で実行する。
- コードのコメントは英語で書く。
- SwiftPM パッケージを宣言していない Podfile では、挙動も Podfile.lock の内容も変えない（CocoaPods とのバイト一致を維持）。
- swiftpods は利用者の `.xcodeproj`、利用者の `Package.swift`、`App.xcworkspace/xcshareddata/swiftpm/Package.resolved` に書き込まない。
- 一本化の判定は厳格に行う。許可するのは「pod の要求範囲に含まれる pod バージョンのタグと、同じコミットを指す SwiftPM のタグ」だけ。
- 不変条件: prebuilt バイナリが前提とするシンボルは、すべてちょうど一度リンクされる。
- テストは実物を使う（ローカルの git リポジトリ、実際の `swift package`）。モックは `SpecSource` のメモリ実装だけにとどめる。
- 各タスクの終わりに `swift test` がすべて通り、警告がないこと。

## Review Focus

1. **`v` 付きタグと annotated tag** — gtm-session-fetcher（`v3.5.0`）と nanopb（annotated）でも、deref したコミットで一致する。→ Task 3 `peelsAnnotatedAndVPrefixedTags`
2. **間接依存だけで入るパッケージ** — `packages:` に書いていない nanopb が GoogleDataTransport 経由で入っても、一本化され二重リンクにならない。→ Task 5 `unifiesIndirectPackage`
3. **2回目の解決で許可外のバージョンが選ばれる** — 区間 `min..<max+patch` の中に、許可されていない SwiftPM タグ（podspec を直したコミットのずれ）があり、それが選ばれた場合はエラー。→ Task 4 `rejectsResolvedVersionOutsideAllowedSet`
4. **再インストールで SwiftPM のバージョンが勝手に上がらない** — `install` は前回の `Package.resolved` を使い、`update` のときだけ捨てる。→ Task 5 `reinstallKeepsSwiftPackagePins`
5. **SwiftPM パッケージなしの Podfile は不変** — `SWIFT PACKAGES:` が出力されず、既存の Podfile.lock とバイト一致する。→ Task 2 `omitsSwiftPackagesSectionWhenEmpty`

---

### Task 1: Podfile.swift の `packages:` と `.product(name:package:)`

**Files:**
- Modify: `Sources/SwiftPodsDescription/Podfile.swift`（`Podfile.init`、`Target`、`Pod`、新しい `SwiftPackage`）
- Modify: `Sources/PodsPodfile/Podfile.swift`（モデル）
- Modify: `Sources/PodsPodfile/PodfileJSON.swift`（JSON → モデル）
- Test: `Tests/PodsManifestTests/SwiftManifestTests.swift`、`Tests/PodsPodfileTests/PodfileTests.swift`

**Interfaces:**
- Produces（SwiftPodsDescription、public）:
  - `public struct SwiftPackage: Sendable` と次の static 関数: `package(url:from:)`、`package(url:exact:)`、`package(url:_: Range<String>)`、`package(url:_: ClosedRange<String>)`、`package(url:_: VersionRequirement)`（`.upToNextMinor(from:)` などに使う）。
  - `Podfile.init(..., packages: [SwiftPackage] = [], ...)`。引数の位置は `installationOptions:` の直後、`dependencies:` の前。
  - `Pod.product(name: String, package: String) -> Pod`。target の `dependencies` に `.pod` と混ぜて書ける。
- Produces（JSON 形式）:
  - トップレベルの `"swift_packages": [{"url": String, "requirement": [String]}]`。requirement の要素は CocoaPods 形式の制約で、`VersionRequirement.constraints` と同じ。
  - target の `"swift_package_products": [{"name": String, "package": String}]`。`dependencies` 配列とは別のキーにして、CocoaPods の JSON との互換を保つ。
- Produces（PodsPodfile、public）:
  - `struct SwiftPackageDependency: Sendable, Hashable { let url: String; let requirement: Requirement; var identity: String }`。`identity` は URL の最後のパス要素から `.git` を除き、小文字にしたもの（SwiftPM の identity と同じ）。
  - `struct PackageProductDependency: Sendable, Hashable { let name: String; let package: String }`。
  - `Podfile.swiftPackages: [SwiftPackageDependency]`
  - `TargetDefinition.packageProducts: [PackageProductDependency]`
  - `ResolvedTarget.packageProducts: [PackageProductDependency]`。`:complete` 継承では `dependencies` と同じ規則で親の分も含める。

- [ ] **Step 1: 失敗するテストを書く**

`SwiftManifestTests.evaluatesPodfileWithSwiftPackages`: 次の Podfile.swift を評価する。
```swift
let podfile = Podfile(
    platform: .iOS(.v15),
    packages: [
        .package(url: "https://github.com/google/GoogleUtilities.git", from: "8.0.0"),
        .package(url: "https://github.com/firebase/nanopb.git", .upToNextMinor(from: "2.30910.0")),
        .package(url: "https://github.com/google/gtm-session-fetcher.git", "3.3.2"..<"4.0.0"),
    ],
    targets: [.target(name: "App", dependencies: [
        .pod(name: "MLKitBarcodeScanning", "~> 8.0"),
        .product(name: "GULLogger", package: "GoogleUtilities"),
    ])]
)
```
次を確認する。
- `podfile.swiftPackages.map(\.identity) == ["googleutilities", "nanopb", "gtm-session-fetcher"]`
- 3つの requirement の `lockfileDescription` がそれぞれ `"(< 9.0.0, >= 8.0.0)"`、`"(< 2.30911.0, >= 2.30910.0)"`、`"(< 4.0.0, >= 3.3.2)"`
- `resolvedTargets[0].dependencies.map(\.name) == ["MLKitBarcodeScanning"]`
- `resolvedTargets[0].packageProducts == [PackageProductDependency(name: "GULLogger", package: "GoogleUtilities")]`

`PodfileTests.rejectsProductOfUndeclaredPackage`: `"swift_package_products": [{"name":"X","package":"Missing"}]` を含み、`swift_packages` が空の JSON は、`` `Missing` `` を含む `FormatError` になる。package 名の照合は identity と大文字小文字を区別せずに比べる。

- [ ] **Step 2: 実行して失敗を確認**
Run: `swift test --filter "evaluatesPodfileWithSwiftPackages|rejectsProductOfUndeclaredPackage"`
Expected: コンパイルエラー（`packages:` / `product` がない）

- [ ] **Step 3: 上の Interfaces を実装する**

`Target.json` では、`Pod` を pod と product に分けて出力する。`Pod` に internal の `productPackage: String?` を追加し、`.product` ではここに値を入れる。

- [ ] **Step 4: 実行して成功を確認**
Run: `swift test`
Expected: すべて PASS

- [ ] **Step 5: Commit**
`git commit -m "Let Podfile.swift declare SwiftPM packages and products"`（本文に理由を書き、Co-Authored-By 行を付ける）

---

### Task 2: Podfile.lock の `SWIFT PACKAGES:` セクション

**Files:**
- Modify: `Sources/PodsLockfile/Lockfile.swift`
- Test: `Tests/PodsLockfileTests/LockfileTests.swift`

**Interfaces:**
- Produces:
  - `public struct Lockfile.SwiftPackage: Sendable, Equatable { url: String; requirement: String; version: Version; revision: String; pods: [String] }`
  - `Lockfile.swiftPackages: [SwiftPackage]`（`init` の引数は `specChecksums:` の直後で、既定値は `[]`）

YAML の形式（セクションは `SPEC CHECKSUMS` の直後、`PODFILE CHECKSUM` の前に置く。キーとリストは既存の `YAMLWriter` で並べ替えとクォートをする）:
```yaml
SWIFT PACKAGES:
  https://github.com/google/GoogleUtilities.git:
    pods:
      - GoogleUtilities
    requirement: "< 8.1.1, >= 8.0.0"
    revision: 60da3616...
    version: 8.1.0
```

- [ ] **Step 1: 失敗するテストを書く**
- `swiftPackagesRoundTrip`: 上の形式の文字列を `Lockfile(yaml:)` で読み、`yaml` で書き戻すとバイト一致する。`swiftPackages[0].pods == ["GoogleUtilities"]` であることも確認する。
- `omitsSwiftPackagesSectionWhenEmpty`: 既存の `roundTripIsByteIdentical` のフィクスチャで `swiftPackages.isEmpty` になり、出力に `SWIFT PACKAGES` が含まれない。

- [ ] **Step 2: 実行して失敗を確認**
Run: `swift test --filter LockfileTests`
Expected: コンパイルエラー

- [ ] **Step 3: 読み書きを実装する**

- [ ] **Step 4: 実行して成功を確認**
Run: `swift test --filter LockfileTests`
Expected: PASS

- [ ] **Step 5: CocoaPods がこのセクションを無視することを確かめる（設計書の確認事項）**
Run: `command -v pod && (cd <scratchpad>/cocoapods-lockcheck && pod install)`。手順: pod だけの小さな Podfile で、Podfile.lock に `SWIFT PACKAGES:` を手で追記してから実行する。
Expected: エラーにならず、`SWIFT PACKAGES:` が消える（CocoaPods が書き直すため）。`pod` がない環境では、確認できなかったことを COMPATIBILITY.md の該当行に書く。

- [ ] **Step 6: Commit**

---

### Task 3: git タグ → コミットの索引

**Files:**
- Create: `Sources/PodsInstaller/SwiftPackages/GitTagIndex.swift`
- Test: `Tests/PodsInstallerTests/GitTagIndexTests.swift`

**Interfaces:**
- Produces:
  - `actor GitTagIndex { init(shell: Shell); func tags(of url: String) async throws -> [String: String] }`。戻り値はタグ名 → コミット SHA。annotated tag では `^{}` 行（deref 後）のコミットを使う。同じ URL への2回目以降の呼び出しは、`git ls-remote` を実行せずメモリのキャッシュから返す。
  - `static func swiftPMVersion(fromTag: String) -> Version?`。SwiftPM と同じく、先頭の `v` / `V` を1文字だけ取り除いてから `Version` として解釈する。

- [ ] **Step 1: 失敗するテストを書く**

`peelsAnnotatedAndVPrefixedTags`: `DownloaderTests.makeRepository` と同じ手順でローカル repo を作る。コミットを2つ作り、1つ目に lightweight タグ `CocoaPods-1.0.0` と `1.0.0` を、2つ目に annotated タグ `v2.0.0` を付ける（`git tag -a v2.0.0 -m x`）。次を確認する。
- `tags["1.0.0"] == tags["CocoaPods-1.0.0"]`
- `tags["v2.0.0"] == <2つ目のコミットの rev-parse HEAD>`（タグオブジェクトの SHA ではない）
- `GitTagIndex.swiftPMVersion(fromTag: "v2.0.0") == Version(2, 0, 0)`
- `GitTagIndex.swiftPMVersion(fromTag: "CocoaPods-1.0.0") == nil`

- [ ] **Step 2: 実行して失敗を確認**
- [ ] **Step 3: 実装する**（`Shell.run("git", ["ls-remote", "--tags", url])`）
- [ ] **Step 4: 実行して成功を確認**
- [ ] **Step 5: Commit**

---

### Task 4: 突き合わせと許可範囲の計算（純粋関数）

**Files:**
- Create: `Sources/PodsInstaller/SwiftPackages/PackageUnifier.swift`
- Test: `Tests/PodsInstallerTests/PackageUnifierTests.swift`

**Interfaces:**
- Consumes: なし（入力はすべて値で受け取る）
- Produces:
```swift
struct PackageUnifier {
    struct PodCandidate: Sendable {
        let root: String
        /// Every requirement on the pod, with who declared it (for error messages).
        let requirements: [(origin: String, requirement: Requirement)]
        /// Pod version → commit of its `source` tag, for versions whose source is a git tag.
        let commits: [Version: String]
        /// The pod's source repository, normalized (lowercased, no `.git`, no trailing `/`).
        let repository: String?
    }
    struct PackageCandidate: Sendable {
        let url: String
        let identity: String
        /// From `packages:`; nil for packages that are only indirect.
        let podfileRequirement: Requirement?
        /// SwiftPM version → commit (tags that `swiftPMVersion(fromTag:)` accepts).
        let commits: [Version: String]
    }
    struct Unification: Sendable, Equatable {
        let podRoot: String
        let packageURL: String
        /// Ascending.
        let allowedVersions: [Version]
        let lowerBound: Version
        /// Exclusive: the highest allowed version with its patch component + 1.
        let upperBound: Version
    }
    static func unify(pods: [PodCandidate], packages: [PackageCandidate]) throws(PodsError) -> [Unification]
    /// Checks the version chosen by SwiftPM's second resolution.
    static func verify(_ unification: Unification, resolved: Version) throws(PodsError)
}
```
- 同一判定のルール: 要求範囲を満たす pod バージョンのコミットのどれかが、パッケージのコミット集合に含まれる。または `repository` を正規化したものがパッケージ URL を正規化したものと等しい。どちらかなら同じライブラリとみなす。
- 許可するバージョン: 要求をすべて満たす pod バージョンのコミット集合に、コミットが含まれる SwiftPM バージョン。`podfileRequirement` があれば、それも満たすもの。
- 同じライブラリと判定したのに許可するバージョンが空なら、エラーにする。メッセージには、パッケージ URL、すべての `origin` と requirement、Podfile.swift の要求を並べる。
- 1つの pod が複数のパッケージと一致した場合もエラーにする。

- [ ] **Step 1: 失敗するテストを書く**（コミットは `"c1"` のような短い文字列で表してよい）
- `narrowsGTMSessionFetcherToBinaryRequirement`: pod `GTMSessionFetcher` の requirements は `("MLKitCommon", ">= 3.3.2, < 4.0")`。commits は 3.3.2→c1、3.5.0→c2、4.0.0→c3。パッケージ gtm-session-fetcher の commits は同じ3つで、`podfileRequirement` は nil。期待値は `allowedVersions == [3.3.2, 3.5.0]`、`lowerBound == 3.3.2`、`upperBound == 3.5.1`。
- `mapsNanopbAcrossVersionSchemes`: pod `nanopb` の 3.30910.0→b7e1 と、パッケージ firebase/nanopb の 2.30910.0→b7e1。期待値は `allowedVersions == [2.30910.0]`。
- `reportsConflictWithPodfileRequirement`: 上の GTM に `podfileRequirement = ">= 4.0.0, < 6.0.0"` を加える。投げられたエラーの文言に `MLKitCommon`、`< 4.0, >= 3.3.2`、`gtm-session-fetcher` が含まれる。
- `skipsPodCommitsWithoutMatchingTag`: pod 8.1.0→cX（`CocoaPods-8.1.0` が podspec 修正用の別コミット）、8.0.0→c0 と、SPM 8.1.0→cY、8.0.0→c0。期待値は `allowedVersions == [8.0.0]`。
- `leavesUnrelatedPodsAlone`: commits も repository も一致しない pod では、結果が空になる。
- `rejectsResolvedVersionOutsideAllowedSet`: allowed が [8.0.0, 8.2.0]（区間は 8.0.0..<8.2.1）で、`verify(_, resolved: 8.1.0)` がエラーになる。

- [ ] **Step 2: 実行して失敗を確認**
- [ ] **Step 3: 実装する**
- [ ] **Step 4: 実行して成功を確認**
- [ ] **Step 5: Commit**

---

### Task 5: SwiftPM の解決と Analyzer への組み込み

**Files:**
- Create: `Sources/PodsInstaller/SwiftPackages/SwiftPackageResolver.swift`
- Modify: `Sources/PodsInstaller/Analyzer.swift`（`Resolution`、`Analysis`、`resolveDependencies()`、`analyze()`）
- Test: `Tests/PodsInstallerTests/SwiftPackageTests.swift`（新規。ローカル git repo のフィクスチャを持つ）

**Interfaces:**
- Consumes: Task 1 の `Podfile.swiftPackages`、Task 3 の `GitTagIndex`、Task 4 の `PackageUnifier`
- Produces:
```swift
struct SwiftPackageResolver {
    struct Pin: Sendable, Equatable { let identity: String; let url: String; let version: Version; let revision: String }
    struct Result: Sendable {
        let pins: [Pin]
        /// identity → names of the package's library products.
        let libraryProducts: [String: [String]]
        /// Raw `Package.resolved` contents.
        let resolvedFile: Data
    }
    init(workDirectory: URL, shell: Shell)
    /// `requirements` maps a package URL to its range. `previousResolved` is copied in first so pins are kept.
    func resolve(_ requirements: [(url: String, lowerBound: Version?, upperBound: Version?, requirement: Requirement?)],
                 previousResolved: Data?) async throws -> Result
}
```
  - 一時的な `Package.swift`（`swift-tools-version: 5.9`）を `workDirectory` に書く。`dependencies` だけを持ち、範囲は `.package(url:, "a"..<"b")` で表す。`Requirement` しかない場合は、`>=` と `<` の制約から同じ形に変換する。変換できない形（`!=` など）はエラーにする。
  - `swift package resolve` を実行し、`Package.resolved` の pins を読む（v2 と v3 の両方の形式）。
  - `swift package show-dependencies --format json` で各 checkout のパスを得て、`swift package dump-package --package-path <path>` から `type.library` の product 名を取る。
  - `workDirectory` は `cacheRoot/SwiftPackages/<Podfile のパスの SHA1>`。
- Produces（Analyzer）:
  - `Analysis.unifications: [PackageUnifier.Unification]`、`Analysis.swiftPackages: SwiftPackageResolver.Result?`（パッケージの宣言がなければ nil）。
  - 一本化した pod は `Analysis.pods` に含めず、ダウンロードもしない。

Analyzer の手順（`resolveDependencies()` で pod を解決した後に行う）:
1. `podfile.swiftPackages` が空なら何もしない（既存の経路から1行も変えない）。
2. 1回目の解決: 宣言した要求のまま `resolve`。`previousResolved` は `options.update == .none` のときだけ `Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` から読む。
3. 1回目のすべての pin（間接依存を含む）について `GitTagIndex.tags(of: pin.url)` を求め、`PackageCandidate` を作る。
4. 解決したすべての pod のうち source が git タグのものについて、`PodCandidate` を作る。
   - requirements: 解決したすべての pod の activated specs の `dependencies(for:)` と、Podfile の依存のうち、rootName が一致するもの。origin は依存を宣言した spec 名か `"Podfile"`。
   - commits: `SourcesManager.candidates(for:)` のうち requirements をすべて満たすバージョンの spec の `source` タグを、`GitTagIndex` で引いた結果。
5. `PackageUnifier.unify` を呼ぶ。
6. 2回目の解決: 宣言したパッケージと一本化したパッケージのすべてについて、一本化したものは `lowerBound..<upperBound` で、それ以外は宣言どおりの要求で `resolve`。`previousResolved` の扱いは手順2と同じ。
7. 一本化した各パッケージの pin を `PackageUnifier.verify` で検証する。

- [ ] **Step 1: フィクスチャと失敗するテストを書く**

フィクスチャ `SwiftPackageFixture.create(in:)` は、ローカル git repo を3つ作る。
- `Lib`: `Package.swift`（library product `LibCore`）、`Lib.podspec`、`Sources/LibCore/Lib.m`、`include/Lib.h` を持つ。タグは `1.0.0`、`CocoaPods-1.0.0`（同じコミット）、`2.0.0`。
- `Wrapper`: `Package.swift` が `Lib` に `from: "1.0.0"` で依存する。タグは `1.0.0`。
- `Binary`: `:path` pod。podspec が `s.dependency 'Lib', '~> 1.0'` を宣言する。

pod の spec は `SourcesTests` / `OutdatedTests` と同じメモリの `SpecSource` で提供し、`Lib` の podspec の source には `:git => file://…/Lib, :tag => 'CocoaPods-1.0.0'` を入れる。

テスト:
- `unifiesDeclaredPackage`: Podfile.swift で `packages: [.package(url: "file://…/Lib", from: "1.0.0")]` と `pod 'Binary'` を宣言する。install の結果、`analysis.pods` に `Lib` が含まれない。unification は `allowedVersions == [1.0.0]`、`upperBound == 1.0.1`。pin の `version == 1.0.0`（2.0.0 は pod の `~> 1.0` で除外される）。
- `unifiesIndirectPackage`: `packages:` には `Wrapper` だけを宣言する。`Lib` は間接依存として一本化される。
- `failsWhenPodfileRangeExcludesBinaryRequirement`: `packages:` に `Lib` を `from: "2.0.0"` で宣言すると、`Binary` と `~> 1.0` を含むエラーになる。
- `reinstallKeepsSwiftPackagePins`: 1回目の install の後で `Lib` に `1.0.1`（`CocoaPods-1.0.1` と同じコミット）を追加する。もう一度 `install` しても pin は `1.0.0` のまま。`update` では `1.0.1` になる。

- [ ] **Step 2: 実行して失敗を確認**
Run: `swift test --filter SwiftPackageTests`
Expected: コンパイルエラー

- [ ] **Step 3: `SwiftPackageResolver` を実装する**
- [ ] **Step 4: Analyzer に組み込む**
- [ ] **Step 5: 実行して成功を確認**
Run: `swift test`
Expected: すべて PASS（既存の Installer / Outdated テストも含む）
- [ ] **Step 6: Commit**

---

### Task 6: `Pods.xcodeproj`・`Package.resolved`・Podfile.lock への反映

**Files:**
- Modify: `Sources/PodsInstaller/InstallationPlan.swift`（`PodTarget.packageProducts`、`AggregateTarget.packageProducts`、`InstallationPlan.swiftPackages`）
- Modify: `Sources/PodsInstaller/TargetBuilder.swift`（`specClosure` が一本化した root を飛ばす。product を割り当てる）
- Modify: `Sources/PodsInstaller/PodsProjectGenerator.swift`（package reference と product 依存）
- Modify: `Sources/PodsInstaller/Installer.swift`（`Package.resolved` を書く。`makeLockfile` で `SWIFT PACKAGES:` を出す）
- Modify: `docs/COMPATIBILITY.md`、`README.md`
- Test: `Tests/PodsInstallerTests/SwiftPackageTests.swift`

**Interfaces:**
- Consumes: Task 5 の `Analysis.unifications`、`Analysis.swiftPackages`、Task 2 の `Lockfile.SwiftPackage`
- Produces:
  - `struct PackageProductRef: Sendable, Hashable { let packageURL: String; let product: String }`
  - `PodTarget.packageProducts: [PackageProductRef]`: その pod の specs が依存する一本化 root ごとに、そのパッケージのすべての library product（`Result.libraryProducts`）を入れる。
  - `AggregateTarget.packageProducts: [PackageProductRef]`: 次の和集合。
    - リンクするすべての pod target の `packageProducts`（推移的に辿る）
    - ユーザーが書いた `ResolvedTarget.packageProducts`（package 名は identity と比べて URL に変換する）
  - `InstallationPlan.swiftPackages: [(url: String, lowerBound: Version, upperBound: Version)]`: `XCRemoteSwiftPackageReference` の `versionRequirement: .range(from:to:)` に使う。一本化していない宣言パッケージは、`Requirement` の `>=` / `<` から同じ形を作る。

ルール:
- product は、pod target と aggregate target の両方で `XCSwiftPackageProductDependency` として持たせる。PBXFrameworksBuildPhase に入れるのは aggregate target だけ（リンクは一度だけ）。
- `Package.resolved` は `Result.resolvedFile` をそのまま `Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` に書く。
- Podfile.lock の `SWIFT PACKAGES:` には、2回目の解決で得たすべての pin を書く。`pods` は、そのパッケージに一本化した pod の root 名（なければ空）。`requirement` は `XCRemoteSwiftPackageReference` に入れた範囲を、`Requirement.lockfileDescription` と同じ書式で書く。一本化した pod は `PODS`・`SPEC REPOS`・`SPEC CHECKSUMS` に載せない。
- `deintegrate` は `Pods/` を丸ごと消すので、package reference も消える。テストで確かめるだけで、コードの変更は不要。

- [ ] **Step 1: 失敗するテストを書く**（`unifiesDeclaredPackage` のフィクスチャを使う）
- `writesPackageReferencesIntoPodsProject`: `Pods.xcodeproj` を XcodeProj で開いて、次を確認する。
  - `rootObject.remotePackages` が1件で、`repositoryURL` が Lib の URL、要求が `.range(from: "1.0.0", to: "1.0.1")`。
  - `Binary` target の `packageProductDependencies.map(\.productName) == ["LibCore"]`。
  - `Pods-App` target の frameworks phase に `LibCore` がちょうど1件ある。
  - `Lib` という名前の native target がない。
- `writesPackageResolvedUnderPods`: `Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` が存在する。`App.xcworkspace/xcshareddata/swiftpm/Package.resolved` は存在しない。
- `recordsSwiftPackagesInLockfile`: `lockfile.swiftPackages[0].pods == ["Lib"]`、`version == 1.0.0`。`lockfile.podNames` に `Lib` が含まれない。
- `deintegrateRemovesPackageReferences`: `Deintegrator` を実行した後、`Pods/` が存在しない。
- `linksUnifiedPackageOnce`（`SWIFTPODS_XCODEBUILD=1` のときだけ実行）: フィクスチャの App を、iphonesimulator 向けに `xcodebuild -workspace App.xcworkspace -scheme App build` でビルドする。App.swift から `Binary` の関数を呼び、その関数は `Lib` の関数を呼ぶ。期待値はビルド成功で、ログに `duplicate symbol` も `Undefined symbols` も含まれないこと。

- [ ] **Step 2: 実行して失敗を確認**
- [ ] **Step 3: TargetBuilder と InstallationPlan を実装する**
- [ ] **Step 4: PodsProjectGenerator を実装する**
- [ ] **Step 5: Installer（`Package.resolved` と lockfile）を実装し、COMPATIBILITY.md と README に Podfile.swift の `packages:` と一本化の説明を追記する**
- [ ] **Step 6: 実行して成功を確認**
Run: `swift test && SWIFTPODS_XCODEBUILD=1 swift test --filter "linksUnifiedPackageOnce|buildsIntegratedWorkspace"`
Expected: すべて PASS
- [ ] **Step 7: Commit**

---

### Task 7: google-mlkit-swiftpm での合格確認

**Files:**
- Create: `Tests/PodsInstallerTests/MLKitAcceptanceTests.swift`（`SWIFTPODS_MLKIT=1` のときだけ実行。ネットワークを使う）
- 作業場所: `<scratchpad>/mlkit`（既存の clone。`~/ghq/.../google-mlkit-swiftpm` には触らない）

**Interfaces:**
- Consumes: Task 1〜6 のすべて

- [ ] **Step 1: 合格テストを書く**

`mlkitPodsUnifyOnSwiftPM`:
1. 一時ディレクトリに `FixtureProject.create`（iOS 15.5）で App を作る。
2. 次の Podfile.swift を書く。
   - mlkit の Podfile の19個の `GoogleMLKit/*`（`~> 9.0.0`）と、`useFrameworks: .static` を書く。
   - `packages:` には次の5つを書く。
     - promises: `from: "2.4.0"`
     - GoogleDataTransport: `from: "10.1.0"`
     - GoogleUtilities: `from: "8.1.0"`
     - gtm-session-fetcher: `"3.5.0"..<"6.0.0"`（現行の `Package.swift` と同じ広い範囲）
     - firebase/nanopb: `.upToNextMinor(from: "2.30910.0")`
   - 統合を有効にするため、`integrateTargets` は指定しない。
3. `install` を実行し、次を確認する。
   - `analysis.pods` に GoogleUtilities、GoogleDataTransport、GTMSessionFetcher、nanopb、PromisesObjC が含まれない。GoogleToolboxForMac と SSZipArchive は含まれる。
   - gtm-session-fetcher の unification の `upperBound <= Version(4, 0, 0)`。
   - nanopb の pin の version の major が `2`。

`mlkitRejectsGTM4`: gtm-session-fetcher を `"4.0.0"..<"6.0.0"` で宣言すると、`MLKitCommon` と `< 4.0` を含むエラーになる。

`mlkitAppLinks`（`SWIFTPODS_XCODEBUILD=1` も必要）:
- 上の App.swift に `import MLKitBarcodeScanning` を書き、`_ = BarcodeScanner.barcodeScanner()` を置く。
- `xcodebuild -workspace App.xcworkspace -scheme App -sdk iphonesimulator build` が成功し、`duplicate symbol` も `Undefined symbols` も出ないこと。
- CocoaPods が付ける `-ObjC` によって ML Kit のすべてのオブジェクトがロードされるので、前提のシンボルが欠けていればここで失敗する。

- [ ] **Step 2: 実行して結果を確認**
Run: `SWIFTPODS_MLKIT=1 SWIFTPODS_XCODEBUILD=1 swift test --filter MLKitAcceptanceTests`
Expected: 3件 PASS。失敗した場合は superpowers:systematic-debugging で原因を調べ、修正は再現テストを先に書いてから、該当するタスクのファイルで行う。

- [ ] **Step 3: mlkit の clone で CLI を実際に動かす**
`<scratchpad>/mlkit` に `Podfile.swift` を置く（上と同じ内容。ただし mlkit と同じく `integrateTargets: false`）。次を実行する。
- `swift build -c release`
- `<release>/swiftpods install`
- `xcodebuild -project Pods/Pods.xcodeproj -alltargets -configuration Release -sdk iphoneos build`
- 同じコマンドを `-sdk iphonesimulator` で実行する

Expected: 両方の SDK でビルドが成功する。`Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` が存在する。Podfile.lock に `SWIFT PACKAGES:` があり、5パッケージが記録される。

- [ ] **Step 4: Commit**（テストファイルのみ。scratchpad の内容はコミットしない）
