import { describe, expect, it } from 'vitest';
import { AesGcmCipher, b64decode, b64encode, baseTag, deriveKeyBytesForTests, fromUtf8, importAesKey, utf8 } from '../src/index.js';
import { golden } from './golden.js';

interface Pbkdf2Case { passphrase: string; salt: string; iterations: number; key: string }
interface AesCase { key: string; nonce: string; plaintext: string; context: string; sealed: string; tamper?: 'aad' | 'tag' | 'nonce'; expect?: 'fail' }

describe('pbkdf2 vectors', () => {
  for (const c of golden<Pbkdf2Case>('pbkdf2.json').cases) {
    it(`${JSON.stringify(c.passphrase)} × ${c.iterations}`, async () => {
      const key = await deriveKeyBytesForTests(c.passphrase, b64decode(c.salt), c.iterations);
      expect(b64encode(key)).toBe(c.key);
    });
  }
});

describe('aes-gcm vectors', () => {
  for (const [i, c] of golden<AesCase>('aesgcm.json').cases.entries()) {
    it(`case ${i} ${c.tamper ?? 'seal/open'}`, async () => {
      const key = await importAesKey(b64decode(c.key));
      const cipher = new AesGcmCipher(key, () => b64decode(c.nonce));
      if (c.expect === 'fail') {
        await expect(cipher.open(b64decode(c.sealed), c.context)).rejects.toThrow();
        return;
      }
      expect(b64encode(await cipher.seal(b64decode(c.plaintext), c.context))).toBe(c.sealed);
      expect(b64encode(await cipher.open(b64decode(c.sealed), c.context))).toBe(c.plaintext);
    });
  }

  it('a sealed object does not open under another context', async () => {
    const cipher = new AesGcmCipher(await importAesKey(new Uint8Array(32)));
    const sealed = await cipher.seal(utf8('x'), 'notes/A.meta');
    expect(sealed.length).toBe(29);
    await expect(cipher.open(sealed, 'notes/B.meta')).rejects.toThrow();
    expect(fromUtf8(await cipher.open(sealed, 'notes/A.meta'))).toBe('x');
  });
});

describe('baseTag', () => {
  it('is 16 base32 characters and depends only on the etag', async () => {
    const a = await baseTag('5d41402abc4b2a76b9719d911017c592');
    expect(a).toMatch(/^[A-Z2-7]{16}$/);
    expect(await baseTag('5d41402abc4b2a76b9719d911017c592')).toBe(a);
    expect(await baseTag('other')).not.toBe(a);
  });
});
