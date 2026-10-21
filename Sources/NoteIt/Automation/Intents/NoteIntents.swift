import AppIntents
import Foundation
import NoteItAPI
import NoteItCore

enum NotePositionOption: String, AppEnum {
    case end, start

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Position"
    static var caseDisplayRepresentations: [NotePositionOption: DisplayRepresentation] = [
        .end: "End",
        .start: "Start",
    ]

    var position: AppendPosition { self == .start ? .start : .end }
}

enum NoteTextFormatOption: String, AppEnum {
    case plainText, markdown

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static var caseDisplayRepresentations: [NoteTextFormatOption: DisplayRepresentation] = [
        .plainText: "Plain Text",
        .markdown: "Markdown",
    ]

    var format: BodyFormatDTO { self == .markdown ? .markdown : .text }
}

struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Note"
    static var description = IntentDescription("Creates a note in NoteIt.")
    static var openAppWhenRun = false

    @Parameter(title: "Title")
    var noteTitle: String?

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Notebook")
    var notebook: NotebookEntity?

    @Parameter(title: "Show Note", default: false)
    var showNote: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Create a note with \(\.$text)") {
            \.$noteTitle
            \.$notebook
            \.$showNote
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> {
        let service = AutomationService.shared
        let meta = try IntentError.run { () throws(AutomationError) in
            try service.create(title: noteTitle, body: text, format: .text, notebook: notebook.map { .id($0.id) },
                               tags: [], pinned: false)
        }
        if showNote { try IntentError.run { () throws(AutomationError) in try service.open(meta.id) } }
        return .result(value: service.noteEntity(meta))
    }
}

struct AppendToNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Append to Note"
    static var description = IntentDescription("Adds text to the end or start of a note.")
    static var openAppWhenRun = false

    @Parameter(title: "Note")
    var note: NoteEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Position", default: .end)
    var position: NotePositionOption

    @Parameter(title: "Add Time", default: false)
    var addTime: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$note)") {
            \.$position
            \.$addTime
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> {
        let service = AutomationService.shared
        let meta = try await IntentError.run { () async throws(AutomationError) in
            try await service.append(note.id, text: text, format: .text, position: position.position, timestamp: addTime,
                                     ifRevision: nil)
        }
        return .result(value: service.noteEntity(meta))
    }
}

struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Note"
    static var description = IntentDescription("Opens a note in NoteIt.")
    static var openAppWhenRun = true

    @Parameter(title: "Note")
    var note: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentError.run { () throws(AutomationError) in try AutomationService.shared.open(note.id) }
        return .result()
    }
}

struct FindNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Notes"
    static var description = IntentDescription("Finds notes the way the note list's search does.")
    static var openAppWhenRun = false

    @Parameter(title: "Search Text")
    var searchText: String

    @Parameter(title: "Notebook")
    var notebook: NotebookEntity?

    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 500))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find notes matching \(\.$searchText)") {
            \.$notebook
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NoteEntity]> {
        let service = AutomationService.shared
        let notes = try IntentError.run { () throws(AutomationError) in
            try service.list(notebook: notebook.map { .id($0.id) }, tag: nil, query: searchText, updatedSince: nil,
                             deleted: .exclude, sort: .list, limit: limit, cursor: nil).notes
        }
        return .result(value: notes.map(service.noteEntity))
    }
}

struct GetNoteTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Note Text"
    static var description = IntentDescription("Gets a note's text as plain text or Markdown.")
    static var openAppWhenRun = false

    @Parameter(title: "Note")
    var note: NoteEntity

    @Parameter(title: "Format", default: .plainText)
    var format: NoteTextFormatOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get the text of \(\.$note) as \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try IntentError.run { () throws(AutomationError) in
            try AutomationService.shared.body(note.id, format: format.format)
        }
        return .result(value: text)
    }
}
