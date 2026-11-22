import CoreGraphics
import Foundation
import IOKit
import os

/// Which mouse an event came from. macOS stamps every hardware event with the registry ID of the HID service that
/// sent it; that ID is looked up in the IORegistry to get the vendor, product and name. Needs no extra permission.
/// `CGEventCopyIOHIDEvent` is not documented, so everything here fails safe: no ID means "unknown device", and
/// Mouse Studio then uses the shared settings.
struct DeviceInfo: Equatable, Sendable, Identifiable {
    /// "vendorID:productID"
    let key: String
    let name: String
    var id: String { key }
}

enum DeviceIdentity {
    private typealias CopyHIDEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias SenderID = @convention(c) (CFTypeRef) -> UInt64

    private static let api: (copy: CopyHIDEvent, sender: SenderID)? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let copy = dlsym(coreGraphics, "CGEventCopyIOHIDEvent"),
              let sender = dlsym(iokit, "IOHIDEventGetSenderID") else { return nil }
        return (unsafeBitCast(copy, to: CopyHIDEvent.self), unsafeBitCast(sender, to: SenderID.self))
    }()

    /// The sending service of a hardware event; 0 for synthetic events (ours, or another app's) and when unknown.
    static func senderID(of event: CGEvent) -> UInt64 {
        guard let api, let hid = api.copy(event)?.takeRetainedValue() else { return 0 }
        return api.sender(hid)
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [UInt64: DeviceInfo?]())

    /// Cached per sender, so the registry is only read the first time a device is seen.
    static func info(forSender id: UInt64) -> DeviceInfo? {
        if let known = cache.withLock({ $0[id] }) { return known }
        let info = lookUp(id)
        cache.withLock { $0[id] = info }
        return info
    }

    private static func lookUp(_ id: UInt64) -> DeviceInfo? {
        guard let matching = IORegistryEntryIDMatching(id) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        // The sending service often carries the identity itself; if not, a parent does.
        for _ in 0..<6 {
            if let info = identity(of: entry) { return info }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }

    private static func identity(of entry: io_registry_entry_t) -> DeviceInfo? {
        func property(_ name: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        return info(vendor: property("VendorID") as? Int, product: property("ProductID") as? Int, name: property("Product") as? String)
    }

    /// "vendor:product" when the device reports them, otherwise its name; nil when it says neither.
    private static func info(vendor: Int?, product: Int?, name: String?) -> DeviceInfo? {
        if let vendor, let product {
            return DeviceInfo(key: "\(vendor):\(product)", name: name ?? "Mouse \(vendor):\(product)")
        }
        if let name { return DeviceInfo(key: "name:\(name)", name: name) }
        return nil
    }

    /// Trackpads keep their own behaviour and are never changed, so they are not offered as mice.
    static func isTrackpad(_ info: DeviceInfo) -> Bool {
        info.name.localizedCaseInsensitiveContains("trackpad")
    }

    /// Pointing devices that are connected now (mice and trackpads), for the device list.
    static func connectedPointingDevices() -> [DeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [DeviceInfo] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // Generic Desktop page (1), usage Mouse (2) or Pointer (1).
            guard (property("PrimaryUsagePage") as? Int) == 1, [1, 2].contains(property("PrimaryUsage") as? Int ?? 0),
                  let info = info(vendor: property("VendorID") as? Int, product: property("ProductID") as? Int, name: property("Product") as? String),
                  !isTrackpad(info) else { continue }
            if !found.contains(info) { found.append(info) }
        }
        return found.sorted { $0.name < $1.name }
    }
}
