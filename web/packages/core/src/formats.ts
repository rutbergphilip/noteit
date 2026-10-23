import { type Bytes, b64decode, b64encode, fromUtf8, utf8 } from './bytes.js';
import { SyncError } from './errors.js';
import { isRecordKind, type RecordKind } from './layout.js';
import { normalizeUuid, type Uuid } from './uuid.js';

// MARK: JSON

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object' && !(value instanceof Uint8Array)) {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort()) {
      const v = (value as Record<string, unknown>)[key];
      if (v !== undefined) out[key] = sortKeys(v);
    }
    return out;
  }
  return value;
}

/** UTF-8 JSON with sorted keys and no undefined keys. */
export function encodeJson(value: unknown, pretty = false): Bytes {
  return utf8(JSON.stringify(sortKeys(value), null, pretty ? 2 : undefined));
}

export function decodeJsonObject(b: Uint8Array, what: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(fromUtf8(b));
  } catch {
    throw new SyncError('invalidPayload', `${what} is not JSON`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new SyncError('invalidPayload', `${what} is not an object`);
  return parsed as Record<string, unknown>;
}

const isString = (v: unknown): v is string => typeof v === 'string';
const isNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

function req<T>(obj: Record<string, unknown>, key: string, check: (v: unknown) => v is T, what: string): T {
  const v = obj[key];
  if (!check(v)) throw new SyncError('invalidPayload', `${what}: bad ${key}`);
  return v;
}

function opt<T>(obj: Record<string, unknown>, key: string, check: (v: unknown) => v is T, what: string): T | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (!check(v)) throw new SyncError('invalidPayload', `${what}: bad ${key}`);
  return v;
}

function uuidField(obj: Record<string, unknown>, key: string, what: string): Uuid {
  const id = normalizeUuid(req(obj, key, isString, what));
  if (!id) throw new SyncError('invalidPayload', `${what}: ${key} is not a UUID`);
  return id;
}

// MARK: Manifest

export interface Keyring {
  keyID: string;
  kdf: string;
  salt: string;
  iterations: number;
  wrappedKey: string;
  changedAt: number;
  changedBy: string;
}
export interface Rekey {
  fromKeyID?: string;
  toKeyID: string;
  startedAt: number;
  updatedAt: number;
  deviceID: string;
  deviceName: string;
  [extra: string]: unknown;
}
export const REKEY_STALE_AFTER_S = 3600;

export interface Manifest {
  formatVersion: number;
  createdAt: number;
  encryption?: { iterations: number; salt: string; keyCheck: string };
  features?: string[];
  keyring?: Keyring;
  rekey?: Rekey;
  [extra: string]: unknown;
}

export const MAX_FORMAT_VERSION = 2;
export type StoreFeature = 'noteit-doc' | 'keyring' | 'locked-notes' | 'noteit-space';
export const KNOWN_FEATURES: ReadonlySet<StoreFeature> = new Set(['noteit-doc', 'keyring', 'locked-notes', 'noteit-space']);
export const SUPPORTED_FEATURES: ReadonlySet<StoreFeature> = new Set(['noteit-doc', 'keyring', 'locked-notes']);
const FEATURE_REQUIRES: Partial<Record<StoreFeature, StoreFeature[]>> = { 'locked-notes': ['noteit-doc'] };
export const BODY_FORMAT_DOC_V1 = 'noteit-doc/1';
export const BODY_FORMAT_LOCKED_V1 = 'noteit-locked/1';

/** Parses the plaintext manifest; unknown keys are kept. Structural problems → invalidManifest. */
export function decodeManifest(b: Uint8Array): Manifest {
  let obj: Record<string, unknown>;
  try {
    obj = decodeJsonObject(b, 'manifest');
  } catch {
    throw new SyncError('invalidManifest', 'unreadable manifest');
  }
  const fail = (why: string): never => {
    throw new SyncError('invalidManifest', why);
  };
  if (!Number.isInteger(obj.formatVersion)) fail('formatVersion');
  if (!isNumber(obj.createdAt)) fail('createdAt');
  if (obj.features !== undefined && (!Array.isArray(obj.features) || !obj.features.every(isString))) fail('features');
  if (obj.encryption !== undefined) {
    const e = obj.encryption as Record<string, unknown>;
    if (!e || typeof e !== 'object' || !Number.isInteger(e.iterations) || !isString(e.salt) || !isString(e.keyCheck)) fail('encryption');
  }
  if (obj.keyring !== undefined) {
    const k = obj.keyring as Record<string, unknown>;
    if (!k || typeof k !== 'object' || !isString(k.keyID) || !isString(k.kdf) || !isString(k.salt) || !Number.isInteger(k.iterations) || !isString(k.wrappedKey)) {
      fail('keyring');
    }
  }
  if (obj.rekey !== undefined) {
    const r = obj.rekey as Record<string, unknown>;
    if (!r || typeof r !== 'object' || !isString(r.toKeyID) || !isString(r.deviceID) || !isNumber(r.updatedAt)) fail('rekey');
  }
  return obj as Manifest;
}

