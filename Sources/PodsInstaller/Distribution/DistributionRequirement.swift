import PodsCore

/// The version requirement written into a generated distribution Package.swift for one dependency.
enum DistributionRequirement: Equatable, Sendable {
    case exact(Version)
    case closedRange(Version, Version)
    /// `lower..<upper`: the declared range of a package that no pod is unified with.
    case range(Version, Version)
    /// Declared range of an overridden package, rendered as written, plus the `#warning` text.
    case unsafe(lower: Version, upper: Version, warning: String)

    /// The maximal run of consecutive tagged versions that are all allowed and contain `pinned`.
    /// Versions between tags that are not allowed must not be inside the range, so the run stops at them.
    static func narrowed(allowed: [Version], tagged: [Version], pinned: Version) throws(PodsError) -> DistributionRequirement {
        let allowedSet = Set(allowed)
        guard allowedSet.contains(pinned), let pinIndex = tagged.firstIndex(of: pinned) else {
            throw PodsError("Resolved version \(pinned) is not among the versions the pods accept, so no distribution requirement can be derived.")
        }
        var start = pinIndex
        while start > tagged.startIndex, allowedSet.contains(tagged[start - 1]) { start -= 1 }
        var end = pinIndex
        while end + 1 < tagged.endIndex, allowedSet.contains(tagged[end + 1]) { end += 1 }
        return start == end ? .exact(pinned) : .closedRange(tagged[start], tagged[end])
    }

    static func forUnification(
        _ unification: PackageUnifier.Unification,
        pinned: Version,
        declared: Requirement?
    ) throws(PodsError) -> DistributionRequirement {
        guard let reason = unification.unsafeOverrideReason else {
            return try narrowed(allowed: unification.allowedVersions, tagged: unification.taggedVersions, pinned: pinned)
        }
        var bounds = (unification.lowerBound, unification.upperBound)
        if let declared {
            let range = try SwiftPackageResolver.range(of: declared, url: unification.packageURL)
            bounds = (range.lower, range.upper)
        }
        let accepted = unification.podAcceptedVersions
        let acceptedText = if let lowest = accepted.first, let highest = accepted.last { "\(lowest)...\(highest)" } else { "no version" }
        let warning = "\(identity(of: unification.packageURL)) \(bounds.0)..<\(bounds.1) is outside the versions the pods accept "
            + "(\(unification.podRoot) accepts \(acceptedText)); ABI compatibility is unsafe and not verified by swiftpods. Reason: \(reason)"
        return .unsafe(lower: bounds.0, upper: bounds.1, warning: warning)
    }

    /// Last path component without `.git`, lowercased (same as `SwiftPackageDependency.identity`).
    private static func identity(of url: String) -> String {
        var name = url.split(separator: "/").last.map(String.init) ?? url
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.lowercased()
    }
}
