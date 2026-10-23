import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { DiskStore, InvalidKeyError } from '../../server/lib/diskStore';

const USER = '6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F';
let dir: string;

afterEach(async () => rm(dir, { recursive: true, force: true }));

describe('DiskStore', () => {
  it('refuses every key and user id that could leave the namespace', async () => {
    dir = await mkdtemp(join(tmpdir(), 'noteit-disk-'));
    const store = new DiskStore(dir);
    await store.init();
    const bad = ['../x', 'noteit/v1/../../x', 'noteit/v1/notes/..', '/etc/passwd', 'noteit/v1/notes//a.meta', 'noteit\\v1', 'noteit/v1/notes/a\0.meta', ''];
    for (const key of bad) {
      expect(() => store.pathFor(USER, key), key).toThrow(InvalidKeyError);
      await expect(store.put(USER, key, new Uint8Array(1), {}), key).rejects.toBeInstanceOf(InvalidKeyError);
    }
    for (const id of ['..', '../x', 'abc', USER.toLowerCase()]) expect(() => store.userRoot(id), id).toThrow(InvalidKeyError);
    await expect(store.list(USER, '../')).rejects.toBeInstanceOf(InvalidKeyError);
    expect(await readdir(join(dir, 'users'))).toEqual([]);
  });

  it('makes conditional writes atomic and uses MD5 ETags', async () => {
    dir = await mkdtemp(join(tmpdir(), 'noteit-disk-'));
    const store = new DiskStore(dir);
    await store.init();
    const key = 'noteit/v1/manifest.json';
    const results = await Promise.all(Array.from({ length: 10 }, (_, i) => store.put(USER, key, new Uint8Array([i]), { ifNoneMatch: true })));
    expect(results.filter((r) => r !== 'preconditionFailed')).toHaveLength(1);
    const put = (await store.put(USER, 'noteit/v1/devices/A.json', new TextEncoder().encode('hello'), {})) as { etag: string };
    expect(put.etag).toBe('5d41402abc4b2a76b9719d911017c592');
    expect(await store.delete(USER, 'noteit/v1/devices/A.json', { ifMatch: 'nope' })).toBe('preconditionFailed');
    expect(await store.delete(USER, 'noteit/v1/devices/A.json', { ifMatch: put.etag })).toBe('ok');
    expect((await store.list(USER, 'noteit/')).map((o) => o.key)).toEqual([key]);
  });
});
