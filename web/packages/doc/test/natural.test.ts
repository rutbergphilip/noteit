import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { dateTokenRewrite, localDateTimeToken, parseNaturalDate } from '../src/index.js';

const vectors = JSON.parse(readFileSync(resolve(__dirname, '../../../../Tests/NoteItCoreTests/Vectors/organise-vectors.json'), 'utf8')).dates as {
  now: string;
  timeZone: string;
  cases: { input: string; due: string | null; remind: string | null }[];
};

describe('natural dates (shared vectors with Swift NaturalDateParser)', () => {
  const now = new Date(vectors.now);
  for (const v of vectors.cases) {
    it(v.input, () => {
      const due = parseNaturalDate(v.input, now, { timeZone: vectors.timeZone });
      const remind = parseNaturalDate(v.input, now, { timeZone: vectors.timeZone, defaultHour: 9 });
      expect(due ? localDateTimeToken(due.value) : null).toBe(v.due);
      expect(remind ? localDateTimeToken(remind.value) : null).toBe(v.remind);
    });
  }

  it('rewrites @due(fri) and @remind(tomorrow) when ) is typed, as native DateTokenAutoFormat', () => {
    const opts = { timeZone: vectors.timeZone };
    expect(dateTokenRewrite('Pay rent @due(fri)', now, opts)).toEqual({ start: 9, end: 18, replacement: '@due(2026-10-23)' });
    expect(dateTokenRewrite('@remind(tomorrow)', now, opts)?.replacement).toBe('@remind(2026-10-20 09:00)');
    expect(dateTokenRewrite('@remind(tomorrow 3pm done)', now, opts)?.replacement).toBe('@remind(2026-10-20 15:00 done)');
    expect(dateTokenRewrite('@due(2026-10-21)', now, opts)).toBeUndefined();
    expect(dateTokenRewrite('@due(call bob fri)', now, opts)).toBeUndefined();
  });
});
