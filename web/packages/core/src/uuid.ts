export type Uuid = string;

const UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

export function newUuid(): Uuid {
  return crypto.randomUUID().toUpperCase();
}

/** The uppercase canonical form, or null when `s` isn't a UUID (Swift `UUID(uuidString:)` is case-insensitive). */
export function normalizeUuid(s: string): Uuid | null {
  return UUID_RE.test(s) ? s.toUpperCase() : null;
}

export function isCanonicalUuid(s: string): boolean {
  return UUID_RE.test(s) && s === s.toUpperCase();
}
