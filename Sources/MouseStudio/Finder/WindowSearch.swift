import Foundation

/// What the search looks at. Kept apart from `WindowItem` so it can be tested with plain values.
protocol WindowSearchable {
    var appName: String { get }
    var title: String { get }
    /// More text to search, such as the address of a browser tab. Matches here rank below the title and the app.
    var detail: String { get }
}

extension WindowSearchable {
    var detail: String { "" }
}

/// The searched texts of one window, already folded, so typing doesn't fold them again for every key.
struct FoldedWindow: Sendable {
    let title: String
    let app: String
    let detail: String

    init(_ item: some WindowSearchable) {
        title = WindowSearch.normalize(item.title)
        app = WindowSearch.normalize(item.appName)
        detail = WindowSearch.normalize(item.detail)
    }
}

/// Finds windows by what the user types: parts of the app name and the title, in any order, ignoring case and
/// accents (so "cua so" finds "Cửa sổ"). Better matches come first; equal ones keep their original order,
/// which is most recently used first.
enum WindowSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    /// `boost` adds to the score of a window that matched, for what the user has picked before.
    static func filter<Item: WindowSearchable>(
        _ items: [Item],
        query: String,
        folded: (Item) -> FoldedWindow = { FoldedWindow($0) },
        boost: (Item) -> Int = { _ in 0 }
    ) -> [Item] {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        var scored: [(index: Int, score: Int)] = []
        for (index, item) in items.enumerated() {
            let text = folded(item)
            var total = 0
            for token in tokens {
                let score = score(token, title: text.title, app: text.app, detail: text.detail)
                if score == 0 { total = 0; break }
                total += score
            }
            if total > 0 { scored.append((index, total + boost(item))) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map { items[$0.index] }
    }

    /// Positions (in `text`'s characters) that the typed words match, for drawing them in a stronger colour.
    static func matchedPositions(in text: String, query: String) -> Set<Int> {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        // Fold one character at a time so a position in the folded text maps back to a character of the original.
        var folded = ""
        var origin: [Int] = []
        for (index, character) in text.enumerated() {
            let piece = normalize(String(character))
            folded += piece
            origin += Array(repeating: index, count: piece.count)
        }
        var found = Set<Int>()
        for token in tokens {
            guard let range = folded.range(of: token) else { continue }
            let start = folded.distance(from: folded.startIndex, to: range.lowerBound)
            for offset in start..<(start + token.count) where origin.indices.contains(offset) { found.insert(origin[offset]) }
        }
        return found
    }

    private static func score(_ token: String, title: String, app: String, detail: String) -> Int {
        if title.hasPrefix(token) { return 100 }
        if hasWordPrefix(title, token) { return 80 }
        if app.hasPrefix(token) { return 70 }
        if hasWordPrefix(app, token) { return 60 }
        if title.contains(token) { return 40 }
        if app.contains(token) { return 30 }
        if !detail.isEmpty {
            if detail.hasPrefix(token) { return 35 }
            if hasWordPrefix(detail, token) { return 25 }
            if detail.contains(token) { return 15 }
        }
        if token.count >= 3, isSubsequence(token, of: app + " " + title) { return 5 }
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
