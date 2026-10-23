import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { fuzzyEvaluate } from '../src/fuzzy.js';

const vectors = JSON.parse(readFileSync(resolve(__dirname, '../../../../Tests/NoteItCoreTests/Vectors/fuzzy-vectors.json'), 'utf8')) as {
  cases: { query: string; candidate: string; match?: false; score?: number; indices?: number[]; exact?: boolean }[];
};

describe('fuzzy matcher (shared vectors with Swift FuzzyMatcher)', () => {
  for (const v of vectors.cases) {
    it(`${JSON.stringify(v.query)} in ${JSON.stringify(v.candidate)}`, () => {
      const r = fuzzyEvaluate(v.query, v.candidate);
      if (v.match === false) return expect(r).toBeUndefined();
      expect(r).toEqual({ match: { score: v.score, matchedIndices: v.indices }, isExact: v.exact });
    });
  }

  it('ranks word starts above in-word matches ("gn" finds "Grocery Notes" first)', () => {
    expect(fuzzyEvaluate('gn', 'Grocery Notes')!.match.score).toBeGreaterThan(fuzzyEvaluate('gn', 'Ginger')!.match.score);
  });
});
