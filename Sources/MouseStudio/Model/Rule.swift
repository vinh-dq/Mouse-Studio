import Foundation

/// One line of configuration: trigger → action, with an on/off switch.
struct Rule: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var isEnabled = true
    var trigger: Trigger
    var action: Action

    var isValid: Bool {
        trigger.isAllowed && action.isAllowed(for: trigger.interaction)
    }
}
