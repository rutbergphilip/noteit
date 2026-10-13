import SwiftUI

struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 10) {
            AppIconView(size: 96)
                .padding(.bottom, 4)
            Text("NoteIt")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Notes that keep up with your thinking.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Spacer().frame(height: 8)
            Text("© 2026 NoteIt. Made for macOS.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Open source · AGPL-3.0-or-later")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
    }
}
