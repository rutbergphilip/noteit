import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export interface ServerConfig {
  dataDir: string;
  publicUrl: string | undefined;
  setupToken: string | undefined;
  sessionSecret: string | undefined;
  adminUsername: string;
  passwordLogin: boolean;
  defaultQuotaBytes: number;
  defaultMaxObjects: number;
  maxObjectBytes: number;
  inviteTtlHours: number;
  sourceUrl: string;
  version: string;
  commit: string;
  /** Behind a reverse proxy that sets X-Forwarded-For. */
  trustProxy: boolean;
  /** How many reverse proxies append to X-Forwarded-For; the client is that many entries from the right. */
  trustedProxyHops: number;
}

/** `NAME` or the contents of the file named by `NAME_FILE`. */
function secret(env: NodeJS.ProcessEnv, name: string): string | undefined {
  const file = env[`${name}_FILE`];
  if (file) return readFileSync(file, 'utf8').trim();
  return env[name] || undefined;
}

const int = (v: string | undefined, d: number) => (v && /^\d+$/.test(v) ? Number(v) : d);

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  return {
    dataDir: resolve(env.NOTEIT_DATA_DIR || '/data'),
    publicUrl: env.NOTEIT_PUBLIC_URL?.replace(/\/$/, '') || undefined,
    setupToken: secret(env, 'NOTEIT_SETUP_TOKEN'),
    sessionSecret: secret(env, 'NOTEIT_SESSION_SECRET'),
    adminUsername: env.NOTEIT_ADMIN_USERNAME || 'admin',
    passwordLogin: env.NOTEIT_PASSWORD_LOGIN !== 'false',
    defaultQuotaBytes: int(env.NOTEIT_DEFAULT_QUOTA_MB, 10240) * 1024 * 1024,
    defaultMaxObjects: int(env.NOTEIT_DEFAULT_MAX_OBJECTS, 100_000),
    maxObjectBytes: int(env.NOTEIT_MAX_OBJECT_MB, 50) * 1024 * 1024,
    inviteTtlHours: int(env.NOTEIT_INVITE_TTL_HOURS, 72),
    sourceUrl: env.NOTEIT_SOURCE_URL || 'https://github.com/rutbergphilip/noteit',
    version: env.NOTEIT_VERSION || '0.1.0',
    commit: env.NOTEIT_COMMIT || 'dev',
    trustProxy: env.NOTEIT_TRUST_PROXY === 'true',
    trustedProxyHops: Math.max(1, int(env.NOTEIT_TRUSTED_PROXY_HOPS, 1)),
  };
}
