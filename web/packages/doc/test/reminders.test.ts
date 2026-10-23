import { describe, expect, it } from 'vitest';
import { parseLocalDateTime, reminderId } from '../src/index.js';

describe('reminderId (native ReminderIdentity)', () => {
  it('matches the Swift test vector and ignores the tokens in the line', () => {
    const at = parseLocalDateTime('2026-10-20 09:00')!;
    expect(reminderId('6B1E2F9A-3C4D-4E5F-8A9B-0C1D2E3F4A5B', at, 'call the supplier @remind(2026-10-20 09:00)')).toBe('C3E8118C-1DED-8134-B864-29B7C62E2B45');
    expect(reminderId('6b1e2f9a-3c4d-4e5f-8a9b-0c1d2e3f4a5b', at, 'call the supplier')).toBe('C3E8118C-1DED-8134-B864-29B7C62E2B45');
  });
});
