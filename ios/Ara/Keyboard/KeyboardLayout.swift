import CoreGraphics

/// Which of the three layers is showing. Layer state is pure UI: every layer
/// types through the same insertion path, so nothing downstream knows about it.
enum KeyboardLayer: Equatable {
    case letters, numbers, symbols

    /// What a key that switches *to* this layer reads.
    var switchLabel: String {
        switch self {
        case .letters: return "ABC"
        case .numbers: return "123"
        case .symbols: return "#+="
        }
    }
}

/// What pressing a key does. `character` carries the base (lowercase) form —
/// the shift state at press time decides the case, so a key never stores it.
enum KeyAction: Equatable {
    case character(String)
    case shift
    case backspace
    case layer(KeyboardLayer)
    case globe
    case space
    case newline
}

/// Key width in units of the ten-per-row letter grid. `flexible` keys split
/// whatever the fixed keys leave, which is what keeps the rows honest across
/// iPhone widths and in landscape without a second layout table.
enum KeySpan: Equatable {
    case units(CGFloat)
    case flexible
}

struct Key: Identifiable, Equatable {
    let id: String
    let action: KeyAction
    var span: KeySpan = .units(1)
    /// Long-press alternates in base case; uppercased at popup time.
    var alternates: [String] = []
}

/// One rendered row. `inset` marks the nine-key home row, which sits half a
/// key in from both edges — the only row that is not full width.
struct KeyRow: Identifiable {
    let id: Int
    let keys: [Key]
    var inset = false
}

/// Fixed geometry. The totals are load-bearing: `KeyboardViewController`
/// constrains the input view to `totalHeight`, and anything that changes a
/// row count or key height has to change that number in the same edit.
enum KeyboardMetrics {
    static let keyHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 10
    static let keySpacing: CGFloat = 6
    static let edgeInset: CGFloat = 3
    static let verticalInset: CGFloat = 5
    static let suggestionBarHeight: CGFloat = 36
    /// 4 rows × 44 + 3 × 10 + 2 × 5.
    static let keyboardHeight: CGFloat = 216
    static let totalHeight = keyboardHeight + suggestionBarHeight

    /// The name every key frame and drag location is measured in, so popup
    /// placement and slide-to-select share one origin.
    static let coordinateSpace = "ara.keyboard"

    /// The width of a single letter key: ten of them plus their gaps fill the
    /// row exactly.
    static func unitWidth(in totalWidth: CGFloat) -> CGFloat {
        max(1, (totalWidth - 2 * edgeInset - 9 * keySpacing) / 10)
    }
}

enum KeyboardLayout {
    static func rows(for layer: KeyboardLayer, needsGlobeKey: Bool) -> [KeyRow] {
        let body: [KeyRow]
        switch layer {
        case .letters:
            body = [
                KeyRow(id: 0, keys: characters("qwertyuiop")),
                KeyRow(id: 1, keys: characters("asdfghjkl"), inset: true),
                KeyRow(id: 2, keys: [Key(id: "shift", action: .shift, span: .flexible)]
                    + characters("zxcvbnm")
                    + [Key(id: "backspace", action: .backspace, span: .flexible)]),
            ]
        case .numbers:
            body = [
                KeyRow(id: 0, keys: characters("1234567890")),
                KeyRow(id: 1, keys: characters("-/:;()$&@\"")),
                KeyRow(id: 2, keys: [switchKey(to: .symbols)]
                    + characters(".,?!'")
                    + [Key(id: "backspace", action: .backspace, span: .flexible)]),
            ]
        case .symbols:
            body = [
                KeyRow(id: 0, keys: characters("[]{}#%^*+=")),
                KeyRow(id: 1, keys: characters("_\\|~<>€£¥•")),
                KeyRow(id: 2, keys: [switchKey(to: .numbers)]
                    + characters(".,?!'")
                    + [Key(id: "backspace", action: .backspace, span: .flexible)]),
            ]
        }
        return body + [KeyRow(id: 3, keys: bottomRow(for: layer,
                                                     needsGlobeKey: needsGlobeKey))]
    }

    private static func bottomRow(for layer: KeyboardLayer,
                                  needsGlobeKey: Bool) -> [Key]
    {
        var keys = [Key(id: "layer.bottom",
                        action: .layer(layer == .letters ? .numbers : .letters),
                        span: .units(1.25))]
        // The globe key is mandatory only when the user has other keyboards
        // installed; iOS tells us via `needsInputModeSwitchKey`.
        if needsGlobeKey {
            keys.append(Key(id: "globe", action: .globe))
        }
        keys.append(Key(id: "space", action: .space, span: .flexible))
        keys.append(Key(id: "return", action: .newline, span: .units(2)))
        return keys
    }

    private static func switchKey(to layer: KeyboardLayer) -> Key {
        Key(id: "layer.\(layer.switchLabel)", action: .layer(layer), span: .flexible)
    }

    private static func characters(_ string: String) -> [Key] {
        string.map { character in
            let text = String(character)
            return Key(id: "char.\(text)",
                       action: .character(text),
                       alternates: alternates[text] ?? [])
        }
    }

    /// Long-press alternates, at most six per key so the popup always fits a
    /// portrait iPhone. Polish diacritics come first on the keys that carry
    /// one: they are the reason this keyboard has popups at all, and the first
    /// cell is the one a blind slide lands on.
    static let alternates: [String: [String]] = [
        "a": ["ą", "à", "á", "â", "ä", "å"],
        "c": ["ć", "ç", "č"],
        "e": ["ę", "è", "é", "ê", "ë", "ē"],
        "i": ["í", "ì", "î", "ï", "į"],
        "l": ["ł"],
        "n": ["ń", "ñ", "ň"],
        "o": ["ó", "ò", "ô", "ö", "õ", "ø"],
        "s": ["ś", "š", "ß"],
        "u": ["ú", "ù", "û", "ü", "ū"],
        "y": ["ý", "ÿ"],
        "z": ["ź", "ż", "ž"],
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["€", "£", "¥", "₩", "¢"],
        "&": ["§"],
        "\"": ["“", "”", "„", "«", "»"],
        "'": ["‘", "’", "`"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "%": ["‰"],
        "=": ["≠", "≈"],
    ]
}
