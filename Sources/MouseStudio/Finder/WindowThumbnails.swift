import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Pictures of windows, taken only while the list is open. Needs the Screen Recording permission.
@MainActor
final class WindowThumbnailer {
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private var windows: [CGWindowID: SCWindow] = [:]

    /// Learns which windows can be captured. Call once when the list opens.
    func prepare() async {
        guard Self.hasAccess,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// A picture of the window no wider than `width` points (twice that many pixels), or nil when it can't be captured.
    func image(of windowID: CGWindowID, width: CGFloat) async -> NSImage? {
        guard let window = windows[windowID], window.frame.width > 1, window.frame.height > 1 else { return nil }
        let scale = min(1, width * 2 / window.frame.width)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
