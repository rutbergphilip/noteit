import AppKit
import SwiftUI

/// NoteIt design tokens.
///
/// Semantic colours map to macOS system colours (they adapt to appearance, accent and accessibility
/// settings); only fixed colours (notebook palette, hotkey tiles, `brand-*`) are hard-coded hex.
enum Tokens {
    // MARK: - Colour

    enum Color {
        // Semantic (system) colours.
        static let surfaceEditor = SwiftUI.Color(nsColor: .textBackgroundColor)
        static let surfaceWindow = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let surfaceRaised = SwiftUI.Color(nsColor: .controlBackgroundColor)
        static let ink = SwiftUI.Color(nsColor: .labelColor)
        static let inkSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        static let inkTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        static let hairline = SwiftUI.Color(nsColor: .separatorColor)
        static let fillQuiet = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        static let accent = SwiftUI.Color.accentColor
        static let onAccent = SwiftUI.Color.white
        static let focusRing = SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor)
        // SwiftUI's system colours: the same values as NSColor.systemOrange/Teal/Green/Red, but they keep
        // SwiftUI's vibrancy treatment in the sidebar (a `Color(nsColor:)` wrapper renders flatter there).
        static let pinned = SwiftUI.Color.orange
        static let recent = SwiftUI.Color.teal
        static let today = SwiftUI.Color.red
        static let tasks = SwiftUI.Color.blue
        static let success = SwiftUI.Color.green
        static let destructive = SwiftUI.Color.red
        /// Search matches in the note list and the editor.
        static let searchHighlight = SwiftUI.Color(nsColor: searchHighlightNS)
        static let searchHighlightNS = NSColor.systemYellow.withAlphaComponent(0.35)

        // Notebook palette (fixed in both appearances).
        static let notebookBlue = SwiftUI.Color(hex: Hex.notebookBlue)
        static let notebookIndigo = SwiftUI.Color(hex: Hex.notebookIndigo)
        static let notebookPurple = SwiftUI.Color(hex: Hex.notebookPurple)
        static let notebookPink = SwiftUI.Color(hex: Hex.notebookPink)
        static let notebookRed = SwiftUI.Color(hex: Hex.notebookRed)
        static let notebookOrange = SwiftUI.Color(hex: Hex.notebookOrange)
        static let notebookYellow = SwiftUI.Color(hex: Hex.notebookYellow)
        static let notebookGreen = SwiftUI.Color(hex: Hex.notebookGreen)
        static let notebookTeal = SwiftUI.Color(hex: Hex.notebookTeal)
        static let notebookGray = SwiftUI.Color(hex: Hex.notebookGray)

        // Settings › Shortcuts hotkey tiles (aliases of notebook colours).
        static let tileShowHide = notebookIndigo
        static let tileNewNote = notebookOrange
        static let tileQuickCapture = notebookBlue
        static let tileOpenQuickly = notebookTeal
        static let tileCommandPalette = notebookPurple
        static let tileCaptureSelection = notebookGreen
        static let tileOpenToday = notebookRed
        static let tileShowTasks = notebookPink

        // Brand (fixed): app icon, Quick Capture tile, marketing. Never note content or app chrome.
        static let brandViolet = SwiftUI.Color(hex: Hex.brandViolet)
        static let brandDeep = SwiftUI.Color(hex: Hex.brandDeep)
        static let brandPencil = SwiftUI.Color(hex: Hex.brandPencil)
        static let brandPaper = SwiftUI.Color(hex: Hex.brandPaper)

