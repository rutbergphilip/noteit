/**
 * Pre-filter for pasted HTML before ProseMirror parses it against the schema (which already drops anything it
 * doesn't know, never loads <img> sources and refuses disallowed link schemes). This removes active content and
 * every attribute except the few the schema reads, so nothing in a paste can run or fetch.
 */
const ALLOWED_ATTRS = new Set(['href', 'style', 'data-kind', 'data-level', 'data-number', 'data-checked', 'data-textcolor', 'data-highlight', 'data-font-delta', 'data-type', 'data-language']);
const DROP_ELEMENTS = 'script,style,iframe,object,embed,link,meta,base,form,input,button,textarea,select,svg,math,template,img,video,audio,source,picture,frame,frameset';

export function sanitizePastedHtml(html: string): string {
  if (typeof DOMParser === 'undefined') return '';
  const doc = new DOMParser().parseFromString(html, 'text/html');
  doc.querySelectorAll(DROP_ELEMENTS).forEach((el) => el.remove());
  for (const el of Array.from(doc.body.querySelectorAll('*'))) {
    for (const attr of Array.from(el.attributes)) {
      if (!ALLOWED_ATTRS.has(attr.name.toLowerCase())) el.removeAttribute(attr.name);
    }
    const href = el.getAttribute('href');
    if (href !== null && !/^(https?:|mailto:|tel:|noteit:\/\/note)/i.test(href.trim())) el.removeAttribute('href');
  }
  return doc.body.innerHTML;
}