/** The gate for opening a store (= Swift SyncEngine.checkOpenable). */
export function checkOpenable(m: Manifest, supported: ReadonlySet<StoreFeature> = SUPPORTED_FEATURES): Set<StoreFeature> {
  if (m.formatVersion > MAX_FORMAT_VERSION) throw new SyncError('unsupportedFormat', undefined, m.formatVersion);
  const features = new Set<StoreFeature>();
  for (const name of m.features ?? []) {
    if (!supported.has(name as StoreFeature)) throw new SyncError('unsupportedFeature', name);
    features.add(name as StoreFeature);
  }
  if ((m.features ?? []).length > 0 && m.formatVersion !== 2) throw new SyncError('invalidManifest', 'features without formatVersion 2');
  for (const f of features) {
    for (const r of FEATURE_REQUIRES[f] ?? []) {
      if (!features.has(r)) throw new SyncError('invalidManifest', `${f} without ${r}`);
    }
  }
  return features;
}

export function rekeyIsStale(rekey: Rekey, now: Date): boolean {
  return now.getTime() / 1000 - (rekey.updatedAt + 978307200) >= REKEY_STALE_AFTER_S;
}

/** What a native v2 build's upgrade writes (spec §3.4 item 6): the manifest with `noteit-doc` added, kept otherwise. */
export function upgradedManifest(m: Manifest): Manifest {
  const features = [...new Set([...(m.features ?? []), 'noteit-doc'])].sort();
  return { ...m, formatVersion: 2, features };
}

// MARK: Envelope, tombstone, device

export interface RemoteEnvelope {
  id: Uuid;
  kind: RecordKind;
  revision: Uuid;
  modifiedAt: number;
  deviceID: string;
  deviceName: string;
  /** base64 of the inner meta JSON */
  meta: string;
  bodySHA256?: string;
  bodyFormat?: string;
  bodyVersion?: Uuid;
}

function checkBodyFields(env: { bodyFormat?: string; bodyVersion?: string }, allowLocked: boolean): void {
  if (env.bodyFormat === undefined) {
    if (env.bodyVersion !== undefined) throw new SyncError('invalidPayload', 'bodyVersion without bodyFormat');
    return;
  }
  if (env.bodyFormat !== BODY_FORMAT_DOC_V1 && !(allowLocked && env.bodyFormat === BODY_FORMAT_LOCKED_V1)) {
    throw new SyncError('invalidPayload', `bodyFormat ${JSON.stringify(env.bodyFormat)}`);
  }
  if (env.bodyVersion === undefined || !normalizeUuid(env.bodyVersion)) {
    throw new SyncError('invalidPayload', 'bodyFormat without bodyVersion');
  }
}

/** Throws invalidPayload unless the body fields follow the wire rule (spec §3.4 item 8). A locked format is
 * only allowed when it is carried unchanged from `base`. */
export function encodeEnvelope(env: RemoteEnvelope, base?: RemoteEnvelope): Bytes {
  const carriedLocked =
    env.bodyFormat === BODY_FORMAT_LOCKED_V1 && base?.bodyFormat === BODY_FORMAT_LOCKED_V1 && base.bodyVersion === env.bodyVersion;
  checkBodyFields(env, carriedLocked);
  return encodeJson(env);
}

