import { unquoteETag } from './backend.js';

export function xmlEscape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

export function xmlUnescape(s: string): string {
  return s
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h: string) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d: string) => String.fromCodePoint(parseInt(d, 10)))
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

function tag(xml: string, name: string): string | undefined {
  const m = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(xml);
  return m ? xmlUnescape(m[1]!) : undefined;
}

export interface ListPage {
  objects: { key: string; etag: string; size: number; lastModified?: number }[];
  isTruncated: boolean;
  nextContinuationToken?: string;
}

export function parseListV2(xml: string): ListPage {
  const objects: ListPage['objects'] = [];
  for (const m of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
    const body = m[1]!;
    const key = tag(body, 'Key');
    if (key === undefined) continue;
    const lm = tag(body, 'LastModified');
    const obj: ListPage['objects'][number] = { key, etag: unquoteETag(tag(body, 'ETag') ?? ''), size: Number(tag(body, 'Size') ?? 0) };
    if (lm) obj.lastModified = Date.parse(lm);
    objects.push(obj);
  }
  const page: ListPage = { objects, isTruncated: tag(xml, 'IsTruncated') === 'true' };
  const next = tag(xml, 'NextContinuationToken');
  if (next) page.nextContinuationToken = next;
  return page;
}

export function parseError(xml: string): { code: string; message: string } | undefined {
  const code = tag(xml, 'Code');
  return code ? { code, message: tag(xml, 'Message') ?? '' } : undefined;
}
