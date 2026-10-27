#!/usr/bin/env node
// Checks that a NoteIt web server (or an unpacked noteit-web-static tarball) serves exactly the client of a
// signed release. Detection only: a server that targets you can still serve honest files to this script.
//
//   node scripts/verify-web-client.mjs <https://notes.example.com | directory> (--expect <X.Y.Z> | --latest)
//        [--allow-older] [--manifest web-client-X.Y.Z.json --sig web-client-X.Y.Z.json.minisig] [--pubkey key.pub]
//
// The expected version always comes from you (--expect) or GitHub (--latest), never from the server. The server's
// claimed version (/api/_actions/server-info) is only compared: a different one fails as a possible rollback
// unless --allow-older, which then verifies the files against the claimed (older) release instead.
// Exit codes: 0 verified, 1 not verified, 2 usage.
import { readFile, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { compareVersions, hashTree, parseManifest, sha256, verifyMinisign } from './lib/web-client.mjs';

const REPO = 'rutbergphilip/noteit';
const GITHUB_API = process.env.NOTEIT_GITHUB_API ?? 'https://api.github.com';
const RELEASES = process.env.NOTEIT_RELEASE_BASE ?? `https://github.com/${REPO}/releases/download`;
const USAGE =
  'usage: verify-web-client.mjs <url|directory> (--expect <X.Y.Z> | --latest) [--allow-older] [--manifest file --sig file] [--pubkey file]';

class Failure extends Error {}

async function main() {
  let parsed;
  try {
    parsed = parseArgs({
      allowPositionals: true,
      options: {
        expect: { type: 'string' },
        latest: { type: 'boolean', default: false },
        'allow-older': { type: 'boolean', default: false },
        manifest: { type: 'string' },
        sig: { type: 'string' },
        pubkey: { type: 'string', default: join(dirname(fileURLToPath(import.meta.url)), 'noteit-release.pub') },
      },
    });
  } catch (e) {
    return usage(e.message);
  }
  const { values: o, positionals } = parsed;
  if (positionals.length !== 1) return usage();
  if (!o.expect === !o.latest) return usage('pass exactly one of --expect <version> and --latest');
  if (!o.manifest !== !o.sig) return usage('--manifest and --sig go together');

  const target = positionals[0];
  const pubkey = await readFile(o.pubkey, 'utf8').catch(() => {
    throw new Failure(`no public key at ${o.pubkey}`);
  });

  const expected = o.expect ?? (await latestRelease());
  console.log(`expected version: ${expected}${o.latest ? ' (latest GitHub release)' : ''}`);

  const manifest = await signedManifest(expected, pubkey, o.manifest, o.sig);
  const isDir = !/^https?:\/\//.test(target);
  let check = manifest;

  if (!isDir) {
    const claimed = await claimedVersion(target);
    if (claimed !== expected) {
      if (!o['allow-older'] || !claimed || compareVersions(claimed, expected) > 0) {
        throw new Failure(`version mismatch (possible rollback): the server claims ${claimed ?? 'nothing'}, expected ${expected}`);
      }
      console.warn(`warning: the server runs the older release ${claimed}; verifying it against that release's manifest`);
      check = await signedManifest(claimed, pubkey);
    }
  }

  const problems = isDir ? await compareDir(target, check) : await compareServer(target, check);
  if (problems.length) {
    throw new Failure(`the client does not match release ${check.version}:\n${problems.map((p) => `  ${p}`).join('\n')}`);
  }
  console.log(`OK: ${Object.keys(check.files).length} files match the signed manifest of release ${check.version}`);
  return 0;
}

function usage(message) {
  if (message) console.error(message);
  console.error(USAGE);
  return 2;
}

async function get(url, what) {
  let res;
  try {
    res = await fetch(url, { redirect: 'follow', cache: 'no-store' });
  } catch (e) {
    throw new Failure(`${what}: ${e.message} (${url})`);
  }
  if (!res.ok) throw new Failure(`${what}: HTTP ${res.status} (${url})`);
  return res;
}

async function latestRelease() {
  // GitHub's "latest" release is never a draft or a pre-release.
  const res = await get(`${GITHUB_API}/repos/${REPO}/releases/latest`, 'latest release');
  const { tag_name: tag, prerelease } = await res.json();
  if (typeof tag !== 'string' || prerelease) throw new Failure('GitHub returned no usable latest release');
  return tag.replace(/^v/, '');
}

async function signedManifest(version, pubkey, manifestFile, sigFile) {
  let bytes;
  let sig;
  if (manifestFile) {
    bytes = await readFile(manifestFile);
    sig = await readFile(sigFile, 'utf8');
  } else {
    const url = `${RELEASES}/v${version}/web-client-${version}.json`;
    bytes = Buffer.from(await (await get(url, 'signed manifest')).arrayBuffer());
    sig = await (await get(`${url}.minisig`, 'manifest signature')).text();
  }
  try {
    verifyMinisign(bytes, sig, pubkey);
  } catch (e) {
    throw new Failure(`bad manifest signature: ${e.message}`);
  }
  const manifest = parseManifest(bytes.toString('utf8'));
  // The signed content names its version; a renamed or swapped file can't pass for another release.
  if (manifest.version !== version) throw new Failure(`the signed manifest is for ${manifest.version}, expected ${version}`);
  console.log(`signature OK: manifest of ${manifest.version} (commit ${manifest.commit})`);
  return manifest;
}

async function claimedVersion(base) {
  const res = await get(new URL('/api/_actions/server-info', base), 'server info');
  const body = await res.json().catch(() => ({}));
  return typeof body?.data?.version === 'string' ? body.data.version : undefined;
}

async function compareServer(base, manifest) {
  const problems = [];
  for (const [path, hash] of Object.entries(manifest.files)) {
    // The server renders the SPA page at `/`; 200.html is only the static-host fallback copy of it.
    if (path === '/200.html') continue;
    const url = new URL(path === '/index.html' ? '/' : path, base);
    let res;
    try {
      res = await fetch(url, { cache: 'no-store', redirect: 'error' });
    } catch (e) {
      problems.push(`unreachable ${path}: ${e.message}`);
      continue;
    }
    if (!res.ok) {
      problems.push(`missing ${path} (HTTP ${res.status})`);
      continue;
    }
    const got = sha256(Buffer.from(await res.arrayBuffer()));
    if (got !== hash) problems.push(`mismatched ${path}`);
    if (path === '/index.html' && manifest.csp && res.headers.get('content-security-policy') !== manifest.csp) {
      problems.push('mismatched Content-Security-Policy header on /');
    }
  }
  return problems;
}

async function compareDir(dir, manifest) {
  if (!(await stat(dir).catch(() => null))?.isDirectory()) throw new Failure(`${dir} is not a directory or URL`);
  const actual = await hashTree(dir);
  const problems = [];
  for (const [path, hash] of Object.entries(manifest.files)) {
    if (!(path in actual)) problems.push(`missing ${path}`);
    else if (actual[path] !== hash) problems.push(`mismatched ${path}`);
  }
  for (const path of Object.keys(actual)) if (!(path in manifest.files)) problems.push(`extra ${path}`);
  return problems;
}

main().then(
  (code) => process.exit(code),
  (e) => {
    console.error(e instanceof Failure ? `FAILED: ${e.message}` : e);
    process.exit(1);
  },
);
