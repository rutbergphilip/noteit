/** noteit-doc → a standalone HTML page, for Export as HTML and Print (as native `HTMLWriter`). */
import { type Block, type Inline, type Mark, type NoteItDoc, isAllowedLink, parseNoteLink } from './schema.js';

export interface HtmlOptions {
  title: string;
  /** A `src` for an image (a data: URL to make the page self-contained); undefined drops the image. */
  imageSrc?: (sha: string, mime: string) => string | undefined;
}

export const escapeHtml = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const safeColor = (c: string) => (/^#[0-9A-Fa-f]{6}$/.test(c) ? c : undefined);

function markOpen(m: Mark): [string, string] | undefined {
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
      // Note links have no target outside NoteIt; their text is kept.
      if (parseNoteLink(m.attrs.href) || !isAllowedLink(m.attrs.href)) return undefined;
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
        const w = markOpen(m);
        if (w) html = `${w[0]}${html}${w[1]}`;
      }
      return html;
    })
    .join('');
}

const align = (a?: string) => (a && a !== 'left' ? ` style="text-align:${a}"` : '');

export function docToHtmlBody(doc: NoteItDoc, o: HtmlOptions): string {
  const out: string[] = [];
  let list: { tag: string; level: number }[] = [];
  const closeLists = (level = -1) => {
    while (list.length && list[list.length - 1]!.level > level) out.push(`</${list.pop()!.tag}>`);
  };
  for (const b of doc.content as Block[]) {
    if (b.type !== 'listItem') closeLists();
    switch (b.type) {
      case 'paragraph':
        out.push(`<p${align(b.attrs?.align)}>${inline(b.content, o) || '<br>'}</p>`);
        break;
      case 'heading':
        out.push(`<h${b.attrs.level}${align(b.attrs.align)}>${inline(b.content, o)}</h${b.attrs.level}>`);
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
        const tag = b.attrs.kind === 'ordered' ? 'ol' : 'ul';
        closeLists(b.attrs.level);
        const top = list[list.length - 1];
        if (top && top.level === b.attrs.level && top.tag !== tag) closeLists(b.attrs.level - 1);
        if (!list.length || list[list.length - 1]!.level < b.attrs.level) {
          const start = b.attrs.kind === 'ordered' && (b.attrs.number ?? 1) !== 1 ? ` start="${b.attrs.number}"` : '';
          out.push(`<${tag}${b.attrs.kind === 'task' ? ' class="tasks"' : ''}${start}>`);
          list.push({ tag, level: b.attrs.level });
        }
        const box = b.attrs.kind === 'task' ? `<input type="checkbox" disabled${b.attrs.checked ? ' checked' : ''}> ` : '';
        out.push(`<li>${box}${inline(b.content, o)}</li>`);
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
  list = [];
  return out.join('\n');
}

export function docToHtml(doc: NoteItDoc, o: HtmlOptions): string {
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(o.title)}</title>
<style>body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:720px;margin:40px auto;padding:0 20px;color:#1d1d1f}
pre{background:#f5f5f7;padding:12px;border-radius:8px;overflow:auto}code{font-family:ui-monospace,Menlo,monospace}
blockquote{border-left:3px solid #d2d2d7;margin:0;padding-left:14px;color:#555}table{border-collapse:collapse}td,th{border:1px solid #d2d2d7;padding:6px 10px}
ul.tasks{list-style:none;padding-left:4px}img{max-width:100%}</style></head>
<body>
${docToHtmlBody(doc, o)}
</body></html>
`;
}
