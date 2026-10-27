// Mirrors native Tests/NoteItTests/ExportTests.swift (naming, folders, note links) for the web's folder export.
import { unzipSync } from 'fflate';
import { describe, expect, it } from 'vitest';
import {
  type BodyContainer,
  type ExportNote,
  type ExportNotebook,
  noteLink,
  planAllExport,
  planNotebookExport,
  sanitizedFileName,
  uniqueFileName,
  writeFolderExport,
  zipFolderExport,
} from '../src/index.js';

let seq = 0;
const id = () => `00000000-0000-4000-8000-${String(++seq).padStart(12, '0')}`;
const notebook = (name: string, sortIndex: number, parent?: string): ExportNotebook => ({ id: id(), name, sortIndex, ...(parent ? { parent } : {}) });
const meta = (title: string, nb: ExportNotebook | undefined, created: number): ExportNote => ({ id: id(), title, createdAt: new Date(created * 1000).toISOString(), ...(nb ? { notebookID: nb.id } : {}) });
const container = (content: BodyContainer['doc']['content'], attachments: BodyContainer['attachments'] = {}): BodyContainer => ({ format: 'noteit-doc', version: 1, doc: { type: 'doc', content }, attachments });
const title = (text: string) => container([{ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text }] }]);
const linked = (before: string, text: string, href: string, after = '') =>
  container([{ type: 'paragraph', content: [...(before ? [{ type: 'text' as const, text: before }] : []), { type: 'text', text, marks: [{ type: 'link', attrs: { href } }] }, ...(after ? [{ type: 'text' as const, text: after }] : [])] }]);
/** Every file and folder under the export's top folder, as native's test lists them. */
const listing = (entries: Record<string, Uint8Array>, root: string) =>
  Object.keys(entries)
    .filter((p) => p !== `${root}/`)
    .map((p) => p.slice(root.length + 1).replace(/\/$/, ''))
    .sort();
const text = (entries: Record<string, Uint8Array>, path: string) => new TextDecoder().decode(entries[path]);

describe('export naming (native ExportNaming)', () => {
  it('sanitizes file names', () => {
    expect(sanitizedFileName('Q3: plan/budget?')).toBe('Q3 planbudget');
    expect(sanitizedFileName('  ..hidden\tnote  ')).toBe('hidden note');
    expect(sanitizedFileName('<>|*"\\')).toBe('Untitled');
    expect(sanitizedFileName('')).toBe('Untitled');
    expect(sanitizedFileName('Käse & Brot – 2026')).toBe('Käse & Brot – 2026');
    expect(sanitizedFileName('a'.repeat(300))).toHaveLength(120);
  });

  it('numbers duplicate names, case-insensitively', () => {
    const taken = new Set<string>();
    expect(uniqueFileName('Note', 'md', taken)).toBe('Note.md');
    expect(uniqueFileName('Note', 'md', taken)).toBe('Note 2.md');
    expect(uniqueFileName('note', 'md', taken)).toBe('note 3.md');
    expect(uniqueFileName('Note', 'html', taken)).toBe('Note.html');
    expect(uniqueFileName('Work', '', taken)).toBe('Work');
    expect(uniqueFileName('Work', '', taken)).toBe('Work 2');
  });
});

