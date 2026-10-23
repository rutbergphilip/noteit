import { describe, expect, it } from 'vitest';
import { HttpProxyBackend, InMemoryBackend, S3Backend, StorageError, utf8 } from '../src/index.js';

const BAD_KEYS = [
  '',
  'noteit/v1/../manifest.json',
  'noteit/v1/notes/../../../etc/passwd',
  'noteit/v1/notes/./x.meta',
  'noteit/v1/notes//x.meta',
  'noteit/v1/notes/',
  '../noteit/v1/manifest.json',
  '/noteit/v1/manifest.json',
  'noteit/v1/notes/a\\b.meta',
  'noteit/v1/notes/%2e%2e.meta',
  'noteit/v1/notes/6a1c8e8c-3f55-4c3a-9f7e-1d2b3c4d5e6f.meta',
  'other/x',
];

function failingFetch(): { fetch: typeof fetch; calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    fetch: (async (input: RequestInfo | URL) => {
      calls.push(String(input));
      return new Response('', { status: 500 });
    }) as typeof fetch,
  };
}

describe('backends reject keys outside the layout grammar before any I/O', () => {
  it('in-memory', async () => {
    const b = new InMemoryBackend();
    for (const key of BAD_KEYS) {
      await expect(b.put(key, utf8('x')), key).rejects.toBeInstanceOf(StorageError);
      await expect(b.get(key), key).rejects.toMatchObject({ kind: 'invalidResponse' });
      await expect(b.delete(key), key).rejects.toMatchObject({ kind: 'invalidResponse' });
    }
    await expect(b.list('../')).rejects.toMatchObject({ kind: 'invalidResponse' });
    expect(b.objects.size).toBe(0);
  });

  it('HTTP proxy', async () => {
    const { fetch, calls } = failingFetch();
    const b = new HttpProxyBackend({ baseUrl: 'https://notes.example', fetch });
    for (const key of BAD_KEYS) {
      await expect(b.put(key, utf8('x')), key).rejects.toMatchObject({ kind: 'invalidResponse' });
      await expect(b.get(key), key).rejects.toMatchObject({ kind: 'invalidResponse' });
      await expect(b.delete(key), key).rejects.toMatchObject({ kind: 'invalidResponse' });
    }
    await expect(b.list('noteit/v1/notes')).rejects.toMatchObject({ kind: 'invalidResponse' });
    expect(calls).toEqual([]);
  });

  it('S3', async () => {
    const { fetch, calls } = failingFetch();
    const b = new S3Backend({ endpoint: 'https://s3.example', bucket: 'b', region: 'us-east-1', accessKeyId: 'k', secretAccessKey: 's', pathStyle: true }, fetch);
    for (const key of BAD_KEYS) {
      await expect(b.put(key, utf8('x')), key).rejects.toMatchObject({ kind: 'invalidResponse' });
      await expect(b.get(key), key).rejects.toMatchObject({ kind: 'invalidResponse' });
      await expect(b.delete(key), key).rejects.toMatchObject({ kind: 'invalidResponse' });
    }
    expect(calls).toEqual([]);
    expect(() => new S3Backend({ endpoint: 'https://s3.example', bucket: 'b', region: 'r', accessKeyId: 'k', secretAccessKey: 's', pathStyle: true, prefix: 'a/../b' }, fetch)).toThrow(StorageError);
  });

  it('allows reading an Inkwell key whose noteit twin is valid, never writing one', async () => {
    const b = new InMemoryBackend();
    await expect(b.get('inkwell/v1/manifest.json')).rejects.toMatchObject({ kind: 'notFound' });
    await expect(b.put('inkwell/v1/manifest.json', utf8('x'))).rejects.toMatchObject({ kind: 'invalidResponse' });
    await expect(b.get('inkwell/v1/../x')).rejects.toMatchObject({ kind: 'invalidResponse' });
  });
});

describe('storeExists', () => {
  it('is false for an empty backend and true once a store is created', async () => {
    const { InMemoryBackend, connect, storeExists } = await import('../src/index.js');
    const backend = new InMemoryBackend();
    expect(await storeExists(backend)).toBe(false);
    await connect(backend, { passphrase: 'correct horse battery', createIfMissing: true });
    expect(await storeExists(backend)).toBe(true);
  });
});
