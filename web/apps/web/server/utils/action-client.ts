import type { H3Event } from 'h3';
import { setResponseStatus } from 'h3';
import { createSafeActionClient } from '#safe-action';
import { ApiFailure } from '../lib/accounts';
import { sessionUser } from '../lib/auth';
import { type ServerContext, serverContext } from '../lib/context';
import { checkActionCsrf } from '../lib/http';
import type { ActionFailure } from '../../shared/types';

/**
 * The control plane (setup, sessions, account, admin) is a set of safe actions under server/actions, served at
 * /api/_actions/<name>. The sync data plane (/api/storage, /s3) stays plain routes: it moves opaque ciphertext with
 * ETags and conditional headers, which is a blob store, not a JSON RPC.
 *
 * Clients layer:  publicClient (CSRF) → authClient (ctx.user) → adminClient (role check).
 * Failures the client branches on everywhere (unauthorized, passwordChangeRequired, forbidden) come from the
 * middleware as a typed `serverError: { code, message }`; failures specific to one action are declared on it
 * with `.errors()` and raised with `fail()`.
 */

export type { ActionFailure } from '../../shared/types';

/** Metadata an action can set; read by the middleware below. */
export interface ActionMeta {
  /** Let an account that must change its password through (the change-password flow itself, sign-out). */
  allowPasswordChange?: boolean;
}

/** The test harness injects its own context; under Nitro it is the process-wide one opened at startup. */
export function useServerContext(event: H3Event): Promise<ServerContext> {
  const injected = event.context.noteit as ServerContext | undefined;
  return injected ? Promise.resolve(injected) : serverContext();
}

const baseClient = createSafeActionClient<ActionFailure>({
  handleServerError(error) {
    if (error instanceof ApiFailure) return { code: error.code, message: error.message };
    console.error('[noteit] action failed:', error);
    return { code: 'internal', message: 'Something went wrong. Try again.' };
  },
});

/** Every action: the server context in `ctx.noteit`, and CSRF refused before any input reaches a handler. */
export const publicClient = baseClient.use(async ({ event, next }) => {
  const noteit = await useServerContext(event);
  try {
    checkActionCsrf(event, noteit.cfg);
  } catch (e) {
    // A forged request gets a real 403/415, not a 200 envelope: no legitimate client ever sees this.
    if (e instanceof ApiFailure) setResponseStatus(event, e.status);
    throw e;
  }
  return next({ ctx: { noteit } });
});

/** Signed-in account in `ctx.user`, re-checked against accounts.json on every call. */
export const authClient = publicClient.use(async ({ ctx, event, metadata, next }) => {
  const user = sessionUser(event, ctx.noteit);
  if (!user) throw new ApiFailure(401, 'unauthorized', 'Sign in again.');
  if (user.mustChangePassword && !(metadata as ActionMeta).allowPasswordChange) {
    throw new ApiFailure(403, 'passwordChangeRequired', 'Choose a new password first.');
  }
  return next({ ctx: { ...ctx, user } });
});

export const adminClient = authClient.use(async ({ ctx, next }) => {
  if (ctx.user.role !== 'admin') throw new ApiFailure(403, 'forbidden', 'Admins only.');
  return next({ ctx });
});
