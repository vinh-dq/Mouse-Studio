import SwiftUI
import UniformTypeIdentifiers

/// Compact pop-up on a rule row for changing what the rule does.
struct ActionMenu: View {
    let interaction: Interaction
    let current: Action
    let onSelect: (Action) -> Void

    @LocalState private var detail: ActionDetail?

    var body: some View {
        Menu {
            ForEach(ActionChoice.sections(for: interaction)) { section in
                if let title = section.title {
                    Section(title) { items(section) }
                } else {
                    items(section)
                }
            }
        } label: {
            HStack(spacing: 8) {
                IconTile(symbol: current.symbol, tint: current.tint, size: 22)
                Text(current.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(width: 230, height: 30)
            .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .sheet(item: $detail) { kind in
            ActionDetailSheet(kind: kind, current: current, onSave: onSelect)
        }
    }

    private func items(_ section: ActionChoice.Section) -> some View {
        ForEach(section.choices) { choice in
            Button {
                switch choice.pick() {
                case .action(let action): onSelect(action)
                case .detail(let kind): detail = kind
                case .chooseApp: if let action = chooseAppAction() { onSelect(action) }
                }
            } label: {
                Label(choice.title, systemImage: choice.symbol)
            }
        }
    }
}

/// One thing a rule can do, as offered in menus and in the action picker.
struct ActionChoice: Identifiable {
    enum Outcome {
        case action(Action)
        case detail(ActionDetail)
        case chooseApp
    }

    struct Section: Identifiable {
        let title: String?
        let choices: [ActionChoice]
        var id: String { title ?? choices.first?.id ?? "-" }
    }

    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let caption: String?
    private let outcome: Outcome
    private let matches: (Action) -> Bool

    func pick() -> Outcome { outcome }
    func isSelected(_ action: Action?) -> Bool { action.map(matches) ?? false }

    /// What is configured, shown on custom choices (for example the recorded shortcut).
    func caption(for action: Action?) -> String? {
        guard let action, matches(action) else { return caption }
        switch action {
        case .keyboardShortcut(let combo): return combo.display
        case .openApp: return action.title
        case .openURL(let url): return url
        case .runScript(let command): return command
        default: return caption
        }
    }

    private init(_ action: Action) {
        id = "action-\(action.title)"
        title = action.title
        symbol = action.symbol
        tint = action.tint
        caption = action.summary
        outcome = .action(action)
        matches = { $0 == action }
    }

    private init(id: String, title: String, symbol: String, tint: Color, caption: String, outcome: Outcome, matches: @escaping (Action) -> Bool) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.caption = caption
        self.outcome = outcome
        self.matches = matches
    }

    private static func system(_ actions: [SystemAction]) -> [ActionChoice] {
        actions.map { ActionChoice(.system($0)) }
    }

    static func sections(for interaction: Interaction) -> [Section] {
        switch interaction {
        case .drag:
            [Section(title: nil, choices: [ActionChoice(.dragScroll), ActionChoice(.swipeGesture)])]
        case .scroll:
            [Section(title: nil, choices: [ActionChoice(.scrollZoom), ActionChoice(.scrollVolume)])]
        case .click, .doubleClick, .hold:
            [
                Section(title: "Mouse", choices: [ActionChoice(.mouseButton(.middle)), ActionChoice(.none)]),
                Section(title: "Navigate", choices: system([.back, .forward, .spaceLeft, .spaceRight])),
                Section(title: "macOS", choices: system([.missionControl, .appExpose, .showDesktop, .launchpad, .previousApp, .minimizeWindow, .closeWindow])),
                Section(title: "Media", choices: system([.volumeUp, .volumeDown, .mute, .playPause, .nextTrack, .previousTrack])),
                Section(title: "Custom", choices: custom),
            ]
        }
    }

    private static let custom: [ActionChoice] = [
        ActionChoice(id: "shortcut", title: "Keyboard Shortcut", symbol: "command", tint: .gray, caption: "Press keys to record",
                     outcome: .detail(.shortcut)) { if case .keyboardShortcut = $0 { true } else { false } },
        ActionChoice(id: "app", title: "Open App", symbol: "app", tint: .teal, caption: "Launch any application",
                     outcome: .chooseApp) { if case .openApp = $0 { true } else { false } },
        ActionChoice(id: "url", title: "Open URL", symbol: "link", tint: .teal, caption: "Open a web page or link",
                     outcome: .detail(.url)) { if case .openURL = $0 { true } else { false } },
        ActionChoice(id: "script", title: "Run Script", symbol: "terminal", tint: .orange, caption: "Run a shell command",
                     outcome: .detail(.script)) { if case .runScript = $0 { true } else { false } },
    ]
}

func chooseAppAction() -> Action? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowsMultipleSelection = false
    panel.message = "Choose the app this button should open"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return .openApp(path: url.path)
}

enum ActionDetail: String, Identifiable {
    case shortcut, url, script
    var id: String { rawValue }
}

/// Asks for the one piece of text or input a custom action needs.
struct ActionDetailSheet: View {
    let kind: ActionDetail
    let current: Action?
    let onSave: (Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @LocalState private var combo: KeyCombo?
    @LocalState private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(explanation))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch kind {
            case .shortcut:
                KeyRecorder(combo: $combo)
            case .url:
                TextField("https://example.com", text: $text)
                    .textFieldStyle(.roundedBorder)
            case .script:
                TextField("Command, for example: open -a Calculator", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(kind == .script ? "Save Script" : "Save") {
                    if let action = builtAction {
                        onSave(action)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(builtAction == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: loadCurrent)
    }

    private var title: String {
        switch kind {
        case .shortcut: "Keyboard Shortcut"
        case .url: "Open URL"
        case .script: "Run Script"
        }
    }

    private var explanation: String {
        switch kind {
        case .shortcut: "Press the keys you want this button to send."
        case .url: "This link opens in your default app for it, usually your browser."
        case .script: "This command runs in the shell each time the gesture happens. Only use commands you trust."
        }
    }

    private var builtAction: Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .shortcut:
            return combo.map(Action.keyboardShortcut)
        case .url:
            guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
            return .openURL(trimmed)
        case .script:
            return trimmed.isEmpty ? nil : .runScript(trimmed)
        }
    }

    private func loadCurrent() {
        switch (kind, current) {
        case (.shortcut, .keyboardShortcut(let existing)?): combo = existing
        case (.url, .openURL(let existing)?): text = existing
        case (.script, .runScript(let existing)?): text = existing
        default: break
        }
    }
}
