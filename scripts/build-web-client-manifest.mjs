#!/usr/bin/env node
// Assembles the static web client of a release and its manifest, from one `pnpm --filter @noteit/web build`:
//
//   node scripts/build-web-client-manifest.mjs --version 0.7.0 --commit <sha> [--output web/apps/web/.output] [--out dist/web]
//
// It starts the built server once (temporary data directory, loopback), takes the page it serves at `/` and its
// Content-Security-Policy, and writes
//   <out>/noteit-web-static-<version>/   .output/public plus that page as index.html and 200.html
//   <out>/web-client-<version>.json      {version, commit, csp, files: {"/path": sha256}}
// The release workflow packs the directory into noteit-web-static-<version>.tar.gz, signs the manifest with
// minisign, and checks the image's copy of the client against it. verify-web-client.mjs checks a running server
// or an unpacked tarball against the signed manifest.
import { spawn } from 'node:child_process';
import { cp, mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { hashTree, manifestJSON } from './lib/web-client.mjs';

const { values: args } = parseArgs({
  options: {
    version: { type: 'string' },
    commit: { type: 'string' },
    output: { type: 'string', default: 'web/apps/web/.output' },
    out: { type: 'string', default: 'dist/web' },
  },
});
if (!args.version || !args.commit) {
  console.error('usage: build-web-client-manifest.mjs --version <X.Y.Z> --commit <sha> [--output <.output>] [--out <dir>]');
  process.exit(2);
}

const output = resolve(args.output);
const out = resolve(args.out);
const staticDir = join(out, `noteit-web-static-${args.version}`);

const port = await new Promise((done, fail) => {
  const s = createServer().listen(0, '127.0.0.1', () => {
    const { port } = s.address();
    s.close(() => done(port));
  });
  s.on('error', fail);
});
const dataDir = await mkdtemp(join(tmpdir(), 'noteit-manifest-'));
const server = spawn(process.execPath, [join(output, 'server/index.mjs')], {
  env: { ...process.env, NODE_ENV: 'production', NOTEIT_DATA_DIR: dataDir, HOST: '127.0.0.1', PORT: String(port), NOTEIT_SETUP_TOKEN: 'manifest-build' },
  stdio: ['ignore', 'ignore', 'inherit'],
});
let page;
let csp;
try {
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; ; i++) {
    try {
      if ((await fetch(`${base}/api/health/live`)).ok) break;
    } catch {}
    if (i > 100 || server.exitCode !== null) throw new Error('the built server did not start');
    await new Promise((r) => setTimeout(r, 100));
  }
  const res = await fetch(`${base}/`);
  if (!res.ok) throw new Error(`GET / answered ${res.status}`);
  page = Buffer.from(await res.arrayBuffer());
  csp = res.headers.get('content-security-policy');
  if (!csp) throw new Error('GET / sent no Content-Security-Policy');
  // The page must not depend on the request (no per-request nonce), or no manifest can describe it.
  const again = Buffer.from(await (await fetch(`${base}/`)).arrayBuffer());
  if (!again.equals(page)) throw new Error('GET / differs between requests; the client page is not reproducible');
} finally {
  server.kill();
  await rm(dataDir, { recursive: true, force: true });
}

await rm(staticDir, { recursive: true, force: true });
await mkdir(out, { recursive: true });
await cp(join(output, 'public'), staticDir, { recursive: true });
// The SPA page: index.html for `/`, 200.html as the fallback for client routes on static hosts.
await writeFile(join(staticDir, 'index.html'), page);
await writeFile(join(staticDir, '200.html'), page);

const manifest = { version: args.version, commit: args.commit, csp, files: await hashTree(staticDir) };
const manifestPath = join(out, `web-client-${args.version}.json`);
await writeFile(manifestPath, manifestJSON(manifest));
console.log(`${Object.keys(manifest.files).length} files → ${manifestPath}`);
console.log(`static client → ${staticDir}`);
