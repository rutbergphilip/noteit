import { b64decode, b64encode, randomBytes, utf8 } from './bytes.js';
import {
  AesGcmCipher,
  DEFAULT_ITERATIONS,
  deriveKey,
  IdentityCipher,
  iterationsInRange,
  KEY_CHECK_CONTEXT,
  KEY_CHECK_PLAINTEXT,
  legacyKeyID,
  opensKeyCheck,
  type SyncCipher,
  unwrapKeyring,
} from './crypto.js';
import { toDouble2001 } from './dates.js';
import { StorageError, SyncError } from './errors.js';
import { checkOpenable, decodeManifest, encodeJson, type Manifest, type StoreFeature, SUPPORTED_FEATURES } from './formats.js';
import { isValidKey, keys, LEGACY_ROOT, ROOT } from './layout.js';
import type { StorageBackend } from './storage/backend.js';

export interface StoreSession {
  manifest: Manifest;
  manifestETag: string;
  cipher: SyncCipher;
  keyID?: string;
  features: ReadonlySet<StoreFeature>;
  supported: ReadonlySet<StoreFeature>;
}

export interface ConnectResult {
  session: StoreSession;
  created: boolean;
}

/** The key a manifest's records are sealed with: the keyring's, else the legacy block's, else none. */
export async function manifestKeyID(m: Manifest): Promise<string | undefined> {
  if (m.keyring) return m.keyring.keyID;
  if (m.encryption) return legacyKeyID(m.encryption);
  if (m.features?.includes('keyring')) throw new SyncError('invalidManifest', 'keyring feature without a keyring or an encryption block');
  return undefined;
}

export interface OpenOptions {
  passphrase?: string;
  /** Joining a plaintext store is allowed (with a warning in the UI); creating one never is. */
  allowPlaintext?: boolean;
  supported?: ReadonlySet<StoreFeature>;
}

/** Opens a manifest with a passphrase (= Swift openSession for a library store). */
export async function openSession(manifest: Manifest, etag: string, opts: OpenOptions): Promise<StoreSession> {
  const supported = opts.supported ?? SUPPORTED_FEATURES;
  const features = checkOpenable(manifest, supported);
  const session = (cipher: SyncCipher, keyID: string | undefined): StoreSession => ({
    manifest,
    manifestETag: etag,
    cipher,
    ...(keyID !== undefined ? { keyID } : {}),
    features,
    supported,
  });
  if (manifest.keyring) {
    if (!features.has('keyring')) throw new SyncError('invalidManifest', 'keyring without the keyring feature');
    if (!opts.passphrase) throw new SyncError('passphraseRequired');
    const key = await unwrapKeyring(opts.passphrase, manifest.keyring);
    return session(new AesGcmCipher(key), manifest.keyring.keyID);
  }
  if (features.has('keyring') && !manifest.encryption) {
    throw new SyncError('invalidManifest', 'keyring feature without a keyring or an encryption block');
  }
  const encryption = manifest.encryption;
  if (!encryption) {
    if (!opts.allowPlaintext) throw new SyncError('invalidManifest', 'store is not encrypted');
    return session(new IdentityCipher(), undefined);
  }
  if (!iterationsInRange(encryption.iterations)) throw new SyncError('invalidManifest', `iterations ${encryption.iterations} out of range`);
  let salt: Uint8Array;
  let keyCheck: Uint8Array;
  try {
    salt = b64decode(encryption.salt);
    keyCheck = b64decode(encryption.keyCheck);
  } catch {
    throw new SyncError('invalidManifest', 'bad base64');
  }
  if (salt.length !== 16) throw new SyncError('invalidManifest', `salt is ${salt.length} bytes, expected 16`);
  if (keyCheck.length === 0) throw new SyncError('invalidManifest', 'missing key check');
  if (!opts.passphrase) throw new SyncError('passphraseRequired');
  const cipher = new AesGcmCipher(await deriveKey(opts.passphrase, salt, encryption.iterations));
  if (!(await opensKeyCheck(cipher, keyCheck))) throw new SyncError('wrongPassphrase');
  return session(cipher, await legacyKeyID(encryption));
}

