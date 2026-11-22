import AppKit
import CoreFoundation
import CoreVideo
import Foundation
import os

/// Fires once per refresh of the display the pointer is on.
private final class DisplayClock {
    private var link: CVDisplayLink?
    private var running = false
    /// Called on the display link's own thread.
    var onTick: (() -> Void)?

    var isAvailable: Bool { link != nil }

    init() {
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess, let created else { return }
        link = created
        CVDisplayLinkSetOutputHandler(created) { [weak self] _, _, _, _, _ in
            self?.onTick?()
            return kCVReturnSuccess
        }
    }

    func start() {
        guard !running, let link else { return }
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(CGEvent(source: nil)?.location ?? .zero, 1, &display, &count) != .success || count == 0 {
            display = CGMainDisplayID()
        }
        CVDisplayLinkSetCurrentCGDisplay(link, display)
        running = CVDisplayLinkStart(link) == kCVReturnSuccess
    }

    func stop() {
        guard running, let link else { return }
        CVDisplayLinkStop(link)
        running = false
    }
}

/// Timers and display-synchronised frames on the event tap's run loop. The processor only schedules from inside
/// event callbacks, so the current run loop is always the tap's own, which keeps all processor state on one thread.
final class RunLoopScheduler: Scheduler {
    private final class TimerTask: ScheduledTask {
        let timer: CFRunLoopTimer
        init(timer: CFRunLoopTimer) { self.timer = timer }
        func cancel() { CFRunLoopTimerInvalidate(timer) }
    }

    private final class FrameTask: ScheduledTask {
        var work: (() -> Void)?
        init(_ work: @escaping () -> Void) { self.work = work }
        func cancel() { work = nil }
    }

    private struct WakeTarget {
        let source: CFRunLoopSource
        let loop: CFRunLoop
    }

    /// Frames waiting for the next refresh. Tap thread only.
    private var frames: [FrameTask] = []
    private var idleStop: ScheduledTask?
    private let display = DisplayClock()
    /// Shared with the display link thread, which only signals the source.
    private let wake = OSAllocatedUnfairLock<WakeTarget?>(initialState: nil)

    init() {
        display.onTick = { [wake] in
            guard let target = wake.withLock({ $0 }) else { return }
            CFRunLoopSourceSignal(target.source)
            CFRunLoopWakeUp(target.loop)
        }
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledTask {
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { _ in work() }!
        // No leeway: by default the system may delay a timer to save power, which shows up as uneven scrolling.
        CFRunLoopTimerSetTolerance(timer, 0)
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        return TimerTask(timer: timer)
    }

    func scheduleFrame(_ work: @escaping () -> Void) -> ScheduledTask {
        guard display.isAvailable, attachToCurrentRunLoop() else { return schedule(after: 1.0 / 120, work) }
        let task = FrameTask(work)
        frames.append(task)
        idleStop?.cancel()
        idleStop = nil
        display.start()
        return task
    }

    /// Makes sure the display link can wake the current (tap) run loop. It changes if the tap thread is rebuilt.
    private func attachToCurrentRunLoop() -> Bool {
        guard let loop = CFRunLoopGetCurrent() else { return false }
        if let target = wake.withLock({ $0 }), target.loop === loop { return true }
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { info in
            guard let info else { return }
            Unmanaged<RunLoopScheduler>.fromOpaque(info).takeUnretainedValue().runFrames()
        }
        guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else { return false }
        CFRunLoopAddSource(loop, source, .commonModes)
        wake.withLock { state in
            if let old = state { CFRunLoopSourceInvalidate(old.source) }
            state = WakeTarget(source: source, loop: loop)
        }
        return true
    }

    private func runFrames() {
        let due = frames
        frames = []
        for task in due { task.work?() }
        guard frames.isEmpty, idleStop == nil else { return }
        // Keep the display link alive briefly: restarting it costs about a frame.
        idleStop = schedule(after: 0.5) { [weak self] in
            guard let self else { return }
            self.idleStop = nil
            if self.frames.isEmpty { self.display.stop() }
        }
    }
}

/// Wires the event tap, the rule engine and the system output together, and exposes the few controls
/// the app needs. Safe to call from the main thread.
final class EngineController {
    var onFailure: ((String) -> Void)? {
        didSet { output.onFailure = onFailure }
    }

    private let configBox = OSAllocatedUnfairLock(initialState: EngineConfig())
    private let capturing = OSAllocatedUnfairLock(initialState: false)
    /// The profile of the mouse that sent the latest button press or wheel turn (nil = shared settings).
    private let activeProfile = OSAllocatedUnfairLock<DeviceProfile?>(initialState: nil)
    /// Mice seen in events this session, newest first, for the device list.
    private let seenDevices = OSAllocatedUnfairLock(initialState: [DeviceInfo]())
    /// Only touched on the tap thread.
    private var lastDeviceKey: String?
    /// Buttons whose press was left alone (excluded device), so their drags and release are left alone too.
    private var bypassedButtons = Set<Int>()
    private let output = SystemEventOutput()
    let trace = EventTrace()
    private let monitor = EventTapMonitor()
    private let processor: MouseEventProcessor
    /// Only touched on the tap thread.
    private var wasCapturing = false

