import Foundation

/// Everything that is saved to disk.
struct AppConfig: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion = AppConfig.currentSchemaVersion
    var isEnabled = true
    var rules: [Rule] = AppConfig.defaultRules
    var scroll = ScrollSettings.recommended
    var wheel = WheelSettings.recommended
    var swipe = SwipeSettings.recommended
    /// Turn off to stop using undocumented macOS features (smooth pinch zoom, interactive Spaces swipe); zoom then
    /// uses ⌘+ / ⌘− and Spaces use their keyboard shortcuts.
    var usePrivateFeatures = true
    var excludedApps: [ExcludedApp] = []
    var devices: [DeviceProfile] = []

    /// What a fresh install, "Reset to Defaults" and a file without rules start from: the author's own tuned setup.
    static var defaultRules: [Rule] {
        func rule(_ button: MouseButton, _ modifiers: ModifierSet, _ interaction: Interaction, _ action: Action) -> Rule {
            Rule(trigger: Trigger(button: button, modifiers: modifiers, interaction: interaction), action: action)
        }
        return [
            rule(MouseButton(number: 3), [], .drag, .dragScroll),
            rule(MouseButton(number: 4), [], .drag, .dragScroll),
            rule(MouseButton(number: 3), [], .scroll, .scrollZoom),
            rule(MouseButton(number: 4), [], .scroll, .scrollZoom),
            rule(MouseButton(number: 2), [], .drag, .swipeGesture),
            rule(.left, [.control], .drag, .dragScroll),
            rule(.left, [.command], .drag, .swipeGesture),
        ]
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        scroll = try container.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        wheel = try container.decodeIfPresent(WheelSettings.self, forKey: .wheel) ?? WheelSettings()
        swipe = try container.decodeIfPresent(SwipeSettings.self, forKey: .swipe) ?? SwipeSettings()
        usePrivateFeatures = try container.decodeIfPresent(Bool.self, forKey: .usePrivateFeatures) ?? true
        excludedApps = (try container.decodeIfPresent([Lossy<ExcludedApp>].self, forKey: .excludedApps) ?? []).compactMap(\.value)
        devices = (try container.decodeIfPresent([Lossy<DeviceProfile>].self, forKey: .devices) ?? []).compactMap(\.value)
        // Version 2 made wheel scrolling linear. Older files carry an acceleration that was tuned against the
        // old behaviour, so it starts from the new default.
        if schemaVersion < 2 { wheel.acceleration = WheelSettings().acceleration }
        schemaVersion = Self.currentSchemaVersion
        // A single unreadable rule (for example from a newer version) must not discard the others.
        let lossy = try container.decodeIfPresent([Lossy<Rule>].self, forKey: .rules)
        rules = lossy?.compactMap(\.value) ?? Self.defaultRules
    }

    /// Drops invalid and duplicate rules (earlier rules win) and clamps numeric settings.
    func sanitized() -> AppConfig {
        var copy = self
        var seen = Set<Trigger>()
        copy.rules = rules.filter { rule in
            rule.isValid && seen.insert(rule.trigger).inserted
        }
        copy.scroll = scroll.clamped()
        copy.wheel = wheel.clamped()
        copy.swipe = swipe.clamped()
        var seenApps = Set<String>()
        copy.excludedApps = excludedApps.filter { !$0.bundleID.isEmpty && seenApps.insert($0.bundleID).inserted }
        var seenDevices = Set<String>()
        copy.devices = devices.filter { !$0.key.isEmpty && seenDevices.insert($0.key).inserted }.map { $0.clamped() }
        return copy
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
