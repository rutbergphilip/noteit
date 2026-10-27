/**
 * TextBundle import (`.textbundle` folders and `.textpack` zips, as Bear exports them), as native
 * `MarkdownImporter.importBundle`: `text.md` (or `.markdown`/`.txt`) plus an `assets` folder, and Bear's dates in
 * `info.json`.
 */
import { parseFrontMatterDate } from './markdown-read.js';

const TEXT_NAMES = ['text.md', 'text.markdown', 'text.txt'];
const TEXT_EXT = /\.(md|markdown|txt)$/i;

/** The bundle's text file among its file paths (relative to the bundle): `text.md`, else any Markdown or text file at its top. */
export function textBundleTextPath(paths: string[]): string | undefined {
  const top = paths.filter((p) => !p.includes('/'));
  return TEXT_NAMES.find((n) => top.includes(n)) ?? top.filter((p) => TEXT_EXT.test(p)).sort()[0];
}

/**
 * The bundle folder inside an unpacked `.textpack` ("" for the archive itself): the archive when it holds
 * `text.md`, else its `.textbundle` folder, else its only folder, looked into the same way. Undefined when none.
 */
export function textPackBundle(paths: string[]): string | undefined {
  let prefix = '';
  for (let depth = 0; depth < 8; depth++) {
    const inside = paths.filter((p) => p.startsWith(prefix)).map((p) => p.slice(prefix.length));
    if (TEXT_NAMES.some((n) => inside.includes(n))) return prefix;
    const entries = [...new Set(inside.map((p) => p.split('/')[0]!))].filter((n) => !n.startsWith('.') && n !== '__MACOSX');
    const dirs = entries.filter((n) => inside.some((p) => p.startsWith(`${n}/`)));
    const bundle = dirs.find((n) => /\.textbundle$/i.test(n));
    if (bundle) return `${prefix}${bundle}/`;
    if (entries.length !== 1 || dirs.length !== 1) return undefined;
    prefix = `${prefix}${dirs[0]}/`;
  }
  return undefined;
}

/** Bear writes `creationDate` and `modificationDate` into `info.json` under `net.shinyfrog.bear`. */
export function textBundleDates(infoJson: string | undefined): { created?: Date; modified?: Date } {
  if (!infoJson) return {};
  let json: unknown;
  try {
    json = JSON.parse(infoJson);
  } catch {
    return {};
  }
  if (!json || typeof json !== 'object') return {};
  const root = json as Record<string, unknown>;
  const bear = (root['net.shinyfrog.bear'] && typeof root['net.shinyfrog.bear'] === 'object' ? root['net.shinyfrog.bear'] : {}) as Record<string, unknown>;
  const date = (key: string) => {
    const v = typeof bear[key] === 'string' ? bear[key] : root[key];
    return typeof v === 'string' ? parseFrontMatterDate(v) : undefined;
  };
  const created = date('creationDate');
  const modified = date('modificationDate');
  return { ...(created ? { created } : {}), ...(modified ? { modified } : {}) };
}
