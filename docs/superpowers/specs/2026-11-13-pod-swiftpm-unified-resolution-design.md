# Pod と SwiftPM の混在解決（プロジェクト1）設計

日付: 2026-11-13
状態: 承認済み（2026-11-14）

## 背景と目的

Google ML Kit の pod は prebuilt バイナリで、特定バージョンの依存ライブラリを前提にビルドされている。
前提と違うバージョンの依存がリンクされるとインターフェースが壊れ、実行時にクラッシュする（シンボルが見つからない、など）。

例: `MLKitCommon` は `GTMSessionFetcher/Core (>= 3.3.2, < 4.0)` と `GoogleUtilities (~> 8.0)` を要求する。
一方 d-date/google-mlkit-swiftpm の `Package.swift` は `gtm-session-fetcher "3.5.0"..<"6.0.0"` を許しており、4.x 以降が選ばれると壊れる。

最終目的は **google-mlkit-swiftpm の仕組み（pod → xcframework → SwiftPM 配布）を swiftpods の一般機能にすること**。
次の4プロジェクトに分け、この順で進める。本書は 1 のみを扱う。

1. **Pod と SwiftPM の混在解決**（本書）
2. SwiftPM 配布パッケージの生成（xcframework 化、`Package.swift` 全体の生成、ML Kit 向け補正の一般化）
3. リリース（成果物生成とアップロードの2段階。両方をコマンドで実行でき、ML Kit は CI で回す）
4. アプリ側 Xcode プロジェクトの SwiftPM 依存の固定

最初の合格基準は google-mlkit-swiftpm で使えること。

## ゴール

- Podfile.swift に pod と SwiftPM パッケージを同じファイルで宣言できる。
- pod と SwiftPM パッケージを **自動で** 突き合わせ、同じライブラリなら **SwiftPM に一本化** する（pod としてはインストールしない）。
- 一本化したライブラリに対する pod 側の要求（prebuilt バイナリの前提）を、SwiftPM パッケージのバージョン制約に変換して必ず守る。
- 満たせない組み合わせはビルド前にエラーにし、どの pod のどの要求が衝突したかを示す。
- **不変条件:** 最終的なリンク構成は CocoaPods だけ／SwiftPM だけで組んだ場合と同じ。prebuilt バイナリが前提とするシンボルは、すべて **ちょうど一度** リンクされる（欠ければ実行時クラッシュ、二重なら重複シンボル）。

## 非ゴール

- `Package.swift` 全体の生成、xcframework 化、リリース（プロジェクト2・3）。
- アプリ側 `.xcodeproj` の package reference の追加・書き換え（プロジェクト4）。
- SwiftPM の依存解決器の再実装。

## アンチゴール（動いても失敗とみなすもの）

- 一本化の結果、prebuilt バイナリが前提とするライブラリがリンクされない、または二重にリンクされる。
- 利用者の `.xcodeproj` や、利用者が自前で組んだ `Package.swift` に swiftpods が勝手に手を入れる。
- `Package.resolved` を `App.xcworkspace/xcshareddata/swiftpm/` に置く。
- SwiftPM パッケージを宣言していない既存の Podfile で、挙動や Podfile.lock の内容が変わる（CocoaPods とのバイト一致は維持）。

## 決まったこと

### Podfile.swift の書き方（ユーザー承認済み）

`Package.swift` と同じ形で書く。

```swift
let podfile = Podfile(
    platform: .iOS(.v15),
    packages: [
        .package(url: "https://github.com/google/GoogleUtilities.git", from: "8.0.0"),
        .package(url: "https://github.com/google/gtm-session-fetcher.git", from: "3.0.0"),
        .package(url: "https://github.com/firebase/nanopb.git", from: "2.30910.0"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .pod(name: "MLKitBarcodeScanning", "~> 8.0"),
                .product(name: "GULLogger", package: "GoogleUtilities"),
            ]
        ),
    ]
)
```

- `packages:` は `Package.swift` の `dependencies` と同じ要求の書き方を受け付ける: `from:`、`.upToNextMajor`、`.upToNextMinor`、`"a"..<"b"`、`"a"..."b"`、`exact:`。branch / revision / path の扱いは builder に任せる（ML Kit では不要）。
- target の `dependencies` には `.pod` と `.product(name:package:)` を混ぜて書ける。
- Ruby の `Podfile` / `Podfile.json` での書き方は本プロジェクトの範囲外。

