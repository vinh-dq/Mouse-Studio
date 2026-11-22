import CoreGraphics
import Foundation

/// A mouse event reduced to what the rule engine needs.
struct MouseInput {
    enum Kind {
        case down, up, dragged, scroll, flagsChanged
    }

    var kind: Kind
    var button = MouseButton.left
    var modifiers: ModifierSet = []
    var location = CGPoint.zero
    /// Pointer movement for `.dragged`; scroll amount in points for `.scroll`.
    var delta = CGPoint.zero
    var timestamp: TimeInterval = 0
    /// Click count the system assigned (1 single, 2 double, ...), for `.down` / `.up`.
    var clickState = 1
    /// For `.scroll`: true for a classic notched wheel (not a Trackpad, Magic Mouse or inertia event).
    var isWheel = false
    /// For `.scroll`: wheel notches, one per click with the system's acceleration removed.
    var lines = CGPoint.zero
    /// For `.scroll`: true when the system flips the wheel (natural scrolling), so deltas point the other way.
    var isDirectionInverted = false
    /// For `.down` / `.scroll`: registry ID of the device that sent it (0 = unknown or synthetic).
    var senderID: UInt64 = 0
}

enum Disposition {
    case passThrough
    case consume
}

/// `began/changed/ended` follow the fingers; the `momentum*` phases are the glide after they lift.
enum ScrollPhase {
    /// A continuous scroll with no gesture phase: apps scroll by the pixels but never rubber-band at the edges.
    /// Used for the mouse wheel.
    case plain
    case began, changed, ended
    case momentumBegan, momentumChanged, momentumEnded
}

/// Direction of a Trackpad-style swipe that follows the pointer.
enum SwipeAxis: Int {
    case horizontal = 1
    case vertical = 2
}

/// Values match IOHIDEvent phase bits.
enum GesturePhase: Int {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
}

/// Rules and tuning as seen by the event path.
struct EngineConfig {
    var rules = RuleSet()
    var scroll = ScrollSettings()
    var wheel = WheelSettings()
    var swipe = SwipeSettings()
    var usePrivateFeatures = true
    /// Bundle identifiers of apps to leave alone while they are in front.
    var excludedApps: Set<String> = []
    /// Per-device profiles by "vendorID:productID".
    var devices: [String: DeviceProfile] = [:]

    init(rules: RuleSet = RuleSet(), scroll: ScrollSettings = ScrollSettings(), wheel: WheelSettings = WheelSettings(), swipe: SwipeSettings = SwipeSettings()) {
        self.rules = rules
        self.scroll = scroll
        self.wheel = wheel
        self.swipe = swipe
    }

    /// The settings that apply to input from `device` (nil = unknown or no profiles): its own wheel / drag-scroll
    /// settings where it has them, the shared ones otherwise.
    func applying(device: DeviceProfile?) -> EngineConfig {
        guard let device else { return self }
        var copy = self
        if let wheel = device.customWheel { copy.wheel = wheel }
        if let scroll = device.customScroll { copy.scroll = scroll }
        return copy
    }

    /// Everything the event path needs from the saved configuration. Add new settings here.
    init(_ config: AppConfig) {
        self.init(rules: RuleSet(rules: config.rules), scroll: config.scroll, wheel: config.wheel, swipe: config.swipe)
        usePrivateFeatures = config.usePrivateFeatures
        excludedApps = Set(config.excludedApps.map(\.bundleID))
        devices = Dictionary(config.devices.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Everything the processor can make happen in the outside world.
protocol EventOutput: AnyObject {
    func perform(_ action: Action)
    /// False when the system can't simulate a Trackpad swipe; Spaces & Mission Control then use a one-shot action.
    var supportsInteractiveSwipe: Bool { get }
    /// Whether smooth pinch zoom works here; when not, zoom falls back to ⌘+ / ⌘−.
    var supportsPinch: Bool { get }
    /// One step of a swipe that follows the pointer. `progress` runs from 0 and is positive for
    /// "up" (Mission Control) and "right" (previous Space).
    func swipe(_ axis: SwipeAxis, progress: Double, phase: GesturePhase, exitSpeed: Double)
    /// `modifiers` are the keys the receiving app sees as held.
    func scroll(x: Int32, y: Int32, phase: ScrollPhase, modifiers: ModifierSet)
    func setCursorFrozen(_ frozen: Bool)
    /// Re-sends a click the processor held back, so buttons without a matching gesture still behave normally.
    func replayClick(button: MouseButton, modifiers: ModifierSet, clickState: Int, at location: CGPoint)
    /// One step of a pinch. `amount` > 0 zooms in.
    func magnify(_ amount: Double, phase: GesturePhase)
    /// True when the app that will receive the pinch ignores the first part of a gesture (Chromium).
    var pinchNeedsPrimer: Bool { get }
}

protocol ScheduledTask {
    func cancel()
}

protocol Scheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledTask
    /// Runs `work` once on the next display refresh. Anything that posts scrolling should use this, so exactly
    /// one step reaches each screen frame instead of drifting against it.
    func scheduleFrame(_ work: @escaping () -> Void) -> ScheduledTask
}

extension Scheduler {
    /// Without a display (tests), frames come from a plain timer.
    func scheduleFrame(_ work: @escaping () -> Void) -> ScheduledTask {
        schedule(after: 1.0 / 120, work)
    }
}

extension EventOutput {
    func scroll(x: Int32, y: Int32, phase: ScrollPhase) {
        scroll(x: x, y: y, phase: phase, modifiers: [])
    }
}
