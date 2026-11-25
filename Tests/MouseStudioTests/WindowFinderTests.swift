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

private func window(_ id: String, _ app: String, _ title: String, bundle: String? = nil) -> WindowItem {
    WindowItem(id: id, pid: 1, windowID: nil, appName: app, bundleID: bundle ?? app, title: title, isMinimized: false,
               isOnOtherSpace: false, isAppHidden: false, element: nil, size: nil, icon: nil)
}

@Suite("Finder list")
@MainActor
struct FinderModelTests {
    private func model(layout: FinderLayout = .cards, count: Int = 10) -> FinderModel {
        let model = FinderModel()
        let items = (0..<count).map { window("w\($0)", "App \($0)", "Window \($0)") }
        model.begin(items: items, releaseKey: "⌥", showsPictures: false, layout: layout, maxVisibleRows: 3)
        return model
    }

    @Test func startsOnTheWindowBeforeTheCurrentOne() {
        #expect(model().selection == 1)
        #expect(!model().interacted)
    }

    @Test func typingNarrowsAndSelectsTheBestMatch() {
        let model = model()
        model.type("window 7")
        #expect(model.results.map(\.id) == ["w7"])
        #expect(model.selection == 0)
        #expect(model.interacted)
        model.backspace()
        #expect(model.query == "window ")
    }

    @Test func cardsMoveByRowsAndStayAtTheEnds() {
        let model = model(count: 10)
        model.moveRow(1)
        #expect(model.selection == 5)
        model.moveRow(1)
        #expect(model.selection == 9)
        model.moveRow(1)
        #expect(model.selection == 9)
        model.moveRow(-1)
        #expect(model.selection == 5)
    }

    @Test func theListMovesOneWindowAtATimeAndWraps() {
        let model = model(layout: .split, count: 3)
        model.moveRow(1)
        #expect(model.selection == 2)
        model.moveRow(1)
        #expect(model.selection == 0)
        model.move(-1)
        #expect(model.selection == 2)
    }

    @Test func closingAWindowKeepsTheSelectionNearby() {
        let model = model(count: 4)
        model.move(1)
        model.remove(id: "w2")
        #expect(model.results.count == 3)
        #expect(model.selection == 2)
    }

    @Test func aFreshListFollowsTheNewOrderUntilTheUserActs() {
        let model = model(count: 3)
        model.replace(items: [window("a", "A", "a"), window("b", "B", "b"), window("c", "C", "c")])
        #expect(model.selected?.id == "b")
        model.move(1)
        model.replace(items: [window("x", "X", "x"), window("c", "C", "c"), window("b", "B", "b")])
        #expect(model.selected?.id == "c")
    }

    @Test func previewOnlyExistsForCards() {
        let split = model(layout: .split)
        split.togglePreview()
        #expect(!split.isPreviewing)
        let cards = model()
        cards.togglePreview()
        #expect(cards.isPreviewing)
    }

    @Test func choicesFromHistoryRaiseAWindow() {
        let model = model(count: 3)
        model.boost = { _, item in item.id == "w2" ? 500 : 0 }
        model.type("window")
        #expect(model.results.first?.id == "w2")
    }
}

@Suite("Finder history")
struct FinderHistoryTests {
    private let sheets = FinderHistory.windowKey(bundleID: "chrome", title: "Budget - Google Sheets")
    private let chrome = FinderHistory.appKey(bundleID: "chrome")

    @Test func whatYouPickedForATextComesFirstNextTime() {
        var history = FinderHistory()
        history.record(query: "sh", windowKey: sheets, appKey: chrome)
        history.record(query: "SH", windowKey: sheets, appKey: chrome)
        #expect(history.boost(query: "sh", windowKey: sheets, appKey: chrome) > history.boost(query: "sh", windowKey: "w:other|x", appKey: "a:other"))
    }

    @Test func aRelatedTextCountsLessThanTheSameText() {
        var history = FinderHistory()
        history.record(query: "sh", windowKey: sheets, appKey: chrome)
        let same = history.boost(query: "sh", windowKey: sheets, appKey: chrome)
        let longer = history.boost(query: "she", windowKey: sheets, appKey: chrome)
        #expect(longer > 0 && longer < same)
        #expect(history.boost(query: "zz", windowKey: sheets, appKey: chrome) == 0)
    }

    @Test func nothingIsLearnedFromAnEmptyText() {
        var history = FinderHistory()
        history.record(query: "  ", windowKey: sheets, appKey: chrome)
        #expect(history == FinderHistory())
    }

    @Test func theBoostHasALimitAndTheHistoryStaysSmall() {
        var history = FinderHistory()
        for _ in 0..<50 { history.record(query: "a", windowKey: sheets, appKey: chrome) }
        #expect(history.boost(query: "a", windowKey: sheets, appKey: chrome) == 150)
        for number in 0..<400 { history.record(query: "q\(number)", windowKey: sheets, appKey: chrome) }
        #expect(history.picks.count <= 300)
    }

    @Test func titlesAreMatchedWithoutAccents() {
        #expect(WindowSearch.matchedPositions(in: "Báo cáo tháng", query: "bao thang") == [0, 1, 2, 8, 9, 10, 11, 12])
        #expect(WindowSearch.matchedPositions(in: "Safari", query: "").isEmpty)
    }
}
