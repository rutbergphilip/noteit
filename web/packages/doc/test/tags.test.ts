import { describe, expect, it } from 'vitest';
import { deriveTags, renameTagInQuery, rewriteTags, tagRenameProblem, type NoteItDoc } from '../src/index.js';

const p = (...content: unknown[]) => ({ type: 'paragraph', content }) as never;
const t = (text: string, marks?: unknown[]) => (marks ? { type: 'text', text, marks } : { type: 'text', text });
const doc = (...content: unknown[]) => ({ type: 'doc', content }) as NoteItDoc;

describe('tag rename, merge and delete (native TagRewriter)', () => {
  it('renames a tag and the tags nested in it, keeping the written case of the rest', () => {
    const d = doc(p(t('Plan #work and #work/Acme, not #workshop or ')), p(t('#work', [{ type: 'code' }])));
    const r = rewriteTags(d, { type: 'rename', from: 'work', to: 'job' })!;
    expect(r.content![0]).toEqual(p(t('Plan #job and #job/Acme, not #workshop or ')));
    expect(r.content![1]).toEqual(d.content![1]);
    expect(deriveTags(r)).toEqual(['job', 'job/acme', 'workshop']);
  });

  it('deletes a tag with one space beside it, and leaves notes without it alone', () => {
    expect(rewriteTags(doc(p(t('Buy #home milk'))), { type: 'delete', tag: 'home' })!.content![0]).toEqual(p(t('Buy milk')));
    expect(rewriteTags(doc(p(t('end #home'))), { type: 'delete', tag: 'home' })!.content![0]).toEqual(p(t('end')));
    expect(rewriteTags(doc(p(t('nothing here'))), { type: 'delete', tag: 'home' })).toBeUndefined();
  });

  it('rewrites a tag split across formatting', () => {
    const r = rewriteTags(doc(p(t('#wo'), t('rk', [{ type: 'bold' }]), t(' x'))), { type: 'rename', from: 'work', to: 'job' })!;
    expect(r.content![0]).toEqual(p(t('#job'), t(' x')));
  });

  it('checks the new name', () => {
    expect(tagRenameProblem('work', 'a b')).toMatch(/letters/);
    expect(tagRenameProblem('work', 'work/sub')).toMatch(/inside itself/);
    expect(tagRenameProblem('a', 'b/c/d/e', ['a/x/y'])).toMatch(/nest up to/);
    expect(tagRenameProblem('work', '#Job')).toBeUndefined();
  });

  it('renames tag: filters in smart folder searches', () => {
    expect(renameTagInQuery('work', 'job', 'tag:work -tag:#work/acme tag:workshop "tag:work"')).toBe('tag:job -tag:#job/acme tag:workshop "tag:work"');
    expect(renameTagInQuery('work', 'my job', 'tag:work')).toBe('tag:"my job"');
  });
});