### pod と SwiftPM パッケージの突き合わせ（ユーザー承認済み: 自動）

**git のコミットが一致するか** で判定する。pod の `source` のタグが指すコミットと、SwiftPM パッケージのタグが指すコミットが同じなら、同じライブラリとみなす。
調査で確認した実例:

| ライブラリ | pod のタグ | SwiftPM のタグ | コミット |
| --- | --- | --- | --- |
| GoogleUtilities | `CocoaPods-8.1.0` | `8.1.0` | 60da3616 |
| GoogleDataTransport | `CocoaPods-10.1.0` | `10.1.0` | 617af071 |
| gtm-session-fetcher | `v3.5.0` | `v3.5.0`（SwiftPM は v 付きタグも読む） | a2ab612c |
| promises (PromisesObjC) | `2.4.0` | `2.4.0` | — |
| nanopb | nanopb/nanopb `0.3.9.10`（annotated、deref 後） | firebase/nanopb `2.30910.0` | b7e11045 |

- nanopb のように、リポジトリもバージョン体系も違うことがある。照合は annotated tag を deref したコミットで行う。
- pod の版番号と SwiftPM の版番号が一致するとは限らない（例: 現在 nanopb pod は `3.30910.0`、SwiftPM は `2.30910.0`）。pod の要求範囲は、コミットの対応表を通して SwiftPM の版番号に変換する。
- **判定は厳格（ユーザー確認済み）:** SwiftPM 側で許すのは、pod の要求範囲に含まれ、かつ pod と同じコミットを指すタグがある SwiftPM のバージョンだけ。`CocoaPods-X.Y.Z` タグが podspec 修正用の別コミットに付いていて一致しないバージョンは、許可しない。許可できるバージョンが1つもなければエラーにする。許可するバージョンの集合が連続した区間にならない場合は、集合の最小から最大までの区間を範囲にする。ただし、その区間に入る許可外のバージョンは、手順3の解決結果がそれを選んだ時点でエラーにする（`Package.resolved` で固定するため、実際に使われるのは選ばれたバージョンだけ）。
- どの SwiftPM パッケージにも対応しない pod 依存（例: GoogleToolboxForMac、SSZipArchive）は、今までどおり pod としてインストールする。

### 一本化（ユーザー承認済み: SwiftPM に一本化）

同じライブラリが pod と SwiftPM の両方から来る場合、pod 側は `Pods.xcodeproj` にターゲットを作らない。代わりに SwiftPM パッケージを使い、pod 側の要求は SwiftPM 側の制約として残す。

### 解決の手順（ユーザー承認済み）

1. pod を今までどおり解決する。
2. 一本化した各 SwiftPM パッケージについて、Podfile.swift の範囲と、それに依存するすべての pod の要求（版番号を変換したもの）との共通部分を求める。空ならエラーにする。
3. 最終的なバージョン決定は SwiftPM に任せる。求めた範囲で一時的な `Package.swift` を作り、`swift package resolve` を実行して `Package.resolved` を得る。SwiftPM パッケージ同士の推移的な依存（GoogleDataTransport → nanopb / promises）は SwiftPM がそのまま扱う。
4. 決まったバージョンを記録する（下記「記録」）。

### Xcode プロジェクトへの反映（ユーザー承認済み: 推奨案）

- SwiftPM パッケージの参照は、swiftpods が生成する `Pods.xcodeproj` に package reference として入れる。範囲は手順2で求めたもの。利用者の `.xcodeproj` には触れない。
- 一本化したライブラリを使う pod がソースからビルドされる場合は、その pod ターゲットに SwiftPM の product を依存として付ける（ヘッダーや module を import できるように）。
- prebuilt の pod（ML Kit）が必要とする product は、aggregate ターゲット（`Pods-<Target>`）経由でリンクする（シンボル解決のため）。
- Podfile.swift の target に直接書いた `.product(...)` も、`Pods-<Target>` 経由でリンクする。
- `deintegrate` は、追加した package reference も取り除く。

### 記録（ユーザー指定: `xcshareddata` には置かない）

