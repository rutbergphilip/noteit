/**
 * `noteit-client.json`, the only runtime configuration of the client (spec §6.4): `{"mode": "server"}` (served by the
 * NoteIt server) or `{"mode": "direct", "sourceUrl"?: "https://…"}` (the static client, syncing straight to S3).
 * Validated strictly: anything else and the app starts nothing.
 */
export type ClientConfig = { mode: 'server' } | { mode: 'direct'; sourceUrl?: string };

export class ClientConfigError extends Error {
  /** The file couldn't be fetched at all (the server is down), as opposed to missing or wrong. */
  constructor(
    message: string,
    readonly network = false,
  ) {
    super(message);
  }
}

export function parseClientConfig(raw: unknown): ClientConfig {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new ClientConfigError('noteit-client.json must be a JSON object');
  const obj = raw as Record<string, unknown>;
  for (const key of Object.keys(obj)) if (key !== 'mode' && key !== 'sourceUrl') throw new ClientConfigError(`noteit-client.json has an unknown key ${JSON.stringify(key)}`);
  if (obj.mode === 'server') {
    if ('sourceUrl' in obj) throw new ClientConfigError('sourceUrl is only for "direct" mode; the server sets its own');
    return { mode: 'server' };
  }
  if (obj.mode !== 'direct') throw new ClientConfigError(`noteit-client.json has an unknown mode ${JSON.stringify(obj.mode)}`);
  if (obj.sourceUrl === undefined) return { mode: 'direct' };
  if (typeof obj.sourceUrl !== 'string' || !/^https:\/\/[^\s]+$/.test(obj.sourceUrl)) throw new ClientConfigError('sourceUrl must be an https:// URL');
  return { mode: 'direct', sourceUrl: obj.sourceUrl };
}

/** Fetches and checks it; a missing file is an error too. */
export async function loadClientConfig(fetchImpl: typeof fetch = fetch): Promise<ClientConfig> {
  let res: Response;
  try {
    res = await fetchImpl('/noteit-client.json', { cache: 'no-store', credentials: 'omit' });
  } catch {
    throw new ClientConfigError("noteit-client.json can't be loaded", true);
  }
  if (!res.ok) throw new ClientConfigError(`noteit-client.json is missing (HTTP ${res.status})`);
  let json: unknown;
  try {
    json = await res.json();
  } catch {
    throw new ClientConfigError('noteit-client.json is not valid JSON');
  }
  return parseClientConfig(json);
}
