/**
 * The direct-mode credential vault (spec §6.4, "Credential storage in the browser"): the S3 settings and key, sealed
 * with AES-256-GCM under PBKDF2-SHA256(passphrase, salt, 210 000). The salt is made on this device, so the vault opens
 * without the network; the record lives in IndexedDB and nothing of it reaches localStorage, cookies or a URL.
 */

export interface DirectCredentials {
  endpoint: string;
  region: string;
  bucket: string;
  /** Key prefix in the bucket, as in the Mac's S3 settings; '' for the bucket root. */
  prefix: string;
  pathStyle: boolean;
  accessKeyId: string;
  secretAccessKey: string;
}

export interface VaultRecord {
  v: 1;
  salt: Uint8Array;
  iv: Uint8Array;
  ciphertext: Uint8Array;
}

export const VAULT_AAD = 'local/credentials/v1';
export const VAULT_ITERATIONS = 210_000;

export class VaultError extends Error {
  constructor(readonly kind: 'wrongPassphrase' | 'invalidRecord') {
    super(kind);
  }
}

const enc = new TextEncoder();

async function credKey(passphrase: string, salt: Uint8Array): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey('raw', enc.encode(passphrase), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'PBKDF2', hash: 'SHA-256', salt: salt as BufferSource, iterations: VAULT_ITERATIONS }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

export async function sealCredentials(passphrase: string, creds: DirectCredentials, aad = VAULT_AAD): Promise<VaultRecord> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await credKey(passphrase, salt);
  const plain = enc.encode(JSON.stringify(normalizeCredentials(creds)));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(aad) }, key, plain));
  return { v: 1, salt, iv, ciphertext };
}

/** Throws VaultError('wrongPassphrase') when the GCM tag doesn't verify (wrong passphrase, or another AAD). */
export async function openCredentials(passphrase: string, record: VaultRecord, aad = VAULT_AAD): Promise<DirectCredentials> {
  if (record?.v !== 1 || !(record.salt instanceof Uint8Array) || !(record.iv instanceof Uint8Array) || !(record.ciphertext instanceof Uint8Array)) throw new VaultError('invalidRecord');
  const key = await credKey(passphrase, record.salt);
  let plain: ArrayBuffer;
  try {
    plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: record.iv as BufferSource, additionalData: enc.encode(aad) }, key, record.ciphertext as BufferSource);
  } catch {
    throw new VaultError('wrongPassphrase');
  }
  return normalizeCredentials(JSON.parse(new TextDecoder().decode(plain)) as DirectCredentials);
}

/** Trims what the user typed and keeps only the known fields. */
export function normalizeCredentials(c: DirectCredentials): DirectCredentials {
  return {
    endpoint: c.endpoint.trim().replace(/\/+$/, ''),
    region: c.region.trim() || 'us-east-1',
    bucket: c.bucket.trim(),
    prefix: c.prefix.trim().replace(/^\/+|\/+$/g, ''),
    pathStyle: !!c.pathStyle,
    accessKeyId: c.accessKeyId.trim(),
    secretAccessKey: c.secretAccessKey.trim(),
  };
}
