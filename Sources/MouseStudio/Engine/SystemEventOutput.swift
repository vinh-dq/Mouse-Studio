import CoreGraphics
import Foundation
import os

/// The real `EventOutput`. Scrolling, cursor control and click replay happen immediately on the event
/// thread (they are quick); everything else runs on a background queue so slow actions can't stall the mouse.
final class SystemEventOutput: EventOutput {
    var onFailure: ((String) -> Void)? {
        didSet { ActionExecutor.onScriptFailure = onFailure }
    }
    /// Zoom steps are recorded, so a report shows what was sent to the app, not only what the mouse did.
    var trace: EventTrace?

    private let queue = DispatchQueue(label: "MouseStudio.actions", qos: .userInitiated)

    func perform(_ action: Action) {
        queue.async { [weak self] in
            do {
                try ActionExecutor.run(action)
            } catch {
                self?.onFailure?(error.localizedDescription)
            }
        }
    }

    /// Set from the settings. Off = never use undocumented macOS features.
    private let privateFeatures = OSAllocatedUnfairLock(initialState: true)

    func setPrivateFeatures(_ enabled: Bool) {
        privateFeatures.withLock { $0 = enabled }
    }

    var supportsInteractiveSwipe: Bool { privateFeatures.withLock { $0 } && DockSwipeSimulator.shared.isAvailable }

    var supportsPinch: Bool { privateFeatures.withLock { $0 } && EventPoster.pinchWorks }

    func swipe(_ axis: SwipeAxis, progress: Double, phase: GesturePhase, exitSpeed: Double) {
        DockSwipeSimulator.shared.post(axis: axis, progress: progress, phase: phase, exitSpeed: exitSpeed)
    }

    func scroll(x: Int32, y: Int32, phase: ScrollPhase, modifiers: ModifierSet) {
        EventPoster.scroll(x: x, y: y, phase: phase, modifiers: modifiers)
    }

    func setCursorFrozen(_ frozen: Bool) {
        CGAssociateMouseAndMouseCursorPosition(frozen ? 0 : 1)
    }

    func replayClick(button: MouseButton, modifiers: ModifierSet, clickState: Int, at location: CGPoint) {
        EventPoster.click(button, modifiers: modifiers, clickState: clickState, at: location)
    }

    var pinchNeedsPrimer: Bool { ChromiumApps.targetNeedsPinchPrimer }

    func magnify(_ amount: Double, phase: GesturePhase) {
        if phase == .began {
            let target = ChromiumApps.pinchTarget
            trace?.record("zoom    target \(target?.name ?? "unknown") -> \(target?.isChromium == true ? "Chromium: primer" : "plain pinch")")
        }
        trace?.record(String(format: "zoom    %@ %+.4f", "\(phase)", amount))
        EventPoster.magnify(amount, phase: phase)
    }
}
