import CoreGraphics
import Foundation
import Testing
@testable import MouseStudio

// MARK: - Test doubles

private final class ManualTask: ScheduledTask {
    let fireAt: TimeInterval
    let work: () -> Void
    var isCancelled = false
    init(fireAt: TimeInterval, work: @escaping () -> Void) {
        self.fireAt = fireAt
        self.work = work
    }
    func cancel() { isCancelled = true }
}

private final class ManualScheduler: Scheduler {
    private(set) var now: TimeInterval = 0
    private var tasks: [ManualTask] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledTask {
        let task = ManualTask(fireAt: now + delay, work: work)
        tasks.append(task)
        return task
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        for task in tasks.filter({ !$0.isCancelled && $0.fireAt <= now }).sorted(by: { $0.fireAt < $1.fireAt }) {
            task.isCancelled = true
            task.work()
        }
        tasks.removeAll { $0.isCancelled }
    }
}

private final class RecordingOutput: EventOutput {
    var actions: [Action] = []
    var scrolls: [(x: Int32, y: Int32, phase: ScrollPhase)] = []
    var frozen: [Bool] = []
    var replays: [MouseButton] = []
    var interactiveSwipe = false
    var swipes: [(axis: SwipeAxis, progress: Double, phase: GesturePhase)] = []

    var supportsInteractiveSwipe: Bool { interactiveSwipe }
    func swipe(_ axis: SwipeAxis, progress: Double, phase: GesturePhase, exitSpeed: Double) { swipes.append((axis, progress, phase)) }

    func perform(_ action: Action) { actions.append(action) }
    var scrollFlags: [ModifierSet] = []
    func scroll(x: Int32, y: Int32, phase: ScrollPhase, modifiers: ModifierSet) {
        scrolls.append((x, y, phase))
        scrollFlags.append(modifiers)
    }
    func setCursorFrozen(_ frozen: Bool) { self.frozen.append(frozen) }
    var clickStates: [Int] = []
    func replayClick(button: MouseButton, modifiers: ModifierSet, clickState: Int, at location: CGPoint) {
        replays.append(button)
        clickStates.append(clickState)
    }
    var pinchNeedsPrimer = false
    var supportsPinch = true
    var magnifies: [(amount: Double, phase: GesturePhase)] = []
    func magnify(_ amount: Double, phase: GesturePhase) { magnifies.append((amount, phase)) }
}

private struct Harness {
    /// The zoom tests count in clicks of 5%, whatever the shipped default is.
    static let fivePercentZoom: WheelSettings = {
        var wheel = WheelSettings()
        wheel.zoomStep = 0.05
        return wheel
    }()

    let output = RecordingOutput()
    let scheduler = ManualScheduler()
    let processor: MouseEventProcessor

    init(rules: [Rule], scroll: ScrollSettings = ScrollSettings(), wheel: WheelSettings = Harness.fivePercentZoom, swipe: SwipeSettings = SwipeSettings()) {
        var smoothless = scroll
        smoothless.smoothness = 0
        let config = EngineConfig(rules: RuleSet(rules: rules), scroll: smoothless, wheel: wheel, swipe: swipe)
        processor = MouseEventProcessor(output: output, scheduler: scheduler, clock: { [scheduler] in scheduler.now }) { config }
    }

    @discardableResult
    func send(_ kind: MouseInput.Kind, button: MouseButton = MouseButton(number: 3), modifiers: ModifierSet = [], delta: CGPoint = .zero, at time: TimeInterval = 0, clickState: Int = 1, wheelLines: CGPoint? = nil, inverted: Bool = false) -> Disposition {
        processor.handle(MouseInput(kind: kind, button: button, modifiers: modifiers, delta: delta, timestamp: time, clickState: clickState, isWheel: wheelLines != nil, lines: wheelLines ?? .zero, isDirectionInverted: inverted))
    }

    func run(seconds: TimeInterval) {
        for _ in 0..<Int(seconds / 0.005) { scheduler.advance(by: 0.005) }
    }
}

private let button4 = MouseButton(number: 3)

private func rule(_ interaction: Interaction, _ action: Action, button: MouseButton = button4, modifiers: ModifierSet = []) -> Rule {
    Rule(trigger: Trigger(button: button, modifiers: modifiers, interaction: interaction), action: action)
}

// MARK: - Tests

@Suite("Mouse event processor")
struct ProcessorTests {
    @Test func eventsWithoutRulesPassThrough() {
        let h = Harness(rules: [rule(.click, .none, button: MouseButton(number: 4))])
        #expect(h.send(.down) == .passThrough)
        #expect(h.send(.dragged, delta: CGPoint(x: 30, y: 0)) == .passThrough)
        #expect(h.send(.up) == .passThrough)
        #expect(h.send(.scroll, delta: CGPoint(x: 0, y: 20)) == .passThrough)
        #expect(h.output.actions.isEmpty && h.output.replays.isEmpty)
    }

    @Test func clickRuleRunsOnceOnReleaseAndSwallowsBothEvents() {
        let h = Harness(rules: [rule(.click, .system(.missionControl))])
        #expect(h.send(.down) == .consume)
        #expect(h.output.actions.isEmpty)
        #expect(h.send(.up) == .consume)
        #expect(h.output.actions == [.system(.missionControl)])
        #expect(h.output.replays.isEmpty)
    }

    @Test func modifiersMustMatchExactly() {
        let h = Harness(rules: [rule(.click, .none, modifiers: [.command])])
        #expect(h.send(.down, modifiers: [.command, .shift]) == .passThrough)
        #expect(h.send(.up, modifiers: [.command, .shift]) == .passThrough)
        #expect(h.send(.down, modifiers: []) == .passThrough)
        #expect(h.send(.down, modifiers: [.command]) == .consume)
    }

    @Test func dragScrollEmitsPhasesFreezesAndReleasesCursor() {
        let h = Harness(rules: [rule(.drag, .dragScroll)])
        h.send(.down)
        #expect(h.send(.dragged, delta: CGPoint(x: 10, y: 20), at: 0.01) == .consume)
        h.send(.dragged, delta: CGPoint(x: 5, y: 5), at: 0.02)
        h.send(.up, at: 0.03)

        #expect(h.output.frozen == [true, false])
        #expect(h.output.scrolls.map(\.phase) == [.began, .changed, .ended])
        #expect(h.output.scrolls.first.map { ($0.x, $0.y) }! == (10, 20))
        #expect(h.output.replays.isEmpty)
        #expect(h.output.actions.isEmpty)
    }

