import Foundation

/// What turning the wheel does while a modifier key is held.
enum WheelModifierAction: String, CaseIterable, Sendable {
    case horizontalScroll, zoom, swift, precise

    var title: String {
        switch self {
        case .horizontalScroll: String(localized: "Scroll Horizontally")
        case .zoom: String(localized: "Zoom In or Out")
        case .swift: String(localized: "Scroll Swiftly")
        case .precise: String(localized: "Scroll Precisely")
        }
    }

    /// Distance multiplier for the two speed actions.
    var speedFactor: Double {
        switch self {
        case .swift: 3
        case .precise: 0.3
        default: 1
        }
    }
}

/// Mouse wheel behaviour (real wheels only; Trackpads and Magic Mouse are never touched).
struct WheelSettings: Codable, Equatable, Sendable {
    static let speedRange = 0.25...4.0
    static let zoomStepRange = 0.03...0.25

    /// How much one wheel click zooms (5% = each click makes the picture 10% bigger or smaller).
    var zoomStep = 0.05
    var reverseVertical = false
    var reverseHorizontal = false
    var speed = 1.0
    /// How much faster turning the wheel quickly scrolls. 0 = every notch scrolls the same distance,
    /// however fast the wheel is turned.
    var acceleration = 0.0
    /// Eases each wheel notch into a continuous glide, like a Trackpad.
    var smooth = true
    /// 0 = quick, 1 = long glide.
    var smoothness = 0.5
    /// Keys that switch the wheel to another job. An empty set means "not assigned".
    var horizontalScrollKeys: ModifierSet = .shift
    var zoomKeys: ModifierSet = .command
    var swiftKeys: ModifierSet = .control
    var preciseKeys: ModifierSet = .option

    init() {}

    static let recommended: WheelSettings = {
        var settings = WheelSettings()
        settings.reverseVertical = true
        settings.speed = 1.0
        settings.acceleration = 0.05
        settings.smoothness = 0.5
        settings.zoomStep = 0.07
        return settings
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WheelSettings()
        reverseVertical = try container.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? defaults.reverseVertical
        reverseHorizontal = try container.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? defaults.reverseHorizontal
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? defaults.speed
        zoomStep = min(max(try container.decodeIfPresent(Double.self, forKey: .zoomStep) ?? defaults.zoomStep, Self.zoomStepRange.lowerBound), Self.zoomStepRange.upperBound)
        acceleration = try container.decodeIfPresent(Double.self, forKey: .acceleration) ?? defaults.acceleration
        smooth = try container.decodeIfPresent(Bool.self, forKey: .smooth) ?? defaults.smooth
        smoothness = try container.decodeIfPresent(Double.self, forKey: .smoothness) ?? defaults.smoothness
        horizontalScrollKeys = try container.decodeIfPresent(ModifierSet.self, forKey: .horizontalScrollKeys) ?? defaults.horizontalScrollKeys
        zoomKeys = try container.decodeIfPresent(ModifierSet.self, forKey: .zoomKeys) ?? defaults.zoomKeys
        swiftKeys = try container.decodeIfPresent(ModifierSet.self, forKey: .swiftKeys) ?? defaults.swiftKeys
        preciseKeys = try container.decodeIfPresent(ModifierSet.self, forKey: .preciseKeys) ?? defaults.preciseKeys
    }

    func keys(for action: WheelModifierAction) -> ModifierSet {
        switch action {
        case .horizontalScroll: horizontalScrollKeys
        case .zoom: zoomKeys
        case .swift: swiftKeys
        case .precise: preciseKeys
        }
    }

    /// Assigns keys to an action; any other action that had the same keys loses them.
    mutating func assign(_ keys: ModifierSet, to action: WheelModifierAction) {
        for other in WheelModifierAction.allCases where other != action && !keys.isEmpty && self.keys(for: other) == keys {
            set([], for: other)
        }
        set(keys, for: action)
    }

    private mutating func set(_ keys: ModifierSet, for action: WheelModifierAction) {
        switch action {
        case .horizontalScroll: horizontalScrollKeys = keys
        case .zoom: zoomKeys = keys
        case .swift: swiftKeys = keys
        case .precise: preciseKeys = keys
        }
    }

    /// The job for exactly these held keys, if one is assigned.
    func action(for modifiers: ModifierSet) -> WheelModifierAction? {
        guard !modifiers.isEmpty else { return nil }
        return WheelModifierAction.allCases.first { keys(for: $0) == modifiers }
    }

    /// False when nothing would change, so the wheel is left completely alone.
    var isActive: Bool {
        reverseVertical || reverseHorizontal || smooth || speed != 1
    }

    func clamped() -> WheelSettings {
        var copy = self
        copy.speed = speed.clamped(to: Self.speedRange)
        copy.smoothness = smoothness.clamped(to: 0...1)
        copy.acceleration = acceleration.clamped(to: 0...1)
        return copy
    }
}
