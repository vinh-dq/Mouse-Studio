import SwiftUI

struct WindowsView: View {
    @EnvironmentObject private var model: AppModel
    @LocalState private var hasScreenAccess = WindowThumbnailer.hasAccess

    private var store: ConfigStore { model.store }
    private var settings: WindowFinderSettings { store.config.windowFinder }

    var body: some View {
        SettingsPage {
            PermissionBanner()

            SettingsGroup(footer: "Hold the key, type a few letters of an app or a window title, and let go to jump there. A quick tap, or any other key pressed sooner, still belongs to your app.") {
                FinderIllustration(keySymbol: settings.key.symbol)
                    .frame(height: 168)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }

            SettingsGroup(title: "Find Windows") {
                ToggleRow(title: String(localized: "Hold \(settings.key.title) to find windows"), isOn: store.binding(\.windowFinder.isEnabled))
                SettingsDivider()
                SettingRow(
                    title: "Shortcut",
                    detail: "Opens the list and keeps it open: type, press ↩ to switch or esc to close. No need to hold anything."
                ) {
                    HStack(spacing: 8) {
                        KeyRecorder(combo: store.binding(\.windowFinder.shortcut))
                            .frame(width: 150)
                        if settings.shortcut != nil {
                            Button { store.update { $0.windowFinder.shortcut = nil } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove the shortcut")
                        }
                    }
                }
                .disabled(!settings.isEnabled)
                SettingsDivider()
                PickerRow(title: "Key", selection: store.binding(\.windowFinder.key)) {
                    ForEach(FinderKey.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.isEnabled)
                SettingsDivider()
                SliderRow(
                    title: "Delay before the list appears",
                    detail: "Tap quickly, or press another key sooner, and the key stays with your app.",
                    value: store.binding(\.windowFinder.delay),
                    range: WindowFinderSettings.delayRange,
                    format: "%.2f s"
                )
                .disabled(!settings.isEnabled)
            }

            SettingsGroup(
                title: "Previews",
                footer: "Mouse Studio only reads window titles and takes small pictures while the list is open. Nothing is saved or sent anywhere."
            ) {
                ToggleRow(title: "Show a picture of each window", detail: "Without it the list shows app icons.", isOn: store.binding(\.windowFinder.showPreviews))
                if settings.showPreviews && !hasScreenAccess {
                    SettingsDivider()
                    SettingRow(title: "Screen Recording access needed", detail: "macOS asks for it before any app may take pictures of windows.") {
                        Button("Allow…") {
                            WindowThumbnailer.requestAccess()
                            WindowThumbnailer.openSystemSettings()
                        }
                    }
                }
            }

            SettingsGroup(title: "In the list", footer: "You can also open the list with a mouse button: add a gesture in Buttons and choose Find Window.") {
                ShortcutRow(keys: ["A", "B", "C"], text: "Filter by app name and window title; accents don't matter")
                SettingsDivider()
                ShortcutRow(keys: ["⇥", "←", "→", "↑", "↓"], text: "Choose a window, or move the pointer over one")
                SettingsDivider()
                ShortcutRow(keys: ["Space"], text: "Quick look at the chosen window")
                SettingsDivider()
                ShortcutRow(keys: ["⌘W", "⌘M"], text: "Close or minimize the chosen window")
                SettingsDivider()
                ShortcutRow(keys: ["⌘Q", "⌘H"], text: "Quit or hide the app of that window")
                SettingsDivider()
                ShortcutRow(keys: [settings.key.symbol], text: "Let go to switch, if you typed, chose or looked at a window")
                SettingsDivider()
                ShortcutRow(keys: ["↩"], text: "Switch right away")
                SettingsDivider()
                ShortcutRow(keys: ["esc"], text: "Cancel")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenAccess = WindowThumbnailer.hasAccess
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
                .frame(width: 118, alignment: .leading)
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// A small picture of the list: cards moving the highlight along, with the keys that do it.
private struct FinderIllustration: View {
    let keySymbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.blue.opacity(0.28), Color.purple.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
            TimelineView(.periodic(from: .now, by: 1.6)) { context in
                let step = reduceMotion ? 1 : Int(context.date.timeIntervalSinceReferenceDate / 1.6) % 3
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text(["", "saf", "safari"][step])
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { index in
                            MiniCard(tint: [Color.orange, .pink, .green][index], isSelected: index == (step == 0 ? 1 : 0))
                        }
                    }
                    .padding(.horizontal, 10)
                    HStack(spacing: 6) {
                        Keycap(label: keySymbol)
                        Keycap(label: "A")
                        Keycap(label: "Space")
                    }
                }
                .padding(.vertical, 12)
                .frame(width: 330)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .animation(.snappy(duration: 0.3), value: step)
            }
        }
    }
}

private struct MiniCard: View {
    let tint: Color
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.gradient)
                .frame(height: 38)
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25)).frame(height: 4)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5))
    }
}
