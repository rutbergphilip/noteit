import AppKit
import SwiftUI

/// Wraps `NSVisualEffectView` for vibrant, translucent backgrounds.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// `.active` keeps vibrancy even when the app isn't frontmost (non-activating panels).
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

/// Small colored rounded-square glyph representing a notebook.
struct NotebookGlyph: View {
    let notebook: Notebook?
    var size: CGFloat = 20

    var body: some View {
        let color = notebook?.color ?? Color.secondary
        Image(systemName: notebook?.symbol ?? "note.text")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.glyph(side: size), style: .continuous)
                    .fill(color.opacity(Tokens.Opacity.tintGlyph))
            )
    }
}

/// Compact menu for choosing which notebook a captured note goes to.
struct NotebookMenuPicker: View {
    @Binding var selection: UUID?
    @ObservedObject var store: NoteStore

    var body: some View {
        let current = store.notebook(with: selection)
        Menu {
            Button {
                selection = nil
            } label: {
                Label("No Notebook", systemImage: "tray.full")
            }
            if !store.notebooks.isEmpty { Divider() }
            ForEach(store.notebookPickerEntries) { entry in
                Button {
                    selection = entry.id
                } label: {
                    NotebookPickerLabel(entry)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current?.symbol ?? "tray.full")
                    .foregroundStyle(current?.color ?? .secondary)
                Text(current?.name ?? "No Notebook")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notebook for this note")
    }
}

/// NoteIt app icon: the bundle icon, or the same artwork from the SwiftPM resources (unbundled runs).
struct AppIconView: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor static var image: NSImage {
        let isBundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        if !isBundled, let artwork = AppResources.appIcon { return artwork }
        return NSApp.applicationIconImage
    }
}

/// Hands the hosting `NSWindow` to a callback once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                if let window = view?.window { onWindow(window) }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
