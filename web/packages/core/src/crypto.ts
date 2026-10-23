import { type Bytes, concat, copyBytes, equalBytes, hex, randomBytes, sha256, utf8, b64decode } from './bytes.js';
import { SyncError } from './errors.js';

export interface SyncCipher {
  readonly encrypted: boolean;
  /** nonce(12) ‖ ciphertext ‖ tag(16); AAD = utf8(context). */
  seal(plaintext: Uint8Array, context: string): Promise<Bytes>;
  open(sealed: Uint8Array, context: string): Promise<Bytes>;
}

export const DEFAULT_ITERATIONS = 210_000;
export const ITERATION_RANGE: readonly [number, number] = [100_000, 10_000_000];
export const KEY_CHECK_PLAINTEXT = 'noteit-key-check';
export const LEGACY_KEY_CHECK_PLAINTEXT = 'inkwell-key-check';
export const KEY_CHECK_CONTEXT = 'manifest';

export function iterationsInRange(n: number): boolean {
  return Number.isInteger(n) && n >= ITERATION_RANGE[0] && n <= ITERATION_RANGE[1];
}

async function pbkdf2Bits(passphraseBytes: Uint8Array, salt: Uint8Array, iterations: number): Promise<Bytes> {
  const base = await crypto.subtle.importKey('raw', copyBytes(passphraseBytes), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: copyBytes(salt), iterations },
    base,
    256,
  );
  return new Uint8Array(bits);
}

/** v1 key: PBKDF2-HMAC-SHA256 over the passphrase's raw UTF-8 (never normalized), used directly as the AES key. */
export async function deriveKey(passphrase: string, salt: Uint8Array, iterations: number, extractable = false): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey('raw', utf8(passphrase), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', hash: 'SHA-256', salt: copyBytes(salt), iterations },
    base,
    { name: 'AES-GCM', length: 256 },
    extractable,
    ['encrypt', 'decrypt'],
  );
}

export function deriveKeyBytesForTests(passphrase: string, salt: Uint8Array, iterations: number): Promise<Bytes> {
  return pbkdf2Bits(utf8(passphrase), salt, iterations);
}

export function importAesKey(raw: Uint8Array, extractable = false): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', copyBytes(raw), { name: 'AES-GCM' }, extractable, ['encrypt', 'decrypt']);
}

export class AesGcmCipher implements SyncCipher {
  readonly encrypted = true;
  constructor(
    readonly key: CryptoKey,
    private readonly randomNonce: () => Bytes = () => randomBytes(12),
  ) {}

  async seal(plaintext: Uint8Array, context: string): Promise<Bytes> {
    const nonce = this.randomNonce();
    const ct = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce, additionalData: utf8(context), tagLength: 128 },
      this.key,
      copyBytes(plaintext),
    );
    return concat(nonce, new Uint8Array(ct));
  }

  async open(sealed: Uint8Array, context: string): Promise<Bytes> {
    if (sealed.length < 28) throw new SyncError('wrongPassphrase', `sealed data too short for ${context}`);
    try {
      const pt = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: copyBytes(sealed.subarray(0, 12)), additionalData: utf8(context), tagLength: 128 },
        this.key,
        copyBytes(sealed.subarray(12)),
      );
      return new Uint8Array(pt);
    } catch {
      throw new SyncError('wrongPassphrase', `cannot open ${context}`);
    }
  }
}

export class IdentityCipher implements SyncCipher {
  readonly encrypted = false;
  async seal(plaintext: Uint8Array): Promise<Bytes> {
    return copyBytes(plaintext);
  }
  async open(sealed: Uint8Array): Promise<Bytes> {
    return copyBytes(sealed);
  }
}

/** Whether `cipher` opens a manifest key check (new stores seal `noteit-key-check`, Inkwell's `inkwell-key-check`). */
export async function opensKeyCheck(cipher: SyncCipher, keyCheck: Uint8Array): Promise<boolean> {
  try {
    const opened = await cipher.open(keyCheck, KEY_CHECK_CONTEXT);
    return equalBytes(opened, utf8(KEY_CHECK_PLAINTEXT)) || equalBytes(opened, utf8(LEGACY_KEY_CHECK_PLAINTEXT));
  } catch {
    return false;
  }
}

async function hex8(data: Uint8Array): Promise<string> {
  return hex((await sha256(data)).subarray(0, 8));
}

/** = Swift KeyIdentity.keyID: SHA256("noteit-key-id" ‖ key), first 8 bytes as hex. */
export function keyIDFor(rawKey: Uint8Array): Promise<string> {
  return hex8(concat(utf8('noteit-key-id'), rawKey));
}

/** = Swift KeyIdentity.legacyKeyID. */
export function legacyKeyID(encryption: { salt: string; iterations: number; keyCheck: string }): Promise<string> {
  const it = new Uint8Array(4);
  new DataView(it.buffer).setUint32(0, encryption.iterations >>> 0, false);
  return hex8(concat(utf8('noteit-legacy-key'), b64decode(encryption.salt), it, b64decode(encryption.keyCheck)));
}

export interface KeyringFields {
  keyID: string;
  kdf: string;
  salt: string;
  iterations: number;
  wrappedKey: string;
}

/** Unwraps a sync-security keyring (NFC passphrase); returns the non-extractable data key. */
export async function unwrapKeyring(passphrase: string, keyring: KeyringFields): Promise<CryptoKey> {
  const normalized = passphrase.normalize('NFC');
  if (normalized.length === 0) throw new SyncError('passphraseRequired');
  if (keyring.kdf !== 'pbkdf2-sha256') throw new SyncError('invalidManifest', `unknown keyring kdf ${keyring.kdf}`);
  if (!iterationsInRange(keyring.iterations)) throw new SyncError('invalidManifest', 'keyring iterations out of range');
  const salt = b64decode(keyring.salt);
  if (salt.length === 0) throw new SyncError('invalidManifest', 'keyring salt is empty');
  const kek = await importAesKey(await pbkdf2Bits(utf8(normalized), salt, keyring.iterations));
  let raw: Bytes;
  try {
    raw = await new AesGcmCipher(kek).open(b64decode(keyring.wrappedKey), `keyring/${keyring.keyID}`);
  } catch {
    throw new SyncError('wrongPassphrase');
  }
  if (raw.length !== 32 || (await keyIDFor(raw)) !== keyring.keyID) {
    throw new SyncError('invalidManifest', "keyring key doesn't match its keyID");
  }
  const key = await importAesKey(raw);
  raw.fill(0);
  return key;
}
