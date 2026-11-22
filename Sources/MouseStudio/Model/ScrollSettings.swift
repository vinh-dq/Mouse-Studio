import Foundation

enum AxisLock: String, Codable, CaseIterable, Sendable {
    case free
    case horizontal
    case vertical

    var title: String {
        switch self {
        case .free: String(localized: "Free (any direction)")
        case .horizontal: String(localized: "Horizontal only")
        case .vertical: String(localized: "Vertical only")
        }
    }
}

/// Tuning for Drag Scroll. Ranges are enforced by `clamped()`.
struct ScrollSettings: Codable, Equatable, Sendable {
    static let speedRange = 0.2...3.0

    var sensitivity = 1.0
    var horizontalSpeed = 1.0
    var verticalSpeed = 1.0
    /// 0 = raw, 1 = heavily smoothed.
    var smoothness = 0.25
    /// How far the content keeps gliding after the button is released. 0 = stops at once.
    var inertia = 0.5
    var invertDirection = false
    var axisLock = AxisLock.free
    var freezeCursor = true

    init() {}

    /// The tuned setup new installs start from (the plain `init()` stays neutral for files that lack a value).
    static let recommended: ScrollSettings = {
        var settings = ScrollSettings()
        settings.sensitivity = 1.5
        settings.horizontalSpeed = 0.94
        settings.verticalSpeed = 1.22
        settings.smoothness = 0.5
        settings.inertia = 0.25
        settings.freezeCursor = false
        return settings
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScrollSettings()
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? defaults.sensitivity
        horizontalSpeed = try container.decodeIfPresent(Double.self, forKey: .horizontalSpeed) ?? defaults.horizontalSpeed
        verticalSpeed = try container.decodeIfPresent(Double.self, forKey: .verticalSpeed) ?? defaults.verticalSpeed
        smoothness = try container.decodeIfPresent(Double.self, forKey: .smoothness) ?? defaults.smoothness
        inertia = try container.decodeIfPresent(Double.self, forKey: .inertia) ?? defaults.inertia
        invertDirection = try container.decodeIfPresent(Bool.self, forKey: .invertDirection) ?? defaults.invertDirection
        axisLock = try container.decodeIfPresent(AxisLock.self, forKey: .axisLock) ?? defaults.axisLock
        freezeCursor = try container.decodeIfPresent(Bool.self, forKey: .freezeCursor) ?? defaults.freezeCursor
    }

    func clamped() -> ScrollSettings {
        var copy = self
        copy.sensitivity = sensitivity.clamped(to: Self.speedRange)
        copy.horizontalSpeed = horizontalSpeed.clamped(to: Self.speedRange)
        copy.verticalSpeed = verticalSpeed.clamped(to: Self.speedRange)
        copy.smoothness = smoothness.clamped(to: 0...1)
        copy.inertia = inertia.clamped(to: 0...1)
        return copy
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
