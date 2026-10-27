import { unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { deleteCookie, getCookie, getRequestURL, type H3Event, setCookie, setResponseHeader } from 'h3';
import * as oidc from 'openid-client';
import type { OidcErrorCode, OidcIntent } from '../../shared/oidc';
import { type AccountsFile, ApiFailure, removesLastAdmin, type User, USERNAME_RE } from './accounts';
import { issueSession, newUser } from './auth';
import type { OidcConfig } from './config';
import type { ServerContext } from './context';
import { isHttps } from './http';

export const OIDC_COOKIE = 'noteit_oidc';
const FLOW_TTL_S = 600;
const SEAL_PURPOSE = 'oidc-flow';

/** What `start` keeps in the encrypted `noteit_oidc` cookie until the callback. */
interface Flow {
  state: string;
  nonce: string;
  verifier: string;
  intent: OidcIntent;
  /** link: the signed-in account and its session epoch (the Strict session cookie isn't sent to the callback). */
  uid?: string;
  epoch?: number;
  /** invite: the invite (by token hash) and the username chosen for it, if any. */
  inviteSha?: string;
  username?: string;
  /** setup: the bootstrap token, re-checked when the admin is created. */
  setupToken?: string;
}

export type FlowInit = Omit<Flow, 'state' | 'nonce' | 'verifier'>;

class OidcOutcome extends Error {
  constructor(readonly code: OidcErrorCode) {
    super(code);
  }
}

const isLoopback = (url: URL) => ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);

/** The value at a dot path (`realm_access.roles`), as a list of strings. */
export function claimList(claims: Record<string, unknown>, path: string): string[] | undefined {
  let v: unknown = claims;
  for (const part of path.split('.')) {
    if (!v || typeof v !== 'object') return undefined;
    v = (v as Record<string, unknown>)[part];
  }
  if (typeof v === 'string') return [v];
  if (Array.isArray(v)) return v.filter((x): x is string => typeof x === 'string');
  return undefined;
}

/** A free username suggested by the claims (never used to find an account). */
export function suggestUsername(claims: Record<string, unknown>, taken: (name: string) => boolean): string {
  const raw = [claims.preferred_username, typeof claims.email === 'string' ? claims.email.split('@')[0] : undefined, claims.name].find((c): c is string => typeof c === 'string' && !!c.trim());
  let base = (raw ?? 'user')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^[^a-z0-9]+/, '')
    .slice(0, 28);
  if (!USERNAME_RE.test(base)) base = 'user';
  if (!taken(base)) return base;
  for (let n = 2; ; n++) if (!taken(`${base}-${n}`)) return `${base}-${n}`;
}

/** OpenID Connect sign-in (spec §7.2): authorization code + PKCE (S256), `state` and `nonce`, users by `(iss, sub)`. */
export class OidcProvider {
  private configuration: Promise<oidc.Configuration> | undefined;

  constructor(
    readonly cfg: OidcConfig,
    private readonly log: (msg: string) => void,
  ) {}

  /** The discovery document, fetched once (and again after a failure). */
  discover(): Promise<oidc.Configuration> {
    this.configuration ??= (async () => {
      const issuer = new URL(this.cfg.issuer);
      const insecure = issuer.protocol === 'http:' && isLoopback(issuer);
      return oidc.discovery(issuer, this.cfg.clientId, this.cfg.clientSecret, undefined, {
        ...(insecure ? { execute: [oidc.allowInsecureRequests] } : {}),
        timeout: 10,
      });
    })();
    this.configuration.catch(() => (this.configuration = undefined));
    return this.configuration;
  }

