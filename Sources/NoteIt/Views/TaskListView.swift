import NoteItCore
import SwiftUI

/// A task row's identity in the list: it stays the same when the task is checked, unlike its `TaskRef`.
struct TaskKey: Hashable {
    var noteID: UUID
    var paragraph: Int

    init(_ ref: TaskRef) {
        noteID = ref.noteID
        paragraph = ref.paragraph
    }
}

/// The middle column when Tasks is selected: every checkbox from every note, grouped by due date.
struct TaskListView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.undoManager) private var undoManager
    @AppStorage(PrefKey.tasksShowCompleted) private var showCompleted = false
    @AppStorage(PrefKey.remindersEnabled) private var remindersEnabled = PrefDefault.remindersEnabled
    @ObservedObject private var notifications = ReminderNotifications.shared
    @State private var selection: TaskRef?
    @State private var settling: [TaskKey: Settling] = [:]
    @State private var settleGeneration = 0
    @State private var message: String?
    @State private var editingDue: TaskRef?

    /// A checked or reopened row kept where it was for a moment, so a mis-click is easy to undo.
    struct Settling {
        var item: TaskItem
        var group: TaskGroup
        var index: Int
    }

    static let settleDelay: TimeInterval = 1.5

    var body: some View {
        let query = SearchQuery.parse(store.searchText)
        let live = store.tasks(query: store.searchText, includeCompleted: showCompleted)
        let groups = Self.display(live: live, settling: settling)
        let openCount = live.filter { $0.key != .completed }.values.reduce(0) { $0 + $1.count }
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.group) { entry in
                        Section(entry.group.title) {
                            ForEach(entry.items) { item in
                                row(item)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: TaskRef.self) { refs in
                    if let ref = refs.first, let item = find(ref, in: groups) { contextMenu(item) }
                } primaryAction: { keys in
                    guard let key = keys.first else { return }
                    EditorNavigator.reveal(key.noteID, paragraph: key.paragraph, inAllNotes: true, store: store)
                    WindowRouter.focusEditor()
                }
                .onKeyPress(.space) {
                    guard let selection, let item = find(selection, in: groups) else { return .ignored }
                    toggle(item, groups: groups)
                    return .handled
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if remindersEnabled, notifications.isAvailable, notifications.isAuthorized == false {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash").foregroundStyle(.secondary)
                        Text("Notifications are off for NoteIt.").font(.callout)
                        Spacer()
                        Button("Open System Settings…") { ReminderNotifications.openSystemSettings() }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
                if let message {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(message).font(.callout)
                        Spacer()
                        Button("OK") { self.message = nil }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .task { await notifications.refreshAuthorization() }
        .navigationTitle("Tasks")
        .navigationSubtitle(openCount == 1 ? "1 open task" : "\(openCount) open tasks")
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search Tasks")
        .toolbar {
            if let issue = query.issues.first {
                ToolbarItem(placement: .primaryAction) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(issue.message)
                        .accessibilityLabel(issue.message)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showCompleted) {
                    Label("Show Completed", systemImage: "checkmark.circle")
                }
                .help(showCompleted ? "Hide Completed" : "Show Completed")
            }
        }
        .onChange(of: selection) { _, key in
            guard let key else { return }
            EditorNavigator.reveal(key.noteID, paragraph: key.paragraph, inAllNotes: false, store: store)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyStateView(symbol: "checklist", title: "No Tasks",
                           message: "Checklist items from all your notes appear here. Add a date with @due(tomorrow).",
                           tint: Tokens.Color.tasks)
        } else {
            EmptyStateView(symbol: "magnifyingglass", title: "No Results", message: "No tasks match “\(store.searchText)”.")
        }
    }

    private func row(_ item: TaskItem) -> some View {
        return TaskRow(item: item, notebook: store.notebook(with: item.notebookID)) {
            toggle(item, groups: Self.display(live: store.tasks(query: store.searchText, includeCompleted: showCompleted),
                                              settling: settling))
        }
        .tag(item.ref)
        .popover(isPresented: Binding(get: { editingDue == item.ref }, set: { if !$0 { editingDue = nil } }), arrowEdge: .trailing) {
            DatePopover(title: "Due Date", initial: item.line.due,
                        onSet: { value in setDue(item, value) },
                        onRemove: item.line.due == nil ? nil : { setDue(item, nil) },
                        onClose: { editingDue = nil })
        }
    }

    @ViewBuilder
    private func contextMenu(_ item: TaskItem) -> some View {
        Button("Set Due Date…") { editingDue = item.ref }
        Button("Remove Due Date") { setDue(item, nil) }
            .disabled(item.line.due == nil)
        Divider()
        Button("Open Note") {
            EditorNavigator.reveal(item.ref.noteID, paragraph: item.ref.paragraph, inAllNotes: true, store: store)
        }
        Button("Copy Task") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TaskParser.displayText(item.line.text), forType: .string)
        }
    }

    private func find(_ ref: TaskRef, in groups: [(group: TaskGroup, items: [TaskItem])]) -> TaskItem? {
        for entry in groups {
            if let item = entry.items.first(where: { $0.ref == ref }) { return item }
        }
        return nil
    }

    /// The ref to edit the row's task with: the listed task with the same text (it may have moved), or the row's own
    /// ref. Never another task that took the row's line, so the store reports a changed task instead.
    static func editRef(for item: TaskItem, live: [TaskGroup: [TaskItem]]) -> TaskRef {
        let candidates = live.values.joined().filter { $0.ref.noteID == item.ref.noteID && $0.ref.textHash == item.ref.textHash }
        if candidates.contains(where: { $0.ref == item.ref }) { return item.ref }
        return candidates.count == 1 ? candidates[0].ref : item.ref
    }

    private func editRef(for item: TaskItem) -> TaskRef {
        Self.editRef(for: item, live: store.tasks(query: "", includeCompleted: true))
    }

    private func setDue(_ item: TaskItem, _ value: LocalDateTime?) {
        do {
            try store.setDue(editRef(for: item), value)
            settling[TaskKey(item.ref)] = nil
            message = nil
        } catch {
            message = Self.message(for: error)
        }
    }

    private func toggle(_ item: TaskItem, groups: [(group: TaskGroup, items: [TaskItem])]) {
        let key = TaskKey(item.ref)
        let ref = editRef(for: item)
        let checked = !item.line.checked
        do {
            try store.setTaskChecked(ref, checked)
        } catch {
            message = Self.message(for: error)
            return
        }
        message = nil
        let newRef = TaskRef(noteID: ref.noteID, paragraph: ref.paragraph,
                             textHash: TaskParser.textHash((checked ? ChecklistMarkers.checked : ChecklistMarkers.unchecked)
                                                           + "\t" + item.line.text))
        undoManager?.registerUndo(withTarget: store) { store in
            try? store.setTaskChecked(newRef, !checked)
        }
        undoManager?.setActionName(checked ? "Check" : "Uncheck")

        if selection == item.ref { selection = newRef }
        var shown = item
        shown.ref = newRef
        shown.line.checked = checked
        if settling[key] != nil {
            settling[key]?.item = shown
        } else if let position = groups.firstIndex(where: { $0.items.contains { TaskKey($0.ref) == key } }),
                  let index = groups[position].items.firstIndex(where: { TaskKey($0.ref) == key }) {
            settling[key] = Settling(item: shown, group: groups[position].group, index: index)
        }
        settleGeneration += 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
            if settleGeneration == generation { settling.removeAll() }
        }
    }

    static func message(for error: Error) -> String {
        switch error as? BodyEditError {
        case .taskChanged, .noteMissing: "This task changed. Open the note to edit it."
        case .locked: "This note is locked. Unlock it to change its tasks."
        case .inTrash: "This note is in Recently Deleted."
        case .writeBlocked: "This note can't be changed right now."
        case .versionNotSaved: "The note's current version couldn't be saved, so it wasn't changed."
        case .folderNotAvailable(let folder): BodyEditError.folderNotAvailableMessage(folder)
        case nil: error.localizedDescription
        }
    }

    /// The live groups in display order, with settling rows kept in their old group and place.
    static func display(live: [TaskGroup: [TaskItem]], settling: [TaskKey: Settling]) -> [(group: TaskGroup, items: [TaskItem])] {
        var groups = live.mapValues { items in items.filter { settling[TaskKey($0.ref)] == nil } }
        for (_, entry) in settling.sorted(by: { $0.value.index < $1.value.index }) {
            var items = groups[entry.group] ?? []
            items.insert(entry.item, at: min(entry.index, items.count))
            groups[entry.group] = items
        }
        return TaskGroup.allCases.compactMap { group in
            guard let items = groups[group], !items.isEmpty else { return nil }
            return (group, items)
        }
    }

    /// "Today", "Tomorrow", "Yesterday" or a short date such as "Fri 23 Oct", with the time when there is one.
    static func dueLabel(_ due: LocalDateTime, now: Date, calendar: Calendar) -> String {
        let today = LocalDateTime(now, calendar: calendar, includeTime: false)
        let start = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> LocalDateTime? {
            calendar.date(byAdding: .day, value: offset, to: start).map { LocalDateTime($0, calendar: calendar, includeTime: false) }
        }
        let date = due.dateOnly
        var label: String
        if date == today {
            label = "Today"
        } else if date == day(1) {
            label = "Tomorrow"
        } else if date == day(-1) {
            label = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.setLocalizedDateFormatFromTemplate(date.year == today.year ? "EEEdMMM" : "EEEdMMMyyyy")
            label = date.date(in: calendar).map(formatter.string(from:)) ?? date.token
        }
        if let hour = due.hour, let minute = due.minute {
            label += String(format: " %02d:%02d", hour, minute)
        }
        return label
    }
}

