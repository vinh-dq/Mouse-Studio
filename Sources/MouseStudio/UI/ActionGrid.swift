import SwiftUI

/// The action picker used when creating a gesture: every choice visible at once, grouped, with a
/// plain-language caption where the name alone isn't enough.
struct ActionGrid: View {
    let interaction: Interaction
    let selection: Action?
    let onSelect: (Action) -> Void

    @LocalState private var detail: ActionDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(ActionChoice.sections(for: interaction)) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if let title = section.title {
                        Text(LocalizedStringKey(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                        ForEach(section.choices) { choice in
                            ActionTile(choice: choice, selection: selection) { pick(choice) }
                        }
                    }
                }
            }
        }
        .sheet(item: $detail) { kind in
            ActionDetailSheet(kind: kind, current: selection, onSave: onSelect)
        }
    }

    private func pick(_ choice: ActionChoice) {
        switch choice.pick() {
        case .action(let action): onSelect(action)
        case .detail(let kind): detail = kind
        case .chooseApp: if let action = chooseAppAction() { onSelect(action) }
        }
    }
}

private struct ActionTile: View {
    let choice: ActionChoice
    let selection: Action?
    let onTap: () -> Void

    var body: some View {
        let isSelected = choice.isSelected(selection)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: onTap) {
            HStack(spacing: 10) {
                IconTile(symbol: choice.symbol, tint: choice.tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(choice.title))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let caption = choice.caption(for: selection) {
                        Text(LocalizedStringKey(caption))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill)))
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
