import SwiftUI

@main
struct MouseStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Mouse Studio", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 580, height: 620)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            switch model.status {
            case .running: Image(nsImage: MenuBarIcon.active)
            case .off: Image(nsImage: MenuBarIcon.paused)
            case .needsPermission, .failed: Image(nsImage: MenuBarIcon.attention)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon. The window is opened from the menu bar icon.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        shrinkWindowOnce()
    }

    /// macOS restores the size a window had last time, so a smaller default never reaches people who already had
    /// the app. Once per size, the window is set to the new default; after that their own size is respected.
    private func shrinkWindowOnce() {
        let key = "windowSizeApplied.580x620"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = NSApp.windows.first(where: { $0.title == "Mouse Studio" && $0.isVisible }) else { return }
            window.setContentSize(NSSize(width: 580, height: 620))
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// Mouse Studio keeps working from the menu bar after its window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The app in front, other than Mouse Studio itself; the menu doesn't take focus from it.
    private var frontApp: NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
    }

    var body: some View {
        Toggle("Enable Mouse Studio", isOn: Binding(
            get: { model.store.config.isEnabled },
            set: { model.setEnabled($0) }
        ))
        Text(model.statusTitle)
        Divider()
        Toggle("Reverse Scroll Direction", isOn: model.store.binding(\.wheel.reverseVertical))
        Toggle("Smooth Scrolling", isOn: model.store.binding(\.wheel.smooth))
        if let app = frontApp, let id = app.bundleIdentifier {
            Toggle("Leave \(app.localizedName ?? id) Alone", isOn: Binding(
                get: { model.isExcluded(id) },
                set: { excluded in
                    if excluded { model.addExcludedApp(bundleID: id, name: app.localizedName ?? id) } else { model.removeExcludedApp(id) }
                }
            ))
        }
        Divider()
        Button("Open Mouse Studio…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Copy Recent Mouse Events") { model.copyDiagnostics() }
        Divider()
        Button("Quit Mouse Studio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
