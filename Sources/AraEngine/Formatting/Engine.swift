import Foundation

/// Which formatting engine `FormatterChain` prefers.
///
/// `mlx` is the default because it is the only one that works on a stock Apple
/// Silicon Mac: `apple` needs macOS 26 with Apple Intelligence switched on, and
/// `cloud` needs an API key and a network.
///
/// `apple` was called `local` until the bundled MLX engine arrived, at which
/// point "local" described two of the three engines and identified neither. The
/// decoder below still accepts the old spelling.
public enum Engine: String, Codable, Sendable, CaseIterable {
    case mlx, apple, cloud, rules, off

    /// The name this engine had in a config file written before the rename, or
    /// `nil` when it never had another name.
    static func legacyName(_ raw: String) -> Engine? {
        raw == "local" ? .apple : nil
    }

    /// Hand-written so `"local"` keeps working.
    ///
    /// This matters more than a compatibility gesture usually would:
    /// `Config.load` discards the **whole file** when any value fails to
    /// decode, so an existing `{"engine": "local", "cloud": {...}}` would lose
    /// its cloud section too, and silently switch the user to a different
    /// engine than either name means.
    ///
    /// An unrecognised value still throws, with the offending string in the
    /// message — `Config.load` renders that into the one line that tells the
    /// user their file is being ignored and why.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let engine = Engine(rawValue: raw) ?? Engine.legacyName(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize Engine from invalid String value \(raw)")
        }
        self = engine
    }
}
