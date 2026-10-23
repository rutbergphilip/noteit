import { defineEventHandler } from 'h3';
import { loadConfig } from '../lib/config';
import { securityHeaders } from '../lib/http';

const cfg = loadConfig();

/** CSP and the other security headers on every response, including the SPA's static files. */
export default defineEventHandler((event) => {
  securityHeaders(event, cfg);
});
