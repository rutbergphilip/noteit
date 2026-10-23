import { describe, expect, it } from 'vitest';
import {
  AesGcmCipher,
  b64decode,
  baseTag,
  checkOpenable,
  decodeDevice,
  decodeEnvelope,
  decodeManifest,
  decodeTombstone,
  encodeEnvelope,
  fromUtf8,
  importAesKey,
  isListablePrefix,
  isValidKey,
  openSession,
  patchMeta,
  prefixFor,
  SyncError,
  upgradedManifest,
  utf8,
  NOTE_META_OWNED_KEYS,
} from '../src/index.js';
import { golden } from './golden.js';

interface EnvelopeCase { name: string; key: string; context: string; keyB64: string; sealed: string; plaintextJSON: string; decoded: Record<string, unknown> }

describe('envelope vectors', () => {
  for (const c of golden<EnvelopeCase>('envelopes.json').cases) {
    it(c.name, async () => {
      const cipher = new AesGcmCipher(await importAesKey(b64decode(c.keyB64)));
      const plain = await cipher.open(b64decode(c.sealed), c.context);
      expect(fromUtf8(plain)).toBe(c.plaintextJSON);
      const expected = c.decoded;
      if (c.context.startsWith('notes/') || c.context.startsWith('notebooks/')) {
        const env = decodeEnvelope(plain);
        const { meta, ...rest } = expected;
        expect({ ...env, meta: undefined }).toEqual({ ...rest, meta: undefined });
        expect(JSON.parse(fromUtf8(b64decode(env.meta)))).toEqual(meta);
        // Re-encoding keeps every field.
        expect(JSON.parse(fromUtf8(encodeEnvelope(env)))).toEqual(JSON.parse(c.plaintextJSON));
      } else if (c.context.startsWith('bodies/')) {
        expect(JSON.parse(fromUtf8(plain))).toEqual(expected);
      } else if (c.context.startsWith('tombstones/')) {
        expect(decodeTombstone(plain)).toEqual(expected);
      } else {
        expect(decodeDevice(plain)).toEqual(expected);
      }
    });
  }

  it('enforces the bodyFormat wire rule', () => {
    const env = { id: '430742D2-5082-469B-9F71-FF2B36718F0D', kind: 'note' as const, revision: '430742D2-5082-469B-9F71-FF2B36718F0D', modifiedAt: 1, deviceID: 'd', deviceName: 'n', meta: '' };
    expect(() => encodeEnvelope({ ...env, bodyFormat: 'rtfd', bodyVersion: env.id })).toThrow(SyncError);
    expect(() => encodeEnvelope({ ...env, bodyFormat: 'noteit-doc/1' })).toThrow(SyncError);
    expect(() => encodeEnvelope({ ...env, bodyVersion: env.id })).toThrow(SyncError);
    expect(() => encodeEnvelope({ ...env, bodyFormat: 'noteit-locked/1', bodyVersion: env.id })).toThrow(SyncError);
    expect(() => encodeEnvelope({ ...env, bodyFormat: 'noteit-doc/1', bodyVersion: env.id })).not.toThrow();
    expect(() => decodeEnvelope(utf8(JSON.stringify({ ...env, bodyFormat: '' , bodyVersion: env.id})))).toThrow(SyncError);
  });
});

interface ManifestCase { name: string; manifestJSON: string; passphrase?: string; expect: string; keyID?: string }

describe('manifest vectors', () => {
  for (const c of golden<ManifestCase>('manifest.json').cases) {
    it(c.name, async () => {
      const run = async () => {
        const m = decodeManifest(utf8(c.manifestJSON));
        return openSession(m, 'etag', { passphrase: c.passphrase, allowPlaintext: true });
      };
      if (c.expect === 'ok') {
        const s = await run();
        if (c.keyID) expect(s.keyID).toBe(c.keyID);
      } else {
        await expect(run()).rejects.toMatchObject({ kind: c.expect });
      }
    }, 20_000);
  }
});

interface FeatureCase { name: string; manifestJSON: string; expect: { features?: string[]; bodyEncoding?: string; legacyStore?: boolean; upgrade?: string; upgradedManifestJSON?: string; error?: string } }

describe('manifest-features vectors', () => {
  for (const c of golden<FeatureCase>('manifest-features.json').cases) {
    it(c.name, () => {
      const m = decodeManifest(utf8(c.manifestJSON));
      if (c.expect.error) {
        expect(() => checkOpenable(m)).toThrow(expect.objectContaining({ kind: c.expect.error }));
        return;
      }
      const features = [...checkOpenable(m)].sort();
      expect(features).toEqual(c.expect.features);
      const doc = features.includes('noteit-doc');
      expect(doc ? 'noteitDocV1' : 'rtfd').toBe(c.expect.bodyEncoding);
      expect(!doc).toBe(c.expect.legacyStore);
      const upgrade = doc ? 'none' : m.rekey ? 'skipRekey' : 'run';
      expect(upgrade).toBe(c.expect.upgrade);
      if (c.expect.upgradedManifestJSON) {
        expect(upgradedManifest(m)).toEqual(JSON.parse(c.expect.upgradedManifestJSON));
      }
    });
  }
});

interface LayoutKey { key: string; valid: boolean; prefix: string | null; action: string }

describe('base-tags vectors', () => {
  for (const c of golden<{ etag: string; tag: string }>('base-tags.json').cases) {
    it(c.etag, async () => {
      expect(await baseTag(c.etag)).toBe(c.tag);
    });
  }
});

describe('layout-keys vectors', () => {
  const g = golden('layout-keys.json') as unknown as { keys: LayoutKey[]; listPrefixes: { prefix: string; allowed: boolean }[] };
  for (const c of g.keys) {
    it(`key ${c.key}`, () => {
      expect(isValidKey(c.key)).toBe(c.valid);
      if (c.valid && c.prefix) expect(prefixFor(c.key)?.path).toBe(c.prefix);
    });
  }
  for (const c of g.listPrefixes) {
    it(`prefix ${JSON.stringify(c.prefix)}`, () => expect(isListablePrefix(c.prefix)).toBe(c.allowed));
  }
  it('accepts versioned body keys', () => {
    expect(isValidKey('noteit/v1/bodies/6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F.6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F.new.body')).toBe(true);
    expect(isValidKey('noteit/v1/bodies/6a1c8e8c-3f55-4c3a-9f7e-1d2b3c4d5e6f.6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F.new.body')).toBe(false);
  });
});

describe('patchMeta', () => {
  it('keeps unknown keys and removes cleared owned keys', () => {
    const raw = utf8(JSON.stringify({ id: 'A', title: 'Old', parent: 'P', notebookID: 'N', futureKey: { x: 1 } }));
    const out = JSON.parse(fromUtf8(patchMeta(raw, { id: 'A', title: 'New', preview: '', tags: [], isPinned: false, createdAt: 'c', updatedAt: 'u' }, NOTE_META_OWNED_KEYS)));
    expect(out).toEqual({ id: 'A', title: 'New', preview: '', tags: [], isPinned: false, createdAt: 'c', updatedAt: 'u', parent: 'P', futureKey: { x: 1 } });
  });
});
