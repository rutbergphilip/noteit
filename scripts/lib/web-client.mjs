// Shared by build-web-client-manifest.mjs and verify-web-client.mjs: the signed web-client manifest
// ({version, commit, csp, files: {"/path": "<sha256 hex>"}}) and minisign signature checks.
// Node built-ins only, so the verifier runs from a plain checkout without installing anything.
import { createHash, createPublicKey, verify } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { join, relative, sep } from 'node:path';

export const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

/** Operators edit it (spec §6.4), so it isn't hashed; `checkClientConfig` checks it against its schema instead. */
export const CLIENT_CONFIG = '/noteit-client.json';

/** Problems with a `noteit-client.json`: `{"mode": "server" | "direct", "sourceUrl"?: "https://…"}` (direct only). */
export function checkClientConfig(text) {
  let c;
  try {
    c = JSON.parse(text);
  } catch {
    return ['noteit-client.json is not JSON'];
  }
  if (!c || typeof c !== 'object' || Array.isArray(c)) return ['noteit-client.json is not an object'];
  const problems = [];
  for (const k of Object.keys(c)) if (k !== 'mode' && k !== 'sourceUrl') problems.push(`noteit-client.json has an unknown key ${k}`);
  if (c.mode !== 'server' && c.mode !== 'direct') problems.push('noteit-client.json mode must be "server" or "direct"');
  if ('sourceUrl' in c && (c.mode !== 'direct' || typeof c.sourceUrl !== 'string' || !/^https:\/\/\S+$/.test(c.sourceUrl))) problems.push('noteit-client.json sourceUrl must be an https:// URL, in direct mode');
  return problems;
}

/** Every file under `dir` except noteit-client.json, keyed by its URL path ("/_nuxt/x.js"), with its SHA-256. */
export async function hashTree(dir) {
  const files = {};
  async function walk(d) {
    for (const entry of await readdir(d, { withFileTypes: true })) {
      const path = join(d, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile()) {
        const key = '/' + relative(dir, path).split(sep).join('/');
        if (key !== CLIENT_CONFIG) files[key] = sha256(await readFile(path));
      }
      else throw new Error(`unexpected entry in the client bundle: ${path}`);
    }
  }
  await walk(dir);
  return Object.fromEntries(Object.entries(files).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

/** The manifest's canonical bytes: sorted file keys, two-space JSON, trailing newline. */
export function manifestJSON({ version, commit, csp, files }) {
  return JSON.stringify({ version, commit, csp, files }, null, 2) + '\n';
}

export function parseManifest(text) {
  const m = JSON.parse(text);
  if (typeof m?.version !== 'string' || typeof m?.commit !== 'string' || typeof m?.files !== 'object' || m.files === null) {
    throw new Error('not a NoteIt web-client manifest');
  }
  for (const [path, hash] of Object.entries(m.files)) {
    if (!path.startsWith('/') || path.includes('..') || !/^[0-9a-f]{64}$/.test(hash)) throw new Error(`bad manifest entry ${path}`);
  }
  return m;
}

// minisign (https://jedisct1.github.io/minisign/): Ed25519 over the BLAKE2b-512 hash of the file ("ED"), plus a
// global signature over that signature and the trusted comment. Legacy non-hashed ("Ed") signatures are refused.
const SPKI_ED25519_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function base64Line(text, what) {
  const lines = text.split(/\r?\n/);
  if (!lines[0]?.startsWith('untrusted comment:')) throw new Error(`${what}: missing untrusted comment line`);
  return { bytes: Buffer.from(lines[1] ?? '', 'base64'), lines };
}

export function parsePublicKey(text) {
  const { bytes } = base64Line(text.trim(), 'public key');
  if (bytes.length !== 42 || bytes.subarray(0, 2).toString() !== 'Ed') throw new Error('public key: not a minisign Ed25519 key');
  return {
    keyId: bytes.subarray(2, 10),
    key: createPublicKey({ key: Buffer.concat([SPKI_ED25519_PREFIX, bytes.subarray(10)]), format: 'der', type: 'spki' }),
  };
}

/** Verifies a .minisig for `data`; returns the trusted comment. Throws on any mismatch. */
export function verifyMinisign(data, sigText, pubText) {
  const pub = parsePublicKey(pubText);
  const { bytes, lines } = base64Line(sigText, 'signature');
  if (bytes.length !== 74) throw new Error('signature: malformed');
  const algorithm = bytes.subarray(0, 2).toString();
  if (algorithm !== 'ED') throw new Error(`signature: unsupported algorithm ${JSON.stringify(algorithm)} (sign with a current minisign)`);
  if (!bytes.subarray(2, 10).equals(pub.keyId)) throw new Error('signature: made with a different key');
  const signature = bytes.subarray(10);
  const digest = createHash('blake2b512').update(data).digest();
  if (!verify(null, digest, pub.key, signature)) throw new Error('signature: does not match the file');
  const trusted = lines[2] ?? '';
  if (!trusted.startsWith('trusted comment: ')) throw new Error('signature: missing trusted comment');
  const comment = trusted.slice('trusted comment: '.length);
  const global = Buffer.from(lines[3] ?? '', 'base64');
  if (!verify(null, Buffer.concat([signature, Buffer.from(comment)]), pub.key, global)) throw new Error('signature: trusted comment was altered');
  return comment;
}

/** -1, 0 or 1 for two MAJOR.MINOR.PATCH[-pre] versions (pre-releases sort before their release). */
export function compareVersions(a, b) {
  const parse = (v) => {
    const [core, pre] = v.split('-', 2);
    return { nums: core.split('.').map(Number), pre };
  };
  const x = parse(a);
  const y = parse(b);
  for (let i = 0; i < 3; i++) if (x.nums[i] !== y.nums[i]) return x.nums[i] < y.nums[i] ? -1 : 1;
  if (x.pre === y.pre) return 0;
  if (x.pre === undefined) return 1;
  if (y.pre === undefined) return -1;
  return x.pre < y.pre ? -1 : 1;
}
