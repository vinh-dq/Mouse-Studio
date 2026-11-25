import SwiftUI

extension View {
    /// Liquid Glass where macOS has it, a blurred material before that.
    @ViewBuilder
    func finderGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
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
            Divider().opacity(0.4)
            Group {
                if model.results.isEmpty {
                    EmptyState(model: model)
                } else if model.layout == .split {
                    SplitBody(model: model)
                } else if model.isPreviewing, let item = model.selected {
                    PreviewPane(item: item, image: model.previewImage ?? model.thumbnails[item.id])
                } else {
                    ResultsGrid(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.4)
            HintBar(releaseKey: model.releaseKey, layout: model.layout)
        }
        .frame(width: model.panelWidth, height: model.contentHeight)
        .clipShape(shape)
        .finderGlass(cornerRadius: FinderMetrics.cornerRadius)
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .padding(FinderMetrics.inset)
        .scaleEffect(model.isVisible || reduceMotion ? 1 : 0.96, anchor: .top)
        .opacity(model.isVisible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.3, bounce: 0.12), value: model.isVisible)
        .animation(.snappy(duration: 0.2), value: model.contentHeight)
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
                    Text("Type to find a window")
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
            Image(systemName: model.items.isEmpty ? "macwindow" : "text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            if model.items.isEmpty {
                Text("No windows are open").font(.system(size: 14, weight: .medium))
            } else {
                Text("No window matches “\(model.query)”").font(.system(size: 14, weight: .medium))
                Text("Try part of the app name or the title.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
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
            Divider().opacity(0.4)
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
        .background(shape.fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(isSelected ? 0.55 : 0), lineWidth: 1))
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
    let releaseKey: String?
    let layout: FinderLayout

    var body: some View {
        HStack(spacing: 16) {
            if let releaseKey {
                Hint(keys: [releaseKey], text: "Release to switch")
            } else {
                Hint(keys: ["↩"], text: "Switch")
            }
            Hint(keys: ["↑", "↓", "←", "→"], text: "Select")
            if layout == .cards { Hint(keys: ["Space"], text: "Preview") }
            Hint(keys: ["⌘W"], text: "Close")
            Hint(keys: ["⌘M"], text: "Minimize")
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
