import { describe, expect, it } from 'vitest';
import { parseQuery, rankSearch, searchFold } from '../src/index.js';

// The cases of Swift SearchRankerTests.
const now = new Date(1_800_000_000_000);
const doc = (title: string, body: string, updatedAt = now) => ({ foldedText: searchFold(`${title}\n${body}`), foldedTitle: searchFold(title), tags: [], isPinned: false, updatedAt });
const order = (docs: ReturnType<typeof doc>[], q: string) => rankSearch(docs, parseQuery(q), searchFold(q), now);

describe('Best Match (native SearchRanker)', () => {
  it('ranks a title match above a body match', () => expect(order([doc('Groceries', 'buy invoice paper'), doc('Invoice', 'send it')], 'invoice')).toEqual([1, 0]));
  it('ranks a word start above a mid-word match', () => expect(order([doc('A', 'the reinvoiced batch'), doc('B', 'the invoiced batch')], 'invoice')).toEqual([1, 0]));
  it('breaks ties by recency', () => expect(order([doc('A', 'budget review', new Date(now.getTime() - 200 * 86_400_000)), doc('B', 'budget review')], 'budget')).toEqual([1, 0]));
  it('matches an accented term at a word start', () => expect(order([doc('A', 'xété long'), doc('B', 'été long')], 'été')).toEqual([1, 0]));
});
