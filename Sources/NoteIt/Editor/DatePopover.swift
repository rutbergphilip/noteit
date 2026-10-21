import AppKit
import NoteItCore
import SwiftUI

/// The date picker for a task's due date or a reminder: from the editor's token chips, Set Due Date… and the
/// Tasks view.
struct DatePopover: View {
    let title: String
    let onSet: (LocalDateTime) -> Void
    var onRemove: (() -> Void)?
    var onDone: (() -> Void)?
    let onClose: () -> Void

    @State private var date: Date
    @State private var includesTime: Bool
    private let calendar: Calendar

    init(title: String, initial: LocalDateTime?, defaultMinutes: Int = 540, calendar: Calendar = .current,
         onSet: @escaping (LocalDateTime) -> Void, onRemove: (() -> Void)? = nil, onDone: (() -> Void)? = nil,
         onClose: @escaping () -> Void) {
        self.title = title
        self.onSet = onSet
        self.onRemove = onRemove
        self.onDone = onDone
        self.onClose = onClose
        self.calendar = calendar
        let start = initial ?? LocalDateTime(Date(), calendar: calendar, includeTime: false)
        let withTime = start.hasTime ? start : start.withTime(hour: defaultMinutes / 60 % 24, minute: defaultMinutes % 60)
        _date = State(initialValue: withTime.date(in: calendar) ?? Date())
        _includesTime = State(initialValue: initial?.hasTime ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            DatePicker("", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Toggle("Time", isOn: $includesTime)
                if includesTime {
                    DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                }
            }
            HStack {
                if let onRemove {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        onClose()
                    }
                }
                if let onDone {
                    Button("Done") {
                        onDone()
                        onClose()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") {
                    onSet(LocalDateTime(date, calendar: calendar, includeTime: includesTime))
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// Shows a `DatePopover` next to a range of an AppKit view.
@MainActor
enum DatePopoverPresenter {
    private static var current: NSPopover?

    static func show(title: String, initial: LocalDateTime?, relativeTo rect: NSRect, of view: NSView,
                     onSet: @escaping (LocalDateTime) -> Void, onRemove: (() -> Void)?, onDone: (() -> Void)? = nil) {
        current?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let close: () -> Void = { [weak popover] in popover?.close() }
        let minutes = UserDefaults.standard.object(forKey: PrefKey.reminderDefaultTime) as? Int ?? PrefDefault.reminderDefaultTime
        popover.contentViewController = NSHostingController(rootView: DatePopover(
            title: title, initial: initial, defaultMinutes: minutes, onSet: onSet, onRemove: onRemove, onDone: onDone,
            onClose: close))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        current = popover
    }
}

/// "Reminder set for tomorrow at 09:00" with Change…, after a reminder was added. The first time, it also offers
/// Open at Login.
struct ReminderSetPopover: View {
    let message: String
    var offersLogin = false
    let onChange: (() -> Void)?
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill").foregroundStyle(.purple)
                Text(message)
                if let onChange { Button("Change…", action: onChange) }
            }
            if offersLogin {
                Text("Reminders ring only while NoteIt is running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Not Now", action: onClose)
                    Button("Open at Login") {
                        ReminderLoginOffer.accept()
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .fixedSize()
    }

    static func message(for value: LocalDateTime, now: Date, calendar: Calendar) -> String {
        "Reminder set for " + dayAndTime(value, now: now, calendar: calendar)
    }

    /// "today at 09:00", "tomorrow at 09:00" or "Wed 21 Oct at 09:00".
    static func dayAndTime(_ value: LocalDateTime, now: Date, calendar: Calendar) -> String {
        let time = String(format: "%02d:%02d", value.hour ?? 0, value.minute ?? 0)
        let today = LocalDateTime(now, calendar: calendar, includeTime: false)
        let day = value.dateOnly
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).map { LocalDateTime($0, calendar: calendar, includeTime: false) }
        let dayText: String
        if day == today {
            dayText = "today"
        } else if day == tomorrow {
            dayText = "tomorrow"
        } else if let date = day.date(in: calendar) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE d MMM"
            dayText = formatter.string(from: date)
        } else {
            dayText = day.token
        }
        return "\(dayText) at \(time)"
    }
}

extension DatePopoverPresenter {
    static func showReminderSet(_ message: String, offersLogin: Bool = false, relativeTo rect: NSRect, of view: NSView,
                                onChange: (() -> Void)?) {
        let popover = NSPopover()
        popover.behavior = .transient
        let change: (() -> Void)? = onChange.map { onChange in { [weak popover] in
            popover?.close()
            onChange()
        } }
        popover.contentViewController = NSHostingController(rootView: ReminderSetPopover(
            message: message, offersLogin: offersLogin, onChange: change, onClose: { [weak popover] in popover?.close() }))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}