    @Test func dragScrollFollowsInversionAxisLockAndSpeed() {
        var settings = ScrollSettings()
        settings.invertDirection = true
        settings.axisLock = .vertical
        settings.verticalSpeed = 2
        let h = Harness(rules: [rule(.drag, .dragScroll)], scroll: settings)
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 10, y: 10), at: 0.01)
        let first = h.output.scrolls.first
        #expect(first?.x == 0)
        #expect(first?.y == -20)
        h.send(.up)
    }

    @Test func tinyMovementsAreNotLost() {
        var settings = ScrollSettings()
        settings.sensitivity = 0.5
        let h = Harness(rules: [rule(.drag, .dragScroll)], scroll: settings)
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 5), at: 0.01)   // starts the drag: 2.5 px
        for i in 0..<10 { h.send(.dragged, delta: CGPoint(x: 0, y: 1), at: 0.02 + Double(i) * 0.01) }
        h.send(.up)
        let total = h.output.scrolls.reduce(0) { $0 + Int($1.y) }
        #expect(total == 7 || total == 8)   // 15 px × 0.5 = 7.5: nothing is lost, the last half pixel is rounded in
    }

    @Test func clickWithOnlyDragRuleIsReplayedNatively() {
        let h = Harness(rules: [rule(.drag, .dragScroll)])
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 1, y: 1))
        h.send(.up)
        #expect(h.output.replays == [button4])
        #expect(h.output.scrolls.isEmpty)
    }

    @Test func dragDoesNotTriggerTheClickRule() {
        let h = Harness(rules: [rule(.click, .system(.back)), rule(.drag, .dragScroll)])
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 30), at: 0.01)
        h.send(.up)
        #expect(h.output.actions.isEmpty)
        #expect(h.output.replays.isEmpty)
    }

    @Test func releasingTheModifierStopsScrollingImmediately() {
        let h = Harness(rules: [rule(.drag, .dragScroll, modifiers: [.option])])
        h.send(.down, modifiers: [.option])
        h.send(.dragged, modifiers: [.option], delta: CGPoint(x: 0, y: 20), at: 0.01)
        h.send(.flagsChanged, modifiers: [])
        #expect(h.output.frozen == [true, false])
        #expect(h.output.scrolls.last?.phase == .ended)

        let before = h.output.scrolls.count
        #expect(h.send(.dragged, modifiers: [], delta: CGPoint(x: 0, y: 20), at: 0.02) == .consume)
        #expect(h.send(.up, modifiers: []) == .consume)
        #expect(h.output.scrolls.count == before)
        #expect(h.output.replays.isEmpty && h.output.actions.isEmpty)
    }

    @Test func addingAnotherModifierDoesNotInterruptDrag() {
        let h = Harness(rules: [rule(.drag, .dragScroll)])
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 20), at: 0.01)
        h.send(.flagsChanged, modifiers: [.shift])
        h.send(.dragged, modifiers: [.shift], delta: CGPoint(x: 0, y: 20), at: 0.02)
        h.run(seconds: 0.03)
        #expect(h.output.scrolls.map(\.phase) == [.began, .changed])
    }

    @Test func resetReleasesTheCursorAndForgetsPresses() {
        let h = Harness(rules: [rule(.drag, .dragScroll)])
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 20), at: 0.01)
        h.processor.reset()
        #expect(h.output.frozen == [true, false])
        // The release that follows a reset belongs to a press nobody remembers, so it passes through.
        #expect(h.send(.up) == .passThrough)
    }

    @Test func holdFiresAfterTheHoldTimeAndSuppressesClick() {
        let h = Harness(rules: [rule(.click, .system(.back)), rule(.hold, .system(.missionControl))])
        h.send(.down)
        h.scheduler.advance(by: 0.5)
        #expect(h.output.actions == [.system(.missionControl)])
        h.send(.up)
        #expect(h.output.actions == [.system(.missionControl)])
    }

    @Test func shortPressWithHoldRuleIsAClick() {
        let h = Harness(rules: [rule(.click, .system(.back)), rule(.hold, .system(.missionControl))])
        h.send(.down)
        h.scheduler.advance(by: 0.1)
        h.send(.up)
        h.scheduler.advance(by: 1)
        #expect(h.output.actions == [.system(.back)])
    }

    @Test func doubleClickRuleReplacesTheSingleClick() {
        let h = Harness(rules: [rule(.click, .system(.back)), rule(.doubleClick, .system(.forward))])
        h.send(.down); h.send(.up)
        h.scheduler.advance(by: 0.1)
        h.send(.down); h.send(.up)
        h.scheduler.advance(by: 1)
        #expect(h.output.actions == [.system(.forward)])
    }

    @Test func singleClickWaitsOutTheDoubleClickWindow() {
        let h = Harness(rules: [rule(.click, .system(.back)), rule(.doubleClick, .system(.forward))])
        h.send(.down); h.send(.up)
        #expect(h.output.actions.isEmpty)
        h.scheduler.advance(by: 0.5)
        #expect(h.output.actions == [.system(.back)])
    }

    @Test func clickAndScrollPinchesSmoothlyWithoutClicking() {
        let h = Harness(rules: [rule(.click, .system(.back)), rule(.scroll, .scrollZoom)])
        h.send(.down)
        #expect(h.send(.scroll, delta: CGPoint(x: 0, y: 20)) == .consume)
        h.run(seconds: 1)
        #expect(h.send(.scroll, delta: CGPoint(x: 0, y: -10), at: 5) == .consume)
        h.run(seconds: 1)
        h.send(.up)
        h.run(seconds: 1)
        let phases = h.output.magnifies.map(\.phase)
        #expect(phases.first == .began && phases.last == .ended)
        #expect(h.output.magnifies.first?.amount == 0)          // opens with a zero-size "began", like a Trackpad
        #expect(phases.filter { $0 == .began }.count == 2)
        // 20 points up zooms in by 0.1, 10 points down zooms back out by 0.05.
        let total = h.output.magnifies.reduce(0) { $0 + $1.amount }
        #expect(abs(total - 0.05) < 0.002)
        #expect(h.output.magnifies.filter { $0.phase == .changed }.count > 3)   // spread over many frames
        #expect(h.output.actions.isEmpty)
    }

    @Test func scrollingWithoutTheButtonPassesThrough() {
        let h = Harness(rules: [rule(.scroll, .scrollZoom)])
        #expect(h.send(.scroll, delta: CGPoint(x: 0, y: 12)) == .passThrough)
    }

    @Test func swipeDragFiresOncePerPress() {
        let h = Harness(rules: [rule(.drag, .swipeGesture)])
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: -50, y: 0), at: 0.01)
        h.send(.dragged, delta: CGPoint(x: -50, y: 0), at: 0.02)
        h.send(.dragged, delta: CGPoint(x: -50, y: 0), at: 0.03)
        h.send(.up)
        #expect(h.output.actions == [.system(.spaceRight)])
    }
}

