import type { InferSafeActionOutput } from '#safe-action';
import type { serverInfo, session } from '#safe-action/actions';
import type { ActionFailure } from '#shared/types';

export type SessionInfo = NonNullable<InferSafeActionOutput<typeof session>>;
export type ServerInfo = InferSafeActionOutput<typeof serverInfo>;

/** Any action result: `useAction`/`useFormAction` resolve one of these from `executeAsync()` and `submit()`. */
interface Result<T> {
  data?: T;
  /** Typed `{ code, message }` from the server; a plain string when the request itself failed or was cancelled. */
  serverError?: ActionFailure | string;
  businessError?: ActionFailure;
  validationErrors?: Record<string, string[]>;
}

/** The failure in a result, normalised to one `{ code, message }`; undefined when it succeeded. */
export function failureOf(r: Result<unknown>): ActionFailure | undefined {
  if (r.businessError) return r.businessError;
  if (typeof r.serverError === 'string') return { code: 'network', message: 'Could not reach the server.' };
  if (r.serverError) return r.serverError;
  if (r.validationErrors) {
    const first = Object.values(r.validationErrors).find((m) => m.length)?.[0];
    return { code: 'invalid', message: first ?? 'Check the highlighted fields.' };
  }
  return undefined;
}

export class ActionFailed extends Error {
  constructor(readonly failure: ActionFailure) {
    super(failure.message);
  }
}

/** For `useAsyncData` handlers: the data, or a throw so the failure lands in the query's `error`. */
export function unwrap<T>(r: Result<T>): T {
  const failure = failureOf(r);
  if (failure) throw new ActionFailed(failure);
  return r.data as T;
}
