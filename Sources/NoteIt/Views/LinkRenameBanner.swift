import SwiftUI

/// Under the editor header: the offer to update link text after a rename, then the result with Undo.
struct LinkRenameBanner: View {
    @ObservedObject var tracker: RenameTracker

    var body: some View {
        Group {
            if let prompt = tracker.prompt {
                bar {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(prompt.noteCount == 1
                         ? "1 note links here as “\(prompt.oldTitle)”. Update the link to “\(prompt.newTitle)”?"
                         : "\(prompt.noteCount) notes link here as “\(prompt.oldTitle)”. Update the links to “\(prompt.newTitle)”?")
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Not Now") { tracker.notNow() }
                    Button("Update") { tracker.update() }
                        .keyboardShortcut(.defaultAction)
                }
            } else if tracker.isUpdating {
                bar {
                    ProgressView().controlSize(.small)
                    Text("Updating links…")
                    Spacer()
                }
            } else if let outcome = tracker.outcome {
                bar {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(outcome.message)
                    Spacer(minLength: 8)
                    if outcome.result != nil {
                        Button("Undo") { tracker.undo() }
                    }
                    Button { tracker.dismissOutcome() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: tracker.prompt)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .transition(.opacity)
    }
}
