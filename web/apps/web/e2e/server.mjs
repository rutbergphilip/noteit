// Starts the production build on a fresh, empty data directory (NOTEIT_DATA_DIR), for one Playwright project or
// the interop script. It refuses any other directory, so a typo can't wipe real data.
import { existsSync } from 'node:fs';
import { mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const dir = process.env.NOTEIT_DATA_DIR;
if (!dir || !/noteit-(e2e|interop)-/.test(dir)) throw new Error(`refusing to wipe NOTEIT_DATA_DIR=${dir}`);
await rm(dir, { recursive: true, force: true });
await mkdir(dir, { recursive: true });
const entry = fileURLToPath(new URL('../.output/server/index.mjs', import.meta.url));
if (!existsSync(entry)) throw new Error('No production build: run `pnpm --filter @noteit/web build` first.');
await import(entry);
