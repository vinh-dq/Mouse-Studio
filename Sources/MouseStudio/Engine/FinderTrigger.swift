import CoreGraphics
import Foundation
import os

/// Follows one modifier key and says when it was pressed alone, let go, or spoiled by something else
/// (another modifier, a mouse button, the wheel). Pure, so it is unit-tested without a keyboard.
struct FinderHoldTracker {
    enum Transition: Equatable {
        case none, pressed, released, disturbed
    }

    private(set) var isHeld = false
    private(set) var isDisturbed = false

    private static let modifierMask: UInt64 = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue

    mutating func flagsChanged(_ raw: UInt64, key: FinderKey) -> Transition {
        let keyIsDown = raw & key.deviceBit != 0 && raw & key.familyBits == key.deviceBit
        let aloneDown = keyIsDown && raw & Self.modifierMask == key.flag
        if aloneDown {
            guard !isHeld else { return .none }
            isHeld = true
            isDisturbed = false
            return .pressed
        }
        guard isHeld else { return .none }
        if keyIsDown { return otherInput() }
        isHeld = false
        isDisturbed = false
        return .released
    }

    /// A mouse button, the wheel or a key other than modifiers was used while the key is held.
    mutating func otherInput() -> Transition {
        guard isHeld, !isDisturbed else { return .none }
        isDisturbed = true
        return .disturbed
    }

    mutating func reset() {
        isHeld = false
        isDisturbed = false
    }
}

/// Carries the key state from the event tap thread to the main thread, where the finder lives.
final class FinderTrigger: @unchecked Sendable {
    static let shared = FinderTrigger()

    private struct State {
        var tracker = FinderHoldTracker()
        var key = FinderKey.rightOption
        var isEnabled = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Set once by the finder; always called on the main thread.
    var onPressed: (@MainActor () -> Void)?
    var onReleased: (@MainActor () -> Void)?
    var onDisturbed: (@MainActor () -> Void)?

    func configure(isEnabled: Bool, key: FinderKey) {
        state.withLock { state in
            if state.key != key || state.isEnabled != isEnabled { state.tracker.reset() }
            state.key = key
            state.isEnabled = isEnabled
        }
    }

    /// Tap thread. `suppressed` is true while the finder must not start (an excluded app is in front, or a button is
    /// being recorded); the key is still followed so a release is never missed.
    func flagsChanged(_ raw: UInt64, suppressed: Bool) {
        let transition: FinderHoldTracker.Transition = state.withLock { state in
            guard state.isEnabled else { return .none }
            var result = state.tracker.flagsChanged(raw, key: state.key)
            if result == .pressed, suppressed {
                _ = state.tracker.otherInput()
                result = .none
            }
            return result
        }
        deliver(transition)
    }

    /// Tap thread: a mouse button or the wheel was used.
    func otherInput() {
        deliver(state.withLock { $0.isEnabled ? $0.tracker.otherInput() : .none })
    }

    private func deliver(_ transition: FinderHoldTracker.Transition) {
        let callback: (@MainActor () -> Void)?
        switch transition {
        case .none: return
        case .pressed: callback = onPressed
        case .released: callback = onReleased
        case .disturbed: callback = onDisturbed
        }
        guard let callback else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}
