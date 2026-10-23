import { describe, expect, it } from 'vitest';
import { findMentions, linkMentions, mentionsAreSearched, type NoteItDoc } from '../src/index.js';

const p = (...content: unknown[]) => ({ type: 'paragraph', content }) as never;
const t = (text: string, marks?: unknown[]) => (marks ? { type: 'text', text, marks } : { type: 'text', text });
const doc = (...content: unknown[]) => ({ type: 'doc', content }) as NoteItDoc;

describe('unlinked mentions (native MentionFinder)', () => {
  const d = doc(p(t('Grocery plan')), p(t('Buy for the grocery plan, not groceryplans or '), t('Grocery Plan', [{ type: 'code' }])), p(t('GROCÉRY PLAN!')));
  it('finds whole-word plain-text matches after the first line, ignoring case and accents', () => {
    expect(findMentions(d, 'Grocery Plan')).toEqual({ contexts: ['Buy for the grocery plan, not groceryplans or Grocery Plan', 'GROCÉRY PLAN!'], count: 2 });
  });
  it('links them, keeping the text', () => {
    const linked = linkMentions(d, 'Grocery Plan', 'noteit://note/X')!;
    expect(linked.content![1]).toEqual(p(t('Buy for the '), t('grocery plan', [{ type: 'link', attrs: { href: 'noteit://note/X' } }]), t(', not groceryplans or '), t('Grocery Plan', [{ type: 'code' }])));
    expect(findMentions(linked, 'Grocery Plan').count).toBe(0);
  });
  it('skips short and daily titles', () => {
    expect(mentionsAreSearched('ab')).toBe(false);
    expect(mentionsAreSearched('2026-10-24')).toBe(false);
    expect(mentionsAreSearched('Plan')).toBe(true);
  });
});
