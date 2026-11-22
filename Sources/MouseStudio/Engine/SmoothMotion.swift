import CoreGraphics
import Foundation

/// A distance still to travel that is consumed with an exponential ease-out. Each wheel notch adds to it,
/// so quick notches blend into one continuous glide instead of stepping.
struct EasedDistance {
    private(set) var remaining = CGPoint.zero
    /// Below this much distance left, the ease finishes in one step.
    private let finishBelow: CGFloat

    init(finishBelow: CGFloat = 0.4) {
        self.finishBelow = finishBelow
    }

    var isIdle: Bool { remaining == .zero }

    /// New input against the current direction cancels what is left, so reversing feels instant.
    mutating func add(_ delta: CGPoint) {
        if delta.x * remaining.x < 0 { remaining.x = 0 }
        if delta.y * remaining.y < 0 { remaining.y = 0 }
        remaining.x += delta.x
        remaining.y += delta.y
    }

    /// Adds without cancelling the opposite direction (for input that should never be dropped).
    mutating func accumulate(_ delta: CGPoint) {
        remaining.x += delta.x
        remaining.y += delta.y
    }

    /// Takes everything that is left at once.
    mutating func drain() -> CGPoint {
        defer { remaining = .zero }
        return remaining
    }

    mutating func step(elapsed: TimeInterval, timeConstant: TimeInterval) -> CGPoint {
        let share = CGFloat(timeConstant <= 0 ? 1 : 1 - exp(-elapsed / timeConstant))
        var moved = CGPoint(x: remaining.x * share, y: remaining.y * share)
        remaining.x -= moved.x
        remaining.y -= moved.y
        if hypot(remaining.x, remaining.y) < finishBelow {
            moved.x += remaining.x
            moved.y += remaining.y
            remaining = .zero
        }
        return moved
    }

    mutating func clear() { remaining = .zero }
}

/// Drives per-frame work: calls `frame(elapsed)` once per display refresh until it returns false.
final class FrameLoop {
    private let scheduler: Scheduler
    private let clock: () -> TimeInterval
    private let interval: TimeInterval
    private var task: ScheduledTask?
    private var lastTick: TimeInterval = 0
    private var work: ((TimeInterval) -> Bool)?

    var isRunning: Bool { task != nil }

    init(scheduler: Scheduler, clock: @escaping () -> TimeInterval, interval: TimeInterval) {
        self.scheduler = scheduler
        self.clock = clock
        self.interval = interval
    }

    func start(_ frame: @escaping (TimeInterval) -> Bool) {
        guard task == nil else { return }
        work = frame
        // Pretend one frame has already passed, so the first notch responds at once.
        lastTick = clock() - interval
        tick()
    }

    func stop() {
        task?.cancel()
        task = nil
        work = nil
    }

    private func tick() {
        let now = clock()
        let elapsed = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        guard let work, work(elapsed) else {
            stop()
            return
        }
        task = scheduler.scheduleFrame { [weak self] in self?.tick() }
    }
}
