/// Path manipulation on plain `String`s with the semantics of Foundation's path APIs
/// (`lastPathComponent`, `pathExtension`, …), without bridging to `NSString`.
extension String {
    /// The path without trailing slashes (the root `/` is kept).
    private var trimmingTrailingSlashes: Substring {
        var path = Substring(self)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `"a/b.txt"` → `"b.txt"`, `"a/b/"` → `"b"`, `"/"` → `"/"`.
    package var lastPathComponent: String {
        let path = trimmingTrailingSlashes
        if path == "/" { return "/" }
        guard let slash = path.lastIndex(of: "/") else { return String(path) }
        return String(path[path.index(after: slash)...])
    }

    /// `"a/b.txt"` → `"a"`, `"b.txt"` → `""`, `"/a"` → `"/"`.
    package var deletingLastPathComponent: String {
        let path = trimmingTrailingSlashes
        if path == "/" { return "/" }
        guard let slash = path.lastIndex(of: "/") else { return "" }
        if slash == path.startIndex { return "/" }
        var parent = path[..<slash]
        while parent.count > 1, parent.hasSuffix("/") { parent.removeLast() }
        return String(parent)
    }

    /// `"a/b.tar.gz"` → `"gz"`; hidden files such as `".gitignore"` have no extension.
    package var pathExtension: String {
        let name = lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// `"a/libFoo.a"` → `"a/libFoo"`.
    package var deletingPathExtension: String {
        let path = String(trimmingTrailingSlashes)
        let ext = pathExtension
        guard !ext.isEmpty else { return path }
        return String(path.dropLast(ext.count + 1))
    }
}
