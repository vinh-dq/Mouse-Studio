import Foundation

/// Built-in macOS actions. Scroll-driven actions (zoom, volume) reuse the same steps.
enum SystemAction: String, Codable, CaseIterable, Sendable {
    case back, forward
    case missionControl, appExpose, showDesktop, launchpad, previousApp
    case minimizeWindow, closeWindow
    case spaceLeft, spaceRight
    case volumeUp, volumeDown, mute
    case playPause, nextTrack, previousTrack
    case zoomIn, zoomOut

    var title: String {
        switch self {
        case .back: String(localized: "Back")
        case .forward: String(localized: "Forward")
        case .missionControl: String(localized: "Mission Control")
        case .appExpose: String(localized: "App Exposé")
        case .showDesktop: String(localized: "Show Desktop")
        case .launchpad: String(localized: "Launchpad")
        case .previousApp: String(localized: "Previous App")
        case .minimizeWindow: String(localized: "Minimize Window")
        case .closeWindow: String(localized: "Close Window")
        case .spaceLeft: String(localized: "Move Left a Space")
        case .spaceRight: String(localized: "Move Right a Space")
        case .volumeUp: String(localized: "Volume Up")
        case .volumeDown: String(localized: "Volume Down")
        case .mute: String(localized: "Mute")
        case .playPause: String(localized: "Play / Pause")
        case .nextTrack: String(localized: "Next Track")
        case .previousTrack: String(localized: "Previous Track")
        case .zoomIn: String(localized: "Zoom In")
        case .zoomOut: String(localized: "Zoom Out")
        }
    }

    var symbol: String {
        switch self {
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.on.rectangle"
        case .showDesktop: "macwindow"
        case .launchpad: "square.grid.3x3"
        case .previousApp: "arrow.left.arrow.right"
        case .minimizeWindow: "minus.rectangle"
        case .closeWindow: "xmark.rectangle"
        case .spaceLeft: "chevron.left.2"
        case .spaceRight: "chevron.right.2"
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .mute: "speaker.slash"
        case .playPause: "playpause"
        case .nextTrack: "forward.end"
        case .previousTrack: "backward.end"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        }
    }
}

/// What a rule does when its trigger fires. New kinds are added as new cases plus one branch in
/// `ActionExecutor` (discrete actions) or `MouseEventProcessor` (continuous actions).
enum Action: Hashable, Codable, Sendable {
    case none
    case mouseButton(MouseButton)
    case keyboardShortcut(KeyCombo)
    case system(SystemAction)
    case openApp(path: String)
    case openURL(String)
    case runScript(String)
    case findWindow
    // Continuous actions
    case dragScroll
    case swipeGesture
    case scrollZoom
    case scrollVolume

    var title: String {
        switch self {
        case .none: String(localized: "Do Nothing")
        case .mouseButton(let button): button.clickName
        case .keyboardShortcut(let combo): combo.display
        case .system(let action): action.title
        case .openApp(let path): Self.appName(path)
        case .openURL(let url): url
        case .runScript: String(localized: "Run Script")
        case .findWindow: String(localized: "Find Window")
        case .dragScroll: String(localized: "Drag Scroll")
        case .swipeGesture: String(localized: "Spaces & Mission Control")
        case .scrollZoom: String(localized: "Zoom In or Out")
        case .scrollVolume: String(localized: "Adjust Volume")
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .mouseButton: "computermouse"
        case .keyboardShortcut: "command"
        case .system(let action): action.symbol
        case .openApp: "app"
        case .openURL: "link"
        case .runScript: "terminal"
        case .findWindow: "macwindow.on.rectangle"
        case .dragScroll: "arrow.up.and.down.and.arrow.left.and.right"
        case .swipeGesture: "rectangle.3.group"
        case .scrollZoom: "plus.magnifyingglass"
        case .scrollVolume: "speaker.wave.2"
        }
    }

    var isScript: Bool {
        if case .runScript = self { return true }
        return false
    }

    func isAllowed(for interaction: Interaction) -> Bool {
        switch self {
        case .dragScroll, .swipeGesture: interaction == .drag
        case .scrollZoom, .scrollVolume: interaction == .scroll
        default: interaction != .drag && interaction != .scroll
        }
    }

    private static func appName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Open App" : name
    }
}
