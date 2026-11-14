import Foundation
import PodsCore
@testable import PodsInstaller
import Testing

/// Runs the generated `[CP] Embed Pods Frameworks` script on real Mach-O binaries.
struct EmbedFrameworksScriptTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-embed-\(UUID().uuidString)")

    /// Builds `<name>.framework` whose binary is made by `command` (with `$SRC` and `$OUT` set).
    private func framework(_ name: String, _ command: String) async throws -> String {
        let directory = root.appendingPathComponent("Vendored/\(name).framework")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("\(name).c")
        try "int \(name)Value(void) { return 1; }\n".write(to: source, atomically: true, encoding: .utf8)
        let output = try await Shell(environment: ["SRC": source.path, "OUT": directory.appendingPathComponent(name).path])
            .execute(["/bin/sh", "-c", command], in: root)
        #expect(output.status == 0, "\(output.stderr)")
        return directory.path
    }

    @Test func embedsOnlyDynamicFrameworks() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dynamic = try await framework("Dynamic", #"xcrun clang -dynamiclib -o "$OUT" "$SRC""#)
        let archive = try await framework("Archive", #"xcrun clang -c -o "$OUT.o" "$SRC" && xcrun ar rcs "$OUT" "$OUT.o" && rm "$OUT.o""#)
        // Prebuilt static frameworks may ship a relocatable object (MH_OBJECT) instead of an archive, e.g. ML Kit's.
        let object = try await framework("Object", #"xcrun clang -c -o "$OUT" "$SRC""#)

        let script = root.appendingPathComponent("frameworks.sh")
        try SupportFiles.embedFrameworksScript(frameworksByConfiguration: [("Debug", [dynamic, archive, object])])
            .write(to: script, atomically: true, encoding: .utf8)
        let build = root.appendingPathComponent("Build").path
        let output = try await Shell(environment: [
            "CONFIGURATION": "Debug", "FRAMEWORKS_FOLDER_PATH": "App.app/Frameworks", "CONFIGURATION_BUILD_DIR": build,
            "TARGET_BUILD_DIR": build, "BUILT_PRODUCTS_DIR": build, "CODE_SIGNING_ALLOWED": "NO",
        ]).execute(["/bin/bash", script.path], in: root)
        #expect(output.status == 0, "\(output.stdout)\(output.stderr)")

        let embedded = try FileManager.default.contentsOfDirectory(atPath: build + "/App.app/Frameworks").sorted()
        #expect(embedded == ["Dynamic.framework"])
    }
}