describe('folder export (native NoteExporter)', () => {
  it('writes one folder per notebook, oldest note first, loose notes in No Notebook', () => {
    const work = notebook('Work', 0);
    const home = notebook('Home: Garden', 1);
    const empty = notebook('Empty', 2);
    const notes = [meta('Plan', work, 2), meta('Plan', work, 1), meta('Roses / tulips', home, 1), meta('', undefined, 1)];
    const plan = planAllExport([work, home, empty], notes, 'markdown');
    const out = writeFolderExport(plan, notes, (n) => title(notes.find((x) => x.id === n)!.title || 'New Note'));
    expect(plan.root).toBe('NoteIt Export');
    expect(out.written).toBe(4);
    expect(listing(out.entries, plan.root)).toEqual(['Empty', 'Home Garden', 'Home Garden/Roses tulips.md', 'No Notebook', 'No Notebook/New Note.md', 'Work', 'Work/Plan 2.md', 'Work/Plan.md']);
    expect(text(out.entries, 'NoteIt Export/Work/Plan.md')).toBe('# Plan\n');
  });

  it('exports one notebook with its assets', () => {
    const work = notebook('Work', 0);
    const other = notebook('Other', 1);
    const notes = [meta('Trip', work, 1), meta('Elsewhere', other, 1)];
    const sha = 'a'.repeat(64);
    const body = container(
      [
        { type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Trip' }] },
        { type: 'paragraph', content: [{ type: 'image', attrs: { sha, name: 'photo.PNG', mime: 'image/png' } }] },
      ],
      { [sha]: { mime: 'image/png', name: 'photo.PNG', data: btoa('png') } },
    );
    const plan = planNotebookExport(work.id, [work, other], notes, 'markdown');
    const out = writeFolderExport(plan, notes, () => body);
    expect(plan.root).toBe('Work');
    expect(out.written).toBe(1);
    expect(listing(out.entries, 'Work')).toEqual(['Trip assets', 'Trip assets/image-1.png', 'Trip.md']);
    expect(text(out.entries, 'Work/Trip.md')).toBe('# Trip\n\n![](<Trip assets/image-1.png>)\n');
    expect(text(out.entries, 'Work/Trip assets/image-1.png')).toBe('png');
  });

  it('names files in the assets folder as native does', () => {
    const work = notebook('Work', 0);
    const notes = [meta('Files', work, 1)];
    const a = 'b'.repeat(64);
    const b = 'c'.repeat(64);
    const body = container([{ type: 'paragraph', content: [{ type: 'attachment', attrs: { sha: a, name: 'Q3: report.pdf', mime: 'application/pdf' } }, { type: 'attachment', attrs: { sha: b, name: 'Q3: report.pdf', mime: 'application/pdf' } }] }], {
      [a]: { mime: 'application/pdf', name: 'Q3: report.pdf', data: '' },
      [b]: { mime: 'application/pdf', name: 'Q3: report.pdf', data: '' },
    });
    const out = writeFolderExport(planNotebookExport(work.id, [work], notes, 'markdown'), notes, () => body);
    expect(text(out.entries, 'Work/Files.md')).toBe('[Q3 report.pdf](<Files assets/Q3 report.pdf>)[Q3 report 2.pdf](<Files assets/Q3 report 2.pdf>)\n');
  });

  it('nests notebook folders, sharing names with the notes beside them', () => {
    const work = notebook('Work', 0);
    const home = notebook('Home', 1);
    const clients = notebook('Clients', 0, work.id);
    const acme = notebook('Acme', 0, clients.id);
    const planNb = notebook('Plan.md', 1, work.id);
    const notes = [meta('Plan', work, 1), meta('Brief', acme, 1), meta('Call', clients, 1), meta('Garden', home, 1)];
    const all = [work, home, clients, acme, planNb];
    const plan = planAllExport(all, notes, 'markdown');
    const out = writeFolderExport(plan, notes, () => container([]));
    expect(listing(out.entries, plan.root)).toEqual(['Home', 'Home/Garden.md', 'Work', 'Work/Clients', 'Work/Clients/Acme', 'Work/Clients/Acme/Brief.md', 'Work/Clients/Call.md', 'Work/Plan.md', 'Work/Plan.md 2']);
    const one = planNotebookExport(clients.id, all, notes, 'html');
    expect(one.files).toHaveLength(2);
    expect(listing(writeFolderExport(one, notes, () => container([])).entries, 'Clients')).toEqual(['Acme', 'Acme/Brief.html', 'Call.html']);
  });

  it('skips Recently Deleted and notes it cannot read', () => {
    const work = notebook('Work', 0);
    const gone = { ...meta('Gone', work, 2), deletedAt: '2026-01-01T00:00:00Z' };
    const loose = { ...meta('Loose', undefined, 3), deletedAt: '2026-01-01T00:00:00Z' };
    const locked = meta('Locked', work, 4);
    const notes = [meta('Kept', work, 1), gone, loose, locked];
    const plan = planAllExport([work], notes, 'markdown');
    const out = writeFolderExport(plan, notes, (n) => (n === locked.id ? undefined : title('Body')));
    expect(listing(out.entries, plan.root)).toEqual(['Work', 'Work/Kept.md']);
    expect(out.written).toBe(1);
    expect(out.skipped).toEqual(['Locked']);
  });

  it('links to exported notes by their file names in Markdown', () => {
    const work = notebook('Work', 0);
    const plan = meta('Plan', work, 1);
    const old = meta('Plan', work, 0);
    const missing = id();
    const elsewhere = meta('Q[1]|#^', undefined, 0);
    const notes = [plan, old, elsewhere];
    const bodies: Record<string, BodyContainer> = {
      [plan.id]: linked('See ', 'Plan', noteLink(old.id)),
      [old.id]: container([
        linked('', 'Plan 2', noteLink(plan.id, 'Maps')).doc.content[0]!,
        linked('Go ', 'there', noteLink(plan.id, 'Maps'), ' now').doc.content[0]!,
        linked('', 'it', noteLink(elsewhere.id)).doc.content[0]!,
        linked('', 'Gone', noteLink(missing)).doc.content[0]!,
        linked('', 'Later', 'noteit://note?title=Later').doc.content[0]!,
      ]),
    };
    const out = writeFolderExport(planNotebookExport(work.id, [work], notes, 'markdown'), notes, (n) => bodies[n]);
    expect(text(out.entries, 'Work/Plan 2.md')).toBe('See [[Plan]]\n');
    expect(text(out.entries, 'Work/Plan.md')).toBe('[[Plan 2#Maps]]\n\nGo [[Plan 2#Maps|there]] now\n\n[[Q1|it]]\n\nGone\n\n[[Later]]\n');
  });

  it('qualifies a name used in two folders', () => {
    const work = notebook('Work', 0);
    const home = notebook('Home', 1);
    const a = meta('Plan', work, 1);
    const b = meta('Plan', home, 1);
    const notes = [a, b];
    const out = writeFolderExport(planAllExport([work, home], notes, 'markdown'), notes, (n) => (n === a.id ? linked('', 'Plan', noteLink(b.id)) : container([])));
    expect(text(out.entries, 'NoteIt Export/Work/Plan.md')).toBe('[[Home/Plan]]\n');
  });

  it('links between HTML files with relative paths and heading anchors', () => {
    const work = notebook('Work', 0);
    const home = notebook('Home', 1);
    const a = meta('Trip Plan', work, 1);
    const b = meta('Maps & Routes', home, 1);
    const c = meta('Notes', work, 2);
    const heading = { type: 'heading' as const, attrs: { level: 2 as const }, content: [{ type: 'text' as const, text: 'Day One!' }] };
    const bodies: Record<string, BodyContainer> = {
      [a.id]: linked('', 'routes', noteLink(b.id, 'Day One!')),
      [b.id]: container([heading, heading]),
      [c.id]: linked('', 'plan', noteLink(a.id)),
    };
    const notes = [a, b, c];
    const out = writeFolderExport(planAllExport([work, home], notes, 'html'), notes, (n) => bodies[n]);
    expect(text(out.entries, 'NoteIt Export/Work/Trip Plan.html')).toContain('<a href="../Home/Maps%20&amp;%20Routes.html#day-one">routes</a>');
    expect(text(out.entries, 'NoteIt Export/Work/Notes.html')).toContain('<a href="Trip%20Plan.html">plan</a>');
    const maps = text(out.entries, 'NoteIt Export/Home/Maps & Routes.html');
    expect(maps).toContain('<h2 id="day-one">');
    expect(maps).toContain('<h2 id="day-one-2">');
  });

  it('zips the folder', () => {
    const work = notebook('Work', 0);
    const notes = [meta('Plan', work, 1)];
    const out = writeFolderExport(planNotebookExport(work.id, [work], notes, 'markdown'), notes, () => title('Plan'));
    const files = unzipSync(zipFolderExport(out));
    expect(Object.keys(files).sort()).toEqual(['Work/', 'Work/Plan.md']);
    expect(new TextDecoder().decode(files['Work/Plan.md'])).toBe('# Plan\n');
  });
});
