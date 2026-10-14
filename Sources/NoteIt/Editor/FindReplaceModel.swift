import AppKit
import Combine

/// State and actions of the editor's find and replace bar. Matches are shown with layout-manager
/// temporary attributes, so highlighting never touches the note's text.
@MainActor
final class FindReplaceModel: ObservableObject {
    enum Field { case find, replace }

    @Published private(set) var isVisible = false
    @Published var showsReplace = false
    @Published var query = "" {
        didSet { if query != oldValue { optionsOrQueryChanged() } }
    }
    @Published var replacement = ""
    @Published var options = FindReplaceEngine.Options() {
        didSet { if options != oldValue { optionsOrQueryChanged() } }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isInvalidRegex = false
    /// Which field should take focus, and a token that changes with each request.
    @Published private(set) var focusRequest: (field: Field, token: Int) = (.find, 0)
    /// False for read-only notes: the replace row is hidden and replacing does nothing.
    @Published var allowsReplace = true {
        didSet { if !allowsReplace { showsReplace = false } }
    }

    weak var editor: EditorController?

    private(set) var ranges: [NSRange] = []
    /// Where the next search starts when there's no current match.
    private var anchor = 0
    private weak var observedTextView: NSTextView?
    private var textObserver: NSObjectProtocol?
    private var pendingRecompute: DispatchWorkItem?

    private static let instances = NSHashTable<FindReplaceModel>.weakObjects()
    /// Above this length, recomputing after a text edit waits a little longer.
    static let largeTextLength = 50_000

    init() {
        Self.instances.add(self)
    }

    var textView: NSTextView? { editor?.textView }

    /// The bar of the key window's editor.
    static func active() -> FindReplaceModel? {
        let models = instances.allObjects.filter { $0.textView?.window != nil }
        return models.first { $0.textView?.window === NSApp.keyWindow }
            ?? models.first { $0.textView?.window === NSApp.mainWindow }
    }

    var statusText: String? {
        if isInvalidRegex { return "Invalid regex" }
        guard !query.isEmpty else { return nil }
        guard matchCount > 0 else { return "No results" }
        let total = matchCount >= FindReplaceEngine.matchLimit ? "\(matchCount)+" : "\(matchCount)"
        guard let currentIndex else { return "\(total) found" }
        return "\(currentIndex + 1) of \(total)"
    }

    var statusIsError: Bool { isInvalidRegex || (!query.isEmpty && matchCount == 0) }

    // MARK: Opening and closing

    func open(replace: Bool) {
        guard let textView else { return }
        attach(to: textView)
        let selection = textView.selectedRange()
        if let selected = Self.findString(fromSelection: selection, in: textView) {
            query = selected
        }
        if replace, allowsReplace { showsReplace = true }
        anchor = selection.location
        isVisible = true
        recompute(fromAnchor: true)
        revealCurrent(select: false)
        requestFocus(.find)
    }

    func close(refocusText: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        pendingRecompute?.cancel()
        let textView = observedTextView
        clearHighlights()
        detach()
        guard let textView else { return }
        if let currentIndex, currentIndex < ranges.count, NSMaxRange(ranges[currentIndex]) <= (textView.textStorage?.length ?? 0) {
            textView.setSelectedRange(ranges[currentIndex])
            textView.scrollRangeToVisible(ranges[currentIndex])
        }
        if refocusText { textView.window?.makeFirstResponder(textView) }
        ranges = []
        matchCount = 0
        currentIndex = nil
    }

    func toggleReplace() {
        guard allowsReplace else { return }
        showsReplace.toggle()
        requestFocus(showsReplace ? .replace : .find)
    }

    func requestFocus(_ field: Field) {
        focusRequest = (field, focusRequest.token + 1)
    }

    // MARK: Navigation

    func findNext() { step(forward: true) }
    func findPrevious() { step(forward: false) }

    /// ⌘E: the selection becomes the search string.
    func useSelectionForFind() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        guard let selected = Self.findString(fromSelection: selection, in: textView) else { return }
        anchor = selection.location
        currentIndex = nil
        query = selected
        if isVisible { revealCurrent(select: false) }
    }

    private func step(forward: Bool) {
        guard let textView else { return }
        if !isVisible {
            guard !query.isEmpty else { open(replace: false); return }
            attach(to: textView)
            isVisible = true
            recompute(fromAnchor: false)
        } else {
            flushPendingRecompute()
        }
        guard !ranges.isEmpty else { return }
        let selection = textView.selectedRange()
        let textHasFocus = textView.window?.firstResponder === textView
        let current = currentIndex.map { ranges[$0] }
        let next: Int
        if let currentIndex, !(textHasFocus && selection != current) {
            next = forward ? (currentIndex + 1) % ranges.count : (currentIndex - 1 + ranges.count) % ranges.count
        } else if forward {
            next = ranges.firstIndex { $0.location >= NSMaxRange(selection) } ?? 0
        } else {
            next = ranges.lastIndex { $0.location < selection.location } ?? ranges.count - 1
        }
        currentIndex = next
        anchor = ranges[next].location
        applyHighlights()
        revealCurrent(select: textHasFocus)
    }

