import { base32, sha256, utf8 } from './bytes.js';
import type { RemoteObject } from './storage/backend.js';
import { normalizeUuid, type Uuid } from './uuid.js';

export const ROOT = 'noteit/v1/';
export const LEGACY_ROOT = 'inkwell/v1/';
export const CANARY_PREFIX = 'noteit/.canary/';
export const CANARY_MISMATCH_ETAG = 'noteit-canary-mismatch';
export const NEW_TAG = 'new';

/** Swift `RecordKind` raw values. Smart folders belong to organise; like notebooks they have no body. */
export type RecordKind = 'notebook' | 'note' | 'smartFolder';
export const RECORD_KINDS: readonly RecordKind[] = ['notebook', 'note', 'smartFolder'];
export const isRecordKind = (k: unknown): k is RecordKind => k === 'notebook' || k === 'note' || k === 'smartFolder';

export const keys = {
  manifest: `${ROOT}manifest.json`,
  notebook: (id: Uuid) => `${ROOT}notebooks/${id}.json`,
  noteMeta: (id: Uuid) => `${ROOT}notes/${id}.meta`,
  noteBody: (id: Uuid) => `${ROOT}notes/${id}.body`,
  docBody: (id: Uuid, version: Uuid, tag: string) => `${ROOT}bodies/${id}.${version}.${tag}.body`,
  smartFolder: (id: Uuid) => `${ROOT}smart-folders/${id}.json`,
  reminderClaims: `${ROOT}claims/reminders/`,
  reminderClaim: (id: Uuid) => `${ROOT}claims/reminders/${id}.json`,
  tombstone: (id: Uuid) => `${ROOT}tombstones/${id}.json`,
  device: (deviceId: string) => `${ROOT}devices/${deviceId}.json`,
  metaKey: (id: Uuid, kind: RecordKind) => (kind === 'notebook' ? keys.notebook(id) : kind === 'smartFolder' ? keys.smartFolder(id) : keys.noteMeta(id)),
};

/** The cipher context of a key: the key with `noteit/v1/` stripped. */
export function context(key: string): string {
  return key.startsWith(ROOT) ? key.slice(ROOT.length) : key;
}

function unquotedETag(etag: string): string {
  return etag.length >= 2 && etag.startsWith('"') && etag.endsWith('"') ? etag.slice(1, -1) : etag;
}

/** First 10 bytes of SHA-256 over the unquoted ETag, base32 without padding (16 chars). Spec §3.4.9. */
export async function baseTag(etag: string): Promise<string> {
  return base32((await sha256(utf8(unquotedETag(etag)))).subarray(0, 10));
}

const UPPER_UUID = '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}';
/** `<ID>.<VERSION>.<TAG>.body|.locked`: uppercase UUIDs, TAG 16 base32 characters or `new` (RemoteLayout.parseDocBody). */
const DOC_BODY_RE = new RegExp(`^(${UPPER_UUID})\\.(${UPPER_UUID})\\.([A-Z2-7]{16}|${NEW_TAG})\\.(body|locked)$`);

export interface RemoteIndex {
  manifest?: RemoteObject;
  metas: Map<Uuid, RemoteObject & { kind: RecordKind }>;
  bodies: Map<Uuid, RemoteObject>;
  docBodies: Map<Uuid, Map<Uuid, RemoteObject & { tag: string; locked: boolean }>>;
  tombstones: Map<Uuid, RemoteObject>;
  devices: Map<string, RemoteObject>;
  sidecars: RemoteObject[];
}

