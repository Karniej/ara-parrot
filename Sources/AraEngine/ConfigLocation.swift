import Foundation

/// Where Ara's user-editable files live.
///
/// Still a seam rather than a path spelled out at each call site:
/// `LocalDictionary` and `Snippets` sit in the engine, and the engine is the
/// part that gets reused. What it is reused *by* is no longer this package's
/// business — the phone builds have their own repository and their own answer,
/// which on those platforms is a shared App Group container. Here there is one
/// process and one home directory, so there is one path and no conditional.
public enum ConfigLocation {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ara")
    }
}

/// Renders a `DecodingError` as the one line a user editing JSON by hand
/// actually needs: where, and what was wrong. Lived in `Config` originally;
/// moved here because it is about JSON files generally and the vocabulary
/// files need it on platforms where `Config` does not exist.
public enum JSONErrors {
    public static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return "\(type(of: error))" }
        let (context, what): (DecodingError.Context, String) = {
            switch error {
            case .dataCorrupted(let c): return (c, "invalid value")
            case .keyNotFound(let key, let c): return (c, "missing key \(key.stringValue)")
            case .typeMismatch(let type, let c): return (c, "expected \(type)")
            case .valueNotFound(let type, let c): return (c, "no value for \(type)")
            @unknown default: return (DecodingError.Context(codingPath: [], debugDescription: ""),
                                      "undecodable")
            }
        }()
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let location = path.isEmpty ? "" : "at \(path): "
        let detail = context.debugDescription.isEmpty ? what : context.debugDescription
        return location + detail
    }
}
