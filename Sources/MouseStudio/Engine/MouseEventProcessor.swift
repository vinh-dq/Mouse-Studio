import CoreGraphics
import Foundation

/// The rule engine's state machine. It decides, for every mouse event, whether to let it through or
/// swallow it, and starts actions. It knows nothing about the event tap, so it can be tested directly.
///
/// Not thread-safe: all calls (including scheduled work) must happen on one thread.
///
/// A button press is only swallowed when a rule exists for that exact button + modifiers. The matching
/// release is always swallowed too, so apps never see a lone "up" and buttons cannot get stuck.
final class MouseEventProcessor {
    struct Timing {
        var holdDuration: TimeInterval = 0.4
        var doubleClickInterval: TimeInterval = 0.3
        var dragThreshold: CGFloat = 4
        /// A button that also has click-and-scroll starts a drag only for movement that looks deliberate: faster
        /// than this (points per second), or at least `deliberateTravel` points. A thumb resting on the button
        /// twitches by a few points, quickly but briefly (recorded: 5–6 pt jerks that scrolled the page for a second
        /// until the wheel turned), which must not scroll the page.
        var deliberateSpeed: CGFloat = 400
        var deliberateTravel: CGFloat = 24
        var swipeThreshold: CGFloat = 80
        /// Scroll points that make one zoom or volume step.
        var scrollStep: CGFloat = 10
        /// Slower than this at release (points/second) and the content just stops.
        var minGlideSpeed: CGFloat = 60
        /// A glide ends when it has slowed to this speed.
        var stopGlideSpeed: CGFloat = 12
        var frameInterval: TimeInterval = 1.0 / 120
        /// Pointer travel (points) that equals a full Trackpad swipe at speed 1.
        var swipeDistance: CGFloat = 625
        /// Pinch amount per scroll point while zooming.
        var zoomPerPoint: CGFloat = 0.005
        /// Wheel events closer together than this belong to the same flick when zooming.
        var zoomBurstGap: TimeInterval = 0.09
    }

    /// The glide after release: speed fades out exponentially, like a Trackpad flick.
    private final class Glide {
        var velocity: CGPoint
        let decayTime: TimeInterval
        var lastTick: TimeInterval
        var remainder = CGPoint.zero
        var began = false
        var task: ScheduledTask?

        init(velocity: CGPoint, decayTime: TimeInterval, lastTick: TimeInterval) {
            self.velocity = velocity
            self.decayTime = decayTime
            self.lastTick = lastTick
        }
    }

    private enum Phase {
        case pending, dragging, scrolling, holdFired, cancelled
    }

    private final class Press {
        let button: MouseButton
        let modifiers: ModifierSet
        let rules: RuleSet.PressRules
        let scrollSettings: ScrollSettings
        let swipeSpeed: Double
        var location: CGPoint
        let clickState: Int
        var phase = Phase.pending
        var travel = CGPoint.zero
        var holdTask: ScheduledTask?
        var scroller = DragScrollAccumulator()
        /// Scroll distance gathered from pointer events, released to the screen at a steady frame rate.
        var pendingScroll = EasedDistance()
        var scrollRemainder = CGPoint.zero
        let scrollLoop: FrameLoop
        var lastMove: TimeInterval = 0
        /// Recent pointer movement while the press is still undecided, to tell a drag from a twitch.
        var recentMoves: [(time: TimeInterval, distance: CGFloat)] = []
        var scrollStarted = false
        /// A drag that began on a button which also zooms: its speed ramps up over the first few points, so a
        /// thumb twitch barely moves the page while a real slow drag still starts smoothly without a dead zone.
        var softStart = false
        var swipeFired = false
        var swipeAxis = SwipeAxis.horizontal
        var swipeProgress = 0.0
        var swipeStarted = false
        var swipeSamples: [(time: TimeInterval, delta: Double)] = []
        var wheelRemainder: CGFloat = 0

