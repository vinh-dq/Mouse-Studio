import CoreGraphics
import Foundation

/// Replaces a classic mouse wheel's notches with Trackpad-style scrolling: reversible, adjustable speed and
/// acceleration, eased into a continuous glide.
///
/// Events carry no gesture phase on purpose: with phases, apps treat the glide as a Trackpad gesture and
/// rubber-band at the top and bottom of a page, which feels like the page is being held.
final class WheelScroller {
    /// Points one wheel "line" scrolls at speed 1.
    static let pointsPerLine: CGFloat = 100

    private let output: EventOutput
    private let loop: FrameLoop
    private let clock: () -> TimeInterval
    /// The slow tail (under a pixel per frame) is cut short: it only looks like stepping.
    private var distance = EasedDistance(finishBelow: 1.5)
    private var remainder = CGPoint.zero
    private var timeConstant: TimeInterval = 0.12
    private var tickRate = TickRate()
    /// Keys the receiving app sees as held while posting.
    private var flags: ModifierSet = []

    init(output: EventOutput, scheduler: Scheduler, clock: @escaping () -> TimeInterval, frameInterval: TimeInterval) {
        self.output = output
        self.clock = clock
        loop = FrameLoop(scheduler: scheduler, clock: clock, interval: frameInterval)
    }

    /// `action` is the job chosen by the keys held (nil for a plain wheel turn). With no job, held keys
    /// are passed on to the app, so ⌘-scroll and the like still work, in the same direction as a plain turn.
    func scroll(lines: CGPoint, settings: WheelSettings, modifiers: ModifierSet = [], action: WheelModifierAction? = nil) {
        let speedFactor = CGFloat(action?.speedFactor ?? 1)
        let acceleration = action == nil ? settings.acceleration : 0
        let scale = Self.pointsPerLine * CGFloat(settings.speed) * speedFactor * CGFloat(boost(acceleration))
        var delta = CGPoint(
            x: lines.x * scale * (settings.reverseHorizontal ? -1 : 1),
            y: lines.y * scale * (settings.reverseVertical ? -1 : 1)
        )
        if action == .horizontalScroll {
            // The vertical turn becomes a sideways scroll, in the direction the plain wheel would have gone.
            delta = CGPoint(x: delta.y, y: 0)
        }
        flags = action == nil ? modifiers : []
        guard settings.smooth else {
            stop()
            emit(delta, final: true)
            return
        }
        timeConstant = 0.05 + settings.smoothness * 0.15
        distance.add(delta)
        loop.start { [weak self] elapsed in self?.advance(elapsed) ?? false }
    }

    /// Stops at once, keeping the position reached.
    func stop() {
        loop.stop()
        distance.clear()
        remainder = .zero
        tickRate.reset()
    }

    /// Turning the wheel faster scrolls further per notch: from 1× up to 4× at full acceleration.
    private func boost(_ acceleration: Double) -> Double {
        1 + 3 * acceleration * tickRate.tick(at: clock())
    }

    private func advance(_ elapsed: TimeInterval) -> Bool {
        let moved = distance.step(elapsed: elapsed, timeConstant: timeConstant)
        emit(moved, final: distance.isIdle)
        return !distance.isIdle
    }

    /// Posts whole pixels and carries the fraction over; on the last step the fraction is rounded in.
    private func emit(_ delta: CGPoint, final: Bool) {
        remainder.x += delta.x
        remainder.y += delta.y
        let rule: FloatingPointRoundingRule = final ? .toNearestOrAwayFromZero : .towardZero
        let x = remainder.x.rounded(rule)
        let y = remainder.y.rounded(rule)
        remainder.x -= x
        remainder.y -= y
        if x != 0 || y != 0 {
            output.scroll(x: Int32(x), y: Int32(y), phase: .plain, modifiers: flags)
        }
        if final { remainder = .zero }
    }
}