@Suite("Click and scroll")
struct ClickAndScrollTests {
    private func zoomHarness() -> Harness {
        Harness(rules: [rule(.scroll, .scrollZoom), rule(.drag, .dragScroll)])
    }

    private func zoomed(_ h: Harness) -> Double {
        h.run(seconds: 1)
        return h.output.magnifies.reduce(0) { $0 + $1.amount }
    }

    @Test func wheelAwayFromYouZoomsInWhateverTheSystemScrollDirection() {
        for inverted in [false, true] {
            let h = zoomHarness()
            h.send(.down)
            // Turning the wheel away gives positive deltas normally and negative ones with natural scrolling.
            h.send(.scroll, delta: CGPoint(x: 0, y: inverted ? -20 : 20), inverted: inverted)
            #expect(zoomed(h) > 0.05, "inverted=\(inverted)")

            let down = zoomHarness()
            down.send(.down)
            down.send(.scroll, delta: CGPoint(x: 0, y: inverted ? 20 : -20), inverted: inverted)
            #expect(zoomed(down) < -0.05, "inverted=\(inverted)")
        }
    }

    @Test func scrollingAfterTheHandWanderedStillZoomsInsteadOfScrollingThePage() {
        let h = zoomHarness()
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 30), at: 0.01)      // enough to start a drag
        #expect(h.output.frozen == [true])
        #expect(h.send(.scroll, delta: CGPoint(x: 0, y: 20)) == .consume)
        #expect(zoomed(h) > 0.05)
        #expect(h.output.frozen == [true, false])                    // the drag ended, pointer released
        // Moving more does not turn it back into a drag.
        h.send(.dragged, delta: CGPoint(x: 0, y: 40), at: 0.5)
        let scrolls = h.output.scrolls.count
        h.run(seconds: 0.1)
        #expect(h.output.scrolls.count == scrolls)
        h.send(.up)
    }

    @Test func chromiumStyleAppsGetAPrimerSoSmallStepsCountFromTheStart() {
        for zoomIn in [true, false] {
            let h = zoomHarness()
            h.output.pinchNeedsPrimer = true
            h.send(.down)
            h.send(.scroll, delta: CGPoint(x: 0, y: zoomIn ? 10 : -10))
            h.run(seconds: 1)
            h.send(.up)
            let steps = h.output.magnifies
            #expect(steps[0].phase == .began && steps[0].amount == 0)
            #expect(steps[1].phase == .changed)
            #expect(steps[1].amount == (zoomIn ? PinchZoom.primerZoomIn : PinchZoom.primerZoomOut))   // swallowed by the app
            #expect(steps.filter { $0.phase == .began }.count == 1)
            let real = steps.dropFirst(2).filter { $0.phase == .changed }.reduce(0) { $0 + $1.amount }
            #expect(abs(real - (zoomIn ? 0.05 : -0.05)) < 0.002)
        }
    }

    @Test func thePrimerReachesTheAppAloneBeforeAnyRealStep() {
        // Chromium merges steps that arrive together; primer + first real step in one frame crosses its line and jumps.
        let h = zoomHarness()
        h.output.pinchNeedsPrimer = true
        h.send(.down)
        h.send(.scroll, delta: CGPoint(x: 0, y: 10))
        #expect(h.output.magnifies.map(\.phase) == [.began, .changed])
        #expect(h.output.magnifies.last?.amount == PinchZoom.primerZoomIn)
        h.scheduler.advance(by: 0.05)   // still inside the gap the app needs to see the primer on its own
        #expect(h.output.magnifies.count == 2)
        h.scheduler.advance(by: 0.05)
        #expect(h.output.magnifies.count >= 3)
        #expect(h.output.magnifies[2].amount > 0 && h.output.magnifies[2].amount < 0.05)
    }

    @Test func turningTheWheelTheOtherWayStartsANewPrimedGesture() {
        let h = zoomHarness()
        h.output.pinchNeedsPrimer = true
        h.send(.down)
        h.send(.scroll, delta: CGPoint(x: 0, y: 10))
        h.run(seconds: 0.3)
        h.send(.scroll, delta: CGPoint(x: 0, y: -10))
        h.run(seconds: 1)
        let phases = h.output.magnifies.map(\.phase)
        #expect(phases.filter { $0 == .began }.count == 2)
        let primers = h.output.magnifies.filter { $0.amount == PinchZoom.primerZoomIn || $0.amount == PinchZoom.primerZoomOut }.map(\.amount)
        #expect(primers == [PinchZoom.primerZoomIn, PinchZoom.primerZoomOut])
    }

    @Test func otherAppsNeverGetThePrimer() {
        let h = zoomHarness()
        h.send(.down)
        h.send(.scroll, delta: CGPoint(x: 0, y: 10))
        h.run(seconds: 1)
        #expect(h.output.magnifies.allSatisfy { $0.amount < PinchZoom.primerZoomIn })
    }

    @Test func aTwitchingThumbDoesNotScrollThePageBeforeTheWheelTurns() {
        // Reproduced on a real Chrome: slow 1 pt twitches after pressing the button scrolled the page ~6 pt each time.
        let h = zoomHarness()
        h.send(.down)
        for i in 0..<8 { h.send(.dragged, delta: CGPoint(x: 1, y: i % 2 == 0 ? 1 : 0), at: 0.06 * Double(i + 1)) }   // 8 pt in 0.5 s
        h.send(.scroll, delta: CGPoint(x: 0, y: 10), wheelLines: CGPoint(x: 0, y: 1))
        h.run(seconds: 1)
        h.send(.up)
        #expect(abs(h.output.scrolls.reduce(0) { $0 + Int($1.y) }) <= 4)   // a twitch eases in: barely moves the page
        #expect(h.output.magnifies.reduce(0) { $0 + $1.amount } > 0.04)
    }

    @Test func theRecordedThumbJerkDoesNotStartADrag() {
        // From a real trace: the button was pressed and 0.4 s later a 5–6 pt jerk started Drag Scroll, which ran for
        // 1.2 s until the wheel turned. A quick but brief jerk (one report of 6 pt) must not count.
        let h = zoomHarness()
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 2, y: 4), at: 0.38)
        h.send(.dragged, delta: CGPoint(x: 0, y: 2), at: 0.388)
        h.send(.dragged, delta: CGPoint(x: 0, y: 1), at: 0.40)
        h.run(seconds: 0.5)
        h.send(.scroll, delta: CGPoint(x: 0, y: 10), wheelLines: CGPoint(x: 0, y: 1))
        h.run(seconds: 0.5)
        h.send(.up)
        #expect(abs(h.output.scrolls.reduce(0) { $0 + Int($1.y) }) <= 4)
    }

    @Test func aDeliberateFastDragStillStartsAtOnceOnAButtonWithClickAndScroll() {
        let h = zoomHarness()
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 6), at: 0.004)
        h.send(.dragged, delta: CGPoint(x: 0, y: 8), at: 0.012)
        #expect(h.output.scrolls.first?.phase == .began)     // started within two events (14 pt in 8 ms)
        h.send(.up, at: 0.02)
    }

    @Test func aSlowButLongDragStartsOnceItHasGoneFarEnough() {
        let h = zoomHarness()
        h.send(.down)
        for i in 1...50 { h.send(.dragged, delta: CGPoint(x: 0, y: 1), at: 0.04 * Double(i)) }    // 25 pt/s for 2 s
        h.run(seconds: 0.2)
        #expect(h.output.scrolls.first?.phase == .began)
        #expect(h.output.scrolls.reduce(0) { $0 + Int($1.y) } > 20)     // keeps moving the page, with no dead stretch first
        h.send(.up, at: 2.1)
    }

    @Test func buttonsWithoutClickAndScrollKeepTheQuickThreshold() {
        let h = Harness(rules: [rule(.drag, .dragScroll)])
        h.send(.down)
        for i in 1...5 { h.send(.dragged, delta: CGPoint(x: 0, y: 1), at: 0.1 * Double(i)) }       // slow, 5 pt
        #expect(h.output.scrolls.first?.phase == .began)
        h.send(.up, at: 0.6)
    }

    @Test func zoomFollowsTheTotalNumberOfClicksInAFlick() {
        // A fast flick of a real wheel is 5-8 events (recorded), each a click: zoom is the sum, not one click.
        func zoomed(_ times: [Double]) -> Double {
            let h = zoomHarness()
            h.send(.down)
            for t in times { h.send(.scroll, delta: CGPoint(x: 0, y: 10), at: 0.3 + t, wheelLines: CGPoint(x: 0, y: 1)) }
            h.run(seconds: 1.5)
            return h.output.magnifies.filter { $0.phase == .changed }.reduce(0) { $0 + $1.amount }
        }
        #expect(abs(zoomed([0]) - 0.05) < 0.003)
        #expect(abs(zoomed([0, 0.031, 0.065, 0.115, 0.165]) - 5 * 0.05) < 0.01)
        #expect(abs(zoomed([0, 0.031, 0.065, 0.115, 0.165, 0.194, 0.24, 0.29]) - 8 * 0.05) < 0.015)
    }

    @Test func eachFlickOpensAFreshPinchButNotForChromium() {
        func gestures(primer: Bool) -> Int {
            let h = zoomHarness()
            h.output.pinchNeedsPrimer = primer
            h.send(.down)
            for flick in 0..<3 {
                for k in 0..<5 { h.send(.scroll, delta: CGPoint(x: 0, y: 10), at: 0.3 + 0.4 * Double(flick) + 0.03 * Double(k), wheelLines: CGPoint(x: 0, y: 1)) }
                h.run(seconds: 0.4)
            }
            return h.output.magnifies.filter { $0.phase == .began }.count
        }
        #expect(gestures(primer: false) == 3)   // PasteClip, Preview...: a pinch per flick, as with a real Trackpad
        #expect(gestures(primer: true) == 1)    // Chromium needs one long pinch
    }

    @Test func withoutPinchSupportZoomFallsBackToKeyboardSteps() {
        let h = zoomHarness()
        h.output.supportsPinch = false
        h.send(.down)
        h.send(.scroll, delta: CGPoint(x: 0, y: 10), at: 1, wheelLines: CGPoint(x: 0, y: 1))
        h.send(.scroll, delta: CGPoint(x: 0, y: -10), at: 2, wheelLines: CGPoint(x: 0, y: -1))
        h.run(seconds: 1)
        #expect(h.output.magnifies.isEmpty)
        #expect(h.output.actions == [.system(.zoomIn), .system(.zoomOut)])
    }

    @Test func theZoomStepSettingSetsTheSizeOfEachClick() {
        #expect(WheelSettings().zoomStep == 0.05)
        var wheel = WheelSettings()
        wheel.zoomStep = 0.2
        let h = Harness(rules: [rule(.scroll, .scrollZoom)], wheel: wheel)
        h.send(.down)
        h.send(.scroll, delta: CGPoint(x: 0, y: 10), at: 1, wheelLines: CGPoint(x: 0, y: 1))
        h.run(seconds: 1.5)
        #expect(abs(h.output.magnifies.reduce(0) { $0 + $1.amount } - 0.2) < 0.005)
    }

    @Test func separateNotchesStillZoomFivePercentEach() {
        let h = zoomHarness()
        h.send(.down)
        for i in 0..<3 { h.send(.scroll, delta: CGPoint(x: 0, y: 10), at: 0.3 + 0.3 * Double(i), wheelLines: CGPoint(x: 0, y: 1)) }
        h.run(seconds: 1.5)
        let total = h.output.magnifies.filter { $0.phase == .changed }.reduce(0) { $0 + $1.amount }
        #expect(abs(total - 0.15) < 0.005)
    }

    @Test func quickNotchesAreOneOpenPinch() {
        let h = zoomHarness()
        h.send(.down)
        for _ in 0..<4 {
            h.send(.scroll, delta: CGPoint(x: 0, y: 10))
            h.run(seconds: 0.15)
        }
        h.run(seconds: 1)
        #expect(h.output.magnifies.filter { $0.phase == .ended }.isEmpty)     // stays open while the button is held
        h.send(.up)
        h.run(seconds: 1)
        #expect(h.output.magnifies.filter { $0.phase == .began }.count == 1)
        #expect(h.output.magnifies.filter { $0.phase == .ended }.count == 1)
    }

    @Test func zoomKeepsWorkingAfterTheButtonHasBeenHeldForAWhile() {
        // The reported case: hold the button, turn the wheel 1–2 clicks, keep holding, wait 2 s, turn again.
        for jitter in [false, true] {
            let h = zoomHarness()
            h.send(.down)
            var zooms: [Double] = []
            for round in 0..<4 {
                let before = h.output.magnifies.reduce(0) { $0 + $1.amount }
                // How the mouse reports a burst: first click tiny, then growing; the tap turns each into one notch.
                h.send(.scroll, delta: CGPoint(x: 0, y: 1), at: h.scheduler.now, wheelLines: CGPoint(x: 0, y: 1))
                h.run(seconds: 0.1)
                h.send(.scroll, delta: CGPoint(x: 0, y: 12), at: h.scheduler.now, wheelLines: CGPoint(x: 0, y: 1))
                // The hand rests on the mouse: tiny movements while waiting.
                for tick in 0..<20 {
                    if jitter { h.send(.dragged, delta: CGPoint(x: 1, y: tick % 2 == 0 ? 1 : -1), at: h.scheduler.now) }
                    h.run(seconds: 0.1)
                }
                zooms.append(h.output.magnifies.reduce(0) { $0 + $1.amount } - before)
                #expect(h.output.frozen.isEmpty || h.output.frozen.last == false, "round \(round) jitter=\(jitter)")
            }
            for (round, zoom) in zooms.enumerated() {
                #expect(abs(zoom - 0.1) < 0.005, "round \(round + 1) jitter=\(jitter) zoomed \(zoom)")
            }
            h.send(.up)
        }
    }

    @Test func everyWheelTurnWhileHeldIsHandled() {
        let h = zoomHarness()
        h.send(.down)
        for _ in 0..<6 {
            #expect(h.send(.scroll, delta: CGPoint(x: 0, y: 10)) == .consume)
            h.run(seconds: 0.05)
        }
        h.send(.up)
        h.run(seconds: 1)
        #expect(h.output.scrolls.isEmpty)
    }

    @Test func volumeFollowsTheWheelDirectionToo() {
        let h = Harness(rules: [rule(.scroll, .scrollVolume)])
        h.send(.down)
        h.send(.scroll, delta: CGPoint(x: 0, y: -30), inverted: true)   // away from you, natural scrolling
        #expect(h.output.actions == [.system(.volumeUp), .system(.volumeUp), .system(.volumeUp)])
    }
}

