import CoreGraphics

enum WheelNotch {
    /// A click of a classic wheel is one notch, always. macOS reports it scaled by its own acceleration curve
    /// (recorded from a real mouse: 0.1 line for the first click of a burst, then 1.2, 3.5, 6.7 ... up to 13); using
    /// that on top of our own speed and acceleration made fast turns jump, so only the direction is kept and the
    /// speed comes from `TickRate`.
    static func count(_ reportedLines: Double) -> CGFloat {
        reportedLines > 0 ? 1 : (reportedLines < 0 ? -1 : 0)
    }

    static func direction(_ lines: CGFloat) -> Double {
        lines > 0 ? 1 : (lines < 0 ? -1 : 0)
    }
}
