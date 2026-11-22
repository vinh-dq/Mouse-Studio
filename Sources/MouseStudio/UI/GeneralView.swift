import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralView: View {
    @EnvironmentObject private var model: AppModel
    @LocalState private var launchAtLogin = LoginItem.isEnabled
    @LocalState private var confirmingReset = false
    @LocalState private var language = AppLanguage.current
    @LocalState private var restartNeeded = false

    var body: some View {
        SettingsPage {
            SettingsGroup(footer: "Turning this off hands your mouse back to macOS immediately.") {
                HStack(spacing: 14) {
                    IconTile(symbol: "computermouse.fill", tint: model.statusColor, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mouse Studio").font(.system(size: 16, weight: .semibold))
                        HStack(spacing: 6) {
                            Circle().fill(model.statusColor).frame(width: 7, height: 7)
                            Text(model.statusTitle).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("Enable Mouse Studio", isOn: Binding(
                        get: { model.store.config.isEnabled },
                        set: { model.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(16)
            }

            PermissionBanner()

            SettingsGroup(title: "Startup") {
                ToggleRow(title: "Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
            }

            SettingsGroup(title: "Language", footer: restartNeeded ? "Restart Mouse Studio to change the language." : nil) {
                PickerRow(title: "Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { _, newValue in
                    newValue.apply()
                    restartNeeded = true
                }
                if restartNeeded {
                    SettingsDivider()
                    ActionRow(title: "Restart Now", symbol: "arrow.clockwise", action: AppLanguage.relaunch)
                }
            }

            SettingsGroup(
                title: "Behavior",
                footer: "Smooth zoom and the interactive Spaces swipe use parts of macOS that Apple doesn't document. If an update to macOS ever breaks them, turn this off: zoom then uses ⌘+ and ⌘−, and Spaces use their keyboard shortcuts."
            ) {
                ToggleRow(title: "Smooth zoom and Spaces swipe", isOn: model.store.binding(\.usePrivateFeatures))
            }

            SettingsGroup(
                title: "Diagnostics",
                footer: "If something misbehaves, copy this right after it happens and share it. It lists recent button, wheel and zoom events and what Mouse Studio did with them: button numbers, scroll amounts and the name of the app a zoom was sent to, never pointer positions, keys or what is on screen. Nothing is sent anywhere."
            ) {
                ActionRow(title: "Copy Recent Mouse Events", symbol: "doc.on.doc") { model.copyDiagnostics() }
            }

            SettingsGroup(
                title: "Configuration",
                footer: "Changes are saved automatically on this Mac. Export a copy to back up your rules or move them to another Mac."
            ) {
                ActionRow(title: "Export Configuration…", symbol: "square.and.arrow.up", action: exportConfig)
                SettingsDivider()
                ActionRow(title: "Import Configuration…", symbol: "square.and.arrow.down", action: importConfig)
                SettingsDivider()
                ActionRow(title: "Reset to Defaults…", symbol: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
            }
        }
        .confirmationDialog("Reset all rules and scrolling settings?", isPresented: $confirmingReset) {
            Button("Reset to Defaults", role: .destructive) { model.store.restoreDefaults() }
        } message: {
            Text("Your current rules will be replaced. Export them first if you want to keep a copy.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            model.issue = "Couldn't change “Open at login”: \(error.localizedDescription)"
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Mouse Studio Configuration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportConfig(to: url)
        } catch {
            model.issue = "Couldn't export the configuration: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            model.issue = try model.store.importConfig(from: url)
        } catch {
            model.issue = error.localizedDescription
        }
    }
}
