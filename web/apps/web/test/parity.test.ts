import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// docs/feature-parity.md must account for every command in the native palette and in the web's registry, so a
// feature can't land on one side without a row saying where the other side stands (CLAUDE.md, CONTRIBUTING.md).
const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const read = (path: string) => readFileSync(resolve(repo, path), 'utf8');
const doc = read('docs/feature-parity.md');
const ids = (source: string, pattern: RegExp) => [...new Set([...source.matchAll(pattern)].map((m) => m[1]!))];

describe('docs/feature-parity.md', () => {
  it('has a row for every native palette command', () => {
    const native = ids(read('Sources/NoteIt/Palette/PaletteCommandRegistry.swift'), /command\("([A-Za-z]+)"/g);
    expect(native.length).toBeGreaterThan(25);
    expect(native.filter((id) => !doc.includes(`\`${id}\``))).toEqual([]);
  });

  it('has a row for every web command', () => {
    const web = ids(read('web/apps/web/app/utils/commands.ts'), /\bid: '([A-Za-z]+)'/g);
    expect(web.length).toBeGreaterThan(15);
    expect(web.filter((id) => !doc.includes(`\`${id}\``))).toEqual([]);
  });
});
