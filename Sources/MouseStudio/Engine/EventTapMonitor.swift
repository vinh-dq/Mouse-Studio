import AppKit
import CoreGraphics
import Foundation

/// Runs a CGEventTap on its own thread, so UI work never delays mouse events.
/// The tap is event-driven: the thread sleeps until macOS delivers an event.
final class EventTapMonitor {
    /// Called on the tap thread for every relevant event.
    var handler: ((MouseInput) -> Disposition)?
    /// Called on the tap thread when macOS switched the tap off (it was too slow, or the user intervened).
    var onTapDisabled: (() -> Void)?
    /// Called on the tap thread just before it exits.
    var onTeardown: (() -> Void)?

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    fileprivate var port: CFMachPort?
    private let finished = DispatchSemaphore(value: 0)

    var isRunning: Bool { thread != nil }

    private static let mask: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .flagsChanged,
        ]
        return types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
    }()

    /// Returns false when macOS refuses to create the tap (permission missing).
    func start() -> Bool {
        guard thread == nil else { return true }
        let ready = DispatchSemaphore(value: 0)
        var created = false

        let worker = Thread { [unowned self] in
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.mask,
                callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            self.port = port
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            created = true
            ready.signal()

            CFRunLoopRun()

            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
            self.onTeardown?()
            self.finished.signal()
        }
        worker.name = "MouseStudio.eventTap"
        worker.qualityOfService = .userInteractive
        worker.start()
        ready.wait()

        guard created else { return false }
        thread = worker
        return true
    }

    func stop() {
        guard thread != nil, let loop = runLoop else { return }
        CFRunLoopStop(loop)
        finished.wait()
        thread = nil
        runLoop = nil
        port = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onTapDisabled?()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return passThrough
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventPoster.marker { return passThrough }
        guard var input = MouseInput(type: type, event: event), let handler else { return passThrough }
        // Which mouse this was is only needed when a button goes down or the wheel turns; the rest follows from that.
        if input.kind == .down || (input.kind == .scroll && input.isWheel) {
            input.senderID = DeviceIdentity.senderID(of: event)
        }
        return handler(input) == .consume ? nil : passThrough
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue().receive(type: type, event: event)
}

extension MouseInput {
    init?(type: CGEventType, event: CGEvent) {
        let modifiers = ModifierSet(cgFlags: event.flags)
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        let location = event.location
        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))

        func buttonNumber() -> MouseButton {
            MouseButton(number: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        }
        func movement() -> CGPoint {
            CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        }

        switch type {
        case .leftMouseDown: self.init(kind: .down, button: .left, modifiers: modifiers, location: location, timestamp: timestamp, clickState: clickState)
        case .rightMouseDown: self.init(kind: .down, button: .right, modifiers: modifiers, location: location, timestamp: timestamp, clickState: clickState)
        case .otherMouseDown: self.init(kind: .down, button: buttonNumber(), modifiers: modifiers, location: location, timestamp: timestamp, clickState: clickState)
        case .leftMouseUp: self.init(kind: .up, button: .left, modifiers: modifiers, location: location, timestamp: timestamp, clickState: clickState)
        case .rightMouseUp: self.init(kind: .up, button: .right, modifiers: modifiers, location: location, timestamp: timestamp, clickState: clickState)
        case .otherMouseUp: self.init(kind: .up, button: buttonNumber(), modifiers: modifiers, location: location, timestamp: timestamp, clickState: clickState)
        case .leftMouseDragged: self.init(kind: .dragged, button: .left, modifiers: modifiers, location: location, delta: movement(), timestamp: timestamp)
        case .rightMouseDragged: self.init(kind: .dragged, button: .right, modifiers: modifiers, location: location, delta: movement(), timestamp: timestamp)
        case .otherMouseDragged: self.init(kind: .dragged, button: buttonNumber(), modifiers: modifiers, location: location, delta: movement(), timestamp: timestamp)
        case .scrollWheel:
            let delta = CGPoint(
                x: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                y: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            )
            // Trackpads and Magic Mouse always carry gesture phases; wheels never do, even high-resolution
            // ones that report in pixels.
            let isWheel = event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
                && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
            let isPixelBased = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let lines = isPixelBased
                ? CGPoint(x: delta.x / WheelScroller.pointsPerLine, y: delta.y / WheelScroller.pointsPerLine)
                : CGPoint(
                    x: WheelNotch.count(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)),
                    y: WheelNotch.count(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                )
            // Only wheels need this, and creating an NSEvent for every Trackpad scroll event would slow the whole system.
            let inverted = isWheel ? (NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false) : false
            self.init(kind: .scroll, modifiers: modifiers, location: location, delta: delta, timestamp: timestamp, isWheel: isWheel, lines: lines, isDirectionInverted: inverted)
        case .flagsChanged:
            self.init(kind: .flagsChanged, modifiers: modifiers, location: location, timestamp: timestamp)
        default:
            return nil
        }
    }
}
