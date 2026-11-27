import AppKit
import Combine
import SwiftUI

/// The glass panel. It takes keystrokes without making Mouse Studio the active app, so the window you are on
/// stays as it is until you choose another.
final class FinderPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above the menu bar and Mission Control, which draws over ordinary floating windows.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Find Windows: hold a key (or press a mouse button set to "Find Window"), type part of a title, let go to switch.
@MainActor
final class WindowFinder {
    static let shared = WindowFinder()

    let model = FinderModel()
    private(set) var isShown = false

    private var settings = WindowFinderSettings()
    private var panel: FinderPanel?
    private var pendingShow: DispatchWorkItem?
    private var isHolding = false
    private var openedByHold = false
    /// Changes whenever the list opens or closes, so late results of an earlier opening are dropped.
    private var session = 0
    private var panelTop: CGFloat = 0
    /// Most recently used apps first, from the workspace's activation notices.
    private var appOrder: [pid_t] = []
    private var keyMonitor: Any?
    /// Used only while the mouse engine is stopped, so the hold key still works when Mouse Studio is paused.
    private var fallbackMonitors: [Any] = []
    private var pressedAt = Date.distantPast
    /// The last list of windows, shown at once on the next opening and then refreshed.
    private var cache: (items: [WindowItem], date: Date)?
    private let history = FinderHistoryStore()
    /// What was picked among tabs; kept apart, so a site you often pick doesn't push windows around.
    private let tabHistory = FinderHistoryStore(fileName: "finder-tab-history.json")
    /// The last tabs read from the browsers, shown at once on the next opening and then refreshed.
    private var tabCache: (snapshot: TabSnapshot, date: Date)?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let thumbnailer = WindowThumbnailer()
    private var prepareTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    private init() {}

