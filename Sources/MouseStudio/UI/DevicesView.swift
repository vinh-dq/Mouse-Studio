import SwiftUI

/// One page per mouse: switch Mouse Studio off for it, or give it its own wheel and Drag Scroll settings.
struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @LocalState private var devices: [DeviceInfo] = []
    @LocalState private var expanded: Set<String> = []
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage {
            PermissionBanner()
            SettingsGroup(
                title: "Your Mice",
                footer: "Press a button or turn the wheel on a mouse and it appears here (the one used last is on top). By default every mouse uses the shared settings from Scrolling. Trackpads and Magic Mouse keep their own behaviour either way."
            ) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { SettingsDivider() }
                    DeviceRow(device: device, isFirst: index == 0, expanded: expanded.contains(device.key)) {
                        if expanded.contains(device.key) { expanded.remove(device.key) } else { expanded.insert(device.key) }
                    }
                }
                if devices.isEmpty {
                    Text("No mouse found yet. Press a button on your mouse.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { devices = model.knownDevices() }
        .onReceive(refresh) { _ in
            let latest = model.knownDevices()
            if latest != devices { devices = latest }
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceInfo
    let isFirst: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let profile = model.profile(for: device)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "computermouse")
                    .font(.system(size: 16))
                    .frame(width: 26)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 13))
                    Text(subtitle(profile)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button {
                    withAnimation(.snappy(duration: 0.2)) { toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings for this mouse")
                .accessibilityLabel("Settings for \(device.name)")
                Toggle("Use Mouse Studio with this mouse", isOn: Binding(
                    get: { profile?.isEnabled ?? true },
                    set: { value in model.updateProfile(for: device) { $0.isEnabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 48)

            if expanded {
                SettingsDivider()
                ToggleRow(title: "Own wheel settings", detail: "Speed, acceleration and direction just for this mouse.", isOn: Binding(
                    get: { profile?.customWheel != nil },
                    set: { value in model.updateProfile(for: device) { $0.customWheel = value ? model.store.config.wheel : nil } }
                ))
                if let wheel = profile?.customWheel {
                    SliderRow(title: "Speed", value: wheelBinding(\.speed, fallback: wheel.speed), range: WheelSettings.speedRange)
                    SliderRow(title: "Acceleration", value: wheelBinding(\.acceleration, fallback: wheel.acceleration), range: 0...1, format: "%.0f%%", scale: 100)
                    ToggleRow(title: "Reverse vertical", isOn: Binding(
                        get: { model.profile(for: device)?.customWheel?.reverseVertical ?? wheel.reverseVertical },
                        set: { value in model.updateProfile(for: device) { $0.customWheel?.reverseVertical = value } }
                    ))
                }
                SettingsDivider()
                ToggleRow(title: "Own Drag Scroll settings", detail: "Sensitivity and momentum just for this mouse.", isOn: Binding(
                    get: { profile?.customScroll != nil },
                    set: { value in model.updateProfile(for: device) { $0.customScroll = value ? model.store.config.scroll : nil } }
                ))
                if let scroll = profile?.customScroll {
                    SliderRow(title: "Sensitivity", value: scrollBinding(\.sensitivity, fallback: scroll.sensitivity), range: ScrollSettings.speedRange)
                    SliderRow(title: "Momentum", value: scrollBinding(\.inertia, fallback: scroll.inertia), range: 0...1, format: "%.0f%%", scale: 100)
                }
            }
        }
    }

    private func subtitle(_ profile: DeviceProfile?) -> String {
        if profile?.isEnabled == false { return String(localized: "Ignored by Mouse Studio") }
        if profile?.customWheel != nil || profile?.customScroll != nil { return String(localized: "Own settings") }
        return isFirst ? String(localized: "Used last · shared settings") : String(localized: "Shared settings")
    }

    private func wheelBinding(_ path: WritableKeyPath<WheelSettings, Double>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { model.profile(for: device)?.customWheel?[keyPath: path] ?? fallback },
            set: { value in model.updateProfile(for: device) { $0.customWheel?[keyPath: path] = value } }
        )
    }

    private func scrollBinding(_ path: WritableKeyPath<ScrollSettings, Double>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { model.profile(for: device)?.customScroll?[keyPath: path] ?? fallback },
            set: { value in model.updateProfile(for: device) { $0.customScroll?[keyPath: path] = value } }
        )
    }
}
