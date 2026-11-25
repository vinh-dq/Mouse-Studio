import Foundation
import os

/// A short, in-memory note of what the window finder did (timings, which fallback was used). Included in
/// "Copy Recent Mouse Events" so a problem after a macOS update can be traced. Holds no window titles.
final class FinderLog: @unchecked Sendable {
    static let shared = FinderLog()

    private let lines = OSAllocatedUnfairLock(initialState: [String]())
    private let start = Date()

    func note(_ text: String) {
        let stamp = String(format: "%8.3f", Date().timeIntervalSince(start))
        lines.withLock { lines in
            lines.append("\(stamp)  finder  \(text)")
            if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        }
    }

    func dump() -> String {
        let missing = SkyLight.missing
        let header = missing.isEmpty ? "window-server calls: all found" : "window-server calls MISSING: \(missing.joined(separator: ", "))"
        return ([header] + lines.withLock { $0 }).joined(separator: "\n")
    }
}