    /// Wires the key trigger and starts following which app was used last. Call once at launch.
    func start() {
        let trigger = FinderTrigger.shared
        trigger.onPressed = { [unowned self] in keyPressed() }
        trigger.onReleased = { [unowned self] in keyReleased() }
        trigger.onDisturbed = { [unowned self] in keyDisturbed() }

        let workspace = NSWorkspace.shared
        appOrder = workspace.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        if let front = workspace.frontmostApplication?.processIdentifier { noteActivated(front) }
        workspace.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.noteActivated(app.processIdentifier)
            }
            .store(in: &cancellables)
        FinderHotKey.shared.onPressed = { [unowned self] kind in
            guard AXIsProcessTrusted() else { return }
            switch kind {
            case .windows: windowsShortcutPressed()
            case .tabs: tabsShortcutPressed()
            }
        }
        model.onCommit = { [unowned self] index in commit(index: index) }
        model.onSetMode = { [unowned self] mode in mode == .tabs ? showTabs() : showWindows() }
        model.boosterFor = { [unowned self] query in
            guard settings.rememberChoices else { return { _ in 0 } }
            let windows = history.booster(query: query)
            let tabs = tabHistory.booster(query: query)
            return { item in item.tab != nil ? tabs(item) : windows(item) }
        }
        // Build the panel now, so the first opening isn't the slow one.
        DispatchQueue.main.async { [unowned self] in if panel == nil { panel = makePanel() } }
        let missing = SkyLight.missing
        if !missing.isEmpty { FinderLog.shared.note("missing window-server calls: \(missing.joined(separator: ", "))") }
        // `@Published` announces a change just before it is stored; waiting a turn of the run loop reads the new value.
        model.$contentHeight
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizePanel() }
            .store(in: &cancellables)
        model.$selection
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectionChanged() }
            .store(in: &cancellables)
        model.$mode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizePanel() }
            .store(in: &cancellables)
        model.$isPreviewing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectionChanged() }
            .store(in: &cancellables)
    }

    func apply(_ settings: WindowFinderSettings) {
        self.settings = settings
        FinderTrigger.shared.configure(isEnabled: settings.isEnabled, key: settings.key)
        FinderHotKey.shared.register(settings.isEnabled ? settings.shortcut : nil, for: .windows)
        FinderHotKey.shared.register(settings.isEnabled && settings.tabsEnabled ? settings.tabShortcut : nil, for: .tabs)
        if !settings.isEnabled { cancelPending() }
    }

    func forgetHistory() {
        history.forget()
        tabHistory.forget()
    }

    /// Opens the list and keeps it open until a window is chosen or it is cancelled (for a mouse button).
    func toggle() {
        if isShown { close() } else { present(byHold: false) }
    }

    /// The windows shortcut: opens the windows, and pressed again goes on to the tabs, and once more closes.
    private func windowsShortcutPressed() {
        if !isShown {
            present(byHold: false)
        } else if model.mode == .windows, settings.tabsEnabled {
            showTabs()
        } else {
            close()
        }
    }

    /// The tabs shortcut: opens the tabs, switches to them from the windows, or closes when already there.
    private func tabsShortcutPressed() {
        guard settings.tabsEnabled else { return }
        if !isShown {
            presentTabs()
        } else if model.mode == .windows {
            showTabs()
        } else {
            close()
        }
    }

    private func noteActivated(_ pid: pid_t) {
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
    }

    // MARK: Key trigger

    /// While the mouse engine isn't running (Mouse Studio paused), the hold key is followed through ordinary
    /// system event monitors instead of the engine's event tap.
    func setEventFallback(_ on: Bool) {
        fallbackMonitors.forEach(NSEvent.removeMonitor)
        fallbackMonitors = []
        guard on else { return }
        let keys: (NSEvent) -> Void = { event in
            FinderTrigger.shared.flagsChanged(UInt64(event.modifierFlags.rawValue), suppressed: false)
        }
        let other: (NSEvent) -> Void = { _ in FinderTrigger.shared.otherInput() }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        fallbackMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: keys),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { keys($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: other),
        ].compactMap { $0 }
    }

    private func keyPressed() {
        guard settings.isEnabled, !isShown, AXIsProcessTrusted() else { return }
        isHolding = true
        pressedAt = Date()
        cancelPending()
        // The list and the pictures are prepared during the hold delay, so the panel can appear at once.
        Task { _ = await fetchSnapshot() }
        if settings.showPreviews { prepareTask = Task { await thumbnailer.prepare() } }
        // A key typed while the modifier is held is a shortcut for the app in front, not a search.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in self?.cancelPending() }
        }
        let work = DispatchWorkItem { [weak self] in self?.holdElapsed() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.delay, execute: work)
    }

    private func keyDisturbed() {
        if !isShown { cancelPending() }
    }

    private func keyReleased() {
        isHolding = false
        guard isShown, openedByHold else {
            cancelPending()
            return
        }
        if model.interacted { commit(index: model.selection) } else { close() }
    }

    private func holdElapsed() {
        pendingShow = nil
        guard isHolding, !typedSincePress(), !anyKeyIsDown() else { return cancelPending() }
        present(byHold: true)
    }

    private func cancelPending() {
        pendingShow?.cancel()
        pendingShow = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if !isShown { session += 1 }
    }

    /// True when a key was pressed since the modifier went down, even one already let go. Asking when the last key
    /// event happened needs no extra permission.
    private func typedSincePress() -> Bool {
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return sinceKey < Date().timeIntervalSince(pressedAt)
    }

    /// A key that was typed and let go inside the hold delay is not seen by the monitor without extra permission,
    /// but one still held is.
    private func anyKeyIsDown() -> Bool {
        let modifiers: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return (0..<128).contains { code in
            let key = CGKeyCode(code)
            return !modifiers.contains(key) && CGEventSource.keyState(.combinedSessionState, key: key)
        }
    }

    // MARK: Showing

    private func present(byHold: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard AXIsProcessTrusted() else { return }
        session += 1
        let current = session
        let started = Date()
        // A list from the last few seconds is shown straight away and then brought up to date; the chosen window
        // follows the fresh order until the user touches anything.
        if let cache, Date().timeIntervalSince(cache.date) < 30 {
            show(cache.items, byHold: byHold)
            FinderLog.shared.note(String(format: "opened from cache (%.0f ms), %d windows", Date().timeIntervalSince(started) * 1000, cache.items.count))
            if Date().timeIntervalSince(cache.date) > 0.5 {
                Task { [weak self] in
                    guard let self else { return }
                    let items = await fetchSnapshot()
                    guard isShown, session == current else { return }
                    model.replace(items: items)
                }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let items = await fetchSnapshot()
            guard session == current, !byHold || isHolding else { return }
            show(items, byHold: byHold)
            FinderLog.shared.note(String(format: "opened after listing (%.0f ms), %d windows", Date().timeIntervalSince(started) * 1000, items.count))
        }
    }

    private func fetchSnapshot() async -> [WindowItem] {
        let order = appOrder
        let includeOtherSpaces = WindowThumbnailer.hasAccess
        let started = Date()
        let items = await Task.detached(priority: .userInitiated) {
            WindowCatalog.snapshot(appOrder: order, includeOtherSpaces: includeOtherSpaces)
        }.value
        cache = (items, Date())
        FinderLog.shared.note(String(format: "listed %d windows in %.0f ms", items.count, Date().timeIntervalSince(started) * 1000))
        return items
    }

    func show(_ items: [WindowItem], byHold: Bool, mode: FinderMode = .windows, tabs: [WindowItem] = []) {
        let screen = Self.screenUnderPointer()
        let showsPictures = settings.showPreviews && WindowThumbnailer.hasAccess
        let visible = screen.visibleFrame
        let layout = settings.layout
        let room = visible.height * 0.78 - 2 * FinderMetrics.inset - FinderMetrics.searchHeight - FinderMetrics.hintHeight
        let listRows = max(1, Int(room / FinderMetrics.rowHeight))
        let rows = layout == .split
            ? listRows
            : min(3, Int(room / (FinderMetrics.cardHeight + FinderMetrics.spacing)))
        model.isVisible = false
        model.begin(
            items: items,
            releaseKey: byHold ? settings.key.symbol : nil,
            showsPictures: showsPictures,
            layout: layout,
            maxVisibleRows: max(1, rows),
            mode: mode,
            tabs: tabs,
            maxListRows: listRows,
            tabsEnabled: settings.tabsEnabled
        )

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panelTop = visible.maxY - visible.height * 0.16
        panel.setFrame(frame(for: model.contentHeight, on: screen), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        isShown = true
        openedByHold = byHold
        DispatchQueue.main.async { [model] in model.isVisible = true }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        if showsPictures && !FinderDemo.isActive && mode == .windows { loadThumbnails() }
        selectionChanged()
    }

    // MARK: Tabs

    /// Opens the list on the tabs. The windows are only fetched if the user goes back to them.
    private func presentTabs() {
        guard AXIsProcessTrusted(), settings.tabsEnabled else { return }
        session += 1
        let current = session
        let fresh = tabCache.flatMap { Date().timeIntervalSince($0.date) < 30 ? $0.snapshot : nil }
        let windows = cache?.items ?? []
        show(windows, byHold: false, mode: .tabs, tabs: fresh?.items ?? [])
        if let fresh { model.replace(tabs: fresh.items, notices: fresh.notices) } else { model.setLoading(.tabs, true) }
        if cache == nil { model.setLoading(.windows, true) }
        refreshTabs(session: current)
    }

    /// From the windows to the tabs, keeping what was typed.
    private func showTabs() {
        guard isShown, settings.tabsEnabled, model.mode == .windows else { return }
        // The key that was held to open the windows has nothing to do with the tabs.
        openedByHold = false
        model.dropReleaseKey()
        if let cached = tabCache?.snapshot { model.replace(tabs: cached.items, notices: cached.notices) } else { model.setLoading(.tabs, true) }
        model.setMode(.tabs)
        selectionChanged()
        refreshTabs(session: session)
    }

    private func switchMode() {
        if model.mode == .windows { showTabs() } else { showWindows() }
    }

    /// From the tabs back to the windows.
    private func showWindows() {
        guard isShown, model.mode == .tabs else { return }
        if let cache { model.replace(items: cache.items) } else { model.setLoading(.windows, true) }
        model.setMode(.windows)
        selectionChanged()
        let current = session
        Task { [weak self] in
            guard let self else { return }
            let items = await fetchSnapshot()
            guard isShown, session == current else { return }
            model.replace(items: items)
            if model.showsPictures && !FinderDemo.isActive && model.thumbnails.isEmpty { loadThumbnails() }
        }
    }

    /// Closes the chosen tab, takes it off the list at once and reads the tabs again a moment later,
    /// because a page can refuse to close (it asks to confirm) and the list should show what really happened.
    private func closeSelectedTab() {
        guard let item = model.selected, item.tab != nil else { return }
        BrowserTabs.close(item)
        model.removeTab(id: item.id)
        if let cached = tabCache {
            var snapshot = cached.snapshot
            snapshot.items.removeAll { $0.id == item.id }
            tabCache = (snapshot, cached.date)
        }
        refreshTabs(session: session, after: 0.45)
    }

    private func refreshTabs(session current: Int, after delay: TimeInterval = 0) {
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self else { return }
            let order = appOrder
            let started = Date()
            let snapshot = await BrowserTabs.snapshot(appOrder: order)
            tabCache = (snapshot, Date())
            FinderLog.shared.note(String(format: "listed %d tabs in %.0f ms", snapshot.items.count, Date().timeIntervalSince(started) * 1000))
            guard isShown, session == current else { return }
            model.replace(tabs: snapshot.items, notices: snapshot.notices)
        }
    }

    private func makePanel() -> FinderPanel {
        let panel = FinderPanel()
        let host = NSHostingView(rootView: FinderView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.keyHandler = { [unowned self] event in handleKey(event) }
        return panel
    }

    private static func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func frame(for contentHeight: CGFloat, on screen: NSScreen) -> NSRect {
        let width = model.panelWidth + 2 * FinderMetrics.inset
        let height = contentHeight + 2 * FinderMetrics.inset
        let visible = screen.visibleFrame
        return NSRect(x: visible.midX - width / 2, y: panelTop - height + FinderMetrics.inset, width: width, height: height)
    }

    private func resizePanel() {
        guard isShown, let panel else { return }
        let target = frame(for: model.contentHeight, on: Self.screenUnderPointer())
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    func close() {
        cancelPending()
        guard isShown else { return }
        isShown = false
        isHolding = false
        session += 1
        let closing = session
        thumbnailTask?.cancel()
        previewTask?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        model.isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.session == closing else { return }
            self.panel?.orderOut(nil)
            self.model.clear()
        }
    }

    private func commit(index: Int) {
        guard model.results.indices.contains(index) else { return close() }
        let item = model.results[index]
        if settings.rememberChoices { (item.tab != nil ? tabHistory : history).record(query: model.query, item: item) }
        close()
        if item.tab != nil { BrowserTabs.switchTo(item) } else { WindowActions.focus(item) }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isShown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)

        switch event.keyCode {
        case 53: // esc
            if model.isPreviewing { model.togglePreview() } else { close() }
            return true
        case 36, 76: // return, enter
            commit(index: model.selection)
            return true
        case 48: // tab: between windows and tabs (one step through the list when tabs are off)
            if settings.tabsEnabled { switchMode() } else { model.move(flags.contains(.shift) ? -1 : 1) }
            return true
        case 123: model.move(-1); return true
        case 124: model.move(1); return true
        case 125: model.moveRow(1); return true
        case 126: model.moveRow(-1); return true
        case 49: // space
            if command { return true }
            if model.layout == .cards && model.query.isEmpty { model.togglePreview() } else if !model.query.isEmpty { model.type(" ") }
            return true
        case 51: // delete
            if command {
                model.clearQuery()
            } else {
                model.backspace()
            }
            return true
        default: break
        }

        if command {
            // In the tabs, ⌘W closes the tab; minimizing, quitting and hiding are for windows.
            guard model.mode == .windows else {
                if event.charactersIgnoringModifiers?.lowercased() == "w" { closeSelectedTab() }
                return true
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": act(on: model.selected, removing: true, WindowActions.close)
            case "m": act(on: model.selected, removing: true, WindowActions.minimize)
            case "q": act(on: model.selected, removing: true, WindowActions.quit)
            case "h": act(on: model.selected, removing: false, WindowActions.hide)
            default: break
            }
            return true
        }
        if flags.contains(.control) { return true }

        // The letters themselves, not what Option turns them into while the key is held.
        if let text = event.charactersIgnoringModifiers,
           !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) && $0.value != 0x7F }) {
            model.type(text)
        }
        return true
    }

    /// Does `action` to the window, then asks for the list again a moment later, because an app can refuse
    /// (a document with unsaved changes) and the list should show what really happened.
    private func act(on item: WindowItem?, removing: Bool, _ action: (WindowItem) -> Void) {
        guard let item else { return }
        action(item)
        if removing { model.remove(id: item.id) }
        refreshList(after: 0.45)
    }

    private func refreshList(after delay: TimeInterval) {
        let current = session
        let order = appOrder
        let includeOtherSpaces = WindowThumbnailer.hasAccess
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isShown, self.session == current else { return }
            Task.detached(priority: .userInitiated) {
                let items = WindowCatalog.snapshot(appOrder: order, includeOtherSpaces: includeOtherSpaces)
                await MainActor.run { [weak self] in
                    guard let self, self.isShown, self.session == current else { return }
                    self.model.replace(items: items)
                }
            }
        }
    }

    // MARK: Pictures

    private func loadThumbnails() {
        thumbnailTask?.cancel()
        // The chosen window first, then the rest in the order they appear.
        let chosen = model.selected?.id
        let ordered = model.results.filter { $0.id == chosen } + model.results.filter { $0.id != chosen }
        let targets = ordered.compactMap { item in item.windowID.map { (item.id, $0) } }
        let thumbnailer = self.thumbnailer
        let preparing = prepareTask
        let width = FinderMetrics.cardWidth
        thumbnailTask = Task { [weak self] in
            if let preparing { await preparing.value } else { await thumbnailer.prepare() }
            var index = 0
            while index < targets.count, !Task.isCancelled {
                let batch = targets[index..<min(index + 4, targets.count)]
                index += 4
                await withTaskGroup(of: (String, NSImage?).self) { group in
                    for (id, windowID) in batch {
                        group.addTask { @MainActor in (id, await thumbnailer.image(of: windowID, width: width)) }
                    }
                    for await (id, image) in group {
                        if let image, !Task.isCancelled { self?.model.setThumbnail(image, for: id) }
                    }
                }
            }
        }
    }

    /// Asks for a larger picture of the selected window while the quick look is open.
    private func selectionChanged() {
        previewTask?.cancel()
        guard isShown, !FinderDemo.isActive, model.mode == .windows, model.isPreviewing || model.layout == .split, model.showsPictures, let windowID = model.selected?.windowID else { return }
        model.setPreview(nil)
        let thumbnailer = self.thumbnailer
        previewTask = Task { [weak self] in
            // Moving quickly through the list shouldn't take a large picture of every window on the way.
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            let image = await thumbnailer.image(of: windowID, width: 900)
            guard !Task.isCancelled, let self, self.model.selected?.windowID == windowID else { return }
            self.model.setPreview(image)
        }
    }
}
