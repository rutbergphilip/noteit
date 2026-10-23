import NoteItCore
import SwiftUI

struct EditorSettingsView: View {
    @EnvironmentObject private var store: NoteStore
    @AppStorage(PrefKey.editorFontSize) private var fontSize = PrefDefault.editorFontSize
    @AppStorage(PrefKey.defaultNotebookID) private var defaultNotebookRaw = ""
    @AppStorage(PrefKey.inlineCodeColor) private var inlineCodeColor = InlineCodeColor.pink.rawValue
    @AppStorage(PrefKey.inlineCodeFont) private var inlineCodeFont = InlineCodeFont.monospaced.rawValue
    @AppStorage(PrefKey.codeBlockTheme) private var codeBlockTheme = CodeTheme.xcode.id
    @AppStorage(PrefKey.syntaxHighlighting) private var syntaxHighlighting = true
    @AppStorage(PrefKey.linkRenameUpdates) private var linkRenameUpdates = PrefDefault.linkRenameUpdates
    @AppStorage(PrefKey.linkNewNoteNotebook) private var linkNewNoteNotebook = PrefDefault.linkNewNoteNotebook
    @AppStorage(PrefKey.templatesNotebookID) private var templatesNotebookRaw = ""
    @AppStorage(PrefKey.dailyNotesNotebookID) private var dailyNotebookRaw = ""
    @AppStorage(PrefKey.dailyNoteTitleFormat) private var dailyTitleFormat = DailyTitleFormat.iso.rawValue
    @AppStorage(PrefKey.dailyNoteTemplateID) private var dailyTemplateRaw = ""
    @AppStorage(PrefKey.showTodayInSidebar) private var showTodayInSidebar = PrefDefault.showTodayInSidebar

