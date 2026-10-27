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

/** OpenID Connect sign-in (spec §7.2); set when NOTEIT_OIDC_ISSUER is. */
export interface OidcConfig {
  issuer: string;
  clientId: string;
  clientSecret: string | undefined;
  redirectUrl: string;
  scopes: string;
  label: string;
  /** Dot path into the ID token (or userinfo) claims. */
  groupsClaim: string;
  autoProvision: boolean;
  allowedGroups: string[];
  adminGroups: string[];
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
  oidc: OidcConfig | undefined;
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

const list = (v: string | undefined) => (v ?? '').split(',').map((g) => g.trim()).filter(Boolean);

/** The issuer must be HTTPS, except on this machine (a test or a local IdP). */
function isLoopback(url: URL): boolean {
  return ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
}

function oidcConfig(env: NodeJS.ProcessEnv, publicUrl: string | undefined): OidcConfig | undefined {
  const issuer = env.NOTEIT_OIDC_ISSUER?.trim();
  if (!issuer) return undefined;
  let url: URL;
  try {
    url = new URL(issuer);
  } catch {
    throw new Error('NOTEIT_OIDC_ISSUER must be a URL');
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && isLoopback(url))) throw new Error('NOTEIT_OIDC_ISSUER must be an https:// URL');
  const clientId = secret(env, 'NOTEIT_OIDC_CLIENT_ID');
  if (!clientId) throw new Error('NOTEIT_OIDC_CLIENT_ID is required when NOTEIT_OIDC_ISSUER is set');
  const redirectUrl = env.NOTEIT_OIDC_REDIRECT_URL || (publicUrl ? `${publicUrl}/api/oidc/callback` : '');
  if (!redirectUrl) throw new Error('Set NOTEIT_PUBLIC_URL (or NOTEIT_OIDC_REDIRECT_URL) to use OIDC sign-in');
  const autoProvision = env.NOTEIT_OIDC_AUTO_PROVISION === 'true';
  const allowedGroups = list(env.NOTEIT_OIDC_ALLOWED_GROUPS);
  // Never "anyone the identity provider knows".
  if (autoProvision && !allowedGroups.length) throw new Error('NOTEIT_OIDC_AUTO_PROVISION=true needs NOTEIT_OIDC_ALLOWED_GROUPS');
  return {
    issuer,
    clientId,
    clientSecret: secret(env, 'NOTEIT_OIDC_CLIENT_SECRET'),
    redirectUrl,
    scopes: env.NOTEIT_OIDC_SCOPES?.trim() || 'openid profile',
    label: env.NOTEIT_OIDC_LABEL?.trim() || 'Single Sign-On',
    groupsClaim: env.NOTEIT_OIDC_GROUPS_CLAIM?.trim() || 'groups',
    autoProvision,
    allowedGroups,
    adminGroups: list(env.NOTEIT_OIDC_ADMIN_GROUPS),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  const store = env.NOTEIT_STORE || 'disk';
  const publicUrl = env.NOTEIT_PUBLIC_URL?.replace(/\/$/, '') || undefined;
  const oidc = oidcConfig(env, publicUrl);
  const passwordLogin = env.NOTEIT_PASSWORD_LOGIN !== 'false';
  if (!passwordLogin && !oidc) throw new Error('NOTEIT_PASSWORD_LOGIN=false needs OIDC sign-in (NOTEIT_OIDC_ISSUER)');
  if (store !== 'disk' && store !== 's3') throw new Error(`NOTEIT_STORE must be disk or s3, not ${JSON.stringify(store)}`);
  return {
    store,
    s3: store === 's3' ? upstreamS3(env) : undefined,
    storeTimeoutMs: Math.max(1, int(env.NOTEIT_STORE_TIMEOUT_S, 120)) * 1000,
    dataDir: resolve(env.NOTEIT_DATA_DIR || '/data'),
    publicUrl,
    setupToken: secret(env, 'NOTEIT_SETUP_TOKEN'),
    sessionSecret: secret(env, 'NOTEIT_SESSION_SECRET'),
    adminUsername: env.NOTEIT_ADMIN_USERNAME || 'admin',
    passwordLogin,
    oidc,
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
