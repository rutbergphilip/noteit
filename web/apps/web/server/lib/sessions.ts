import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';
import { readIfExists, writeFileAtomic } from './files';

export const SESSION_COOKIE = 'noteit_session';
export const SESSION_TTL_S = 30 * 24 * 3600;

export interface SessionPayload {
  uid: string;
  epoch: number;
  iat: number;
  exp: number;
}

/** HMAC-signed cookie values. The secret comes from NOTEIT_SESSION_SECRET or /data/session-secret (generated). */
export class SessionSigner {
  private constructor(private readonly secret: Buffer) {}

  static async create(dataDir: string, configured: string | undefined): Promise<SessionSigner> {
    if (configured) return new SessionSigner(Buffer.from(configured));
    const path = join(dataDir, 'session-secret');
    let secret = await readIfExists(path);
    if (!secret) {
      secret = randomBytes(32).toString('base64url');
      await writeFileAtomic(path, secret);
    }
    return new SessionSigner(Buffer.from(secret.trim()));
  }

  sign(p: SessionPayload): string {
    const body = Buffer.from(JSON.stringify(p)).toString('base64url');
    const mac = createHmac('sha256', this.secret).update(body).digest('base64url');
    return `${body}.${mac}`;
  }

  verify(value: string | undefined, nowS = Math.floor(Date.now() / 1000)): SessionPayload | undefined {
    if (!value) return undefined;
    const [body, mac] = value.split('.');
    if (!body || !mac) return undefined;
    const expected = createHmac('sha256', this.secret).update(body).digest();
    const given = Buffer.from(mac, 'base64url');
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return undefined;
    try {
      const p = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as SessionPayload;
      if (typeof p.uid !== 'string' || typeof p.exp !== 'number' || p.exp <= nowS) return undefined;
      return p;
    } catch {
      return undefined;
    }
  }
}

/** Fixed-window limiter keyed by caller-chosen strings (IP, IP+username). */
export class RateLimiter {
  private readonly hits = new Map<string, { count: number; resetAt: number }>();
  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  /** Returns seconds to wait when over the limit, else 0 (and counts the hit). */
  hit(key: string, now = Date.now()): number {
    const entry = this.hits.get(key);
    if (!entry || entry.resetAt <= now) {
      this.hits.set(key, { count: 1, resetAt: now + this.windowMs });
      if (this.hits.size > 10_000) for (const [k, v] of this.hits) if (v.resetAt <= now) this.hits.delete(k);
      return 0;
    }
    entry.count += 1;
    return entry.count > this.limit ? Math.ceil((entry.resetAt - now) / 1000) : 0;
  }

  reset(key: string): void {
    this.hits.delete(key);
  }
}

/** The single-use setup token: NOTEIT_SETUP_TOKEN[_FILE], else /data/setup-token, else generated and logged once. */
export class BootstrapToken {
  private token: string | undefined;
  constructor(
    private readonly dataDir: string,
    private readonly configured: string | undefined,
  ) {}

  async load(needed: boolean, log: (msg: string) => void): Promise<void> {
    if (!needed) return;
    if (this.configured) {
      this.token = this.configured;
      return;
    }
    const path = join(this.dataDir, 'setup-token');
    let token = (await readIfExists(path))?.trim();
    if (!token) {
      token = randomBytes(24).toString('base64url');
      await writeFileAtomic(path, token);
      log(`NoteIt setup token (first admin only): ${token}`);
      log(`It is also stored in ${path}.`);
    }
    this.token = token;
  }

  matches(candidate: unknown): boolean {
    if (!this.token || typeof candidate !== 'string') return false;
    const a = Buffer.from(createHmac('sha256', 'cmp').update(candidate).digest());
    const b = Buffer.from(createHmac('sha256', 'cmp').update(this.token).digest());
    return timingSafeEqual(a, b);
  }

  consume(): void {
    this.token = undefined;
  }
}