@Suite("Swipe that follows the pointer")
struct SwipeTests {
    private func harness() -> Harness {
        let h = Harness(rules: [rule(.drag, .swipeGesture)])
        h.output.interactiveSwipe = true
        return h
    }

    @Test func horizontalDragLeftMovesProgressNegativeAndFreezesCursor() {
        let h = harness()
        h.send(.down)
        for i in 1...10 { h.send(.dragged, delta: CGPoint(x: -10, y: 1), at: Double(i) * 0.01) }
        #expect(h.output.swipes.first?.phase == .began)
        #expect(h.output.swipes.allSatisfy { $0.axis == .horizontal })
        #expect(h.output.swipes.last!.progress < -0.1)
        #expect(h.output.frozen == [true])
        h.send(.up, at: 0.105)
        #expect(h.output.swipes.last?.phase == .ended)
        #expect(h.output.frozen == [true, false])
        #expect(h.output.actions.isEmpty)
    }

    @Test func draggingUpIsPositiveVerticalProgress() {
        let h = harness()
        h.send(.down)
        for i in 1...5 { h.send(.dragged, delta: CGPoint(x: 0, y: -20), at: Double(i) * 0.01) }
        #expect(h.output.swipes.allSatisfy { $0.axis == .vertical })
        #expect(h.output.swipes.last!.progress > 0.1)
    }

