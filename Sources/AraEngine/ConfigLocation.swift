import Foundation

/// Where Ara's user-editable files live, per platform — the seam that lets
/// `LocalDictionary` and `Snippets` compile for an iOS keyboard without
/// knowing anything about either platform's conventions.
///
/// On iOS this is the App Group container (`group.com.silpho.ara`, decided
/// 2026-08-07) so the container app and the keyboard extension read the same
/// dictionary. The Application Support fallback exists only for processes
/// missing the entitlement — real, writable, and wrong only in that the two
/// processes would not share it; `containerURL` returning nil is the honest
/// signal provisioning is broken, and UI should surface it.
public enum ConfigLocation {
    public static let appGroup = "group.com.silpho.ara"

    public static var directory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ara")
        #else
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appendingPathComponent("ara")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
            .appendingPathComponent("ara")
        #endif
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
