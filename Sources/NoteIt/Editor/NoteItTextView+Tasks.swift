import AppKit
import NoteItCore

extension NoteItTextView {
    /// The line around `location` without its line break.
    func lineRange(at location: Int) -> NSRange {
        var range = paragraphRange(at: location)
        while range.length > 0, let scalar = UnicodeScalar(nsString.character(at: NSMaxRange(range) - 1)),
              CharacterSet.newlines.contains(scalar) {
            range.length -= 1
        }
        return range
    }

    /// The line around `location` when it's a checklist item.
    func taskLineRange(at location: Int) -> NSRange? {
        let line = lineRange(at: location)
        let text = nsString.substring(with: line)
        guard text.hasPrefix(ChecklistMarkers.unchecked + "\t") || text.hasPrefix(ChecklistMarkers.checked + "\t") else { return nil }
        return line
    }

    private func maskedLine(_ line: NSRange) -> String {
        NoteStore.maskedForTokens(storage.attributedSubstring(from: line))
    }

    private func existingToken(_ kind: NoteStore.LineToken, in line: NSRange) -> (value: LocalDateTime, done: Bool)? {
        for token in TokenGrammar.tokens(inMasked: maskedLine(line)) {
            switch (token.kind, kind) {
            case (.due(let value), .due): return (value, false)
            case (.remind(let value, let done), .remind): return (value, done)
            default: continue
            }
        }
        return nil
    }

