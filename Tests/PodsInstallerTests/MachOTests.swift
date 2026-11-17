import Foundation
import PodsCore
@testable import PodsInstaller
import Testing

private func toolchainAvailable() async -> Bool {
    (try? await Shell().execute(["xcrun", "--find", "clang"]).status) == 0
}

/// Builds real Mach-O fixtures with the Xcode toolchain and inspects or rewrites them.
@Suite(.enabled("requires the Xcode toolchain") { await toolchainAvailable() })
struct MachOTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-macho-\(UUID().uuidString)")
    let shell = Shell()

    /// Compiles `source` into `<root>/<path>` for `target`.
    private func object(_ path: String, source: String, target: String = "arm64-apple-ios15.0") async throws -> URL {
        let output = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = output.deletingPathExtension().appendingPathExtension("c")
        try source.write(to: file, atomically: true, encoding: .utf8)
        try await shell.run("xcrun", ["clang", "-c", "-target", target, file.path, "-o", output.path])
        return output
    }

    private func archive(_ name: String, of objects: [URL]) async throws -> URL {
        let output = root.appendingPathComponent(name)
        try await shell.run("xcrun", ["libtool", "-static", "-o", output.path] + objects.map(\.path))
        return output
    }

    @Test func detectsKinds() async throws {
        let device = try await object("device.o", source: "int device(void) { return 1; }\n")
        let intel = try await object("intel.o", source: "int intel(void) { return 2; }\n", target: "x86_64-apple-ios15.0-simulator")
        let library = try await archive("libDevice.a", of: [device])
        let fat = root.appendingPathComponent("fat.o")
        try await shell.run("xcrun", ["lipo", "-create", device.path, intel.path, "-output", fat.path])
        let image = root.appendingPathComponent("libImage.dylib")
        try await shell.run("xcrun", ["clang", "-dynamiclib", "-target", "arm64-apple-macos12.0",
                                      root.appendingPathComponent("device.c").path, "-o", image.path])
        let text = root.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)

        #expect(try MachO.kind(of: device) == .object)
        #expect(try MachO.kind(of: library) == .archive)
        #expect(try MachO.kind(of: fat) == .fat)
        #expect(try MachO.kind(of: image) == .image)
        #expect(try MachO.kind(of: text) == .unknown)
    }

    @Test func rewritesObjectPlatform() async throws {
        let device = try await object("device.o", source: "int device(void) { return 1; }\n")
        #expect(try MachO.platforms(of: device) == [2])

        try MachO.rewritePlatform(of: device, to: 7)

        #expect(try MachO.platforms(of: device) == [7])
        let load = try await shell.run("xcrun", ["otool", "-l", device.path]).stdout
        #expect(load.contains("platform 7"))
    }

    @Test func rewritesArchiveWithDuplicateMembers() async throws {
        let first = try await object("a/globals.o", source: "int firstGlobal = 1;\n")
        let second = try await object("b/globals.o", source: "int secondGlobal = 2;\n")
        // Longer than 16 bytes, so BSD `ar` stores the name as `#1/<len>` in front of the payload.
        let long = try await object("c/a_rather_long_member_name.o", source: "int longName(void) { return 3; }\n")
        let library = try await archive("libGlobals.a", of: [first, second, long])
        let membersBefore = try await shell.run("xcrun", ["ar", "-t", library.path]).stdout
        let symbolsBefore = try await shell.run("xcrun", ["nm", library.path]).stdout
        #expect(membersBefore.split(separator: "\n").filter { $0 == "globals.o" }.count == 2)
        #expect(try MachO.platforms(of: library) == [2])

        try MachO.rewritePlatform(of: library, to: 7)

        #expect(try MachO.platforms(of: library) == [7])
        #expect(try await shell.run("xcrun", ["ar", "-t", library.path]).stdout == membersBefore)
        #expect(try await shell.run("xcrun", ["nm", library.path]).stdout == symbolsBefore)
    }

    @Test func missingBuildVersionThrows() async throws {
        // Deployment targets this old make clang emit LC_VERSION_MIN_IPHONEOS instead of LC_BUILD_VERSION.
        let legacy = try await object("legacy.o", source: "int legacy(void) { return 1; }\n", target: "arm64-apple-ios9.0")
        let before = try Data(contentsOf: legacy)

        let error = #expect(throws: PodsError.self) { try MachO.rewritePlatform(of: legacy, to: 7) }

        #expect(error?.message.contains(legacy.path) == true)
        #expect(try Data(contentsOf: legacy) == before)

        // One member without LC_BUILD_VERSION fails the whole archive, which stays untouched.
        let modern = try await object("modern.o", source: "int modern(void) { return 2; }\n")
        let library = try await archive("libMixed.a", of: [modern, legacy])
        let archiveBefore = try Data(contentsOf: library)
        let archiveError = #expect(throws: PodsError.self) { try MachO.rewritePlatform(of: library, to: 7) }
        #expect(archiveError?.message.contains(library.path) == true)
        #expect(archiveError?.message.contains("legacy.o") == true)
        #expect(try Data(contentsOf: library) == archiveBefore)
    }
}
