import CoreGraphics
import Foundation

/// Turns pointer movement into scroll distance (axis lock, direction, per-axis speed) and measures how fast
/// the content is moving, so a flick can keep gliding after release. Output pacing is the caller's job.
struct DragScrollAccumulator {
    private var samples: [(time: TimeInterval, x: CGFloat, y: CGFloat)] = []

    /// Movement this recent (seconds before release) decides how fast the content keeps gliding.
    private static let velocityWindow = 0.1
    /// If the pointer paused this long before release, the user "stopped" and nothing glides.
    private static let restTime = 0.06
    private static let maxVelocity: CGFloat = 8000

    /// The scroll distance for a pointer movement, or nil if there is none.
    mutating func consume(_ delta: CGPoint, at time: TimeInterval, settings: ScrollSettings) -> CGPoint? {
        var scaled = delta
        switch settings.axisLock {
        case .free: break
        case .horizontal: scaled.y = 0
        case .vertical: scaled.x = 0
        }
        // Content follows the pointer, like two fingers on a Trackpad.
        let direction: CGFloat = settings.invertDirection ? -1 : 1
        scaled.x *= settings.sensitivity * settings.horizontalSpeed * direction
        scaled.y *= settings.sensitivity * settings.verticalSpeed * direction
        guard scaled != .zero else { return nil }

        samples.append((time, scaled.x, scaled.y))
        samples.removeAll { time - $0.time > Self.velocityWindow * 2 }
        return scaled
    }

    /// Speed of the content in points per second at the moment the button is released.
    func releaseVelocity(at time: TimeInterval) -> CGPoint {
        guard let last = samples.last, time - last.time <= Self.restTime else { return .zero }
        var sum = CGPoint.zero
        for sample in samples where time - sample.time <= Self.velocityWindow {
            sum.x += sample.x
            sum.y += sample.y
        }
        var velocity = CGPoint(x: sum.x / Self.velocityWindow, y: sum.y / Self.velocityWindow)
        let speed = hypot(velocity.x, velocity.y)
        if speed > Self.maxVelocity {
            velocity.x *= Self.maxVelocity / speed
            velocity.y *= Self.maxVelocity / speed
        }
        return velocity
    }
}
