/// A version constraint such as `~> 1.2` or `>= 1.0, < 2.0`.
public struct Requirement: Sendable, Hashable, CustomStringConvertible {
    public enum Operator: String, Sendable, Hashable, CaseIterable {
        case equal = "="
        case notEqual = "!="
        case greaterThan = ">"
        case lessThan = "<"
        case greaterThanOrEqual = ">="
        case lessThanOrEqual = "<="
        case optimistic = "~>"
    }

    public struct Constraint: Sendable, Hashable, CustomStringConvertible {
        public let op: Operator
        public let version: Version

        public init(_ op: Operator, _ version: Version) {
            self.op = op
            self.version = version
        }

        public func isSatisfied(by candidate: Version) -> Bool {
            switch op {
            case .equal: candidate == version
            case .notEqual: candidate != version
            case .greaterThan: candidate > version
            case .lessThan: candidate < version
            case .greaterThanOrEqual: candidate >= version
            case .lessThanOrEqual: candidate <= version
            case .optimistic:
                // Release segments must share the prefix; prereleases of the bound are excluded.
                candidate >= version && candidate.release.lexicographicallyPrecedes(version.optimisticUpperBound.release)
            }
        }

        public var description: String { "\(op.rawValue) \(version)" }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            switch self {
            case .invalid(let string): "Invalid requirement '\(string)'"
            }
        }
    }

    public let constraints: [Constraint]

    /// A requirement matching any version.
    public static let any = Requirement(constraints: [])

    public init(constraints: [Constraint]) {
        self.constraints = constraints
    }

    public static func exact(_ version: Version) -> Requirement {
        Requirement(constraints: [Constraint(.equal, version)])
    }

    /// Parses requirement strings like `"~> 1.0"`, `"1.0"`, `">= 1.0, < 2.0"`.
    public init(parsing strings: [String]) throws(ParseError) {
        var constraints: [Constraint] = []
        for string in strings {
            for part in string.split(separator: ",") {
                constraints.append(try Self.parseConstraint(part.trimmingWhitespace()))
            }
        }
        self.constraints = constraints
    }

    public init(parsing string: String) throws(ParseError) {
        try self.init(parsing: [string])
    }

    private static func parseConstraint(_ string: String) throws(ParseError) -> Constraint {
        // Longest operators first so that ">=" is not read as ">".
        let operators = Operator.allCases.sorted { $0.rawValue.count > $1.rawValue.count }
        for op in operators where string.hasPrefix(op.rawValue) {
            let rest = string.dropFirst(op.rawValue.count).trimmingWhitespace()
            guard let version = Version(rest) else { throw .invalid(string) }
            return Constraint(op, version)
        }
        guard let version = Version(string) else { throw .invalid(string) }
        return Constraint(.equal, version)
    }

    public func isSatisfied(by version: Version) -> Bool {
        constraints.allSatisfy { $0.isSatisfied(by: version) }
    }

    /// Whether any constraint explicitly references a pre-release version.
    /// CocoaPods only selects pre-release versions in that case.
    public var allowsPreRelease: Bool {
        constraints.contains { $0.version.isPreRelease }
    }

    public var isAny: Bool { constraints.isEmpty }

    /// Combines two requirements (logical AND).
    public func merging(_ other: Requirement) -> Requirement {
        var merged = constraints
        for constraint in other.constraints where !merged.contains(constraint) {
            merged.append(constraint)
        }
        return Requirement(constraints: merged)
    }

    public var description: String {
        constraints.isEmpty ? ">= 0" : constraints.map(\.description).joined(separator: ", ")
    }

    /// The representation used in Podfile.lock (`(~> 1.0)`), empty when unconstrained.
    /// Constraints are sorted as strings, like CocoaPods' vendored `Gem::Requirement#as_list`.
    public var lockfileDescription: String {
        constraints.isEmpty ? "" : "(\(constraints.map(\.description).sorted().joined(separator: ", ")))"
    }
}