/** One listing of the root, indexed by record. Unknown prefixes and kinds are skipped, never errors. */
export function indexRemote(objects: RemoteObject[]): RemoteIndex {
  const index: RemoteIndex = {
    metas: new Map(),
    bodies: new Map(),
    docBodies: new Map(),
    tombstones: new Map(),
    devices: new Map(),
    sidecars: [],
  };
  for (const object of objects) {
    if (!object.key.startsWith(ROOT)) continue;
    const path = object.key.slice(ROOT.length);
    if (path === 'manifest.json') {
      index.manifest = object;
      continue;
    }
    const slash = path.indexOf('/');
    if (slash < 0) continue;
    const dir = path.slice(0, slash);
    const name = path.slice(slash + 1);
    if (name.includes('/')) continue;
    const idFor = (suffix: string): Uuid | null =>
      name.endsWith(suffix) ? normalizeUuid(name.slice(0, -suffix.length)) : null;
    switch (dir) {
      case 'notebooks': {
        const id = idFor('.json');
        if (id) index.metas.set(id, { ...object, kind: 'notebook' });
        else if (name.length > 36 && normalizeUuid(name.slice(0, 36))) index.sidecars.push(object);
        break;
      }
      case 'smart-folders': {
        const id = idFor('.json');
        if (id) index.metas.set(id, { ...object, kind: 'smartFolder' });
        else if (name.length > 36 && normalizeUuid(name.slice(0, 36))) index.sidecars.push(object);
        break;
      }
      case 'notes': {
        const meta = idFor('.meta');
        const body = idFor('.body');
        if (meta) index.metas.set(meta, { ...object, kind: 'note' });
        else if (body) index.bodies.set(body, object);
        else if (name.length > 36 && normalizeUuid(name.slice(0, 36))) index.sidecars.push(object);
        break;
      }
      case 'bodies': {
        const m = DOC_BODY_RE.exec(name);
        const id = m && normalizeUuid(m[1]!);
        const version = m && normalizeUuid(m[2]!);
        if (!m || !id || !version) break;
        let versions = index.docBodies.get(id);
        if (!versions) index.docBodies.set(id, (versions = new Map()));
        versions.set(version, { ...object, tag: m[3]!, locked: m[4] === 'locked' });
        break;
      }
      case 'tombstones': {
        const id = idFor('.json');
        if (id) index.tombstones.set(id, object);
        break;
      }
      case 'devices':
        if (name.endsWith('.json')) index.devices.set(name.slice(0, -5), object);
        break;
      default:
        break;
    }
  }
  return index;
}

// MARK: key grammar (program spec §4 rule 8; RemoteLayout.isValidKey / isListablePrefix)

export interface RemotePrefix {
  path: string;
  depth: number;
  owner: string;
}

export const PREFIXES: readonly RemotePrefix[] = [
  { path: `${ROOT}notebooks/`, depth: 1, owner: 'core' },
  { path: `${ROOT}notes/`, depth: 1, owner: 'core' },
  { path: `${ROOT}tombstones/`, depth: 1, owner: 'core' },
  { path: `${ROOT}devices/`, depth: 1, owner: 'core' },
  { path: `${ROOT}bodies/`, depth: 1, owner: 'web-app' },
  { path: `${ROOT}smart-folders/`, depth: 1, owner: 'organise' },
  { path: `${ROOT}claims/reminders/`, depth: 1, owner: 'organise' },
  { path: `${ROOT}keys/`, depth: 1, owner: 'sync-security' },
  { path: `${ROOT}boards/`, depth: 1, owner: 'surfaces-polish' },
];

const SEGMENT_RE = /^[A-Za-z0-9._-]{1,128}$/;
const UUID_STEM_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

function hasValidSegments(key: string): boolean {
  return key.split('/').every((segment) => {
    if (!SEGMENT_RE.test(segment) || segment === '.' || segment === '..') return false;
    const dot = segment.indexOf('.');
    const stem = dot < 0 ? segment : segment.slice(0, dot);
    if (UUID_STEM_RE.test(stem)) return stem === stem.toUpperCase();
    return true;
  });
}

function depthBelow(key: string, path: string): number {
  const rest = key.slice(path.length);
  return rest.length === 0 ? 0 : rest.split('/').length;
}

export function prefixFor(key: string): RemotePrefix | undefined {
  return PREFIXES.filter((p) => key.startsWith(p.path) && depthBelow(key, p.path) === p.depth).sort(
    (a, b) => b.path.length - a.path.length,
  )[0];
}

export function isCanaryKey(key: string): boolean {
  return key.startsWith(CANARY_PREFIX) && depthBelow(key, CANARY_PREFIX) === 1;
}

export function isValidKey(key: string): boolean {
  if (!hasValidSegments(key)) return false;
  if (key === keys.manifest || isCanaryKey(key)) return true;
  const prefix = prefixFor(key);
  if (prefix === undefined) return false;
  return prefix.path !== `${ROOT}bodies/` || DOC_BODY_RE.test(key.slice(prefix.path.length));
}

export function isListablePrefix(prefix: string): boolean {
  if (!prefix.endsWith('/') || !hasValidSegments(prefix.slice(0, -1))) return false;
  return [...PREFIXES.map((p) => p.path), CANARY_PREFIX, LEGACY_ROOT].some((p) => p.startsWith(prefix));
}