    @Test func speedSettingScalesHowFarTheDesktopsMove() {
        func progress(speed: Double) -> Double {
            var swipe = SwipeSettings()
            swipe.speed = speed
            let h = Harness(rules: [rule(.drag, .swipeGesture)], swipe: swipe)
            h.output.interactiveSwipe = true
            h.send(.down)
            h.send(.dragged, delta: CGPoint(x: 100, y: 0), at: 0.01)
            return h.output.swipes.last!.progress
        }
        #expect(abs(progress(speed: 1) - 100.0 / 625) < 0.0001)
        #expect(abs(progress(speed: 0.5) - progress(speed: 1) / 2) < 0.0001)
    }

    @Test func progressGrowsGraduallyWithEveryMovement() {
        let h = harness()
        h.send(.down)
        for i in 1...6 { h.send(.dragged, delta: CGPoint(x: 15, y: 0), at: Double(i) * 0.01) }
        let progress = h.output.swipes.map(\.progress)
        #expect(progress.count >= 5)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func pullingBackBeforeReleaseCancels() {
        let h = harness()
        h.send(.down)
        for i in 1...20 { h.send(.dragged, delta: CGPoint(x: 50, y: 0), at: Double(i) * 0.01) }
        for i in 21...30 { h.send(.dragged, delta: CGPoint(x: -30, y: 0), at: Double(i) * 0.01) }
        #expect(h.output.swipes.last!.progress > 0)
        h.send(.up, at: 0.305)
        #expect(h.output.swipes.last?.phase == .cancelled)
    }

