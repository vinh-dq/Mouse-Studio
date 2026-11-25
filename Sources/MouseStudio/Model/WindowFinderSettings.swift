import CoreGraphics
import Foundation

/// The modifier key that opens the window finder when it is held on its own.
enum FinderKey: String, Codable, CaseIterable, Sendable {
    case rightOption, leftOption, rightCommand, rightControl

    var title: String {
        switch self {
        case .rightOption: String(localized: "Right Option")
        case .leftOption: String(localized: "Left Option")
        case .rightCommand: String(localized: "Right Command")
        case .rightControl: String(localized: "Right Control")
        }
    }

    var symbol: String {
        switch self {
        case .rightOption, .leftOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        }
    }

    /// The bit that says this physical key is down (device-dependent part of `CGEventFlags`).
    var deviceBit: UInt64 {
        switch self {
        case .rightOption: 0x40
        case .leftOption: 0x20
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        }
    }

    /// Both physical keys of this modifier; the other one must not be down as well.
    var familyBits: UInt64 {
        switch self {
        case .rightOption, .leftOption: 0x60
        case .rightCommand: 0x18
        case .rightControl: 0x2001
        }
    }

    /// The logical modifier flag (⌥, ⌘ or ⌃).
    var flag: UInt64 {
        switch self {
        case .rightOption, .leftOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl: CGEventFlags.maskControl.rawValue
        }
    }
}

/// How the list is laid out.
enum FinderLayout: String, Codable, CaseIterable, Sendable {
    /// A list on the left and a large picture of the chosen window on the right.
    case split
    /// Cards with a picture each.
    case cards
}

/// Settings of "Find Windows": hold a key, type part of a window's title, let go to jump there.
struct WindowFinderSettings: Codable, Equatable, Sendable {
    static let delayRange = 0.15...0.6

    var isEnabled = true
    var key = FinderKey.rightOption
    /// How long the key must be held before the list appears. A tap, or any other key pressed sooner, is left alone.
    var delay = 0.25
    /// Show a picture of each window. Needs the Screen Recording permission; without it the list shows app icons.
    var showPreviews = true
    /// Opens the list and keeps it open (type, ↩ to switch, esc to cancel), without holding anything.
    var shortcut: KeyCombo?
    var layout = FinderLayout.split
    /// What you pick for what you typed moves that window up next time.
    var rememberChoices = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WindowFinderSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        key = (try? container.decodeIfPresent(FinderKey.self, forKey: .key)) ?? defaults.key
        delay = try container.decodeIfPresent(Double.self, forKey: .delay) ?? defaults.delay
        showPreviews = try container.decodeIfPresent(Bool.self, forKey: .showPreviews) ?? defaults.showPreviews
        shortcut = try? container.decodeIfPresent(KeyCombo.self, forKey: .shortcut)
        layout = (try? container.decodeIfPresent(FinderLayout.self, forKey: .layout)) ?? defaults.layout
        rememberChoices = try container.decodeIfPresent(Bool.self, forKey: .rememberChoices) ?? defaults.rememberChoices
    }

    func clamped() -> WindowFinderSettings {
        var copy = self
        copy.delay = delay.clamped(to: Self.delayRange)
        return copy
    }
}

extension FinderLayout: Identifiable {
    var id: String { rawValue }
}

extension FinderKey: Identifiable {
    var id: String { rawValue }
}
