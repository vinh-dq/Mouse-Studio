import AppKit

/// A made-up set of windows for taking screenshots of the finder without showing anyone's real windows.
/// Only a debug build reacts to it (`MOUSESTUDIO_DEMO`); a release build never does.
enum FinderDemo {
    #if DEBUG
    static let isActive = ProcessInfo.processInfo.environment["MOUSESTUDIO_DEMO"] != nil
    #else
    static let isActive = false
    #endif
}

#if DEBUG
@MainActor
extension FinderDemo {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Shows the finder with made-up windows. `MOUSESTUDIO_DEMO` is "finder" for that, anything else for the
    /// settings window only. Also: `_LAYOUT` (split/cards), `_QUERY`, `_LANG` (vi), `_BACKDROP` (white/dark), `_MODE` (tabs).
    static func run() {
        if environment["MOUSESTUDIO_DEMO"] != "finder" {
            // The settings window, tall enough to show most of a tab.
            NSApp.windows.first { $0.title == "Mouse Studio" }?.setContentSize(NSSize(width: 580, height: 1000))
            return
        }
        let vietnamese = environment["MOUSESTUDIO_DEMO_LANG"] == "vi"
        NSApp.windows.filter { !($0 is FinderPanel) }.forEach { $0.orderOut(nil) }
        showBackdrop()
        let (items, pictures) = windows(vietnamese: vietnamese)
        let layout = FinderLayout(rawValue: environment["MOUSESTUDIO_DEMO_LAYOUT"] ?? "") ?? .split
        let tabs = environment["MOUSESTUDIO_DEMO_MODE"] == "tabs" ? demoTabs() : nil
        WindowFinder.shared.showDemo(items: items, pictures: pictures, layout: layout, query: environment["MOUSESTUDIO_DEMO_QUERY"] ?? "", tabs: tabs)
    }

    /// Made-up tabs in two Chrome windows and one Safari window, for screenshots (`MOUSESTUDIO_DEMO_MODE=tabs`).
    private static func demoTabs() -> [WindowItem] {
        let chrome = icon("/Applications/Google Chrome.app")
        let safari = icon("/Applications/Safari.app")
        struct Spec { var title: String; var url: String }
        let windows: [(app: String, id: String, family: BrowserFamily, name: String, active: Int, icon: NSImage, tabs: [Spec])] = [
            ("Google Chrome", "com.google.Chrome", .chromium, "", 2, chrome, [
                Spec(title: "Sprint 50 Backlog - Google Sheets", url: "https://docs.google.com/spreadsheets/d/1abc/edit"),
                Spec(title: "Pull requests · acme/web-automation", url: "https://github.com/acme/web-automation/pulls"),
                Spec(title: "Test Case - Google Sheets", url: "https://docs.google.com/spreadsheets/d/2def/edit"),
                Spec(title: "Dashboard | Portal", url: "https://portal.example.com/"),
                Spec(title: "Bug #107 · Issue · acme/backlog", url: "https://github.com/acme/backlog/issues/107"),
            ]),
            ("Google Chrome", "com.google.Chrome", .chromium, "research", 1, chrome, [
                Spec(title: "Claude Certified Architect — Practice Exam", url: "https://examcademy.com/exams/anthropic/cca-f/1"),
                Spec(title: "Meeting plan - Google Gemini", url: "https://gemini.google.com/app/9ea5"),
                Spec(title: "Swift Concurrency — Apple Developer", url: "https://developer.apple.com/documentation/swift/concurrency"),
            ]),
            ("Safari", "com.apple.Safari", .safari, "", 1, safari, [
                Spec(title: "Mouse Studio — Release notes", url: "https://example.com/mouse-studio/releases"),
                Spec(title: "Weather", url: "https://weather.example.org/"),
            ]),
        ]
        var items: [WindowItem] = []
        for (windowIndex, window) in windows.enumerated() {
            for (index, spec) in window.tabs.enumerated() {
                let tab = BrowserTab(
                    family: window.family, windowID: 100 + windowIndex, windowNumber: window.app == "Safari" ? 1 : windowIndex + 1,
                    windowCount: window.app == "Safari" ? 1 : 2, windowName: window.name, windowTabCount: window.tabs.count,
                    tabIndex: index + 1, tabKey: "\(index + 1)", url: spec.url, isActive: window.active == index + 1, isPrivate: false
                )
                items.append(WindowItem(
                    id: "tab\(windowIndex)-\(index)", pid: Int32(10 + windowIndex), windowID: nil, appName: window.app, bundleID: window.id,
                    title: spec.title, isMinimized: false, isOnOtherSpace: false, isAppHidden: false, element: nil, size: nil,
                    icon: window.icon, tab: tab
                ))
            }
        }
        return items
    }

