import SwiftUI

struct WindowsView: View {
    @EnvironmentObject private var model: AppModel
    @LocalState private var hasScreenAccess = WindowThumbnailer.hasAccess
    /// Which shortcut was just refused because the other list already uses it.
    @LocalState private var refusedShortcut: FinderMode?

    private var store: ConfigStore { model.store }
    private var settings: WindowFinderSettings { store.config.windowFinder }

    /// The two shortcuts must differ, or one of them would never be reached.
    private var windowsShortcut: Binding<KeyCombo?> {
        Binding(
            get: { settings.shortcut },
            set: { new in
                if let new, new == settings.tabShortcut {
                    refusedShortcut = .windows
                } else {
                    refusedShortcut = nil
                    store.update { $0.windowFinder.shortcut = new }
                }
            }
        )
    }

    private var tabsShortcut: Binding<KeyCombo?> {
        Binding(
            get: { settings.tabShortcut },
            set: { new in
                if let new, new == settings.shortcut {
                    refusedShortcut = .tabs
                } else {
                    refusedShortcut = nil
                    store.update { $0.windowFinder.tabShortcut = new }
                }
            }
        )
    }

    var body: some View {
        SettingsPage {
            PermissionBanner()

            SettingsGroup(footer: "Hold the key, type a few letters of an app or a window title, and let go to jump there. A quick tap, or any other key pressed sooner, still belongs to your app.") {
                FinderIllustration(keySymbol: settings.key.symbol)
                    .frame(height: 168)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }

            SettingsGroup(title: "Look") {
                HStack(spacing: 12) {
                    ForEach(FinderLayout.allCases) { layout in
                        LayoutTile(layout: layout, isSelected: settings.layout == layout) {
                            store.update { $0.windowFinder.layout = layout }
                        }
                    }
                }
                .padding(14)
            }

            SettingsGroup(title: "Find Windows") {
                ToggleRow(title: String(localized: "Hold \(settings.key.title) to find windows"), isOn: store.binding(\.windowFinder.isEnabled))
                SettingsDivider()
                SettingRow(
                    title: "Shortcut",
                    detail: "Opens the list and keeps it open: type, press ↩ to switch or esc to close. No need to hold anything. Press it again to search browser tabs, and once more to close."
                ) {
                    HStack(spacing: 8) {
                        KeyRecorder(combo: windowsShortcut, compact: true)
                            .frame(width: 170)
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
                if refusedShortcut == .windows {
                    ShortcutWarning(text: "That shortcut already opens the tabs list. Choose another one.")
                }
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
                title: "Find Tabs",
                footer: "Safari and Chromium browsers (Chrome, Edge, Brave, Vivaldi, Opera, Arc). macOS asks once for each browser before Mouse Studio may read its tabs. Titles and addresses are read only while the list is open; nothing is saved or sent anywhere, and what you pick in private windows is never remembered."
            ) {
                ToggleRow(
                    title: "Search browser tabs",
                    detail: "Press ⇥ in the list, or press the shortcut above a second time, to switch between windows and tabs.",
                    isOn: store.binding(\.windowFinder.tabsEnabled)
                )
                .disabled(!settings.isEnabled)
                SettingsDivider()
                SettingRow(
                    title: "Tabs shortcut",
                    detail: "Opens the list straight on the tabs. Press it again to close, or from the windows to switch to the tabs."
                ) {
                    HStack(spacing: 8) {
                        KeyRecorder(combo: tabsShortcut, compact: true)
                            .frame(width: 170)
                        if settings.tabShortcut != nil {
                            Button { store.update { $0.windowFinder.tabShortcut = nil } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove the shortcut")
                        }
                    }
                }
                .disabled(!settings.isEnabled || !settings.tabsEnabled)
                if refusedShortcut == .tabs {
                    ShortcutWarning(text: "That shortcut already opens the windows list. Choose another one.")
                }
                SettingsDivider()
                ActionRow(
                    title: "Open Automation Settings",
                    detail: "Switch Mouse Studio on for each browser you want to search.",
                    symbol: "lock.shield"
                ) { Automation.openSettings() }
            }

            SettingsGroup(
                title: "Learning",
                footer: "Kept only on this Mac, as counts of what you picked for what you typed."
            ) {
                ToggleRow(title: "Remember my choices", detail: "The window you usually pick for “sh” comes first next time.", isOn: store.binding(\.windowFinder.rememberChoices))
                SettingsDivider()
                ActionRow(title: "Forget What I Picked", symbol: "arrow.counterclockwise", role: .destructive) { WindowFinder.shared.forgetHistory() }
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
                ShortcutRow(keys: ["A", "B", "C"], text: "Filter by app name and window title (or tab title and address); accents don't matter")
                SettingsDivider()
                ShortcutRow(keys: ["⇥"], text: "Switch between searching windows and browser tabs")
                SettingsDivider()
                ShortcutRow(keys: ["←", "→", "↑", "↓"], text: "Choose a window, or move the pointer over one")
                SettingsDivider()
                ShortcutRow(keys: ["Space"], text: "Quick look at the chosen window")
                SettingsDivider()
                ShortcutRow(keys: ["⌘W", "⌘M"], text: "Close or minimize the chosen window")
                SettingsDivider()
                ShortcutRow(keys: ["⌘W"], text: "In the tabs: close the chosen tab")
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

private struct ShortcutWarning: View {
    let text: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        Keycap(label: "↩")
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

/// A small picture of one layout, to choose by looking.
private struct LayoutTile: View {
    let layout: FinderLayout
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                    sketch.padding(10)
                }
                .frame(height: 78)
                Text(layout == .split ? "List with preview" : "Cards")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var sketch: some View {
        switch layout {
        case .split:
            HStack(spacing: 6) {
                VStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { row in
                        RoundedRectangle(cornerRadius: 3).fill(row == 1 ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.2)).frame(height: 9)
                    }
                }
                .frame(width: 44)
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.blue.opacity(0.5), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        case .cards:
            VStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(row == 0 && column == 1 ? Color.accentColor.opacity(0.6) : [Color.orange, .pink, .green, .teal, .indigo, .mint][row * 3 + column].opacity(0.45))
                        }
                    }
                }
            }
        }
    }
}
