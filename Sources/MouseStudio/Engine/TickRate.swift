import Foundation

/// How fast the wheel is being turned, from the time between clicks. This is the one speed signal used by both
/// scrolling and zoom; the amount macOS reports for a click is never used (it ranges from 0.1 to ~14 lines for the
/// same click, depending on its own acceleration, which stacked with ours and made fast turns jump).
struct TickRate {
    private var last: TimeInterval?
    /// Smoothed clicks per second.
    private var rate = 0.0

    /// Below this many clicks per second the wheel counts as slow, above `fastRate` as fast.
    static let slowRate = 6.0
    static let fastRate = 30.0

    /// Records a click and returns 0 (slow) ... 1 (fast).
    mutating func tick(at time: TimeInterval) -> Double {
        if let last {
            let gap = time - last
            rate = gap > 0.25 ? 0 : rate * 0.5 + (1 / max(gap, 0.004)) * 0.5
        }
        last = time
        return min(max((rate - Self.slowRate) / (Self.fastRate - Self.slowRate), 0), 1)
    }

    mutating func reset() {
        last = nil
        rate = 0
    }
}
