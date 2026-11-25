import AppKit
import SwiftUI

/// Records a keyboard shortcut by listening to the real keyboard.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo?
    /// A small version for a row in the settings.
    var compact = false
    @LocalState private var liveModifiers: ModifierSet = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: compact ? 1.5 : 2)
            Text(label)
                .font(.system(size: compact ? 13 : 20, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(combo == nil && liveModifiers.isEmpty ? .secondary : .primary)
            RecorderSurface(combo: $combo, liveModifiers: $liveModifiers)
        }
        .frame(height: compact ? 30 : 52)
        .accessibilityLabel("Shortcut recorder")
    }

    private var label: String {
        if let combo { return combo.display }
        return liveModifiers.isEmpty ? String(localized: "Press a shortcut…") : liveModifiers.symbols
    }
}

private struct RecorderSurface: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    @Binding var liveModifiers: ModifierSet

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onRecord = { combo = $0 }
        view.onModifiers = { liveModifiers = $0 }
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {}
}

private final class RecorderNSView: NSView {
    var onRecord: ((KeyCombo) -> Void)?
    var onModifiers: ((ModifierSet) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        onModifiers?(ModifierSet(event.modifierFlags))
    }

    /// Command shortcuts arrive here first; claiming them stops the app's own menu from reacting.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = ModifierSet(event.modifierFlags)
        let label = KeyCombo.label(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        onRecord?(KeyCombo(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label))
        onModifiers?([])
    }
}