export function decodeEnvelope(b: Uint8Array, allowLocked = true): RemoteEnvelope {
  const o = decodeJsonObject(b, 'envelope');
  const what = 'envelope';
  const kind = req(o, 'kind', isString, what);
  if (!isRecordKind(kind)) throw new SyncError('invalidPayload', `envelope kind ${kind}`);
  const env: RemoteEnvelope = {
    id: uuidField(o, 'id', what),
    kind,
    revision: uuidField(o, 'revision', what),
    modifiedAt: req(o, 'modifiedAt', isNumber, what),
    deviceID: req(o, 'deviceID', isString, what),
    deviceName: req(o, 'deviceName', isString, what),
    meta: req(o, 'meta', isString, what),
  };
  const sha = opt(o, 'bodySHA256', isString, what);
  if (sha !== undefined) env.bodySHA256 = sha;
  const format = opt(o, 'bodyFormat', isString, what);
  if (format !== undefined) env.bodyFormat = format;
  const version = opt(o, 'bodyVersion', isString, what);
  if (version !== undefined) env.bodyVersion = normalizeUuid(version) ?? version;
  checkBodyFields(env, allowLocked);
  return env;
}

export interface Tombstone {
  id: Uuid;
  kind: RecordKind;
  deletedAt: number;
  deviceID: string;
  deletedMetaETag?: string;
}

/** Undefined for a tombstone of a kind this build doesn't know (skipped, program spec §4 rule 9). */
export function decodeTombstone(b: Uint8Array): Tombstone | undefined {
  const o = decodeJsonObject(b, 'tombstone');
  const kind = req(o, 'kind', isString, 'tombstone');
  if (!isRecordKind(kind)) return undefined;
  const t: Tombstone = {
    id: uuidField(o, 'id', 'tombstone'),
    kind,
    deletedAt: req(o, 'deletedAt', isNumber, 'tombstone'),
    deviceID: req(o, 'deviceID', isString, 'tombstone'),
  };
  const etag = opt(o, 'deletedMetaETag', isString, 'tombstone');
  if (etag !== undefined) t.deletedMetaETag = etag;
  return t;
}

export interface DeviceInfo {
  deviceID: string;
  name: string;
  lastSync: number;
  platform?: string;
  appVersion?: string;
  supportedFeatures?: string[];
  rekeyAck?: string;
  [extra: string]: unknown;
}

export function decodeDevice(b: Uint8Array): DeviceInfo {
  const o = decodeJsonObject(b, 'device');
  req(o, 'deviceID', isString, 'device');
  req(o, 'name', isString, 'device');
  req(o, 'lastSync', isNumber, 'device');
  return o as DeviceInfo;
}

// MARK: Inner metas

export interface NoteMeta {
  id: Uuid;
  title: string;
  preview: string;
  tags: string[];
  isPinned: boolean;
  notebookID?: Uuid;
  createdAt: string;
  updatedAt: string;
  revision?: Uuid;
  conflictSource?: string;
  conflictOriginalID?: Uuid;
  deletedAt?: string;
  lock?: { keyID: string; sealedID: Uuid };
}

export interface NotebookMeta {
  id: Uuid;
  name: string;
  colorHex: string;
  symbol: string;
  sortIndex: number;
  modifiedAt?: string;
  revision?: Uuid;
}

export const NOTE_META_OWNED_KEYS: readonly string[] = [
  'id', 'title', 'preview', 'tags', 'isPinned', 'notebookID', 'createdAt', 'updatedAt', 'revision',
  'conflictSource', 'conflictOriginalID', 'deletedAt', 'lock',
];
export const NOTEBOOK_META_OWNED_KEYS: readonly string[] = ['id', 'name', 'colorHex', 'symbol', 'sortIndex', 'modifiedAt', 'revision'];

/** Swift `SmartFolder` (organise): a saved search in the sidebar. */
export interface SmartFolderMeta {
  id: Uuid;
  name: string;
  query: string;
  symbol: string;
  sortIndex: number;
  revision?: Uuid;
  modifiedAt?: string;
}
/** `SmartFolder.ownedCodingKeys`. */
export const SMART_FOLDER_META_OWNED_KEYS: readonly string[] = ['id', 'name', 'query', 'symbol', 'sortIndex', 'revision', 'modifiedAt'];
export const SMART_FOLDER_DEFAULT_SYMBOL = 'folder.badge.gearshape';
export const SMART_FOLDER_MAX_NAME = 60;
export const SMART_FOLDER_MAX_QUERY = 500;
export const SMART_FOLDER_MAX_COUNT = 200;

