import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps Mouse Studio leaves alone while they are in front: games, remote desktops, virtual machines.
struct AppsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsPage {
            PermissionBanner()
            SettingsGroup(
                title: "Leave These Apps Alone",
                footer: "While one of these apps is in front, your mouse works exactly as macOS defines it: no rules, no smooth scrolling, no zoom. Useful for games, remote desktops and virtual machines."
            ) {
                let apps = model.store.config.excludedApps
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { SettingsDivider() }
                    SettingRow(title: app.name, detail: app.bundleID) {
                        HStack(spacing: 12) {
                            AppIcon(bundleID: app.bundleID)
                            Button {
                                model.removeExcludedApp(app.bundleID)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Stop leaving this app alone")
                            .accessibilityLabel("Remove \(app.name)")
                        }
                    }
                }
                if apps.isEmpty {
                    Text("No apps yet. Mouse Studio is active everywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SettingsDivider()
                ActionRow(title: "Choose App…", symbol: "plus.circle.fill", action: chooseApp)
                SettingsDivider()
                RunningAppsRow()
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            model.addExcludedApp(bundleID: id, name: name)
        }
    }
}

/// "Add a running app" as a pop-up menu, so the app doesn't have to be found in Finder.
private struct RunningAppsRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !model.isExcluded($0.bundleIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        Menu {
            ForEach(candidates, id: \.processIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                    if let id = app.bundleIdentifier { model.addExcludedApp(bundleID: id, name: app.localizedName ?? id) }
                }
            }
            if candidates.isEmpty { Text("No other apps are open") }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "app.badge")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(Color.accentColor)
                Text("Add a Running App").font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}

struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "questionmark.app").frame(width: 26, height: 26).foregroundStyle(.secondary)
        }
    }
}
