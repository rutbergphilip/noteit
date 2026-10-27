/**
 * Markdown → noteit-doc: a port of the Swift reader (`MarkdownCodec.parse` with `BlockParser`, `InlineParser`,
 * `FrontMatter` and `WikiLink` in `Sources/NoteItMarkdown`). CommonMark + GFM blocks and inlines, the NoteIt
 * attribute comments and fallback payloads, `==highlight==`, the NoteIt HTML tags and `[[wiki links]]`; anything
 * else stays literal text. The Swift codec's fixtures in `Tests/NoteItMarkdownTests/Fixtures` are this reader's
 * conformance tests. Text is read in grapheme clusters, as Swift's `Character` does.
 *
 * Also the paste heuristic of `Sources/NoteIt/Editor/MarkdownPaste.swift` (`looksLikeMarkdown`), and
 * `markdownForPaste`, which turns pasted Markdown source into blocks the way native paste does.
 */
import { listRuns } from './list-runs.js';
import { addAttachment } from './container.js';
import { HIGHLIGHT_YELLOW } from './markdown.js';
import { sha256HexSync } from './sha256.js';
import { type Align, type Block, type BodyContainer, type Inline, type Mark, type NoteItDoc, MAX_ATTACHMENT_BYTES, isAllowedLink } from './schema.js';

/** A line break read from a plain newline: shown like a hard break, written back as a newline (Swift `.softBreak`). */
export interface SoftBreak {
  type: 'hardBreak';
  attrs: { soft: true };
}
type Inl = Inline | SoftBreak;
type Json = Record<string, unknown>;
/** A block as JSON: a known `Block`, or an unknown node kept verbatim (Swift `DocNode.unknown`). */
type Node = Json & { type: string };

/** Maps a wiki-link target (`[[Plan]]`, `[x](Plan.md)`) to a note id; undefined leaves it unresolved. */
export type NoteLinkResolver = (target: string) => string | undefined;

export interface MarkdownReadOptions {
  resolveNoteLink?: NoteLinkResolver;
}

/** The YAML front matter NoteIt reads (Swift `FrontMatter`); unknown keys stay verbatim in `extra`. */
export interface FrontMatter {
  id?: string;
  created?: Date;
  updated?: Date;
  pinned: boolean;
  deleted?: Date;
  conflictOf?: string;
  conflictSource?: string;
  locked: boolean;
  /** Read only: the `tags:` lines themselves stay in `extra`. */
  tags: string[];
  /** Unknown keys in their original order, lines joined with "\n". */
  extra: string;
}

export interface AttachmentRef {
  /** As written, percent-decoded. */
  path: string;
  displayName: string;
  width?: number;
}

export interface ParsedMarkdown {
  frontMatter: FrontMatter;
  /** Attachments empty; an image's or attachment's `sha` is its path as written, percent-decoded. */
  body: BodyContainer;
  /** In document order, without duplicates. */
  attachmentRefs: AttachmentRef[];
}

export interface ImportedMarkdown {
  frontMatter: FrontMatter;
  body: BodyContainer;
  /** Paths with no data, empty data or data over the attachment limit; dropped from the body. */
  unresolvedImages: AttachmentRef[];
}

/** Swift `MarkdownError.invalidFrontMatter(line:)`. */
export class InvalidFrontMatterError extends Error {
  constructor(readonly line: number) {
    super(`Invalid front matter at line ${line}`);
  }
}

// MARK: - Characters (Swift `Character` semantics: grapheme clusters, properties of the first scalar)

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function graphemes(s: string): string[] {
  if (/^[\x00-\x7f]*$/.test(s) && !s.includes('\r\n')) return s.split('');
  return Array.from(segmenter.segment(s), (x) => x.segment);
}

const WHITESPACE = /^[\t-\r \x85\xa0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]/;
const isWhitespace = (c: string | undefined): boolean => c !== undefined && WHITESPACE.test(c);

function asciiValue(c: string): number | undefined {
  if (c === '\r\n') return 10;
  if (c.length !== 1) return undefined;
  const v = c.charCodeAt(0);
  return v < 128 ? v : undefined;
}

function isASCIIPunctuation(c: string): boolean {
  const a = asciiValue(c);
  return a !== undefined && ((a >= 33 && a <= 47) || (a >= 58 && a <= 64) || (a >= 91 && a <= 96) || (a >= 123 && a <= 126));
}

/** CommonMark 0.31: Unicode P and S categories. */
const isMarkdownPunctuation = (c: string): boolean => isASCIIPunctuation(c) || /^[\p{P}\p{S}]/u.test(c);
const isLetter = (c: string): boolean => /^\p{Alphabetic}/u.test(c);
const isNumber = (c: string): boolean => /^\p{N}/u.test(c);
const isASCIILetter = (c: string): boolean => /^[A-Za-z]$/.test(c);

/** `trimmingCharacters(in: .whitespaces)`: tabs and Zs. */
const trimWhitespaces = (s: string): string => trimBy(s, (c) => c === '\t' || /\p{Zs}/u.test(c));
/** `BlockParser.trimmed`: spaces and tabs only. */
const trimmed = (s: string): string => trimBy(s, isSpaceOrTab);
const isSpaceOrTab = (c: string): boolean => c === ' ' || c === '\t';

/** `s` without the leading and trailing UTF-16 units that pass `test` (a loop: a `x+$` regex is quadratic). */
function trimBy(s: string, test: (c: string) => boolean, leading = true): string {
  let start = 0;
  let end = s.length;
  while (leading && start < end && test(s[start]!)) start += 1;
  while (end > start && test(s[end - 1]!)) end -= 1;
  return s.slice(start, end);
}

/** How many trailing UTF-16 units of `s` equal `c`. */
function trailing(s: string, c: string): number {
  let n = 0;
  while (n < s.length && s[s.length - 1 - n] === c) n += 1;
  return n;
}

/** `str.splitOnce(sep)`. */
function splitOnce(s: string, sep: string): [string, string | undefined] {
  const i = s.indexOf(sep);
  return i < 0 ? [s, undefined] : [s.slice(0, i), s.slice(i + sep.length)];
}

/** Swift `Int(String)`: optional sign, decimal digits, in range. */
function parseInt64(s: string): number | undefined {
  if (!/^[+-]?\d+$/.test(s)) return undefined;
  const n = Number(s);
  return Math.abs(n) <= Number.MAX_SAFE_INTEGER ? n : undefined;
}

