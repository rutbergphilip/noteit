/**
 * Tag names from other apps written in NoteIt's tag grammar (native `ImportTags`). One value per import run keeps
 * names that are different in the other app different here.
 */
import { deriveTags } from './derive.js';
import type { NoteItDoc } from './schema.js';
import { isValidTagName, MAX_TAG_DEPTH, normalizedTag } from './tokens.js';

/** Symbols that carry meaning in tag names (`C++`, `C#`, `R&D`), spelled out. */
const SYMBOL_WORDS: Record<string, string> = { '+': 'plus', '#': 'sharp', '&': 'and', '@': 'at' };
const KEPT = /^[\p{L}\p{M}\p{N}_]$/u;
const LETTER = /^\p{L}$/u;
const MARK = /^\p{M}$/u;

function segment(raw: string): string | undefined {
  let out = '';
  let dash = false;
  for (const ch of raw) {
    if (KEPT.test(ch)) {
      if (dash && out) out += '-';
      dash = false;
      out += ch;
    } else if (SYMBOL_WORDS[ch]) {
      if (out) out += '-';
      out += SYMBOL_WORDS[ch];
      dash = true;
    } else {
      dash = true;
    }
  }
  const first = [...out][0];
  if (first === undefined) return undefined;
  const startsWell = first === '_' || (LETTER.test(first) && !MARK.test(first));
  return startsWell ? out : `_${out}`;
}

/**
 * `name` as a NoteIt tag without `#`: `+ # & @` are spelled out, spaces and other punctuation become `-`, a segment
 * that doesn't start with a letter gets a leading `_`, and levels past the fifth join the fifth. Undefined when
 * nothing usable is left.
 */
export function sanitizedImportTag(name: string): string | undefined {
  let s = name.trim();
  while (s.startsWith('#') && /[\p{L}\p{N}]/u.test(s.slice(1))) s = s.slice(1);
  let segments = s
    .split('/')
    .filter(Boolean)
    .map(segment)
    .filter((x): x is string => x !== undefined);
  if (!segments.length) return undefined;
  if (segments.length > MAX_TAG_DEPTH) segments = [...segments.slice(0, MAX_TAG_DEPTH - 1), segments.slice(MAX_TAG_DEPTH - 1).join('-')];
  const tag = normalizedTag(segments.join('/'));
  return isValidTagName(tag) ? tag : undefined;
}

export class ImportTags {
  /** Folded original name → tag. */
  private assigned = new Map<string, string>();
  /** Tag → the folded original name it was given to. */
  private owners = new Map<string, string>();
  /** Folded original names nothing usable was left of. */
  readonly dropped = new Set<string>();

  /** The tag for `name` in this run: the same name always gets the same tag; a taken tag gets `-2`, `-3`… */
  tag(name: string): string | undefined {
    const key = name.trim().toLowerCase();
    const known = this.assigned.get(key);
    if (known) return known;
    const base = sanitizedImportTag(name);
    if (!base) {
      this.dropped.add(key);
      return undefined;
    }
    let tag = base;
    for (let n = 2; this.owners.has(tag) && this.owners.get(tag) !== key; n++) tag = `${base}-${n}`;
    if (!isValidTagName(tag)) {
      this.dropped.add(key);
      return undefined;
    }
    this.assigned.set(key, tag);
    this.owners.set(tag, key);
    return tag;
  }

  /** A line of hashtags for `names`, leaving out tags `doc` already has; undefined when none are left. */
  line(names: string[], doc: NoteItDoc): string | undefined {
    const seen = new Set(deriveTags(doc));
    const tags: string[] = [];
    for (const name of names) {
      const t = this.tag(name);
      if (t && !seen.has(t)) {
        seen.add(t);
        tags.push(t);
      }
    }
    return tags.length ? tags.map((t) => `#${t}`).join(' ') : undefined;
  }
}
