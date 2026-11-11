import Foundation

/// File pattern matching with the semantics of Ruby's `Dir.glob` as used by CocoaPods:
/// `*` (no `/`), `?`, `**/` (zero or more directories), `{a,b}` alternation and `[abc]` classes.
struct Glob {
    let root: URL

    /// Expands `{a,b}` alternatives (nested braces supported).
    static func expandBraces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var close: String.Index?
        var commas: [String.Index] = []
        var index = open
        while index < pattern.endIndex {
            switch pattern[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { close = index }
            case "," where depth == 1: commas.append(index)
            default: break
            }
            if close != nil { break }
            index = pattern.index(after: index)
        }
        guard let close else { return [pattern] }
        let prefix = String(pattern[..<open])
        let suffix = String(pattern[pattern.index(after: close)...])
        var bounds = [pattern.index(after: open)]
        for comma in commas { bounds.append(pattern.index(after: comma)) }
        var alternatives: [String] = []
        for (i, start) in bounds.enumerated() {
            let end = i + 1 < bounds.count ? pattern.index(before: bounds[i + 1]) : close
            alternatives.append(String(pattern[start..<end]))
        }
        return alternatives.flatMap { expandBraces(prefix + $0 + suffix) }
    }

    /// Converts a brace-free glob into a regular expression over relative paths.
    static func regex(for pattern: String) -> NSRegularExpression? {
        var regex = "^"
        var chars = Array(pattern)[...]
        while let c = chars.popFirst() {
            switch c {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" {
                        chars.removeFirst()
                        regex += "(?:[^/]*/)*" // `**/` → zero or more directories
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            case "[":
                var set = ""
                while let n = chars.popFirst(), n != "]" { set.append(n == "!" && set.isEmpty ? "^" : n) }
                regex += "[\(set)]"
            case ".", "(", ")", "+", "|", "^", "$", "\\", "{", "}":
                regex += "\\" + String(c)
            default:
                regex.append(c)
            }
        }
        // Dir.glob does not match dot files with wildcards; mirror that by excluding them.
        return try? NSRegularExpression(pattern: regex + "$")
    }

    /// Every file and directory under the root, as paths relative to it (dot files skipped).
    func allPaths() -> [(path: String, isDirectory: Bool)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [(String, Bool)] = []
        for case let url as URL in enumerator {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let relative = String(resolved.dropFirst(rootPath.count + 1))
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            result.append((relative, isDirectory))
            // Bundle-like directories are opaque: their contents are never sources on their own.
            if isDirectory, Self.opaqueDirectoryExtensions.contains(url.pathExtension) {
                enumerator.skipDescendants()
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Paths matching any of `patterns`. Directories matched by a pattern expand to their files
    /// with one of `directoryExtensions` (if given), as `source_files = 'Sources'` does.
    func match(_ patterns: [String], directoryExtensions: Set<String>? = nil, in paths: [(path: String, isDirectory: Bool)]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let regexes = patterns.flatMap(Self.expandBraces).compactMap { pattern -> NSRegularExpression? in
            var trimmed = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
            // `Sources/Moya/` names the directory itself.
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            return Self.regex(for: trimmed)
        }
        for (path, isDirectory) in paths {
            let range = NSRange(path.startIndex..., in: path)
            guard regexes.contains(where: { $0.firstMatch(in: path, range: range) != nil }) else { continue }
            if isDirectory && !Self.isOpaqueBundle(path) {
                guard let directoryExtensions else { continue }
                for (child, childIsDirectory) in paths where child.hasPrefix(path + "/") {
                    let ext = (child as NSString).pathExtension
                    if (directoryExtensions.contains(ext) && !childIsDirectory) || (childIsDirectory && Self.isOpaqueBundle(child) && directoryExtensions.contains(ext)),
                       seen.insert(child).inserted {
                        result.append(child)
                    }
                }
            } else if seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }

    /// Directories whose contents are not enumerated (Xcode treats them as single items).
    static let opaqueDirectoryExtensions: Set<String> = [
        "framework", "xcframework", "bundle", "xcassets", "docc", "xcdatamodeld", "xcmappingmodel",
        "playground", "xcodeproj", "xcworkspace", "app", "appex",
    ]

    static func isOpaqueBundle(_ path: String) -> Bool {
        ["framework", "xcframework", "bundle", "xcassets", "lproj", "xcdatamodeld", "xcmappingmodel", "storyboard", "xib"]
            .contains((path as NSString).pathExtension)
    }
}