/// Click-and-scroll zoom as a real pinch: the scroll amount is eased into a stream of magnify gestures.
final class PinchZoom {
    /// A pinch stays open this long after the last input, so quick notches are one smooth gesture.
    private static let lingerTime = 0.3
    /// Chromium holds back a pinch until it has grown by about 1.5× (or shrunk to 1/1.5) and jumps the page if a
    /// step reaches that line. The primer must land inside a narrow window just short of it: measured against
    /// Chrome at several zoom levels, a single wheel click then gives exactly its own zoom. Zoom in: 0.49–0.4975
    /// works, 0.485 swallows a single click and 0.5 can jump the page. Zoom out: -0.325 to -0.332 works, -0.32
    /// loses part of a click and -0.3333 jumps. The two directions differ because the line is a ratio.
    /// Re-measure if Chromium changes (see docs/ARCHITECTURE.md).
    static let primerZoomIn = 0.493
    static let primerZoomOut = -0.329

    private let output: EventOutput
    private let loop: FrameLoop
    private let clock: () -> TimeInterval
    private var distance = EasedDistance(finishBelow: 0.0004)
    private var began = false
    /// Whether the open pinch got a primer; decided once when it opens, not looked up again for every frame.
    private var primed = false
    /// +1 / -1: the direction the open gesture was primed for.
    private var direction = 0.0
    private var lastInput: TimeInterval = 0
    /// When the primer was sent; the first real step waits `primerGap` after it.
    private var primedAt: TimeInterval = 0
    /// The app merges steps that reach it within one of its own frames (up to ~33 ms on a busy 60 Hz display).
    /// Measured on a recorded run: a gap of one of our frames was sometimes not enough and the page jumped.
    static let primerGap = 0.06

    init(output: EventOutput, scheduler: Scheduler, clock: @escaping () -> TimeInterval, frameInterval: TimeInterval) {
        self.output = output
        self.clock = clock
        loop = FrameLoop(scheduler: scheduler, clock: clock, interval: frameInterval)
    }

    /// While a button is held the pinch stays open between notches (up to `holdTime`): one gesture, one primer,
    /// instead of a new gesture the app rounds differently every time.
    private static let holdTime = 5.0
    private var keepOpen = false

    /// `newGesture` starts a fresh pinch at this click (the previous one is closed). Apps such as Preview add up
    /// everything a pinch has asked for, including what went past their zoom limit, so one long pinch pushed to the
    /// limit needs the same amount of turning back before the picture moves again. A pinch per flick keeps that
    /// excess to one flick. Chromium-based apps are the exception: they need one long pinch (see `primerZoomIn`).
    func zoom(by amount: Double, keepOpen: Bool = false, newGesture: Bool = false) {
        if newGesture, began, !primed {
            output.magnify(0, phase: .ended)
            began = false
        }
        self.keepOpen = keepOpen
        distance.add(CGPoint(x: amount, y: 0))
        lastInput = clock()
        loop.start { [weak self] elapsed in self?.advance(elapsed) ?? false }
    }

    /// The button was let go: finish once the zoom has settled.
    func release() {
        keepOpen = false
        lastInput = clock()
    }

    func stop() {
        keepOpen = false
        loop.stop()
        distance.clear()
        if began { output.magnify(0, phase: .ended) }
        began = false
    }

    private func advance(_ elapsed: TimeInterval) -> Bool {
        let moved = distance.step(elapsed: elapsed, timeConstant: 0.07)
        let step: Double = moved.x > 0 ? 1 : (moved.x < 0 ? -1 : 0)
        // Turning the wheel the other way starts a new gesture, primed for the new direction.
        if began, step != 0, step != direction {
            output.magnify(0, phase: .ended)
            began = false
        }
        // Like a Trackpad, the gesture opens with a zero-size "began"; apps ignore the amount carried by it.
        if !began, step != 0 {
            output.magnify(0, phase: .began)
            began = true
            direction = step
            primed = output.pinchNeedsPrimer
            if primed {
                output.magnify(step > 0 ? Self.primerZoomIn : Self.primerZoomOut, phase: .changed)
                // The primer must reach the app on its own: the app merges steps that arrive together, and primer +
                // first real step would then cross the line it is meant to stay short of (the page jumps).
                primedAt = clock()
                distance.accumulate(moved)
                return true
            }
        }
        if primed, began, moved.x != 0, clock() - primedAt < Self.primerGap {
            distance.accumulate(moved)
            return true
        }
        if moved.x != 0 { output.magnify(Double(moved.x), phase: .changed) }
        if !distance.isIdle || clock() - lastInput < (keepOpen ? Self.holdTime : Self.lingerTime) { return true }
        if began { output.magnify(0, phase: .ended) }
        began = false
        return false
    }
}
