import type { H3Event } from 'h3';

export class BodyTooLarge extends Error {}

/**
 * Reads the request body with a running byte count. A declared Content-Length above `max` is refused before any
 * byte is read; a chunked or under-declared body is cut off (and the socket's request stream destroyed) as soon as
 * it passes `max`. Callers authenticate before calling this, so an anonymous client can't make the server buffer.
 */
export function readBodyLimited(event: H3Event, max: number): Promise<Uint8Array> {
  const req = event.node.req;
  const declared = req.headers['content-length'];
  if (declared !== undefined && (!/^\d+$/.test(declared) || Number(declared) > max)) return Promise.reject(new BodyTooLarge());
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    let done = false;
    const finish = (err?: Error) => {
      if (done) return;
      done = true;
      req.off('data', onData);
      req.off('end', onEnd);
      req.off('error', onError);
      if (err) reject(err);
      else resolve(new Uint8Array(Buffer.concat(chunks, total)));
    };
    const onData = (chunk: Buffer) => {
      total += chunk.length;
      if (total > max) {
        chunks.length = 0;
        req.pause();
        finish(new BodyTooLarge());
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => finish();
    const onError = (e: Error) => finish(e);
    req.on('data', onData);
    req.on('end', onEnd);
    req.on('error', onError);
  });
}