    var body: some View {
        Form {
            Section {
                LabeledContent("Default font size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 11...24, step: 1)
                            .frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .animation(.easeOut(duration: 0.12), value: fontSize)
            } header: {
                Text("Text")
            }

            Section {
                Picker("Inline code color", selection: $inlineCodeColor) {
                    ForEach(InlineCodeColor.allCases) { color in
                        Text(color.displayName).tag(color.rawValue)
                    }
                }
                Picker("Inline code font", selection: $inlineCodeFont) {
                    ForEach(InlineCodeFont.allCases) { font in
                        Text(font.displayName).tag(font.rawValue)
                    }
                }
                Picker("Code block theme", selection: $codeBlockTheme) {
                    ForEach(CodeTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Toggle("Syntax highlighting", isOn: $syntaxHighlighting)
                CodePreview(settings: CodeStyleSettings(
                    inlineColor: InlineCodeColor(rawValue: inlineCodeColor) ?? .pink,
                    inlineFont: InlineCodeFont(rawValue: inlineCodeFont) ?? .monospaced,
                    theme: CodeTheme.named(codeBlockTheme),
                    highlighting: syntaxHighlighting))
            } header: {
                Text("Code")
            }

            Section {
                Picker("Default notebook for new notes", selection: notebookBinding) {
                    Label("No Notebook", systemImage: "tray.full").tag(PrefDefault.noNotebook)
                    Divider()
                    ForEach(store.notebookPickerEntries) { entry in
                        NotebookPickerLabel(entry).tag(entry.id.uuidString)
                    }
                }
                SettingsFootnote(text: "Used by Quick Capture and notes created from the menu bar.")
            } header: {
                Text("New Notes")
            }

            Section {
                Picker("When a note is renamed", selection: $linkRenameUpdates) {
                    Text("Ask").tag("ask")
                    Text("Always update links").tag("always")
                    Text("Never update links").tag("never")
                }
                Picker("New notes from links go to", selection: $linkNewNoteNotebook) {
                    Text("Same notebook as the linking note").tag("source")
                    Text("Notebook for new notes").tag("default")
                }
            } header: {
                Text("Links")
            }

            Section {
                Picker("Templates notebook", selection: templatesNotebookBinding) {
                    Text("Templates (created on first use)").tag("")
                    Divider()
                    ForEach(store.notebookPickerEntries) { entry in
                        NotebookPickerLabel(entry).tag(entry.id.uuidString)
                    }
                }
                SettingsFootnote(text: "Notes in this notebook are templates. Use New Template in the command palette to add one.")
            } header: {
                Text("Templates")
            }

            if DailyNotes.isAvailable {
                Section {
                    Picker("Notebook", selection: dailyNotebookBinding) {
                        Text("Daily Notes (created on first use)").tag("")
                        Divider()
                        ForEach(store.notebookPickerEntries) { entry in
                            NotebookPickerLabel(entry).tag(entry.id.uuidString)
                        }
                    }
                    Picker("Title", selection: $dailyTitleFormat) {
                        ForEach(DailyTitleFormat.allCases, id: \.self) { format in
                            Text(DailyNoteTitle.title(for: today, format: format, locale: .current)).tag(format.rawValue)
                        }
                    }
                    Picker("Template", selection: dailyTemplateBinding) {
                        Text("None").tag("")
                        if !store.templates.isEmpty { Divider() }
                        ForEach(store.templates) { template in
                            Text(NoteStore.templateName(template)).tag(template.id.uuidString)
                        }
                    }
                    Toggle("Show Today in the sidebar", isOn: $showTodayInSidebar)
                } header: {
                    Text("Daily Notes")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    private var today: DayKey { DayKey(Date(), calendar: DayKey.dailyCalendar()) }

    private var dailyNotebookBinding: Binding<String> {
        Binding(
            get: {
                _ = dailyNotebookRaw
                return store.dailyNotesNotebookID(createIfMissing: false)?.uuidString ?? ""
            },
            set: { dailyNotebookRaw = $0 }
        )
    }

    private var dailyTemplateBinding: Binding<String> {
        Binding(
            get: {
                _ = dailyTemplateRaw
                return store.dailyNoteTemplateID?.uuidString ?? ""
            },
            set: { dailyTemplateRaw = $0 }
        )
    }

    private var templatesNotebookBinding: Binding<String> {
        Binding(
            get: {
                _ = templatesNotebookRaw
                return store.templatesNotebookIDIfSet?.uuidString ?? ""
            },
            set: { templatesNotebookRaw = $0 }
        )
    }

    private var notebookBinding: Binding<String> {
        Binding(
            get: {
                _ = defaultNotebookRaw
                return store.defaultNotebookIDForNewNotes?.uuidString ?? PrefDefault.noNotebook
            },
            set: { defaultNotebookRaw = $0 }
        )
    }
}

/// A small sample of inline code and a highlighted code block in the current code settings.
private struct CodePreview: View {
    let settings: CodeStyleSettings
    @Environment(\.colorScheme) private var colorScheme

    private static let sample = """
    // Greet everyone
    let names = ["Ada", "Grace"]
    for name in names {
        print("Hello, \\(name)!", 42)
    }
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("Run ") + inlineCode + Text(" to build the app."))
                .font(.system(size: 13))
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(cardFill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: EditorStyle.codeBlockBorder), lineWidth: 0.5))
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.12), value: settings)
    }

    private var inlineCode: Text {
        let font: Font = settings.inlineFont == .monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13)
        var string = AttributedString("\u{2009}swift build\u{2009}")
        string.font = font
        string.foregroundColor = Color(nsColor: settings.inlineColor.textColor)
        string.backgroundColor = Color(nsColor: settings.inlineColor.fillColor)
        return Text(string)
    }

    private var cardFill: Color {
        Color(nsColor: (settings.highlighting ? settings.theme.background : nil) ?? EditorStyle.codeBlockBackground)
    }

    private var highlighted: AttributedString {
        let ns = Self.sample as NSString
        let out = NSMutableAttributedString(string: Self.sample)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        func resolved(_ color: NSColor) -> NSColor {
            var result = color
            appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
            return result
        }
        let plain = settings.highlighting ? settings.theme.color(for: nil) : NSColor.labelColor
        out.addAttribute(.foregroundColor, value: resolved(plain), range: NSRange(location: 0, length: ns.length))
        if settings.highlighting {
            for token in SyntaxHighlighter.tokenize(Self.sample, language: .swift) {
                out.addAttribute(.foregroundColor, value: resolved(settings.theme.color(for: token.kind)), range: token.range)
            }
        }
        return (try? AttributedString(out, including: \.appKit)) ?? AttributedString(Self.sample)
    }
}
