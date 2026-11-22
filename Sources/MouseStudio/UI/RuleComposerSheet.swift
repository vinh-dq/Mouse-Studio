import SwiftUI

/// Creates a gesture as one sentence: "When I … do …".
/// With `fixedAction` the action is preset and only the trigger is chosen.
struct RuleComposerSheet: View {
    let initial: CapturedTrigger?
    var fixedAction: Action?

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @LocalState private var captured: CapturedTrigger?
    @LocalState private var action: Action?

    init(initial: CapturedTrigger?, fixedAction: Action? = nil) {
        self.initial = initial
        self.fixedAction = fixedAction
        _captured = LocalState(wrappedValue: initial)
        _action = LocalState(wrappedValue: fixedAction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(fixedAction == nil ? "New Gesture" : "New Drag Scroll Trigger")
                .font(.title3.weight(.semibold))

            if let trigger = captured {
                triggerCard(trigger)
                if fixedAction == nil {
                    actionSection(trigger)
                }
                notices(trigger)
            } else {
                CaptureArea(
                    title: "Press a mouse button",
                    activeTitle: "Now press a mouse button",
                    subtitle: "Move your pointer here, then press the button you want to use."
                ) { trigger in
                    // A preset drag action always uses the drag gesture, whatever gesture was captured.
                    captured = fixedAction == nil ? trigger : CapturedTrigger(button: trigger.button, modifiers: trigger.modifiers, interaction: .drag)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Gesture") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    // MARK: - Sections

    private func triggerCard(_ trigger: CapturedTrigger) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When I").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "computermouse.fill", tint: .accentColor, size: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                KeyCaps(modifiers: trigger.modifiers)
                                Text(trigger.button.name).font(.headline)
                            }
                            Text(fixedAction == nil ? trigger.interaction.title : "Click and Drag")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fixedAction == nil {
                            Menu("Gesture") {
                                Picker("Gesture", selection: interactionBinding) {
                                    ForEach(Interaction.allCases.filter { !(trigger.button.isPrimary && $0 == .doubleClick) }, id: \.self) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.inline)
                            }
                            .menuStyle(.button)
                            .fixedSize()
                        }
                        Button("Choose Again") { captured = nil }
                            .controlSize(.small)
                    }
                    Divider()
                    HStack(spacing: 6) {
                        Text("With keys")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(ModifierSet.ordered, id: \.name) { entry in
                            Toggle(isOn: modifierBinding(entry.modifier)) {
                                Text("\(entry.symbol) \(entry.name)")
                            }
                            .toggleStyle(.button)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func actionSection(_ trigger: CapturedTrigger) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Do").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                ActionGrid(interaction: trigger.interaction, selection: action) { action = $0 }
                    .padding(.vertical, 2)
                    .padding(.trailing, 6)
            }
            .frame(height: trigger.interaction == .drag || trigger.interaction == .scroll ? 90 : 300)
        }
    }

    @ViewBuilder
    private func notices(_ trigger: CapturedTrigger) -> some View {
        if let existing = model.store.existingRule(for: asTrigger(trigger)) {
            Label("This replaces the current gesture: \(existing.action.title).", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !asTrigger(trigger).isAllowed {
            Label("Hold at least one key (⌘ ⌥ ⌃ ⇧) with the left or right button, so you can't lock yourself out.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - State

    private var interactionBinding: Binding<Interaction> {
        Binding(
            get: { captured?.interaction ?? .click },
            set: { newValue in
                captured?.interaction = newValue
                if let current = action, !current.isAllowed(for: newValue) { action = nil }
            }
        )
    }

    private func modifierBinding(_ modifier: ModifierSet) -> Binding<Bool> {
        Binding(
            get: { captured?.modifiers.contains(modifier) ?? false },
            set: { isOn in
                if isOn { captured?.modifiers.insert(modifier) } else { captured?.modifiers.remove(modifier) }
            }
        )
    }

    private func asTrigger(_ captured: CapturedTrigger) -> Trigger {
        Trigger(button: captured.button, modifiers: captured.modifiers, interaction: captured.interaction)
    }

    private var canAdd: Bool {
        guard let captured, asTrigger(captured).isAllowed, let action else { return false }
        return action.isAllowed(for: captured.interaction)
    }

    private func add() {
        guard let captured, let action else { return }
        model.store.addRule(trigger: asTrigger(captured), action: action)
        dismiss()
    }
}