        init(button: MouseButton, modifiers: ModifierSet, rules: RuleSet.PressRules, scrollSettings: ScrollSettings, swipeSpeed: Double, location: CGPoint, clickState: Int, scrollLoop: FrameLoop) {
            self.button = button
            self.modifiers = modifiers
            self.rules = rules
            self.scrollSettings = scrollSettings
            self.swipeSpeed = swipeSpeed
            self.location = location
            self.clickState = clickState
            self.scrollLoop = scrollLoop
        }
    }

    private struct ClickKey: Hashable {
        let button: Int
        let modifiers: UInt8
    }

    private let output: EventOutput
    private let scheduler: Scheduler
    private let timing: Timing
    private let clock: () -> TimeInterval
    private let trace: EventTrace?
    private let configProvider: () -> EngineConfig

    private var presses: [Int: Press] = [:]
    private var pendingClicks: [ClickKey: ScheduledTask] = [:]
    private var cursorFrozen = false
    private var glide: Glide?
    private let wheelScroller: WheelScroller
    private let pinchZoom: PinchZoom

    init(
        output: EventOutput,
        scheduler: Scheduler,
        timing: Timing = Timing(),
        trace: EventTrace? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        configProvider: @escaping () -> EngineConfig
    ) {
        self.output = output
        self.scheduler = scheduler
        self.timing = timing
        self.clock = clock
        self.trace = trace
        wheelScroller = WheelScroller(output: output, scheduler: scheduler, clock: clock, frameInterval: timing.frameInterval)
        pinchZoom = PinchZoom(output: output, scheduler: scheduler, clock: clock, frameInterval: timing.frameInterval)
        self.configProvider = configProvider
    }

    func handle(_ input: MouseInput) -> Disposition {
        let result = process(input)
        if let trace, input.kind != .dragged { trace.record(describe(input, result)) }
        return result
    }

    private func describe(_ input: MouseInput, _ result: Disposition) -> String {
        let keys = input.modifiers.isEmpty ? "-" : input.modifiers.symbols
        let presses = self.presses.values.map { "button\($0.button.number + 1)=\($0.phase)" }.sorted().joined(separator: ",")
        let decision = result == .consume ? "consumed" : "passed on"
        switch input.kind {
        case .scroll:
            return "scroll  lines=\(input.lines.y) points=\(input.delta.y) wheel=\(input.isWheel) naturalDirection=\(input.isDirectionInverted) keys=\(keys) -> \(decision) [held: \(presses.isEmpty ? "none" : presses)]"
        case .flagsChanged:
            return "keys    now \(keys) [held: \(presses.isEmpty ? "none" : presses)]"
        default:
            return "\(input.kind) button\(input.button.number + 1) keys=\(keys) -> \(decision) [held: \(presses.isEmpty ? "none" : presses)]"
        }
    }

    private func process(_ input: MouseInput) -> Disposition {
        // Touching the mouse again stops a glide, just as touching the Trackpad does.
        if input.kind == .down || input.kind == .scroll { stopGlide() }
        if input.kind == .down { wheelScroller.stop() }
        switch input.kind {
        case .down: return pressBegan(input)
        case .dragged: return pressMoved(input)
        case .up: return pressEnded(input)
        case .scroll: return wheelScrolled(input)
        case .flagsChanged:
            modifiersChanged(input.modifiers)
            return .passThrough
        }
    }

    /// Drops all in-flight state and gives the cursor back. Called when event delivery is interrupted.
    func reset() {
        trace?.record("reset   engine state cleared (held buttons forgotten)")
        presses.values.forEach(discard)
        presses.removeAll()
        pendingClicks.values.forEach { $0.cancel() }
        pendingClicks.removeAll()
        stopGlide()
        wheelScroller.stop()
        pinchZoom.stop()
        setCursorFrozen(false)
    }

    // MARK: - Press lifecycle

    private func pressBegan(_ input: MouseInput) -> Disposition {
        if let stale = presses.removeValue(forKey: input.button.number) {
            discard(stale)
        }
        let config = configProvider()
        guard let rules = config.rules.rules(for: input.button, modifiers: input.modifiers) else {
            return .passThrough
        }
        let press = Press(button: input.button, modifiers: input.modifiers, rules: rules, scrollSettings: config.scroll, swipeSpeed: config.swipe.speed, location: input.location, clickState: input.clickState,
                          scrollLoop: FrameLoop(scheduler: scheduler, clock: clock, interval: timing.frameInterval))
        if rules.hold != nil {
            press.holdTask = scheduler.schedule(after: timing.holdDuration) { [weak self, weak press] in
                guard let self, let press else { return }
                self.holdElapsed(press)
            }
        }
        presses[input.button.number] = press
        return .consume
    }

