import Foundation

/// Spaces & Mission Control drag. `speed` 1 is how far the desktops move per pointer travel by default
/// (20% slower than the first version, which felt too quick under the hand).
struct SwipeSettings: Codable, Equatable, Sendable {
    static let speedRange = 0.5...1.5

    var speed = 1.0

    init() {}

    static let recommended: SwipeSettings = {
        var settings = SwipeSettings()
        settings.speed = 0.8
        return settings
    }()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? SwipeSettings().speed
    }

    func clamped() -> SwipeSettings {
        var copy = self
        copy.speed = speed.clamped(to: Self.speedRange)
        return copy
    }
}