export function decodeSmartFolderMeta(b: Uint8Array): SmartFolderMeta {
  const o = decodeJsonObject(b, 'smartFolder');
  const w = 'smartFolder';
  const meta: SmartFolderMeta = {
    id: uuidField(o, 'id', w),
    name: req(o, 'name', isString, w),
    query: req(o, 'query', isString, w),
    symbol: req(o, 'symbol', isString, w),
    sortIndex: Number.isInteger(o.sortIndex) ? (o.sortIndex as number) : 0,
  };
  const rev = opt(o, 'revision', isString, w);
  if (rev && normalizeUuid(rev)) meta.revision = normalizeUuid(rev)!;
  const mod = opt(o, 'modifiedAt', isString, w);
  if (mod !== undefined) meta.modifiedAt = mod;
  return meta;
}

/** RawMetaOverlay: owned keys come only from `meta` (absent there → removed), every other key from `raw`. */
export function patchMeta(raw: Uint8Array | undefined, meta: object, ownedKeys: readonly string[]): Bytes {
  const mine = JSON.parse(JSON.stringify(meta)) as Record<string, unknown>;
  if (!raw) return encodeJson(mine, true);
  let merged: Record<string, unknown>;
  try {
    const parsed = JSON.parse(fromUtf8(raw)) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return encodeJson(mine, true);
    merged = parsed as Record<string, unknown>;
  } catch {
    return encodeJson(mine, true);
  }
  for (const key of ownedKeys) {
    if (mine[key] === undefined || mine[key] === null) delete merged[key];
    else merged[key] = mine[key];
  }
  return encodeJson(merged, true);
}

export function decodeNoteMeta(b: Uint8Array): NoteMeta {
  const o = decodeJsonObject(b, 'note meta');
  const w = 'note meta';
  const meta: NoteMeta = {
    id: uuidField(o, 'id', w),
    title: opt(o, 'title', isString, w) ?? '',
    preview: opt(o, 'preview', isString, w) ?? '',
    tags: Array.isArray(o.tags) ? o.tags.filter(isString) : [],
    isPinned: o.isPinned === true,
    createdAt: req(o, 'createdAt', isString, w),
    updatedAt: req(o, 'updatedAt', isString, w),
  };
  const nb = opt(o, 'notebookID', isString, w);
  if (nb && normalizeUuid(nb)) meta.notebookID = normalizeUuid(nb)!;
  const rev = opt(o, 'revision', isString, w);
  if (rev && normalizeUuid(rev)) meta.revision = normalizeUuid(rev)!;
  const cs = opt(o, 'conflictSource', isString, w);
  if (cs !== undefined) meta.conflictSource = cs;
  const co = opt(o, 'conflictOriginalID', isString, w);
  if (co && normalizeUuid(co)) meta.conflictOriginalID = normalizeUuid(co)!;
  const del = opt(o, 'deletedAt', isString, w);
  if (del !== undefined) meta.deletedAt = del;
  if (o.lock && typeof o.lock === 'object') meta.lock = o.lock as NoteMeta['lock'];
  return meta;
}

export function decodeNotebookMeta(b: Uint8Array): NotebookMeta & { parent?: Uuid } {
  const o = decodeJsonObject(b, 'notebook');
  const w = 'notebook';
  const meta: NotebookMeta & { parent?: Uuid } = {
    id: uuidField(o, 'id', w),
    name: opt(o, 'name', isString, w) ?? '',
    colorHex: opt(o, 'colorHex', isString, w) ?? '#8E8E93',
    symbol: opt(o, 'symbol', isString, w) ?? 'folder',
    sortIndex: Number.isInteger(o.sortIndex) ? (o.sortIndex as number) : 0,
  };
  const mod = opt(o, 'modifiedAt', isString, w);
  if (mod !== undefined) meta.modifiedAt = mod;
  const rev = opt(o, 'revision', isString, w);
  if (rev && normalizeUuid(rev)) meta.revision = normalizeUuid(rev)!;
  // `parent` belongs to organise (nested notebooks); read for display only.
  const parent = typeof o.parent === 'string' ? normalizeUuid(o.parent) : null;
  if (parent) meta.parent = parent;
  return meta;
}

export function metaBytes(env: RemoteEnvelope): Bytes {
  return b64decode(env.meta);
}

export function metaToBase64(b: Uint8Array): string {
  return b64encode(b);
}
