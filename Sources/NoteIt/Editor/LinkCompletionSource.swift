import AppKit
import NoteItCore

/// `[[` suggestions: notes, a note's headings after `#`, and **Create "…"**.
@MainActor
final class LinkCompletionSource: InlineCompletionSource {
    let store: NoteStore
    let noteID: UUID
    /// Shown text from a selection (Link to Note…), used unless the query has an alias.
    var presetText: String?
    /// Where Link to Note… inserted the `[[`; it's removed again when the list closes without a choice.
    var insertedOpening: Int?
    private var suggestions: [String: LinkSuggestion] = [:]
    private var lastQuery = LinkQuery("")

    init(store: NoteStore, noteID: UUID) {
        self.store = store
        self.noteID = noteID
    }

    var accessibilityName: String { "Note link" }

    func shouldEnd(for query: String) -> Bool {
        (query as NSString).length > NoteLink.maxTextLength || query.contains("]]") || query.contains("[")
    }

    func rows(for raw: String) -> [InlineCompletionRow] {
        var query = LinkQuery(raw)
        let head = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        if query.heading == nil, head.contains("#") { query.heading = "" }
        lastQuery = query
        var candidates: [LinkCandidate]
        if query.heading != nil, query.title.isEmpty {
            guard let current = store.note(with: noteID) else { return [] }
            query.title = current.title
            candidates = [LinkCandidate(id: current.id, title: current.title, notebookName: "", updatedAt: current.updatedAt)]
        } else {
            candidates = store.linkCandidates(excluding: query.heading == nil ? noteID : nil)
        }
        let result = LinkSuggester.suggestions(for: query, candidates: candidates,
                                               headings: { [store] in store.headings(for: $0) })
        suggestions = [:]
        return result.map { suggestion in
            let row: InlineCompletionRow
            switch suggestion {
            case let .note(id, title, notebookName, matched):
                row = InlineCompletionRow(id: "note:\(id.uuidString)", title: title,
                                          detail: notebookName.isEmpty ? nil : notebookName, matched: matched, symbol: "doc.text")
            case let .heading(id, text, level):
                row = InlineCompletionRow(id: "heading:\(id.uuidString):\(text)", title: text, detail: nil, matched: [],
                                          symbol: level == 1 ? "number" : "textformat.size.smaller")
            case let .create(title):
                row = InlineCompletionRow(id: "create:\(title)", title: "Create “\(title)”", detail: nil, matched: [], symbol: "plus")
            }
            suggestions[row.id] = suggestion
            return row
        }
    }

    func accept(_ row: InlineCompletionRow, replacing range: NSRange, in textView: NoteItTextView) {
        guard let suggestion = suggestions[row.id] else { return }
        let query = lastQuery
        let link: NoteLink
        let shown: String
        switch suggestion {
        case let .note(id, title, _, _):
            link = .note(id: id, heading: nil)
            shown = query.alias ?? presetText ?? title
        case let .heading(id, text, _):
            let heading = String(text.prefix(NoteLink.maxTextLength))
            link = .note(id: id, heading: heading)
            let title = store.note(with: id)?.title ?? ""
            shown = query.alias ?? presetText ?? (id == noteID && LinkQuery(textView.nsString.substring(with: range)).title.isEmpty
                ? text : "\(title) › \(text)")
        case let .create(title):
            let meta = store.createNoteForLink(title: title, from: noteID)
            link = .note(id: meta.id, heading: nil)
            shown = query.alias ?? presetText ?? meta.title
        }
        textView.insertNoteLink(link, text: shown, replacing: NSRange(location: range.location - 2, length: range.length + 2))
    }

    func didCancel(in textView: NoteItTextView, queryRange: NSRange) {
        guard let location = insertedOpening else { return }
        let opening = NSRange(location: location, length: 2)
        guard NSMaxRange(opening) <= textView.storage.length, textView.nsString.substring(with: opening) == "[[" else { return }
        let caret = textView.selectedRange().location
        let after = caret >= NSMaxRange(opening) ? caret - 2 : min(caret, location)
        textView.replace(opening, with: NSAttributedString(), select: NSRange(location: after, length: 0), actionName: "Link to Note")
    }
}
