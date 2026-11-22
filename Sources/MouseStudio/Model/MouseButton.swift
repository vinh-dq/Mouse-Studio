import Foundation

/// A physical mouse button, identified by the macOS button number
/// (0 left, 1 right, 2 middle, 3 = "Button 4", 4 = "Button 5", ...).
struct MouseButton: Hashable, Codable, Comparable, Sendable {
    var number: Int

    static let left = MouseButton(number: 0)
    static let right = MouseButton(number: 1)
    static let middle = MouseButton(number: 2)

    /// Left and right buttons are needed to operate the Mac, so rules on them always require a modifier key.
    var isPrimary: Bool { number <= 1 }

    var name: String {
        switch number {
        case 0: String(localized: "Left Button")
        case 1: String(localized: "Right Button")
        case 2: String(localized: "Middle Button")
        default: String(localized: "Button \(number + 1)")
        }
    }

    var clickName: String {
        switch number {
        case 0: String(localized: "Left Click")
        case 1: String(localized: "Right Click")
        case 2: String(localized: "Middle Click")
        default: String(localized: "Button \(number + 1) Click")
        }
    }

    init(number: Int) {
        self.number = number
    }

    init(from decoder: Decoder) throws {
        number = try decoder.singleValueContainer().decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(number)
    }

    static func < (lhs: MouseButton, rhs: MouseButton) -> Bool {
        lhs.number < rhs.number
    }
}
