import AppKit
import ApplicationServices

/// Accessibility is the permission macOS requires to watch and replace mouse events.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted = AXIsProcessTrusted()

    func refresh() {
        let granted = AXIsProcessTrusted()
        if granted != isAccessibilityGranted { isAccessibilityGranted = granted }
    }

    /// Shows the system prompt that leads the user to Privacy & Security.
    func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        isAccessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