/** Swift `Double(String)`: decimal or hex floats, `inf`, `infinity`, `nan`. */
function parseDouble(s: string): number | undefined {
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return Number(s);
  const special = /^([+-]?)(inf|infinity|nan)$/i.exec(s);
  if (special) return special[2]!.toLowerCase() === 'nan' ? NaN : special[1] === '-' ? -Infinity : Infinity;
  const hex = /^([+-]?)0[xX]([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/.exec(s);
  if (!hex || (!hex[2] && !hex[3])) return undefined;
  const frac = hex[3] ?? '';
  const mantissa = parseInt((hex[2] || '0') + frac, 16);
  const value = mantissa * 2 ** (Number(hex[4] ?? 0) - 4 * frac.length);
  return hex[1] === '-' ? -value : value;
}

/** `removingPercentEncoding ?? s`. */
function percentDecoded(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

/** Swift `Double.rounded()` (half away from zero), then `Int`. */
const roundInt = (v: number): number => Math.sign(v) * Math.round(Math.abs(v));

// MARK: - Links

/**
 * Swift `LinkPolicy.allows`: `URLComponents` must accept the href (its scheme, and the host and port of an
 * authority), the scheme must be listed, and a `noteit:` link must name the `note` host. The web's own
 * `isAllowedLink` must accept it too, so the doc validates; that adds one rule native lacks: no whitespace.
 */
export function linkPolicyAllows(href: string): boolean {
  const scheme = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(href);
  if (!scheme || !isAllowedLink(href)) return false;
  const rest = href.slice(scheme[0].length);
  if (!rest.startsWith('//')) return true;
  const authority = /^[^/?#]*/.exec(rest.slice(2))![0];
  const hostPort = authority.slice(authority.lastIndexOf('@') + 1);
  const bracket = /^\[[^\]]*\]/.exec(hostPort);
  const host = bracket ? bracket[0] : hostPort.split(':')[0]!;
  const port = hostPort.slice(host.length);
  if (port && !/^:\d*$/.test(port)) return false;
  if (!bracket && /[\x00-\x20\x7f<>"{}|\\^`[\]]/.test(host)) return false;
  if (/%(?![0-9A-Fa-f]{2})/.test(host)) return false;
  // A host with non-ASCII letters must convert to IDNA, whose label rules then apply to every label.
  if (!/[^\x00-\x7f]/.test(host)) return true;
  const labels = host.split('.');
  if (labels.length > 1 && labels[labels.length - 1] === '') labels.pop();
  return labels.every((l) => l && !l.startsWith('-') && !l.endsWith('-') && l.slice(2, 4) !== '--' && !/^\p{M}|[\u200c\u200d]/u.test(l));
}

const QUERY_ALLOWED = /[A-Za-z0-9\-._~!$'()*,;:@]/;

/** `addingPercentEncoding(withAllowedCharacters: urlQueryAllowed - "&=+#?/")`. */
function queryEncoded(value: string): string {
  let out = '';
  for (const ch of value) {
    if (QUERY_ALLOWED.test(ch)) out += ch;
    else for (const b of new TextEncoder().encode(ch)) out += `%${b.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

/** `[[target]]`, `[[target|shown]]`, `[[target#heading]]` (Swift `WikiLink`). */
interface WikiLink {
  target: string;
  heading?: string;
  shownText?: string;
}

/** The text between `[[` and `]]`. In a table cell the `|` is written `\|`; both are read. */
function parseWikiLink(inner: string): WikiLink | undefined {
  let targetPart = inner;
  let shown: string | undefined;
  const bar = inner.includes('\\|') ? '\\|' : inner.includes('|') ? '|' : undefined;
  if (bar) [targetPart, shown] = splitOnce(inner, bar);
  const [target, heading] = splitOnce(targetPart, '#');
  const t = trimWhitespaces(target);
  if (!t && heading === undefined) return undefined;
  return { target: t, heading: heading === undefined ? undefined : trimWhitespaces(heading), shownText: shown === undefined || shown === '' || shown === t ? undefined : shown };
}

/** `noteit://note/<UUID>` when the target resolves, else `noteit://note?title=<target>`; plus `heading=`. */
function wikiHref(link: WikiLink, resolve: NoteLinkResolver): string {
  const id = resolve(link.target);
  if (id) return `noteit://note/${id.toUpperCase()}${link.heading !== undefined ? `?heading=${queryEncoded(link.heading)}` : ''}`;
  return `noteit://note?title=${queryEncoded(link.target)}${link.heading !== undefined ? `&heading=${queryEncoded(link.heading)}` : ''}`;
}

// MARK: - MIME types

const MIME_BY_EXTENSION: Record<string, string> = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', heic: 'image/heic', heif: 'image/heif',
  webp: 'image/webp', tif: 'image/tiff', tiff: 'image/tiff', bmp: 'image/bmp', svg: 'image/svg+xml', pdf: 'application/pdf',
  zip: 'application/zip', txt: 'text/plain', md: 'text/markdown', csv: 'text/csv', json: 'application/json', html: 'text/html',
  htm: 'text/html', rtf: 'text/rtf', mp3: 'audio/mpeg', m4a: 'audio/mp4', wav: 'audio/wav', mp4: 'video/mp4',
  mov: 'video/quicktime', doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xls: 'application/vnd.ms-excel', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ppt: 'application/vnd.ms-powerpoint', pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

/** `NSString.lastPathComponent`. */
function lastPathComponent(path: string): string {
  const stripped = path.slice(0, path.length - trailing(path, '/'));
  if (!stripped) return path ? '/' : '';
  return stripped.slice(stripped.lastIndexOf('/') + 1);
}

/** `NSString.pathExtension`, lowercased; undefined when there is none. */
function fileExtension(name: string): string | undefined {
  const last = lastPathComponent(name);
  const dot = last.lastIndexOf('.');
  const ext = dot > 0 && /[^.]/.test(last.slice(0, dot)) ? last.slice(dot + 1) : '';
  return ext && !ext.includes(' ') ? ext.toLowerCase() : undefined;
}

const mimeForName = (name: string): string => MIME_BY_EXTENSION[fileExtension(name) ?? ''] ?? 'application/octet-stream';
const isImageExtension = (ext: string): boolean => MIME_BY_EXTENSION[ext.toLowerCase()]?.startsWith('image/') === true;

// MARK: - Doc nodes (canonical JSON, as Swift encodes them)

function withAttrs(attrs: Json): Json | undefined {
  const out: Json = {};
  for (const [k, v] of Object.entries(attrs)) if (v !== undefined) out[k] = v;
  return Object.keys(out).length ? out : undefined;
}

function textBlock(type: string, attrs: Json, content: Inl[], keepAttrs = false): Node {
  const node: Node = { type };
  const a = withAttrs(attrs);
  if (a || keepAttrs) node.attrs = a ?? {};
  if (content.length) node.content = content;
  return node;
}

const paragraph = (align: Align | undefined, indent: number | undefined, content: Inl[]): Node => textBlock('paragraph', { align, indent }, content);
const heading = (level: number, align: Align | undefined, indent: number | undefined, content: Inl[]): Node =>
  textBlock('heading', { level, align, indent }, content, true);
const codeBlock = (align: Align | undefined, language: string | undefined, content: Inl[]): Node => textBlock('codeBlock', { align, language }, content);
const text = (t: string, marks: Mark[] = []): Inline => (marks.length ? { type: 'text', text: t, marks } : { type: 'text', text: t });
const HARD: Inline = { type: 'hardBreak' };
const SOFT: SoftBreak = { type: 'hardBreak', attrs: { soft: true } };
const isSoft = (i: Inl): boolean => i.type === 'hardBreak' && (i as SoftBreak).attrs?.soft === true;
const isBreak = (i: Inl): boolean => i.type === 'hardBreak';
const inlinesOf = (n: Node): Inl[] => (n.content as Inl[] | undefined) ?? [];
const nodeAttrs = (n: Node): Json => (n.attrs as Json | undefined) ?? {};

interface Cell {
  header: boolean;
  content: Node[];
}

function table(widths: number[] | undefined, rows: Cell[][]): Node {
  const node: Node = { type: 'table' };
  if (widths) node.attrs = { columnWidths: widths };
  node.content = rows.map((row) => ({ type: 'tableRow', content: row.map((c) => ({ type: c.header ? 'tableHeader' : 'tableCell', content: c.content })) }));
  return node;
}

function tableRows(n: Node): Cell[][] {
  return ((n.content as Json[] | undefined) ?? []).map((row) =>
    ((row.content as Json[] | undefined) ?? []).map((c) => ({ header: c.type === 'tableHeader', content: (c.content as Node[] | undefined) ?? [] })),
  );
}

// MARK: - Marks

function markRank(m: Mark): number {
  return ['bold', 'italic', 'underline', 'strike', 'code', 'link', 'textColor', 'highlight', 'fontSize'].indexOf(m.type);
}

const markKey = (m: Mark): string => ('attrs' in m ? `${m.type}:${JSON.stringify(m.attrs)}` : m.type);
const sameMarks = (a: Mark[], b: Mark[]): boolean => a.length === b.length && a.every((m, i) => markKey(m) === markKey(b[i]!));
const canonical = (marks: Mark[]): Mark[] => [...marks].sort((a, b) => markRank(a) - markRank(b));
const link = (href: string): Mark => ({ type: 'link', attrs: { href } });
const YELLOW: Mark = { type: 'highlight', attrs: { color: HIGHLIGHT_YELLOW } };

/** A soft break only stays soft between other content; one at an end or next to another break becomes hard. */
function resolvingSoftBreaks(content: Inl[]): Inl[] {
  return content.map((n, i) =>
    isSoft(n) && (i === 0 || i === content.length - 1 || isBreak(content[i - 1]!) || isBreak(content[i + 1]!)) ? HARD : n,
  );
}

/** Every break hard: headings have no soft form. */
const hardeningSoftBreaks = (content: Inl[]): Inl[] => content.map((n) => (isSoft(n) ? HARD : n));

/** Adjacent text runs with equal marks merged, empty runs dropped. */
function mergingTextRuns(content: Inl[]): Inl[] {
  const out: Inl[] = [];
  for (const n of content) {
    const last = out[out.length - 1];
    if (n.type !== 'text') out.push(n);
    else if (!n.text) continue;
    else if (last?.type === 'text' && sameMarks(last.marks ?? [], n.marks ?? [])) out[out.length - 1] = text(last.text + n.text, n.marks);
    else out.push(n);
  }
  return out;
}

// MARK: - Entities and escapes

const NAMED_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00A0', '#32': ' ', '#9': '\t' };

/** `&name;` at `start` → (decoded, length in characters). */
function decodeEntity(chars: string[], start: number): [string, number] | undefined {
  if (chars[start] !== '&') return undefined;
  let j = start + 1;
  while (j < chars.length && j - start <= 32 && chars[j] !== ';') {
    if (!/^[A-Za-z0-9#]$/.test(chars[j]!)) return undefined;
    j += 1;
  }
  if (j >= chars.length || chars[j] !== ';' || j <= start + 1) return undefined;
  const name = chars.slice(start + 1, j).join('');
  const named = NAMED_ENTITIES[name];
  if (named !== undefined) return [named, j - start + 1];
  if (!name.startsWith('#')) return undefined;
  const digits = name.slice(1);
  const hex = digits[0] === 'x' || digits[0] === 'X';
  const body = hex ? digits.slice(1) : digits;
  if (!(hex ? /^[0-9A-Fa-f]+$/ : /^[0-9]+$/).test(body)) return undefined;
  const scalar = parseInt(body, hex ? 16 : 10);
  if (scalar === 0 || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return undefined;
  return [String.fromCodePoint(scalar), j - start + 1];
}

/** Backslash escapes and entities (Swift `Unescape.text`). */
function unescapeText(raw: string): string {
  const chars = graphemes(raw);
  let out = '';
  let i = 0;
  while (i < chars.length) {
    const entity = chars[i] === '&' ? decodeEntity(chars, i) : undefined;
    if (chars[i] === '\\' && i + 1 < chars.length && isASCIIPunctuation(chars[i + 1]!)) {
      out += chars[i + 1];
      i += 2;
    } else if (entity) {
      out += entity[0];
      i += entity[1];
    } else {
      out += chars[i];
      i += 1;
    }
  }
  return out;
}

// MARK: - HTML tags

/** ` key="value" data-x='y'` → pairs in order; undefined when malformed. */
function htmlAttributes(s: string): [string, string][] | undefined {
  const pairs: [string, string][] = [];
  let rest = s;
  for (;;) {
    rest = rest.replace(/^ +/, '');
    if (!rest) return pairs;
    const key = /^[A-Za-z0-9-]*/.exec(rest)![0];
    if (!key) return undefined;
    rest = rest.slice(key.length);
    if (rest[0] !== '=') return undefined;
    const quote = rest[1];
    if (quote !== '"' && quote !== "'") return undefined;
    const close = rest.indexOf(quote, 2);
    if (close < 0) return undefined;
    pairs.push([key.toLowerCase(), rest.slice(2, close)]);
    rest = rest.slice(close + 1);
  }
}

function normalizedColor(value: string): string | undefined {
  if (!value.startsWith('#')) return undefined;
  let hex = value.slice(1).toUpperCase();
  if ([...hex].length === 3) hex = [...hex].map((c) => c + c).join('');
  return [...hex].length === 6 && /^[0-9A-F\uFF10-\uFF19\uFF21-\uFF26]+$/.test(hex) ? `#${hex}` : undefined;
}

/** `color: #2899E0` → "#2899E0"; the only declaration allowed is one of `names`. */
function cssColor(style: string, names: string[]): string | undefined {
  const declarations = style.split(';').map(trimWhitespaces).filter((d) => d);
  if (declarations.length !== 1) return undefined;
  const [name, value] = splitOnce(declarations[0]!, ':');
  if (value === undefined || !names.includes(trimWhitespaces(name).toLowerCase())) return undefined;
  return normalizedColor(trimWhitespaces(value));
}

interface Tag {
  name: string;
  closing: boolean;
  marks: Mark[];
  hardBreak?: boolean;
}

const KNOWN_TAGS = new Set(['u', 'ins', 'strong', 'b', 'em', 'i', 'del', 's', 'strike', 'mark', 'span']);

function htmlTag(inner: string): Tag | undefined {
  let body = inner;
  const closing = body.startsWith('/');
  if (closing) body = body.slice(1);
  const rawName = /^[A-Za-z]*/.exec(body)![0];
  const name = rawName.toLowerCase();
  let rest = body.slice(rawName.length);
  if (name === 'br') {
    rest = rest.replace(/^ +/, '');
    return !closing && (rest === '' || rest === '/') ? { name, closing: false, marks: [], hardBreak: true } : undefined;
  }
  if (closing) return /^ *$/.test(rest) && KNOWN_TAGS.has(name) ? { name, closing: true, marks: [] } : undefined;
  const attributes = htmlAttributes(rest);
  if (!attributes) return undefined;
  const plain = (mark: Mark): Tag | undefined => (attributes.length ? undefined : { name, closing: false, marks: [mark] });
  switch (name) {
    case 'u':
    case 'ins':
      return plain({ type: 'underline' });
    case 'strong':
    case 'b':
      return plain({ type: 'bold' });
    case 'em':
    case 'i':
      return plain({ type: 'italic' });
    case 'del':
    case 's':
    case 'strike':
      return plain({ type: 'strike' });
    case 'mark': {
      if (!attributes.length) return { name, closing: false, marks: [YELLOW] };
      const color = attributes.length === 1 && attributes[0]![0] === 'style' ? cssColor(attributes[0]![1], ['background-color', 'background']) : undefined;
      return color ? { name, closing: false, marks: [{ type: 'highlight', attrs: { color } }] } : undefined;
    }
    case 'span': {
      const marks: Mark[] = [];
      for (const [key, value] of attributes) {
        if (key === 'style') {
          const color = cssColor(value, ['color']);
          if (!color) return undefined;
          marks.push({ type: 'textColor', attrs: { color } });
        } else if (key === 'data-size') {
          const delta = parseInt64(value.startsWith('+') ? value.slice(1) : value);
          if (delta === undefined || delta === 0) return undefined;
          marks.push({ type: 'fontSize', attrs: { delta } });
        } else {
          return undefined;
        }
      }
      return marks.length ? { name, closing: false, marks } : undefined;
    }
    default:
      return undefined;
  }
}

function autolinkHref(inner: string): string | undefined {
  if (!inner || /[ \t]/.test(inner)) return undefined;
  const colon = inner.indexOf(':');
  if (colon >= 0) {
    const scheme = graphemes(inner.slice(0, colon));
    if (scheme.length < 2 || scheme.length > 32 || !isASCIILetter(scheme[0]!) || !scheme.every((c) => /^[A-Za-z0-9+.-]$/.test(c))) return undefined;
    return linkPolicyAllows(inner) ? inner : undefined;
  }
  const parts = inner.split('@');
  if (parts.length !== 2 || !parts[0] || !parts[1]!.includes('.') || parts[1]!.startsWith('.') || parts[1]!.endsWith('.')) return undefined;
  return graphemes(inner).every((c) => isASCII(c) && !isWhitespace(c)) ? `mailto:${inner}` : undefined;
}

const isASCII = (c: string): boolean => asciiValue(c) !== undefined;

// MARK: - Link destinations

type LinkTarget = { href: string } | { attachment: string } | undefined;

function linkTarget(destination: string, resolve: NoteLinkResolver): LinkTarget {
  const colon = destination.indexOf(':');
  if (colon >= 2 && /^[A-Za-z0-9+.-]+$/.test(destination.slice(0, colon))) {
    if (destination.toLowerCase().startsWith('file:')) return { attachment: filePath(destination) };
    return linkPolicyAllows(destination) ? { href: destination } : undefined;
  }
  if (!destination || destination.startsWith('#')) return undefined;
  const decoded = percentDecoded(destination);
  const [path, fragment] = splitOnce(decoded, '#');
  const lowered = path.toLowerCase();
  if (lowered.endsWith('.md') || lowered.endsWith('.markdown')) {
    let target = path.slice(0, path.length - (lowered.endsWith('.md') ? 3 : 9));
    while (target.startsWith('./')) target = target.slice(2);
    return { href: wikiHref({ target, heading: fragment }, resolve) };
  }
  return { attachment: decoded };
}

/** `URL(string:)?.path` of a `file:` URL: the percent-decoded path, without host, query or fragment. */
function filePath(destination: string): string {
  let rest = destination.slice(5).replace(/[?#].*$/, '');
  if (rest.startsWith('//')) rest = rest.slice(2 + (/^[^/]*/.exec(rest.slice(2))![0].length));
  return percentDecoded(rest);
}

/** cmark's limit; also keeps `[a](` repeated from rescanning the rest of the paragraph at every `]`. */
const MAX_PAREN_DEPTH = 32;

/** `(destination "title")` at `start` → the unescaped destination and the index after `)`. */
function parseLinkDestination(chars: string[], start: number): [string, number] | undefined {
  if (chars[start] !== '(') return undefined;
  let j = start + 1;
  const skipSpace = () => {
    while (j < chars.length && (chars[j] === ' ' || chars[j] === '\t' || chars[j] === '\n')) j += 1;
  };
  skipSpace();
  let raw = '';
  if (chars[j] === '<') {
    j += 1;
    while (j < chars.length && chars[j] !== '>') {
      if (chars[j] === '\n' || chars[j] === '<') return undefined;
      if (chars[j] === '\\' && j + 1 < chars.length && isASCIIPunctuation(chars[j + 1]!)) {
        raw += chars[j];
        j += 1;
      }
      raw += chars[j];
      j += 1;
    }
    if (j >= chars.length) return undefined;
    j += 1;
  } else {
    let depth = 0;
    while (j < chars.length) {
      const c = chars[j]!;
      if (c === '\\' && j + 1 < chars.length && isASCIIPunctuation(chars[j + 1]!)) {
        raw += c + chars[j + 1];
        j += 2;
        continue;
      }
      if (isWhitespace(c)) break;
      if (c === '(') {
        depth += 1;
        if (depth > MAX_PAREN_DEPTH) return undefined;
      }
      if (c === ')') {
        if (depth === 0) break;
        depth -= 1;
      }
      raw += c;
      j += 1;
    }
  }
  skipSpace();
  const closing = ({ '"': '"', "'": "'", '(': ')' } as Record<string, string>)[chars[j] ?? ''];
  if (j < chars.length && closing) {
    j += 1;
    while (j < chars.length && chars[j] !== closing) {
      if (closing === ')' && chars[j] === '(') return undefined;
      if (chars[j] === '\\') j += 1;
      j += 1;
    }
    if (j >= chars.length) return undefined;
    j += 1;
    skipSpace();
  }
  if (chars[j] !== ')') return undefined;
  return [unescapeText(raw), j + 1];
}

// MARK: - Inline scanner

interface Delimiter {
  char: string;
  count: number;
  originalCount: number;
  canOpen: boolean;
  canClose: boolean;
}

interface SNode {
  text: string;
  marks: Mark[];
  atom?: Inl;
  delimiter?: Delimiter;
  tag?: Tag;
}

interface Bracket {
  node: number;
  sourceStart: number;
  image: boolean;
  delimiterBottom: number | null;
  spanBottom: number;
}

/** An entry of CommonMark's delimiter stack, kept as a doubly linked list over `delimiters`. */
interface DelimiterEntry {
  node: number;
  prev: number | null;
  next: number | null;
}

/** A mark over `nodes[start..<end]`, applied once scanning is done. */
interface Span {
  start: number;
  end: number;
  mark: Mark;
}

const emptyNode = (): SNode => ({ text: '', marks: [] });

/** Nested images copy their alt source, so deeper `![` is read as `!` and a plain bracket. */
const MAX_OPEN_IMAGES = 4;

/** Closers that share a key fail on the same openers (the rule of 3 for `*`/`_`, the length for `~`). */
function openersBottomKey(d: Delimiter): number {
  if (d.char === '*') return (d.canOpen ? 3 : 0) + (d.originalCount % 3);
  if (d.char === '_') return 6 + (d.canOpen ? 3 : 0) + (d.originalCount % 3);
  if (d.char === '~') return 12 + Math.min(d.count, 2);
  return 15;
}

function canPair(opener: Delimiter, closer: Delimiter): boolean {
  if (closer.char === '~' || closer.char === '=') return opener.count === closer.count;
  return !(
    (opener.canClose || closer.canOpen) &&
    (opener.originalCount + closer.originalCount) % 3 === 0 &&
    !(opener.originalCount % 3 === 0 && closer.originalCount % 3 === 0)
  );
}

/** `name|480` → ["name", 480]. A `|` escaped as `\|` is part of the name. */
function imageName(raw: string): [string, number | undefined] {
  const bar = raw.lastIndexOf('|');
  if (bar > 0 && raw[bar - 1] !== '\\') {
    const digits = raw.slice(bar + 1);
    const width = /^[0-9.]+$/.test(digits) ? parseDouble(digits) : undefined;
    if (width !== undefined) return [unescapeText(raw.slice(0, bar)), width];
  }
  return [unescapeText(raw), undefined];
}

class InlineScanner {
  refs: AttachmentRef[] = [];
  nodes: SNode[] = [];
  private delimiters: DelimiterEntry[] = [];
  private delimiterTop: number | null = null;
  private spans: Span[] = [];
  private brackets: Bracket[] = [];
  /** Non-image brackets below this index can't make a link any more: links don't nest. */
  private linkFloor = 0;
  private openImages = 0;
  private backtickRuns: Map<number, number[]> | undefined;
  private bareURLBlockedUntil = 0;
  hardNewlines = new Set<number>();
  private buffer = '';
  private i = 0;

  constructor(
    private readonly chars: string[],
    private readonly resolve: NoteLinkResolver,
  ) {}

  scan(): void {
    const chars = this.chars;
    while (this.i < chars.length) {
      const c = chars[this.i]!;
      switch (c) {
        case '\\':
          if (this.i + 1 >= chars.length || chars[this.i + 1] === '\n') {
            this.appendAtom(HARD);
            this.i += 2;
          } else if (isASCIIPunctuation(chars[this.i + 1]!)) {
            this.buffer += chars[this.i + 1];
            this.i += 2;
          } else {
            this.buffer += c;
            this.i += 1;
          }
          break;
        case '\n':
          this.appendAtom(this.hardNewlines.has(this.i) ? HARD : SOFT);
          this.i += 1;
          break;
        case '`':
          this.scanCodeSpan();
          break;
        case '&':
          this.scanEntity();
          break;
        case '<':
          this.scanAngle();
          break;
        case '!':
          if (this.peek(1) === '[' && this.peek(2) === '[' && this.scanWikiLink(true)) break;
          if (this.peek(1) === '[') this.pushBracket(true);
          else this.literal(c);
          break;
        case '[':
          if (this.peek(1) === '[' && this.scanWikiLink(false)) break;
          this.pushBracket(false);
          break;
        case ']':
          this.closeBracket();
          break;
        case '*':
        case '_':
        case '~':
        case '=':
          this.scanDelimiterRun();
          break;
        case 'h':
        case 'w':
          if (!this.scanBareURL()) this.literal(c);
          break;
        default:
          this.literal(c);
      }
    }
    this.flush();
    this.processEmphasis(null);
    this.applySpans();
    this.processTags();
  }

  private literal(c: string): void {
    this.buffer += c;
    this.i += 1;
  }

  private peek(offset: number): string | undefined {
    return this.chars[this.i + offset];
  }

  private flush(): void {
    if (!this.buffer) return;
    this.nodes.push({ text: this.buffer, marks: [] });
    this.buffer = '';
  }

  private appendAtom(atom: Inl): void {
    this.flush();
    this.nodes.push({ text: '', marks: [], atom });
  }

  private appendText(t: string, marks: Mark[]): void {
    this.flush();
    this.nodes.push({ text: t, marks });
  }

  private scanCodeSpan(): void {
    const chars = this.chars;
    let run = 0;
    while (this.i + run < chars.length && chars[this.i + run] === '`') run += 1;
    this.backtickRuns ??= InlineScanner.findBacktickRuns(chars);
    const starts = this.backtickRuns.get(run) ?? [];
    let low = 0;
    let high = starts.length;
    while (low < high) {
      const mid = (low + high) >> 1;
      if (starts[mid]! < this.i + run) low = mid + 1;
      else high = mid;
    }
    if (low >= starts.length) {
      this.buffer += '`'.repeat(run);
      this.i += run;
      return;
    }
    const j = starts[low]!;
    let content = chars.slice(this.i + run, j).map((c) => (c === '\n' ? ' ' : c));
    if (content.length >= 2 && content[0] === ' ' && content[content.length - 1] === ' ' && content.some((c) => c !== ' ')) content = content.slice(1, -1);
    this.appendText(content.join(''), [{ type: 'code' }]);
    this.i = j + run;
  }

  /** Start offsets of every maximal backtick run, by run length, so finding a closer doesn't rescan the line. */
  private static findBacktickRuns(chars: string[]): Map<number, number[]> {
    const runs = new Map<number, number[]>();
    let j = 0;
    while (j < chars.length) {
      if (chars[j] !== '`') {
        j += 1;
        continue;
      }
      let length = 0;
      while (j + length < chars.length && chars[j + length] === '`') length += 1;
      const list = runs.get(length) ?? [];
      list.push(j);
      runs.set(length, list);
      j += length;
    }
    return runs;
  }

  private scanEntity(): void {
    const entity = decodeEntity(this.chars, this.i);
    if (entity) {
      this.buffer += entity[0];
      this.i += entity[1];
    } else {
      this.literal('&');
    }
  }

  // Angle brackets: autolinks and HTML tags

  private scanAngle(): void {
    const chars = this.chars;
    let close = this.i + 1;
    while (close < chars.length && chars[close] !== '>' && chars[close] !== '<' && chars[close] !== '\n') close += 1;
    if (chars[close] !== '>') return this.literal('<');
    const inner = chars.slice(this.i + 1, close).join('');
    const href = autolinkHref(inner);
    const tag = href === undefined ? htmlTag(inner) : undefined;
    if (href !== undefined) {
      this.appendText(inner, [link(href)]);
    } else if (tag) {
      this.flush();
      this.nodes.push(tag.hardBreak ? { text: '', marks: [], atom: HARD } : { text: `<${inner}>`, marks: [], tag });
    } else {
      return this.literal('<');
    }
    this.i = close + 1;
  }

  // Bare URLs (GFM extended autolinks)

  private scanBareURL(): boolean {
    const chars = this.chars;
    const i = this.i;
    if (i < this.bareURLBlockedUntil) return false;
    if (i > 0) {
      const previous = chars[i - 1]!;
      if (!isWhitespace(previous) && !'*_~('.includes(previous)) return false;
    }
    const rest = chars.slice(i, i + 8).join('');
    const prefix = ['https://', 'http://', 'www.'].find((p) => rest.startsWith(p));
    if (!prefix) return false;
    let end = i;
    while (end < chars.length && !isWhitespace(chars[end]) && chars[end] !== '<') end += 1;
    const runEnd = end;
    let opening = 0;
    let closing = 0;
    for (let k = i; k < end; k++) {
      if (chars[k] === '(') opening += 1;
      else if (chars[k] === ')') closing += 1;
    }
    while (end > i) {
      const last = chars[end - 1]!;
      if (last.length === 1 && '?!.,:*_~\'"'.includes(last)) {
        end -= 1;
      } else if (last === ')' && closing > opening) {
        closing -= 1;
        end -= 1;
      } else {
        break;
      }
    }
    const urlChars = chars.slice(i, end);
    if (urlChars.length <= prefix.length || !urlChars.slice(prefix.length).some((c) => isLetter(c) || isNumber(c))) return false;
    const t = urlChars.join('');
    const href = prefix === 'www.' ? `http://${t}` : t;
    if (!linkPolicyAllows(href)) {
      // Later starts in the same run are suffixes of this one; trying each would be quadratic.
      this.bareURLBlockedUntil = runEnd;
      return false;
    }
    this.appendText(t, [link(href)]);
    this.i = end;
    return true;
  }

  // Wiki links

  private scanWikiLink(embed: boolean): boolean {
    const chars = this.chars;
    const open = this.i + (embed ? 3 : 2);
    let j = open;
    let close: number | undefined;
    while (j + 1 < chars.length && chars[j] !== '\n') {
      if (chars[j] === '[') return false;
      if (chars[j] === ']') {
        if (chars[j + 1] !== ']') return false;
        close = j;
        break;
      }
      j += 1;
    }
    if (close === undefined || close <= open) return false;
    const wiki = parseWikiLink(chars.slice(open, close).join(''));
    if (!wiki) return false;
    const ext = fileExtension(wiki.target);
    if (embed && ext && isImageExtension(ext)) {
      const width = wiki.shownText === undefined ? undefined : parseDouble(wiki.shownText);
      const name = lastPathComponent(wiki.target);
      this.refs.push(width === undefined ? { path: wiki.target, displayName: name } : { path: wiki.target, displayName: name, width: roundInt(width) });
      this.appendAtom(imageNode(wiki.target, name, mimeForName(name), width));
    } else {
      this.appendText(wiki.shownText ?? wiki.target, [link(wikiHref(wiki, this.resolve))]);
    }
    this.i = close + 2;
    return true;
  }

  // Links and images

  private pushBracket(image: boolean): void {
    if (image && this.openImages >= MAX_OPEN_IMAGES) return this.literal('!');
    this.flush();
    this.nodes.push({ text: image ? '![' : '[', marks: [] });
    this.brackets.push({ node: this.nodes.length - 1, sourceStart: this.i, image, delimiterBottom: this.delimiterTop, spanBottom: this.spans.length });
    if (image) this.openImages += 1;
    this.i += image ? 2 : 1;
  }

  private popBracket(): void {
    if (this.brackets.pop()!.image) this.openImages -= 1;
    this.linkFloor = Math.min(this.linkFloor, this.brackets.length);
  }

  private closeBracket(): void {
    const bracket = this.brackets[this.brackets.length - 1];
    if (!bracket) return this.literal(']');
    const active = bracket.image || this.brackets.length - 1 >= this.linkFloor;
    const parsed = active ? parseLinkDestination(this.chars, this.i + 1) : undefined;
    if (!parsed) {
      this.popBracket();
      return this.literal(']');
    }
    const [destination, end] = parsed;
    this.flush();
    this.processEmphasis(bracket.delimiterBottom);
    this.popBracket();
    const innerStart = bracket.node + 1;
    const innerEnd = this.nodes.length;
    if (bracket.image) {
      const [name, width] = imageName(this.chars.slice(bracket.sourceStart + 2, this.i).join(''));
      const path = percentDecoded(destination);
      this.refs.push(width === undefined ? { path, displayName: name } : { path, displayName: name, width: roundInt(width) });
      const mimeSource = fileExtension(name) !== undefined ? name : path;
      this.spans.length = bracket.spanBottom;
      this.nodes.length = innerStart;
      this.nodes[bracket.node] = { text: '', marks: [], atom: imageNode(path, name, mimeForName(mimeSource), width) };
    } else {
      const target = linkTarget(destination, this.resolve);
      if (target && 'href' in target) {
        this.spans.push({ start: innerStart, end: innerEnd, mark: link(target.href) });
        this.nodes[bracket.node] = emptyNode();
      } else if (target) {
        const name = InlineScanner.plainText(this.nodes.slice(innerStart, innerEnd));
        this.refs.push({ path: target.attachment, displayName: name });
        this.spans.length = bracket.spanBottom;
        this.nodes.length = innerStart;
        const mime = mimeForName(name ? name : target.attachment);
        this.nodes[bracket.node] = { text: '', marks: [], atom: { type: 'attachment', attrs: { sha: target.attachment, name, mime } } };
      } else {
        this.nodes[bracket.node] = emptyNode();
      }
      // Whatever it points at, this is a link, and a link can't contain one (nested names were quadratic).
      this.linkFloor = this.brackets.length;
    }
    this.i = end;
  }

  private static plainText(nodes: SNode[]): string {
    return nodes
      .map((n) => {
        if (n.atom?.type === 'image' || n.atom?.type === 'attachment') return n.atom.attrs.name;
        if (n.atom?.type === 'hardBreak') return ' ';
        if (n.delimiter) return n.delimiter.char.repeat(n.delimiter.count);
        return n.text;
      })
      .join('');
  }

  // Emphasis

  private scanDelimiterRun(): void {
    const chars = this.chars;
    const c = chars[this.i]!;
    let count = 0;
    while (this.i + count < chars.length && chars[this.i + count] === c) count += 1;
    const valid = c === '~' ? count <= 2 : c === '=' ? count === 2 : true;
    if (!valid) {
      this.buffer += c.repeat(count);
      this.i += count;
      return;
    }
    const before = this.i > 0 ? chars[this.i - 1]! : ' ';
    const after = this.i + count < chars.length ? chars[this.i + count]! : ' ';
    const leftFlanking = !isWhitespace(after) && (!isMarkdownPunctuation(after) || isWhitespace(before) || isMarkdownPunctuation(before));
    const rightFlanking = !isWhitespace(before) && (!isMarkdownPunctuation(before) || isWhitespace(after) || isMarkdownPunctuation(after));
    let canOpen = leftFlanking;
    let canClose = rightFlanking;
    if (c === '_') {
      canOpen = leftFlanking && (!rightFlanking || isMarkdownPunctuation(before));
      canClose = rightFlanking && (!leftFlanking || isMarkdownPunctuation(after));
    }
    this.flush();
    this.nodes.push({ text: c.repeat(count), marks: [], delimiter: { char: c, count, originalCount: count, canOpen, canClose } });
    this.delimiters.push({ node: this.nodes.length - 1, prev: this.delimiterTop, next: null });
    if (this.delimiterTop !== null) this.delimiters[this.delimiterTop]!.next = this.delimiters.length - 1;
    this.delimiterTop = this.delimiters.length - 1;
    this.i += count;
  }

  /**
   * CommonMark's "process emphasis" over the delimiters above `bottom` (all of them when null); afterwards those
   * delimiters are gone. `openersBottom` keeps a failed search from being repeated, so this is linear.
   */
  private processEmphasis(bottom: number | null): void {
    const d = this.delimiters;
    let first: number | null = null;
    let cursor = this.delimiterTop;
    while (cursor !== null && cursor !== bottom) {
      first = cursor;
      cursor = d[cursor]!.prev;
    }
    const openersBottom: (number | null)[] = new Array(16).fill(bottom);
    let closerEntry = first;
    while (closerEntry !== null) {
      const closer = closerEntry;
      const closerNode = d[closer]!.node;
      const closing = this.nodes[closerNode]!.delimiter!;
      if (!closing.canClose) {
        closerEntry = d[closer]!.next;
        continue;
      }
      const key = openersBottomKey(closing);
      let found: number | null = null;
      let candidate = d[closer]!.prev;
      while (candidate !== null && candidate !== bottom && candidate !== openersBottom[key]) {
        const opener = this.nodes[d[candidate]!.node]!.delimiter;
        if (opener && opener.char === closing.char && opener.canOpen && canPair(opener, closing)) {
          found = candidate;
          break;
        }
        candidate = d[candidate]!.prev;
      }
      if (found === null) {
        openersBottom[key] = d[closer]!.prev;
        closerEntry = d[closer]!.next;
        if (!closing.canOpen) this.removeDelimiter(closer, openersBottom);
        continue;
      }
      const openerNode = d[found]!.node;
      const opener = this.nodes[openerNode]!.delimiter!;
      let used: number;
      let mark: Mark;
      if (closing.char === '~') {
        used = closing.count;
        mark = { type: 'strike' };
      } else if (closing.char === '=') {
        used = 2;
        mark = YELLOW;
      } else {
        used = opener.count >= 2 && closing.count >= 2 ? 2 : 1;
        mark = { type: used === 2 ? 'bold' : 'italic' };
      }
      this.spans.push({ start: openerNode + 1, end: closerNode, mark });
      let between = d[found]!.next;
      while (between !== null && between !== closer) {
        const entry = between;
        between = d[entry]!.next;
        this.removeDelimiter(entry, openersBottom);
      }
      opener.count -= used;
      closing.count -= used;
      if (opener.count === 0) this.removeDelimiter(found, openersBottom);
      if (closing.count === 0) {
        closerEntry = d[closer]!.next;
        this.removeDelimiter(closer, openersBottom);
      }
    }
    if (bottom !== null) d[bottom]!.next = null;
    this.delimiterTop = bottom;
  }

  private removeDelimiter(entry: number, openersBottom: (number | null)[]): void {
    const { prev, next } = this.delimiters[entry]!;
    if (prev !== null) this.delimiters[prev]!.next = next;
    if (next !== null) this.delimiters[next]!.prev = prev;
    else this.delimiterTop = prev;
    for (let k = 0; k < openersBottom.length; k++) if (openersBottom[k] === entry) openersBottom[k] = prev;
  }

  private addMark(mark: Mark, index: number): void {
    const node = this.nodes[index]!;
    if (node.atom) return;
    const rank = markRank(mark);
    if (node.marks.some((m) => markRank(m) === rank)) return;
    node.marks.push(mark);
  }

  /** Marks that don't depend on order: emphasis marks of one rank are all equal and links never overlap. */
  private applySpans(): void {
    const depths: (Int32Array | undefined)[] = new Array(9).fill(undefined);
    const marks: (Mark | undefined)[] = new Array(9).fill(undefined);
    for (const span of this.spans) {
      if (span.start >= span.end) continue;
      if (span.mark.type === 'link') {
        for (let k = span.start; k < span.end; k++) this.addMark(span.mark, k);
        continue;
      }
      const rank = markRank(span.mark);
      const changes = (depths[rank] ??= new Int32Array(this.nodes.length + 1));
      marks[rank] = span.mark;
      changes[span.start] = changes[span.start]! + 1;
      changes[span.end] = changes[span.end]! - 1;
    }
    for (let rank = 0; rank < 9; rank++) {
      const changes = depths[rank];
      const mark = marks[rank];
      if (!changes || !mark) continue;
      let depth = 0;
      for (let k = 0; k < this.nodes.length; k++) {
        depth += changes[k]!;
        if (depth > 0) this.addMark(mark, k);
      }
    }
    this.spans = [];
  }

  // Tags

  private processTags(): void {
    const open: number[] = [];
    const openByName = new Map<string, { position: number; node: number }[]>();
    const matched: { start: number; end: number; marks: Mark[] }[] = [];
    for (let index = 0; index < this.nodes.length; index++) {
      const tag = this.nodes[index]!.tag;
      if (!tag) continue;
      if (!tag.closing) {
        const list = openByName.get(tag.name) ?? [];
        list.push({ position: open.length, node: index });
        openByName.set(tag.name, list);
        open.push(index);
        continue;
      }
      let position: number | undefined;
      const list = openByName.get(tag.name);
      while (list?.length) {
        const last = list.pop()!;
        if (last.position < open.length && open[last.position] === last.node) {
          position = last.position;
          break;
        }
      }
      if (position === undefined) continue;
      const opener = open[position]!;
      if (opener + 1 < index) matched.push({ start: opener + 1, end: index, marks: this.nodes[opener]!.tag!.marks });
      this.nodes[opener] = emptyNode();
      this.nodes[index] = emptyNode();
      open.length = position;
    }
    this.applyNested(matched);
  }

  /** Matched tags nest properly, and the innermost tag wins a rank, as if each were applied as it closed. */
  private applyNested(ranges: { start: number; end: number; marks: Mark[] }[]): void {
    if (!ranges.length) return;
    const order = ranges.map((_, k) => k).sort((a, b) => (ranges[a]!.start !== ranges[b]!.start ? ranges[a]!.start - ranges[b]!.start : ranges[b]!.end - ranges[a]!.end));
    const active: number[] = [];
    const byRank: Mark[][] = Array.from({ length: 9 }, () => []);
    let next = 0;
    for (let index = 0; index < this.nodes.length; index++) {
      while (active.length && ranges[active[active.length - 1]!]!.end <= index) {
        for (const mark of ranges[active.pop()!]!.marks) byRank[markRank(mark)]!.pop();
      }
      while (next < order.length && ranges[order[next]!]!.start === index) {
        for (const mark of ranges[order[next]!]!.marks) byRank[markRank(mark)]!.push(mark);
        active.push(order[next]!);
        next += 1;
      }
      if (!active.length) continue;
      for (const list of byRank) {
        const mark = list[list.length - 1];
        if (mark) this.addMark(mark, index);
      }
    }
  }

  // Output

  flattened(): Inl[] {
    const result: Inl[] = [];
    let run = '';
    let runMarks: Mark[] = [];
    for (const node of this.nodes) {
      if (node.atom) {
        if (run) result.push(text(run, runMarks));
        run = '';
        result.push(node.atom);
        continue;
      }
      const t = node.delimiter ? node.delimiter.char.repeat(node.delimiter.count) : node.text;
      if (!t) continue;
      const marks = canonical(node.marks);
      if (!sameMarks(marks, runMarks)) {
        if (run) result.push(text(run, runMarks));
        run = '';
        runMarks = marks;
      }
      run += t;
    }
    if (run) result.push(text(run, runMarks));
    return result;
  }
}

function imageNode(sha: string, name: string, mime: string, width: number | undefined): Inline {
  return { type: 'image', attrs: width === undefined ? { sha, name, mime } : { sha, name, mime, width } };
}

class InlineParser {
  /** Every image and attachment reference seen, in document order. */
  refs: AttachmentRef[] = [];

  constructor(private readonly resolve: NoteLinkResolver) {}

  parse(source: string): Inl[] {
    return this.run(graphemes(source), new Set());
  }

  /** The lines of a paragraph or list item. A line ending in two spaces makes a hard break, a plain newline a soft one. */
  parseLines(lines: string[]): Inl[] {
    const chars: string[] = [];
    const hard = new Set<number>();
    lines.forEach((line, index) => {
      if (index > 0) {
        if (hardBreakSpaces(lines[index - 1]!)) hard.add(chars.length);
        chars.push('\n');
      }
      for (const c of graphemes(trimmed(line))) chars.push(c);
    });
    return resolvingSoftBreaks(this.run(chars, hard));
  }

  private run(chars: string[], hard: Set<number>): Inl[] {
    const scanner = new InlineScanner(chars, this.resolve);
    scanner.hardNewlines = hard;
    scanner.scan();
    for (const ref of scanner.refs) this.refs.push(ref);
    return scanner.flattened();
  }
}

// MARK: - Line classification

interface SourceLine {
  text: string;
}

const isBlank = (line: string): boolean => /^[ \t]*$/.test(line);

function indentation(line: string): number {
  let columns = 0;
  for (const c of line) {
    if (c === ' ') columns += 1;
    else if (c === '\t') columns += 4 - (columns % 4);
    else break;
  }
  return columns;
}

function removingIndentation(line: string, columns: number): string {
  let removed = 0;
  let index = 0;
  while (index < line.length && removed < columns) {
    if (line[index] === ' ') removed += 1;
    else if (line[index] === '\t') removed += 4 - (removed % 4);
    else break;
    index += 1;
  }
  return line.slice(index);
}

/** Two spaces when `line` ends in a hard break's spaces. */
const hardBreakSpaces = (line: string): string => (trailing(line, ' ') >= 2 ? '  ' : '');

function atxHeading(line: string): [number, string] | undefined {
  if (indentation(line) >= 4) return undefined;
  const rest = line.replace(/^ +/, '');
  const hashes = /^#*/.exec(rest)![0].length;
  if (hashes < 1 || hashes > 6) return undefined;
  const after = rest.slice(hashes);
  if (after && after[0] !== ' ' && after[0] !== '\t') return undefined;
  let t = trimmed(after);
  const closing = trailing(t, '#');
  if (closing > 0) {
    const before = t.slice(0, t.length - closing);
    if (!before || before.endsWith(' ') || before.endsWith('\t')) t = trimmed(before);
  }
  return [hashes, t];
}

function isThematicBreak(line: string): boolean {
  if (indentation(line) >= 4) return false;
  const marks = graphemes(line).filter((c) => c !== ' ' && c !== '\t');
  return marks.length >= 3 && '*-_'.includes(marks[0]!) && marks[0]!.length === 1 && marks.every((c) => c === marks[0]);
}

function setextLevel(line: string): number | undefined {
  if (indentation(line) >= 4) return undefined;
  const t = trimmed(line);
  if (!/^(=+|-+)$/.test(t)) return undefined;
  return t[0] === '=' ? 1 : 2;
}

function quoteContent(line: string): string | undefined {
  if (indentation(line) >= 4) return undefined;
  const rest = line.replace(/^[ \t]+/, '');
  if (rest[0] !== '>') return undefined;
  const content = rest.slice(1);
  return content[0] === ' ' || content[0] === '\t' ? content.slice(1) : content;
}

/**
 * Whether `line` starts a block other than a paragraph. A paragraph can't be interrupted by an indented code line,
 * an empty list item or an ordered item that doesn't start at 1.
 */
function startsBlock(line: string, interruptingParagraph = false): boolean {
  if (fence(line) || atxHeading(line) || isThematicBreak(line) || quoteContent(line) !== undefined || parseBlockAttributes(line)) return true;
  const item = listItemLine(line);
  if (!item || item.indent >= 4) return false;
  if (!interruptingParagraph) return true;
  if (!item.content) return false;
  return item.kind.type !== 'ordered' || item.kind.number === 1;
}

interface Fence {
  char: string;
  length: number;
  indent: number;
  language?: string;
}

function fence(line: string): Fence | undefined {
  const indent = indentation(line);
  if (indent >= 4) return undefined;
  const rest = line.replace(/^ +/, '');
  const char = rest[0];
  if (char !== '`' && char !== '~') return undefined;
  const run = (char === '`' ? /^`*/ : /^~*/).exec(rest)![0].length;
  if (run < 3) return undefined;
  const info = trimmed(rest.slice(run));
  if (char === '`' && info.includes('`')) return undefined;
  const word = info.split(' ').find((w) => w);
  return { char, length: run, indent, language: word === undefined ? undefined : unescapeText(word) };
}

function fenceCloses(f: Fence, line: string): boolean {
  if (indentation(line) >= 4) return false;
  const t = graphemes(trimmed(line));
  return t.length >= f.length && t.every((c) => c === f.char);
}

type ListKind = { type: 'bullet' } | { type: 'ordered'; number: number } | { type: 'task'; checked: boolean };

interface ListItemLine {
  indent: number;
  kind: ListKind;
  content: string;
}

function listItemLine(line: string): ListItemLine | undefined {
  const indent = indentation(line);
  const rest = line.replace(/^[ \t]+/, '');
  if (!rest) return undefined;
  let kind: ListKind;
  let after: string;
  if ('-+*'.includes(rest[0]!) && graphemes(rest.slice(0, 4))[0]!.length === 1) {
    kind = { type: 'bullet' };
    after = rest.slice(1);
  } else {
    const digits = /^[0-9]*/.exec(rest)![0];
    if (digits.length < 1 || digits.length > 9) return undefined;
    const delimiter = rest[digits.length];
    if (delimiter !== '.' && delimiter !== ')') return undefined;
    kind = { type: 'ordered', number: Number(digits) };
    after = rest.slice(digits.length + 1);
  }
  if (after && after[0] !== ' ' && after[0] !== '\t') return undefined;
  let t = trimmed(after);
  const chars = graphemes(t.slice(0, 8));
  const lowered = chars.slice(0, 3).join('').toLowerCase();
  if ((lowered === '[ ]' || lowered === '[x]') && (chars.length === 3 || chars[3] === ' ' || chars[3] === '\t')) {
    kind = { type: 'task', checked: lowered === '[x]' };
    t = trimmed(t.slice(3));
  }
  return { indent, kind, content: t };
}

// MARK: - Attribute comments and fallback payloads

/** `<!-- noteit: align=center indent=2 level=3 widths=120,80 doc=… -->`. Unknown keys are ignored. */
interface BlockAttributes {
  align?: Align;
  indent?: number;
  level?: number;
  widths?: number[];
  payload?: Node;
}

const ATTRIBUTES_PREFIX = '<!-- noteit:';
const ALIGNS = new Set(['left', 'center', 'right', 'justify']);

function parseBlockAttributes(line: string): BlockAttributes | undefined {
  const t = trimmed(line);
  if (indentation(line) >= 4 || !t.startsWith(ATTRIBUTES_PREFIX) || !t.endsWith('-->')) return undefined;
  const attrs: BlockAttributes = {};
  const inRange = (v: number | undefined) => (v !== undefined && v >= 1 && v <= 8 ? v : undefined);
  for (const pair of t.slice(ATTRIBUTES_PREFIX.length, t.length - 3).split(/[ \t]/)) {
    const [key, value] = splitOnce(pair, '=');
    if (!pair || value === undefined) continue;
    if (key === 'align') attrs.align = ALIGNS.has(value) ? (value as Align) : undefined;
    else if (key === 'indent') attrs.indent = inRange(parseInt64(value));
    else if (key === 'level') attrs.level = inRange(parseInt64(value));
    else if (key === 'widths') {
      const numbers = value.split(',').filter((s) => s).map(parseDouble).filter((n): n is number => n !== undefined);
      attrs.widths = !numbers.length || numbers.some((n) => !Number.isFinite(n)) ? undefined : numbers;
    } else if (key === 'doc') attrs.payload = decodeRichBlock(value);
  }
  return attrs;
}

/** A comment followed by a blank line or the end is an empty paragraph with its alignment and indent. */
const emptyParagraphOf = (a: BlockAttributes): Node | undefined => (a.align !== undefined || a.indent !== undefined ? paragraph(a.align, a.indent, []) : undefined);

class DocDecodingError extends Error {}
class UnknownDocType extends Error {}
/** Nodes kept verbatim because they hold a type this reader doesn't know (Swift `DocNode.unknown`). */
const UNKNOWN_NODES = new WeakSet<object>();
const isUnknown = (n: Node): boolean => UNKNOWN_NODES.has(n);

/** A base64url noteit-doc block (Swift `RichBlock.decode`); undefined when it isn't one or is a whole doc. */
function decodeRichBlock(value: string): Node | undefined {
  let base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  while (base64.length % 4 !== 0) base64 += '=';
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(base64)) return undefined;
  try {
    const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    const node = decodeNode(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)));
    return node.type === 'doc' ? undefined : node;
  } catch {
    return undefined;
  }
}

// Decoding a payload as Swift `DocNode(json:)` does: invalid shapes throw, unknown types make the nearest block
// an unknown node kept verbatim. The result is canonical JSON (no nulls, no empty `content`, `marks` or `attrs`).

function fields(v: unknown): Json {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new DocDecodingError();
  return v as Json;
}

function optional<T>(o: Json, key: string, check: (v: unknown) => T): T | undefined {
  const v = o[key];
  return v === undefined || v === null ? undefined : check(v);
}

const asString = (v: unknown): string => {
  if (typeof v !== 'string') throw new DocDecodingError();
  return v;
};
const asInt = (v: unknown): number => {
  if (typeof v !== 'number' || !Number.isInteger(v) || Math.abs(v) >= 1e15) throw new DocDecodingError();
  return v;
};
const asDouble = (v: unknown): number => {
  if (typeof v !== 'number' || !Number.isFinite(v)) throw new DocDecodingError();
  return v;
};
const asBool = (v: unknown): boolean => {
  if (typeof v !== 'boolean') throw new DocDecodingError();
  return v;
};
const asArray = (o: Json, key: string): unknown[] => {
  const v = o[key];
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new DocDecodingError();
  return v;
};
const required = <T>(v: T | undefined): T => {
  if (v === undefined) throw new DocDecodingError();
  return v;
};
const attrsOf = (o: Json): Json => fields(o.attrs === undefined || o.attrs === null ? {} : o.attrs);
const asAlign = (v: unknown): Align => {
  if (!ALIGNS.has(asString(v))) throw new DocDecodingError();
  return v as Align;
};

function decodeMark(v: unknown): Mark {
  const o = fields(v);
  const type = required(optional(o, 'type', asString));
  const attr = (key: string, check: (v: unknown) => string | number) => required(optional(attrsOf(o), key, check));
  switch (type) {
    case 'bold':
    case 'italic':
    case 'underline':
    case 'strike':
    case 'code':
      return { type };
    case 'link':
      return link(attr('href', asString) as string);
    case 'textColor':
    case 'highlight':
      return { type, attrs: { color: attr('color', asString) as string } };
    case 'fontSize':
      return { type, attrs: { delta: attr('delta', asInt) as number } };
    default:
      throw new UnknownDocType();
  }
}

function decodeInline(v: unknown): Inl {
  const o = fields(v);
  const type = required(optional(o, 'type', asString));
  switch (type) {
    case 'text': {
      const marks = asArray(o, 'marks').map(decodeMark);
      return text(required(optional(o, 'text', asString)), marks);
    }
    case 'hardBreak':
      return optional(attrsOf(o), 'soft', asBool) === true ? SOFT : HARD;
    case 'image': {
      const a = attrsOf(o);
      return imageNode(required(optional(a, 'sha', asString)), required(optional(a, 'name', asString)), required(optional(a, 'mime', asString)), optional(a, 'width', asDouble));
    }
    case 'attachment': {
      const a = attrsOf(o);
      return { type: 'attachment', attrs: { sha: required(optional(a, 'sha', asString)), name: required(optional(a, 'name', asString)), mime: required(optional(a, 'mime', asString)) } };
    }
    default:
      throw new UnknownDocType();
  }
}

function decodeNode(v: unknown): Node {
  const o = fields(v);
  const type = required(optional(o, 'type', asString));
  try {
    return decodeKnown(type, o);
  } catch (e) {
    if (!(e instanceof UnknownDocType)) throw e;
    UNKNOWN_NODES.add(o);
    return o as Node;
  }
}

function decodeKnown(type: string, o: Json): Node {
  const inlines = () => asArray(o, 'content').map(decodeInline);
  const a = () => attrsOf(o);
  switch (type) {
    case 'doc':
      return { type: 'doc', content: asArray(o, 'content').map(decodeNode) };
    case 'paragraph':
      return paragraph(optional(a(), 'align', asAlign), optional(a(), 'indent', asInt), inlines());
    case 'heading':
      return heading(required(optional(a(), 'level', asInt)), optional(a(), 'align', asAlign), optional(a(), 'indent', asInt), inlines());
    case 'codeBlock':
      return codeBlock(optional(a(), 'align', asAlign), optional(a(), 'language', asString), inlines());
    case 'blockquote': {
      const indent = optional(a(), 'indent', asInt);
      const node: Node = { type: 'blockquote' };
      if (indent !== undefined) node.attrs = { indent };
      node.content = asArray(o, 'content').map(decodeNode);
      return node;
    }
    case 'horizontalRule':
      return { type: 'horizontalRule' };
    case 'listItem': {
      const kind = optional(a(), 'kind', (k) => {
        if (k !== 'bullet' && k !== 'ordered' && k !== 'task') throw new DocDecodingError();
        return k;
      });
      return textBlock(
        'listItem',
        { kind: required(kind), level: required(optional(a(), 'level', asInt)), number: optional(a(), 'number', asInt), checked: optional(a(), 'checked', asBool), align: optional(a(), 'align', asAlign) },
        inlines(),
        true,
      );
    }
    case 'table': {
      const raw = a().columnWidths;
      let widths: number[] | undefined;
      if (raw !== undefined && raw !== null) {
        if (!Array.isArray(raw)) throw new DocDecodingError();
        widths = raw.map(asDouble);
      }
      const rows = asArray(o, 'content').map((row) => {
        const r = fields(row);
        if (required(optional(r, 'type', asString)) !== 'tableRow') throw new UnknownDocType();
        return asArray(r, 'content').map((cell) => {
          const c = fields(cell);
          const cellType = required(optional(c, 'type', asString));
          if (cellType !== 'tableHeader' && cellType !== 'tableCell') throw new UnknownDocType();
          return { header: cellType === 'tableHeader', content: asArray(c, 'content').map(decodeNode) };
        });
      });
      return table(widths, rows);
    }
    default:
      throw new UnknownDocType();
  }
}

/** The visible text of blocks with whitespace collapsed: what must match for a payload to be used. */
function fingerprint(nodes: Node[]): string {
  const words: string[] = [];
  const add = (content: Inl[]) => {
    for (const n of content) {
      if (n.type === 'text') words.push(n.text);
      else if (n.type === 'image' || n.type === 'attachment') words.push(` ${n.attrs.name} `);
      else words.push(' ');
    }
    words.push(' ');
  };
  const visit = (n: Node): void => {
    if (isUnknown(n)) return;
    if (n.type === 'paragraph' || n.type === 'heading' || n.type === 'codeBlock' || n.type === 'listItem') add(inlinesOf(n));
    else if (n.type === 'blockquote' || n.type === 'doc') ((n.content as Node[] | undefined) ?? []).forEach(visit);
    else if (n.type === 'table') for (const row of tableRows(n)) for (const cell of row) cell.content.forEach(visit);
  };
  nodes.forEach(visit);
  return graphemes(words.join(''))
    .map((c) => (isWhitespace(c) ? ' ' : c))
    .join('')
    .split(' ')
    .filter((w) => w)
    .join(' ');
}

/** Images and attachments in a payload; their `sha` holds the path. */
function payloadRefs(node: Node): AttachmentRef[] {
  const refs: AttachmentRef[] = [];
  const visit = (n: Node): void => {
    if (isUnknown(n)) return;
    if (n.type === 'paragraph' || n.type === 'heading' || n.type === 'codeBlock' || n.type === 'listItem') {
      for (const i of inlinesOf(n)) {
        if (i.type === 'image') refs.push(i.attrs.width === undefined ? { path: i.attrs.sha, displayName: i.attrs.name } : { path: i.attrs.sha, displayName: i.attrs.name, width: roundInt(i.attrs.width) });
        else if (i.type === 'attachment') refs.push({ path: i.attrs.sha, displayName: i.attrs.name });
      }
    } else if (n.type === 'blockquote' || n.type === 'doc') ((n.content as Node[] | undefined) ?? []).forEach(visit);
    else if (n.type === 'table') for (const row of tableRows(n)) for (const cell of row) cell.content.forEach(visit);
  };
  visit(node);
  return refs;
}

// MARK: - Block parser

/** One or more doc blocks from the same lines (a fence gives one code block per line). */
interface Unit {
  nodes: Node[];
  isListItem: boolean;
}

/** Quotes nested deeper than this read their remaining `>` as text, so nesting can't exhaust the stack. */
const MAX_QUOTE_DEPTH = 32;

const EMPTY_PARAGRAPH = (): Node => ({ type: 'paragraph' });

/**
 * Block structure: CommonMark + GFM (ATX and setext headings, paragraphs, fenced and indented code, lists, task
 * items, quotes, thematic breaks, pipe tables) plus NoteIt's attribute comment lines. Blank lines beyond the one
 * that separates two blocks are empty paragraphs (none between list items).
 */
class BlockParser {
  readonly inline: InlineParser;

  constructor(resolve: NoteLinkResolver) {
    this.inline = new InlineParser(resolve);
  }

  parseBlocks(lines: SourceLine[], quoteDepth = 0): Node[] {
    const units: Unit[] = [];
    /** Blank lines before each unit, and after the last. */
    const blanks: number[] = [0];
    let i = 0;
    let pending: BlockAttributes | undefined;
    const add = (unit: Unit) => {
      units.push(unit);
      blanks.push(0);
    };

    while (i < lines.length) {
      const line = lines[i]!;
      if (isBlank(line.text)) {
        const empty = pending && emptyParagraphOf(pending);
        if (empty) add({ nodes: [empty], isListItem: false });
        pending = undefined;
        blanks[blanks.length - 1]! += 1;
        i += 1;
        continue;
      }
      const comment = parseBlockAttributes(line.text);
      if (comment) {
        if (comment.payload && isUnknown(comment.payload)) {
          add({ nodes: [comment.payload], isListItem: false });
          pending = undefined;
        } else {
          pending = comment;
        }
        i += 1;
        continue;
      }
      const attrs = pending ?? {};
      pending = undefined;
      const previousIsList = units[units.length - 1]?.isListItem === true && blanks[blanks.length - 1] === 0;
      let produced: Unit[] = [];
      let listBlanks: number[] = [];
      const f = fence(line.text);
      const atx = f ? undefined : atxHeading(line.text);
      const item = listItemLine(line.text);
      if (f) {
        let j = i + 1;
        const code: string[] = [];
        while (j < lines.length && !fenceCloses(f, lines[j]!.text)) {
          code.push(removingIndentation(lines[j]!.text, f.indent));
          j += 1;
        }
        produced = [{ nodes: (code.length ? code : ['']).map((c) => codeBlock(attrs.align, f.language, c ? [text(c)] : [])), isListItem: false }];
        i = Math.min(j + 1, lines.length);
      } else if (atx) {
        produced = [{ nodes: [heading(Math.min(atx[0], 3), attrs.align, attrs.indent, this.inline.parse(atx[1]))], isListItem: false }];
        i += 1;
      } else if (isThematicBreak(line.text)) {
        produced = [{ nodes: [{ type: 'horizontalRule' }], isListItem: false }];
        i += 1;
      } else if (quoteDepth < MAX_QUOTE_DEPTH && quoteContent(line.text) !== undefined) {
        const inner: SourceLine[] = [];
        let j = i;
        while (j < lines.length && !isBlank(lines[j]!.text)) {
          const content = quoteContent(lines[j]!.text);
          if (content !== undefined) inner.push({ text: content });
          else if (inner.length && !isBlank(inner[inner.length - 1]!.text) && !startsBlock(lines[j]!.text)) inner.push(lines[j]!);
          else break;
          j += 1;
        }
        const quote: Node = { type: 'blockquote' };
        if (attrs.indent !== undefined) quote.attrs = { indent: attrs.indent };
        quote.content = quoteParagraphs(this.parseBlocks(inner, quoteDepth + 1));
        produced = [{ nodes: [quote], isListItem: false }];
        i = j;
      } else if (item && (item.indent < 4 || previousIsList || attrs.level !== undefined || (attrs.align !== undefined && item.indent % 4 === 0))) {
        const list = this.parseList(lines, i, attrs);
        produced = list.units;
        listBlanks = list.gaps;
        i = list.next;
      } else {
        const tableResult = this.parseTable(lines, i, attrs);
        if (tableResult) {
          produced = [tableResult[0]];
          i = tableResult[1];
        } else if (indentation(line.text) >= 4) {
          let j = i;
          const code: string[] = [];
          let lastCode = i;
          while (j < lines.length && (isBlank(lines[j]!.text) || indentation(lines[j]!.text) >= 4)) {
            code.push(removingIndentation(lines[j]!.text, 4));
            if (!isBlank(lines[j]!.text)) lastCode = j;
            j += 1;
          }
          produced = [{ nodes: code.slice(0, lastCode - i + 1).map((c) => codeBlock(attrs.align, undefined, c ? [text(c)] : [])), isListItem: false }];
          i = lastCode + 1;
        } else {
          const texts = [line.text];
          let j = i + 1;
          let setext: number | undefined;
          while (j < lines.length && !isBlank(lines[j]!.text)) {
            setext = setextLevel(lines[j]!.text);
            if (setext !== undefined || startsBlock(lines[j]!.text, true)) break;
            texts.push(lines[j]!.text);
            j += 1;
          }
          const content = this.inline.parseLines(texts);
          if (setext !== undefined) {
            produced = [{ nodes: [heading(setext, attrs.align, attrs.indent, hardeningSoftBreaks(content))], isListItem: false }];
            i = j + 1;
          } else {
            produced = [{ nodes: [paragraph(attrs.align, attrs.indent, content)], isListItem: false }];
            i = j;
          }
        }
      }
      produced.forEach((unit, index) => {
        if (index === 0 && attrs.payload) unit = this.applying(attrs.payload, unit);
        if (index > 0) blanks[blanks.length - 1] = listBlanks[index]!;
        add(unit);
      });
    }
    const empty = pending && emptyParagraphOf(pending);
    if (empty) add({ nodes: [empty], isListItem: false });

    const result: Node[] = [];
    const newList = listRuns();
    units.forEach((unit, index) => {
      const gap = blanks[index]!;
      const breaks = newList(unit.isListItem ? (unit.nodes[0] as never) : undefined);
      const separator = index === 0 ? 0 : units[index - 1]!.isListItem && unit.isListItem && !breaks ? 0 : 1;
      for (let k = Math.min(separator, gap); k < gap; k++) result.push(EMPTY_PARAGRAPH());
      result.push(...unit.nodes);
    });
    for (let k = 0; k < blanks[units.length]!; k++) result.push(EMPTY_PARAGRAPH());
    return result;
  }

  /** A fallback payload replaces the blocks it was written for, while their visible text still matches. */
  private applying(payload: Node, unit: Unit): Unit {
    if (fingerprint([payload]) !== fingerprint(unit.nodes)) return unit;
    for (const ref of payloadRefs(payload)) this.inline.refs.push(ref);
    return { nodes: [payload], isListItem: payload.type === 'listItem' && !isUnknown(payload) ? unit.isListItem : false };
  }

  // Lists

  private parseList(lines: SourceLine[], first: number, firstAttrs: BlockAttributes): { units: Unit[]; gaps: number[]; next: number } {
    interface Item {
      line: ListItemLine;
      attrs: BlockAttributes;
      text: string[];
      blanksBefore: number;
    }
    const firstLine = listItemLine(lines[first]!.text)!;
    const items: Item[] = [{ line: firstLine, attrs: firstAttrs, text: [firstLine.content + hardBreakSpaces(lines[first]!.text)], blanksBefore: 0 }];
    let j = first + 1;
    while (j < lines.length) {
      let k = j;
      while (k < lines.length && isBlank(lines[k]!.text)) k += 1;
      if (k >= lines.length) break;
      const gap = k - j;
      let attrs: BlockAttributes = {};
      let itemIndex = k;
      const comment = parseBlockAttributes(lines[k]!.text);
      if (comment && k + 1 < lines.length && listItemLine(lines[k + 1]!.text)) {
        attrs = comment;
        itemIndex = k + 1;
      }
      const next = listItemLine(lines[itemIndex]!.text);
      if (next && !isThematicBreak(lines[itemIndex]!.text)) {
        items.push({ line: next, attrs, text: [next.content + hardBreakSpaces(lines[itemIndex]!.text)], blanksBefore: gap });
        j = itemIndex + 1;
        continue;
      }
      if (gap > 0 || startsBlock(lines[k]!.text, true)) break;
      items[items.length - 1]!.text.push(lines[k]!.text);
      j = k + 1;
    }

    const indents = items.map((it) => it.line.indent);
    let levels: number[];
    if (indents.every((n) => n % 4 === 0)) {
      levels = indents.map((n) => n / 4);
    } else {
      const stack: number[] = [];
      levels = indents.map((indent) => {
        while (stack.length && stack[stack.length - 1]! > indent) stack.pop();
        if (stack[stack.length - 1] !== indent) stack.push(indent);
        return stack.length - 1;
      });
    }
    if (firstAttrs.level !== undefined && firstAttrs.level !== levels[0]) {
      const offset = firstAttrs.level - levels[0]!;
      levels = levels.map((l) => l + offset);
    }
    const units: Unit[] = [];
    const gaps: number[] = [];
    items.forEach((it, index) => {
      const level = Math.min(8, Math.max(0, levels[index]!));
      const content = this.inline.parseLines(it.text);
      const k = it.line.kind;
      const attrs =
        k.type === 'task'
          ? { kind: 'task', level, checked: k.checked, align: it.attrs.align }
          : k.type === 'ordered'
            ? { kind: 'ordered', level, number: k.number, align: it.attrs.align }
            : { kind: 'bullet', level, align: it.attrs.align };
      let unit: Unit = { nodes: [textBlock('listItem', attrs, content, true)], isListItem: true };
      if (index > 0 && it.attrs.payload) unit = this.applying(it.attrs.payload, unit);
      units.push(unit);
      gaps.push(it.blanksBefore);
    });
    return { units, gaps, next: j };
  }

  // Tables

  private parseTable(lines: SourceLine[], first: number, attrs: BlockAttributes): [Unit, number] | undefined {
    if (first + 1 >= lines.length || !lines[first]!.text.includes('|')) return undefined;
    const alignments = delimiterRow(lines[first + 1]!.text);
    if (!alignments) return undefined;
    const header = tableCells(lines[first]!.text);
    if (header.length !== alignments.length) return undefined;
    const rows = [header];
    let j = first + 2;
    while (j < lines.length && !isBlank(lines[j]!.text) && lines[j]!.text.includes('|') && !startsBlock(lines[j]!.text)) {
      rows.push(tableCells(lines[j]!.text));
      j += 1;
    }
    const headerIsEmpty = header.every((c) => !c);
    if (headerIsEmpty) rows.shift();
    const docRows = rows.map((row, index) =>
      alignments.map((align, column) => ({
        header: index === 0 && !headerIsEmpty,
        content: [paragraph(align, undefined, this.inline.parse(row[column] ?? ''))],
      })),
    );
    return [{ nodes: [table(attrs.widths, docRows)], isListItem: false }, j];
  }
}

/** `| a | b\|c |` → ["a", "b|c"]: cells trimmed, `\|` unescaped. */
function tableCells(line: string): string[] {
  let t = trimWhitespaces(line);
  if (t.startsWith('|')) t = t.slice(1);
  if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1);
  const cells: string[] = [];
  let current = '';
  const chars = graphemes(t);
  for (let k = 0; k < chars.length; k++) {
    const c = chars[k]!;
    if (c === '\\') {
      const next = chars[k + 1];
      if (next === undefined) {
        current += c;
        break;
      }
      if (next !== '|') current += c;
      current += next;
      k += 1;
    } else if (c === '|') {
      cells.push(current);
      current = '';
    } else {
      current += c;
    }
  }
  cells.push(current);
  return cells.map(trimWhitespaces);
}

function delimiterRow(line: string): (Align | undefined)[] | undefined {
  if (!line.includes('-')) return undefined;
  const result: (Align | undefined)[] = [];
  for (const cell of tableCells(line)) {
    if (!/^[-:]+$/.test(cell) || !cell.includes('-') || cell.slice(1, -1).includes(':')) return undefined;
    const left = cell[0] === ':';
    const right = cell.length > 1 && cell.endsWith(':');
    result.push(left && right ? 'center' : left ? 'left' : right ? 'right' : undefined);
  }
  return line.includes('|') || result.length > 1 ? result : undefined;
}

/** A quote holds paragraphs only; other blocks inside a foreign quote keep their text. */
function quoteParagraphs(nodes: Node[]): Node[] {
  return nodes.flatMap((n): Node[] => {
    if (isUnknown(n)) return [];
    const align = nodeAttrs(n).align as Align | undefined;
    switch (n.type) {
      case 'paragraph':
      case 'heading':
      case 'listItem':
        return [paragraph(align, undefined, inlinesOf(n))];
      case 'codeBlock':
        return [paragraph(align, undefined, inlinesOf(n).map((i) => (i.type === 'text' ? text(i.text, canonical([...(i.marks ?? []), { type: 'code' }])) : i)))];
      case 'blockquote':
        return quoteParagraphs((n.content as Node[] | undefined) ?? []);
      case 'table':
        return tableRows(n).map((row) => {
          const content: Inl[] = row.flatMap((cell) => cell.content.flatMap((p) => (p.type === 'paragraph' ? [...inlinesOf(p), text(' ')] : [])));
          return paragraph(undefined, undefined, content.slice(0, -1));
        });
      default:
        return [];
    }
  });
}

// MARK: - Front matter

const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/** Lines without their endings (LF or CRLF) and the offset after each line's ending. */
function splitLines(s: string, from = 0): { content: string; end: number }[] {
  const out: { content: string; end: number }[] = [];
  let start = from;
  while (start < s.length) {
    const nl = s.indexOf('\n', start);
    const end = nl < 0 ? s.length : nl;
    let content = s.slice(start, end);
    if (content.endsWith('\r')) content = content.slice(0, -1);
    out.push({ content, end: nl < 0 ? end : end + 1 });
    start = nl < 0 ? s.length : nl + 1;
  }
  return out;
}

/** The key of a `key: value` line, undefined for anything else. */
function frontMatterKey(line: string): string | undefined {
  const colon = line.indexOf(':');
  if (colon < 0) return undefined;
  const after = line[colon + 1];
  if (after !== undefined && after !== ' ' && after !== '\t') return undefined;
  const key = line.slice(0, colon);
  return key && !/[ \t]/.test(key) ? key : undefined;
}

function unquoted(value: string): string {
  const chars = graphemes(value);
  const first = chars[0];
  if (chars.length < 2 || first !== chars[chars.length - 1] || (first !== '"' && first !== "'")) return value;
  const inner = chars.slice(1, -1).join('');
  if (first !== '"') return inner.replace(/''/g, "'");
  return inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
}

function parseBool(value: string): boolean | undefined {
  const v = value.toLowerCase();
  return ['true', 'yes', 'on'].includes(v) ? true : ['false', 'no', 'off'].includes(v) ? false : undefined;
}

function parseTags(value: string, continuation: string[]): string[] {
  let raw: string[] = [];
  if (value.startsWith('[') && value.endsWith(']')) raw = value.slice(1, -1).split(',').filter((s) => s);
  else if (value) raw = value.split(/[, ]/).filter((s) => s);
  for (const line of continuation) {
    const t = trimWhitespaces(line);
    if (t.startsWith('- ')) raw.push(t.slice(2));
  }
  return raw
    .map((s) => unquoted(trimWhitespaces(s)))
    .map((s) => (s.startsWith('#') ? s.slice(1) : s))
    .filter((s) => s);
}

/** ISO 8601 with `Z`, an offset or no zone (read as UTC); fractional seconds and date-only values are accepted. */
export function parseFrontMatterDate(value: string): Date | undefined {
  let t = value.replace(/ /g, 'T');
  if ([...t].length === 10) t += 'T00:00:00Z';
  if (!(t.endsWith('Z') || /[+-]\d\d:?\d\d$/.test(t))) t += 'Z';
  // ISO8601DateFormatter's internet date-time, with or without fractional seconds; out-of-range days roll over.
  const m = /^(\d{1,4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?(Z|([+-])(\d\d)(?::?(\d\d))?)$/.exec(t);
  if (!m) return undefined;
  const [month, day, hour, minute, second] = [m[2], m[3], m[4], m[5], m[6]].map(Number) as [number, number, number, number, number];
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 24 || minute > 59 || second > 59) return undefined;
  const date = new Date(Date.UTC(2000, month - 1, day, hour, minute, second, m[7] ? Math.floor(Number(m[7]) * 1000) : 0));
  date.setUTCFullYear(Number(m[1]) + date.getUTCFullYear() - 2000);
  if (m[9]) date.setTime(date.getTime() - (m[9] === '-' ? -1 : 1) * (Number(m[10]) * 60 + Number(m[11] ?? 0)) * 60_000);
  return date;
}

/**
 * Reads the YAML front matter at the start of `text` (Swift `FrontMatter.read`); `bodyStart` is the offset after
 * the closing `---`, or 0 without front matter. Throws `InvalidFrontMatterError`.
 */
export function readFrontMatter(text: string): { frontMatter: FrontMatter; bodyStart: number } {
  const result: FrontMatter = { pinned: false, locked: false, tags: [], extra: '' };
  const lines = splitLines(text);
  if (lines[0]?.content !== '---') return { frontMatter: result, bodyStart: 0 };
  const entries: { content: string; number: number }[][] = [];
  let bodyStart: number | undefined;
  for (let k = 1; k < lines.length; k++) {
    const line = lines[k]!;
    const number = k + 1;
    if (line.content === '---' || line.content === '...') {
      bodyStart = line.end;
      break;
    }
    const first = line.content[0];
    if (first === undefined || first === ' ' || first === '\t' || first === '-' || first === '#') {
      if (!entries.length) entries.push([]);
      entries[entries.length - 1]!.push({ content: line.content, number });
    } else {
      if (frontMatterKey(line.content) === undefined) throw new InvalidFrontMatterError(number);
      entries.push([{ content: line.content, number }]);
    }
  }
  if (bodyStart === undefined) throw new InvalidFrontMatterError(1);

  const extra: string[] = [];
  for (const entry of entries) {
    const head = entry[0];
    const key = head && frontMatterKey(head.content);
    if (!head || key === undefined) {
      extra.push(...entry.map((l) => l.content));
      continue;
    }
    const value = unquoted(trimWhitespaces(head.content.slice(key.length + 1)));
    const must = <T>(v: T | undefined): T => {
      if (v === undefined) throw new InvalidFrontMatterError(head.number);
      return v;
    };
    const date = () => must(parseFrontMatterDate(value));
    const bool = () => must(parseBool(value));
    const uuid = () => must(UUID_RE.test(value) ? value.toUpperCase() : undefined);
    switch (key) {
      case 'id':
        result.id = uuid();
        break;
      case 'created':
        result.created = date();
        break;
      case 'updated':
        result.updated = date();
        break;
      case 'deleted':
        result.deleted = date();
        break;
      case 'pinned':
        result.pinned = bool();
        break;
      case 'locked':
        result.locked = bool();
        break;
      case 'conflict-of':
        result.conflictOf = uuid();
        break;
      case 'conflict-source':
        result.conflictSource = value;
        break;
      case 'tags':
        result.tags = parseTags(value, entry.slice(1).map((l) => l.content));
        extra.push(...entry.map((l) => l.content));
        break;
      default:
        extra.push(...entry.map((l) => l.content));
    }
  }
  result.extra = extra.join('\n');
  return { frontMatter: result, bodyStart };
}

// MARK: - Codec

/**
 * Reads Markdown in either profile of the Swift codec (library or portable), as `MarkdownCodec.parse`. Throws
 * only `InvalidFrontMatterError`. Images and attachments keep their path in `sha`; see `resolveMarkdownAttachments`.
 */
export function parseMarkdown(markdown: string, opts: MarkdownReadOptions = {}): ParsedMarkdown {
  const source = markdown.startsWith('\uFEFF') ? markdown.slice(1) : markdown;
  const { frontMatter, bodyStart } = readFrontMatter(source);
  const parser = new BlockParser(opts.resolveNoteLink ?? (() => undefined));
  const lines = splitLines(source, bodyStart).map((l) => ({ text: l.content }));
  if (bodyStart !== 0 && lines[0] && isBlank(lines[0].text)) lines.shift();
  const blocks = parser.parseBlocks(lines);
  const seen = new Set<string>();
  const attachmentRefs = parser.inline.refs.filter((r) => {
    const key = JSON.stringify([r.path, r.displayName, r.width ?? null]);
    return !seen.has(key) && !!seen.add(key);
  });
  const body: BodyContainer = { format: 'noteit-doc', version: 1, doc: { type: 'doc', content: blocks as Block[] }, attachments: {} };
  if (frontMatter.extra) body.frontMatter = frontMatter.extra;
  return { frontMatter, body, attachmentRefs };
}

/** Markdown → the document alone; see `parseMarkdown`. */
export function markdownToDoc(markdown: string, opts: MarkdownReadOptions = {}): NoteItDoc {
  return parseMarkdown(markdown, opts).body.doc;
}

function mapContent(node: Node, transform: (content: Inl[]) => Inl[]): Node {
  if (isUnknown(node)) return node;
  switch (node.type) {
    case 'doc':
    case 'blockquote':
      return { ...node, content: ((node.content as Node[] | undefined) ?? []).map((n) => mapContent(n, transform)) };
    case 'paragraph':
    case 'heading':
    case 'codeBlock':
    case 'listItem': {
      const { content: _, ...rest } = node;
      const content = transform(inlinesOf(node));
      return content.length ? { ...rest, content } : (rest as Node);
    }
    case 'table':
      return table(
        (nodeAttrs(node).columnWidths as number[] | undefined) ?? undefined,
        tableRows(node).map((row) => row.map((c) => ({ header: c.header, content: c.content.map((n) => mapContent(n, transform)) }))),
      );
    default:
      return node;
  }
}

/**
 * `parsed` with each image and attachment path replaced by the bytes `read` gives for it, keyed by SHA-256
 * (Swift `MarkdownCodec.resolvingAttachments`). A path with no data, empty data or data over the attachment
 * limit is dropped from the body and listed in `unresolvedImages`.
 */
export function resolveMarkdownAttachments(parsed: ParsedMarkdown, read: (path: string) => Uint8Array | undefined): ImportedMarkdown {
  const store: BodyContainer = { ...parsed.body, attachments: {} };
  const shas = new Map<string, string>();
  const unresolved: AttachmentRef[] = [];
  const tried = new Set<string>();
  const pending = new Map<string, Uint8Array>();
  for (const ref of parsed.attachmentRefs) {
    if (tried.has(ref.path)) continue;
    tried.add(ref.path);
    const bytes = read(ref.path);
    if (!bytes || !bytes.length || bytes.length > MAX_ATTACHMENT_BYTES) {
      unresolved.push(ref);
      continue;
    }
    pending.set(ref.path, bytes);
  }
  const doc = mapContent(parsed.body.doc as unknown as Node, (content) =>
    mergingTextRuns(
      content.flatMap((n): Inl[] => {
        if (n.type !== 'image' && n.type !== 'attachment') return [n];
        const bytes = pending.get(n.attrs.sha);
        if (!bytes) return [];
        // The first node with these bytes names the attachment, as in Swift.
        let sha = shas.get(n.attrs.sha);
        if (sha === undefined) {
          sha = sha256HexSync(bytes);
          shas.set(n.attrs.sha, sha);
        }
        if (!store.attachments[sha]) addAttachment(store, bytes, n.attrs.name, n.attrs.mime);
        return [{ ...n, attrs: { ...n.attrs, sha } } as Inl];
      }),
    ),
  );
  store.doc = doc as unknown as NoteItDoc;
  return { frontMatter: parsed.frontMatter, body: store, unresolvedImages: unresolved };
}

// MARK: - Paste (Swift `MarkdownPasteDetector` and `pasteMarkdown`)

/** Longer pastes skip detection and paste as plain text. */
export const PASTE_MAX_LENGTH = 200_000;
/** Converting a line longer than this could stall the editor, so such pastes stay plain text. */
export const PASTE_MAX_LINE_LENGTH = 5_000;

/** `MarkdownReader.lines`: CRLF and CR become LF. */
const pasteLines = (text: string): string[] => text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

// The Swift patterns use possessive quantifiers; these are written so that JS backtracking stays linear.
const STRONG_SIGNALS = [
  /^[ \t]*[-*+] \[[ xX]\](?:[ \t]|$)/m,
  /\[[^[\]\n]+\]\(https?:\/\/[^()\s]+(?:[ \t]+"[^"\n]*")?\)/,
  /^ {0,3}>[ \t]+\S/m,
];
const WORD = '\\p{Alphabetic}\\p{M}\\p{Nd}\\p{Pc}\\u200c\\u200d';
const BOLD_OPEN = new RegExp(`(?<![${WORD}*])\\*\\*[^\\s*]`, 'u');
const BOLD_CLOSE = new RegExp(`[^\\s*]\\*\\*(?![${WORD}*(])`, 'gu');
const FENCE = /^[ \t]*(?:```|~~~)/;
const LIST_ITEM = /^[ \t]*(?:[-*+]|\p{Nd}{1,9}[.)]) \S/u;
const COMMENT_STAR = /^[ \t]+\*/;
const ENV_LINE = /^[A-Z_][A-Z0-9_]*=/;
const ORDERED_LIST_MARKER = /^\p{Nd}{1,9}[.)] /u;
const CODE_STARTS = ['def ', 'class ', 'import ', 'from ', 'func ', 'fn ', '#include', '#!', '//', '/*'];

/** Decides whether pasted plain text is Markdown source worth converting. Anything unclear stays plain text. */
export function looksLikeMarkdown(text: string): boolean {
  if (text.length > PASTE_MAX_LENGTH) return false;
  const all = pasteLines(text);
  const lines = all.slice(frontMatterLineCount(all));
  let hasFencedBlock = false;
  let outside: string[] = [];
  let fenced: string[] | undefined;
  for (const line of lines) {
    if (FENCE.test(line)) {
      if (!fenced) {
        fenced = [line];
      } else {
        fenced = undefined;
        hasFencedBlock = true;
      }
    } else if (fenced) {
      fenced.push(line);
    } else {
      outside.push(line);
    }
  }
  outside = outside.concat(fenced ?? []);
  if (looksLikeCode(outside)) return false;
  if (hasFencedBlock) return true;

  const joined = outside.join('\n');
  const normalized = removingBareURLs(joined);
  if (STRONG_SIGNALS.some((r) => r.test(normalized)) || hasBold(normalized) || hasTable(normalized)) return true;
  const inComment = joined.includes('/**') || joined.includes('*/');
  return outside.filter((l) => LIST_ITEM.test(l) && !(inComment && COMMENT_STAR.test(l))).length >= 2;
}

/** Whether some line of `text` is longer than `limit` UTF-16 units. */
export function hasLineLongerThan(text: string, limit: number): boolean {
  let run = 0;
  for (let k = 0; k < text.length; k++) {
    const unit = text.charCodeAt(k);
    if (unit === 0x0a || unit === 0x0d || unit === 0x2028 || unit === 0x2029 || unit === 0x85) {
      run = 0;
    } else if (++run > limit) {
      return true;
    }
  }
  return false;
}

/** The lines of a leading `---` YAML block such as an Obsidian note's front matter, through its closing `---` or `...`, or 0. */
export function frontMatterLineCount(lines: string[]): number {
  const trailingTrimmed = (line: string) => trimBy(line, isSpaceOrTab, false);
  if (!lines.length || trailingTrimmed(lines[0]!) !== '---') return 0;
  const close = lines.findIndex((l, k) => k > 0 && ['---', '...'].includes(trailingTrimmed(l)));
  if (close < 0) return 0;
  let hasKey = false;
  for (const line of lines.slice(1, close)) {
    if (isBlank(line)) continue;
    if (isFrontMatterKey(line)) {
      hasKey = true;
      continue;
    }
    const other = line[0] === ' ' || line[0] === '\t' || line.startsWith('- ') || line === '#' || line.startsWith('# ');
    if (!hasKey || !other) return 0;
  }
  return hasKey ? close + 1 : 0;
}

/** A column-0 quoted key, or a short label before the first `: ` or a trailing `:` that doesn't read like prose. */
function isFrontMatterKey(line: string): boolean {
  const endsKey = (rest: string) => rest === ':' || rest.startsWith(': ') || rest.startsWith(':\t');
  const quote = line[0];
  if (quote === '"' || quote === "'") {
    const close = line.indexOf(quote, 1);
    return close >= 0 && endsKey(line.slice(close + 1));
  }
  const first = graphemes(line.slice(0, 8))[0];
  if (first === undefined || !(isLetter(first) || isNumber(first) || first === '_')) return false;
  let colon = -1;
  for (let k = line.indexOf(':'); k >= 0; k = line.indexOf(':', k + 1)) {
    if (endsKey(line.slice(k))) {
      colon = k;
      break;
    }
  }
  if (colon < 0) return false;
  const key = line.slice(0, colon);
  const last = graphemes(key).pop() ?? '';
  return (
    !ORDERED_LIST_MARKER.test(line) &&
    !key.includes('://') &&
    !key.includes('. ') &&
    !key.includes(') ') &&
    key.split(/[ \t]/).filter((w) => w).length <= 4 &&
    !(last.length === 1 && '.!?,;'.includes(last))
  );
}

const isWordScalar = (c: string): boolean => /^[\p{L}\p{M}\p{N}_]$/u.test(c);

/** Diffs, and text where many lines read like a programming language. */
function looksLikeCode(lines: string[]): boolean {
  if (lines.some((l) => l.startsWith('diff --git') || l.startsWith('@@ ') || l.startsWith('+++ ') || l.startsWith('--- a/'))) return true;
  const changed = lines.filter((l) => l.startsWith('+') || l.startsWith('-'));
  const indented = changed.filter((l) => l.slice(1).startsWith('  ') || l.slice(1).startsWith('\t'));
  if (changed.length && indented.length * 2 > changed.length) return true;

  const inComment = lines.some((l) => l.includes('/*') || l.includes('*/'));
  const nonBlank = lines.filter((l) => trimWhitespaces(l));
  if (!nonBlank.length) return false;
  // Less-indented lines before the current one, each with whether it opens a YAML map (a bare `key:` or a
  // `- key:` item) and whether it can hold a YAML list (a `key:` or `- key:` with an empty value).
  const outer: { indent: number; opensMap: boolean; opensList: boolean }[] = [];
  let codeLike = 0;
  for (const line of nonBlank) {
    const indent = /^[ \t]*/.exec(line)![0].length;
    while (outer.length && outer[outer.length - 1]!.indent >= indent) outer.pop();
    const t = trimWhitespaces(line);
    let config: boolean;
    let opensMap: boolean;
    let opensList: boolean;
    if (t.startsWith('- ')) {
      // `- key: value` starts a map in a YAML list; the item counts as config only under a parent holding a list.
      const key = yamlKey(t.slice(2));
      opensMap = key?.lowercase === true;
      opensList = opensMap && key?.opensMap === true;
      config = opensMap && outer[outer.length - 1]?.opensList === true;
    } else {
      const key = yamlKey(line);
      if (key) {
        config = indent === 0 ? key.lowercase : outer[outer.length - 1]?.opensMap === true;
        opensMap = key.opensMap;
        opensList = key.opensMap;
      } else {
        config = ENV_LINE.test(line);
        opensMap = false;
        opensList = false;
      }
    }
    outer.push({ indent, opensMap, opensList });
    if (
      config ||
      ['{', '}', ';', '):'].some((s) => t.endsWith(s)) ||
      CODE_STARTS.some((s) => t.startsWith(s)) ||
      (inComment && COMMENT_STAR.test(line)) ||
      isPathOrGlob(t)
    ) {
      codeLike += 1;
    }
  }
  return codeLike >= 0.3 * nonBlank.length;
}

/** A line starting with optional indentation and `key:` followed by a space, a tab or the line's end. */
function yamlKey(line: string): { lowercase: boolean; opensMap: boolean } | undefined {
  const scalars = [...line.replace(/^[ \t]+/, '')];
  const first = scalars[0];
  if (first === undefined || !/^[_a-zA-Z]$/.test(first)) return undefined;
  let k = 0;
  while (k < scalars.length && (isWordScalar(scalars[k]!) || scalars[k] === '.' || scalars[k] === '-')) k += 1;
  if (scalars[k] !== ':') return undefined;
  const after = scalars.slice(k + 1);
  if (after.length && after[0] !== ' ' && after[0] !== '\t') return undefined;
  return { lowercase: /^[_a-z]$/.test(first), opensMap: after.every((c) => c === ' ' || c === '\t') };
}

/** A single path or glob such as `build/`, `*.log` or `.DS_Store`. */
function isPathOrGlob(line: string): boolean {
  const token = line.startsWith('!') ? line.slice(1) : line;
  let hasWord = false;
  for (const c of token) {
    if (isWordScalar(c)) hasWord = true;
    else if (!'.*?/[]-'.includes(c)) return false;
  }
  return hasWord && (line.includes('/') || line.startsWith('.') || line.includes('*.') || line.includes('.*'));
}

/** `**bold**` within one line. */
function hasBold(text: string): boolean {
  for (const line of text.split('\n')) {
    const open = BOLD_OPEN.exec(line);
    if (!open) continue;
    BOLD_CLOSE.lastIndex = open.index + 2;
    if (BOLD_CLOSE.exec(line)) return true;
  }
  return false;
}

/** The GFM delimiter row, read as the possessive Swift pattern does. */
function isTableDelimiter(line: string): boolean {
  let k = 0;
  const spaces = () => {
    while (line[k] === ' ' || line[k] === '\t') k += 1;
  };
  const cell = (): boolean => {
    if (line[k] === ':') k += 1;
    if (line[k] !== '-') return false;
    while (line[k] === '-') k += 1;
    if (line[k] === ':') k += 1;
    spaces();
    return true;
  };
  spaces();
  if (line[k] === '|') k += 1;
  spaces();
  if (!cell()) return false;
  let cells = 0;
  for (;;) {
    const save = k;
    if (line[k] !== '|') break;
    k += 1;
    spaces();
    if (!cell()) {
      k = save;
      break;
    }
    cells += 1;
  }
  if (!cells) return false;
  if (line[k] === '|') k += 1;
  spaces();
  return k === line.length;
}

/** A GFM table: a line with a `|` followed by a delimiter row. */
function hasTable(text: string): boolean {
  const lines = text.split('\n');
  return lines.some((line, k) => k > 0 && isTableDelimiter(line) && lines[k - 1]!.includes('|'));
}

/**
 * Drops bare URLs such as `https://example.com/a_b*`, whose underscores and asterisks aren't emphasis. A URL starts
 * at a letter not preceded by `(`, `<` or a word character.
 */
function removingBareURLs(text: string): string {
  let out = '';
  let copied = 0;
  let search = 0;
  const code = (k: number) => text.charCodeAt(k);
  const isAsciiLetter = (c: number) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
  const isScheme = (c: number) => isAsciiLetter(c) || (c >= 0x30 && c <= 0x39) || c === 0x2b || c === 0x2e || c === 0x2d;
  const isSpace = (c: number) => /[\t-\r \x85\xa0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]/.test(String.fromCharCode(c));
  const blocksURL = (c: number) => c === 0x28 || c === 0x3c || ((c < 0xd800 || c > 0xdfff) && isWordScalar(String.fromCharCode(c)));
  while (search < text.length) {
    const separator = text.indexOf('://', search);
    if (separator < 0) break;
    let runStart = separator;
    while (runStart > copied && isScheme(code(runStart - 1))) runStart -= 1;
    let start: number | undefined;
    for (let k = runStart; k < separator; k++) {
      if (isAsciiLetter(code(k)) && (k === 0 || !blocksURL(code(k - 1)))) {
        start = k;
        break;
      }
    }
    let end = separator + 3;
    if (start !== undefined) {
      while (end < text.length && !isSpace(code(end))) end += 1;
      if (end > separator + 3) {
        out += text.slice(copied, start);
        copied = end;
        search = end;
        continue;
      }
    }
    search = separator + 1;
  }
  return out + text.slice(copied);
}

export interface PastedMarkdown {
  /** The pasted blocks, front matter first as plain paragraphs. */
  blocks: Block[];
  /**
   * One line of body text: it joins the paragraph at the insertion point instead of starting blocks of its own.
   * `blocks` is then a single paragraph.
   */
  inline: boolean;
  /** Whether the pasted text ended in a newline: blocks then leave the caret on a line of its own. */
  endsWithNewline: boolean;
}

/**
 * Pasted plain text as blocks, when it is clearly Markdown source (`looksLikeMarkdown`) and has no line over
 * `PASTE_MAX_LINE_LENGTH`; undefined means paste it as plain text. As native paste does: a leading YAML block
 * stays verbatim as plain paragraphs, blank lines only separate blocks, images and attachments keep their text
 * (a web image becomes a link) since nothing is fetched, and inline-only Markdown on one line joins the current
 * line. Native builds the blocks with the editor's own Markdown reader; this uses `parseMarkdown`.
 */
export function markdownForPaste(source: string, opts: MarkdownReadOptions = {}): PastedMarkdown | undefined {
  if (!looksLikeMarkdown(source)) return undefined;
  const lines = pasteLines(source);
  const frontMatter = frontMatterLineCount(lines);
  const markdown = lines.slice(frontMatter).join('\n');
  if (hasLineLongerThan(markdown, PASTE_MAX_LINE_LENGTH)) return undefined;
  const pasted = (content: Inl[]): Inl[] =>
    mergingTextRuns(
      content.flatMap((n): Inl[] => {
        if (n.type === 'image') {
          const web = /^https?:\/\//i.test(n.attrs.sha) && linkPolicyAllows(n.attrs.sha);
          return web ? [text(n.attrs.name || n.attrs.sha, [link(n.attrs.sha)])] : [text(n.attrs.name)];
        }
        return n.type === 'attachment' ? [text(n.attrs.name)] : [n];
      }),
    );
  const body = parseBody(markdown, opts)
    .map((b) => mapContent(b, pasted))
    .filter((b) => !(b.type === 'paragraph' && !b.content && !b.attrs));
  if (!body.length) return undefined;
  const verbatim = lines.slice(0, frontMatter).map((l) => paragraph(undefined, undefined, l ? [text(l)] : []));
  const blocks = [...verbatim, ...body] as Block[];
  const single = blocks.length === 1 ? blocks[0]! : undefined;
  const isNewline = (c: string) => /[\n\r\v\f\x85\u2028\u2029]/.test(c);
  const inline =
    !/[\n\r\v\f\x85\u2028\u2029]/.test(trimBy(source, isNewline)) &&
    single?.type === 'paragraph' &&
    !single.attrs &&
    !(single.content ?? []).some((n) => n.type === 'hardBreak');
  return { blocks, inline: !!inline, endsWithNewline: isNewline(source.slice(-1)) };
}

/** The blocks of Markdown with no front matter of its own (a paste's YAML block was already split off). */
function parseBody(markdown: string, opts: MarkdownReadOptions): Node[] {
  const parser = new BlockParser(opts.resolveNoteLink ?? (() => undefined));
  return parser.parseBlocks(splitLines(markdown).map((l) => ({ text: l.content })));
}