    private var activity: NSObjectProtocol?
    /// Ends the "don't nap" activity a few seconds after the last mouse event.
    private let activityQueue = DispatchQueue(label: "MouseStudio.activity")
    private var activityEnd: DispatchWorkItem?
    private static let activityLinger: TimeInterval = 3

    /// Bundle identifier of the app in front, kept up to date from workspace notifications (cheap to read per event).
    private let frontmost = OSAllocatedUnfairLock<String?>(initialState: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    private var frontmostObserver: NSObjectProtocol?
    /// Only touched on the tap thread: whether the last event was passed through because of an excluded app.
    private var wasExcluded = false

    var isRunning: Bool { monitor.isRunning }

    init(doubleClickInterval: TimeInterval) {
        var timing = MouseEventProcessor.Timing()
        timing.doubleClickInterval = doubleClickInterval
        processor = MouseEventProcessor(output: output, scheduler: RunLoopScheduler(), timing: timing, trace: trace) { [configBox, activeProfile] in
            configBox.withLock { $0 }.applying(device: activeProfile.withLock { $0 })
        }
        output.trace = trace
        monitor.handler = { [unowned self] input in self.process(input) }
        monitor.onTapDisabled = { [unowned self] in
            self.trace.record("macOS switched the event tap off; it is being turned back on")
            self.processor.reset()
        }
        monitor.onTeardown = { [unowned self] in self.processor.reset() }
    }

    func start() -> Bool {
        guard monitor.start() else { return false }
        // A crash while the pointer was frozen (Drag Scroll, Spaces swipe) could leave it frozen; make sure it moves.
        CGAssociateMouseAndMouseCursorPosition(1)
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [frontmost] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            frontmost.withLock { $0 = app?.bundleIdentifier }
        }
        frontmost.withLock { $0 = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        return true
    }

    func stop() {
        monitor.stop()
        if let frontmostObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver) }
        frontmostObserver = nil
        activityQueue.async { [self] in
            activityEnd?.cancel()
            endLowLatencyActivity()
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// While the mouse is in use, macOS must not put the app to sleep ("App Nap") or coalesce its timers.
    /// Mouse events still wake the app, but the 120 Hz frames behind smooth scrolling, Drag Scroll and zoom run
    /// on timers; a napping app gets them late and uneven, which looks like stutter or a zoom that stops responding
    /// after a few quiet seconds.
    /// Held only while the mouse is in use and for `activityLinger` after, so an idle menu-bar app can rest.
    private func noteActivity() {
        activityQueue.async { [self] in
            beginLowLatencyActivity()
            activityEnd?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endLowLatencyActivity() }
            activityEnd = work
            activityQueue.asyncAfter(deadline: .now() + Self.activityLinger, execute: work)
        }
    }

    private func beginLowLatencyActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Handling mouse input"
        )
    }

    private func endLowLatencyActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func update(_ config: AppConfig) {
        let engineConfig = EngineConfig(config)
        configBox.withLock { $0 = engineConfig }
        output.setPrivateFeatures(engineConfig.usePrivateFeatures)
    }

    /// While the user is recording a button press in the app, every event passes through untouched.
    func setCapturing(_ isCapturing: Bool) {
        capturing.withLock { $0 = isCapturing }
    }

    private func process(_ input: MouseInput) -> Disposition {
        if capturing.withLock({ $0 }) {
            if !wasCapturing {
                processor.reset()
                wasCapturing = true
            }
            return .passThrough
        }
        wasCapturing = false

        // An excluded app in front gets the mouse exactly as macOS delivers it.
        if let app = frontmost.withLock({ $0 }), configBox.withLock({ $0.excludedApps.contains(app) }) {
            if !wasExcluded {
                processor.reset()
                wasExcluded = true
                trace.record("excluded app in front (\(app)): mouse left alone")
            }
            return .passThrough
        }
        wasExcluded = false

        // Which mouse is it? Only looked up for presses and wheel turns; drags and releases follow their press.
        if input.kind == .down || (input.kind == .scroll && input.isWheel) {
            let profile = resolveDevice(input.senderID)
            if profile?.isEnabled == false {
                if input.kind == .down { bypassedButtons.insert(input.button.number) }
                return .passThrough
            }
        } else if input.kind == .dragged || input.kind == .up, bypassedButtons.contains(input.button.number) {
            if input.kind == .up { bypassedButtons.remove(input.button.number) }
            return .passThrough
        }

        noteActivity()
        return processor.handle(input)
    }

    /// Mice seen so far this session, newest first.
    func recentDevices() -> [DeviceInfo] {
        seenDevices.withLock { $0 }
    }

    private func resolveDevice(_ senderID: UInt64) -> DeviceProfile? {
        guard senderID != 0, let info = DeviceIdentity.info(forSender: senderID) else {
            activeProfile.withLock { $0 = nil }
            return nil
        }
        if DeviceIdentity.isTrackpad(info) {
            activeProfile.withLock { $0 = nil }
            return nil
        }
        if lastDeviceKey != info.key {
            lastDeviceKey = info.key
            trace.record("device  \(info.name) (\(info.key))")
            seenDevices.withLock { devices in
                devices.removeAll { $0.key == info.key }
                devices.insert(info, at: 0)
            }
        }
        let profile = configBox.withLock { $0.devices[info.key] }
        activeProfile.withLock { $0 = profile }
        return profile
    }
}