    // MARK: Replacing

    func replaceCurrent() {
        guard allowsReplace, let textView, textView.isEditable, isVisible else { return }
        flushPendingRecompute()
        guard let currentIndex, currentIndex < ranges.count else { return }
        let range = ranges[currentIndex]
        let text = textView.string
        let string = FindReplaceEngine.replacement(for: range, in: text, query: query, template: replacement, options: options)
        guard FindReplaceApplier.replace([range], with: [string], in: textView, actionName: "Replace") else { return }
        pendingRecompute?.cancel()
        anchor = range.location + (string as NSString).length
        self.currentIndex = nil
        recompute(fromAnchor: true)
        revealCurrent(select: false)
    }

    func replaceAll() {
        guard allowsReplace, let textView, textView.isEditable, isVisible else { return }
        flushPendingRecompute()
        guard !ranges.isEmpty else { return }
        let text = textView.string
        let strings = ranges.map {
            FindReplaceEngine.replacement(for: $0, in: text, query: query, template: replacement, options: options)
        }
        guard FindReplaceApplier.replace(ranges, with: strings, in: textView, actionName: "Replace All") else { return }
        pendingRecompute?.cancel()
        anchor = ranges.first?.location ?? 0
        currentIndex = nil
        recompute(fromAnchor: true)
    }

    // MARK: Matching

    private func optionsOrQueryChanged() {
        guard isVisible else { return }
        if let currentIndex, currentIndex < ranges.count { anchor = ranges[currentIndex].location }
        currentIndex = nil
        recompute(fromAnchor: true)
        revealCurrent(select: false, indicate: false)
    }

    /// Recomputes matches. With `fromAnchor`, the current match is the first one at or after the anchor;
    /// otherwise (the text was edited) it's the first one at or after the text view's insertion point.
    private func recompute(fromAnchor: Bool) {
        pendingRecompute = nil
        guard let textView = observedTextView ?? textView else { return }
        do {
            ranges = try FindReplaceEngine.matches(in: textView.string, query: query, options: options)
            isInvalidRegex = false
        } catch {
            ranges = []
            isInvalidRegex = true
        }
        matchCount = ranges.count
        if ranges.isEmpty {
            currentIndex = nil
        } else {
            let start = fromAnchor ? anchor : textView.selectedRange().location
            currentIndex = ranges.firstIndex { $0.location >= start } ?? 0
        }
        applyHighlights()
    }

    private func flushPendingRecompute() {
        guard let pending = pendingRecompute else { return }
        pending.cancel()
        recompute(fromAnchor: false)
    }

    private func scheduleRecompute() {
        pendingRecompute?.cancel()
        let length = observedTextView?.textStorage?.length ?? 0
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.recompute(fromAnchor: false)
            }
        }
        pendingRecompute = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (length > Self.largeTextLength ? 0.3 : 0.05), execute: item)
    }

    private func revealCurrent(select: Bool, indicate: Bool = true) {
        guard let textView = observedTextView, let currentIndex, currentIndex < ranges.count else { return }
        let range = ranges[currentIndex]
        if select { textView.setSelectedRange(range) }
        textView.scrollRangeToVisible(range)
        if indicate { textView.showFindIndicator(for: range) }
    }

    // MARK: Highlighting

    static let matchColor = NSColor.systemYellow.withAlphaComponent(0.32)
    static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.55)

    private func applyHighlights() {
        guard let textView = observedTextView, let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length else { return }
        let all = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for (index, range) in ranges.enumerated() where NSMaxRange(range) <= length {
            let color = index == currentIndex ? Self.currentMatchColor : Self.matchColor
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
    }

    private func clearHighlights() {
        guard let textView = observedTextView, let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
    }

    // MARK: Text view

    private func attach(to textView: NSTextView) {
        guard observedTextView !== textView else { return }
        clearHighlights()
        detach()
        observedTextView = textView
        textObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil
        ) { [weak self] notification in
            let mask = (notification.object as? NSTextStorage)?.editedMask ?? []
            guard mask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.scheduleRecompute() }
        }
    }

    private func detach() {
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        textObserver = nil
        observedTextView = nil
    }

    /// Single-line selections fill the find field; longer or multi-line ones don't.
    static func findString(fromSelection selection: NSRange, in textView: NSTextView) -> String? {
        guard selection.length > 0, selection.length <= 500, NSMaxRange(selection) <= (textView.string as NSString).length else { return nil }
        let string = (textView.string as NSString).substring(with: selection)
        guard string.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return string
    }
}
