import Foundation

/// How the user operates a button.
enum Interaction: String, Codable, CaseIterable, Sendable {
    case click
    case doubleClick
    case hold
    case drag
    case scroll

    var title: String {
        switch self {
        case .click: String(localized: "Click")
        case .doubleClick: String(localized: "Double Click")
        case .hold: String(localized: "Hold")
        case .drag: String(localized: "Click and Drag")
        case .scroll: String(localized: "Click and Scroll")
        }
    }

    var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// What starts a rule: a button, the modifier keys held with it, and how the button is used.
struct Trigger: Hashable, Codable, Sendable {
    var button: MouseButton
    var modifiers: ModifierSet
    var interaction: Interaction

    /// The left and right buttons need a modifier (so the user can't lock themselves out) and never
    /// support double click: Finder, browsers and every app depend on its exact timing.
    var isAllowed: Bool {
        guard button.isPrimary else { return true }
        return !modifiers.isEmpty && interaction != .doubleClick
    }

    var title: String {
        let prefix = modifiers.isEmpty ? "" : modifiers.symbols + " "
        return "\(prefix)\(button.name) · \(interaction.title)"
    }
}
