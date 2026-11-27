import SwiftUI

extension View {
    /// Liquid Glass where macOS has it, a blurred material before that.
    @ViewBuilder
    func finderGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                // A bright rim at the top and a faint dark line outside give the edge of the glass its shape,
                // also over a white page where glass alone would melt into the background.
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.7), .white.opacity(0.06), .white.opacity(0.32)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .overlay(shape.inset(by: -0.5).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        }
    }
}

struct FinderView: View {
    @ObservedObject var model: FinderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FinderMetrics.cornerRadius, style: .continuous)
        VStack(spacing: 0) {
            SearchHeader(model: model)
            Divider().opacity(0.2)
            Group {
                if model.results.isEmpty {
                    EmptyState(model: model)
                } else if model.mode == .tabs {
                    TabsBody(model: model)
                } else if model.layout == .split {
                    SplitBody(model: model)
                } else if model.isPreviewing, let item = model.selected {
                    PreviewPane(item: item, image: model.previewImage ?? model.thumbnails[item.id])
                } else {
                    ResultsGrid(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.mode == .tabs, let notice = model.tabNotices.first(where: { if case .needsAccess = $0 { true } else { false } }) ?? model.tabNotices.first {
                Divider().opacity(0.2)
                NoticeBar(notice: notice)
            }
            Divider().opacity(0.2)
            HintBar(model: model)
        }
        .frame(width: model.panelWidth, height: model.contentHeight)
        .clipShape(shape)
        .finderGlass(cornerRadius: FinderMetrics.cornerRadius)
        .shadow(color: .black.opacity(0.26), radius: 26, y: 12)
        .padding(FinderMetrics.inset)
        .scaleEffect(model.isVisible || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(model.isVisible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.3, bounce: 0.12), value: model.isVisible)
        .animation(.snappy(duration: 0.2), value: model.contentHeight)
        .animation(.snappy(duration: 0.2), value: model.panelWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Search

private struct SearchHeader: View {
    @ObservedObject var model: FinderModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(model.mode == .tabs ? "Type to find a tab" : "Type to find a window")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 1) {
                    Text(model.query)
                        .font(.system(size: 22))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Caret()
                }
            }
            Spacer(minLength: 8)
            if model.tabsEnabled { ModeSwitch(model: model) }
            Text("\(model.results.count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(minWidth: 28, minHeight: 22)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: model.results.count)
        }
        .padding(.horizontal, 22)
        .frame(height: FinderMetrics.searchHeight)
    }
}

private struct Caret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: 24)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - Results

private struct ResultsGrid: View {
    @ObservedObject var model: FinderModel

    private let columns = Array(
        repeating: GridItem(.fixed(FinderMetrics.cardWidth), spacing: FinderMetrics.spacing),
        count: FinderMetrics.columns
    )

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: FinderMetrics.spacing) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        WindowCard(item: item, query: model.query, thumbnail: model.thumbnails[item.id], showsPicture: model.showsPictures, isSelected: index == model.selection)
                            .id(item.id)
                            .onContinuousHover { phase in
                                if case .active = phase { model.hover(index) }
                            }
                            .onTapGesture { model.onCommit?(index) }
                    }
                }
                .padding(FinderMetrics.gridPadding)
            }
            .onChange(of: model.selection) { _, _ in
                guard let id = model.selected?.id else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct WindowCard: View {
    let item: WindowItem
    let query: String
    let thumbnail: NSImage?
    let showsPicture: Bool
    let isSelected: Bool

    var body: some View {
        let pad = FinderMetrics.cardPadding
        let thumbWidth = FinderMetrics.cardWidth - 2 * pad
        VStack(alignment: .leading, spacing: pad) {
            Thumbnail(item: item, image: thumbnail, showsPicture: showsPicture)
                .frame(width: thumbWidth, height: FinderMetrics.thumbHeight)
            VStack(alignment: .leading, spacing: 1) {
                Text(Highlight.title(item.title, query: query))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: thumbWidth, height: FinderMetrics.titleHeight - 4, alignment: .topLeading)
        }
        .padding(pad)
        .frame(width: FinderMetrics.cardWidth, height: FinderMetrics.cardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct Thumbnail: View {
    let item: WindowItem
    let image: NSImage?
    let showsPicture: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            shape.fill(Color.primary.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .padding(6)
                }
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .opacity(showsPicture ? 0.45 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) { badges.padding(5) }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .clipShape(shape)
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if item.isMinimized { Badge(symbol: "minus", text: "Minimized") }
            if item.isOnOtherSpace { Badge(symbol: "rectangle.on.rectangle", text: "Other desktop") }
            if item.isAppHidden && !item.isMinimized { Badge(symbol: "eye.slash", text: "Hidden") }
        }
    }
}

private struct Badge: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9.5, weight: .medium))
        }
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Preview and empty state

