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
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let thumbnailer = WindowThumbnailer()
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
        FinderHotKey.shared.onPressed = { [unowned self] in if AXIsProcessTrusted() { toggle() } }
        model.onCommit = { [unowned self] index in commit(index: index) }
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
        model.$isPreviewing
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectionChanged() }
            .store(in: &cancellables)
    }

    func apply(_ settings: WindowFinderSettings) {
        self.settings = settings
        FinderTrigger.shared.configure(isEnabled: settings.isEnabled, key: settings.key)
        FinderHotKey.shared.register(settings.isEnabled ? settings.shortcut : nil)
        if !settings.isEnabled { cancelPending() }
    }

    /// Opens the list and keeps it open until a window is chosen or it is cancelled (for a mouse button).
    func toggle() {
        if isShown { close() } else { present(byHold: false) }
    }

    private func noteActivated(_ pid: pid_t) {
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
    }

    // MARK: Key trigger

    private func keyPressed() {
        guard settings.isEnabled, !isShown, AXIsProcessTrusted() else { return }
        isHolding = true
        cancelPending()
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
        guard isHolding, !anyKeyIsDown() else { return cancelPending() }
        present(byHold: true)
    }

    private func cancelPending() {
        pendingShow?.cancel()
        pendingShow = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if !isShown { session += 1 }
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
        let order = appOrder
        let includeOtherSpaces = WindowThumbnailer.hasAccess
        Task.detached(priority: .userInitiated) {
            let items = WindowCatalog.snapshot(appOrder: order, includeOtherSpaces: includeOtherSpaces)
            await MainActor.run { [weak self] in
                guard let self, self.session == current, !byHold || self.isHolding else { return }
                self.show(items, byHold: byHold)
            }
        }
    }

    private func show(_ items: [WindowItem], byHold: Bool) {
        let screen = Self.screenUnderPointer()
        let showsPictures = settings.showPreviews && WindowThumbnailer.hasAccess
        let visible = screen.visibleFrame
        let rowsThatFit = Int((visible.height * 0.78 - 2 * FinderMetrics.inset - FinderMetrics.searchHeight - FinderMetrics.hintHeight) / (FinderMetrics.cardHeight + FinderMetrics.spacing))
        model.isVisible = false
        model.begin(
            items: items,
            releaseKey: byHold ? settings.key.symbol : nil,
            showsPictures: showsPictures,
            maxVisibleRows: max(1, min(3, rowsThatFit))
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
        if showsPictures { loadThumbnails() }
        selectionChanged()
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
        let width = FinderMetrics.width + 2 * FinderMetrics.inset
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
        close()
        WindowActions.focus(item)
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
        case 48: model.move(flags.contains(.shift) ? -1 : 1); return true
        case 123: model.move(-1); return true
        case 124: model.move(1); return true
        case 125: model.moveRow(1); return true
        case 126: model.moveRow(-1); return true
        case 49: // space
            if command { return true }
            if model.query.isEmpty { model.togglePreview() } else { model.type(" ") }
            return true
        case 51: // delete
            if command { model.clearQuery() } else { model.backspace() }
            return true
        default: break
        }

        if command {
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
        let targets = model.items.compactMap { item in item.windowID.map { (item.id, $0) } }
        let thumbnailer = self.thumbnailer
        let width = FinderMetrics.cardWidth
        thumbnailTask = Task { [weak self] in
            await thumbnailer.prepare()
            var index = 0
            while index < targets.count, !Task.isCancelled {
                let batch = targets[index..<min(index + 3, targets.count)]
                index += 3
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
        guard isShown, model.isPreviewing, model.showsPictures, let windowID = model.selected?.windowID else { return }
        model.setPreview(nil)
        let thumbnailer = self.thumbnailer
        previewTask = Task { [weak self] in
            let image = await thumbnailer.image(of: windowID, width: 900)
            guard !Task.isCancelled, let self, self.model.selected?.windowID == windowID else { return }
            self.model.setPreview(image)
        }
    }
}
