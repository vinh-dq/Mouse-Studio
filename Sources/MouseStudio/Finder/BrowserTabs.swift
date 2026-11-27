import AppKit
import ApplicationServices

/// The browsers whose tabs can be listed, and how each one is asked.
enum BrowserFamily: Sendable {
    case safari, chromium

    private static let safariIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
    ]

    static func of(bundleID: String?) -> BrowserFamily? {
        guard let bundleID else { return nil }
        if safariIDs.contains(bundleID) { return .safari }
        if chromiumIDs.contains(bundleID) { return .chromium }
        return nil
    }
}

/// Where a tab lives, enough to select exactly that tab again later.
struct BrowserTab: Sendable, Equatable {
    let family: BrowserFamily
    let windowID: Int
    /// 1-based position of the window among the browser's windows, front to back.
    let windowNumber: Int
    let windowCount: Int
    let windowName: String
    let windowTabCount: Int
    let tabIndex: Int
    /// What tells this tab from the others: the browser's own tab number, or the position when it has none.
    let tabKey: String
    let url: String
    let isActive: Bool
    let isPrivate: Bool

    var groupKey: String { "\(windowID)" }

    /// "docs.google.com", or the address as it is when there is no host (about:blank).
    var host: String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The address without its scheme, for searching and for showing in full.
    var address: String {
        guard let range = url.range(of: "://") else { return url }
        return String(url[range.upperBound...])
    }
}

/// Something that kept a browser from being listed, to tell the user instead of showing nothing.
enum TabNotice: Equatable, Sendable {
    case needsAccess(String)
    case notResponding(String)

    var browser: String {
        switch self {
        case .needsAccess(let name), .notResponding(let name): name
        }
    }
}

struct TabSnapshot: Sendable {
    var items: [WindowItem] = []
    var notices: [TabNotice] = []
}

/// One window of a browser as the script reports it, before it becomes list items.
struct ParsedBrowserWindow: Equatable {
    var id = 0
    var activeIndex = 0
    var isPrivate = false
    var name = ""
    var tabs: [ParsedBrowserTab] = []
}

struct ParsedBrowserTab: Equatable {
    var key: String
    var title: String
    var url: String
}

/// Lists the tabs of the running browsers and selects one. The browsers are asked with AppleScript, which needs
/// the Automation permission (macOS asks once per browser).
enum BrowserTabs {
    static let separatorField = "\u{1F}"
    static let separatorRecord = "\u{1E}"

    /// One queue for every script: scripting from several threads at once is not safe, and a browser that
    /// doesn't answer holds up the queue for no more than the script's own time limit.
    private static let queue = DispatchQueue(label: "mousestudio.browser-tabs", qos: .userInitiated)

    // MARK: Listing