    /// A plain soft backdrop, so a screenshot shows the glass over something neutral and not the real desktop.
    private static func showBackdrop() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        let image = NSImage(size: screen.frame.size, flipped: false) { rect in
            switch environment["MOUSESTUDIO_DEMO_BACKDROP"] {
            case "white":
                NSColor.white.setFill()
                rect.fill()
                return true
            case "stripes":
                NSColor.white.setFill()
                rect.fill()
                for i in 0..<Int(rect.width / 60) {
                    [NSColor.systemRed, .systemBlue, .systemGreen, .systemOrange][i % 4].setFill()
                    NSRect(x: CGFloat(i) * 60, y: 0, width: 30, height: rect.height).fill()
                }
                return true
            case "dark":
                NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
                rect.fill()
                return true
            default: break
            }
            NSGradient(colors: [
                NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.86, alpha: 1),
                NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.82, alpha: 1),
                NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.62, alpha: 1),
            ])?.draw(in: rect, angle: 35)
            return true
        }
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = image
        window.contentView = view
        window.orderFront(nil)
    }

    private static func icon(_ path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    private static func windows(vietnamese vi: Bool) -> ([WindowItem], [String: NSImage]) {
        struct Spec { var app: String; var path: String; var title: String; var place: String; var tint: NSColor; var layout: Int }
        let desktop1 = vi ? "Màn hình nền 1" : "Desktop 1"
        let desktop2 = vi ? "Màn hình nền 2" : "Desktop 2"
        let full = vi ? "Toàn màn hình" : "Full screen"
        let specs: [Spec] = [
            Spec(app: "Terminal", path: "/System/Applications/Utilities/Terminal.app", title: "build — zsh", place: desktop1, tint: .darkGray, layout: 3),
            Spec(app: "Safari", path: "/Applications/Safari.app", title: vi ? "Mouse Studio — Ghi chú phát hành" : "Mouse Studio — Release notes", place: desktop1, tint: .systemBlue, layout: 0),
            Spec(app: vi ? "Ghi chú" : "Notes", path: "/System/Applications/Notes.app", title: vi ? "Ghi chú cuộc họp" : "Meeting notes", place: desktop1, tint: .systemYellow, layout: 1),
            Spec(app: "Mail", path: "/System/Applications/Mail.app", title: vi ? "Hộp thư đến (3)" : "Inbox (3)", place: desktop2, tint: .systemTeal, layout: 2),
            Spec(app: vi ? "Lịch" : "Calendar", path: "/System/Applications/Calendar.app", title: vi ? "Tháng 11, 2026" : "November 2026", place: desktop2, tint: .systemRed, layout: 4),
            Spec(app: "Finder", path: "/System/Library/CoreServices/Finder.app", title: vi ? "Tải xuống" : "Downloads", place: desktop1, tint: .systemIndigo, layout: 2),
            Spec(app: "Preview", path: "/System/Applications/Preview.app", title: vi ? "Báo cáo quý 3.pdf" : "Quarterly report.pdf", place: desktop2, tint: .systemOrange, layout: 1),
            Spec(app: vi ? "Ảnh" : "Photos", path: "/System/Applications/Photos.app", title: vi ? "Thư viện" : "Library", place: desktop1, tint: .systemPink, layout: 4),
            Spec(app: vi ? "Nhạc" : "Music", path: "/System/Applications/Music.app", title: vi ? "Đang phát" : "Now Playing", place: full, tint: .systemPurple, layout: 0),
        ]
        var items: [WindowItem] = []
        var pictures: [String: NSImage] = [:]
        for (index, spec) in specs.enumerated() {
            let id = "demo\(index)"
            items.append(WindowItem(
                id: id, pid: 1, windowID: nil, appName: spec.app, bundleID: spec.path, title: spec.title,
                isMinimized: spec.app == "Preview", isOnOtherSpace: false, isAppHidden: false, element: nil, size: nil,
                icon: icon(spec.path), place: spec.place
            ))
            pictures[id] = mockWindow(tint: spec.tint, layout: spec.layout)
        }
        return (items, pictures)
    }

    /// A drawn stand-in for a window: title bar, sidebar or header, blocks and lines.
    private static func mockWindow(tint: NSColor, layout: Int) -> NSImage {
        let size = NSSize(width: 800, height: 500)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedWhite: layout == 3 ? 0.12 : 0.98, alpha: 1).setFill()
            rect.fill()
            let ink = NSColor(calibratedWhite: layout == 3 ? 0.75 : 0.82, alpha: 1)
            // Title bar and traffic lights.
            NSColor(calibratedWhite: layout == 3 ? 0.2 : 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 44).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(i) * 22, y: 14, width: 14, height: 14)).fill()
            }
            func block(_ r: NSRect, _ color: NSColor, radius: CGFloat = 8) {
                color.setFill()
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
            func lines(x: CGFloat, y: CGFloat, width: CGFloat, count: Int) {
                for i in 0..<count {
                    block(NSRect(x: x, y: y + CGFloat(i) * 26, width: i % 3 == 2 ? width * 0.6 : width, height: 10), ink, radius: 5)
                }
            }
            switch layout {
            case 0: // header image and text
                block(NSRect(x: 40, y: 80, width: rect.width - 80, height: 150), tint.withAlphaComponent(0.85), radius: 14)
                lines(x: 40, y: 260, width: rect.width - 80, count: 7)
            case 1: // sidebar and text
                block(NSRect(x: 0, y: 44, width: 190, height: rect.height - 44), tint.withAlphaComponent(0.25), radius: 0)
                for i in 0..<6 { block(NSRect(x: 20, y: 70 + CGFloat(i) * 44, width: 150, height: 28), tint.withAlphaComponent(i == 1 ? 0.7 : 0.3), radius: 7) }
                lines(x: 230, y: 90, width: rect.width - 290, count: 12)
            case 2: // list rows
                for i in 0..<8 {
                    block(NSRect(x: 30, y: 70 + CGFloat(i) * 52, width: 44, height: 36), tint.withAlphaComponent(0.55), radius: 8)
                    lines(x: 94, y: 76 + CGFloat(i) * 52, width: rect.width - 140, count: 1)
                    block(NSRect(x: 94, y: 96 + CGFloat(i) * 52, width: 220, height: 8), ink.withAlphaComponent(0.6), radius: 4)
                }
            case 3: // terminal
                for i in 0..<14 {
                    block(NSRect(x: 28, y: 70 + CGFloat(i) * 28, width: CGFloat(120 + (i * 53) % 420), height: 10), i % 5 == 0 ? tint.withAlphaComponent(0.9) : NSColor.systemGreen.withAlphaComponent(0.7), radius: 5)
                }
            default: // grid
                for row in 0..<3 {
                    for column in 0..<4 {
                        block(NSRect(x: 30 + CGFloat(column) * 185, y: 70 + CGFloat(row) * 140, width: 170, height: 125), tint.withAlphaComponent(0.25 + 0.15 * CGFloat((row + column) % 3)), radius: 12)
                    }
                }
            }
            return true
        }
    }
}

@MainActor
extension WindowFinder {
    func showDemo(items: [WindowItem], pictures: [String: NSImage], layout: FinderLayout, query: String, tabs: [WindowItem]? = nil) {
        var demo = WindowFinderSettings()
        demo.layout = layout
        apply(demo)
        if let tabs {
            show(items, byHold: false, mode: .tabs, tabs: tabs)
            model.replace(tabs: tabs, notices: [])
        } else {
            show(items, byHold: true)
        }
        for (id, image) in pictures { model.setThumbnail(image, for: id) }
        model.setPreview(nil)
        if !query.isEmpty { model.type(query) }
    }
}
#endif
