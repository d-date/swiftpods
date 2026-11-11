import PodsCore
public import PodsSpec

/// Static checks for podspecs, a subset of `pod spec lint --quick`.
public enum SpecLinter {
    public static func lint(_ spec: Specification) -> [String] {
        var issues: [String] = []
        for attribute in ["summary", "homepage", "license", "authors", "source"] where spec.rootAttribute(attribute) == nil {
            issues.append("Missing required attribute `\(attribute)`.")
        }
        if let summary = spec.summary, summary.count > 140 {
            issues.append("The summary should be shorter than 140 characters.")
        }
        if spec.rootAttribute("source") != nil, spec.source == nil {
            issues.append("`source` must specify `git`, `http` or `path`.")
        }
        if case .git(_, .defaultBranch, _)? = spec.source {
            issues.append("A git `source` should specify a `tag` or `commit`.")
        }
        if spec.declaredPlatforms == nil {
            issues.append("No platforms declared; the pod will be considered available on every platform.")
        }
        for subspec in [spec] + spec.recursiveSubspecs {
            let hasContent = Platform.Name.allCases.contains { platform in
                let consumer = subspec.consumer(for: platform)
                return !consumer.sourceFiles.isEmpty || !consumer.vendoredFrameworks.isEmpty || !consumer.vendoredLibraries.isEmpty
                    || !consumer.resources.isEmpty || !consumer.resourceBundles.isEmpty
            }
            if !hasContent && subspec.subspecs.isEmpty && subspec.allDependencies.isEmpty {
                issues.append("`\(subspec.name)` has no source files, resources, vendored binaries or dependencies.")
            }
            for dependency in subspec.allDependencies where dependency.rootName == spec.name && spec.subspec(named: dependency.name) == nil {
                issues.append("`\(subspec.name)` depends on the missing subspec `\(dependency.name)`.")
            }
        }
        return issues
    }
}
