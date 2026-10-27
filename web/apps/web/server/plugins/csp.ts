import { createHash } from 'node:crypto';
import { defineNitroPlugin } from 'nitropack/runtime';
import { loadConfig } from '../lib/config';
import { contentSecurityPolicy, metaContentSecurityPolicy } from '../lib/http';

const direct = loadConfig().mode === 'static';

/** Hashes the page's inline scripts into its CSP instead of allowing 'unsafe-inline'. */
export default defineNitroPlugin((nitroApp) => {
  nitroApp.hooks.hook('render:response', (response) => {
    if (typeof response.body !== 'string') return;
    const hashes: string[] = [];
    for (const m of response.body.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)) {
      if (/type="application\/json"/.test(m[0])) continue;
      hashes.push(createHash('sha256').update(m[1] ?? '').digest('base64'));
    }
    // The same page is the static client (release tarball): it carries its own policy for hosts without the header.
    const meta = `<meta http-equiv="Content-Security-Policy" content="${metaContentSecurityPolicy(hashes)}">`;
    response.body = response.body.replace(/<head([^>]*)>/, (m) => `${m}${meta}`);
    response.headers = { ...response.headers, 'content-security-policy': contentSecurityPolicy(hashes, direct) };
  });
});