    static func snapshot(appOrder: [pid_t]) async -> TabSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: collect(appOrder: appOrder)) }
        }
    }

    private static func collect(appOrder: [pid_t]) -> TabSnapshot {
        let rank = Dictionary(appOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let apps = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && BrowserFamily.of(bundleID: $0.bundleIdentifier) != nil }
            .sorted { (rank[$0.processIdentifier] ?? Int.max) < (rank[$1.processIdentifier] ?? Int.max) }
        var snapshot = TabSnapshot()
        for app in apps {
            guard let bundleID = app.bundleIdentifier, let family = BrowserFamily.of(bundleID: bundleID) else { continue }
            let name = app.localizedName ?? bundleID
            switch Automation.status(of: bundleID, ask: true) {
            case .denied:
                snapshot.notices.append(.needsAccess(name))
                continue
            case .notRunning:
                continue
            case .allowed, .unknown:
                break
            }
            let started = Date()
            switch run(listScript(family: family, bundleID: bundleID)) {
            case .success(let text):
                let windows = parse(text)
                snapshot.items += items(from: windows, app: app, family: family, name: name)
                FinderLog.shared.note(String(format: "tabs of %@: %d windows in %.0f ms", name, windows.count, Date().timeIntervalSince(started) * 1000))
            case .failure(let error):
                FinderLog.shared.note("tabs of \(name): error \(error.code)")
                snapshot.notices.append(error.code == Automation.deniedCode ? .needsAccess(name) : .notResponding(name))
            }
        }
        return snapshot
    }

    private static func items(from windows: [ParsedBrowserWindow], app: NSRunningApplication, family: BrowserFamily, name: String) -> [WindowItem] {
        var result: [WindowItem] = []
        let icon = app.icon
        for (windowIndex, window) in windows.enumerated() {
            for (tabIndex, tab) in window.tabs.enumerated() {
                let info = BrowserTab(
                    family: family,
                    windowID: window.id,
                    windowNumber: windowIndex + 1,
                    windowCount: windows.count,
                    windowName: window.name,
                    windowTabCount: window.tabs.count,
                    tabIndex: tabIndex + 1,
                    tabKey: tab.key,
                    url: tab.url,
                    isActive: window.activeIndex == tabIndex + 1,
                    isPrivate: window.isPrivate
                )
                let title = tab.title.isEmpty ? (info.host.isEmpty ? String(localized: "Untitled") : info.host) : tab.title
                result.append(WindowItem(
                    id: "t:\(app.processIdentifier):\(window.id):\(tab.key)",
                    pid: app.processIdentifier,
                    windowID: nil,
                    appName: name,
                    bundleID: app.bundleIdentifier,
                    title: title,
                    isMinimized: false,
                    isOnOtherSpace: false,
                    isAppHidden: app.isHidden,
                    element: nil,
                    size: nil,
                    icon: icon,
                    tab: info
                ))
            }
        }
        return result
    }

    /// Reads the script's answer: records split by U+001E, fields by U+001F.
    /// `W` = window (id, active tab, private, name), `T` = tab (key, title, address).
    static func parse(_ text: String) -> [ParsedBrowserWindow] {
        var windows: [ParsedBrowserWindow] = []
        for record in text.split(separator: Character(separatorRecord), omittingEmptySubsequences: true) {
            let fields = record.split(separator: Character(separatorField), omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "W" where fields.count >= 5:
                windows.append(ParsedBrowserWindow(
                    id: Int(fields[1]) ?? 0,
                    activeIndex: Int(fields[2]) ?? 0,
                    isPrivate: fields[3] == "incognito" || fields[3] == "private",
                    name: fields[4]
                ))
            case "T" where fields.count >= 4 && !windows.isEmpty:
                windows[windows.count - 1].tabs.append(ParsedBrowserTab(key: fields[1], title: fields[2], url: fields[3]))
            default:
                continue
            }
        }
        return windows
    }

    // MARK: Switching

    /// Selects the tab in its window and brings that window up, on its own desktop.
    static func switchTo(_ item: WindowItem) {
        guard let tab = item.tab, let bundleID = item.bundleID else { return }
        queue.async {
            let source = selectScript(family: tab.family, bundleID: bundleID, tab: tab)
            let app = NSRunningApplication(processIdentifier: item.pid)
            switch run(source) {
            case .success(let text) where text.hasPrefix("ok"):
                let numbers = text.split(separator: Character(separatorField)).dropFirst().compactMap { Double($0) }
                let bounds = numbers.count == 4 ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1]) : nil
                bringUp(item, tab: tab, bounds: bounds)
            case .success:
                // The tab was closed since the list was made.
                FinderLog.shared.note("tab is gone: \(item.title)")
                NSSound.beep()
                app?.activate()
            case .failure(let error):
                FinderLog.shared.note("select tab failed: \(error.code)")
                NSSound.beep()
                app?.activate()
            }
        }
    }

    /// Closes the tab, found again the same way as when switching. The window stays where it is.
    static func close(_ item: WindowItem) {
        guard let tab = item.tab, let bundleID = item.bundleID else { return }
        queue.async {
            switch run(selectScript(family: tab.family, bundleID: bundleID, tab: tab, closing: true)) {
            case .success(let text): if !text.hasPrefix("ok") { FinderLog.shared.note("close tab: already gone") }
            case .failure(let error): FinderLog.shared.note("close tab failed: \(error.code)")
            }
        }
    }

    /// Raises the window that holds the tab. Its Accessibility element is found by where it is on screen; when
    /// it is on another desktop the window server's list is used, and as a last resort the app is activated.
    private static func bringUp(_ item: WindowItem, tab: BrowserTab, bounds: CGRect?) {
        let pid = item.pid
        if let bounds, let target = WindowLocator.find(pid: pid, bounds: bounds, hint: tab.family == .safari ? tab.windowID : nil) {
            let focus = WindowItem(
                id: item.id, pid: pid, windowID: target.windowID, appName: item.appName, bundleID: item.bundleID,
                title: item.title, isMinimized: target.isMinimized, isOnOtherSpace: target.element == nil,
                isAppHidden: item.isAppHidden, element: target.element, size: bounds.size, icon: item.icon
            )
            WindowActions.focus(focus)
        } else {
            FinderLog.shared.note("tab window not located; activating \(item.appName)")
            NSRunningApplication(processIdentifier: pid)?.unhide()
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: Scripts

    private struct ScriptError: Error {
        let code: Int
    }

    private static func run(_ source: String) -> Result<String, ScriptError> {
        guard let script = NSAppleScript(source: source) else { return .failure(ScriptError(code: -1)) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return .failure(ScriptError(code: error[NSAppleScript.errorNumber] as? Int ?? -1))
        }
        return .success(result.stringValue ?? "")
    }

    /// Everything is asked for all windows at once, so the cost is a few Apple events however many tabs there are.
    /// Optional properties sit in `try` blocks: browsers differ in which of them they offer.
    static func listScript(family: BrowserFamily, bundleID: String) -> String {
        let header = """
        if application id "\(bundleID)" is not running then return ""
        set US to (ASCII character 31)
        set RS to (ASCII character 30)
        """
        switch family {
        case .chromium:
            return """
            \(header)
            tell application id "\(bundleID)"
              with timeout of 3 seconds
                set windowIDs to id of every window
                set windowNames to {}
                try
                  set windowNames to name of every window
                end try
                set tabTitles to title of tabs of every window
                set tabURLs to URL of tabs of every window
                set tabIDs to {}
                try
                  set tabIDs to id of tabs of every window
                end try
                set activeIndexes to {}
                try
                  set activeIndexes to active tab index of every window
                end try
                set windowModes to {}
                try
                  set windowModes to mode of every window
                end try
                set out to {}
                repeat with i from 1 to count of windowIDs
                  set active to 0
                  try
                    set active to item i of activeIndexes
                  end try
                  set mode_ to "normal"
                  try
                    set mode_ to item i of windowModes
                  end try
                  set wname to ""
                  try
                    set wname to item i of windowNames
                  end try
                  set end of out to "W" & US & (item i of windowIDs) & US & active & US & mode_ & US & wname
                  set titles_ to item i of tabTitles
                  set urls_ to item i of tabURLs
                  if class of titles_ is not list then
                    set titles_ to {titles_}
                    set urls_ to {urls_}
                  end if
                  repeat with j from 1 to count of titles_
                    set tabKey to j as text
                    try
                      set tabKey to (item j of (item i of tabIDs)) as text
                    end try
                    set url_ to item j of urls_
                    if url_ is missing value then set url_ to ""
                    set end of out to "T" & US & tabKey & US & (item j of titles_) & US & url_
                  end repeat
                end repeat
                set AppleScript's text item delimiters to RS
                set joined to out as text
                set AppleScript's text item delimiters to ""
                return joined
              end timeout
            end tell
            """
        case .safari:
            // One window at a time: Safari also lists windows that have no tabs (its settings, for one),
            // and asking those for their tabs must not spoil the answer for the others.
            return """
            \(header)
            tell application id "\(bundleID)"
              with timeout of 3 seconds
                set out to {}
                repeat with w in every window
                  try
                    set windowID to id of w
                    set tabTitles to name of tabs of w
                    set tabURLs to URL of tabs of w
                    set active to 0
                    try
                      set active to index of current tab of w
                    end try
                    set wname to ""
                    try
                      set wname to name of w
                    end try
                    set end of out to "W" & US & windowID & US & active & US & "normal" & US & wname
                    repeat with j from 1 to count of tabTitles
                      set url_ to item j of tabURLs
                      if url_ is missing value then set url_ to ""
                      set title_ to item j of tabTitles
                      if title_ is missing value then set title_ to ""
                      set end of out to "T" & US & j & US & title_ & US & url_
                    end repeat
                  end try
                end repeat
                set AppleScript's text item delimiters to RS
                set joined to out as text
                set AppleScript's text item delimiters to ""
                return joined
              end timeout
            end tell
            """
        }
    }

    /// Selects the tab and puts its window first among the browser's windows. Answers "ok" and the window's
    /// edges, or "gone" when the window or tab no longer exists. The tab is looked up again by its own number
    /// (or, in Safari, its address), because tabs may have moved since the list was made.
    static func selectScript(family: BrowserFamily, bundleID: String, tab: BrowserTab, closing: Bool = false) -> String {
        let key = escaped(tab.tabKey)
        let url = escaped(tab.url)
        let tail = """
              set b to bounds of w
              set US to (ASCII character 31)
              return "ok" & US & (item 1 of b) & US & (item 2 of b) & US & (item 3 of b) & US & (item 4 of b)
        """
        switch family {
        case .chromium:
            return """
            if application id "\(bundleID)" is not running then return "gone"
            tell application id "\(bundleID)"
              with timeout of 3 seconds
                try
                  set w to window id \(tab.windowID)
                on error
                  return "gone"
                end try
                set idx to \(tab.tabIndex)
                set hasIDs to false
                set found to false
                try
                  set ids to id of tabs of w
                  set hasIDs to true
                  repeat with k from 1 to count of ids
                    if ((item k of ids) as text) is "\(key)" then
                      set idx to k
                      set found to true
                    end if
                  end repeat
                end try
                if hasIDs and not found then return "gone"
                if \(closing) then
                  close tab idx of w
                  return "ok"
                end if
                try
                  set active tab index of w to idx
                on error
                  tell tab idx of w to select
                end try
                set index of w to 1
            \(tail)
              end timeout
            end tell
            """
        case .safari:
            return """
            if application id "\(bundleID)" is not running then return "gone"
            tell application id "\(bundleID)"
              with timeout of 3 seconds
                try
                  set w to window id \(tab.windowID)
                on error
                  return "gone"
                end try
                set idx to \(tab.tabIndex)
                set urls_ to URL of tabs of w
                set same to false
                if idx ≤ (count of urls_) then
                  if ((item idx of urls_) as text) is "\(url)" then set same to true
                end if
                if not same then
                  set found to 0
                  repeat with k from 1 to count of urls_
                    if found is 0 and ((item k of urls_) as text) is "\(url)" then set found to k
                  end repeat
                  if found is 0 then return "gone"
                  set idx to found
                end if
                if \(closing) then
                  close tab idx of w
                  return "ok"
                end if
                set current tab of w to tab idx of w
                set index of w to 1
            \(tail)
              end timeout
            end tell
            """
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Whether Mouse Studio may control a browser (the Automation permission).
enum Automation {
    enum Status {
        case allowed, denied, notRunning, unknown
    }

    static let deniedCode = -1743

    /// With `ask`, macOS shows its permission question the first time. Call it off the main thread: it waits for the answer.
    static func status(of bundleID: String, ask: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let result = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(result) {
        case 0: return .allowed
        case deniedCode, -1744: return .denied
        case -600: return .notRunning
        default: return .unknown
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Finds the window server's number and Accessibility element of a browser window from where it is on screen.
enum WindowLocator {
    struct Target {
        var windowID: CGWindowID?
        var element: AXUIElement?
        var isMinimized: Bool
    }

    static func find(pid: pid_t, bounds: CGRect, hint: Int?) -> Target? {
        AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), 0.5)
        // On this desktop: the app's windows in front-to-back order, the first one of that size is the one just raised.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
           let elements = value as? [AXUIElement] {
            let matches = elements.filter { element in
                guard let frame = WindowCatalog.frame(of: element) else { return false }
                return close(frame, bounds)
            }
            let chosen = matches.first { element in hint != nil && WindowCatalog.windowID(of: element).map { Int($0) == hint } == true } ?? matches.first
            if let chosen {
                return Target(windowID: WindowCatalog.windowID(of: chosen), element: chosen, isMinimized: WindowCatalog.isMinimized(chosen))
            }
        }
        // Other desktops: the window server lists them, front to back.
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var candidates: [CGWindowID] = []
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let rect = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: rect["X"] ?? 0, y: rect["Y"] ?? 0, width: rect["Width"] ?? 0, height: rect["Height"] ?? 0)
            if close(frame, bounds) { candidates.append(number) }
        }
        let chosen = candidates.first { hint != nil && Int($0) == hint } ?? candidates.first
        return chosen.map { Target(windowID: $0, element: nil, isMinimized: false) }
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