- 禁止しているのは、アプリの `App.xcworkspace/xcshareddata/swiftpm/Package.resolved` に置くことだけ（ユーザー確認済み）。`Pods/` の下なら `xcshareddata` でもよい。
  - swiftpods は、手順3の `Package.resolved` を `Pods/Pods.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` に書く。これは Xcode / xcodebuild がこのプロジェクトの固定に使う場所で、package reference の範囲は手順2の範囲のままにする。
  - `integrate_targets` が有効で、Xcode がアプリの workspace 側に `Package.resolved` を自分で作る場合の扱いは builder に任せる。ただし swiftpods がそこへ書き込んではならない。
- Podfile.lock には、CocoaPods が無視する新しいセクション（例: `SWIFT PACKAGES:`）で、一本化したパッケージの URL・要求・決定バージョン・コミットを記録する。SwiftPM パッケージがない Podfile では、このセクションを出力しない。
- **builder の確認事項:** CocoaPods 1.17 が未知のトップレベルキーを読み飛ばすことを実際に確かめること。

### 設計者の判断（ユーザー未確認。レビューで指摘があれば変える）

- **Podfile.lock の既存セクション:** 一本化した pod は `PODS`・`SPEC REPOS`・`SPEC CHECKSUMS`・`Pods/Manifest.lock` に載せず、`SWIFT PACKAGES:` にだけ記録する。`DEPENDENCIES` は Podfile に書いた依存のままにする。SwiftPM パッケージを含む Podfile.swift は CocoaPods では読めないので、CocoaPods との整合性はこの場合は気にしない。`outdated` / `update` では、一本化したパッケージを pod の一覧から外す。
- **間接的な SwiftPM パッケージ:** 突き合わせの対象は `packages:` に宣言したものだけでなく、解決後のパッケージグラフに含まれるすべてのパッケージとする（例: GoogleDataTransport 経由で入る nanopb）。宣言しなかった間接パッケージを見逃すと二重リンクになり、不変条件が破れるため。そのため、手順3の解決結果を手順2の照合にも使う（必要なら2回解決する）。
- **リンクの検証:** `use_frameworks! :linkage => :static` では静的ターゲットが何もリンクしないので、`-alltargets` のビルドだけでは不変条件を確かめられない。合格基準に、実際にリンクする検証用ターゲットを追加する（例: ダミーのアプリか dylib に `Pods-MLKit` をリンクし、未解決シンボルと重複シンボルがないこと）。
- **`post_install` フック:** Podfile.swift には書かない。既存の検証（コミット 65fb9bd）では、このフックを無視して警告を出すだけでも、iphoneos・iphonesimulator の両方でビルドが通った。

## 制約

- Swift 6.4、Swift Concurrency を活用する。NSString へのキャストは禁止。外部コマンドは `Shell`（swift-subprocess）経由で実行する。
- 既存の pod のみの経路（Podfile.lock のバイト一致など）を壊さない。
- 実際の依存をなるべく使ったテスト（ローカル git リポジトリで pod / SwiftPM のタグを作る、など）。

## 合格基準（google-mlkit-swiftpm）

- google-mlkit-swiftpm の Podfile を Podfile.swift に書き換え、5パッケージ（promises、GoogleDataTransport、GoogleUtilities、gtm-session-fetcher、nanopb）を `packages:` に宣言する。
- `swiftpods install` で、上の5ライブラリが pod としてインストールされず、自動で SwiftPM に一本化される。
- gtm-session-fetcher の範囲が ML Kit の要求どおり `< 4.0` に絞られる。わざと `"4.0.0"..<"6.0.0"` を宣言するとエラーになり、`MLKitCommon` の `GTMSessionFetcher/Core (< 4.0, >= 3.3.2)` との衝突が示される。
- nanopb の pod 要求（`3.30910.0` 系）が、SwiftPM の `2.30910.0` に変換される。
- `xcodebuild -project Pods/Pods.xcodeproj -alltargets`（Release、iphoneos と iphonesimulator）が成功する。GoogleToolboxForMac と SSZipArchive はこれまでどおりビルドされる。

## builder に任せること

- pod のサブスペック（例: `GoogleUtilities/Logger`）と SwiftPM の product（例: `GULLogger`）の対応付け。モジュール名やソースパスの一致などで決めてよい。ただし不変条件（ちょうど一度リンク）を満たすこと。
- コミット照合のキャッシュ方法と、タグを走査する範囲。
- `.package(...)` の branch / revision / path 指定の扱い。
- エラーメッセージの文言。
