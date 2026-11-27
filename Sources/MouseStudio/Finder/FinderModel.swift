import AppKit

/// Sizes of the finder's panel. The panel is a glass card with room around it for its shadow.
enum FinderMetrics {
    static let inset: CGFloat = 48
    static let width: CGFloat = 760
    static let searchHeight: CGFloat = 62
    static let hintHeight: CGFloat = 42
    static let gridPadding: CGFloat = 14
    static let spacing: CGFloat = 8
    static let columns = 4
    static let cardPadding: CGFloat = 8
    static let thumbHeight: CGFloat = 100
    static let titleHeight: CGFloat = 34
    static let cardWidth: CGFloat = (width - 2 * gridPadding - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    static let cardHeight: CGFloat = thumbHeight + titleHeight + 3 * cardPadding
    static let previewHeight: CGFloat = 410
    static let emptyHeight: CGFloat = 140
    static let cornerRadius: CGFloat = 30

    // The split layout: a list and a large picture.
    static let splitWidth: CGFloat = 880
    static let listWidth: CGFloat = 330
    static let rowHeight: CGFloat = 56
    static let listPadding: CGFloat = 10
    static let splitMinBody: CGFloat = 330
    static let splitMaxRows = 8
    static let groupHeaderHeight: CGFloat = 32
    static let noticeHeight: CGFloat = 36

    static func width(for layout: FinderLayout) -> CGFloat {
        layout == .split ? splitWidth : width
    }
}

/// What the finder looks through: the open windows, or the tabs of the browsers.
enum FinderMode: Sendable {
    case windows, tabs
}

/// The line above the tabs of one browser window, shown while nothing is typed.
struct TabGroupHeader {
    let browser: String
    /// "Window 2", when the browser has more than one.
    let window: String?
    /// What the window was named, when that says more than its current tab.
    let name: String?
    let count: Int
    let icon: NSImage?
}

/// What the finder shows: the windows or tabs, what was typed, which one is selected.
@MainActor
final class FinderModel: ObservableObject {
    @Published private(set) var windowItems: [WindowItem] = []
    @Published private(set) var tabItems: [WindowItem] = []
    @Published private(set) var mode = FinderMode.windows
    @Published private(set) var loading: Set<FinderMode> = []
    @Published private(set) var tabNotices: [TabNotice] = []
    /// First tab of each browser window → the line to draw above it. Only while nothing is typed.
    @Published private(set) var groupHeaders: [String: TabGroupHeader] = [:]
    @Published private(set) var results: [WindowItem] = []
    @Published private(set) var query = ""
    @Published private(set) var selection = 0
    @Published private(set) var isPreviewing = false
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var contentHeight: CGFloat = FinderMetrics.emptyHeight + FinderMetrics.searchHeight + FinderMetrics.hintHeight
    @Published var isVisible = false
    /// The key to let go of to switch, shown in the hint line; nil when the list was opened by a mouse button.
    @Published private(set) var releaseKey: String?
    /// Whether windows are shown as pictures (previews on, and Screen Recording allowed).
    @Published private(set) var showsPictures = false
    @Published private(set) var layout = FinderLayout.split
    /// Whether browser tabs can be searched; without it the Windows/Tabs switch is not shown.
    @Published private(set) var tabsEnabled = true

    /// The list being searched.
    var items: [WindowItem] { mode == .windows ? windowItems : tabItems }
    var isLoading: Bool { loading.contains(mode) }
    /// Tabs are always a list with details, whatever layout the windows use.
    var activeLayout: FinderLayout { mode == .tabs ? .split : layout }
    var hasTypedText: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// True once the user typed, selected or previewed something. Letting go of the key then switches windows.
    private(set) var interacted = false
    var maxVisibleRows = 3
    /// Rows the list-with-details can show; the cards layout has fewer rows than a list when tabs are shown.
    var maxListRows = 3
    var onCommit: ((Int) -> Void)?
    /// A click on "Windows" or "Tabs" in the search line.
    var onSetMode: ((FinderMode) -> Void)?
    /// Extra score for windows the user has picked before for what they typed.
    var boost: ((String, WindowItem) -> Int)?
    /// The same, made once for a typed text, so a long list isn't prepared again for every item.
    var boosterFor: ((String) -> (WindowItem) -> Int)?
    private var folded: [String: FoldedWindow] = [:]

