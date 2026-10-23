import { createHash } from 'node:crypto';
import { defineNitroPlugin } from 'nitropack/runtime';
import { contentSecurityPolicy } from '../lib/http';

/** Hashes the page's inline scripts into its CSP instead of allowing 'unsafe-inline'. */
export default defineNitroPlugin((nitroApp) => {
  nitroApp.hooks.hook('render:response', (response) => {
    if (typeof response.body !== 'string') return;
    const hashes: string[] = [];
    for (const m of response.body.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)) {
      if (/type="application\/json"/.test(m[0])) continue;
      hashes.push(createHash('sha256').update(m[1] ?? '').digest('base64'));
    }
    response.headers = { ...response.headers, 'content-security-policy': contentSecurityPolicy(hashes) };
  });
});
