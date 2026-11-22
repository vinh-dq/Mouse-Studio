import AppKit
import SwiftUI

/// "Keyboard Modifiers": which key turns the wheel into which job. Each box records the keys the user holds.
struct WheelModifierKeys: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 28, verticalSpacing: 18) {
                GridRow {
                    cell(.horizontalScroll)
                    cell(.zoom)
                }
                GridRow {
                    cell(.swift)
                    cell(.precise)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func cell(_ action: WheelModifierAction) -> some View {
        let keys = Binding(
            get: { model.store.config.wheel.keys(for: action) },
            set: { newKeys in model.store.update { $0.wheel.assign(newKeys, to: action) } }
        )
        return VStack(spacing: 6) {
            Text(action.title).font(.callout)
            HStack(spacing: 8) {
                Button {
                    keys.wrappedValue = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(keys.wrappedValue.isEmpty ? 0.25 : 1)
                .disabled(keys.wrappedValue.isEmpty)
                .help("Remove this key")
                .accessibilityLabel("Remove key for \(action.title)")
                ModifierKeyField(keys: keys)
            }
        }
    }
}

/// A box that records modifier keys: click it, hold the keys, let go.
struct ModifierKeyField: View {
    @Binding var keys: ModifierSet
    @LocalState private var isRecording = false
    @LocalState private var live: ModifierSet = []

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button {
            live = []
            isRecording.toggle()
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(showsPlaceholder ? Color.secondary : Color.primary)
                .frame(width: 130, height: 32)
                .background(shape.fill(Color(nsColor: .textBackgroundColor)))
                .overlay(shape.strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isRecording ? 2 : 0.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background {
            if isRecording {
                ModifierCatcher(
                    onLive: { live = $0 },
                    onCommit: { newKeys in
                        keys = newKeys
                        isRecording = false
                    },
                    onCancel: { isRecording = false }
                )
            }
        }
        .accessibilityLabel(isRecording ? String(localized: "Hold the keys, then let go") : String(localized: "Keys: \(keys.isEmpty ? String(localized: "none") : keys.symbols)"))
    }

    private var showsPlaceholder: Bool {
        isRecording ? live.isEmpty : keys.isEmpty
    }

    private var label: String {
        if isRecording { return live.isEmpty ? String(localized: "Hold keys…") : live.symbols }
        return keys.isEmpty ? String(localized: "None") : keys.symbols
    }
}

private struct ModifierCatcher: NSViewRepresentable {
    let onLive: (ModifierSet) -> Void
    let onCommit: (ModifierSet) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onLive = onLive
        view.onCommit = onCommit
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {}
}

private final class CatcherView: NSView {
    var onLive: ((ModifierSet) -> Void)?
    var onCommit: ((ModifierSet) -> Void)?
    var onCancel: (() -> Void)?
    /// The largest set held since recording began; it is what gets assigned when the keys are released.
    private var peak: ModifierSet = []

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let held = ModifierSet(event.modifierFlags)
        onLive?(held)
        if held.isEmpty {
            if !peak.isEmpty { onCommit?(peak) }
        } else if held.rawValue.nonzeroBitCount >= peak.rawValue.nonzeroBitCount {
            peak = held
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // Escape
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        return true
    }
}
