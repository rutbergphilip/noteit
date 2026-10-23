import { getSchema } from '@tiptap/core';
import { DOMSerializer, Node as PMNode } from '@tiptap/pm/model';
import { describe, expect, it } from 'vitest';
import { emptyContainer, type BodyContainer, validateContainer } from '../src/index.js';
import { noteItExtensions, prepareForEditor, safeAlign, safeBlobUrl, safeColor, safeHref, safeInt, safeLanguage } from '../src/tiptap/index.js';

const EVIL_CSS = 'left; background-image: url(https://evil.example/x.png)';

function container(content: unknown[]): BodyContainer {
  return { ...emptyContainer(), doc: { type: 'doc', content } } as unknown as BodyContainer;
}

/** Serializes through the real renderHTML specs into a tiny DOM stand-in and returns every attribute written. */
function renderedAttributes(doc: unknown): string[] {
  const attrs: string[] = [];
  const el = (tag: string) => ({
    tagName: tag,
    children: [] as unknown[],
    setAttribute: (k: string, v: string) => attrs.push(`${tag}.${k}=${v}`),
    setAttributeNS: (_ns: string, k: string, v: string) => attrs.push(`${tag}.${k}=${v}`),
    appendChild(c: unknown) {
      this.children.push(c);
      return c;
    },
  });
  const fakeDocument = { createElement: el, createElementNS: (_: string, t: string) => el(t), createTextNode: (t: string) => ({ text: t }), createDocumentFragment: () => el('#fragment') };
  const schema = getSchema(noteItExtensions());
  const node = PMNode.fromJSON(schema, doc);
  DOMSerializer.fromSchema(schema).serializeFragment(node.content, { document: fakeDocument as unknown as Document });
  return attrs;
}

describe('attribute sanitizers', () => {
  it('allowlist align, colors, ints, links, blob URLs and languages', () => {
    expect(safeAlign('center')).toBe('center');
    expect(safeAlign(EVIL_CSS)).toBeNull();
    expect(safeAlign('CENTER')).toBeNull();
    for (const bad of ['red', '#fff', '#12345g', 'rgb(1,2,3)', '#123456; background:url(x)', '#1234567']) expect(safeColor(bad), bad).toBeNull();
    expect(safeColor('#A1b2C3')).toBe('#A1b2C3');
    expect(safeInt('3', 0, 8)).toBe(3);
    expect(safeInt('3px', 0, 8)).toBeNull();
    expect(safeInt(9, 0, 8)).toBeNull();
    for (const bad of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', ' javascript:x', 'data:text/html,x', 'vbscript:x', 'file:///etc/passwd', 'noteit://settings', '//evil.example', 'https://ok.example/\nx']) {
      expect(safeHref(bad), bad).toBeNull();
    }
    expect(safeHref('https://example.com/a?b=1')).toBe('https://example.com/a?b=1');
    expect(safeHref('noteit://note/8F14E45F-CEEA-467A-9575-5E4F0C6B7A21')).not.toBeNull();
    expect(safeBlobUrl('blob:http://localhost:3000/0b7c1f2e-1111-2222-3333-444455556666')).not.toBeNull();
    for (const bad of ['https://evil.example/x.png', 'data:image/png;base64,AAAA', 'blob:x") url(https://evil', 'javascript:x']) expect(safeBlobUrl(bad), bad).toBeNull();
    expect(safeLanguage('swift')).toBe('swift');
    expect(safeLanguage('x" onmouseover="y')).toBeNull();
  });
});

describe('malicious documents', () => {
  const hostile = [
    { type: 'paragraph', attrs: { align: EVIL_CSS, indent: '1; background:url(https://evil.example)' }, content: [{ type: 'text', text: 'p' }] },
    { type: 'heading', attrs: { level: 1, align: 'right;color:red' }, content: [{ type: 'text', text: 'h' }] },
    { type: 'listItem', attrs: { kind: 'bullet" onclick="x', level: '2; x', align: EVIL_CSS }, content: [{ type: 'text', text: 'l' }] },
    { type: 'codeBlock', attrs: { language: 'js" onload="x', align: EVIL_CSS }, content: [{ type: 'text', text: 'c' }] },
    {
      type: 'paragraph',
      content: [
        { type: 'text', text: 'link', marks: [{ type: 'link', attrs: { href: 'javascript:alert(1)' } }] },
        { type: 'text', text: 'color', marks: [{ type: 'textColor', attrs: { color: 'red; background:url(https://evil.example)' } }] },
        { type: 'text', text: 'hl', marks: [{ type: 'highlight', attrs: { color: 'url(https://evil.example)' } }] },
        { type: 'text', text: 'size', marks: [{ type: 'fontSize', attrs: { delta: '1px); background:url(https://evil.example' } }] },
      ],
    },
  ];

  it('are refused by the doc-validate rules and never loaded as-is into the editor', () => {
    expect(validateContainer(container(hostile))).not.toBe('valid');
    const prepared = prepareForEditor(container(hostile));
    expect(prepared.editable).toBe(false);
    expect(JSON.stringify(prepared.doc)).not.toMatch(/evil|javascript|onclick|onload/);
  });

  it('render without any injected CSS, URL or handler even if they bypassed validation', () => {
    const attrs = renderedAttributes({ type: 'doc', content: hostile });
    const joined = attrs.join('\n');
    expect(joined).not.toMatch(/evil|url\(|javascript|onclick|onload|;\s*color|background/i);
    // The link mark renders without an href at all.
    expect(attrs.filter((a) => a.startsWith('a.href='))).toEqual([]);
  });

  it('keeps legitimate attributes', () => {
    const attrs = renderedAttributes({
      type: 'doc',
      content: [
        { type: 'paragraph', attrs: { align: 'center', indent: 2 }, content: [{ type: 'text', text: 'x', marks: [{ type: 'link', attrs: { href: 'https://example.com' } }, { type: 'textColor', attrs: { color: '#FF0000' } }] }] },
      ],
    });
    expect(attrs).toContain('p.style=text-align: center; margin-left: 48px');
    expect(attrs).toContain('a.href=https://example.com');
    expect(attrs).toContain('span.style=color: #FF0000');
  });
});
