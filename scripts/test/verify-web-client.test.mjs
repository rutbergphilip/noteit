// node --test scripts/test/verify-web-client.test.mjs
// The verifier against local servers and directories, with a minisign key pair made for the test (never the
// release key). When the minisign CLI is installed, signatures are also cross-checked with it.
import { execFile, execFileSync, spawnSync } from 'node:child_process';
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { compareVersions, hashTree, manifestJSON, verifyMinisign } from '../lib/web-client.mjs';

const VERIFIER = join(dirname(fileURLToPath(import.meta.url)), '..', 'verify-web-client.mjs');
const CSP = "default-src 'self'";

function testKey() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const keyId = randomBytes(8);
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const pub = `untrusted comment: test key\n${Buffer.concat([Buffer.from('Ed'), keyId, raw]).toString('base64')}\n`;
  const signFile = (data, comment = 'test') => {
    const sig = sign(null, createHash('blake2b512').update(data).digest(), privateKey);
    const global = sign(null, Buffer.concat([sig, Buffer.from(comment)]), privateKey);
    return `untrusted comment: test signature\n${Buffer.concat([Buffer.from('ED'), keyId, sig]).toString('base64')}\ntrusted comment: ${comment}\n${global.toString('base64')}\n`;
  };
  return { pub, signFile };
}

const key = testKey();
let root;
let pubPath;

/** A fake client build for `version`: index.html, a script and a worker chunk. */
async function bundle(version) {
  const dir = join(root, `static-${version}`);
  await mkdir(join(dir, '_nuxt'), { recursive: true });
  const page = `<!DOCTYPE html><html><head><script type="module" src="/_nuxt/entry-${version}.js"></script></head><body></body></html>`;
  await writeFile(join(dir, 'index.html'), page);
  await writeFile(join(dir, '200.html'), page);
  await writeFile(join(dir, `_nuxt/entry-${version}.js`), `console.log(${JSON.stringify(version)})`);
  await writeFile(join(dir, '_nuxt/worker.js'), 'self.onmessage = () => {}');
  await writeFile(join(dir, 'noteit-client.json'), '{"mode": "direct"}\n');
  return dir;
}

/** Writes and signs web-client-<name>.json for `dir`, whose signed version is `version`. */
async function release(version, dir, name = version) {
  const releaseDir = join(root, 'releases', `v${name}`);
  await mkdir(releaseDir, { recursive: true });
  const json = manifestJSON({ version, commit: 'abc1234', csp: CSP, files: await hashTree(dir) });
  const path = join(releaseDir, `web-client-${name}.json`);
  await writeFile(path, json);
  await writeFile(`${path}.minisig`, key.signFile(Buffer.from(json)));
  return path;
}

/** Serves `dir` like the NoteIt server (`/` is the SPA page) and claims `claim` in server-info. */
function serve(handler) {
  return new Promise((done) => {
    const server = createServer(handler).listen(0, '127.0.0.1', () => done({ server, url: `http://127.0.0.1:${server.address().port}` }));
  });
}
const servers = [];
async function noteitServer(dir, claim, { csp = CSP } = {}) {
  const s = await serve(async (req, res) => {
    if (req.url === '/api/_actions/server-info') {
      res.setHeader('content-type', 'application/json');
      return res.end(JSON.stringify({ data: { version: claim } }));
    }
    const path = req.url === '/' ? '/index.html' : req.url;
    try {
      const body = await readFile(join(dir, path));
      if (req.url === '/') res.setHeader('content-security-policy', csp);
      res.end(body);
    } catch {
      res.statusCode = 404;
      res.end();
    }
  });
  servers.push(s.server);
  return s.url;
}