    private func pressMoved(_ input: MouseInput) -> Disposition {
        guard let press = presses[input.button.number] else { return .passThrough }
        press.location = input.location
        guard press.phase != .cancelled else { return .consume }

        press.travel.x += input.delta.x
        press.travel.y += input.delta.y

        switch press.phase {
        case .pending:
            guard press.rules.drag != nil else { break }
            press.recentMoves.append((input.timestamp, hypot(input.delta.x, input.delta.y)))
            press.recentMoves.removeAll { input.timestamp - $0.time > 0.1 }
            let travel = hypot(press.travel.x, press.travel.y)
            if travel >= timing.dragThreshold {
                press.softStart = press.rules.scroll != nil && !looksDeliberate(press, now: input.timestamp, travel: travel)
                beginDrag(press, at: input.timestamp, travel: travel)
            }
        case .dragging:
            drag(press, by: input.delta, at: input.timestamp)
        case .scrolling, .holdFired, .cancelled:
            break
        }
        return .consume
    }

    private func pressEnded(_ input: MouseInput) -> Disposition {
        guard let press = presses.removeValue(forKey: input.button.number) else { return .passThrough }
        press.holdTask?.cancel()
        press.holdTask = nil
        switch press.phase {
        case .pending: completeClick(press, at: input.location)
        case .dragging: endDrag(press, releasedAt: input.timestamp)
        case .scrolling:
            pinchZoom.release()
        case .holdFired, .cancelled: break
        }
        return .consume
    }

    private func holdElapsed(_ press: Press) {
        guard press.phase == .pending, presses[press.button.number] === press, let action = press.rules.hold else { return }
        press.phase = .holdFired
        output.perform(action)
    }

    private func modifiersChanged(_ modifiers: ModifierSet) {
        for press in presses.values where press.phase != .cancelled && !modifiers.isSuperset(of: press.modifiers) {
            discard(press)
            press.phase = .cancelled
        }
    }

    /// Stops a press from doing anything further, without removing it (its release is still swallowed).
    private func discard(_ press: Press) {
        press.holdTask?.cancel()
        press.holdTask = nil
        if press.phase == .dragging { endDrag(press) }
    }

    // MARK: - Clicks

    private func completeClick(_ press: Press, at location: CGPoint) {
        let button = press.button
        let modifiers = press.modifiers
        let rules = press.rules
        let clickState = press.clickState

        guard let doubleClickAction = rules.doubleClick else {
            fireSingleClick(button, modifiers, rules, clickState: press.clickState, at: location)
            return
        }
        let key = ClickKey(button: button.number, modifiers: modifiers.rawValue)
        if let waiting = pendingClicks.removeValue(forKey: key) {
            waiting.cancel()
            output.perform(doubleClickAction)
            return
        }
        pendingClicks[key] = scheduler.schedule(after: timing.doubleClickInterval) { [weak self] in
            guard let self else { return }
            self.pendingClicks[key] = nil
            self.fireSingleClick(button, modifiers, rules, clickState: press.clickState, at: location)
        }
    }

    private func fireSingleClick(_ button: MouseButton, _ modifiers: ModifierSet, _ rules: RuleSet.PressRules, clickState: Int, at location: CGPoint) {
        if let action = rules.click {
            output.perform(action)
        } else {
            output.replayClick(button: button, modifiers: modifiers, clickState: clickState, at: location)
        }
    }

    // MARK: - Drag

    private func recentSpeed(_ press: Press, now: TimeInterval) -> CGFloat {
        guard let first = press.recentMoves.first else { return 0 }
        let span = max(now - first.time, 0.03)
        return press.recentMoves.reduce(0) { $0 + $1.distance } / CGFloat(span)
    }

