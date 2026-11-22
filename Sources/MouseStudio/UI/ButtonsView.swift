import SwiftUI

struct ButtonsView: View {
    @EnvironmentObject private var model: AppModel
    @LocalState private var composing: CapturedTrigger?
    @LocalState private var confirmingRestore = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                PermissionBanner()
                CaptureArea { composing = $0 }
                RuleGroups()
                Button("Restore Defaults…") { confirmingRestore = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: Theme.pageWidth)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $composing) { trigger in
            RuleComposerSheet(initial: trigger)
        }
        .confirmationDialog("Restore default gestures and scrolling settings?", isPresented: $confirmingRestore) {
            Button("Restore Defaults", role: .destructive) { model.store.restoreDefaults() }
        } message: {
            Text("Your current gestures will be replaced. You can export them first from the General tab.")
        }
    }
}

extension CapturedTrigger: Identifiable {
    var id: String { "\(button.number)-\(modifiers.rawValue)-\(interaction.rawValue)" }
}

private struct RuleGroups: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let groups = model.store.groupedRules()
        if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "computermouse")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No gestures yet")
                    .font(.headline)
                Text("Your mouse works exactly as macOS defines it. Add a gesture above to change that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 16) {
                ForEach(groups, id: \.button) { group in
                    Card {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                IconTile(symbol: "computermouse.fill", tint: .gray, size: 24)
                                Text(group.button.name).font(.headline)
                                Spacer()
                                Text(group.rules.count == 1 ? String(localized: "1 gesture") : String(localized: "\(group.rules.count) gestures"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            ForEach(group.rules) { rule in
                                Divider().padding(.leading, 14)
                                RuleRow(rule: rule)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RuleRow: View {
    let rule: Rule
    @EnvironmentObject private var model: AppModel
    @LocalState private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                KeyCaps(modifiers: rule.trigger.modifiers)
                TriggerLabel(interaction: rule.trigger.interaction)
            }
            Spacer(minLength: 8)

            ActionMenu(interaction: rule.trigger.interaction, current: rule.action) { action in
                model.store.setAction(action, forRule: rule.id)
            }

            Toggle("Enabled", isOn: Binding(
                get: { rule.isEnabled },
                set: { model.setRule(rule, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                model.store.removeRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0.35)
            .help("Remove this gesture")
            .accessibilityLabel("Remove gesture")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}

/// "Click and **Drag**": the gesture with its last word emphasised.
struct TriggerLabel: View {
    let interaction: Interaction

    var body: some View {
        gesture.font(.body)
    }

    private var gesture: Text {
        Text(interaction.title).fontWeight(.medium)
    }
}