    @Test func releasingTheModifierOrResettingCancelsTheSwipe() {
        let h = Harness(rules: [rule(.drag, .swipeGesture, modifiers: [.option])])
        h.output.interactiveSwipe = true
        h.send(.down, modifiers: [.option])
        h.send(.dragged, modifiers: [.option], delta: CGPoint(x: 30, y: 0), at: 0.01)
        h.send(.flagsChanged, modifiers: [])
        #expect(h.output.swipes.last?.phase == .cancelled)

        let r = harness()
        r.send(.down)
        r.send(.dragged, delta: CGPoint(x: 30, y: 0), at: 0.01)
        r.processor.reset()
        #expect(r.output.swipes.last?.phase == .cancelled)
        #expect(r.output.frozen == [true, false])
    }
}

@Suite("Glide after release")
struct GlideTests {
    /// Drags downward at 500 px/s, then releases `pause` seconds after the last movement.
    private func flick(inertia: Double = 0.5, pause: TimeInterval = 0.005) -> Harness {
        var settings = ScrollSettings()
        settings.inertia = inertia
        let h = Harness(rules: [rule(.drag, .dragScroll)], scroll: settings)
        h.send(.down)
        for i in 1...12 { h.send(.dragged, delta: CGPoint(x: 0, y: 4), at: Double(i) * 0.008) }
        h.send(.up, at: 12 * 0.008 + pause)
        return h
    }

    private func runGlide(_ h: Harness, seconds: TimeInterval) {
        for _ in 0..<Int(seconds / 0.01) { h.scheduler.advance(by: 0.01) }
    }

    @Test func flickKeepsGlidingThenStops() {
        let h = flick()
        runGlide(h, seconds: 4)
        let phases = h.output.scrolls.map(\.phase)
        #expect(phases.contains(.momentumBegan))
        #expect(phases.last == .momentumEnded)
        let glide = h.output.scrolls.filter { $0.phase == .momentumBegan || $0.phase == .momentumChanged }
        #expect(glide.reduce(0) { $0 + Int($1.y) } > 100)
        #expect(glide.allSatisfy { $0.y >= 0 })
        // It slows down: the second half moves less than the first half.
        let half = glide.count / 2
        #expect(glide.prefix(half).reduce(0) { $0 + Int($1.y) } > glide.suffix(glide.count - half).reduce(0) { $0 + Int($1.y) })
    }

    @Test func pausingBeforeReleaseMeansNoGlide() {
        let h = flick(pause: 0.3)
        runGlide(h, seconds: 2)
        #expect(!h.output.scrolls.contains { $0.phase == .momentumBegan })
    }

    @Test func zeroInertiaMeansNoGlide() {
        let h = flick(inertia: 0)
        runGlide(h, seconds: 2)
        #expect(!h.output.scrolls.contains { $0.phase == .momentumBegan })
    }

    @Test func touchingTheMouseStopsTheGlide() {
        let h = flick()
        runGlide(h, seconds: 0.3)
        #expect(h.output.scrolls.last?.phase == .momentumChanged)
        h.send(.scroll, button: .left, delta: CGPoint(x: 0, y: 3))
        #expect(h.output.scrolls.last?.phase == .momentumEnded)
        let count = h.output.scrolls.count
        runGlide(h, seconds: 1)
        #expect(h.output.scrolls.count == count)
    }

    @Test func cancellingByReleasingTheModifierDoesNotGlide() {
        var settings = ScrollSettings()
        settings.inertia = 1
        let h = Harness(rules: [rule(.drag, .dragScroll, modifiers: [.option])], scroll: settings)
        h.send(.down, modifiers: [.option])
        for i in 1...12 { h.send(.dragged, modifiers: [.option], delta: CGPoint(x: 0, y: 4), at: Double(i) * 0.008) }
        h.send(.flagsChanged, modifiers: [])
        runGlide(h, seconds: 1)
        #expect(!h.output.scrolls.contains { $0.phase == .momentumBegan })
    }
}

@Suite("Drag scroll maths")
struct AccumulatorTests {
    @Test func appliesDirectionAxisLockAndSpeed() {
        var settings = ScrollSettings()
        settings.invertDirection = true
        settings.axisLock = .vertical
        settings.verticalSpeed = 2
        var accumulator = DragScrollAccumulator()
        let out = accumulator.consume(CGPoint(x: 10, y: 10), at: 0, settings: settings)
        #expect(out == CGPoint(x: 0, y: -20))
        #expect(accumulator.consume(CGPoint(x: 10, y: 0), at: 0.01, settings: settings) == nil)
    }

    @Test func releaseVelocityMatchesSteadyDrag() {
        var accumulator = DragScrollAccumulator()
        let settings = ScrollSettings()
        for i in 1...12 { _ = accumulator.consume(CGPoint(x: 0, y: 4), at: Double(i) * 0.008, settings: settings) }
        let velocity = accumulator.releaseVelocity(at: 12 * 0.008 + 0.004)
        #expect(abs(velocity.y - 500) < 80)    // 4 pt every 8 ms
        #expect(accumulator.releaseVelocity(at: 12 * 0.008 + 0.3) == .zero)
    }
}

@Suite("Drag scroll pacing")
struct DragPacingTests {
    @Test func manyMouseEventsPerFrameBecomeOneScrollPerFrame() {
        var settings = ScrollSettings()
        settings.smoothness = 0
        let h = Harness(rules: [rule(.drag, .dragScroll)], scroll: settings)
        h.send(.down)
        // A 1000 Hz mouse for 100 ms: 100 events of 2 points.
        for i in 1...100 {
            h.send(.dragged, delta: CGPoint(x: 0, y: 2), at: Double(i) * 0.001)
            h.scheduler.advance(by: 0.001)
        }
        let moves = h.output.scrolls.filter { $0.phase == .began || $0.phase == .changed }
        #expect(moves.count <= 14)                       // ~120 Hz, not 1000 Hz
        #expect(moves.count >= 8)
        #expect(moves.allSatisfy { $0.y > 0 })
        h.send(.up, at: 0.101)
        #expect(h.output.scrolls.filter { $0.phase != .ended }.reduce(0) { $0 + Int($1.y) } == 200)   // nothing lost
    }

