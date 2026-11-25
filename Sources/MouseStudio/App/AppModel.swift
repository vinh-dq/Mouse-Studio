import AppKit
import Combine

/// The app-level state the UI reads: configuration, permission, and whether the mouse monitor is running.
@MainActor
final class AppModel: ObservableObject {
    /// A demo copy (screenshots) keeps its settings in a throw-away folder and leaves the real ones alone.
    static let shared = AppModel(store: FinderDemo.isActive ? ConfigStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MouseStudioDemo")) : nil)

    enum Status: Equatable {
        case off
        case needsPermission
        case running
        case failed
    }

    let store: ConfigStore
    let permissions = PermissionManager()
    @Published private(set) var status = Status.off
    /// A message for the user about something that went wrong. Cleared by the user.
    @Published var issue: String?

    private let engine = EngineController(doubleClickInterval: NSEvent.doubleClickInterval)
    private var cancellables = Set<AnyCancellable>()
    private var lastEnabled: Bool

    private static let promptedKey = "didPromptForAccessibility"

    init(store: ConfigStore? = nil) {
        let store = store ?? ConfigStore()
        self.store = store
        lastEnabled = store.config.isEnabled
        issue = store.loadIssue
        engine.update(store.config)
        WindowFinder.shared.start()
        WindowFinder.shared.apply(store.config.windowFinder)

        engine.onFailure = { [weak self] message in
            Task { @MainActor in self?.issue = message }
        }
        store.onSaveError = { [weak self] message in
            self?.issue = String(localized: "Couldn't save your settings (\(message)). The previous settings file is untouched.")
        }

        // Views read the configuration through `store`, a separate object, so its changes must be
        // forwarded or they only show up when a view happens to be rebuilt (for example on tab switch).
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        store.$config
            .dropFirst()
            .sink { [weak self] config in self?.configChanged(config) }
            .store(in: &cancellables)

        // A demo copy (screenshots) never touches the mouse or the permission prompts.
        guard !FinderDemo.isActive else { return }
        observeSystemEvents()
        reconcile()
        promptForPermissionOnFirstLaunch()
    }

    var statusTitle: String {
        switch status {
        case .off: String(localized: "Paused")
        case .needsPermission: String(localized: "Needs permission")
        case .running: String(localized: "Active")
        case .failed: String(localized: "Not running")
        }
    }

    func setEnabled(_ enabled: Bool) {
        store.update { $0.isEnabled = enabled }
    }

    func setCapturing(_ isCapturing: Bool) {
        engine.setCapturing(isCapturing)
    }

    /// Brings the monitor in line with the settings and the permission, starting or stopping as needed.
    /// `enabled` is passed in when the caller already knows the new value: `store.$config` announces a change before
    /// `store.config` holds it, so reading the store at that moment gives the previous setting (the switch and the
    /// status then disagreed by one toggle).
    func reconcile(enabled: Bool? = nil) {
        defer { WindowFinder.shared.setEventFallback(!engine.isRunning) }
        permissions.refresh()
        guard enabled ?? store.config.isEnabled else {
            engine.stop()
            status = .off
            return
        }
        guard permissions.isAccessibilityGranted else {
            engine.stop()
            status = .needsPermission
            return
        }
        status = engine.isRunning || engine.start() ? .running : .failed
    }

    /// Switching a script rule on needs an explicit yes, because scripts can do anything.
    func setRule(_ rule: Rule, enabled: Bool) {
        if enabled, case .runScript(let command) = rule.action, !Self.confirmScript(command) { return }
        store.setEnabled(enabled, forRule: rule.id)
    }

    /// Facts for diagnosing a problem: versions, status, settings, rules and the most recent mouse events.
    func diagnosticsReport() -> String {
        let config = store.config
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
        let rules = config.rules.map { rule in
            let keys = rule.trigger.modifiers.isEmpty ? "-" : rule.trigger.modifiers.symbols
            return "  button\(rule.trigger.button.number + 1) keys=\(keys) \(rule.trigger.interaction.rawValue) -> \(rule.action.title)\(rule.isEnabled ? "" : " (off)")"
        }.joined(separator: "\n")
        return """
        Mouse Studio \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Status: \(statusTitle); display refresh: \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz
        Wheel: \(config.wheel)
        Drag scroll: \(config.scroll)
        Spaces & Mission Control: \(config.swipe)
        Rules:
        \(rules)

        Recent events (seconds since launch):
        \(engine.trace.dump())

        Window finder:
        \(FinderLog.shared.dump())
        """
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport(), forType: .string)
    }

    // MARK: - Excluded apps

    func addExcludedApp(bundleID: String, name: String) {
        guard !bundleID.isEmpty, !store.config.excludedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        store.update { $0.excludedApps.append(ExcludedApp(bundleID: bundleID, name: name)) }
    }

    func removeExcludedApp(_ bundleID: String) {
        store.update { $0.excludedApps.removeAll { $0.bundleID == bundleID } }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return store.config.excludedApps.contains { $0.bundleID == bundleID }
    }

    // MARK: - Devices

    /// Connected mice, mice seen in recent events and mice that already have a profile, newest activity first.
    func knownDevices() -> [DeviceInfo] {
        var result = engine.recentDevices()
        for device in DeviceIdentity.connectedPointingDevices() where !result.contains(where: { $0.key == device.key }) {
            result.append(device)
        }
        for profile in store.config.devices where !result.contains(where: { $0.key == profile.key }) {
            result.append(DeviceInfo(key: profile.key, name: profile.name))
        }
        return result
    }

    func profile(for device: DeviceInfo) -> DeviceProfile? {
        store.config.devices.first { $0.key == device.key }
    }

    /// Changes a device's profile, creating it on first use. A profile that is back to "everything shared" is removed.
    func updateProfile(for device: DeviceInfo, _ change: (inout DeviceProfile) -> Void) {
        var profile = self.profile(for: device) ?? DeviceProfile(key: device.key, name: device.name)
        change(&profile)
        store.update { config in
            config.devices.removeAll { $0.key == device.key }
            if !profile.isEnabled || profile.customWheel != nil || profile.customScroll != nil {
                config.devices.append(profile)
            }
        }
    }

    func shutdown() {
        engine.stop()
        store.flush()
    }

    // MARK: - Private

    private func configChanged(_ config: AppConfig) {
        engine.update(config)
        WindowFinder.shared.apply(config.windowFinder)
        if config.isEnabled != lastEnabled {
            lastEnabled = config.isEnabled
            reconcile(enabled: config.isEnabled)
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.engine.setCapturing(false) }
            .store(in: &cancellables)
        // After sleep the event tap can be silently dead, so it is rebuilt from scratch.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.engine.stop()
                self?.reconcile()
            }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))
            .delay(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
    }

    private func promptForPermissionOnFirstLaunch() {
        guard status == .needsPermission, !UserDefaults.standard.bool(forKey: Self.promptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
        permissions.request()
    }

    private static func confirmScript(_ command: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Turn on this script rule?")
        alert.informativeText = String(localized: "Mouse Studio will run this command whenever the rule fires:\n\n\(command)")
        alert.addButton(withTitle: String(localized: "Turn On"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
