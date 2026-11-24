import Foundation
import PodsCore

/// Reads and patches Mach-O files and BSD `ar` archives of them.
///
/// A prebuilt device slice becomes a simulator slice by rewriting the platform of its
/// LC_BUILD_VERSION commands: the code is identical, only the platform the linker checks differs.
/// Patching in place keeps an archive's member layout and symbol index intact, which matters because
/// archives may contain several members with the same name that would not survive an extract/repack.
enum MachO {
    enum Kind: Equatable, Sendable { case archive, object, image, fat, unknown }

    private static let archiveMagic: [UInt8] = Array("!<arch>\n".utf8)
    private static let archiveHeaderSize = 60
    private static let fatMagics: Set<UInt32> = [0xcafe_babe, 0xcafe_babf]
    private static let objectFileType: UInt32 = 0x1
    private static let buildVersionCommand: UInt32 = 0x32

    static func kind(of file: URL) throws -> Kind {
        let bytes = try read(file)
        if bytes.starts(with: archiveMagic) { return .archive }
        if let magic = bytes.uint32(at: 0, littleEndian: false), fatMagics.contains(magic) { return .fat }
        guard let header = Header(bytes, at: 0), let fileType = bytes.uint32(at: 12, littleEndian: header.littleEndian) else {
            return .unknown
        }
        return fileType == objectFileType ? .object : .image
    }

    /// Rewrites the platform of every LC_BUILD_VERSION in a thin Mach-O or in every member of a thin
    /// `ar` archive, in place, keeping the archive layout. Throws `PodsError` when a file or member has
    /// no LC_BUILD_VERSION (it cannot be added in place).
    static func rewritePlatform(of file: URL, to platform: UInt32) throws {
        var bytes = try read(file)
        for (name, offset) in try machOs(in: bytes, file: file) {
            let commands = try buildVersions(in: bytes, at: offset, file: file)
            guard !commands.isEmpty else {
                let location = name.map { "\(file.path)(\($0))" } ?? file.path
                throw PodsError("\(location) has no LC_BUILD_VERSION load command; its platform cannot be rewritten in place")
            }
            let littleEndian = Header(bytes, at: offset)!.littleEndian
            for command in commands { bytes.setUInt32(platform, at: command + 8, littleEndian: littleEndian) }
        }
        try Data(bytes).write(to: file)
    }

    /// Adds an LC_BUILD_VERSION (no tool entries) to a thin object file that has no platform load
    /// command at all, writing it into the padding between the load commands and the first data.
    ///
    /// This is the fallback for vendored objects whose header has room for the 24-byte command but
    /// not for what `vtool` wants, on toolchains whose `ld -r` ignores `-platform_version` (Xcode 26).
    /// Returns false, leaving the file untouched, when the file already names a platform, is not a
    /// thin object, has a load command whose file offsets are unknown, or lacks the padding.
    static func insertBuildVersion(into file: URL, platform: UInt32, minimumOS: String, sdk: String) throws -> Bool {
        var bytes = try read(file)
        guard let header = Header(bytes, at: 0),
              bytes.uint32(at: 12, littleEndian: header.littleEndian) == objectFileType,
              let count = bytes.uint32(at: 16, littleEndian: header.littleEndian),
              let commandsSize = bytes.uint32(at: 20, littleEndian: header.littleEndian),
              let minimumOS = encodedVersion(minimumOS), let sdk = encodedVersion(sdk)
        else { return false }
        let littleEndian = header.littleEndian
        let commandsEnd = header.size + Int(commandsSize)
        guard let dataStart = try firstDataOffset(in: bytes, header: header, count: Int(count), file: file),
              commandsEnd + buildVersionSize <= dataStart,
              bytes[commandsEnd ..< commandsEnd + buildVersionSize].allSatisfy({ $0 == 0 })
        else { return false }

        for (index, value) in [buildVersionCommand, UInt32(buildVersionSize), platform, minimumOS, sdk, 0].enumerated() {
            bytes.setUInt32(value, at: commandsEnd + 4 * index, littleEndian: littleEndian)
        }
        bytes.setUInt32(count + 1, at: 16, littleEndian: littleEndian)
        bytes.setUInt32(commandsSize + UInt32(buildVersionSize), at: 20, littleEndian: littleEndian)
        try Data(bytes).write(to: file)
        return true
    }

