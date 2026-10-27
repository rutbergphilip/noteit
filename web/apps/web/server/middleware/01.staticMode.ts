import { defineEventHandler } from 'h3';
import { loadConfig } from '../lib/config';
import { staticModeResponse } from '../lib/staticMode';

const cfg = loadConfig();

/** NOTEIT_MODE=static: only the client's files and the health routes (spec §6.4). */
export default defineEventHandler((event) => {
  if (cfg.mode === 'static') return staticModeResponse(event);
});
