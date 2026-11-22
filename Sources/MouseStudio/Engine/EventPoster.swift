import AppKit
import CoreGraphics

/// Creates and posts synthetic events. Every event carries `marker` so the event tap can recognise
/// (and ignore) what Mouse Studio itself sends.
enum EventPoster {
    static let marker: Int64 = 0x4D53_5455

    private static let source = CGEventSource(stateID: .hidSystemState)

    static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    static func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            post(event)
        }
    }

    /// Volume and media keys are "system defined" events, not regular key presses.
    static func mediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0xA00 : 0xB00
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | state),
                data2: -1
            )
            post(event?.cgEvent)
        }
    }

    static func click(_ button: MouseButton, modifiers: ModifierSet = [], clickState: Int = 1, at location: CGPoint) {
        let types: (down: CGEventType, up: CGEventType) = switch button.number {
        case 0: (.leftMouseDown, .leftMouseUp)
        case 1: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        let cgButton = CGMouseButton(rawValue: UInt32(button.number)) ?? .center
        for type in [types.down, types.up] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)
            event?.flags = modifiers.cgFlags
            event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.number))
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            post(event)
        }
    }

    static func scroll(x: Int32, y: Int32, phase: ScrollPhase, modifiers: ModifierSet = []) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.flags = modifiers.cgFlags
        // (scroll phase, momentum phase) as CGScrollPhase / CGMomentumScrollPhase values.
        let phases: (scroll: Int64, momentum: Int64) = switch phase {
        case .plain: (0, 0)
        case .began: (1, 0)
        case .changed: (2, 0)
        case .ended: (4, 0)
        case .momentumBegan: (0, 1)
        case .momentumChanged: (0, 2)
        case .momentumEnded: (0, 3)
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases.scroll)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phases.momentum)
        post(event)
    }

    /// A Trackpad pinch: gesture event (type 29) carrying a "zoom" sub-type, phase and magnification.
    static func magnify(_ amount: Double, phase: GesturePhase) {
        makeMagnifyEvent(amount, phase: phase)?.post(tap: .cgSessionEventTap)
    }

    private static func makeMagnifyEvent(_ amount: Double, phase: GesturePhase) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.type = CGEventType(rawValue: 29) ?? event.type
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase.rawValue))
        event.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
        return event
    }

    /// Start-up check of the undocumented pinch event: it must read back as a magnify gesture of the same size.
    /// If a macOS update changes the layout, this fails and zoom falls back to ⌘+ / ⌘− instead of misbehaving.
    static let pinchWorks: Bool = {
        guard let event = makeMagnifyEvent(0.125, phase: .changed), let ns = NSEvent(cgEvent: event) else { return false }
        return ns.type == .magnify && abs(Double(ns.magnification) - 0.125) < 0.0001
    }()

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
