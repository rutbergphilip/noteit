import AppKit
import SwiftUI

struct InlineCompletionRow: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String?
    var matched: [Range<String.Index>]
    var symbol: String?
}

/// What an inline completion list shows and inserts; `InlineCompletionController` does the rest.
@MainActor protocol InlineCompletionSource: AnyObject {
    func rows(for query: String) -> [InlineCompletionRow]
    /// Replaces `range` (the query) and whatever else the source owns around it, in one undo group.
    func accept(_ row: InlineCompletionRow, replacing range: NSRange, in textView: NoteItTextView)
    /// "Note link", "Tag".
    var accessibilityName: String { get }
    /// Source-specific close rules, checked on every refresh.
    func shouldEnd(for query: String) -> Bool
    /// The list closed without accepting (Esc, or a close rule).
    func didCancel(in textView: NoteItTextView, queryRange: NSRange)
}

extension InlineCompletionSource {
    func shouldEnd(for query: String) -> Bool { false }
    func didCancel(in textView: NoteItTextView, queryRange: NSRange) {}
}

/// A list under the caret that filters as the user types into the note (spec §4). Typing stays in the text view;
/// the list never becomes key. Keys reach it through the coordinator's `doCommandBy`.
@MainActor
final class InlineCompletionController {
    static let maxRows = 8
    static let rowHeight: CGFloat = 28
    static let width: CGFloat = 320

    private unowned let textView: NoteItTextView
    private var source: InlineCompletionSource?
    private var start = 0
    private let model = InlineCompletionModel()
    private nonisolated(unsafe) var panel: InlineCompletionPanel?
    private var resignObserver: NSObjectProtocol?
    private var cancelOnEnd = false

    init(textView: NoteItTextView) {
        self.textView = textView
    }

    deinit {
        guard let panel else { return }
        MainActor.assumeIsolated {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    var isActive: Bool { source != nil }
    var rows: [InlineCompletionRow] { model.rows }
    var selectedIndex: Int { model.selected }

    /// The query is the text from `location` to the caret.
    func begin(at location: Int, source: InlineCompletionSource) {
        end()
        self.source = source
        start = location
        if let window = textView.window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
        refresh()
    }

    func refresh() {
        guard let source else { return }
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location >= start, caret.location <= textView.storage.length else { return cancel() }
        let range = NSRange(location: start, length: caret.location - start)
        let query = textView.nsString.substring(with: range)
        if query.contains(where: \.isNewline) || source.shouldEnd(for: query) { return cancel() }
        let rows = Array(source.rows(for: query).prefix(Self.maxRows))
        let previous = model.rows.indices.contains(model.selected) ? model.rows[model.selected].id : nil
        model.rows = rows
        model.selected = previous.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        if rows.isEmpty { hidePanel() } else { showPanel() }
        announceSelection()
    }

    /// `moveUp:`, `moveDown:`, `insertNewline:`, `insertTab:`, `cancelOperation:`. True when handled.
    func handle(_ selector: Selector) -> Bool {
        guard isActive else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            guard !model.rows.isEmpty else { return false }
            model.selected = (model.selected - 1 + model.rows.count) % model.rows.count
            announceSelection()
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !model.rows.isEmpty else { return false }
            model.selected = (model.selected + 1) % model.rows.count
            announceSelection()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            guard model.rows.indices.contains(model.selected) else { cancel(); return false }
            accept(model.rows[model.selected])
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func accept(_ row: InlineCompletionRow) {
        guard let source else { return }
        let caret = textView.selectedRange().location
        let location = min(start, textView.storage.length)
        let range = NSRange(location: location, length: max(min(caret, textView.storage.length) - location, 0))
        end()
        source.accept(row, replacing: range, in: textView)
    }

    func end() {
        source = nil
        hidePanel()
        model.rows = []
        model.selected = 0
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Closes the list as Esc does.
    func cancel() {
        guard let source else { return }
        let caret = textView.selectedRange().location
        let location = min(start, textView.storage.length)
        let range = NSRange(location: location, length: max(min(caret, textView.storage.length) - location, 0))
        end()
        source.didCancel(in: textView, queryRange: range)
    }

    // MARK: Panel

    private func showPanel() {
        guard let window = textView.window else { return }
        let panel = self.panel ?? makePanel()
        let height = CGFloat(model.rows.count) * Self.rowHeight + 8
        let caret = textView.firstRect(forCharacterRange: NSRange(location: textView.selectedRange().location, length: 0), actualRange: nil)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var origin = NSPoint(x: caret.minX - 12, y: caret.minY - height - 4)
        if origin.y < visible.minY { origin.y = caret.maxY + 4 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.width)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> InlineCompletionPanel {
        let panel = InlineCompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        let list = InlineCompletionList(model: model) { [weak self] index in
            guard let self, self.model.rows.indices.contains(index) else { return }
            self.accept(self.model.rows[index])
        }
        panel.contentView = NSHostingView(rootView: list)
        self.panel = panel
        return panel
    }

    private func announceSelection() {
        guard model.rows.indices.contains(model.selected) else { return }
        let row = model.rows[model.selected]
        let text = "\(row.title), \(model.selected + 1) of \(model.rows.count)"
        NSAccessibility.post(element: textView, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

private final class InlineCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class InlineCompletionModel: ObservableObject {
    @Published var rows: [InlineCompletionRow] = []
    @Published var selected = 0
}

private struct InlineCompletionList: View {
    @ObservedObject var model: InlineCompletionModel
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    if let symbol = row.symbol {
                        Image(systemName: symbol)
                            .frame(width: 14)
                            .foregroundStyle(index == model.selected ? Color.white : Color.secondary)
                    }
                    Text(highlighted(row))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let detail = row.detail {
                        Text(detail)
                            .lineLimit(1)
                            .foregroundStyle(index == model.selected ? Color.white.opacity(0.8) : Color.secondary)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(index == model.selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: InlineCompletionController.rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(index == model.selected ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == model.selected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: InlineCompletionController.width, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func highlighted(_ row: InlineCompletionRow) -> AttributedString {
        var text = AttributedString(row.title)
        for range in row.matched {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .system(size: 13, weight: .bold)
        }
        return text
    }
}
