# Compatibility with CocoaPods

SwiftPods aims to be a drop-in replacement for `pod install` / `pod update`. This page lists
what is implemented and where behaviour differs. When adding a feature, update this file.

Legend: ✅ supported · ⚠️ partial · ❌ not supported

## Files

| Item | Status | Notes |
| --- | --- | --- |
| `Podfile` (Ruby DSL) | ✅ | Evaluated by the built-in Ruby-subset interpreter (`PodsDSL`) |
| `Podfile.json` (`pod ipc podfile-json` format) | ✅ | |
| `Podfile.yaml` | ❌ | |
| `Podfile.swift` | ✅ | SwiftPods extension |
| `*.podspec` (Ruby DSL) | ✅ | |
| `*.podspec.json` | ✅ | Canonical format |
| `*.podspec.swift` | ✅ | SwiftPods extension; `spec json` converts it for trunk |
| `Podfile.lock` / `Pods/Manifest.lock` | ✅ | Byte-identical output, including `SPEC CHECKSUMS`; the `COCOAPODS:` version of an existing lockfile is kept |

## Podfile DSL

| Directive | Status | Notes |
| --- | --- | --- |
| `source` | ✅ | CDN trunk; git spec repos. The `CocoaPods/Specs` git URL is served by the CDN |
| `platform` | ✅ | Inferred from the user project when omitted |
| `target`, `abstract_target`, `abstract!` | ✅ | |
| `inherit! :complete / :none / :search_paths` | ✅ | |
| `pod` with requirements | ✅ | `~>`, `>=`, `<`, `=`, `!=`, combined |
| `pod` `:path`, `:git` (`:tag`/`:branch`/`:commit`), `:podspec` | ✅ | Branch checkouts are locked to a commit in `CHECKOUT OPTIONS` |
| `pod` `:subspecs`, `:configurations`, `:modular_headers`, `:inhibit_warnings`, `:source` | ✅ | `:testspecs` / `:appspecs` are parsed but test/app specs are not integrated |
| `use_frameworks!` (`:linkage => :static / :dynamic`) | ✅ | |
| `use_modular_headers!` | ✅ | Module maps are generated for every Objective-C static library anyway |
| `inhibit_all_warnings!` | ✅ | |
| `project` (with build configuration mapping) | ✅ | |
| `workspace` | ✅ | |
| `install! 'cocoapods', integrate_targets: false` | ✅ | No user project is needed; the Podfile must specify `platform`. Other installation options are accepted and ignored |
| `pre_install`, `post_install`, `pre_integrate`, `post_integrate` | ❌ | Reported as warnings; Ruby code cannot run |
| `plugin` | ❌ | Reported as warnings |
| `podspec` directive | ⚠️ | Recorded as a `:path` dependency |
| `generate_multiple_pod_projects` | ❌ | One `Pods.xcodeproj` is generated |

## Podspec attributes

| Attribute | Status | Notes |
| --- | --- | --- |
| Root attributes (`name`, `version`, `source`, `license`, `platforms`, `swift_versions`, `module_name`, `header_dir`, `static_framework`, …) | ✅ | |
| `source_files`, `exclude_files`, `public/private/project_header_files` | ✅ | Ruby `Dir.glob` semantics (`**`, `{a,b}`, `[abc]`) |
| `resources`, `resource_bundles` | ✅ | Bundles are separate targets; static libraries copy them with `[CP] Copy Pods Resources` |
| `vendored_frameworks` (`.framework`, `.xcframework`), `vendored_libraries` | ✅ | xcframework slices are copied by `[CP] Copy XCFrameworks` |
| `frameworks`, `weak_frameworks`, `libraries`, `compiler_flags`, `requires_arc` | ✅ | |
| `pod_target_xcconfig`, `user_target_xcconfig`, `xcconfig` | ✅ | |
| `prefix_header_file` (including `false`), `prefix_header_contents` | ✅ | |
| `module_map` (including `false`) | ✅ | A `module.modulemap` shipped next to public headers is used for static libraries |
| `header_mappings_dir` | ✅ | |
| `subspec`, `default_subspecs` (including `:none`) | ✅ | |
| `script_phases` | ✅ | |
| `prepare_command` | ✅ | Run after downloading, like CocoaPods |
| `test_spec`, `app_spec` | ⚠️ | Parsed and listed; no test/app targets are generated |
| `info_plist` | ❌ | |
| `on_demand_resources` | ❌ | |

## Generated project

| Feature | Status |
| --- | --- |
| Static libraries (default) | ✅ |
| Dynamic / static frameworks (`use_frameworks!`) | ✅ |
| Swift static libraries imported from Objective-C (`-Swift.h` module maps) | ✅ |
| Mixed Swift/Objective-C pods | ✅ |
| Platform variants (`Alamofire-iOS`, `Alamofire-macOS`) when a pod is used on several platforms | ⚠️ Implemented; not yet verified with `xcodebuild` |
| Different subspec sets per target | ⚠️ The union of subspecs is built once per platform |
| Acknowledgements (`Pods-App-acknowledgements.markdown/.plist`) | ✅ |
| Deterministic object identifiers | ⚠️ Stable across re-installs of the same inputs, but not CocoaPods' UUIDs |
| `deintegrate` | ✅ Removes phases, base configurations, products and `Pods/` |

## Behavioural differences

* Unchanged `install` runs do not rewrite the user project (verified by tests), but the first
  install over a CocoaPods-generated project rewrites `Pods.xcodeproj` entirely.
* `ENABLE_USER_SCRIPT_SANDBOXING = NO` is set in the aggregate xcconfig, because the `[CP]`
  scripts read files that are not declared as inputs.
* `outdated` reports, like `pod outdated`, the version `update` would install (a resolution with
  every pod unlocked, so requirements between pods are respected) and `(unused)` for pods that
  would be removed.
* `:git` checkouts pinned by `:tag` or `:commit` are cached like released pods and are not
  cloned again on every install; `:branch` checkouts are locked to a commit after the first install.
* `pod lib lint` / `pod trunk push` / `pod spec create` are not implemented; `spec lint` performs
  static checks only.
