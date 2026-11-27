import AppKit
import SwiftUI

/// Records a keyboard shortcut by listening to the real keyboard.
/// A compact recorder (in the settings) listens only after it is clicked, takes one shortcut and stops;
/// esc, or a click elsewhere, stops it without a change. The large one (in a sheet) always listens.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo?
    /// A small version for a row in the settings.
    var compact = false
    @LocalState private var liveModifiers: ModifierSet = []
    @LocalState private var isRecording: Bool

    init(combo: Binding<KeyCombo?>, compact: Bool = false) {
        _combo = combo
        self.compact = compact
        _isRecording = LocalState(wrappedValue: !compact)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.22), lineWidth: compact ? (isRecording ? 1.5 : 1) : 2)
            Text(label)
                .font(.system(size: compact ? 13 : 20, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(combo == nil && liveModifiers.isEmpty ? .secondary : .primary)
            RecorderSurface(combo: $combo, liveModifiers: $liveModifiers, isRecording: $isRecording, alwaysOn: !compact)
        }
        .frame(height: compact ? 30 : 52)
        .animation(.easeOut(duration: 0.12), value: isRecording)
        .accessibilityLabel("Shortcut recorder")
    }

    private var label: String {
        if !isRecording { return combo?.display ?? String(localized: "Click to record") }
        if let combo, liveModifiers.isEmpty { return combo.display }
        return liveModifiers.isEmpty ? String(localized: "Press a shortcut…") : liveModifiers.symbols
    }
}

private struct RecorderSurface: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    @Binding var liveModifiers: ModifierSet
    @Binding var isRecording: Bool
    let alwaysOn: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onRecord = { combo = $0; if !alwaysOn { isRecording = false } }
        view.onModifiers = { liveModifiers = $0 }
        view.onStart = { isRecording = true }
        view.onStop = { isRecording = false; liveModifiers = [] }
        return view
    }

    func updateNSView(_ view: RecorderNSView, context: Context) {
        view.alwaysOn = alwaysOn
        view.isRecording = isRecording || alwaysOn
        guard !alwaysOn else { return }
        // Listening means holding the keyboard; stopping gives it back.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            if isRecording, window.firstResponder !== view {
                window.makeFirstResponder(view)
            } else if !isRecording, window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
    }
}

private final class RecorderNSView: NSView {
    var onRecord: ((KeyCombo) -> Void)?
    var onModifiers: ((ModifierSet) -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            FinderHotKey.shared.recorderChanged(isRecording: isRecording)
        }
    }
    var alwaysOn = false

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Going away while listening (the sheet closed, another tab opened) must give the shortcuts back.
        if newWindow == nil { isRecording = false }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard alwaysOn else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !alwaysOn else { return }
        onStart?()
    }

    /// Clicking elsewhere, or another recorder taking the keyboard, ends the recording.
    override func resignFirstResponder() -> Bool {
        if !alwaysOn { onStop?() }
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        onModifiers?(ModifierSet(event.modifierFlags))
    }

    /// Command shortcuts arrive here first; claiming them stops the app's own menu from reacting.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let modifiers = ModifierSet(event.modifierFlags)
        if !alwaysOn, event.keyCode == 53, modifiers.isEmpty {
            onStop?()
            return
        }
        let label = KeyCombo.label(forKeyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        onRecord?(KeyCombo(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label))
        onModifiers?([])
    }
}