    private func looksDeliberate(_ press: Press, now: TimeInterval, travel: CGFloat) -> Bool {
        travel >= timing.deliberateTravel || recentSpeed(press, now: now) >= timing.deliberateSpeed
    }

    private func beginDrag(_ press: Press, at time: TimeInterval, travel: CGFloat) {
        trace?.record("drag    button\(press.button.number + 1) started after \(Int(travel)) pt at \(Int(recentSpeed(press, now: time))) pt/s")
        press.holdTask?.cancel()
        press.holdTask = nil
        press.phase = .dragging
        switch press.rules.drag {
        case .dragScroll? where press.scrollSettings.freezeCursor: setCursorFrozen(true)
        case .swipeGesture? where output.supportsInteractiveSwipe: setCursorFrozen(true)
        default: break
        }
        drag(press, by: press.travel, at: time)
    }

    private func drag(_ press: Press, by delta: CGPoint, at time: TimeInterval) {
        switch press.rules.drag {
        case .dragScroll?:
            let gain = press.softStart ? min(1, hypot(press.travel.x, press.travel.y) / timing.deliberateTravel) : 1
            guard let distance = press.scroller.consume(CGPoint(x: delta.x * gain, y: delta.y * gain), at: time, settings: press.scrollSettings) else { return }
            // Mouse events arrive at the mouse's own rate (125–1000 Hz) and unevenly; scrolling is posted once
            // per frame instead, which is what keeps it from stuttering.
            press.pendingScroll.accumulate(distance)
            press.lastMove = clock()
            press.scrollLoop.start { [weak self, weak press] elapsed in
                guard let self, let press else { return false }
                return self.scrollFrame(press, elapsed: elapsed)
            }
        case .swipeGesture? where output.supportsInteractiveSwipe:
            followSwipe(press, by: delta, at: time)
        case .swipeGesture?:
            guard !press.swipeFired, hypot(press.travel.x, press.travel.y) >= timing.swipeThreshold else { return }
            press.swipeFired = true
            output.perform(.system(swipeAction(for: press.travel)))
        default:
            break
        }
    }

    /// `releasedAt` is set when the user let go of the button; it lets the content glide on.
    /// Cancelled drags (modifier released, interruptions) stop at once.
    private func endDrag(_ press: Press, releasedAt time: TimeInterval? = nil) {
        switch press.rules.drag {
        case .dragScroll?:
            press.scrollLoop.stop()
            emitScroll(press, press.pendingScroll.drain(), final: true)
            if press.scrollStarted {
                output.scroll(x: 0, y: 0, phase: .ended)
            }
            setCursorFrozen(false)
            if let time, press.scrollStarted {
                startGlide(velocity: press.scroller.releaseVelocity(at: time), inertia: press.scrollSettings.inertia)
            }
        case .swipeGesture?:
            endSwipe(press, releasedAt: time)
            setCursorFrozen(false)
        default:
            break
        }
    }

    // MARK: - Swipe that follows the pointer

    /// The first movement picks the direction (horizontal Spaces or vertical Mission Control) and it stays
    /// locked until release, like a three-finger swipe.
    private func followSwipe(_ press: Press, by delta: CGPoint, at time: TimeInterval) {
        if !press.swipeStarted {
            press.swipeAxis = abs(press.travel.x) >= abs(press.travel.y) ? .horizontal : .vertical
        }
        let distance = Double(timing.swipeDistance) / press.swipeSpeed
        let step: Double = switch press.swipeAxis {
        case .horizontal: Double(delta.x) / distance
        case .vertical: -Double(delta.y) / distance
        }
        guard step != 0 || !press.swipeStarted else { return }
        press.swipeProgress += step
        press.swipeSamples.append((time, step))
        press.swipeSamples.removeAll { time - $0.time > 0.2 }
        output.swipe(press.swipeAxis, progress: press.swipeProgress, phase: press.swipeStarted ? .changed : .began, exitSpeed: 0)
        press.swipeStarted = true
    }

