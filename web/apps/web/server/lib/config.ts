import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export interface UpstreamS3Config {
  endpoint: string;
  region: string;
  bucket: string;
  prefix: string;
  pathStyle: boolean;
  accessKeyId: string;
  secretAccessKey: string;
}

export interface ServerConfig {
  /** Where user stores live: the data directory, or an upstream S3 bucket (spec §6.2). */
  store: 'disk' | 's3';
  s3: UpstreamS3Config | undefined;
  /** Timeout of each upstream store request. */
  storeTimeoutMs: number;
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

function required(env: NodeJS.ProcessEnv, name: string): string {
  const v = secret(env, name);
  if (!v) throw new Error(`${name} is required when NOTEIT_STORE=s3`);
  return v;
}

function upstreamS3(env: NodeJS.ProcessEnv): UpstreamS3Config {
  const endpoint = required(env, 'NOTEIT_S3_ENDPOINT');
  if (!/^https?:\/\//.test(endpoint)) throw new Error('NOTEIT_S3_ENDPOINT must be an http(s) URL');
  return {
    endpoint,
    region: env.NOTEIT_S3_REGION || 'us-east-1',
    bucket: required(env, 'NOTEIT_S3_BUCKET'),
    prefix: env.NOTEIT_S3_PREFIX ?? '',
    pathStyle: env.NOTEIT_S3_PATH_STYLE !== 'false',
    accessKeyId: required(env, 'NOTEIT_S3_ACCESS_KEY_ID'),
    secretAccessKey: required(env, 'NOTEIT_S3_SECRET_ACCESS_KEY'),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  const store = env.NOTEIT_STORE || 'disk';
  if (store !== 'disk' && store !== 's3') throw new Error(`NOTEIT_STORE must be disk or s3, not ${JSON.stringify(store)}`);
  return {
    store,
    s3: store === 's3' ? upstreamS3(env) : undefined,
    storeTimeoutMs: Math.max(1, int(env.NOTEIT_STORE_TIMEOUT_S, 120)) * 1000,
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
