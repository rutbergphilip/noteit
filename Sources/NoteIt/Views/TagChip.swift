import SwiftUI

/// A small rounded tag label for note rows.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.Font.cardMeta)
            .foregroundStyle(Tokens.Color.accent)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Tokens.Color.accent.opacity(0.12)))
    }
}

/// Up to `limit` tag chips, then `+N` for the rest.
struct TagChipRow: View {
    let tags: [String]
    var limit = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(limit), id: \.self) { TagChip(text: "#\($0)") }
            if tags.count > limit {
                Text("+\(tags.count - limit)")
                    .font(Tokens.Font.cardMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tags: " + tags.joined(separator: ", "))
    }
}
