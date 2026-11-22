import Foundation
import Testing
@testable import MouseStudio

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MouseStudioTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let button4Click = Trigger(button: MouseButton(number: 3), modifiers: [], interaction: .click)

@Suite("Rule set")
struct RuleSetTests {
    @Test func firstRuleWinsForTheSameTrigger() {
        let rules = [Rule(trigger: button4Click, action: .system(.back)), Rule(trigger: button4Click, action: .system(.forward))]
        let match = RuleSet(rules: rules).rules(for: MouseButton(number: 3), modifiers: [])
        #expect(match?.click == .system(.back))
    }

    @Test func disabledAndInvalidRulesAreIgnored() {
        var off = Rule(trigger: button4Click, action: .system(.back))
        off.isEnabled = false
        let bareLeftClick = Rule(trigger: Trigger(button: .left, modifiers: [], interaction: .click), action: .none)
        let wrongAction = Rule(trigger: button4Click, action: .dragScroll)
        #expect(RuleSet(rules: [off, bareLeftClick, wrongAction]).isEmpty)
    }

    @Test func leftButtonIsAllowedWithAModifier() {
        let rule = Rule(trigger: Trigger(button: .left, modifiers: [.option], interaction: .click), action: .none)
        #expect(RuleSet(rules: [rule]).rules(for: .left, modifiers: [.option]) != nil)
    }
}

@Suite("Configuration storage")
@MainActor
struct ConfigStoreTests {
    @Test func savesAndReloadsRules() throws {
        let directory = temporaryDirectory()
        let store = ConfigStore(directory: directory)
        store.addRule(trigger: button4Click, action: .keyboardShortcut(KeyCombo(keyCode: 8, modifiers: [.command], keyLabel: "C")))
        store.update { $0.scroll.sensitivity = 2 }
        store.flush()

        let reloaded = ConfigStore(directory: directory)
        #expect(reloaded.config.rules.contains { $0.trigger == button4Click && $0.action == .keyboardShortcut(KeyCombo(keyCode: 8, modifiers: [.command], keyLabel: "C")) })
        #expect(reloaded.config.scroll.sensitivity == 2)
        #expect(reloaded.loadIssue == nil)
    }

    @Test func addingTheSameTriggerReplacesInsteadOfDuplicating() {
        let store = ConfigStore(directory: temporaryDirectory())
        store.addRule(trigger: button4Click, action: .system(.back))
        let replaced = store.addRule(trigger: button4Click, action: .system(.forward))
        #expect(replaced)
        #expect(store.config.rules.filter { $0.trigger == button4Click }.map(\.action) == [.system(.forward)])
    }

