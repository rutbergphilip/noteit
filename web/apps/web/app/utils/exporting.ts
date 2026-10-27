import { type BodyContainer, defaultAttachmentPath, docToHtml, docToMarkdown, type FolderExportFormat, noteLink, planAllExport, planNotebookExport, writeFolderExport, zipFolderExport } from '@noteit/doc';
import { useNoteit } from '~/composables/useNoteit';

export type ExportFormat = 'markdown' | 'html' | 'noteitdoc';

const fileName = (title: string) => (title || 'Untitled').replace(/[\\/:*?"<>|]/g, '-').slice(0, 80);

function download(name: string, blob: Blob): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

async function load(id: string): Promise<{ title: string; container: BodyContainer } | undefined> {
  const { client, toast } = useNoteit();
  const opened = await client().getNote(id);
  if (!opened?.container) {
    toast("This note can't be exported here. Open NoteIt on your Mac to export it.", 'error');
    return undefined;
  }
  return { title: opened.row.title, container: opened.container };
}

/** Names of linked notes for `[[wiki links]]`, as native export writes them. */
function noteName(id: string): string | undefined {
  const { state } = useNoteit();
  return state.notes.find((n) => n.id.toUpperCase() === id.toUpperCase())?.title || undefined;
}

const dataUrl = (c: BodyContainer) => (sha: string) => {
  const a = c.attachments[sha];
  return a && /^image\//.test(a.mime) ? `data:${a.mime};base64,${a.data}` : undefined;
};

export function noteMarkdown(container: BodyContainer): string {
  return docToMarkdown(container.doc, { noteName, attachmentPath: defaultAttachmentPath });
}

/** Export Note As… (native ⇧⌘S): Markdown, a self-contained HTML page, or the NoteIt document itself. */
export async function exportNote(id: string, format: ExportFormat): Promise<void> {
  const note = await load(id);
  if (!note) return;
  const name = fileName(note.title);
  if (format === 'markdown') download(`${name}.md`, new Blob([noteMarkdown(note.container)], { type: 'text/markdown' }));
  else if (format === 'html') download(`${name}.html`, new Blob([docToHtml(note.container.doc, { title: note.title || 'Untitled', imageSrc: dataUrl(note.container) })], { type: 'text/html' }));
  else download(`${name}.noteitdoc`, new Blob([JSON.stringify(note.container)], { type: 'application/json' }));
}

/**
 * Export Notebook… and Export All Notes… (native NoteExporter): the same folders and file names as on the Mac, as a
 * zip named after the top folder. Notes this browser can't read (locked, or from an older Mac) are left out and named.
 */
export async function exportFolder(notebookID: string | undefined, format: FolderExportFormat): Promise<void> {
  const { state, client, toast } = useNoteit();
  const plan = notebookID ? planNotebookExport(notebookID, state.notebooks, state.notes, format) : planAllExport(state.notebooks, state.notes, format);
  const bodies = new Map<string, BodyContainer>();
  for (const f of plan.files) {
    const opened = await client().getNote(f.note.id);
    if (opened?.container && opened.readOnly !== 'locked' && opened.readOnly !== 'legacy') bodies.set(f.note.id, opened.container);
  }
  const result = writeFolderExport(plan, state.notes, (id) => bodies.get(id));
  download(`${plan.root}.zip`, new Blob([zipFolderExport(result) as BlobPart], { type: 'application/zip' }));
  const total = plan.files.length;
  const done = result.written < total ? `Exported ${result.written} of ${total} notes` : result.written === 1 ? 'Exported 1 note' : `Exported ${result.written} notes`;
  if (!result.skipped.length) return toast(`${done} to “${plan.root}.zip”`, 'success');
  const shown = result.skipped.slice(0, 10).map((t) => `“${t}”`).join(', ');
  const more = result.skipped.length > 10 ? ` and ${result.skipped.length - 10} more` : '';
  toast(`${done}. Not exported: ${shown}${more} can't be read here; export ${result.skipped.length === 1 ? 'it' : 'them'} from NoteIt on your Mac.`, 'info');
}

/** Print… (native ⌘P); the browser's print dialog also saves as PDF. */
export async function printNote(id: string): Promise<void> {
  const note = await load(id);
  if (!note) return;
  const frame = document.createElement('iframe');
  frame.style.cssText = 'position:fixed;width:0;height:0;border:0;opacity:0';
  frame.setAttribute('sandbox', 'allow-modals allow-same-origin');
  frame.srcdoc = docToHtml(note.container.doc, { title: note.title || 'Untitled', imageSrc: dataUrl(note.container) });
  frame.onload = () => {
    frame.contentWindow?.print();
    setTimeout(() => frame.remove(), 1000);
  };
  document.body.append(frame);
}

async function copyText(text: string, done: string): Promise<void> {
  const { toast } = useNoteit();
  try {
    await navigator.clipboard.writeText(text);
    toast(done, 'success');
  } catch {
    toast("Couldn't copy to the clipboard.", 'error');
  }
}

/** Copy as Markdown (native ⌥⇧⌘C), the whole note. */
export async function copyMarkdown(id: string): Promise<void> {
  const note = await load(id);
  if (note) await copyText(noteMarkdown(note.container), 'Copied as Markdown');
}

/** Copy Note Link (native ⌃⌘L): a `noteit://note/<id>` link, which opens the note in NoteIt on a Mac. */
export async function copyNoteLink(id: string): Promise<void> {
  await copyText(noteLink(id), 'Copied note link');
}
