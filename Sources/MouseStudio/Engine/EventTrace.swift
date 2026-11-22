import Foundation
import os

/// The most recent button, wheel and reset events with what the engine decided, kept in memory only.
/// It exists so a problem can be diagnosed from facts: users can copy it from the General tab.
/// It holds button numbers, scroll amounts and decisions; never pointer positions, keys or window contents.
final class EventTrace {
    private static let capacity = 400

    private let entries = OSAllocatedUnfairLock(initialState: [String]())
    private let start = ProcessInfo.processInfo.systemUptime

    func record(_ text: @autoclosure () -> String) {
        let line = String(format: "%8.3f  ", ProcessInfo.processInfo.systemUptime - start) + text()
        entries.withLock { lines in
            lines.append(line)
            if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        }
    }

    func dump() -> String {
        entries.withLock { $0.joined(separator: "\n") }
    }
}
