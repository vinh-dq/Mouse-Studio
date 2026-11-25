import AppKit

/// Sizes of the finder's panel. The panel is a glass card with room around it for its shadow.
enum FinderMetrics {
    static let inset: CGFloat = 32
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
}

/// What the finder shows: the windows, what was typed, which one is selected.
@MainActor
final class FinderModel: ObservableObject {
    @Published private(set) var items: [WindowItem] = []
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

    /// True once the user typed, selected or previewed something. Letting go of the key then switches windows.
    private(set) var interacted = false
    var maxVisibleRows = 3
    var onCommit: ((Int) -> Void)?

    private var openedPointer = NSEvent.mouseLocation
    private var pointerMoved = false

    var selected: WindowItem? { results.indices.contains(selection) ? results[selection] : nil }

    func begin(items: [WindowItem], releaseKey: String?, showsPictures: Bool, maxVisibleRows: Int) {
        self.items = items
        self.releaseKey = releaseKey
        self.showsPictures = showsPictures
        self.maxVisibleRows = maxVisibleRows
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
        items = []
        results = []
        thumbnails = [:]
        previewImage = nil
        query = ""
        isPreviewing = false
    }

    /// A fresh list (after a window was closed, say): the query and the selected window are kept where possible.
    func replace(items: [WindowItem]) {
        self.items = items
        refilter(keeping: selected?.id)
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
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
        guard !results.isEmpty, !isPreviewing else { return }
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
        guard selected != nil else { return }
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

    private func refilter(keeping id: String?, nearIndex: Int? = nil) {
        results = WindowSearch.filter(items, query: query)
        if let id, let index = results.firstIndex(where: { $0.id == id }) {
            selection = index
        } else if let nearIndex {
            selection = min(nearIndex, max(0, results.count - 1))
        } else {
            // With nothing typed, the window just left is first, so the one before it is the natural choice.
            selection = query.isEmpty && results.count > 1 ? 1 : 0
        }
        if results.isEmpty { isPreviewing = false }
        updateHeight()
    }

    private func updateHeight() {
        let chrome = FinderMetrics.searchHeight + FinderMetrics.hintHeight
        let body: CGFloat
        if results.isEmpty {
            body = FinderMetrics.emptyHeight
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
