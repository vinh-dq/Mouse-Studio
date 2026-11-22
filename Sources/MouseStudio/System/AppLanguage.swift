import AppKit
import Foundation

/// The language of the interface. "Automatic" follows macOS; the others override it for this app only.
/// macOS reads the preferred language when an app starts, so a change takes effect after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic, english, vietnamese

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whatever language is showing now.
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    private var code: String? {
        switch self {
        case .automatic: nil
        case .english: "en"
        case .vietnamese: "vi"
        }
    }

    static var current: AppLanguage {
        guard let first = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first,
              UserDefaults.standard.object(forKey: "appLanguageChosen") != nil else { return .automatic }
        return allCases.first { $0.code.map(first.hasPrefix) ?? false } ?? .automatic
    }

    func apply() {
        let defaults = UserDefaults.standard
        if let code {
            defaults.set([code], forKey: "AppleLanguages")
            defaults.set(true, forKey: "appLanguageChosen")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: "appLanguageChosen")
        }
    }

    /// Starts a fresh copy of the app and quits this one.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
