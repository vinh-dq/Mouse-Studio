import AppKit
import CoreGraphics
import os

struct ActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Carries out discrete actions. Continuous ones (drag scroll, zoom/volume by scrolling) are driven
/// by `MouseEventProcessor`, which calls back here step by step.
enum ActionExecutor {
    private enum Key {
        static let w: CGKeyCode = 13
        static let m: CGKeyCode = 46
        static let tab: CGKeyCode = 48
        static let equals: CGKeyCode = 24
        static let minus: CGKeyCode = 27
        static let leftBracket: CGKeyCode = 33
        static let rightBracket: CGKeyCode = 30
        static let leftArrow: CGKeyCode = 123
        static let rightArrow: CGKeyCode = 124
        static let downArrow: CGKeyCode = 125
        static let f11: CGKeyCode = 103
    }

    private enum MediaKey {
        static let volumeUp: Int32 = 0
        static let volumeDown: Int32 = 1
        static let mute: Int32 = 7
        static let playPause: Int32 = 16
        static let next: Int32 = 17
        static let previous: Int32 = 18
    }

    static func run(_ action: Action) throws {
        switch action {
        case .none, .dragScroll, .swipeGesture, .scrollZoom, .scrollVolume:
            break
        case .mouseButton(let button):
            EventPoster.click(button, at: EventPoster.cursorLocation)
        case .keyboardShortcut(let combo):
            EventPoster.key(CGKeyCode(combo.keyCode), flags: combo.modifiers.cgFlags)
        case .system(let action):
            try run(action)
        case .openApp(let path):
            try openApp(path)
        case .openURL(let text):
            try openURL(text)
        case .runScript(let command):
            try runScript(command)
        }
    }

    private static func run(_ action: SystemAction) throws {
        let command: CGEventFlags = .maskCommand
        // Arrow-key shortcuts for Spaces expect the Function flag, as the real keys set it.
        let controlArrow: CGEventFlags = [.maskControl, .maskSecondaryFn]
        switch action {
        case .back: EventPoster.key(Key.leftBracket, flags: command)
        case .forward: EventPoster.key(Key.rightBracket, flags: command)
        case .missionControl: try openSystemApp(["Mission Control"])
        case .appExpose: EventPoster.key(Key.downArrow, flags: controlArrow)
        case .showDesktop: EventPoster.key(Key.f11)
        case .launchpad: try openSystemApp(["Launchpad", "Apps"])
        case .previousApp: EventPoster.key(Key.tab, flags: command)
        case .minimizeWindow: EventPoster.key(Key.m, flags: command)
        case .closeWindow: EventPoster.key(Key.w, flags: command)
        case .spaceLeft: EventPoster.key(Key.leftArrow, flags: controlArrow)
        case .spaceRight: EventPoster.key(Key.rightArrow, flags: controlArrow)
        case .volumeUp: EventPoster.mediaKey(MediaKey.volumeUp)
        case .volumeDown: EventPoster.mediaKey(MediaKey.volumeDown)
        case .mute: EventPoster.mediaKey(MediaKey.mute)
        case .playPause: EventPoster.mediaKey(MediaKey.playPause)
        case .nextTrack: EventPoster.mediaKey(MediaKey.next)
        case .previousTrack: EventPoster.mediaKey(MediaKey.previous)
        case .zoomIn: EventPoster.key(Key.equals, flags: command)
        case .zoomOut: EventPoster.key(Key.minus, flags: command)
        }
    }

    private static func openSystemApp(_ names: [String]) throws {
        for name in names {
            let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        throw ActionError(message: String(localized: "\(names[0]) isn't available on this version of macOS."))
    }

    private static func openApp(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ActionError(message: String(localized: "Couldn't open \(url.lastPathComponent): the app was moved or deleted. Choose it again in the rule."))
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func openURL(_ text: String) throws {
        guard let url = URL(string: text), let scheme = url.scheme else {
            throw ActionError(message: String(localized: "Couldn't open “\(text)”: it isn't a valid link. Include the scheme, for example https://."))
        }
        // A file link would launch whatever it points at, and rules can arrive from an imported file. Apps have
        // their own action, which asks for the app by choosing it.
        guard scheme.lowercased() != "file" else {
            throw ActionError(message: String(localized: "Couldn't open “\(text)”: links to files aren't allowed. Use the Open App action for apps."))
        }
        NSWorkspace.shared.open(url)
    }

    /// How long a script may run before it is stopped. Scripts here are quick commands ("open -a …", "say …");
    /// one that never ends would otherwise stay in the background for good.
    static let scriptTimeout: TimeInterval = 30

    /// Reports a script that failed or was stopped. Set once by `SystemEventOutput`.
    nonisolated(unsafe) static var onScriptFailure: ((String) -> Void)?

    /// Starts the script and returns at once; its outcome (timeout, non-zero exit) is reported later through
    /// `onScriptFailure`, so a slow script never holds up other actions.
    private static func runScript(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let tail = OSAllocatedUnfairLock(initialState: Data())
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            tail.withLock { data in
                data.append(chunk)
                if data.count > 2048 { data = data.suffix(2048) }
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ActionError(message: String(localized: "Couldn't run the script: \(error.localizedDescription)"))
        }
        DispatchQueue.global(qos: .utility).async {
            let timedOut = finished.wait(timeout: .now() + scriptTimeout) == .timedOut
            if timedOut { process.terminate() }
            errors.fileHandleForReading.readabilityHandler = nil
            if timedOut {
                onScriptFailure?(String(localized: "A script took longer than \(Int(scriptTimeout)) seconds and was stopped."))
            } else if process.terminationStatus != 0 {
                let text = String(decoding: tail.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let code = Int(process.terminationStatus)
                onScriptFailure?(text.isEmpty
                    ? String(localized: "A script failed (exit code \(code)).")
                    : String(localized: "A script failed (exit code \(code)): \(String(text.suffix(200)))"))
            }
        }
    }
}