    private static let buildVersionSize = 24
    /// LC_VERSION_MIN_MACOSX, _IPHONEOS, _TVOS, _WATCHOS.
    private static let versionMinCommands: Set<UInt32> = [0x24, 0x25, 0x2f, 0x30]
    /// Load commands that hold no file offsets: UUID, LC_LINKER_OPTION, LC_SOURCE_VERSION.
    private static let offsetFreeCommands: Set<UInt32> = [0x1b, 0x2d, 0x2a]
    /// linkedit_data_command types: code signature, split info, function starts, data in code,
    /// code-sign DRs, linker optimization hints, dyld exports trie, dyld chained fixups.
    private static let linkeditDataCommands: Set<UInt32> = [0x1d, 0x1e, 0x26, 0x29, 0x2b, 0x2e, 0x8000_0033, 0x8000_0034]

    /// The lowest file offset any load command points at, or nil when the object already names a
    /// platform or has a command this reader cannot account for.
    private static func firstDataOffset(in bytes: [UInt8], header: Header, count: Int, file: URL) throws -> Int? {
        let littleEndian = header.littleEndian
        func value(_ offset: Int) throws -> Int {
            guard let value = bytes.uint32(at: offset, littleEndian: littleEndian) else {
                throw PodsError("\(file.path) has a truncated load command at offset \(offset)")
            }
            return Int(value)
        }
        var lowest = bytes.count
        func note(_ offset: Int) { if offset > 0 { lowest = min(lowest, offset) } }
        var offset = header.size
        for _ in 0 ..< count {
            let command = UInt32(try value(offset)), size = try value(offset + 4)
            guard size >= 8 else { throw PodsError("\(file.path) has an invalid load command at offset \(offset)") }
            switch command {
            case buildVersionCommand:
                return nil
            case _ where versionMinCommands.contains(command):
                return nil
            case 0x19, 0x1:  // LC_SEGMENT_64, LC_SEGMENT
                let is64 = command == 0x19
                let (segmentHeader, sectionSize) = is64 ? (72, 80) : (56, 68)
                let (fileOffsetField, fileSizeField) = is64 ? (40, 48) : (32, 36)
                if try value(offset + fileSizeField) > 0 { note(try value(offset + fileOffsetField)) }
                let sections = try value(offset + segmentHeader - 8)
                for index in 0 ..< sections {
                    let section = offset + segmentHeader + index * sectionSize
                    // offset and reloff follow the names, address and size.
                    let fields = is64 ? (48, 56) : (40, 48)
                    note(try value(section + fields.0))
                    note(try value(section + fields.1))
                }
            case 0x2:  // LC_SYMTAB: symoff, stroff
                note(try value(offset + 8))
                note(try value(offset + 16))
            case 0xb:  // LC_DYSYMTAB: tocoff, modtaboff, extrefsymoff, indirectsymoff, extreloff, locreloff
                for field in [32, 40, 48, 56, 64, 72] { note(try value(offset + field)) }
            case _ where linkeditDataCommands.contains(command):
                note(try value(offset + 8))
            case _ where offsetFreeCommands.contains(command):
                break
            default:
                return nil
            }
            offset += size
        }
        return lowest
    }

