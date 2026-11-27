import Carbon.HIToolbox
import Foundation

/// Global shortcuts that open the finder: one for windows, one for browser tabs. Carbon hot keys need no extra permission.
@MainActor
final class FinderHotKey {
    enum Kind: UInt32, CaseIterable {
        case windows = 1
        case tabs = 2
    }

    static let shared = FinderHotKey()

    var onPressed: ((Kind) -> Void)?
    private var references: [Kind: EventHotKeyRef] = [:]
    private var combos: [Kind: KeyCombo] = [:]
    /// While a shortcut is being recorded, the finder's own shortcuts are put aside; otherwise recording one of
    /// them again would open the list instead of recording it.
    private var recorders = 0
    private var handler: EventHandlerRef?

    private init() {}

    func recorderChanged(isRecording: Bool) {
        recorders = max(0, recorders + (isRecording ? 1 : -1))
        let saved = combos
        for kind in Kind.allCases { register(saved[kind], for: kind) }
    }

    func register(_ combo: KeyCombo?, for kind: Kind) {
        if let reference = references.removeValue(forKey: kind) { UnregisterEventHotKey(reference) }
        combos[kind] = combo
        guard let combo, recorders == 0 else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == OSType(0x4D534657), let kind = Kind(rawValue: id.id) else { return noErr }
                DispatchQueue.main.async { MainActor.assumeIsolated { FinderHotKey.shared.onPressed?(kind) } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var modifiers = 0
        if combo.modifiers.contains(.command) { modifiers |= cmdKey }
        if combo.modifiers.contains(.shift) { modifiers |= shiftKey }
        if combo.modifiers.contains(.option) { modifiers |= optionKey }
        if combo.modifiers.contains(.control) { modifiers |= controlKey }
        let id = EventHotKeyID(signature: OSType(0x4D534657), id: kind.rawValue) // "MSFW"
        var reference: EventHotKeyRef?
        RegisterEventHotKey(UInt32(combo.keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &reference)
        if let reference { references[kind] = reference }
    }
}
