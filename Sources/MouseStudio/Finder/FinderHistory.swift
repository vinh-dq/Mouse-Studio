import Foundation

/// What the user picked for what they typed, so that the window they usually mean comes first next time.
/// Kept on this Mac only, as counts, never as a log of what was open.
struct FinderHistory: Codable, Equatable {
    /// Typed text (folded) → window key → times picked.
    private(set) var picks: [String: [String: Int]] = [:]

    private static let maxQueries = 300
    private static let maxWindowsPerQuery = 8

    static func windowKey(bundleID: String?, title: String) -> String {
        "w:\(bundleID ?? "?")|\(String(WindowSearch.normalize(title).prefix(80)))"
    }

    /// A tab is remembered by its site, not its title, which changes with the page ("(3) Inbox").
    static func tabKey(bundleID: String?, host: String) -> String {
        "t:\(bundleID ?? "?")|\(String(WindowSearch.normalize(host).prefix(80)))"
    }

    static func key(for item: WindowItem) -> String {
        if let tab = item.tab { return tabKey(bundleID: item.bundleID, host: tab.host) }
        return windowKey(bundleID: item.bundleID, title: item.title)
    }

    static func appKey(bundleID: String?) -> String {
        "a:\(bundleID ?? "?")"
    }

    mutating func record(query: String, windowKey: String, appKey: String) {
        let typed = WindowSearch.normalize(query).trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        var counts = picks[typed] ?? [:]
        counts[windowKey, default: 0] += 1
        counts[appKey, default: 0] += 1
        // Few entries per text: the least picked windows make room.
        let windows = counts.filter { $0.key.hasPrefix("w:") || $0.key.hasPrefix("t:") }
        if windows.count > Self.maxWindowsPerQuery, let weakest = windows.min(by: { $0.value < $1.value }), weakest.key != windowKey {
            counts[weakest.key] = nil
        }
        picks[typed] = counts
        if picks.count > Self.maxQueries,
           let drop = picks.filter({ $0.key != typed }).min(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) })?.key {
            picks[drop] = nil
        }
    }

    /// How much to raise a window that matches `query`. The same text counts fully, a longer or shorter text that
    /// starts the same way counts half (picking "sh" also helps "she").
    func boost(query: String, windowKey: String, appKey: String) -> Int {
        booster(query: query)(windowKey, appKey)
    }

    /// The same as `boost`, with the typed text folded and the related entries picked out once, for scoring a whole list.
    func booster(query: String) -> (_ windowKey: String, _ appKey: String) -> Int {
        let typed = WindowSearch.normalize(query).trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return { _, _ in 0 } }
        var related: [(weight: Double, counts: [String: Int])] = []
        for (text, counts) in picks {
            let weight: Double = text == typed ? 1 : (text.hasPrefix(typed) || typed.hasPrefix(text) ? 0.5 : 0)
            if weight > 0 { related.append((weight, counts)) }
        }
        guard !related.isEmpty else { return { _, _ in 0 } }
        return { windowKey, appKey in
            var total = 0.0
            for (weight, counts) in related {
                total += weight * (Double(counts[windowKey] ?? 0) * 25 + Double(counts[appKey] ?? 0) * 8)
            }
            return min(150, Int(total))
        }
    }
}

/// Loads and saves the history next to the settings file.
@MainActor
final class FinderHistoryStore {
    private(set) var history = FinderHistory()
    private let url: URL

    init(directory: URL = ConfigStore.defaultDirectory, fileName: String = "finder-history.json") {
        url = directory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode(FinderHistory.self, from: data) {
            history = loaded
        }
    }

    func record(query: String, item: WindowItem) {
        // What was open in a private window is never written down.
        guard item.tab?.isPrivate != true else { return }
        history.record(query: query, windowKey: FinderHistory.key(for: item), appKey: FinderHistory.appKey(bundleID: item.bundleID))
        save()
    }

    /// A scorer for one typed text, so the text is folded once for the whole list.
    func booster(query: String) -> (WindowItem) -> Int {
        let score = history.booster(query: query)
        return { score(FinderHistory.key(for: $0), FinderHistory.appKey(bundleID: $0.bundleID)) }
    }

    func forget() {
        history = FinderHistory()
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
