import Foundation

/// What the search looks at. Kept apart from `WindowItem` so it can be tested with plain values.
protocol WindowSearchable {
    var appName: String { get }
    var title: String { get }
}

/// Finds windows by what the user types: parts of the app name and the title, in any order, ignoring case and
/// accents (so "cua so" finds "Cửa sổ"). Better matches come first; equal ones keep their original order,
/// which is most recently used first.
enum WindowSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    static func filter<Item: WindowSearchable>(_ items: [Item], query: String) -> [Item] {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        var scored: [(index: Int, score: Int)] = []
        for (index, item) in items.enumerated() {
            let title = normalize(item.title)
            let app = normalize(item.appName)
            var total = 0
            for token in tokens {
                let score = score(token, title: title, app: app)
                if score == 0 { total = 0; break }
                total += score
            }
            if total > 0 { scored.append((index, total)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map { items[$0.index] }
    }

    private static func score(_ token: String, title: String, app: String) -> Int {
        if title.hasPrefix(token) { return 100 }
        if hasWordPrefix(title, token) { return 80 }
        if app.hasPrefix(token) { return 70 }
        if hasWordPrefix(app, token) { return 60 }
        if title.contains(token) { return 40 }
        if app.contains(token) { return 30 }
        if token.count >= 2, isSubsequence(token, of: app + " " + title) { return 5 }
        return 0
    }

    private static func hasWordPrefix(_ text: String, _ token: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(token) }
    }

    private static func isSubsequence(_ token: String, of text: String) -> Bool {
        var remaining = token[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }
}