  /** Creates the flow state in the encrypted cookie and returns the identity provider URL to navigate to. */
  async start(event: H3Event, ctx: ServerContext, init: FlowInit): Promise<string> {
    let config: oidc.Configuration;
    try {
      config = await this.discover();
    } catch (e) {
      this.log(`NoteIt OIDC: discovery failed: ${(e as Error).message}`);
      throw new ApiFailure(502, 'oidcUnavailable', "The identity provider can't be reached. Try again shortly.");
    }
    const flow: Flow = { ...init, state: oidc.randomState(), nonce: oidc.randomNonce(), verifier: oidc.randomPKCECodeVerifier() };
    setCookie(event, OIDC_COOKIE, ctx.sessions.seal(SEAL_PURPOSE, flow, FLOW_TTL_S), {
      httpOnly: true,
      secure: isHttps(event, ctx.cfg),
      sameSite: 'lax',
      path: '/api/oidc',
      maxAge: FLOW_TTL_S,
    });
    return oidc
      .buildAuthorizationUrl(config, {
        redirect_uri: this.cfg.redirectUrl,
        scope: this.cfg.scopes,
        response_type: 'code',
        code_challenge: await oidc.calculatePKCECodeChallenge(flow.verifier),
        code_challenge_method: 'S256',
        state: flow.state,
        nonce: flow.nonce,
      })
      .toString();
  }

  /**
   * GET /api/oidc/callback. Always answers with a small same-origin page that moves on to the app (no script), so the
   * Strict session cookie set here is sent on the next, same-site request.
   */
  async callback(event: H3Event, ctx: ServerContext): Promise<string> {
    const flow = ctx.sessions.unseal<Flow>(SEAL_PURPOSE, getCookie(event, OIDC_COOKIE));
    deleteCookie(event, OIDC_COOKIE, { path: '/api/oidc' });
    let target: string;
    try {
      target = await this.finish(event, ctx, flow);
    } catch (e) {
      const code: OidcErrorCode = e instanceof OidcOutcome ? e.code : 'failed';
      if (!(e instanceof OidcOutcome)) this.log(`NoteIt OIDC: sign-in failed: ${e instanceof Error ? e.message : String(e)}`);
      target = `/#oidc-error=${code}`;
    }
    setResponseHeader(event, 'Content-Type', 'text/html; charset=utf-8');
    setResponseHeader(event, 'Cache-Control', 'no-store');
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=${target}"><title>NoteIt</title></head><body><p><a href="${target}">Continue to NoteIt</a></p></body></html>`;
  }

