import AppKit

struct PaletteCommand {
    let info: PaletteCommandInfo
    let isAvailable: Bool
    let perform: @MainActor () -> Void
}

/// The commands offered by the command palette, built from the app state when it opens. Each one runs
/// the same code as its menu item.
@MainActor
enum PaletteCommandRegistry {
    static func commands(for store: NoteStore) -> [PaletteCommand] {
        commands(for: store, shortcuts: .shared)
    }

    static func commands(for store: NoteStore, shortcuts: MenuShortcutStore) -> [PaletteCommand] {
        let note = store.note(with: store.selectedNoteID)
        let liveNote = note?.deletedAt == nil ? note : nil
        let hasNote = note != nil
        let hasLiveNote = liveNote != nil

        var list: [PaletteCommand] = [
            command("newNote", "New Note", symbol: "square.and.pencil", shortcut: shortcuts.current(.newNote)?.display, keywords: ["create", "add"]) {
                NotificationCenter.default.post(name: .noteItNewNote, object: nil)
            },
            command("newNotebook", "New Notebook…", symbol: "folder.badge.plus", shortcut: shortcuts.current(.newNotebook)?.display, keywords: ["create", "add", "folder"]) {
                WindowRouter.showMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .noteItNewNotebook, object: nil)
                }
            },
            command("searchNotes", "Search Notes", symbol: "magnifyingglass", shortcut: shortcuts.current(.searchNotes)?.display, keywords: ["find", "filter"]) {
                NotificationCenter.default.post(name: .noteItFocusSearch, object: nil)
            },
            command("find", "Find…", symbol: "text.magnifyingglass", shortcut: shortcuts.current(.find)?.display, keywords: ["search", "in note"], available: hasNote) {
                WindowRouter.showMainWindow()
                FindReplaceModel.active()?.open(replace: false)
            },
            command("findReplace", "Find and Replace…", symbol: "arrow.left.arrow.right", shortcut: shortcuts.current(.findAndReplace)?.display, keywords: ["search", "substitute"], available: hasNote) {
                WindowRouter.showMainWindow()
                FindReplaceModel.active()?.open(replace: true)
            },
            command("export", "Export Note As…", symbol: "square.and.arrow.up", shortcut: shortcuts.current(.exportNote)?.display, keywords: ["save", "markdown", "html", "pdf"], available: hasNote) {
                WindowRouter.showMainWindow()
                ExportActions.exportCurrentNote()
            },
            command("print", "Print…", symbol: "printer", shortcut: shortcuts.current(.print)?.display, keywords: [], available: hasNote) {
                WindowRouter.showMainWindow()
                ExportActions.printCurrentNote()
            },
            command("copyMarkdown", "Copy as Markdown", symbol: "doc.on.clipboard", shortcut: shortcuts.current(.copyAsMarkdown)?.display, keywords: ["clipboard", "pasteboard"], available: hasNote) {
                WindowRouter.showMainWindow()
                ExportActions.copyAsMarkdown()
            },
            command("copyNoteLink", "Copy Note Link", symbol: "link", shortcut: shortcuts.current(.copyNoteLink)?.display, keywords: ["url", "clipboard"], available: hasLiveNote) {
                if let liveNote { CopyNoteLink.perform(noteID: liveNote.id, store: store) }
            },
            command("versionHistory", "Version History…", symbol: "clock.arrow.circlepath", shortcut: shortcuts.current(.versionHistory)?.display, keywords: ["revisions", "restore"], available: hasLiveNote) {
                if let liveNote { NoteMenuActions.showVersionHistory(of: liveNote) }
            },
            command("togglePin", liveNote?.isPinned == true ? "Unpin Note" : "Pin Note",
                    symbol: liveNote?.isPinned == true ? "pin.slash" : "pin", shortcut: nil, keywords: ["favorite"], available: hasLiveNote) {
                if let liveNote { store.togglePin(liveNote.id) }
            },
            command("deleteNote", note?.deletedAt != nil ? "Delete Now…" : "Delete Note", symbol: "trash", shortcut: shortcuts.current(.deleteNote)?.display,
                    keywords: ["remove", "trash"], available: hasNote) {
                guard let note else { return }
                WindowRouter.showMainWindow()
                NoteMenuActions.delete(note, store: store, undoManager: WindowRouter.mainWindow?.undoManager)
            },
            command("showRecentlyDeleted", "Show Recently Deleted", symbol: "trash", shortcut: nil, keywords: ["trash", "recover", "restore"],
                    available: store.hasRecentlyDeleted) {
                store.selection = .recentlyDeleted
                WindowRouter.showMainWindow()
            },
            command("import", "Import…", symbol: "square.and.arrow.down", shortcut: nil, keywords: ["markdown", "apple notes"]) {
                ImportSheetPresenter.show()
            },
            command("settings", "Settings…", symbol: "gearshape", shortcut: MenuShortcuts.settings.display, keywords: ["preferences", "options"]) {
                SettingsOpener.open()
            },
            command("integrationsSettings", "Integrations Settings…", symbol: SettingsView.Tab.integrations.symbol, shortcut: nil,
                    keywords: ["links", "url", "automation", "preferences"]) {
                SettingsTabRouter.show(.integrations)
            },
        ]

        if let liveNote {
            for notebook in store.sortedNotebooks where notebook.id != liveNote.notebookID {
                list.append(command("move.\(notebook.id.uuidString)", "Move to \(notebook.name)", symbol: notebook.symbol,
                                    shortcut: nil, keywords: ["notebook", "folder"]) {
                    store.moveNote(liveNote.id, to: notebook.id)
                })
            }
        }
        return list
    }

    static func availableCommands(for store: NoteStore) -> [PaletteCommand] {
        commands(for: store).filter(\.isAvailable)
    }

    private static func command(_ id: String, _ title: String, symbol: String, shortcut: String?, keywords: [String],
                                available: Bool = true, perform: @escaping @MainActor () -> Void) -> PaletteCommand {
        PaletteCommand(info: PaletteCommandInfo(id: id, title: title, symbol: symbol, shortcut: shortcut, keywords: keywords),
                       isAvailable: available, perform: perform)
    }
}
