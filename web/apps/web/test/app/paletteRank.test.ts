import { describe, expect, it } from 'vitest';
import { rankPalette } from '../../app/utils/paletteRank';

const note = (id: string, title: string, updatedAt = '2026-10-20T10:00:00Z') => ({ id, title, updatedAt, isPinned: false });
const commands = [
  { id: 'newNote', title: 'New Note', keywords: ['create'] },
  { id: 'settings', title: 'Settings…', keywords: ['preferences'] },
  { id: 'showTasks', title: 'Show Tasks', keywords: ['todo'] },
];

describe('rankPalette (native PaletteRanker)', () => {
  it('finds notes by spread-out letters: "gn" → Grocery Notes', () => {
    const rows = rankPalette({ query: 'gn', notes: [note('a', 'Ginger'), note('b', 'Grocery Notes')], notebooks: [], commands });
    expect(rows[0]).toMatchObject({ kind: 'note', id: 'b', matchedIndices: [0, 8] });
  });

  it('puts New Note "…" after every match, so Return opens a match instead of creating', () => {
    const rows = rankPalette({ query: 'set', notes: [note('a', 'Sunset photos')], notebooks: [], commands });
    expect(rows.at(-1)).toMatchObject({ kind: 'create', title: 'set' });
    expect(rows[0]!.kind).not.toBe('create');
  });

  it('offers no create row when a note already has that title', () => {
    const rows = rankPalette({ query: 'grocery notes', notes: [note('b', 'Grocery Notes')], notebooks: [], commands });
    expect(rows.some((r) => r.kind === 'create')).toBe(false);
  });

  it('`>` lists commands only, by title when empty', () => {
    expect(rankPalette({ query: '>', notes: [note('a', 'Settings notes')], notebooks: [], commands }).map((r) => r.title)).toEqual(['New Note', 'Settings…', 'Show Tasks']);
    expect(rankPalette({ query: '> tsk', notes: [], notebooks: [], commands }).map((r) => r.title)).toEqual(['Show Tasks']);
    expect(rankPalette({ query: '>todo', notes: [], notebooks: [], commands })[0]).toMatchObject({ id: 'showTasks', matchedIndices: [] });
  });

  it('ranks body-only hits after title hits and names nested notebooks by path', () => {
    const rows = rankPalette({
      query: 'acme',
      notes: [note('a', 'Budget', '2026-10-22T00:00:00Z'), note('b', 'Acme call')],
      bodyMatches: new Set(['a']),
      notebooks: [{ id: 'w', name: 'Work' }, { id: 'c', name: 'Acme', parent: 'w' }],
      commands,
    });
    expect(rows.map((r) => r.key)).toEqual(['notebook:c', 'note:b', 'note:a', 'create']);
    expect(rows[0]!.subtitle).toBe('Work · 0 notes');
  });

  it('lists the 10 most recently edited notes with nothing typed', () => {
    const notes = Array.from({ length: 12 }, (_, i) => note(String(i), `N${i}`, `2026-10-${String(10 + i).padStart(2, '0')}T00:00:00Z`));
    const rows = rankPalette({ query: '', notes, notebooks: [], commands });
    expect(rows).toHaveLength(10);
    expect(rows[0]!.id).toBe('11');
  });
});