    var panelWidth: CGFloat { FinderMetrics.width(for: activeLayout) }

    private var openedPointer = NSEvent.mouseLocation
    private var pointerMoved = false

    var selected: WindowItem? { results.indices.contains(selection) ? results[selection] : nil }

    func begin(
        items: [WindowItem],
        releaseKey: String?,
        showsPictures: Bool,
        layout: FinderLayout,
        maxVisibleRows: Int,
        mode: FinderMode = .windows,
        tabs: [WindowItem] = [],
        maxListRows: Int? = nil,
        tabsEnabled: Bool = true
    ) {
        self.tabsEnabled = tabsEnabled
        self.layout = layout
        self.mode = mode
        windowItems = items
        tabItems = tabs
        tabNotices = []
        loading = []
        fold(items + tabs)
        self.releaseKey = releaseKey
        self.showsPictures = showsPictures
        self.maxVisibleRows = maxVisibleRows
        self.maxListRows = maxListRows ?? maxVisibleRows
        query = ""
        interacted = false
        isPreviewing = false
        previewImage = nil
        thumbnails = [:]
        pointerMoved = false
        openedPointer = NSEvent.mouseLocation
        refilter(keeping: nil)
    }

    func clear() {
        windowItems = []
        tabItems = []
        tabNotices = []
        groupHeaders = [:]
        loading = []
        folded = [:]
        mode = .windows
        results = []
        thumbnails = [:]
        previewImage = nil
        query = ""
        isPreviewing = false
    }

    /// A fresh list (after a window was closed, say): the query and the selected window are kept where possible.
    func replace(items: [WindowItem]) {
        windowItems = items
        fold(items)
        loading.remove(.windows)
        if mode == .windows {
            // Until the user does something, the list may still be a cached one; the choice follows the fresh order.
            refilter(keeping: interacted ? selected?.id : nil)
        }
    }

    /// The tabs just read from the browsers (or the ones that couldn't be read, with the reason).
    func replace(tabs: [WindowItem], notices: [TabNotice]) {
        tabItems = tabs
        tabNotices = notices
        fold(tabs)
        loading.remove(.tabs)
        if mode == .tabs {
            refilter(keeping: interacted ? selected?.id : nil)
        }
    }

    func dropReleaseKey() {
        releaseKey = nil
    }

    func setLoading(_ mode: FinderMode, _ isLoading: Bool) {
        if isLoading { loading.insert(mode) } else { loading.remove(mode) }
    }

    /// Switches between windows and tabs. What was typed stays.
    func setMode(_ new: FinderMode) {
        guard new != mode else { return }
        mode = new
        isPreviewing = false
        previewImage = nil
        interacted = true
        refilter(keeping: nil)
    }

    func removeTab(id: String) {
        tabItems.removeAll { $0.id == id }
        refilter(keeping: nil, nearIndex: selection)
    }

    func remove(id: String) {
        windowItems.removeAll { $0.id == id }
        refilter(keeping: nil, nearIndex: selection)
    }

    // MARK: Typing

    func type(_ text: String) {
        query += text
        interacted = true
        isPreviewing = false
        refilter(keeping: nil)
    }

    func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        interacted = true
        refilter(keeping: nil)
    }

    func clearQuery() {
        guard !query.isEmpty else { return }
        query = ""
        refilter(keeping: nil)
    }

