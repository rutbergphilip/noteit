import { CANARY_PREFIX, newUuid, type S3Backend, StorageError, utf8 } from '@noteit/core';

/**
 * The connect wizard's check before anything is saved (spec §6.4). A CORS rejection reaches script as a TypeError
 * with no status (`network` here), so each step names what its failure means.
 */
export type CorsProblem = 'originNotAllowed' | 'putNotAllowed' | 'conditionalNotAllowed' | 'etagNotExposed' | 'unauthorized' | 'clockSkew' | 'bucket' | 'other';

export const CORS_HINTS: Record<CorsProblem, string> = {
  originNotAllowed: "The bucket didn't answer this page: origin not allowed. Add this site's address to the bucket's CORS rules, or check the endpoint.",
  putNotAllowed: 'Listing works, but uploading was refused: PUT or If-None-Match not allowed. Allow PUT, HEAD and DELETE and the request headers listed below in the CORS rules.',
  conditionalNotAllowed: 'Uploads work, but a DELETE or a conditional request was refused: DELETE or If-Match not allowed. Allow DELETE and the if-match header in the CORS rules, and make sure refusals carry the CORS headers too.',
  etagNotExposed: 'Uploads work, but the browser can’t read the ETag: ETag not exposed. Add ETag to the CORS rules’ exposed headers.',
  unauthorized: 'The bucket refused the access key. Check the key, its secret and that it may read, write, delete and list this bucket.',
  clockSkew: "This device's clock is too far off for S3 to accept requests. Set the clock automatically and try again.",
  bucket: "That bucket or endpoint doesn't look right. Check the endpoint URL, the bucket name, the region and path-style.",
  other: "The bucket answered in a way NoteIt didn't expect.",
};

export type CorsResult = { ok: true; writes: boolean; deletes: boolean } | { ok: false; problem: CorsProblem; hint: string; detail: string };

function problemOf(e: unknown, onNetwork: CorsProblem): CorsProblem {
  if (!(e instanceof StorageError)) return 'other';
  if (e.kind === 'network') return onNetwork;
  if (e.kind === 'unauthorized') return 'unauthorized';
  if (e.kind === 'clockSkew') return 'clockSkew';
  if (e.kind === 'notFound') return 'bucket';
  return 'other';
}

const failed = (problem: CorsProblem, e: unknown): CorsResult => ({ ok: false, problem, hint: CORS_HINTS[problem], detail: e instanceof Error ? e.message : String(e) });

export async function corsCheck(backend: S3Backend): Promise<CorsResult> {
  // 1. ListObjectsV2 on the prefix: the origin is allowed and the credentials work.
  try {
    await backend.probe();
  } catch (e) {
    return failed(problemOf(e, 'originNotAllowed'), e);
  }
  // 2. A canary PUT with If-None-Match, reading the ETag header: PUT, the request headers and the exposed ETag.
  const key = `${CANARY_PREFIX}${newUuid()}`;
  try {
    let etag: string;
    try {
      etag = await backend.putExposingETag(key, utf8('cors-check'));
    } catch (e) {
      return failed(problemOf(e, 'putNotAllowed'), e);
    }
    if (!etag) return failed('etagNotExposed', new StorageError('invalidResponse', 'ETag not exposed'));
  } finally {
    await backend.delete(key).catch(() => undefined);
  }
  // 3. The rest of the canary: which conditional requests the provider honours.
  await backend.verifyConditionals();
  if (!backend.conditionalsChecked) return failed('conditionalNotAllowed', new StorageError('network', 'the conditional request check could not finish'));
  return { ok: true, ...backend.capabilities };
}