  private async finish(event: H3Event, ctx: ServerContext, flow: Flow | undefined): Promise<string> {
    const url = getRequestURL(event);
    if (url.searchParams.get('error')) throw new OidcOutcome(url.searchParams.get('error') === 'access_denied' ? 'denied' : 'failed');
    if (!flow) throw new OidcOutcome('expired');
    let config: oidc.Configuration;
    try {
      config = await this.discover();
    } catch {
      throw new OidcOutcome('unavailable');
    }
    // The registered redirect URL with this request's query: the token request must name exactly that URL.
    const current = new URL(this.cfg.redirectUrl);
    current.search = url.search;
    const tokens = await oidc.authorizationCodeGrant(config, current, {
      pkceCodeVerifier: flow.verifier,
      expectedState: flow.state,
      expectedNonce: flow.nonce,
      idTokenExpected: true,
    });
    const claims = tokens.claims() as (Record<string, unknown> & { iss: string; sub: string }) | undefined;
    if (!claims) throw new OidcOutcome('failed');
    let groups = claimList(claims, this.cfg.groupsClaim);
    if (!groups && (this.cfg.adminGroups.length || this.cfg.allowedGroups.length)) {
      try {
        groups = claimList(await oidc.fetchUserInfo(config, tokens.access_token, claims.sub), this.cfg.groupsClaim);
      } catch (e) {
        this.log(`NoteIt OIDC: userinfo failed: ${(e as Error).message}`);
      }
    }
    const identity = { issuer: claims.iss, sub: claims.sub };
    const linked = (f: AccountsFile) => f.users.find((u) => u.oidc?.issuer === identity.issuer && u.oidc.sub === identity.sub);
    const displayName = (typeof claims.name === 'string' && claims.name.trim().slice(0, 64)) || undefined;
    const inGroups = (wanted: string[]) => !!groups?.some((g) => wanted.includes(g));

    switch (flow.intent) {
      case 'login': {
        const user = await ctx.accounts.mutate((f) => {
          // Before first-admin setup only the setup intent (with the token) creates an account, even from a flow
          // cookie minted earlier.
          if (f.users.length === 0) throw new OidcOutcome('setupRequired');
          let u = linked(f);
          if (!u) {
            if (!this.cfg.autoProvision || !inGroups(this.cfg.allowedGroups)) throw new OidcOutcome('notLinked');
            const username = suggestUsername(claims, (n) => f.users.some((x) => x.username === n));
            u = newUser(ctx, { username, displayName: displayName ?? username, role: 'user', passwordHash: undefined }, { oidc: identity });
            f.users.push(u);
          }
          if (u.status !== 'active') throw new OidcOutcome('disabled');
          this.applyAdminGroups(f, u, groups);
          u.lastSeenAt = new Date().toISOString();
          return u;
        });
        issueSession(event, ctx, user);
        return '/';
      }
      case 'link': {
        const user = await ctx.accounts.mutate((f) => {
          const u = f.users.find((x) => x.id === flow.uid);
          if (!u || u.status !== 'active' || u.sessionEpoch !== flow.epoch) throw new OidcOutcome('expired');
          const other = linked(f);
          if (other && other.id !== u.id) throw new OidcOutcome('alreadyLinked');
          u.oidc = identity;
          return u;
        });
        this.log(`NoteIt OIDC: ${user.username} linked a sign-in from ${identity.issuer}`);
        return '/#oidc-linked';
      }
      case 'invite': {
        const user = await ctx.accounts.mutate((f) => {
          if (f.users.length === 0) throw new OidcOutcome('setupRequired');
          const invite = f.invites.find((i) => i.tokenSha256 === flow.inviteSha);
          if (!invite || invite.usedAt || invite.revokedAt || Date.parse(invite.expiresAt) < Date.now()) throw new OidcOutcome('inviteInvalid');
          if (linked(f)) throw new OidcOutcome('alreadyLinked');
          const taken = (n: string) => f.users.some((x) => x.username === n);
          if (flow.username && taken(flow.username)) throw new OidcOutcome('usernameTaken');
          const username = flow.username || suggestUsername(claims, taken);
          const u = newUser(
            ctx,
            { username, displayName: displayName ?? username, role: invite.role, passwordHash: undefined },
            { oidc: identity, ...(invite.quotaBytes ? { quotaBytes: invite.quotaBytes } : {}), ...(invite.maxObjects ? { maxObjects: invite.maxObjects } : {}) },
          );
          f.users.push(u);
          invite.usedAt = new Date().toISOString();
          invite.usedBy = u.id;
          return u;
        });
        issueSession(event, ctx, user);
        return '/';
      }
      case 'setup': {
        // The token proves control of the server, so the allowed-groups rule doesn't apply.
        const user = await ctx.accounts.mutate((f) => {
          if (f.users.length > 0 || !ctx.bootstrap.matches(flow.setupToken)) throw new OidcOutcome('setupDone');
          const username = flow.username || suggestUsername(claims, () => false);
          const u = newUser(ctx, { username, displayName: displayName ?? username, role: 'admin', passwordHash: undefined }, { oidc: identity });
          f.users.push(u);
          return u;
        });
        ctx.bootstrap.consume();
        await unlink(join(ctx.cfg.dataDir, 'setup-token')).catch(() => undefined);
        issueSession(event, ctx, user);
        return '/';
      }
    }
  }

  /** With NOTEIT_OIDC_ADMIN_GROUPS, each OIDC sign-in sets the role from the groups claim; never demotes the last admin. */
  private applyAdminGroups(f: AccountsFile, u: User, groups: string[] | undefined): void {
    if (!this.cfg.adminGroups.length) return;
    const role = groups?.some((g) => this.cfg.adminGroups.includes(g)) ? 'admin' : 'user';
    if (role === u.role) return;
    if (role === 'user' && removesLastAdmin(f, { userId: u.id, role: 'user' })) {
      this.log(`NoteIt OIDC: kept ${u.username} an admin: removing the role would leave no active admin`);
      return;
    }
    u.role = role;
  }
}