    @Test func damagedFileFallsBackToBackup() throws {
        let directory = temporaryDirectory()
        let store = ConfigStore(directory: directory)
        store.addRule(trigger: button4Click, action: .system(.back))
        store.flush()
        store.update { $0.scroll.sensitivity = 2.5 }   // second save creates the backup of the first
        store.flush()

        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("config.json"))
        let recovered = ConfigStore(directory: directory)
        #expect(recovered.loadIssue != nil)
        #expect(recovered.config.rules.contains { $0.trigger == button4Click })
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.damaged.json").path))
    }

    @Test func damagedFileWithoutBackupLoadsDefaults() throws {
        let directory = temporaryDirectory()
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("config.json"))
        let store = ConfigStore(directory: directory)
        #expect(store.loadIssue != nil)
        #expect(store.config.rules.map(\.trigger) == AppConfig.defaultRules.map(\.trigger))
        #expect(store.config.scroll == ScrollSettings.recommended)
    }

    @Test func oneUnreadableRuleDoesNotDiscardTheRest() throws {
        let json = """
        {"schemaVersion":1,"isEnabled":true,"rules":[
          {"id":"\(UUID().uuidString)","isEnabled":true,"trigger":{"button":3,"modifiers":0,"interaction":"click"},"action":{"system":{"_0":"back"}}},
          {"id":"\(UUID().uuidString)","isEnabled":true,"trigger":{"button":4,"modifiers":0,"interaction":"hologram"},"action":{"none":{}}}
        ]}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.rules.count == 1)
    }

    @Test func oldFilesStartWheelAccelerationFromTheNewDefault() throws {
        let json = #"{"schemaVersion":1,"isEnabled":true,"rules":[],"wheel":{"acceleration":0.4,"speed":2}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.wheel.acceleration == 0)
        #expect(config.wheel.speed == 2)
        #expect(config.schemaVersion == AppConfig.currentSchemaVersion)

        let current = #"{"schemaVersion":2,"isEnabled":true,"rules":[],"wheel":{"acceleration":0.4}}"#
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(current.utf8)).wheel.acceleration == 0.4)
    }

    @Test func swipeSettingReachesTheEngine() {
        var config = AppConfig()
        config.swipe.speed = 0.7
        #expect(EngineConfig(config).swipe.speed == 0.7)
    }

    @Test func importedScriptRulesStartDisabled() throws {
        let source = ConfigStore(directory: temporaryDirectory())
        source.addRule(trigger: button4Click, action: .runScript("say hi"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).json")
        try source.exportConfig(to: file)

        let target = ConfigStore(directory: temporaryDirectory())
        let summary = try target.importConfig(from: file)
        #expect(target.config.rules.first { $0.action.isScript }?.isEnabled == false)
        #expect(summary.contains("switched off"))
    }

    @Test func theSettingsFileIsReadableOnlyByTheUser() throws {
        let directory = temporaryDirectory()
        let store = ConfigStore(directory: directory)
        store.update { $0.scroll.sensitivity = 2 }
        store.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("config.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func importingGarbageChangesNothing() throws {
        let store = ConfigStore(directory: temporaryDirectory())
        let before = store.config
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).json")
        try Data("nope".utf8).write(to: file)
        #expect(throws: ConfigError.self) { try store.importConfig(from: file) }
        #expect(store.config == before)
    }
}

@Suite("Apps and devices")
@MainActor
struct AppsAndDevicesTests {
    @Test func exclusionsAndDeviceProfilesSurviveASaveAndReload() {
        let directory = temporaryDirectory()
        let store = ConfigStore(directory: directory)
        var profile = DeviceProfile(key: "1133:45091", name: "Logitech MX Master 3S")
        profile.customWheel = WheelSettings.recommended
        profile.customWheel?.speed = 2
        store.update {
            $0.excludedApps = [ExcludedApp(bundleID: "com.valvesoftware.steam", name: "Steam")]
            $0.devices = [profile]
            $0.usePrivateFeatures = false
        }
        store.flush()
        let reloaded = ConfigStore(directory: directory).config
        #expect(reloaded.excludedApps.map(\.bundleID) == ["com.valvesoftware.steam"])
        #expect(reloaded.devices.first?.customWheel?.speed == 2)
        #expect(reloaded.usePrivateFeatures == false)
    }

    @Test func duplicatesAreDroppedAndOldFilesStillLoad() throws {
        var config = AppConfig()
        config.excludedApps = [ExcludedApp(bundleID: "a", name: "A"), ExcludedApp(bundleID: "a", name: "A again"), ExcludedApp(bundleID: "", name: "none")]
        config.devices = [DeviceProfile(key: "1:2", name: "x"), DeviceProfile(key: "1:2", name: "y")]
        let clean = config.sanitized()
        #expect(clean.excludedApps.map(\.name) == ["A"])
        #expect(clean.devices.map(\.name) == ["x"])

        let old = #"{"schemaVersion":2,"isEnabled":true,"rules":[]}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
        #expect(decoded.excludedApps.isEmpty && decoded.devices.isEmpty && decoded.usePrivateFeatures)
    }

    @Test func aDeviceUsesItsOwnSettingsOnlyWhereItHasThem() {
        var config = AppConfig()
        config.wheel.speed = 1
        config.scroll.sensitivity = 1
        var profile = DeviceProfile(key: "1:2", name: "x")
        profile.customWheel = {
            var wheel = WheelSettings(); wheel.speed = 3; return wheel
        }()
        let engine = EngineConfig(config)
        let applied = engine.applying(device: profile)
        #expect(applied.wheel.speed == 3)
        #expect(applied.scroll.sensitivity == 1)              // no own drag-scroll settings: shared ones
        #expect(engine.applying(device: nil).wheel.speed == 1)
    }
}

@Suite("Factory settings")
struct FactorySettingsTests {
    @Test func aFreshInstallStartsFromTheTunedSetup() {
        let config = AppConfig()
        #expect(config.rules.count == 7)
        #expect(config.rules.allSatisfy { $0.isValid })
        #expect(Set(config.rules.map(\.trigger)).count == 7)        // no duplicates
        #expect(config.wheel.reverseVertical && config.wheel.zoomStep == 0.07)
        #expect(config.scroll.freezeCursor == false && config.scroll.inertia == 0.25)
        #expect(config.sanitized().rules.count == 7)                // nothing is dropped as invalid
        #expect(config.sanitized().wheel == config.wheel && config.sanitized().scroll == config.scroll)
    }
}

@Suite("App model")
@MainActor
struct AppModelTests {
    @Test func theStatusFollowsTheSwitchImmediately() {
        let model = AppModel(store: ConfigStore(directory: temporaryDirectory()))
        model.setEnabled(false)
        #expect(model.status == .off)
        model.setEnabled(true)
        #expect(model.status != .off)      // was one toggle behind: the status showed the previous setting
        model.setEnabled(false)
        #expect(model.status == .off)
        model.shutdown()
    }
}

@Suite("Translations")
struct TranslationTests {
    private func placeholders(_ text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let percent = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: percent)...]
            for token in ["@", "lld", "d"] where rest.hasPrefix(token) {
                found.append("%" + token)
                break
            }
        }
        return found
    }

    @Test func vietnameseKeepsEveryPlaceholderOfTheEnglishText() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/vi.lproj/Localizable.strings")
        let table = try #require(NSDictionary(contentsOf: file) as? [String: String])
        #expect(table.count > 200)
        for (english, vietnamese) in table {
            #expect(placeholders(english) == placeholders(vietnamese), "“\(english)” and its translation must use the same placeholders")
            #expect(!vietnamese.isEmpty)
        }
    }

    @Test func trackpadsAreNotOfferedAsMice() {
        #expect(DeviceIdentity.isTrackpad(DeviceInfo(key: "name:Apple Internal Keyboard / Trackpad", name: "Apple Internal Keyboard / Trackpad")))
        #expect(!DeviceIdentity.isTrackpad(DeviceInfo(key: "1133:45091", name: "MX Master 3S")))
    }
}

@Suite("Script action", .serialized)
struct ScriptActionTests {
    @Test func aFailingScriptIsReportedWithItsExitCodeAndMessage() async throws {
        let reported = LockedBox<String?>(nil)
        ActionExecutor.onScriptFailure = { reported.set($0) }
        defer { ActionExecutor.onScriptFailure = nil }
        try ActionExecutor.run(.runScript("echo something went wrong >&2; exit 3"))
        for _ in 0..<50 where reported.get() == nil { try await Task.sleep(for: .milliseconds(100)) }
        let message = try #require(reported.get())
        #expect(message.contains("3"))
        #expect(message.contains("something went wrong"))
    }

    @Test func aSuccessfulScriptReportsNothing() async throws {
        let reported = LockedBox<String?>(nil)
        ActionExecutor.onScriptFailure = { reported.set($0) }
        defer { ActionExecutor.onScriptFailure = nil }
        try ActionExecutor.run(.runScript("exit 0"))
        try await Task.sleep(for: .seconds(1))
        #expect(reported.get() == nil)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
}
