import NoteItCore
import SwiftUI

/// The month calendar for daily notes (spec §10): dots on days with a note, today circled.
struct DailyCalendarView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var month: DayKey
    @State private var focused: DayKey
    @State private var pendingDay: DayKey?
    @FocusState private var hasFocus: Bool
    let onDone: () -> Void

    private static var calendar: Calendar {
        var calendar = DayKey.dailyCalendar()
        calendar.locale = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    init(selected: DayKey? = nil, onDone: @escaping () -> Void) {
        let day = selected ?? DayKey(Date(), calendar: DayKey.dailyCalendar())
        _month = State(initialValue: DayKey(year: day.year, month: day.month, day: 1))
        _focused = State(initialValue: day)
        self.onDone = onDone
    }

    var body: some View {
        let calendar = Self.calendar
        let today = DayKey(Date(), calendar: calendar)
        let days = monthDate.map { store.dailyNoteDays(inMonthOf: $0) } ?? []
        VStack(spacing: 10) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous Month")
                Spacer()
                Text(monthTitle).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Next Month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(width: 30, height: 30) }
                ForEach(1...daysInMonth, id: \.self) { number in
                    let day = DayKey(year: month.year, month: month.month, day: number)
                    dayCell(day, hasNote: days.contains(day), isToday: day == today)
                }
            }
            if let pendingDay {
                Button("Create note for \(Self.longName(pendingDay))") { open(pendingDay) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 262)
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onAppear { hasFocus = true }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-7); return .handled }
        .onKeyPress(.downArrow) { move(7); return .handled }
        .onKeyPress(.return) { open(focused); return .handled }
        .onKeyPress(.escape) { onDone(); return .handled }
    }

    private func dayCell(_ day: DayKey, hasNote: Bool, isToday: Bool) -> some View {
        Button {
            focused = day
            if hasNote { open(day) } else { pendingDay = day }
        } label: {
            VStack(spacing: 1) {
                Text("\(day.day)")
                    .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                    .monospacedDigit()
                Circle()
                    .fill(hasNote ? Tokens.Color.accent : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(day == focused ? Tokens.Color.accent.opacity(0.18) : .clear)
            )
            .overlay(Circle().strokeBorder(isToday ? Tokens.Color.accent : .clear, lineWidth: 1.5).padding(1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.longName(day) + (hasNote ? ", has a note" : ""))
    }

    private func open(_ day: DayKey) {
        store.openDailyNote(for: day)
        onDone()
        WindowRouter.focusEditor()
    }

    private var monthDate: Date? { month.date(calendar: Self.calendar, hour: 12) }

    private var monthTitle: String {
        guard let date = monthDate else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: date)
    }

    private var weekdaySymbols: [String] {
        let calendar = Self.calendar
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private var leadingBlanks: Int {
        guard let date = monthDate else { return 0 }
        let weekday = Self.calendar.component(.weekday, from: date)
        return (weekday - Self.calendar.firstWeekday + 7) % 7
    }

    private var daysInMonth: Int {
        guard let date = monthDate else { return 30 }
        return Self.calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    private func shiftMonth(_ delta: Int) {
        guard let date = monthDate, let shifted = Self.calendar.date(byAdding: .month, value: delta, to: date) else { return }
        let key = DayKey(shifted, calendar: Self.calendar)
        month = DayKey(year: key.year, month: key.month, day: 1)
        pendingDay = nil
    }

    private func move(_ days: Int) {
        guard let date = focused.date(calendar: Self.calendar, hour: 12),
              let moved = Self.calendar.date(byAdding: .day, value: days, to: date) else { return }
        focused = DayKey(moved, calendar: Self.calendar)
        month = DayKey(year: focused.year, month: focused.month, day: 1)
        pendingDay = nil
    }

    /// "Tuesday, 14 October" in the Mac's language.
    static func longName(_ day: DayKey) -> String {
        guard let date = day.date(calendar: calendar, hour: 12) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date)
    }
}

extension Notification.Name {
    static let noteItShowDailyCalendar = Notification.Name("noteItShowDailyCalendar")
}
