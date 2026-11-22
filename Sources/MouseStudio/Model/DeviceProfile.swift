import Foundation

/// Settings for one particular mouse. `key` is "vendorID:productID", so the same model keeps its settings
/// when it is unplugged, switched between Bluetooth and a cable, or replaced by an identical one.
struct DeviceProfile: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var name: String
    /// Off = Mouse Studio ignores this device completely.
    var isEnabled = true
    /// nil = use the shared wheel / drag-scroll settings.
    var customWheel: WheelSettings?
    var customScroll: ScrollSettings?

    var id: String { key }

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    func clamped() -> DeviceProfile {
        var copy = self
        copy.customWheel = customWheel?.clamped()
        copy.customScroll = customScroll?.clamped()
        return copy
    }
}