    /// Letting go lets macOS finish the animation: it commits if the swipe was going on in the same direction
    /// and cancels (springs back) if the user pulled back or the swipe was interrupted.
    private func endSwipe(_ press: Press, releasedAt time: TimeInterval?) {
        guard press.swipeStarted else { return }
        var phase = GesturePhase.cancelled
        var exitSpeed = 0.0
        if let time {
            let recent = press.swipeSamples.filter { time - $0.time <= 0.1 }
            let speed = recent.reduce(0) { $0 + $1.delta } / 0.1
            let resting = press.swipeSamples.last.map { time - $0.time > 0.06 } ?? true
            let pulledBack = !resting && speed * press.swipeProgress < 0
            if !pulledBack {
                phase = .ended
                exitSpeed = resting ? 0 : speed * 1.6
            }
        }
        output.swipe(press.swipeAxis, progress: press.swipeProgress, phase: phase, exitSpeed: exitSpeed)
        press.swipeStarted = false
    }

    /// One frame of drag scrolling: releases a share of the gathered distance. `smoothness` sets how long
    /// that takes; at 0 everything gathered goes out in the frame.
    private func scrollFrame(_ press: Press, elapsed: TimeInterval) -> Bool {
        let moved = press.pendingScroll.step(elapsed: elapsed, timeConstant: press.scrollSettings.smoothness * 0.06)
        emitScroll(press, moved, final: false)
        // Keep ticking while the pointer is active, so the next movement waits for the next frame instead of
        // being posted at once; give up after a quiet moment.
        return !press.pendingScroll.isIdle || clock() - press.lastMove < 0.25
    }

    private func emitScroll(_ press: Press, _ delta: CGPoint, final: Bool) {
        press.scrollRemainder.x += delta.x
        press.scrollRemainder.y += delta.y
        let rule: FloatingPointRoundingRule = final ? .toNearestOrAwayFromZero : .towardZero
        let x = press.scrollRemainder.x.rounded(rule)
        let y = press.scrollRemainder.y.rounded(rule)
        press.scrollRemainder.x -= x
        press.scrollRemainder.y -= y
        guard x != 0 || y != 0 else { return }
        output.scroll(x: Int32(x), y: Int32(y), phase: press.scrollStarted ? .changed : .began)
        press.scrollStarted = true
    }

    // MARK: - Glide

    private func startGlide(velocity: CGPoint, inertia: Double) {
        guard inertia > 0, hypot(velocity.x, velocity.y) >= timing.minGlideSpeed else { return }
        stopGlide()
        glide = Glide(velocity: velocity, decayTime: 0.15 + inertia * 0.55, lastTick: clock())
        tickGlide()
    }

    private func tickGlide() {
        guard let glide else { return }
        let now = clock()
        let elapsed = max(0, min(now - glide.lastTick, 0.1))
        glide.lastTick = now

        let fade = CGFloat(exp(-elapsed / glide.decayTime))
        glide.velocity.x *= fade
        glide.velocity.y *= fade
        if hypot(glide.velocity.x, glide.velocity.y) < timing.stopGlideSpeed {
            stopGlide()
            return
        }
        glide.remainder.x += glide.velocity.x * elapsed
        glide.remainder.y += glide.velocity.y * elapsed
        let x = glide.remainder.x.rounded(.towardZero)
        let y = glide.remainder.y.rounded(.towardZero)
        glide.remainder.x -= x
        glide.remainder.y -= y
        if x != 0 || y != 0 {
            output.scroll(x: Int32(x), y: Int32(y), phase: glide.began ? .momentumChanged : .momentumBegan)
            glide.began = true
        }
        glide.task = scheduler.scheduleFrame { [weak self] in self?.tickGlide() }
    }

    private func stopGlide() {
        guard let glide else { return }
        glide.task?.cancel()
        if glide.began { output.scroll(x: 0, y: 0, phase: .momentumEnded) }
        self.glide = nil
    }

    /// Dragging works like a three-finger swipe: up = Mission Control, down = App Exposé,
    /// left/right = switch Space.
    private func swipeAction(for travel: CGPoint) -> SystemAction {
        if abs(travel.x) > abs(travel.y) {
            return travel.x < 0 ? .spaceRight : .spaceLeft
        }
        return travel.y < 0 ? .missionControl : .appExpose
    }

