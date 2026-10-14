import SwiftUI

/// Shown above a note in Recently Deleted, which opens read-only.
struct DeletedNoteBanner: View {
    @EnvironmentObject private var store: NoteStore
    let note: NoteMeta
    let deletedAt: Date

    var body: some View {
        HStack(spacing: Tokens.Space.s10) {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 60 * 60)) { context in
                Text(NoteStore.deletionSummary(deletedAt: deletedAt, now: context.date))
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.Color.ink)
                    .lineLimit(2)
            }
            Spacer(minLength: Tokens.Space.s8)
            Button("Recover") { store.recover([note.id]) }
                .controlSize(.small)
                .help("Put this note back in its notebook")
            Button("Delete Now…") { RecentlyDeletedCoordinator.shared.pendingDeleteNow = [note.id] }
                .controlSize(.small)
                .help("Remove this note for good")
        }
        .padding(.horizontal, Tokens.Space.s12)
        .padding(.vertical, Tokens.Space.s8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.Color.fillQuiet.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Tokens.Color.hairline, lineWidth: 1)
        )
        .padding(.horizontal, Tokens.Space.s16)
        .padding(.vertical, Tokens.Space.s6)
        .accessibilityElement(children: .contain)
    }
}
