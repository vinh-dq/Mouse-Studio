import Foundation
import Testing
@testable import MouseStudio

private struct Entry: WindowSearchable, Equatable {
    var appName: String
    var title: String
}

private let windows = [
    Entry(appName: "Safari", title: "Apple"),
    Entry(appName: "Google Chrome", title: "Báo cáo tháng 11 - Google Sheets"),
    Entry(appName: "Xcode", title: "AppModel.swift"),
    Entry(appName: "Terminal", title: "zsh — 80×24"),
    Entry(appName: "Finder", title: "Cửa sổ Tải xuống"),
]

@Suite("Window search")
struct WindowSearchTests {
    @Test func emptyQueryKeepsEveryWindowInOrder() {
        #expect(WindowSearch.filter(windows, query: "  ") == windows)
    }

    @Test func ignoresCaseAndAccents() {
        #expect(WindowSearch.filter(windows, query: "bao cao").map(\.appName) == ["Google Chrome"])
        #expect(WindowSearch.filter(windows, query: "TAI XUONG").map(\.appName) == ["Finder"])
        #expect(WindowSearch.filter(windows, query: "Tải").map(\.appName) == ["Finder"])
        #expect(WindowSearch.normalize("Đường") == "duong")
    }

    @Test func everyWordMustMatchInAnyOrder() {
        #expect(WindowSearch.filter(windows, query: "sheets chrome").map(\.appName) == ["Google Chrome"])
        #expect(WindowSearch.filter(windows, query: "chrome terminal").isEmpty)
    }

    @Test func startsOfWordsRankAboveMiddlesOfWords() {
        // "app" begins "Apple" (Safari's title) and "AppModel.swift", and is only inside no other title.
        let names = WindowSearch.filter(windows, query: "app").map(\.appName)
        #expect(names == ["Safari", "Xcode"])
    }

    @Test func equalMatchesKeepRecencyOrder() {
        let same = [Entry(appName: "A", title: "note 1"), Entry(appName: "B", title: "note 2")]
        #expect(WindowSearch.filter(same, query: "note").map(\.appName) == ["A", "B"])
    }

    @Test func lettersInOrderStillFindAWindow() {
        #expect(WindowSearch.filter(windows, query: "gsh").map(\.appName) == ["Google Chrome"])
    }
}

@Suite("Finder key")
struct FinderHoldTrackerTests {
    private let rightOption: UInt64 = 0x40 | 0x80000
    private let leftOption: UInt64 = 0x20 | 0x80000

    @Test func rightOptionAlonePressesAndReleases() {
        var tracker = FinderHoldTracker()
        #expect(tracker.flagsChanged(rightOption, key: .rightOption) == .pressed)
        #expect(tracker.flagsChanged(0, key: .rightOption) == .released)
    }

    @Test func theOtherOptionKeyDoesNotCount() {
        var tracker = FinderHoldTracker()
        #expect(tracker.flagsChanged(leftOption, key: .rightOption) == .none)
        #expect(tracker.flagsChanged(0, key: .rightOption) == .none)
    }

    @Test func holdingBothOptionKeysIsNotAPress() {
        var tracker = FinderHoldTracker()
        #expect(tracker.flagsChanged(0x60 | 0x80000, key: .rightOption) == .none)
    }

    @Test func anotherModifierSpoilsTheHold() {
        var tracker = FinderHoldTracker()
        _ = tracker.flagsChanged(rightOption, key: .rightOption)
        let withCommand = rightOption | 0x100000 | 0x8
        #expect(tracker.flagsChanged(withCommand, key: .rightOption) == .disturbed)
        #expect(tracker.flagsChanged(withCommand, key: .rightOption) == .none)
        // Back to the key alone: still the same hold, so it is not a new press.
        #expect(tracker.flagsChanged(rightOption, key: .rightOption) == .none)
        #expect(tracker.flagsChanged(0, key: .rightOption) == .released)
    }

    @Test func aModifierAlreadyDownMeansNoPress() {
        var tracker = FinderHoldTracker()
        let shiftThenOption = rightOption | 0x20000
        #expect(tracker.flagsChanged(shiftThenOption, key: .rightOption) == .none)
    }

    @Test func mouseUseWhileHeldSpoilsOnlyOnce() {
        var tracker = FinderHoldTracker()
        _ = tracker.flagsChanged(rightOption, key: .rightOption)
        #expect(tracker.otherInput() == .disturbed)
        #expect(tracker.otherInput() == .none)
        #expect(tracker.flagsChanged(0, key: .rightOption) == .released)
        #expect(tracker.otherInput() == .none)
    }

    @Test func rightCommandIsRecognisedByItsOwnBits() {
        var tracker = FinderHoldTracker()
        #expect(tracker.flagsChanged(0x10 | 0x100000, key: .rightCommand) == .pressed)
    }
}

@Suite("Finder settings")
struct WindowFinderSettingsTests {
    @Test func olderFilesWithoutTheSettingGetDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"schemaVersion":2}"#.utf8))
        #expect(config.windowFinder == WindowFinderSettings())
        #expect(config.windowFinder.isEnabled)
    }

    @Test func unknownKeyAndWildDelayFallBackSafely() throws {
        let json = #"{"windowFinder":{"key":"hyper","delay":99,"showPreviews":false}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).sanitized()
        #expect(config.windowFinder.key == .rightOption)
        #expect(config.windowFinder.delay == WindowFinderSettings.delayRange.upperBound)
        #expect(!config.windowFinder.showPreviews)
    }

    @Test func findWindowActionSurvivesSaving() throws {
        let data = try JSONEncoder().encode(Action.findWindow)
        #expect(try JSONDecoder().decode(Action.self, from: data) == .findWindow)
        #expect(Action.findWindow.isAllowed(for: .click))
        #expect(!Action.findWindow.isAllowed(for: .drag))
    }
}
