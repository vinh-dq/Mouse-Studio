import CoreGraphics

/// The modifier keys a rule can require: Control, Option, Shift and Command.
struct ModifierSet: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8

    static let control = ModifierSet(rawValue: 1 << 0)
    static let option = ModifierSet(rawValue: 1 << 1)
    static let shift = ModifierSet(rawValue: 1 << 2)
    static let command = ModifierSet(rawValue: 1 << 3)

    /// Display order follows the macOS convention: ⌃ ⌥ ⇧ ⌘.
    static let ordered: [(modifier: ModifierSet, symbol: String, name: String)] = [
        (.control, "⌃", String(localized: "Control")),
        (.option, "⌥", String(localized: "Option")),
        (.shift, "⇧", String(localized: "Shift")),
        (.command, "⌘", String(localized: "Command")),
    ]

    init(rawValue: UInt8) {
        self.rawValue = rawValue & 0b1111
    }

    init(cgFlags: CGEventFlags) {
        var set: ModifierSet = []
        if cgFlags.contains(.maskControl) { set.insert(.control) }
        if cgFlags.contains(.maskAlternate) { set.insert(.option) }
        if cgFlags.contains(.maskShift) { set.insert(.shift) }
        if cgFlags.contains(.maskCommand) { set.insert(.command) }
        self = set
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    var symbols: String {
        Self.ordered.filter { contains($0.modifier) }.map(\.symbol).joined()
    }
}
