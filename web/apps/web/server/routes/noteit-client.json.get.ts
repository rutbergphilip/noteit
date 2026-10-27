import { defineEventHandler, setResponseHeader } from 'h3';
import { loadConfig } from '../lib/config';
import { clientConfigFor } from '../lib/staticMode';

const cfg = loadConfig();

/** The client's runtime configuration, from NOTEIT_MODE: `direct` in static mode, `server` otherwise. */
export default defineEventHandler((event) => {
  setResponseHeader(event, 'Cache-Control', 'no-store');
  return clientConfigFor(cfg);
});
