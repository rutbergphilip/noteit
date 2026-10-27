/**
 * Reading ZIP archives for import (a `.textpack`, a Notion export), as native `MarkdownImporter.unpack` with
 * `ZipLimits`: entries whose names would land outside the archive are refused, and the entries and bytes of one
 * import's archives are capped so a ZIP bomb is refused.
 */
import { unzipSync } from 'fflate';

export interface ZipLimits {
  maxEntries: number;
  maxBytes: number;
}

/** Native `ZipLimits.standard`. */
export const standardZipLimits = (): ZipLimits => ({ maxEntries: 200_000, maxBytes: 8 * 1024 ** 3 });

export class ZipTooLargeError extends Error {
  constructor(readonly archive: string) {
    super(`“${archive}” unpacks to more files or data than NoteIt can import at once. Unzip it and import its folders a few at a time.`);
  }
}

export class ZipUnreadableError extends Error {
  constructor(readonly archive: string) {
    super(`“${archive}” couldn't be opened. Unzip it and choose the folder instead.`);
  }
}

/** Native `isSafeZipEntry`: no absolute or home paths, no `..`. */
export function isSafeZipEntry(name: string): boolean {
  return !name.startsWith('/') && !name.startsWith('~') && !name.split('/').includes('..') && !name.includes('\\');
}

/**
 * The files in an archive by path ("/"-separated, NFC), directories, hidden `__MACOSX` folders and unsafe names
 * left out. Takes the archive's entries and bytes off `limits`; throws `ZipTooLargeError` past them and
 * `ZipUnreadableError` when the archive can't be read (encrypted, damaged or an unknown compression).
 */
export function unzipArchive(bytes: Uint8Array, name: string, limits: ZipLimits): Map<string, Uint8Array> {
  let entries = 0;
  let total = 0;
  let tooLarge = false;
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes, {
      filter: (f) => {
        entries += 1;
        total += f.originalSize;
        if (entries > limits.maxEntries || total > limits.maxBytes) tooLarge = true;
        if (tooLarge || f.name.endsWith('/')) return false;
        return isSafeZipEntry(f.name) && !f.name.split('/').includes('__MACOSX');
      },
    });
  } catch {
    if (tooLarge) throw new ZipTooLargeError(name);
    throw new ZipUnreadableError(name);
  }
  if (tooLarge) throw new ZipTooLargeError(name);
  limits.maxEntries -= entries;
  limits.maxBytes -= total;
  const out = new Map<string, Uint8Array>();
  for (const [path, data] of Object.entries(files)) {
    const key = path.normalize('NFC');
    if (!out.has(key)) out.set(key, data);
  }
  return out;
}
