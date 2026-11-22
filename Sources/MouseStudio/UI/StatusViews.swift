import SwiftUI

extension AppModel {
    var statusColor: Color {
        switch status {
        case .running: .green
        case .off: .secondary
        case .needsPermission, .failed: .orange
        }
    }

    var statusDetail: String {
        switch status {
        case .running: String(localized: "Mouse Studio is watching your mouse and applying your rules.")
        case .off: String(localized: "Paused. Your mouse behaves exactly as macOS defines it.")
        case .needsPermission: String(localized: "Accessibility access is needed before Mouse Studio can see your mouse buttons.")
        case .failed: String(localized: "The mouse monitor couldn't start. Check that Mouse Studio is allowed under Privacy & Security → Accessibility, then try again.")
        }
    }
}

/// Explains why a permission is needed and offers the one action that fixes it.
/// Shown only while the monitor is blocked by permission, or failed to start.
struct PermissionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.status == .needsPermission || model.status == .failed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.status == .needsPermission ? "Allow Accessibility access" : "Mouse monitor not running")
                        .font(.headline)
                    Text(model.statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("This is how macOS lets an app read and replace mouse buttons. Mouse Studio keeps everything on your Mac and sends nothing anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if model.status == .needsPermission {
                            Button("Allow Access…") { model.permissions.request() }
                                .keyboardShortcut(.defaultAction)
                        }
                        Button("Open System Settings") { model.permissions.openSystemSettings() }
                        Button("Check Again") { model.reconcile() }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        }
    }
}

extension ModifierSet {
    init(_ flags: NSEvent.ModifierFlags) {
        var set: ModifierSet = []
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.command) { set.insert(.command) }
        self = set
    }
}
