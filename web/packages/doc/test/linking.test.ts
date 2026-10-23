import { describe, expect, it } from 'vitest';
import { linkSuggestions, noteLinkURL, parseLinkQuery, parseNoteLink, wikiLink } from '../src/index.js';

const notes = [
  { id: 'AAAAAAAA-0000-0000-0000-000000000001', title: 'Grocery Notes', updatedAt: '2026-10-20T00:00:00Z' },
  { id: 'AAAAAAAA-0000-0000-0000-000000000002', title: 'Plans / ideas', notebookID: 'NB', updatedAt: '2026-10-21T00:00:00Z' },
  { id: 'AAAAAAAA-0000-0000-0000-000000000003', title: 'Plans / ideas', updatedAt: '2026-10-22T00:00:00Z' },
];
const here = { notes, noteID: 'AAAAAAAA-0000-0000-0000-00000000000F', noteTitle: 'Today', notebookID: 'NB' };

describe('[[ links (native LinkQuery, NoteLink.url)', () => {
  it('parses title#heading|alias', () => {
    expect(parseLinkQuery(' Plans # Week 1 | this week ')).toEqual({ title: 'Plans', heading: 'Week 1', alias: 'this week' });
    expect(parseLinkQuery('#Top')).toEqual({ title: '', heading: 'Top' });
  });

  it('writes URLs as native does, and they read back', () => {
    expect(noteLinkURL({ title: 'Plans / ideas & more', heading: 'A#B' })).toBe('noteit://note?title=Plans%20/%20ideas%20%26%20more&heading=A%23B');
    expect(parseNoteLink(noteLinkURL({ title: 'Plans / ideas & more' }))).toEqual({ title: 'Plans / ideas & more' });
    expect(noteLinkURL({ id: 'aaaaaaaa-0000-0000-0000-000000000001', heading: 'x y' })).toBe('noteit://note/AAAAAAAA-0000-0000-0000-000000000001?heading=x%20y');
  });

  it('resolves a title in the same notebook first, else links by title', () => {
    expect(wikiLink('plans / IDEAS', here)).toEqual({ href: 'noteit://note/AAAAAAAA-0000-0000-0000-000000000002', text: 'plans / IDEAS' });
    expect(wikiLink('Nowhere|go', here)).toEqual({ href: 'noteit://note?title=Nowhere', text: 'go' });
    expect(wikiLink('#Intro', here)).toEqual({ href: 'noteit://note/AAAAAAAA-0000-0000-0000-00000000000F?heading=Intro', text: 'Intro' });
    expect(wikiLink('Grocery Notes#Milk', here)?.text).toBe('Grocery Notes › Milk');
  });

  it('suggests notes by fuzzy title', () => {
    expect(linkSuggestions(notes, 'gn').map((n) => n.title)).toEqual(['Grocery Notes']);
    expect(linkSuggestions(notes, '').length).toBe(3);
  });
});