    /// Writes, replaces or removes a `@due`/`@remind` token in a line as one undoable change.
    func writeLineToken(_ kind: NoteStore.LineToken, value: String?, line: NSRange, actionName: String) {
        guard isEditable, NSMaxRange(line) <= storage.length else { return }
        let copy = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: line))
        NoteStore.setToken(kind, value: value, paragraph: NSRange(location: 0, length: copy.length), in: copy)
        guard !copy.isEqual(to: storage.attributedSubstring(from: line)) else { return }
        let caret = selectedRange()
        replace(line, with: copy, actionName: actionName)
        let delta = copy.length - line.length
        if caret.location >= NSMaxRange(line) {
            setSelectedRange(clamp(NSRange(location: caret.location + delta, length: 0)))
        } else {
            setSelectedRange(clamp(caret))
        }
        tokenStyler.restyleAll()
    }

    private func rect(for range: NSRange) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return bounds }
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect.width < 1 ? NSRect(x: rect.minX, y: rect.minY, width: 1, height: max(rect.height, 1)) : rect
    }

    /// Format › Task › Set Due Date…: the date picker for the checklist item under the caret.
    @objc func setDueDate(_ sender: Any?) {
        guard isEditable, let line = taskLineRange(at: selectedRange().location) else {
            NSSound.beep()
            return
        }
        let existing = existingToken(.due, in: line)?.value
        showDatePopover(.due, title: "Due Date", initial: existing, line: line, anchor: line, canRemove: existing != nil)
    }

    /// Format › Task › Add Reminder…: reads the date written in the line under the caret and adds `@remind(…)`;
    /// without a date in the line, opens the date picker.
    @objc func addReminder(_ sender: Any?) {
        let line = lineRange(at: selectedRange().location)
        guard isEditable, line.length > 0 else {
            NSSound.beep()
            return
        }
        let minutes = NoteStore.reminderDefaultMinutes()
        let existing = existingToken(.remind, in: line)
        let masked = maskedLine(line)
        guard existing == nil,
              let found = NoteStore.reminderDate(inLine: masked, now: Date(), calendar: .current, defaultMinutes: minutes) else {
            showDatePopover(.remind, title: "Reminder", initial: existing?.value, line: line, anchor: line, canRemove: existing != nil)
            return
        }
        writeLineToken(.remind, value: "@remind(\(found.token))", line: line, actionName: "Set Reminder")
        let updated = lineRange(at: min(line.location, storage.length))
        let message = ReminderSetPopover.message(for: found, now: Date(), calendar: .current)
        DatePopoverPresenter.showReminderSet(message, offersLogin: ReminderLoginOffer.take(), relativeTo: rect(for: updated),
                                             of: self) { [weak self] in
            guard let self else { return }
            let current = self.lineRange(at: min(updated.location, self.storage.length))
            self.showDatePopover(.remind, title: "Reminder", initial: found, line: current, anchor: current, canRemove: true)
        }
    }

    /// A click on a `@due`/`@remind` chip.
    func editDateToken(_ range: NSRange) {
        guard isEditable, NSMaxRange(range) <= storage.length else { return }
        let line = lineRange(at: range.location)
        let text = nsString.substring(with: range)
        let kind: NoteStore.LineToken = text.hasPrefix("@remind(") ? .remind : .due
        let existing = existingToken(kind, in: line)?.value
        showDatePopover(kind, title: kind == .due ? "Due Date" : "Reminder", initial: existing, line: line, anchor: range,
                        canRemove: true)
    }

    private func showDatePopover(_ kind: NoteStore.LineToken, title: String, initial: LocalDateTime?, line: NSRange,
                                 anchor: NSRange, canRemove: Bool) {
        let lineText = nsString.substring(with: line)
        let name = kind == .due ? "due" : "remind"
        // The line may have moved by the time the popover closes; find it again by its text.
        let locate: (NoteItTextView) -> NSRange? = { view in
            if NSMaxRange(line) <= view.storage.length, view.nsString.substring(with: line) == lineText { return line }
            let found = view.nsString.range(of: lineText)
            return found.location == NSNotFound ? nil : view.lineRange(at: found.location)
        }
        DatePopoverPresenter.show(title: title, initial: initial, relativeTo: rect(for: anchor), of: self, onSet: { [weak self] value in
            guard let self, let target = locate(self) else { return }
            var stored = value
            if kind == .remind, !stored.hasTime {
                let minutes = UserDefaults.standard.object(forKey: PrefKey.reminderDefaultTime) as? Int ?? PrefDefault.reminderDefaultTime
                stored = stored.withTime(hour: minutes / 60 % 24, minute: minutes % 60)
            }
            self.writeLineToken(kind, value: "@\(name)(\(stored.token))", line: target,
                                actionName: kind == .due ? "Set Due Date" : "Set Reminder")
            if kind == .remind, ReminderLoginOffer.take() {
                let updated = self.lineRange(at: min(target.location, self.storage.length))
                let message = ReminderSetPopover.message(for: stored, now: Date(), calendar: .current)
                // After the date popover has gone, so the two don't fight over the anchor.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    DatePopoverPresenter.showReminderSet(message, offersLogin: true, relativeTo: self.rect(for: updated), of: self,
                                                         onChange: nil)
                }
            }
        }, onRemove: canRemove ? { [weak self] in
            guard let self, let target = locate(self) else { return }
            self.writeLineToken(kind, value: nil, line: target, actionName: kind == .due ? "Remove Due Date" : "Remove Reminder")
        } : nil, onDone: kind == .remind && NoteStore.reminderDoneEdit(forMaskedLine: maskedLine(line)) != nil ? { [weak self] in
            guard let self, let target = locate(self) else { return }
            self.markReminderDone(line: target)
        } : nil)
    }

    private func markReminderDone(line: NSRange) {
        guard isEditable, NSMaxRange(line) <= storage.length,
              let edit = NoteStore.reminderDoneEdit(forMaskedLine: maskedLine(line)) else { return }
        switch edit {
        case .check: toggleCheckbox(atParagraphStart: line.location)
        case .markDone(let token): writeLineToken(.remind, value: token, line: line, actionName: "Mark Reminder Done")
        }
    }

    /// After `)` closes `@due(…)` or `@remind(…)` written in words: rewrites it as a full date. True when it did.
    @discardableResult
    func formatDateTokenAfterTyping(at location: Int) -> Bool {
        guard isEditable, location > 0, location <= storage.length else { return false }
        let line = lineRange(at: location - 1)
        guard blockKind(ofParagraph: paragraphRange(at: location - 1)) != .code else { return false }
        let upto = NSRange(location: line.location, length: location - line.location)
        let masked = NoteStore.maskedForTokens(storage.attributedSubstring(from: upto))
        let minutes = UserDefaults.standard.object(forKey: PrefKey.reminderDefaultTime) as? Int ?? PrefDefault.reminderDefaultTime
        guard let rewrite = DateTokenAutoFormat.rewrite(masked, now: Date(), calendar: .current, reminderMinutes: minutes) else {
            return false
        }
        let target = NSRange(location: line.location + rewrite.range.location, length: rewrite.range.length)
        let attributes = storage.attributes(at: target.location, effectiveRange: nil)
        let replacement = NSAttributedString(string: rewrite.replacement, attributes: attributes)
        let done = replace(target, with: replacement,
                           select: NSRange(location: target.location + replacement.length, length: 0), actionName: "Format Date")
        if done { tokenStyler.restyleAll() }
        return done
    }
}
