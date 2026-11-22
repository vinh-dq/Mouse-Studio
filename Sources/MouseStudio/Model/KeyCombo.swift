import Foundation

/// A keyboard shortcut recorded from the keyboard.
struct KeyCombo: Hashable, Codable, Sendable {
    var keyCode: UInt16
    var modifiers: ModifierSet
    var keyLabel: String

    var display: String {
        modifiers.symbols + keyLabel
    }

    static func label(forKeyCode keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let characters, let first = characters.first, !first.isWhitespace, !first.isNewline {
            return String(first).uppercased()
        }
        return String(localized: "Key \(Int(keyCode))")
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
    ]
}
