import AppKit
import os

/// Chromium-based apps (Chrome, Edge, Brave, Arc, Electron apps…) ignore a pinch until the gesture has built up
/// about 0.4 of total magnification, then apply the rest. A Trackpad pinch passes that at once; a mouse wheel's
/// small steps never do, so zoom seemed to work only when scrolling very fast. See `PinchZoom`.
enum ChromiumApps {
    private static let cache = OSAllocatedUnfairLock(initialState: [URL: Bool]())

    struct Target {
        let name: String
        let isChromium: Bool
    }

    /// The app a pinch will reach: the one owning the window under the pointer. nil when that can't be told, and then
    /// the pinch is sent like for any other app (no primer): guessing wrong would hand a primer to a normal app, which
    /// applies it (+49% on the picture), while skipping it only costs Chromium its first steps.
    static var pinchTarget: Target? {
        let now = ProcessInfo.processInfo.systemUptime
        let pointer = CGEvent(source: nil)?.location ?? .zero
        // Looking up the windows costs a few milliseconds; a flick opens a pinch many times a second.
        if let recent = lastLookup.withLock({ $0 }), now - recent.time < 0.25, hypot(recent.pointer.x - pointer.x, recent.pointer.y - pointer.y) < 24 {
            return recent.target
        }
        let target = lookUpPinchTarget()
        lastLookup.withLock { $0 = (now, pointer, target) }
        return target
    }

    private static let lastLookup = OSAllocatedUnfairLock<(time: TimeInterval, pointer: CGPoint, target: Target?)?>(initialState: nil)

    private static func lookUpPinchTarget() -> Target? {
        guard let app = appUnderPointer(), let url = app.bundleURL else { return nil }
        let chromium: Bool
        if let known = cache.withLock({ $0[url] }) {
            chromium = known
        } else {
            chromium = isChromiumBased(url)
            cache.withLock { $0[url] = chromium }
        }
        return Target(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, isChromium: chromium)
    }

    static var targetNeedsPinchPrimer: Bool { pinchTarget?.isChromium ?? false }

    /// System surfaces that can sit in front of an app's window without being what a pinch is meant for
    /// (Stage Manager's strip, the Dock, menu extras, the lock screen).
    private static let systemSurfaces: Set<String> = [
        "com.apple.WindowManager", "com.apple.dock", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.systemuiserver", "com.apple.loginwindow",
    ]

    /// The topmost window containing the pointer, front to back, floating panels included: a floating image
    /// (PasteClip and the like) lives in a panel above normal windows and belongs to a menu-bar app, and skipping it
    /// meant the Chromium window behind it was taken for the target, so the picture got Chrome's primer (+49%).
    /// Uses only CoreGraphics, so it is safe on the event thread.
    private static func appUnderPointer() -> NSRunningApplication? {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            // Layers 0–19 are app windows, floating panels and modal panels; the Dock, menu bar and above are not.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.contains(pointer),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited,
                  !systemSurfaces.contains(app.bundleIdentifier ?? "") else { continue }
            return app
        }
        return nil
    }

    /// Chromium apps carry a "… Helper (Renderer).app" next to, or inside, their framework.
    static func isChromiumBased(_ appURL: URL) -> Bool {
        let manager = FileManager.default
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks")
        guard let entries = try? manager.contentsOfDirectory(atPath: frameworks.path) else { return false }
        if entries.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) { return true }
        for entry in entries where entry.hasSuffix(".framework") {
            let helpers = frameworks.appendingPathComponent(entry).appendingPathComponent("Helpers")
            if let inner = try? manager.contentsOfDirectory(atPath: helpers.path), inner.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) {
                return true
            }
        }
        return false
    }
}
