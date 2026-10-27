import { describe, expect, it } from 'vitest';
import { addingCaptureReminder, captureReminder, localDateTimeToken, parseLocalDateTime, reminderDayAndTime } from '../src/index.js';

// Wednesday 2026-10-21 12:00 in Stockholm (native ReminderStoreTests).
const now = new Date('2026-10-21T10:00:00Z');
const opts = { timeZone: 'Europe/Stockholm', defaultMinutes: 540 };

describe('Quick Capture reminder offer (native ReminderStoreTests)', () => {
  it('offers the future date in the first line only', () => {
    const offer = (title: string, body: string) => {
      const at = captureReminder(title, body, now, opts);
      return at && localDateTimeToken(at);
    };
    expect(offer('Call the bank tomorrow', 'about the loan friday')).toBe('2026-10-22 09:00');
    expect(offer('', '  send invoice friday 3pm\nthen file it')).toBe('2026-10-23 15:00');
    expect(offer('Call the bank', 'about the loan friday')).toBeUndefined();
    expect(offer('Call the bank tomorrow @remind(2026-10-22 08:00)', '')).toBeUndefined();
    expect(offer('Call at 8am today', '')).toBeUndefined();
  });

  it('adds the reminder to the end of the first line', () => {
    const at = parseLocalDateTime('2026-10-22 09:00')!;
    expect(addingCaptureReminder(at, ' Call the bank tomorrow ', 'x').title).toBe('Call the bank tomorrow @remind(2026-10-22 09:00)');
    expect(addingCaptureReminder(at, '', '\nsend invoice tomorrow\nthen file it\n')).toEqual({ title: '', body: 'send invoice tomorrow @remind(2026-10-22 09:00)\nthen file it' });
  });

  it('names the day as the Mac does', () => {
    const at = (t: string) => parseLocalDateTime(t)!;
    expect(reminderDayAndTime(at('2026-10-22 09:00'), now, 'Europe/Stockholm')).toBe('tomorrow at 09:00');
    expect(reminderDayAndTime(at('2026-10-21 18:30'), now, 'Europe/Stockholm')).toBe('today at 18:30');
    expect(reminderDayAndTime(at('2026-10-30 08:00'), now, 'Europe/Stockholm')).toBe('Fri 30 Oct at 08:00');
  });
});
