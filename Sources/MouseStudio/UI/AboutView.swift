import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Mouse Studio").font(.title.weight(.semibold))
                Text(version).foregroundStyle(.secondary)
            }
            Text("Make any mouse work the way you do: custom buttons, shortcuts and smooth two-way drag scrolling.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 8) {
                Label("Works with any mouse brand", systemImage: "computermouse")
                Label("Settings stay on this Mac", systemImage: "lock")
                Label("Nothing you do is recorded or sent anywhere", systemImage: "eye.slash")
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
