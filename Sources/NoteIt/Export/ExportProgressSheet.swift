import AppKit
import SwiftUI

@MainActor
final class ExportProgress: ObservableObject {
    @Published var completed = 0
    let total: Int
    @Published private(set) var isCancelled = false

    init(total: Int) {
        self.total = total
    }

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    func cancel() {
        isCancelled = true
    }
}

/// Shown while Export Notebook… or Export All Notes… writes many notes.
struct ExportProgressSheet: View {
    @ObservedObject var progress: ExportProgress
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
                    .fill(Tokens.Color.notebookBlue.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: Tokens.Color.notebookBlue.opacity(0.35), radius: 6, y: 3)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: progress.fraction)
                HStack {
                    Text(progress.isCancelled ? "Stopping…" : "Exporting…")
                    Spacer()
                    Text("\(progress.completed) of \(progress.total)")
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { progress.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(progress.isCancelled)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// Shows an `ExportProgressSheet` on a window.
@MainActor
enum ExportProgressPresenter {
    static func show(_ progress: ExportProgress, title: String, on parent: NSWindow) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: ExportProgressSheet(progress: progress, title: title))
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
        parent.beginSheet(window)
        return window
    }

    static func dismiss(_ window: NSWindow) {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
