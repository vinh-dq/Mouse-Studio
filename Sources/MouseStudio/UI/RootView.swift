import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case general, buttons, scrolling, windows, apps, devices, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .buttons: String(localized: "Buttons")
        case .scrolling: String(localized: "Scrolling")
        case .windows: String(localized: "Windows")
        case .apps: String(localized: "Apps")
        case .devices: String(localized: "Devices")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .buttons: "computermouse"
        case .scrolling: "arrow.up.and.down.and.arrow.left.and.right"
        case .windows: "macwindow.on.rectangle"
        case .apps: "square.dashed.inset.filled"
        case .devices: "computermouse.fill"
        case .about: "info.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    /// The last tab is remembered between launches.
    @AppStorage("selectedTab") private var selectedTab = AppTab.buttons.rawValue

    private var tab: Binding<AppTab> {
        Binding(get: { AppTab(rawValue: selectedTab) ?? .buttons }, set: { selectedTab = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab.wrappedValue {
                case .general: GeneralView()
                case .buttons: ButtonsView()
                case .scrolling: ScrollingView()
                case .windows: WindowsView()
                case .apps: AppsView()
                case .devices: DevicesView()
                case .about: AboutView()
                }
            }
            if let issue = model.issue {
                IssueBar(message: issue) { model.issue = nil }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabBar(selection: tab)
            }
        }
    }
}

private struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .frame(width: 60, height: 46)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selection == tab ? Color.primary.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
    }
}

private struct IssueBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("Dismiss", action: dismiss)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