async function readManifest(backend: StorageBackend): Promise<{ manifest: Manifest; etag: string } | undefined> {
  try {
    const { data, etag } = await backend.get(keys.manifest);
    return { manifest: decodeManifest(data), etag };
  } catch (e) {
    if (e instanceof StorageError && e.kind === 'notFound') return undefined;
    throw e;
  }
}

/** RemoteMigration: a store found only under `inkwell/v1/` is copied byte for byte to `noteit/v1/`, manifest last. */
export async function migrateLegacyStoreIfNeeded(backend: StorageBackend): Promise<boolean> {
  const current = await backend.list(ROOT);
  if (current.some((o) => o.key === keys.manifest)) return false;
  const legacy = await backend.list(LEGACY_ROOT);
  const legacyManifest = legacy.find((o) => o.key === `${LEGACY_ROOT}manifest.json`);
  if (!legacyManifest) return false;
  for (const object of legacy) {
    if (object === legacyManifest) continue;
    const target = ROOT + object.key.slice(LEGACY_ROOT.length);
    // Anything that wouldn't be a valid key in the new root (stray files, odd names, traversal) is not copied.
    if (!isValidKey(target)) continue;
    const { data } = await backend.get(object.key);
    await backend.put(target, data, {});
  }
  const { data } = await backend.get(legacyManifest.key);
  try {
    await backend.put(keys.manifest, data, { ifNoneMatch: true });
  } catch (e) {
    if (!(e instanceof StorageError && e.kind === 'preconditionFailed')) throw e;
  }
  return true;
}

/**
 * Opens or creates the store. New stores get formatVersion 2, features ['noteit-doc'] and a v1-style encryption
 * block. A store without `noteit-doc` throws SyncError('legacyStore') after the passphrase checked out, with no write.
 */
export async function connect(
  backend: StorageBackend,
  opts: { passphrase?: string; createIfMissing: boolean; allowPlaintext?: boolean; now?: () => Date },
): Promise<ConnectResult> {
  await migrateLegacyStoreIfNeeded(backend);
  const finish = (session: StoreSession, created: boolean): ConnectResult => {
    if (!session.features.has('noteit-doc')) throw new SyncError('legacyStore');
    return { session, created };
  };
  const existing = await readManifest(backend);
  if (existing) return finish(await openSession(existing.manifest, existing.etag, opts), false);
  if (!opts.createIfMissing) throw new SyncError('storeMissing');
  if (!opts.passphrase) throw new SyncError('passphraseRequired');
  const salt = randomBytes(16);
  const cipher = new AesGcmCipher(await deriveKey(opts.passphrase, salt, DEFAULT_ITERATIONS));
  const keyCheck = await cipher.seal(utf8(KEY_CHECK_PLAINTEXT), KEY_CHECK_CONTEXT);
  const encryption = { iterations: DEFAULT_ITERATIONS, salt: b64encode(salt), keyCheck: b64encode(keyCheck) };
  const manifest: Manifest = {
    formatVersion: 2,
    createdAt: toDouble2001(opts.now?.() ?? new Date()),
    encryption,
    features: ['noteit-doc'],
  };
  try {
    const etag = await backend.put(keys.manifest, encodeJson(manifest), { ifNoneMatch: true });
    const session: StoreSession = {
      manifest,
      manifestETag: etag,
      cipher,
      keyID: await legacyKeyID(encryption),
      features: new Set(['noteit-doc']),
      supported: SUPPORTED_FEATURES,
    };
    return finish(session, true);
  } catch (e) {
    if (!(e instanceof StorageError && e.kind === 'preconditionFailed')) throw e;
    const raced = await readManifest(backend);
    if (!raced) throw new SyncError('storeMissing');
    return finish(await openSession(raced.manifest, raced.etag, opts), false);
  }
}
