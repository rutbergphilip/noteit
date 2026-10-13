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
            AppIconView(size: Tokens.Size.aboutIcon)
                .padding(.bottom, 4)
            wordmark
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

    /// Two-tone wordmark: "Note" in label colour, "It" in brand violet.
    private var wordmark: some View {
        (Text("Note").foregroundColor(Tokens.Color.ink) + Text("It").foregroundColor(Tokens.Color.brandViolet))
            .font(Tokens.Font.wordmark(size: 26))
            .tracking(Tokens.Tracking.wordmark)
            .accessibilityLabel("NoteIt")
    }
}