let releases;
let githubApi;
let latestTag = 'v1.1.0';
/** Runs the verifier asynchronously (the test's own servers must keep answering). */
function run(args) {
  return new Promise((done) => {
    execFile(
      process.execPath,
      [VERIFIER, ...args, '--pubkey', pubPath],
      { env: { ...process.env, NOTEIT_RELEASE_BASE: releases, NOTEIT_GITHUB_API: githubApi } },
      (error, stdout, stderr) => done({ code: error ? error.code : 0, out: stdout + stderr }),
    );
  });
}

before(async () => {
  root = await mkdtemp(join(tmpdir(), 'verify-web-client-'));
  pubPath = join(root, 'test.pub');
  await writeFile(pubPath, key.pub);
  await release('1.0.0', await bundle('1.0.0'));
  await release('1.1.0', await bundle('1.1.0'));
  const rel = await serve(async (req, res) => {
    try {
      res.end(await readFile(join(root, 'releases', req.url)));
    } catch {
      res.statusCode = 404;
      res.end();
    }
  });
  servers.push(rel.server);
  releases = rel.url;
  const api = await serve((req, res) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/repos/rutbergphilip/noteit/releases/latest') return res.end(JSON.stringify({ tag_name: latestTag, prerelease: false }));
    res.statusCode = 404;
    res.end('{}');
  });
  servers.push(api.server);
  githubApi = api.url;
});
after(() => servers.forEach((s) => s.close()));