    @Test func releaseFlushesWhatWasGathered() {
        let h = Harness(rules: [rule(.drag, .dragScroll)])
        h.send(.down)
        h.send(.dragged, delta: CGPoint(x: 0, y: 10), at: 0.01)
        h.send(.dragged, delta: CGPoint(x: 0, y: 10), at: 0.011)
        h.send(.up, at: 0.012)
        #expect(h.output.scrolls.reduce(0) { $0 + Int($1.y) } == 20)
        #expect(h.output.scrolls.last?.phase == .ended)
    }
}

@Suite("Mouse wheel")
struct WheelTests {
    private let line = Int(WheelScroller.pointsPerLine)

    private func harness(_ edit: (inout WheelSettings) -> Void = { _ in }) -> Harness {
        var wheel = WheelSettings()
        wheel.acceleration = 0
        edit(&wheel)
        return Harness(rules: [], wheel: wheel)
    }

    private func total(_ h: Harness) -> (x: Int, y: Int) {
        (h.output.scrolls.reduce(0) { $0 + Int($1.x) }, h.output.scrolls.reduce(0) { $0 + Int($1.y) })
    }

    @Test func smoothScrollSpreadsOneNotchOverManyFramesWithoutGesturePhases() {
        let h = harness()
        #expect(h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1)) == .consume)
        h.run(seconds: 1.5)
        #expect(h.output.scrolls.count > 8)
        // No gesture phases: apps must not rubber-band at the top or bottom of a page.
        #expect(h.output.scrolls.allSatisfy { $0.phase == .plain })
        #expect(total(h).y == line)
        #expect(Int(h.output.scrolls.first!.y) > Int(h.output.scrolls.last!.y))   // eases out
    }

    @Test func reverseFlipsEachAxisIndependently() {
        let h = harness { $0.reverseVertical = true }
        h.send(.scroll, button: .left, wheelLines: CGPoint(x: 1, y: 1))
        h.run(seconds: 1.5)
        #expect(total(h).y == -line)
        #expect(total(h).x == line)
    }

