// The upstream S3 driver against a real S3-compatible server. Skipped unless NOTEIT_LIVE_S3_ENDPOINT is set:
//   NOTEIT_LIVE_S3_ENDPOINT=http://127.0.0.1:4566 NOTEIT_LIVE_S3_BUCKET=noteit-live \
//   NOTEIT_LIVE_S3_ACCESS_KEY_ID=… NOTEIT_LIVE_S3_SECRET_ACCESS_KEY=… pnpm --filter @noteit/web test s3Store.live
// The bucket must exist. Each run uses a fresh prefix and deletes what it wrote.
import { randomUUID } from 'node:crypto';
import { fromUtf8, utf8 } from '@noteit/core';
import { describe, expect, it } from 'vitest';
import { S3Store } from '../../server/lib/s3Store';

const env = process.env;
const live = env.NOTEIT_LIVE_S3_ENDPOINT;
const USER = randomUUID().toUpperCase();

describe.skipIf(!live)('S3Store against a live S3 endpoint', () => {
  const store = () =>
    new S3Store(
      {
        endpoint: live!,
        region: env.NOTEIT_LIVE_S3_REGION || 'us-east-1',
        bucket: env.NOTEIT_LIVE_S3_BUCKET || 'noteit-live',
        prefix: `noteit-live-${Date.now()}`,
        pathStyle: env.NOTEIT_LIVE_S3_PATH_STYLE !== 'false',
        accessKeyId: env.NOTEIT_LIVE_S3_ACCESS_KEY_ID || 'test',
        secretAccessKey: env.NOTEIT_LIVE_S3_SECRET_ACCESS_KEY || 'test',
        timeoutMs: 10_000,
      },
      () => undefined,
    );

  it('passes the startup canary and round-trips objects with conditional requests', async () => {
    const s = store();
    try {
      await s.init();
      expect(s.started()).toBe(true);
      const key = 'noteit/v1/manifest.json';
      const put = await s.put(USER, key, utf8('one'), { ifNoneMatch: true });
      if (put === 'preconditionFailed') throw new Error('create refused');
      expect(await s.put(USER, key, utf8('two'), { ifNoneMatch: true })).toBe('preconditionFailed');
      const second = await s.put(USER, key, utf8('two'), { ifMatch: put.etag });
      if (second === 'preconditionFailed') throw new Error('update refused');
      expect(second.etag).not.toBe(put.etag);
      expect(fromUtf8((await s.get(USER, key))!.data)).toBe('two');
      expect((await s.list(USER, 'noteit/')).map((o) => o.key)).toEqual([key]);
      expect(await s.delete(USER, key, { ifMatch: put.etag })).toBe('preconditionFailed');
      expect(await s.delete(USER, key, { ifMatch: second.etag })).toBe('ok');
      expect(await s.list(USER, 'noteit/')).toEqual([]);
    } finally {
      await s.deleteNamespace(USER).catch(() => undefined);
      s.close();
    }
  });
});
