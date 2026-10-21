import AppIntents

struct NoteItShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateNoteIntent(), phrases: ["Create a note in \(.applicationName)"],
                    shortTitle: "Create Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: FindNotesIntent(), phrases: ["Search \(.applicationName)"],
                    shortTitle: "Find Notes", systemImageName: "magnifyingglass")
        AppShortcut(intent: AppendToNoteIntent(), phrases: ["Add to a note in \(.applicationName)"],
                    shortTitle: "Append to Note", systemImageName: "text.append")
    }
}
