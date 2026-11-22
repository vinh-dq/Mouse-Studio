import Foundation

/// A read-only lookup built from the enabled rules, shaped for the event path:
/// one dictionary lookup per button press. Earlier rules win when two share a trigger.
struct RuleSet {
    /// Everything configured for one button + exact modifier combination.
    struct PressRules {
        var click: Action?
        var doubleClick: Action?
        var hold: Action?
        var drag: Action?
        var scroll: Action?
    }

    private struct Key: Hashable {
        var button: Int
        var modifiers: UInt8
    }

    private var table: [Key: PressRules] = [:]

    var isEmpty: Bool { table.isEmpty }

    init(rules: [Rule] = []) {
        for rule in rules where rule.isEnabled && rule.isValid {
            let key = Key(button: rule.trigger.button.number, modifiers: rule.trigger.modifiers.rawValue)
            var entry = table[key] ?? PressRules()
            switch rule.trigger.interaction {
            case .click: entry.click = entry.click ?? rule.action
            case .doubleClick: entry.doubleClick = entry.doubleClick ?? rule.action
            case .hold: entry.hold = entry.hold ?? rule.action
            case .drag: entry.drag = entry.drag ?? rule.action
            case .scroll: entry.scroll = entry.scroll ?? rule.action
            }
            table[key] = entry
        }
    }

    /// Modifiers must match exactly: a rule for ⌘ + Button 4 does not fire for ⌘⇧ + Button 4.
    func rules(for button: MouseButton, modifiers: ModifierSet) -> PressRules? {
        table[Key(button: button.number, modifiers: modifiers.rawValue)]
    }
}