    // MARK: Selection

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + step % results.count + results.count) % results.count
        interacted = true
    }

    /// Up and down move one row; at the first or last row they stay where they are.
    func moveRow(_ rows: Int) {
        guard !results.isEmpty else { return }
        if activeLayout == .split {
            move(rows)
            return
        }
        guard !isPreviewing else { return }
        let target = selection + rows * FinderMetrics.columns
        if results.indices.contains(target) {
            selection = target
        } else if rows > 0, selection / FinderMetrics.columns < (results.count - 1) / FinderMetrics.columns {
            selection = results.count - 1
        }
        interacted = true
    }

    /// The pointer is over a card. Ignored until the pointer really moves, so a list that opens under a resting
    /// pointer doesn't select whatever is there.
    func hover(_ index: Int) {
        if !pointerMoved {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - openedPointer.x, now.y - openedPointer.y) > 3 else { return }
            pointerMoved = true
        }
        guard index != selection, results.indices.contains(index) else { return }
        selection = index
        interacted = true
    }

    func togglePreview() {
        guard selected != nil, activeLayout == .cards else { return }
        isPreviewing.toggle()
        previewImage = nil
        interacted = true
        updateHeight()
    }

    func setThumbnail(_ image: NSImage, for id: String) {
        thumbnails[id] = image
    }

    func setPreview(_ image: NSImage?) {
        previewImage = image
    }

    // MARK: Private

    private func fold(_ list: [WindowItem]) {
        for item in list where folded[item.id] == nil { folded[item.id] = FoldedWindow(item) }
        // Items that are gone are dropped now and then, so the table doesn't grow over a long session.
        if folded.count > 4 * (windowItems.count + tabItems.count) + 64 {
            let live = Set((windowItems + tabItems).map(\.id))
            folded = folded.filter { live.contains($0.key) }
        }
    }

    private func refilter(keeping id: String?, nearIndex: Int? = nil) {
        let typed = query
        let booster = boosterFor?(typed)
        let boost = self.boost
        let table = folded
        results = WindowSearch.filter(
            items,
            query: query,
            folded: { table[$0.id] ?? FoldedWindow($0) },
            boost: { booster?($0) ?? boost?(typed, $0) ?? 0 }
        )
        if let id, let index = results.firstIndex(where: { $0.id == id }) {
            selection = index
        } else if let nearIndex {
            selection = min(nearIndex, max(0, results.count - 1))
        } else {
            selection = defaultSelection()
        }
        groupHeaders = mode == .tabs && !hasTypedText ? Self.headers(for: results) : [:]
        if results.isEmpty { isPreviewing = false }
        updateHeight()
    }

    private func defaultSelection() -> Int {
        guard !hasTypedText else { return 0 }
        if mode == .tabs {
            // Where you are now, so the arrows start from it.
            return results.firstIndex { $0.tab?.isActive == true } ?? 0
        }
        // With nothing typed, the window just left is first, so the one before it is the natural choice.
        return results.count > 1 ? 1 : 0
    }

    /// One header per browser window, in the order the tabs come.
    private static func headers(for tabs: [WindowItem]) -> [String: TabGroupHeader] {
        var result: [String: TabGroupHeader] = [:]
        var index = 0
        while index < tabs.count {
            guard let first = tabs[index].tab else { index += 1; continue }
            var end = index
            while end < tabs.count, tabs[end].pid == tabs[index].pid, tabs[end].tab?.windowID == first.windowID { end += 1 }
            let group = tabs[index..<end]
            let active = group.first { $0.tab?.isActive == true }?.title
            let named = first.windowName.isEmpty || first.windowName == active || group.contains { $0.title == first.windowName } ? nil : first.windowName
            result[tabs[index].id] = TabGroupHeader(
                browser: tabs[index].appName,
                window: first.windowCount > 1 ? String(localized: "Window \(first.windowNumber)") : nil,
                name: named,
                count: group.count,
                icon: tabs[index].icon
            )
            index = end
        }
        return result
    }

    private func updateHeight() {
        var chrome = FinderMetrics.searchHeight + FinderMetrics.hintHeight
        if mode == .tabs, !tabNotices.isEmpty { chrome += FinderMetrics.noticeHeight }
        let body: CGFloat
        if results.isEmpty {
            body = FinderMetrics.emptyHeight
        } else if activeLayout == .split {
            let cap = min(layout == .split ? maxVisibleRows : maxListRows, FinderMetrics.splitMaxRows)
            let content = CGFloat(results.count) * FinderMetrics.rowHeight + CGFloat(groupHeaders.count) * FinderMetrics.groupHeaderHeight
            let shown = min(content, CGFloat(cap) * FinderMetrics.rowHeight + CGFloat(min(groupHeaders.count, 1)) * FinderMetrics.groupHeaderHeight)
            body = max(FinderMetrics.splitMinBody, shown + 2 * FinderMetrics.listPadding)
        } else if isPreviewing {
            body = FinderMetrics.previewHeight
        } else {
            let rows = (results.count + FinderMetrics.columns - 1) / FinderMetrics.columns
            let shown = CGFloat(min(rows, maxVisibleRows))
            body = shown * FinderMetrics.cardHeight + (shown - 1) * FinderMetrics.spacing + 2 * FinderMetrics.gridPadding
        }
        contentHeight = chrome + body
    }
}
