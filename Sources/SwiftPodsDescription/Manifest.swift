// SwiftPodsDescription: manifest registration and JSON output.

/// Minimal JSON model; the description API must not depend on Foundation.
enum _JSON: Sendable {
    case null
    case bool(Bool)
    case string(String)
    case array([_JSON])
    case object([(String, _JSON)])

    func serialized() -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .string(let value): return _JSON.escape(value)
        case .array(let items): return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { _JSON.escape($0.0) + ":" + $0.1.serialized() }.joined(separator: ",") + "}"
        }
    }

    static func escape(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case let s where s.value < 0x20:
                let hex = String(s.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Dictionaries have no order; sort keys so that output is deterministic.
    static func sortedObject(_ dictionary: [String: _JSON]) -> _JSON {
        .object(dictionary.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }
}

/// Collects the manifest created by the user's code (like SwiftPM's `Package` registration).
enum _ManifestRegistry {
    // Manifests are reference types (like SwiftPM's `Package`) so that mutations made
    // after initialisation are reflected in the output.
    enum Manifest {
        case podfile(Podfile)
        case spec(PodSpec)
    }

    // The manifest program is single threaded; this is written once from top-level code.
    nonisolated(unsafe) static var manifests: [Manifest] = []

    static func register(_ manifest: Manifest) {
        manifests.append(manifest)
    }
}

/// Prints the registered manifest as JSON between markers. Called by the generated entry point.
public func __swiftpodsEmitManifest() {
    guard let manifest = _ManifestRegistry.manifests.last else {
        print("swiftpods: error: the manifest does not create a `Podfile` or `PodSpec`")
        return
    }
    let json: _JSON = switch manifest {
    case .podfile(let podfile): .object([("kind", .string("podfile")), ("manifest", podfile.json)])
    case .spec(let spec): .object([("kind", .string("podspec")), ("manifest", spec.json)])
    }
    print("<swiftpods-manifest>" + json.serialized() + "</swiftpods-manifest>")
}
