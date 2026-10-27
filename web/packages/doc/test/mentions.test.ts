import { describe, expect, it } from 'vitest';
import { findMentions, linkMentions, mentionsAreSearched, rewriteLinkText, type NoteItDoc } from '../src/index.js';

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

describe('update links on rename (native NoteStoreLinksTests)', () => {
  const id = '8F14E45F-CEEA-467A-9575-5E4F0C6B7A21';
  const link = (href: string, extra: unknown[] = []) => [{ type: 'link', attrs: { href } }, ...extra];
  const own = `noteit://note/${id}`;

  it('rewrites only links to the note whose text reads the old title, keeping their formatting', () => {
    const d = doc(
      p(t('Source')),
      p(t('See '), t('atlas', link(own, [{ type: 'bold' }])), t(' and '), t('the map', link(own))),
      p(t('At', link(own)), t('las ', link(own, [{ type: 'italic' }]))),
      p(t('Atlas', link(`${own}?heading=Intro`)), t(' '), t('Atlas', link('noteit://note/00000000-0000-0000-0000-000000000001'))),
    );
    const r = rewriteLinkText(d, id.toLowerCase(), ' Atlas', 'Atlas 2')!;
    expect(r.count).toBe(2);
    expect(r.doc.content![1]).toEqual(p(t('See '), t('Atlas 2', link(own, [{ type: 'bold' }])), t(' and '), t('the map', link(own))));
    expect(r.doc.content![2]).toEqual(p(t('Atlas 2', link(own))));
    expect(r.doc.content![3]).toEqual(d.content![3]);
  });

  it('leaves aliases alone and does nothing for an empty title', () => {
    const d = doc(p(t('Source')), p(t('Atlas map', link(own))));
    expect(rewriteLinkText(d, id, 'Atlas', 'Globe')).toBeUndefined();
    expect(rewriteLinkText(doc(p(t('Atlas', link(own)))), id, 'Atlas', '  ')).toBeUndefined();
  });
});
