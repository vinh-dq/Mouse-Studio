import CoreGraphics
import Darwin
import Foundation
import os

/// Posts the "dock swipe" gesture a Trackpad produces for three-finger swipes, so Spaces and Mission
/// Control follow the pointer while the user drags, and settle when they let go.
///
/// macOS has no public API for this. On macOS 27 the gesture travels as an `IOHIDEvent` wrapped in a
/// CGEvent of type 30, and the only way to attach one is to store its pointer inside the CGEvent record.
/// That is fragile, so everything private lives in this file and is guarded:
/// - it only activates on macOS 27 and when every system symbol resolves;
/// - before writing, the target block is checked with `malloc_size`;
/// - after writing, the event is read back; any mismatch switches the feature off for good.
///
/// When unavailable (`isAvailable == false`) the caller falls back to a plain one-shot action.
final class DockSwipeSimulator {
    static let shared = DockSwipeSimulator()

    private struct Api {
        typealias Create = @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> UnsafeMutableRawPointer?
        typealias SetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32, Int) -> Void
        typealias SetDouble = @convention(c) (UnsafeMutableRawPointer, UInt32, Double) -> Void
        typealias Append = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void
        typealias CopyHIDEvent = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

        let create: Create
        let setInteger: SetInteger
        let setDouble: SetDouble
        let append: Append
        let copyHIDEvent: CopyHIDEvent

        init?() {
            guard #available(macOS 27, *),
                  let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
                  let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
                  let create = dlsym(iokit, "IOHIDEventCreate"),
                  let setInteger = dlsym(iokit, "IOHIDEventSetIntegerValue"),
                  let setDouble = dlsym(iokit, "IOHIDEventSetDoubleValue"),
                  let append = dlsym(iokit, "IOHIDEventAppendEvent"),
                  let copy = dlsym(coreGraphics, "CGEventCopyIOHIDEvent") else { return nil }
            self.create = unsafeBitCast(create, to: Create.self)
            self.setInteger = unsafeBitCast(setInteger, to: SetInteger.self)
            self.setDouble = unsafeBitCast(setDouble, to: SetDouble.self)
            self.append = unsafeBitCast(append, to: Append.self)
            self.copyHIDEvent = unsafeBitCast(copy, to: CopyHIDEvent.self)
        }
    }

    // IOHIDEvent constants (IOHIDEventTypes.h / IOHIDEventFieldDefs.h)
    private static let dockSwipeType: UInt32 = 23
    private static let velocityType: UInt32 = 9
    private static let dockPrimaryFlavor = 3
    private static let phaseShift: UInt32 = 24
    // Offsets of the HID event pointer inside a CGEvent record.
    private static let recordOffset = 0x18
    private static let hidEventOffset = 0xD0

    private let api = Api()
    private let isBroken = OSAllocatedUnfairLock(initialState: false)
    /// Bumped whenever a gesture begins, so late repeats of an old "end" can't cut a new gesture short.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    var isAvailable: Bool {
        api != nil && !isBroken.withLock { $0 }
    }

    func post(axis: SwipeAxis, progress: Double, phase: GesturePhase, exitSpeed: Double) {
        guard let api, isAvailable else { return }
        if phase == .began { generation.withLock { $0 += 1 } }
        guard let event = makeEvent(api, axis: axis, progress: progress, phase: phase, exitSpeed: exitSpeed) else {
            isBroken.withLock { $0 = true }
            return
        }
        event.post(tap: .cgSessionEventTap)

        // The system sometimes ignores an end event while it is busy, which leaves the animation stuck
        // half-way. Repeating it shortly after is harmless and reliably unsticks it.
        guard phase == .ended || phase == .cancelled else { return }
        let current = generation.withLock { $0 }
        for delay in [0.2, 0.5] {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [generation] in
                if generation.withLock({ $0 }) == current { event.post(tap: .cgSessionEventTap) }
            }
        }
    }

    private func makeEvent(_ api: Api, axis: SwipeAxis, progress: Double, phase: GesturePhase, exitSpeed: Double) -> CGEvent? {
        func base(_ type: UInt32) -> UInt32 { type << 16 }

        guard let hid = api.create(kCFAllocatorDefault, Self.dockSwipeType, 0, UInt32(phase.rawValue) << Self.phaseShift) else { return nil }
        let hidOwner = Unmanaged<AnyObject>.fromOpaque(hid)
        defer { hidOwner.release() }

        api.setInteger(hid, base(Self.dockSwipeType) | 1, axis.rawValue)
        api.setInteger(hid, base(Self.dockSwipeType) | 5, Self.dockPrimaryFlavor)
        api.setDouble(hid, base(Self.dockSwipeType) | 2, progress)

        if phase == .ended || phase == .cancelled, let velocity = api.create(kCFAllocatorDefault, Self.velocityType, 0, 0) {
            api.setDouble(velocity, base(Self.velocityType) | 0, exitSpeed)
            api.setDouble(velocity, base(Self.velocityType) | 1, exitSpeed)
            api.setDouble(velocity, base(Self.velocityType) | 2, 0)
            api.append(hid, velocity, 0)
            Unmanaged<AnyObject>.fromOpaque(velocity).release()
        }

        guard let event = CGEvent(source: nil) else { return nil }
        event.type = CGEventType(rawValue: 30) ?? event.type
        let raw = Unmanaged.passUnretained(event).toOpaque()
        guard let record = raw.advanced(by: Self.recordOffset).load(as: UnsafeMutableRawPointer?.self),
              malloc_size(record) >= Self.hidEventOffset + MemoryLayout<UnsafeMutableRawPointer>.size else { return nil }

        // The CGEvent keeps its own reference to the HID event.
        hidOwner.retain()
        record.advanced(by: Self.hidEventOffset).storeBytes(of: hid, as: UnsafeMutableRawPointer.self)

        guard let stored = api.copyHIDEvent(raw) else { return nil }
        Unmanaged<AnyObject>.fromOpaque(stored).release()
        return stored == hid ? event : nil
    }
}
