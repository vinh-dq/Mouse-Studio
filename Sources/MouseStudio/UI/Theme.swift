import SwiftUI

/// Shared look: quiet cards, system colors, one corner radius. Everything adapts to Light and Dark Mode.
enum Theme {
    static let corner: CGFloat = 12
    static let pageWidth: CGFloat = 540
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 5, y: 1)
    }
}

/// A rounded square with a white symbol, like the icons in System Settings.
struct IconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
    }
}

/// Modifier keys drawn as small keys: ⌃ ⌥ ⇧ ⌘.
struct KeyCaps: View {
    let modifiers: ModifierSet

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ModifierSet.ordered.filter { modifiers.contains($0.modifier) }, id: \.name) { entry in
                Text(entry.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 22, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .quaternarySystemFill)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5))
            }
        }
    }
}

extension SystemAction {
    var tint: Color {
        switch self {
        case .back, .forward, .spaceLeft, .spaceRight: .gray
        case .missionControl, .appExpose, .showDesktop, .launchpad, .previousApp, .minimizeWindow, .closeWindow: .blue
        case .volumeUp, .volumeDown, .mute, .playPause, .nextTrack, .previousTrack: .pink
        case .zoomIn, .zoomOut: .teal
        }
    }
}

extension Action {
    var tint: Color {
        switch self {
        case .none, .mouseButton, .keyboardShortcut: .gray
        case .system(let action): action.tint
        case .openApp, .openURL: .teal
        case .findWindow: .indigo
        case .runScript: .orange
        case .dragScroll, .swipeGesture, .scrollZoom, .scrollVolume: .blue
        }
    }

    /// One plain sentence for actions whose name alone isn't obvious.
    var summary: String? {
        switch self {
        case .dragScroll: String(localized: "Scroll in any direction, with momentum")
        case .swipeGesture: String(localized: "Slide Spaces and Mission Control by hand")
        case .scrollZoom: String(localized: "Scroll to zoom in and out")
        case .scrollVolume: String(localized: "Scroll to change the volume")
        case .findWindow: String(localized: "Type a few letters to jump to any window")
        case .none: String(localized: "Button does nothing")
        default: nil
        }
    }
}
