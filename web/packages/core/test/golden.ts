import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../../../fixtures/golden');

export function golden<T = Record<string, unknown>>(name: string): { cases: T[]; [k: string]: unknown } {
  return JSON.parse(readFileSync(resolve(root, name), 'utf8')) as { cases: T[] };
}
