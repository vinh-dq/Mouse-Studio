import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Lists the open windows. Titles come from Accessibility (which Mouse Studio already has); the window server adds
/// the front-to-back order, and windows on other desktops when Screen Recording is allowed.
enum WindowCatalog {
    /// Most recently used apps first. Windows of the same app keep the window server's order.
    static func snapshot(appOrder: [pid_t], includeOtherSpaces: Bool) -> [WindowItem] {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }
        let stacking = stackingOrder()

        let lock = NSLock()
        var found: [WindowItem] = []
        // Apps are asked at the same time, so one that is not answering delays the list by at most the timeout.
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let items = windows(of: apps[index])
            lock.withLock { found += items }
        }

        if includeOtherSpaces {
            let known = Set(found.compactMap(\.windowID))
            let byPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
            found += otherSpaceWindows(excluding: known, apps: byPID)
        }

        let rank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ item: WindowItem) -> (Int, Int, String) {
            let z = item.windowID.flatMap { stacking[$0] } ?? Int.max
            return (z, rank[item.pid] ?? Int.max, item.title)
        }
        var sorted = found.sorted { key($0) < key($1) }
        let places = WindowSpaces.labels(for: sorted.compactMap(\.windowID))
        for index in sorted.indices {
            if let id = sorted[index].windowID { sorted[index].place = places[id] }
        }
        return sorted
    }

    /// Window number → position from the front, for windows that are on screen now.
    private static func stackingOrder() -> [CGWindowID: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var order: [CGWindowID: Int] = [:]
        for (position, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            order[number] = position
        }
        return order
    }

    private static func windows(of app: NSRunningApplication) -> [WindowItem] {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
        var result: [WindowItem] = []
        for (index, element) in elements.enumerated() {
            let subrole: String? = attribute(element, kAXSubroleAttribute)
            guard subrole == nil || subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { continue }
            let title: String = attribute(element, kAXTitleAttribute) ?? ""
            if title.isEmpty, subrole == nil { continue }
            var windowID: CGWindowID = 0
            let hasID = _AXUIElementGetWindow(element, &windowID) == .success && windowID != 0
            let minimized: Bool = attribute(element, kAXMinimizedAttribute) ?? false
            result.append(WindowItem(
                id: hasID ? "w\(windowID)" : "p\(pid)-\(index)",
                pid: pid,
                windowID: hasID ? windowID : nil,
                appName: name,
                bundleID: app.bundleIdentifier,
                title: title.isEmpty ? name : title,
                isMinimized: minimized,
                isOnOtherSpace: false,
                isAppHidden: app.isHidden,
                element: element,
                size: size(of: element),
                icon: app.icon
            ))
        }
        return result
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        attribute(element, kAXMinimizedAttribute) ?? false
    }

    /// Where a window is on screen, in the same coordinates the window server uses.
    static func frame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        var origin = CGPoint.zero
        guard let size = size(of: element),
              AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgPoint, &origin) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Windows that are not on this desktop. The window server only gives their titles to apps that may record the screen.
    private static func otherSpaceWindows(excluding known: Set<CGWindowID>, apps: [pid_t: NSRunningApplication]) -> [WindowItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [WindowItem] = []
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID, !known.contains(number),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool) != true,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, let app = apps[pid],
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 120, (bounds["Height"] ?? 0) >= 80 else { continue }
            result.append(WindowItem(
                id: "w\(number)",
                pid: pid,
                windowID: number,
                appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                bundleID: app.bundleIdentifier,
                title: title,
                isMinimized: false,
                isOnOtherSpace: true,
                isAppHidden: app.isHidden,
                element: nil,
                size: CGSize(width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0),
                icon: app.icon
            ))
        }
        return result
    }

    private static func attribute<Value>(_ element: AXUIElement, _ name: String) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }
}

/// What can be done to a window once it is chosen.
enum WindowActions {
    static func focus(_ item: WindowItem) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = NSRunningApplication(processIdentifier: item.pid)
            if app?.isHidden == true { app?.unhide() }
            if let element = item.element, item.isMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            // Asking the window server for this very window also switches to its desktop. Activating the app alone
            // would bring up whichever of its windows was used last, and stay on this desktop.
            var switched = false
            if let windowID = item.windowID, item.element != nil {
                var psn = ProcessSerialNumber()
                if GetProcessForPID(item.pid, &psn) == 0 {
                    switched = SkyLight.setFront?(&psn, windowID, 0x200) == .success
                    if switched { makeKey(&psn, windowID) }
                }
            }
            if !switched, item.windowID != nil { FinderLog.shared.note("window-server focus unavailable; using app activation") }
            if !switched && item.element != nil {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(item.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                app?.activate()
            }
            // A window on another desktop is not in the app's window list until that desktop shows; its element has to
            // be found by asking for the app's elements one by one. Raising it is what switches to its desktop.
            var element = item.element
            if element == nil, let windowID = item.windowID {
                let started = Date()
                element = axWindow(pid: item.pid, windowID: windowID) ?? hiddenWindow(pid: item.pid, windowID: windowID)
                FinderLog.shared.note(String(format: "other-desktop window: element %@ after %.0f ms", element == nil ? "NOT found" : "found", Date().timeIntervalSince(started) * 1000))
            }
            if let element {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                if let windowID = item.windowID {
                    var psn = ProcessSerialNumber()
                    if GetProcessForPID(item.pid, &psn) == 0 {
                        _ = SkyLight.setFront?(&psn, windowID, 0x200)
                        makeKey(&psn, windowID)
                    }
                }
            } else if !switched {
                app?.activate()
            }
        }
    }

    /// Looks for a window's Accessibility element by trying element numbers 0…1999 of the app.
    /// Gives up after a second and a half, so an app that is not answering can't keep this busy.
    private static func hiddenWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(1.5)
        for number in 0..<2000 {
            if number % 25 == 0, Date() > deadline { return nil }
            var token = Data(count: 20)
            token.withUnsafeMutableBytes { raw in
                var pid32 = pid
                var zero: Int32 = 0
                var marker: Int32 = 0x636f_636f
                var index = UInt64(number)
                memcpy(raw.baseAddress!, &pid32, 4)
                memcpy(raw.baseAddress! + 4, &zero, 4)
                memcpy(raw.baseAddress! + 8, &marker, 4)
                memcpy(raw.baseAddress! + 12, &index, 8)
            }
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                  subrole as? String == kAXStandardWindowSubrole as String else { continue }
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success, id == windowID { return element }
        }
        return nil
    }

    private static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == windowID
        }
    }

    /// Tells the window server that this window is the one that takes the keyboard.
    private static func makeKey(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        var id = windowID
        memcpy(&bytes[0x3C], &id, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xFF, 0x10)
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            _ = SkyLight.postEvent?(&psn, &bytes)
        }
    }

    static func close(_ item: WindowItem) {
        guard let element = item.element else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    static func minimize(_ item: WindowItem) {
        guard let element = item.element else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    static func quit(_ item: WindowItem) {
        NSRunningApplication(processIdentifier: item.pid)?.terminate()
    }

    static func hide(_ item: WindowItem) {
        NSRunningApplication(processIdentifier: item.pid)?.hide()
    }
}
