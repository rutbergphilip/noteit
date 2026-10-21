import AppKit
import Combine
import NoteItCore

/// Marks the list search's words in the open note with temporary attributes, so the note's text never changes.
/// Cleared by an edit, by Esc in the editor and when the search is cleared.
@MainActor
final class SearchHighlightController: ObservableObject {
    weak var editor: EditorController?
    private(set) var terms: [String] = []
    private(set) var ranges: [NSRange] = []
    private weak var highlightedTextView: NSTextView?
    private var textObserver: NSObjectProtocol?
    private static let instances = NSHashTable<SearchHighlightController>.weakObjects()

    init() {
        Self.instances.add(self)
    }

    /// The highlighted terms of the editor showing `textView`.
    static func firstTerm(in textView: NSTextView) -> String? {
        instances.allObjects.first { $0.highlightedTextView === textView && !$0.ranges.isEmpty }?.terms.first
    }

    /// The controller highlighting in `textView`, if any.
    static func controller(for textView: NSTextView) -> SearchHighlightController? {
        instances.allObjects.first { $0.highlightedTextView === textView && !$0.ranges.isEmpty }
    }

    /// Highlights `search`'s terms once the editor has loaded the note.
    func update(search: String) {
        let terms = SearchQuery.parse(search).highlightTerms
        DispatchQueue.main.async { [weak self] in self?.apply(terms) }
    }

    func apply(_ terms: [String]) {
        clear()
        self.terms = terms
        guard !terms.isEmpty, let textView = editor?.textView, let storage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }
        ranges = SearchHighlighter.ranges(of: terms, in: storage.string)
        guard !ranges.isEmpty else { return }
        highlightedTextView = textView
        for range in ranges where NSMaxRange(range) <= storage.length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Tokens.Color.searchHighlightNS, forCharacterRange: range)
        }
        textObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] notification in
            let mask = (notification.object as? NSTextStorage)?.editedMask ?? []
            guard mask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.clear() }
        }
        redraw(textView)
        let titleEnd = (storage.string as NSString).lineRange(for: NSRange(location: 0, length: 0)).length
        if let first = ranges.first(where: { $0.location >= titleEnd }) {
            textView.scrollRangeToVisible(first)
        }
    }

    func clear() {
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        textObserver = nil
        if let textView = highlightedTextView, let storage = textView.textStorage, let layoutManager = textView.layoutManager {
            for range in ranges where NSMaxRange(range) <= storage.length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            redraw(textView)
        }
        highlightedTextView = nil
        ranges = []
    }

    private func redraw(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: length))
        textView.setNeedsDisplay(textView.visibleRect)
    }
}