        /// Settings › Sync provider tiles (fixed). The two extra hex values keep the
        /// light-mode values of `success` and `recent` fixed so the tiles look the same in Dark.
        enum SyncProvider {
            static let folder = notebookBlue
            static let awsS3 = notebookOrange
            static let cloudflareR2 = notebookIndigo
            static let backblazeB2 = notebookRed
            static let googleCloud = SwiftUI.Color(hex: Hex.syncGreen)
            static let minio = SwiftUI.Color(hex: Hex.syncTeal)
            static let customS3 = notebookGray
        }
    }

    /// Hex strings for the fixed colours. Notebooks persist their colour as one of these strings.
    enum Hex {
        static let notebookBlue = "#0A84FF"
        static let notebookIndigo = "#5E5CE6"
        static let notebookPurple = "#BF5AF2"
        static let notebookPink = "#FF375F"
        static let notebookRed = "#FF453A"
        static let notebookOrange = "#FF9F0A"
        static let notebookYellow = "#FFD60A"
        static let notebookGreen = "#30D158"
        static let notebookTeal = "#64D2FF"
        static let notebookGray = "#8E8E93"

        /// The 10 notebook swatches, in picker order.
        static let notebookPalette: [String] = NotebookPalette.colors

        static let brandViolet = "#6E5BFF"
        static let brandDeep = "#1E2470"
        static let brandPencil = "#FFC93C"
        static let brandPaper = "#FBF8F1"

        static let syncGreen = "#34C759"
        static let syncTeal = "#30B0C7"
    }

    // MARK: - Type

    /// Chrome type styles. Editor styles live in `EditorStyles` (they scale from the body size).
    enum Font {
        static let cardTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let cardPreview = SwiftUI.Font.system(size: 12)
        static let cardMeta = SwiftUI.Font.system(size: 11)
        static let row = SwiftUI.Font.system(size: 13)
        static let rowMeta = SwiftUI.Font.system(size: 11)
        /// Always uppercase, with `Tokens.Tracking.sectionLabel`.
        static let sectionLabel = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let captureTitle = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let captureBody = SwiftUI.Font.system(size: 14)
        /// SF Pro Heavy Italic, tight (`Tokens.Tracking.wordmark`). Always two-tone.
        static func wordmark(size: CGFloat = 34) -> SwiftUI.Font {
            .system(size: size, weight: .heavy).italic()
        }
    }

    enum Tracking {
        static let sectionLabel: CGFloat = 0.6
        static let wordmark: CGFloat = -0.5
    }

    // MARK: - Spacing

    enum Space {
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s14: CGFloat = 14
        static let s16: CGFloat = 16
        static let quoteIndent: CGFloat = 18
        static let editorInsetY: CGFloat = 22
        static let editorInsetX: CGFloat = 28
    }

    // MARK: - Radius (always continuous corners)

    enum Radius {
        static let toolbar: CGFloat = 6
        static let tile: CGFloat = 7
        static let card: CGFloat = 10
        static let preview: CGFloat = 12
        static let panel: CGFloat = 16
        /// Notebook glyph tiles: 28% of the tile's side.
        static let glyphFraction: CGFloat = 0.28
        static func glyph(side: CGFloat) -> CGFloat { side * glyphFraction }
    }

    // MARK: - Sizes

    enum Size {
        static let hairline: CGFloat = 0.5
        static let toolbarButtonWidth: CGFloat = 26
        static let toolbarButtonHeight: CGFloat = 24
        static let emptyStateCircle: CGFloat = 88
        static let aboutIcon: CGFloat = 96
        static let menuBarGlyph: CGFloat = 18
        static let readingMax: CGFloat = 1100
        static let sidebarMin: CGFloat = 190
        static let sidebarWidth: CGFloat = 220
        static let sidebarMax: CGFloat = 320
        static let noteListMin: CGFloat = 240
        static let noteListWidth: CGFloat = 300
        static let noteListMax: CGFloat = 440
        static let menuBarPanelWidth: CGFloat = 340
        static let menuBarPanelHeight: CGFloat = 460
        static let captureWidth: CGFloat = 580
        static let captureHeight: CGFloat = 330
        static let settingsWidth: CGFloat = 520
        static let toastWidth: CGFloat = 320
    }

    // MARK: - Opacity

    enum Opacity {
        static let tintChip: CGFloat = 0.14
        static let tintGlyph: CGFloat = 0.16
    }
}
