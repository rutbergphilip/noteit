/** noteit-doc → a standalone HTML page, for Export as HTML and Print (as native `HTMLWriter`). */
import { type Block, type Inline, type Mark, type NoteItDoc, isAllowedLink, parseNoteLink } from './schema.js';

export interface HtmlOptions {
  title: string;
  /** A `src` for an image (a data: URL to make the page self-contained); undefined drops the image. */
  imageSrc?: (sha: string, mime: string) => string | undefined;
  /** A relative link to a note written by the same export (native ExportLinkContext.href); undefined keeps the text. */
  noteHref?: (link: { id: string; heading?: string }) => string | undefined;
}

/** A heading's HTML `id` (native HeadingSlug): lowercased letters and digits, other runs as `-`. */
export function headingSlug(text: string): string {
  let out = '';
  let dash = false;
  for (const ch of text.toLowerCase()) {
    if (/[\p{L}\p{N}]/u.test(ch)) {
      if (dash && out) out += '-';
      out += ch;
      dash = false;
    } else dash = true;
  }
  return out || 'heading';
}

export const escapeHtml = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const safeColor = (c: string) => (/^#[0-9A-Fa-f]{6}$/.test(c) ? c : undefined);

function markOpen(m: Mark, o: HtmlOptions): [string, string] | undefined {
  switch (m.type) {
    case 'bold':
      return ['<strong>', '</strong>'];
    case 'italic':
      return ['<em>', '</em>'];
    case 'underline':
      return ['<u>', '</u>'];
    case 'strike':
      return ['<s>', '</s>'];
    case 'code':
      return ['<code>', '</code>'];
    case 'textColor': {
      const c = safeColor(m.attrs.color);
      return c ? [`<span style="color:${c}">`, '</span>'] : undefined;
    }
    case 'highlight': {
      const c = safeColor(m.attrs.color);
      return c ? [`<mark style="background-color:${c}">`, '</mark>'] : undefined;
    }
    case 'link': {
      // Note links point at the linked note's file when it's in the same export; otherwise their text is kept.
      const note = parseNoteLink(m.attrs.href);
      if (note) {
        const href = 'id' in note ? o.noteHref?.(note) : undefined;
        return href ? [`<a href="${escapeHtml(href)}">`, '</a>'] : ['<span class="note-link">', '</span>'];
      }
      if (!isAllowedLink(m.attrs.href)) return undefined;
      return [`<a href="${escapeHtml(m.attrs.href)}">`, '</a>'];
    }
    default:
      return undefined;
  }
}

function inline(content: Inline[] | undefined, o: HtmlOptions): string {
  return (content ?? [])
    .map((n) => {
      if (n.type === 'hardBreak') return '<br>';
      if (n.type === 'image') {
        const src = o.imageSrc?.(n.attrs.sha, n.attrs.mime);
        return src ? `<img src="${escapeHtml(src)}" alt="${escapeHtml(n.attrs.name)}"${n.attrs.width ? ` width="${Math.round(n.attrs.width)}"` : ''}>` : `[${escapeHtml(n.attrs.name)}]`;
      }
      if (n.type === 'attachment') return `<span class="file">📎 ${escapeHtml(n.attrs.name)}</span>`;
      let html = escapeHtml(n.text);
      for (const m of [...(n.marks ?? [])].reverse()) {
        const w = markOpen(m, o);
        if (w) html = `${w[0]}${html}${w[1]}`;
      }
      return html;
    })
    .join('');
}

const align = (a?: string) => (a && a !== 'left' ? ` style="text-align:${a}"` : '');

export function docToHtmlBody(doc: NoteItDoc, o: HtmlOptions): string {
  const out: string[] = [];
  // Open lists, innermost last, each with an unclosed <li>: a nested list goes inside its parent item, as native
  // HTMLWriter writes it. Checklists are their own kind of list, so their items never get a bullet.
  const lists: { key: string; tag: string; level: number }[] = [];
  const slugs = new Map<string, number>();
  const headingId = (text: string) => {
    const base = headingSlug(text);
    const n = (slugs.get(base) ?? 0) + 1;
    slugs.set(base, n);
    return n === 1 ? base : `${base}-${n}`;
  };
  const closeLists = (level = -1) => {
    while (lists.length && lists[lists.length - 1]!.level > level) out.push(`</li></${lists.pop()!.tag}>`);
  };
  for (const b of doc.content as Block[]) {
    if (b.type !== 'listItem') closeLists();
    switch (b.type) {
      case 'paragraph':
        out.push(`<p${align(b.attrs?.align)}>${inline(b.content, o) || '<br>'}</p>`);
        break;
      case 'heading':
        out.push(`<h${b.attrs.level} id="${escapeHtml(headingId((b.content ?? []).map((n) => (n.type === 'text' ? n.text : '')).join('')))}"${align(b.attrs.align)}>${inline(b.content, o)}</h${b.attrs.level}>`);
        break;
      case 'codeBlock':
        out.push(`<pre><code>${inline(b.content, o)}</code></pre>`);
        break;
      case 'blockquote':
        out.push(`<blockquote>${b.content.map((p) => `<p>${inline(p.content, o)}</p>`).join('')}</blockquote>`);
        break;
      case 'horizontalRule':
        out.push('<hr>');
        break;
      case 'listItem': {
        const { kind, level } = b.attrs;
        const tag = kind === 'ordered' ? 'ol' : 'ul';
        const key = kind === 'task' ? 'checklist' : tag;
        const start = kind === 'ordered' && (b.attrs.number ?? 1) !== 1 ? ` start="${b.attrs.number}"` : '';
        const opening = kind === 'task' ? '<ul class="checklist">' : `<${tag}${start}>`;
        closeLists(level);
        const last = lists[lists.length - 1];
        if (last && last.level === level) {
          if (last.key === key) out.push('</li>');
          else {
            out.push(`</li></${last.tag}>`);
            lists.pop();
          }
        }
        if (!lists.length || lists[lists.length - 1]!.level < level) {
          out.push(opening);
          lists.push({ key, tag, level });
        }
        const text = inline(b.content, o);
        if (kind === 'task') {
          const box = `<input type="checkbox" disabled${b.attrs.checked ? ' checked' : ''}> `;
          out.push(`<li class="${b.attrs.checked ? 'checked' : 'unchecked'}"${align(b.attrs.align)}>${box}${b.attrs.checked ? `<span class="done">${text}</span>` : text}`);
        } else out.push(`<li${align(b.attrs.align)}>${text}`);
        break;
      }
      case 'table':
        out.push(
          `<table>${(b.content ?? [])
            .map((r) => `<tr>${r.content.map((c) => { const t = c.type === 'tableHeader' ? 'th' : 'td'; return `<${t}>${c.content.map((p) => inline(p.content, o)).join('<br>')}</${t}>`; }).join('')}</tr>`)
            .join('')}</table>`,
        );
        break;
      default:
        break;
    }
  }
  closeLists();
  return out.join('\n');
}

export function docToHtml(doc: NoteItDoc, o: HtmlOptions): string {
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(o.title)}</title>
<style>body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:720px;margin:40px auto;padding:0 20px;color:#1d1d1f}
pre{background:#f5f5f7;padding:12px;border-radius:8px;overflow:auto}code{font-family:ui-monospace,Menlo,monospace}
blockquote{border-left:3px solid #d2d2d7;margin:0;padding-left:14px;color:#555}table{border-collapse:collapse}td,th{border:1px solid #d2d2d7;padding:6px 10px}
ul,ol{padding-left:1.6em}li>ul,li>ol{margin:.2em 0 0}ul.checklist{list-style:none;padding-left:.3em}ul.checklist ul.checklist{padding-left:1.6em}\nul.checklist input{margin:0 .4em 0 0;vertical-align:-1px}.done{color:#6e6e73;text-decoration:line-through}img{max-width:100%}</style></head>
<body>
${docToHtmlBody(doc, o)}
</body></html>
`;
}