private struct TaskRow: View {
    let item: TaskItem
    let notebook: Notebook?
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.line.checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.line.checked ? Tokens.Color.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.line.checked ? "Reopen task" : "Complete task")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(TaskParser.displayText(item.line.text))
                        .strikethrough(item.line.checked)
                        .foregroundStyle(item.line.checked ? .secondary : .primary)
                        .lineLimit(2)
                    if let due = item.line.due {
                        chip(TaskListView.dueLabel(due, now: Date(), calendar: .current), symbol: "calendar",
                             tint: !item.line.checked && TaskListView.isOverdue(due) ? .red : Tokens.Color.accent)
                    }
                    if let remind = item.line.remind, !item.line.remindDone {
                        chip(TaskListView.dueLabel(remind, now: Date(), calendar: .current), symbol: "bell", tint: .purple)
                    }
                }
                HStack(spacing: 4) {
                    if let notebook {
                        Circle().fill(notebook.color).frame(width: 6, height: 6)
                    }
                    Text(notebook.map { "\(item.noteTitle) · \($0.name)" } ?? item.noteTitle)
                        .lineLimit(1)
                }
                .font(Tokens.Font.cardMeta)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

extension TaskListView {
    static func isOverdue(_ due: LocalDateTime, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let line = TaskLine(paragraph: 0, text: "", checked: false, due: due, remind: nil, remindDone: false, textHash: "")
        return NoteStore.group(of: line, now: now, calendar: calendar) == .overdue
    }
}
