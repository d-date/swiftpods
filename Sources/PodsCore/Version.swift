/// A pod version, compatible with CocoaPods' `Pod::Version` semantics.
///
/// A version consists of numeric *release* segments optionally followed by
/// *pre-release* identifiers. Both semver style (`1.2.3-beta.1`) and RubyGems
/// style (`1.2.3.beta.1`) pre-release notations are accepted.
public struct Version: Sendable, Hashable, Comparable, CustomStringConvertible, LosslessStringConvertible {
    public enum Identifier: Sendable, Hashable, Comparable, CustomStringConvertible {
        case number(Int)
        case text(String)

        public var description: String {
            switch self {
            case .number(let n): String(n)
            case .text(let s): s
            }
        }

        // Numeric identifiers have lower precedence than alphanumeric ones (semver §11).
        public static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case (.number(let a), .number(let b)): a < b
            case (.text(let a), .text(let b)): a < b
            case (.number, .text): true
            case (.text, .number): false
            }
        }
    }

    /// The string the version was created from.
    public let rawValue: String
    /// Numeric release segments, e.g. `[1, 2, 3]`.
    public let release: [Int]
    /// Pre-release identifiers, e.g. `["beta", 1]`. Empty for final releases.
    public let preRelease: [Identifier]
    /// Build metadata (`+build`), ignored for precedence.
    public let buildMetadata: String?

    public init?(_ description: String) {
        let trimmed = description.trimmingWhitespace()
        guard !trimmed.isEmpty else { return nil }

        var body = Substring(trimmed)
        var metadata: String?
        if let plus = body.firstIndex(of: "+") {
            metadata = String(body[body.index(after: plus)...])
            body = body[..<plus]
        }

        var releasePart = body
        var preParts: [Substring] = []
        if let dash = body.firstIndex(of: "-") {
            releasePart = body[..<dash]
            preParts = body[body.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
        }

        var release: [Int] = []
        var pre: [Identifier] = []
        var inPreRelease = false
        for segment in releasePart.split(separator: ".", omittingEmptySubsequences: false) {
            guard !segment.isEmpty else { return nil }
            for piece in Self.splitAlphaNumeric(segment) {
                if !inPreRelease, let n = Int(piece) {
                    release.append(n)
                } else {
                    guard piece.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
                    inPreRelease = true
                    pre.append(Int(piece).map(Identifier.number) ?? .text(String(piece)))
                }
            }
        }
        for part in preParts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return nil }
            pre.append(Int(part).map(Identifier.number) ?? .text(String(part)))
        }
        guard !release.isEmpty else { return nil }

        self.rawValue = trimmed
        self.release = release
        self.preRelease = pre
        self.buildMetadata = metadata
    }

    public init(_ release: Int...) {
        self.release = release
        self.preRelease = []
        self.buildMetadata = nil
        self.rawValue = release.map(String.init).joined(separator: ".")
    }

    public var description: String { rawValue }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    /// Major version (first release segment).
    public var major: Int { release[0] }
    public var minor: Int { release.count > 1 ? release[1] : 0 }
    public var patch: Int { release.count > 2 ? release[2] : 0 }

    /// The upper bound used by the optimistic operator (`~>`).
    ///
    /// `~> 1.2.3` → `1.3`, `~> 1.2` → `2`, `~> 1` → `2`.
    public var optimisticUpperBound: Version {
        var segments = release
        if segments.count > 1 { segments.removeLast() }
        segments[segments.count - 1] += 1
        return Version(segments: segments)
    }

    private init(segments: [Int]) {
        self.release = segments
        self.preRelease = []
        self.buildMetadata = nil
        self.rawValue = segments.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        // Hash the canonical form so that `1.0` and `1.0.0` hash identically.
        var canonical = release
        while canonical.count > 1, canonical.last == 0 { canonical.removeLast() }
        hasher.combine(canonical)
        hasher.combine(preRelease)
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ lhs: Version, _ rhs: Version) -> Int {
        let length = max(lhs.release.count, rhs.release.count)
        for i in 0..<length {
            let a = i < lhs.release.count ? lhs.release[i] : 0
            let b = i < rhs.release.count ? rhs.release[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for (a, b) in zip(lhs.preRelease, rhs.preRelease) where a != b {
            return a < b ? -1 : 1
        }
        return lhs.preRelease.count == rhs.preRelease.count ? 0 : (lhs.preRelease.count < rhs.preRelease.count ? -1 : 1)
    }

    /// Splits `"0beta2"` into `["0", "beta", "2"]`, mirroring RubyGems segment scanning.
    private static func splitAlphaNumeric(_ segment: Substring) -> [Substring] {
        var result: [Substring] = []
        var start = segment.startIndex
        var index = segment.startIndex
        while index < segment.endIndex {
            let next = segment.index(after: index)
            if next < segment.endIndex, segment[index].isNumber != segment[next].isNumber {
                result.append(segment[start..<next])
                start = next
            }
            index = next
        }
        if start < segment.endIndex { result.append(segment[start...]) }
        return result
    }
}

extension Version: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = Version(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid version '\(string)'")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension StringProtocol {
    /// Trims spaces, tabs and newlines without depending on Foundation.
    package func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })!
        return String(String.UnicodeScalarView(scalars[first...last]))
    }
}