    @Test func speedScalesDistance() {
        let h = harness { $0.speed = 2 }
        h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1))
        h.run(seconds: 1.5)
        #expect(total(h).y == 2 * line)
    }

    @Test func fewSlowNotchesScrollTheBaseDistanceAndFastSpinsScrollFurther() {
        func distanceOfFiveNotches(gap: TimeInterval, acceleration: Double) -> Int {
            let h = harness { $0.acceleration = acceleration }
            for _ in 0..<5 {
                h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1))
                h.run(seconds: gap)
            }
            h.run(seconds: 2)
            return total(h).y
        }
        #expect(distanceOfFiveNotches(gap: 0.4, acceleration: 1) == 5 * line)          // unhurried: no boost
        #expect(distanceOfFiveNotches(gap: 0.02, acceleration: 0) == 5 * line)         // no acceleration: no boost
        #expect(distanceOfFiveNotches(gap: 0.02, acceleration: 1) > 8 * line)          // fast + acceleration: far more
        #expect(distanceOfFiveNotches(gap: 0.02, acceleration: 0.5) < distanceOfFiveNotches(gap: 0.02, acceleration: 1))
    }

    @Test func quickNotchesBlendIntoOneGlide() {
        let h = harness()
        for _ in 0..<5 {
            h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1))
            h.run(seconds: 0.02)
        }
        h.run(seconds: 2)
        #expect(total(h).y == 5 * line)
    }

    @Test func reversingDirectionCancelsWhatWasLeft() {
        let h = harness()
        h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 3))
        h.run(seconds: 0.03)
        let before = total(h).y
        h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: -1))
        h.run(seconds: 2)
        #expect(total(h).y == before - line)
    }

    @Test func withoutSmoothingEachNotchIsOneImmediateStep() {
        let h = harness { $0.smooth = false; $0.reverseVertical = true }
        h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1))
        #expect(h.output.scrolls.count == 1)
        #expect(total(h).y == -line)
    }

    @Test func trackpadsAreNeverTouched() {
        let h = harness()
        #expect(h.send(.scroll, button: .left, delta: CGPoint(x: 0, y: 30)) == .passThrough)   // not a wheel
        #expect(h.send(.scroll, button: .left, modifiers: [.shift], delta: CGPoint(x: 0, y: 30)) == .passThrough)
        #expect(h.output.scrolls.isEmpty)
    }

    // MARK: Keyboard modifiers

    @Test func shiftTurnsTheWheelSidewaysInTheSameDirectionAsAPlainTurn() {
        for reverse in [false, true] {
            let plain = harness { $0.reverseVertical = reverse }
            plain.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1))
            plain.run(seconds: 1.5)

            let sideways = harness { $0.reverseVertical = reverse }
            sideways.send(.scroll, button: .left, modifiers: [.shift], wheelLines: CGPoint(x: 0, y: 1))
            sideways.run(seconds: 1.5)
            #expect(total(sideways).y == 0)
            #expect(total(sideways).x == total(plain).y)
            #expect(sideways.output.scrollFlags.allSatisfy { $0.isEmpty })   // shift is used up, not passed on
        }
    }

    @Test func controlScrollsSwiftlyAndOptionPrecisely() {
        let plain = harness(); plain.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1)); plain.run(seconds: 1.5)
        let swift = harness(); swift.send(.scroll, button: .left, modifiers: [.control], wheelLines: CGPoint(x: 0, y: 1)); swift.run(seconds: 1.5)
        let precise = harness(); precise.send(.scroll, button: .left, modifiers: [.option], wheelLines: CGPoint(x: 0, y: 1)); precise.run(seconds: 1.5)
        #expect(total(swift).y == 3 * total(plain).y)
        #expect(abs(total(precise).y - Int(0.3 * Double(total(plain).y))) <= 1)
    }

    @Test func reversalAppliesToHeldKeysToo() {
        // Regression: ⌃-scroll once went the opposite way to a plain turn because it bypassed the reversal.
        let h = harness { $0.reverseVertical = true }
        h.send(.scroll, button: .left, modifiers: [.control], wheelLines: CGPoint(x: 0, y: 1))
        h.run(seconds: 1.5)
        #expect(total(h).y < 0)
        let unassigned = harness { $0.reverseVertical = true }
        unassigned.send(.scroll, button: .left, modifiers: [.control, .option], wheelLines: CGPoint(x: 0, y: 1))
        unassigned.run(seconds: 1.5)
        #expect(total(unassigned).y < 0)
        #expect(unassigned.output.scrollFlags.allSatisfy { $0 == [.control, .option] })   // keys still reach the app
    }

    @Test func commandScrollZoomsWithAPinch() {
        let h = harness()
        #expect(h.send(.scroll, button: .left, modifiers: [.command], wheelLines: CGPoint(x: 0, y: 1)) == .consume)
        h.run(seconds: 1)
        #expect(h.output.scrolls.isEmpty)
        #expect(abs(h.output.magnifies.reduce(0) { $0 + $1.amount } - WheelSettings().zoomStep) < 0.002)

        let natural = harness()
        natural.send(.scroll, button: .left, modifiers: [.command], wheelLines: CGPoint(x: 0, y: -1), inverted: true)   // away from you
        natural.run(seconds: 1)
        #expect(natural.output.magnifies.reduce(0) { $0 + $1.amount } > 0.04)
    }

    @Test func aRemovedKeyNoLongerHasAJob() {
        var wheel = WheelSettings()
        wheel.acceleration = 0
        wheel.smooth = false
        wheel.zoomKeys = []
        wheel.reverseVertical = true
        let h = Harness(rules: [], wheel: wheel)
        h.send(.scroll, button: .left, modifiers: [.command], wheelLines: CGPoint(x: 0, y: 1))   // plain scroll with ⌘ kept
        #expect(h.output.magnifies.isEmpty)
        #expect(h.output.scrollFlags == [.command])
    }

    @Test func assigningKeysTakesThemFromTheOtherJob() {
        var wheel = WheelSettings()
        wheel.assign(.control, to: .zoom)
        #expect(wheel.zoomKeys == .control)
        #expect(wheel.swiftKeys.isEmpty)
        #expect(wheel.action(for: .control) == .zoom)
        #expect(wheel.action(for: []) == nil)
        wheel.assign([.command, .shift], to: .precise)
        #expect(wheel.action(for: [.command, .shift]) == .precise)
    }

    @Test func keyAssignmentsSurviveSavingAndLoading() throws {
        var config = AppConfig()
        config.wheel.assign(.shift, to: .swift)
        config.wheel.assign([], to: .zoom)
        let data = try JSONEncoder().encode(config)
        let loaded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(loaded.wheel.swiftKeys == .shift)
        #expect(loaded.wheel.zoomKeys.isEmpty)
        #expect(loaded.wheel.horizontalScrollKeys.isEmpty)   // taken by swift
    }

    @Test func untouchedSettingsLeaveTheWheelAlone() {
        var wheel = WheelSettings()
        wheel.smooth = false
        wheel.acceleration = 0
        let h = Harness(rules: [], wheel: wheel)
        #expect(h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 1)) == .passThrough)
        // Held keys with no job assigned and nothing else changed: left alone too.
        #expect(h.send(.scroll, button: .left, modifiers: [.control, .option], wheelLines: CGPoint(x: 0, y: 1)) == .passThrough)
    }

    @Test func clickingStopsASmoothScroll() {
        let h = harness()
        h.send(.scroll, button: .left, wheelLines: CGPoint(x: 0, y: 5))
        h.run(seconds: 0.05)
        h.send(.down, button: .left)
        let count = h.output.scrolls.count
        h.run(seconds: 1)
        #expect(h.output.scrolls.count == count)
    }

    @Test func settingsReachTheEngine() {
        // Regression: the wheel settings were once left out when the saved configuration was applied.
        var config = AppConfig()
        config.wheel.reverseVertical = true
        config.wheel.speed = 2.5
        config.wheel.acceleration = 0.9
        let engine = EngineConfig(config)
        #expect(engine.wheel == config.wheel)
        #expect(engine.scroll == config.scroll)
    }
}

@Suite("Wheel notches")
struct WheelNotchTests {
    @Test func everyClickIsOneNotchWhateverTheSystemReported() {
        // Values recorded from a real mouse during one burst of fast scrolling.
        for reported in [-0.1, -1.712, -8.375, -12.5, -13.922] {
            #expect(WheelNotch.direction(CGFloat(reported)) == -1)
            #expect(WheelNotch.count(reported) == -1)
        }
        for reported in [0.1, 1.295, 3.866, 6.315] {
            #expect(WheelNotch.direction(CGFloat(reported)) == 1)
            #expect(WheelNotch.count(reported) == 1)
        }
        #expect(WheelNotch.direction(0) == 0)
    }
}

@Suite("Left and right buttons")
struct PrimaryButtonTests {
    @Test func doubleClickIsNeverAllowedOnLeftOrRight() {
        for button in [MouseButton.left, .right] {
            #expect(!Trigger(button: button, modifiers: [.command], interaction: .doubleClick).isAllowed)
            #expect(Trigger(button: button, modifiers: [.command], interaction: .click).isAllowed)
        }
        #expect(Trigger(button: MouseButton(number: 3), modifiers: [], interaction: .doubleClick).isAllowed)
    }

    @Test func oldDoubleClickRulesOnLeftAreDroppedWhenLoading() {
        let rule = Rule(trigger: Trigger(button: .left, modifiers: [.option], interaction: .doubleClick), action: .none)
        var config = AppConfig()
        config.rules = [rule]
        #expect(config.sanitized().rules.isEmpty)
    }

    @Test func replayedClicksKeepTheirClickCount() {
        let h = Harness(rules: [rule(.drag, .dragScroll, button: .left, modifiers: [.option])])
        h.send(.down, button: .left, modifiers: [.option], clickState: 2)
        h.send(.up, button: .left, modifiers: [.option], clickState: 2)
        #expect(h.output.clickStates == [2])
    }
}