private struct PreviewPane: View {
    let item: WindowItem
    let image: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(item.appName).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                } else if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96).opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .transition(.opacity)
    }
}

private struct EmptyState: View {
    @ObservedObject var model: FinderModel

    var body: some View {
        VStack(spacing: 8) {
            if model.isLoading && model.items.isEmpty {
                ProgressView().controlSize(.small)
                Text(model.mode == .tabs ? "Reading your tabs…" : "Looking for windows…")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                if model.items.isEmpty {
                    Text(model.mode == .tabs ? "No browser tabs found" : "No windows are open").font(.system(size: 14, weight: .medium))
                    if model.mode == .tabs {
                        Text("Open a tab in Safari, Chrome, Edge, Brave or another Chromium browser.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    Text(model.mode == .tabs ? "No tab matches “\(model.query)”" : "No window matches “\(model.query)”").font(.system(size: 14, weight: .medium))
                    Text(model.mode == .tabs ? "Try part of the title or the address." : "Try part of the app name or the title.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        if model.items.isEmpty { return model.mode == .tabs ? "square.on.square" : "macwindow" }
        return "text.magnifyingglass"
    }
}

// MARK: - Split layout

private struct SplitBody: View {
    @ObservedObject var model: FinderModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                            WindowRow(item: item, query: model.query, isSelected: index == model.selection)
                                .id(item.id)
                                .onContinuousHover { phase in
                                    if case .active = phase { model.hover(index) }
                                }
                                .onTapGesture { model.onCommit?(index) }
                        }
                    }
                    .padding(FinderMetrics.listPadding)
                }
                .onChange(of: model.selection) { _, _ in
                    guard let id = model.selected?.id else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            .frame(width: FinderMetrics.listWidth)
            Divider().opacity(0.2)
            if let item = model.selected {
                DetailPane(item: item, image: model.previewImage ?? model.thumbnails[item.id], showsPictures: model.showsPictures)
            }
        }
    }
}

private struct WindowRow: View {
    let item: WindowItem
    let query: String
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 11) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .opacity(item.isMinimized || item.isAppHidden ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(Highlight.title(item.title, query: query))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isMinimized {
                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: FinderMetrics.rowHeight - 2)
        .background(shape.fill(isSelected ? Color.accentColor.opacity(0.17) : .clear))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(isSelected ? 0.22 : 0), lineWidth: 0.75))
        .contentShape(shape)
        .animation(.snappy(duration: 0.12), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The large picture of the chosen window, with its name above it.
private struct DetailPane: View {
    let item: WindowItem
    let image: NSImage?
    let showsPictures: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 15, height: 15) }
                    Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if item.isMinimized { Badge(symbol: "minus", text: "Minimized") }
                    if item.isAppHidden && !item.isMinimized { Badge(symbol: "eye.slash", text: "Hidden") }
                }
            }
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                        .transition(.opacity)
                } else if let icon = item.icon {
                    VStack(spacing: 8) {
                        Image(nsImage: icon).resizable().frame(width: 84, height: 84).opacity(0.9)
                        if showsPictures { Text("No picture available").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: image == nil)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The typed letters, drawn stronger inside the title.
enum Highlight {
    static func title(_ title: String, query: String) -> AttributedString {
        var text = AttributedString(title)
        let positions = WindowSearch.matchedPositions(in: title, query: query)
        guard !positions.isEmpty else { return text }
        let indices = Array(text.characters.indices)
        for offset in positions.sorted() where indices.indices.contains(offset) {
            let index = indices[offset]
            let next = text.characters.index(after: index)
            text[index..<next].foregroundColor = .accentColor
            text[index..<next].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}

extension WindowItem {
    /// "Safari · Desktop 2" — the app, and where the window is when that is worth saying.
    var subtitle: String {
        [appName, place].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Hints

private struct HintBar: View {
    @ObservedObject var model: FinderModel

    var body: some View {
        HStack(spacing: 16) {
            if model.mode == .windows, let releaseKey = model.releaseKey {
                Hint(keys: [releaseKey], text: "Release to switch")
            } else {
                Hint(keys: ["↩"], text: "Switch")
            }
            Hint(keys: model.mode == .tabs ? ["↑", "↓"] : ["↑", "↓", "←", "→"], text: "Select")
            if model.mode == .tabs { Hint(keys: ["⌘W"], text: "Close") }
            if model.mode == .windows {
                if model.layout == .cards { Hint(keys: ["Space"], text: "Preview") }
                Hint(keys: ["⌘W"], text: "Close")
            }
            if model.tabsEnabled { Hint(keys: ["⇥"], text: model.mode == .tabs ? "Windows" : "Tabs") }
            Hint(keys: ["esc"], text: "Cancel")
        }
        .frame(maxWidth: .infinity)
        .frame(height: FinderMetrics.hintHeight)
    }
}

private struct Hint: View {
    let keys: [String]
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }
}


// MARK: - Windows or tabs

/// Two small buttons at the right of the search line. The chosen one is a pill that slides across.
private struct ModeSwitch: View {
    @ObservedObject var model: FinderModel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            segment(.windows, title: "Windows", symbol: "macwindow")
            segment(.tabs, title: "Tabs", symbol: "square.on.square")
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .animation(.snappy(duration: 0.22), value: model.mode)
    }

    private func segment(_ mode: FinderMode, title: LocalizedStringKey, symbol: String) -> some View {
        let isSelected = model.mode == mode
        return Button { model.onSetMode?(mode) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(0.13))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Tabs

private struct TabsBody: View {
    @ObservedObject var model: FinderModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                            VStack(spacing: 2) {
                                if let header = model.groupHeaders[item.id] {
                                    TabGroupHeaderRow(header: header, isFirst: index == 0)
                                }
                                TabRow(item: item, query: model.query, isSelected: index == model.selection)
                                    .onContinuousHover { phase in
                                        if case .active = phase { model.hover(index) }
                                    }
                                    .onTapGesture { model.onCommit?(index) }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(FinderMetrics.listPadding)
                }
                .onAppear {
                    guard let id = model.selected?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
                .onChange(of: model.selected?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            .frame(width: FinderMetrics.listWidth)
            Divider().opacity(0.2)
            if let item = model.selected, item.tab != nil {
                TabDetailPane(item: item)
            }
        }
    }
}

private struct TabGroupHeaderRow: View {
    let header: TabGroupHeader
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon = header.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
            }
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(header.count == 1 ? String(localized: "1 tab") : String(localized: "\(header.count) tabs"))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: FinderMetrics.groupHeaderHeight - (isFirst ? 6 : 0), alignment: .bottom)
        .padding(.bottom, 4)
        .padding(.top, isFirst ? 0 : 0)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        [header.browser, header.window, header.name.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A coloured tile with the first letter of the site: browsers don't hand out the pictures of sites.
private struct SiteTile: View {
    let host: String
    let size: CGFloat
    var isPrivate = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        let hue = Self.hue(of: host)
        ZStack {
            shape.fill(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.58, brightness: 0.95), Color(hue: (hue + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.72, brightness: 0.74)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            if isPrivate {
                Image(systemName: "eye.slash.fill").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
            } else {
                Text(Self.letter(of: host))
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
    }

    /// The name of the site, without "www" or the ending: "docs.google.com" → "google".
    private static func mainLabel(of host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host }
        return parts[parts.count - 2]
    }

    static func letter(of host: String) -> String {
        guard let first = mainLabel(of: host).first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(first).uppercased()
    }

    /// The same site always gets the same colour, and subdomains of one site match.
    static func hue(of host: String) -> Double {
        var hash: UInt32 = 5381
        for byte in mainLabel(of: host).lowercased().utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return Double(hash % 360) / 360
    }
}

private struct TabRow: View {
    let item: WindowItem
    let query: String
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tab = item.tab
        HStack(spacing: 11) {
            SiteTile(host: tab?.host ?? "", size: 34, isPrivate: tab?.isPrivate == true)
                .overlay(alignment: .bottomTrailing) {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 15, height: 15)
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(Highlight.title(item.title, query: query))
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if tab?.isActive == true {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .help("Current tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: FinderMetrics.rowHeight - 2)
        .background(shape.fill(isSelected ? Color.accentColor.opacity(0.17) : .clear))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(isSelected ? 0.22 : 0), lineWidth: 0.75))
        .contentShape(shape)
        .animation(.snappy(duration: 0.12), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The site; while searching, which window it is in too, since the results no longer sit under their window
    /// (the browser is told by the small icon on the tile).
    private var subtitle: String {
        guard let tab = item.tab else { return item.subtitle }
        var parts = [tab.host.isEmpty ? item.appName : tab.host]
        if !query.isEmpty, tab.windowCount > 1 { parts.append(String(localized: "Window \(tab.windowNumber)")) }
        return parts.joined(separator: " · ")
    }
}

/// What is known about the chosen tab: its site, full address, and where it is.
private struct TabDetailPane: View {
    let item: WindowItem

    var body: some View {
        if let tab = item.tab {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    SiteTile(host: tab.host, size: 56, isPrivate: tab.isPrivate)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if !tab.host.isEmpty {
                            Text(tab.host).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if !tab.url.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Address").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
                        Text(tab.url)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .truncationMode(.middle)
                    }
                }
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 9) {
                    DetailLine(symbol: nil, icon: item.icon, text: item.appName)
                    DetailLine(symbol: "macwindow", icon: nil, text: windowText(tab))
                    DetailLine(symbol: "square.on.square", icon: nil, text: String(localized: "Tab \(tab.tabIndex) of \(tab.windowTabCount)"))
                    if tab.isActive { DetailLine(symbol: "circle.fill", icon: nil, text: String(localized: "Current tab"), tint: .accentColor) }
                    if tab.isPrivate { DetailLine(symbol: "eye.slash", icon: nil, text: String(localized: "Private window")) }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func windowText(_ tab: BrowserTab) -> String {
        tab.windowCount > 1
            ? String(localized: "Window \(tab.windowNumber) of \(tab.windowCount)")
            : String(localized: "Only window")
    }
}

private struct DetailLine: View {
    let symbol: String?
    let icon: NSImage?
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                }
            }
            .frame(width: 16, height: 16)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
        }
    }
}

/// Shown when a browser couldn't be read: the permission is missing, or the browser didn't answer.
private struct NoticeBar: View {
    let notice: TabNotice

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if case .needsAccess = notice {
                Button("Open Settings") {
                    Automation.openSettings()
                    WindowFinder.shared.close()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: FinderMetrics.noticeHeight)
        .background(Color.orange.opacity(0.08))
    }

    private var message: String {
        switch notice {
        case .needsAccess(let name): String(localized: "Allow Mouse Studio to control \(name) to see its tabs.")
        case .notResponding(let name): String(localized: "\(name) didn't answer, so its tabs are missing.")
        }
    }
}