    // MARK: - Click and scroll

    /// One wheel click of zoom: a smooth pinch, or ⌘+ / ⌘− when the pinch can't be used on this Mac.
    private func zoomStep(up: Double, input: MouseInput, pinch: (_ newGesture: Bool) -> Void) {
        guard output.supportsPinch else {
            if up != 0 { output.perform(.system(up > 0 ? .zoomIn : .zoomOut)) }
            return
        }
        noteZoomEvent(input, direction: up < 0 ? -1 : 1)
        pinch(zoomFlickStarted)
    }

    private var lastZoomEvent: (time: TimeInterval, direction: Double)?
    /// Set by `noteZoomEvent` when the event it just saw is the first of a new flick.
    private var zoomFlickStarted = false

    /// Every wheel event is one click, so zoom follows the total number of clicks: a flick of five clicks zooms five
    /// steps, a single click one. Only the start of a flick is noted, because each flick opens a fresh pinch.
    private func noteZoomEvent(_ input: MouseInput, direction: Double) {
        zoomFlickStarted = lastZoomEvent.map { $0.direction != direction || input.timestamp - $0.time >= timing.zoomBurstGap } ?? true
        lastZoomEvent = (input.timestamp, direction)
    }

    private func wheelScrolled(_ input: MouseInput) -> Disposition {
        // A wheel turn while the button is down belongs to "click and scroll" even if the hand has already
        // wandered far enough to start a drag.
        guard let press = presses.values.first(where: { $0.rules.scroll != nil && $0.phase != .cancelled && $0.phase != .holdFired }),
              let scrollAction = press.rules.scroll else {
            return plainWheelScrolled(input)
        }
        press.holdTask?.cancel()
        press.holdTask = nil
        if press.phase == .dragging {
            trace?.record("drag    button\(press.button.number + 1) ended by the wheel")
            endDrag(press)
        }
        press.phase = .scrolling

        // Turning the wheel away from you is "up", whichever way the system's scroll direction setting points.
        // A real wheel counts in notches (10 points each), so the amount never depends on how fast it turns.
        let amount = input.isWheel ? CGFloat(WheelNotch.direction(input.lines.y)) * 10 : input.delta.y
        let up = Double(input.isDirectionInverted ? -amount : amount)

        if scrollAction == .scrollZoom {
            zoomStep(up: up, input: input) { pinchZoom.zoom(by: up / 10 * configProvider().wheel.zoomStep, keepOpen: true, newGesture: $0) }
            return .consume
        }

        press.wheelRemainder += CGFloat(up)
        let steps = Int((press.wheelRemainder / timing.scrollStep).rounded(.towardZero))
        guard steps != 0 else { return .consume }
        press.wheelRemainder -= CGFloat(steps) * timing.scrollStep
        let action: SystemAction = steps > 0 ? .volumeUp : .volumeDown
        for _ in 0..<min(abs(steps), 5) {
            output.perform(.system(action))
        }
        return .consume
    }

    /// A wheel turn with no button held. Held keys can give it another job (sideways, zoom, faster, slower);
    /// without a job it is reversed, scaled and smoothed like any plain turn, keeping the held keys.
    private func plainWheelScrolled(_ input: MouseInput) -> Disposition {
        guard input.isWheel else { return .passThrough }
        let settings = configProvider().wheel
        let action = settings.action(for: input.modifiers)
        guard action != nil || settings.isActive else { return .passThrough }

        if action == .zoom {
            // One click is `zoomStep`; turning the wheel away from you zooms in.
            let up = WheelNotch.direction(input.lines.y) * (input.isDirectionInverted ? -1 : 1)
            zoomStep(up: Double(up), input: input) { pinchZoom.zoom(by: Double(up) * settings.zoomStep, newGesture: $0) }
        } else {
            wheelScroller.scroll(lines: input.lines, settings: settings, modifiers: input.modifiers, action: action)
        }
        return .consume
    }

    // MARK: - Cursor

    private func setCursorFrozen(_ frozen: Bool) {
        guard cursorFrozen != frozen else { return }
        cursorFrozen = frozen
        output.setCursorFrozen(frozen)
    }
}
