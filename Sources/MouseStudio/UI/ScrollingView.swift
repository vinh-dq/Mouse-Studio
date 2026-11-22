import SwiftUI

struct ScrollingView: View {
    private enum Page: String, CaseIterable {
        case wheel = "Mouse Wheel"
        case drag = "Drag Scroll"
        case spaces = "Spaces"

        var symbol: String {
            switch self {
            case .wheel: "computermouse"
            case .drag: "hand.draw"
            case .spaces: "rectangle.3.group"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @LocalState private var addingTrigger = false
    @AppStorage("scrollingPage") private var pageName = Page.wheel.rawValue

    private var store: ConfigStore { model.store }
    private var page: Binding<Page> {
        Binding(get: { Page(rawValue: pageName) ?? .wheel }, set: { pageName = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            PillPicker(items: Page.allCases, title: { $0.rawValue }, symbol: { $0.symbol }, selection: page)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 4)

            SettingsPage {
                PermissionBanner()
                switch page.wrappedValue {
                case .wheel: wheelPage
                case .drag: dragPage
                case .spaces: spacesPage
                }
            }
        }
        .sheet(isPresented: $addingTrigger) {
            RuleComposerSheet(initial: nil, fixedAction: .dragScroll)
        }
    }

    // MARK: - Mouse wheel

    @ViewBuilder private var wheelPage: some View {
        SettingsGroup(title: "Feel") {
            ToggleRow(title: "Smooth scrolling", detail: "Glides each notch to a stop, like a Trackpad.", isOn: store.binding(\.wheel.smooth))
            SettingsDivider()
            SliderRow(title: "Smoothness", detail: "How long a notch glides.", value: store.binding(\.wheel.smoothness), range: 0...1, format: "%.0f%%", scale: 100)
                .disabled(!store.config.wheel.smooth)
            SettingsDivider()
            SliderRow(title: "Speed", detail: "How far each notch scrolls.", value: store.binding(\.wheel.speed), range: WheelSettings.speedRange)
            SettingsDivider()
            SliderRow(title: "Acceleration", detail: "At 0% every notch is equal; raise it so quick spins travel further.", value: store.binding(\.wheel.acceleration), range: 0...1, format: "%.0f%%", scale: 100)
        }

        SettingsGroup(title: "Zoom", footer: "Used while you hold a zoom button or key and turn the wheel. Every click counts, so a quick flick of five clicks zooms five steps.") {
            SliderRow(title: "Zoom step", detail: "How much each wheel click zooms.", value: store.binding(\.wheel.zoomStep), range: WheelSettings.zoomStepRange, format: "%.0f%%", scale: 100)
        }

        SettingsGroup(title: "Direction") {
            ToggleRow(title: "Reverse vertical", isOn: store.binding(\.wheel.reverseVertical))
            SettingsDivider()
            ToggleRow(title: "Reverse horizontal", isOn: store.binding(\.wheel.reverseHorizontal))
        }

        SettingsGroup(title: "Hold a Key While Scrolling", footer: "Click a box, hold the keys you want, then let go. Applies to a mouse wheel only; Trackpads and Magic Mouse are never changed.") {
            WheelModifierKeys()
                .padding(14)
        }

        resetButton("Reset Mouse Wheel") { $0.wheel = WheelSettings.recommended }
    }

    // MARK: - Drag scroll

    @ViewBuilder private var dragPage: some View {
        let triggers = store.config.rules.filter { $0.action == .dragScroll }
        SettingsGroup(title: "Triggers", footer: "Hold the button and move the mouse, like two fingers on a Trackpad. Flick and let go to keep gliding.") {
            ForEach(Array(triggers.enumerated()), id: \.element.id) { index, rule in
                if index > 0 { SettingsDivider() }
                SettingRow(title: rule.trigger.button.name) {
                    HStack(spacing: 12) {
                        KeyCaps(modifiers: rule.trigger.modifiers)
                        Toggle("Enabled", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { model.setRule(rule, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        Button {
                            store.removeRule(id: rule.id)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this trigger")
                        .accessibilityLabel("Remove trigger")
                    }
                }
            }
            if triggers.isEmpty {
                Text("No trigger yet. Add one to scroll in any direction by holding a button and moving the mouse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsDivider()
            ActionRow(title: "Add Trigger…", symbol: "plus.circle.fill") { addingTrigger = true }
        }

        SettingsGroup(title: "Speed") {
            SliderRow(title: "Sensitivity", value: store.binding(\.scroll.sensitivity), range: ScrollSettings.speedRange)
            SettingsDivider()
            SliderRow(title: "Horizontal", value: store.binding(\.scroll.horizontalSpeed), range: ScrollSettings.speedRange)
            SettingsDivider()
            SliderRow(title: "Vertical", value: store.binding(\.scroll.verticalSpeed), range: ScrollSettings.speedRange)
        }

        SettingsGroup(title: "Feel") {
            SliderRow(title: "Smoothness", value: store.binding(\.scroll.smoothness), range: 0...1, format: "%.0f%%", scale: 100)
            SettingsDivider()
            SliderRow(title: "Momentum", detail: "How far it keeps gliding after you let go.", value: store.binding(\.scroll.inertia), range: 0...1, format: "%.0f%%", scale: 100)
        }

        SettingsGroup(title: "Behavior") {
            PickerRow(title: "Direction", selection: store.binding(\.scroll.invertDirection)) {
                Text("Content follows the mouse").tag(false)
                Text("Reversed").tag(true)
            }
            SettingsDivider()
            PickerRow(title: "Lock axis", selection: store.binding(\.scroll.axisLock)) {
                ForEach(AxisLock.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            SettingsDivider()
            ToggleRow(title: "Freeze the pointer while scrolling", isOn: store.binding(\.scroll.freezeCursor))
        }

        resetButton("Reset Drag Scroll") { $0.scroll = ScrollSettings.recommended }
    }

    // MARK: - Spaces

    @ViewBuilder private var spacesPage: some View {
        SettingsGroup(title: "Spaces & Mission Control", footer: "How far the desktops move for each bit of mouse movement. Lower is slower and gentler.") {
            SliderRow(title: "Speed", value: store.binding(\.swipe.speed), range: SwipeSettings.speedRange, format: "%.0f%%", scale: 100)
        }
        resetButton("Reset Spaces Speed") { $0.swipe = SwipeSettings.recommended }
    }

    private func resetButton(_ title: String, _ reset: @escaping (inout AppConfig) -> Void) -> some View {
        Button(title) { store.update(reset) }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}