describe('verify-web-client', () => {
  it('passes against a server running the expected release', async () => {
    const url = await noteitServer(join(root, 'static-1.1.0'), '1.1.0');
    const r = await run([url, '--expect', '1.1.0']);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /OK: 4 files match/);
  });

  it('fails when one byte of an asset changed', async () => {
    const dir = join(root, 'tampered');
    await cp(join(root, 'static-1.1.0'), dir, { recursive: true });
    const js = join(dir, '_nuxt/worker.js');
    const bytes = await readFile(js);
    bytes[0] ^= 1;
    await writeFile(js, bytes);
    const r = await run([await noteitServer(dir, '1.1.0'), '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /mismatched \/_nuxt\/worker\.js/);
  });

  it('fails when the page gains a script', async () => {
    const dir = join(root, 'injected');
    await cp(join(root, 'static-1.1.0'), dir, { recursive: true });
    const page = await readFile(join(dir, 'index.html'), 'utf8');
    await writeFile(join(dir, 'index.html'), page.replace('</head>', '<script src="/evil.js"></script></head>'));
    const r = await run([await noteitServer(dir, '1.1.0'), '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /mismatched \/index\.html/);
  });

  it('fails when the CSP header differs from the signed one', async () => {
    const url = await noteitServer(join(root, 'static-1.1.0'), '1.1.0', { csp: "default-src *; script-src 'unsafe-inline'" });
    const r = await run([url, '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /Content-Security-Policy/);
  });

  it('fails on a bad signature', async () => {
    const manifest = join(root, 'releases/v1.1.0/web-client-1.1.0.json');
    const forged = join(root, 'forged.json');
    await writeFile(forged, (await readFile(manifest, 'utf8')).replace('abc1234', 'fff0000'));
    const url = await noteitServer(join(root, 'static-1.1.0'), '1.1.0');
    const r = await run([url, '--expect', '1.1.0', '--manifest', forged, '--sig', `${manifest}.minisig`]);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /bad manifest signature/);
  });

  it('flags a rollback, and verifies the older release with --allow-older', async () => {
    const url = await noteitServer(join(root, 'static-1.0.0'), '1.0.0');
    const r = await run([url, '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /version mismatch \(possible rollback\)/);
    const older = await run([url, '--expect', '1.1.0', '--allow-older']);
    assert.equal(older.code, 0, older.out);
    assert.match(older.out, /warning: the server runs the older release 1\.0\.0/);
  });

  it('fails when the server serves old files but claims the expected version', async () => {
    const r = await run([await noteitServer(join(root, 'static-1.0.0'), '1.1.0'), '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /mismatched \/index\.html/);
  });

  it('refuses a renamed manifest whose signed version is another release', async () => {
    await release('1.0.0', join(root, 'static-1.0.0'), '1.2.0');
    const r = await run([await noteitServer(join(root, 'static-1.0.0'), '1.2.0'), '--expect', '1.2.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /signed manifest is for 1\.0\.0, expected 1\.2\.0/);
  });

  it('needs --expect or --latest', async () => {
    const r = await run([`http://127.0.0.1:1`]);
    assert.equal(r.code, 2, r.out);
    assert.match(r.out, /usage:/);
  });

  it('resolves --latest through the GitHub API', async () => {
    latestTag = 'v1.0.0';
    const r = await run([await noteitServer(join(root, 'static-1.0.0'), '1.0.0'), '--latest']);
    latestTag = 'v1.1.0';
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /expected version: 1\.0\.0 \(latest GitHub release\)/);
  });

  it('checks an unpacked static tarball, including extra files', async () => {
    const ok = await run([join(root, 'static-1.1.0'), '--expect', '1.1.0']);
    assert.equal(ok.code, 0, ok.out);
    const dir = join(root, 'extra');
    await cp(join(root, 'static-1.1.0'), dir, { recursive: true });
    await writeFile(join(dir, '_nuxt/extra.js'), '');
    const r = await run([dir, '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /extra \/_nuxt\/extra\.js/);
  });

  it("doesn't hash noteit-client.json, but checks it against its schema", async () => {
    const dir = join(root, 'configured');
    await cp(join(root, 'static-1.1.0'), dir, { recursive: true });
    await writeFile(join(dir, 'noteit-client.json'), '{"mode": "direct", "sourceUrl": "https://git.example.com/noteit"}');
    const ok = await run([dir, '--expect', '1.1.0']);
    assert.equal(ok.code, 0, ok.out);
    await writeFile(join(dir, 'noteit-client.json'), '{"mode": "direct", "endpoint": "https://evil.example"}');
    const r = await run([dir, '--expect', '1.1.0']);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /unknown key endpoint/);
  });
});

describe('minisign', () => {
  it('refuses an altered trusted comment', () => {
    const data = Buffer.from('hello');
    const sig = key.signFile(data, 'release 1.0.0').replace('release 1.0.0', 'release 9.9.9');
    assert.throws(() => verifyMinisign(data, sig, key.pub), /trusted comment was altered/);
  });

  const cli = spawnSync('minisign', ['-v']).status === 0;
  it('agrees with the minisign CLI', { skip: !cli && 'minisign is not installed' }, async () => {
    const dir = await mkdtemp(join(tmpdir(), 'minisign-'));
    const [pub, sec, file] = ['k.pub', 'k.key', 'm.json'].map((n) => join(dir, n));
    execFileSync('minisign', ['-G', '-W', '-p', pub, '-s', sec]);
    await writeFile(file, '{"version":"1.0.0"}\n');
    execFileSync('minisign', ['-S', '-s', sec, '-m', file, '-t', 'noteit web client 1.0.0']);
    assert.equal(verifyMinisign(await readFile(file), await readFile(`${file}.minisig`, 'utf8'), await readFile(pub, 'utf8')), 'noteit web client 1.0.0');
    // And the CLI accepts what the test key signs.
    await writeFile(join(dir, 't.pub'), key.pub);
    await writeFile(`${file}.minisig`, key.signFile(await readFile(file)));
    execFileSync('minisign', ['-V', '-p', join(dir, 't.pub'), '-m', file], { stdio: 'pipe' });
  });

  it('orders versions', () => {
    assert.equal(compareVersions('1.0.0', '1.1.0'), -1);
    assert.equal(compareVersions('1.10.0', '1.9.0'), 1);
    assert.equal(compareVersions('1.0.0-beta.1', '1.0.0'), -1);
    assert.equal(compareVersions('2.0.0', '2.0.0'), 0);
  });
});