    /// `X.Y.Z` as the nibble-packed `xxxx.yy.zz` that version load commands store.
    private static func encodedVersion(_ version: String) -> UInt32? {
        let parts = version.split(separator: ".").map { UInt32($0) }
        guard (1 ... 3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        guard numbers[0] <= 0xffff, numbers[1] <= 0xff, numbers[2] <= 0xff else { return nil }
        return numbers[0] << 16 | numbers[1] << 8 | numbers[2]
    }

    /// The platforms named by every LC_BUILD_VERSION in a thin Mach-O or in the members of a thin `ar` archive.
    static func platforms(of file: URL) throws -> Set<UInt32> {
        let bytes = try read(file)
        var platforms: Set<UInt32> = []
        for (_, offset) in try machOs(in: bytes, file: file) {
            let littleEndian = Header(bytes, at: offset)!.littleEndian
            for command in try buildVersions(in: bytes, at: offset, file: file) {
                platforms.insert(bytes.uint32(at: command + 8, littleEndian: littleEndian)!)
            }
        }
        return platforms
    }

    private static func read(_ file: URL) throws -> [UInt8] {
        do { return [UInt8](try Data(contentsOf: file)) } catch {
            throw PodsError("Could not read \(file.path): \(error.localizedDescription)")
        }
    }

    /// The thin Mach-O headers in `bytes`: the file itself, or each Mach-O member of an archive
    /// (with its member name). Non-Mach-O members such as the symbol index are skipped.
    private static func machOs(in bytes: [UInt8], file: URL) throws -> [(name: String?, offset: Int)] {
        guard bytes.starts(with: archiveMagic) else {
            guard Header(bytes, at: 0) != nil else { throw PodsError("\(file.path) is not a thin Mach-O file or archive") }
            return [(nil, 0)]
        }
        var members: [(name: String?, offset: Int)] = []
        var offset = archiveMagic.count
        while offset + archiveHeaderSize <= bytes.count {
            guard let size = bytes.decimal(at: offset + 48, length: 10), size > 0,
                  offset + archiveHeaderSize + size <= bytes.count
            else { throw PodsError("\(file.path) has an invalid archive member header at offset \(offset)") }
            var payload = offset + archiveHeaderSize
            var nameBytes = bytes[offset ..< offset + 16]
            // BSD `ar` stores names longer than 16 bytes at the start of the payload, counted in `size`.
            if nameBytes.starts(with: Array("#1/".utf8)) {
                guard let length = bytes.decimal(at: offset + 3, length: 13), length <= size else {
                    throw PodsError("\(file.path) has an invalid archive member name at offset \(offset)")
                }
                nameBytes = bytes[payload ..< payload + length]
                payload += length
            }
            if Header(bytes, at: payload) != nil {
                // Short names are space-padded, long ones NUL-padded.
                let name = nameBytes.prefix { $0 != 0 }.reversed().drop { $0 == UInt8(ascii: " ") }.reversed()
                members.append((String(decoding: name, as: UTF8.self), payload))
            }
            offset += archiveHeaderSize + size
            offset += offset % 2  // Members are padded to an even size.
        }
        return members
    }

    /// Offsets of the LC_BUILD_VERSION load commands of the Mach-O whose header is at `base`.
    private static func buildVersions(in bytes: [UInt8], at base: Int, file: URL) throws -> [Int] {
        let header = Header(bytes, at: base)!
        guard let count = bytes.uint32(at: base + 16, littleEndian: header.littleEndian) else {
            throw PodsError("\(file.path) has a truncated Mach-O header at offset \(base)")
        }
        var offset = base + header.size
        var commands: [Int] = []
        for _ in 0 ..< count {
            guard let command = bytes.uint32(at: offset, littleEndian: header.littleEndian),
                  let size = bytes.uint32(at: offset + 4, littleEndian: header.littleEndian), size >= 8
            else { throw PodsError("\(file.path) has an invalid load command at offset \(offset)") }
            if command == buildVersionCommand {
                guard bytes.uint32(at: offset + 8, littleEndian: header.littleEndian) != nil else {
                    throw PodsError("\(file.path) has a truncated LC_BUILD_VERSION at offset \(offset)")
                }
                commands.append(offset)
            }
            offset += Int(size)
        }
        return commands
    }

    /// The parts of a thin Mach-O header that decide how the rest is read.
    private struct Header {
        let littleEndian: Bool
        let size: Int

        init?(_ bytes: [UInt8], at offset: Int) {
            switch bytes.uint32(at: offset, littleEndian: true) {
            case 0xfeed_facf: (littleEndian, size) = (true, 32)
            case 0xfeed_face: (littleEndian, size) = (true, 28)
            case 0xcffa_edfe: (littleEndian, size) = (false, 32)
            case 0xcefa_edfe: (littleEndian, size) = (false, 28)
            default: return nil
            }
        }
    }
}

private extension [UInt8] {
    func uint32(at offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let value = (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << (8 * $1) }
        return littleEndian ? value : value.byteSwapped
    }

    mutating func setUInt32(_ value: UInt32, at offset: Int, littleEndian: Bool) {
        let stored = littleEndian ? value : value.byteSwapped
        for index in 0 ..< 4 { self[offset + index] = UInt8(truncatingIfNeeded: stored >> (8 * index)) }
    }

    /// A space-padded ASCII decimal field, as used in `ar` headers.
    func decimal(at offset: Int, length: Int) -> Int? {
        guard offset + length <= count else { return nil }
        let digits = self[offset ..< offset + length].prefix { $0 != UInt8(ascii: " ") }
        guard !digits.isEmpty, digits.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }) else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
    }
}
