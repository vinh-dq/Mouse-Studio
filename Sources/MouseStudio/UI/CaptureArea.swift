import AppKit
import SwiftUI

/// A button press recognised in the capture area.
struct CapturedTrigger: Equatable {
    var button: MouseButton
    var modifiers: ModifierSet
    var interaction: Interaction
}

/// Listens for a button press so the user never has to describe their mouse: they just use it.
/// While the pointer is over this card the engine lets every event through, so the press reaches it untouched.
struct CaptureArea: View {
    var title = "Add a gesture"
    var activeTitle = "Now press a mouse button"
    var subtitle = "Move your pointer here, then press the button you want to customize."
    var onCapture: (CapturedTrigger) -> Void

    @EnvironmentObject private var model: AppModel
    @LocalState private var isHovering = false
    @LocalState private var hint: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                IconTile(symbol: "computermouse.fill", tint: isHovering ? .accentColor : .gray, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(isHovering ? activeTitle : title))
                        .font(.headline)
                    Text(LocalizedStringKey(isHovering
                         ? "Click, double-click, hold, drag or scroll. Hold ⌘ ⌥ ⌃ ⇧ with it for combinations."
                         : subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isHovering ? "cursorarrow.click.2" : "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            if let hint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(isHovering ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.7), lineWidth: isHovering ? 2 : 0.5))
        .shadow(color: .black.opacity(0.04), radius: 5, y: 1)
        .overlay {
            CaptureSurface(
                onCapture: { trigger in
                    hint = nil
                    onCapture(trigger)
                },
                onRejected: { hint = $0 }
            )
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if !hovering { hint = nil }
            model.setCapturing(hovering)
        }
        .onDisappear { model.setCapturing(false) }
        .accessibilityLabel("Press a mouse button here to add a gesture")
    }
}

private struct CaptureSurface: NSViewRepresentable {
    let onCapture: (CapturedTrigger) -> Void
    let onRejected: (String) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = onCapture
        view.onRejected = onRejected
        return view
    }

    func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.onRejected = onRejected
    }
}

private final class CaptureNSView: NSView {
    var onCapture: ((CapturedTrigger) -> Void)?
    var onRejected: ((String) -> Void)?

    private static let holdDuration: TimeInterval = 0.4
    private static let dragDistance: CGFloat = 6

    private var pressedButton: Int?
    private var pressStart = Date()
    private var pressOrigin = CGPoint.zero
    private var didDrag = false
    private var didScroll = false
    private var pendingClick: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { begin(event) }
    override func rightMouseDown(with event: NSEvent) { begin(event) }
    override func otherMouseDown(with event: NSEvent) { begin(event) }
    override func mouseUp(with event: NSEvent) { end(event) }
    override func rightMouseUp(with event: NSEvent) { end(event) }
    override func otherMouseUp(with event: NSEvent) { end(event) }
    override func mouseDragged(with event: NSEvent) { moved(event) }
    override func rightMouseDragged(with event: NSEvent) { moved(event) }
    override func otherMouseDragged(with event: NSEvent) { moved(event) }

    override func scrollWheel(with event: NSEvent) {
        if pressedButton != nil {
            didScroll = true
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private func begin(_ event: NSEvent) {
        pressedButton = event.buttonNumber
        pressStart = Date()
        pressOrigin = event.locationInWindow
        didDrag = false
        didScroll = false
    }

    private func moved(_ event: NSEvent) {
        let dx = event.locationInWindow.x - pressOrigin.x
        let dy = event.locationInWindow.y - pressOrigin.y
        if hypot(dx, dy) >= Self.dragDistance { didDrag = true }
    }

    private func end(_ event: NSEvent) {
        guard let number = pressedButton else { return }
        pressedButton = nil
        let button = MouseButton(number: number)
        let modifiers = ModifierSet(event.modifierFlags)

        if didScroll {
            report(button, modifiers, .scroll)
        } else if didDrag {
            report(button, modifiers, .drag)
        } else if Date().timeIntervalSince(pressStart) >= Self.holdDuration {
            report(button, modifiers, .hold)
        } else if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            report(button, modifiers, .doubleClick)
        } else {
            // Wait briefly: a second click would make this a double click.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                self?.report(button, modifiers, .click)
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    private func report(_ button: MouseButton, _ modifiers: ModifierSet, _ interaction: Interaction) {
        let trigger = CapturedTrigger(button: button, modifiers: modifiers, interaction: interaction)
        guard Trigger(button: button, modifiers: modifiers, interaction: interaction).isAllowed else {
            if button.isPrimary, !modifiers.isEmpty, interaction == .doubleClick {
                onRejected?(String(localized: "Double click can't be customized on the left and right buttons, so opening files and folders always works."))
            } else {
                onRejected?(String(localized: "The left and right buttons need a key held with them, such as ⌘, ⌥, ⌃ or ⇧, so you can't lock yourself out. Hold one and try again."))
            }
            return
        }
        onCapture?(trigger)
    }
}
