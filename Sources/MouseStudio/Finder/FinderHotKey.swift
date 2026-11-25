import Carbon.HIToolbox
import Foundation

/// A global shortcut that opens the finder. Carbon hot keys need no extra permission.
@MainActor
final class FinderHotKey {
    static let shared = FinderHotKey()

    var onPressed: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {}

    func register(_ combo: KeyCombo?) {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard let combo else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { FinderHotKey.shared.onPressed?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var modifiers = 0
        if combo.modifiers.contains(.command) { modifiers |= cmdKey }
        if combo.modifiers.contains(.shift) { modifiers |= shiftKey }
        if combo.modifiers.contains(.option) { modifiers |= optionKey }
        if combo.modifiers.contains(.control) { modifiers |= controlKey }
        let id = EventHotKeyID(signature: OSType(0x4D534657), id: 1) // "MSFW"
        RegisterEventHotKey(UInt32(combo.keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &reference)
    }
}
