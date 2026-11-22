import Foundation

/// An app Mouse Studio leaves alone while it is in front (games, remote desktops, virtual machines…).
struct ExcludedApp: Codable, Equatable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String

    var id: String { bundleID }
}
