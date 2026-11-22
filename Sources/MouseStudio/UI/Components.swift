import SwiftUI

// Building blocks for the settings pages. One rhythm everywhere: 24 pt page margin, 22 pt between groups,
// 8 pt between a group's title and its card, 14 × 11 pt inside each row.

/// A scrolling page of groups, centred and no wider than `Theme.pageWidth`.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(maxWidth: Theme.pageWidth)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A titled card holding rows. Put a `SettingsDivider` between rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Card {
                VStack(spacing: 0) { content }
            }
            if let footer {
                Text(LocalizedStringKey(footer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

/// A title (and an optional plain-words line under it) on the left, a control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 13))
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// Title and value on one line, the slider across the full width below, an optional explanation under it.
struct SliderRow: View {
    let title: String
    var detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.1f×"
    var scale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 13))
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 52, minHeight: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A row with a pop-up menu on the right.
struct PickerRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder let options: Options

    var body: some View {
        SettingRow(title: title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// A row that is one button, aligned to the left like a menu item.
struct ActionRow: View {
    let title: String
    var detail: String?
    var symbol: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.system(size: 13))
                        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                    if let detail {
                        Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A centred, content-sized switch between a few pages, with a sliding highlight. Looks like Control Center's
/// pills, and never stretches across the window the way the system segmented control does.
struct PillPicker<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    let symbol: (Item) -> String
    @Binding var selection: Item
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(item)).font(.system(size: 12, weight: .medium))
                        Text(LocalizedStringKey(title(item))).font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "highlight", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .frame(maxWidth: .infinity)
    }
}
