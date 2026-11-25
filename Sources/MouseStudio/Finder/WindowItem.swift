import AppKit
import ApplicationServices

/// One window in the list. The Accessibility element is how it is raised, closed or minimized.
struct WindowItem: Identifiable, WindowSearchable, @unchecked Sendable {
    let id: String
    let pid: pid_t
    let windowID: CGWindowID?
    let appName: String
    let bundleID: String?
    let title: String
    var isMinimized: Bool
    /// On another desktop (Space). Found only with Screen Recording access, and brought up by activating its app.
    let isOnOtherSpace: Bool
    let isAppHidden: Bool
    let element: AXUIElement?
    /// The window's real size, to tell a true picture from a scaled or tilted one (Stage Manager's side strip).
    let size: CGSize?
    let icon: NSImage?
}
