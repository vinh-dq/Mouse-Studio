import Combine
import Foundation
import SwiftUI

/// Owns the configuration: edits, autosave, recovery from damaged files, import and export.
///
/// Saving is debounced, written atomically (a failed write leaves the old file untouched) and keeps the
/// previous file as `config.backup.json`, which is used if the main file turns out to be unreadable.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig
    /// Set when the file on disk could not be used at launch.
    private(set) var loadIssue: String?
    var onSaveError: ((String) -> Void)?

    private let fileURL: URL
    private let backupURL: URL
    private let writeQueue = DispatchQueue(label: "MouseStudio.config-writer", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mouse Studio", isDirectory: true)
    }

    init(directory: URL = ConfigStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("config.json")
        backupURL = directory.appendingPathComponent("config.backup.json")
        let loaded = Self.load(fileURL: fileURL, backupURL: backupURL)
        config = loaded.config
        loadIssue = loaded.issue
    }

    // MARK: - Editing

    func update(_ change: (inout AppConfig) -> Void) {
        var copy = config
        change(&copy)
        copy = copy.sanitized()
        guard copy != config else { return }
        config = copy
        scheduleSave()
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Adds a rule, or replaces the action of the rule that already has this trigger.
    /// Returns true when an existing rule was replaced.
    @discardableResult
    func addRule(trigger: Trigger, action: Action) -> Bool {
        var replaced = false
        update { config in
            if let index = config.rules.firstIndex(where: { $0.trigger == trigger }) {
                config.rules[index].action = action
                config.rules[index].isEnabled = true
                replaced = true
            } else {
                config.rules.append(Rule(trigger: trigger, action: action))
            }
        }
        return replaced
    }

    func removeRule(id: Rule.ID) {
        update { $0.rules.removeAll { $0.id == id } }
    }

    func setAction(_ action: Action, forRule id: Rule.ID) {
        update { config in
            guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
            config.rules[index].action = action
        }
    }

    func setEnabled(_ isEnabled: Bool, forRule id: Rule.ID) {
        update { config in
            guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
            config.rules[index].isEnabled = isEnabled
        }
    }

    func restoreDefaults() {
        update { config in
            config.rules = AppConfig.defaultRules
            config.scroll = ScrollSettings.recommended
            config.wheel = WheelSettings.recommended
            config.swipe = SwipeSettings.recommended
        }
    }

    func existingRule(for trigger: Trigger) -> Rule? {
        config.rules.first { $0.trigger == trigger }
    }

    /// Rules grouped by button, in the order shown in the Buttons tab.
    func groupedRules() -> [(button: MouseButton, rules: [Rule])] {
        Dictionary(grouping: config.rules, by: \.trigger.button)
            .map { button, rules in
                let sorted = rules.sorted {
                    ($0.trigger.interaction.sortOrder, $0.trigger.modifiers.rawValue)
                        < ($1.trigger.interaction.sortOrder, $1.trigger.modifiers.rawValue)
                }
                return (button: button, rules: sorted)
            }
            .sorted { $0.button < $1.button }
    }

    // MARK: - Import / export

    func exportConfig(to url: URL) throws {
        try Self.encode(config).write(to: url, options: .atomic)
    }

    /// Replaces the current configuration with the file's. Script rules arrive switched off, because a
    /// script must only run when the user has looked at it and turned it on.
    func importConfig(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let decoded: AppConfig
        do {
            decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw ConfigError.unreadable
        }
        var imported = decoded.sanitized()
        let skipped = decoded.rules.count - imported.rules.count
        var scriptCount = 0
        for index in imported.rules.indices where imported.rules[index].action.isScript {
            imported.rules[index].isEnabled = false
            scriptCount += 1
        }
        update { $0 = imported }

        var summary = String(localized: "Imported \(imported.rules.count) rule(s).")
        if skipped > 0 { summary += " " + String(localized: "\(skipped) invalid or duplicate rule(s) skipped.") }
        if scriptCount > 0 { summary += " " + String(localized: "\(scriptCount) script rule(s) switched off until you turn them on.") }
        return summary
    }

    // MARK: - Saving

    /// Writes immediately. Called when the app quits.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? Self.encode(config) else { return }
        let (file, backup) = (fileURL, backupURL)
        writeQueue.sync { _ = Self.write(data, to: file, backup: backup) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveInBackground() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveInBackground() {
        pendingSave = nil
        guard let data = try? Self.encode(config) else { return }
        let (file, backup) = (fileURL, backupURL)
        writeQueue.async { [weak self] in
            guard let message = Self.write(data, to: file, backup: backup) else { return }
            DispatchQueue.main.async { self?.onSaveError?(message) }
        }
    }

    nonisolated private static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Returns an error message, or nil on success.
    nonisolated private static func write(_ data: Data, to file: URL, backup: URL) -> String? {
        let manager = FileManager.default
        do {
            // The settings can hold script commands, so only this user may read them.
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if manager.fileExists(atPath: file.path) {
                try? manager.removeItem(at: backup)
                try? manager.copyItem(at: file, to: backup)
            }
            try data.write(to: file, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Loading

    nonisolated private static func read(_ url: URL) -> AppConfig? {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return nil }
        return config.sanitized()
    }

    nonisolated private static func load(fileURL: URL, backupURL: URL) -> (config: AppConfig, issue: String?) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return (AppConfig(), nil) }
        if let config = read(fileURL) { return (config, nil) }

        let damaged = fileURL.deletingLastPathComponent().appendingPathComponent("config.damaged.json")
        try? manager.removeItem(at: damaged)
        try? manager.moveItem(at: fileURL, to: damaged)
        if let config = read(backupURL) {
            return (config, String(localized: "Your settings file was damaged, so Mouse Studio restored the last backup. The damaged file was kept as config.damaged.json."))
        }
        return (AppConfig(), String(localized: "Your settings file was damaged and there was no backup, so default settings were loaded. The damaged file was kept as config.damaged.json."))
    }
}

enum ConfigError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        String(localized: "This file isn't a Mouse Studio configuration, or it is damaged. Nothing was changed.")
    }
}
