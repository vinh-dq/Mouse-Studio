import CoreGraphics
import Foundation

/// Which desktop (Space) and display a window is on, as a short label such as "Desktop 2" or "Full screen".
enum WindowSpaces {
    private struct Place {
        var desktop: Int?
        var display: Int
    }

    /// Labels for the given windows. Empty when there is only one desktop on one display (a label would say nothing),
    /// or when macOS doesn't offer the information.
    static func labels(for windowIDs: [CGWindowID]) -> [CGWindowID: String] {
        guard !windowIDs.isEmpty,
              let connection = SkyLight.mainConnection?(),
              let displays = SkyLight.copyDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]],
              let spacesForWindows = SkyLight.copySpacesForWindows else { return [:] }

        var places: [Int: Place] = [:]
        var desktopTotal = 0
        for (displayIndex, display) in displays.enumerated() {
            var desktop = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["ManagedSpaceID"] as? Int ?? space["id64"] as? Int else { continue }
                if (space["type"] as? Int ?? 0) == 0 {
                    desktop += 1
                    places[id] = Place(desktop: desktop, display: displayIndex + 1)
                } else {
                    places[id] = Place(desktop: nil, display: displayIndex + 1)
                }
            }
            desktopTotal += desktop
        }
        guard desktopTotal > 1 || displays.count > 1 else { return [:] }

        var labels: [CGWindowID: String] = [:]
        for windowID in windowIDs {
            let ids = spacesForWindows(connection, 7, [Int(windowID)] as CFArray)?.takeRetainedValue() as? [Int] ?? []
            if ids.count > 1 {
                labels[windowID] = String(localized: "All desktops")
            } else if let place = ids.first.flatMap({ places[$0] }) {
                labels[windowID] = label(place, displayCount: displays.count)
            }
        }
        return labels
    }

    private static func label(_ place: Place, displayCount: Int) -> String {
        let name = place.desktop.map { String(localized: "Desktop \($0)") } ?? String(localized: "Full screen")
        return displayCount > 1 ? name + " · " + String(localized: "Display \(place.display)") : name
    }
}
