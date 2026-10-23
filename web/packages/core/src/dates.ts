/** Seconds between 1970-01-01 and 2001-01-01 (Apple reference date). */
export const APPLE_EPOCH_OFFSET = 978307200;

export function toDouble2001(d: Date): number {
  return d.getTime() / 1000 - APPLE_EPOCH_OFFSET;
}

export function fromDouble2001(n: number): Date {
  return new Date((n + APPLE_EPOCH_OFFSET) * 1000);
}

/** `YYYY-MM-DDTHH:MM:SSZ`, milliseconds truncated (inner metas, spec §2.2). */
export function toIsoSeconds(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** Accepts fractional seconds and offsets. */
export function parseIso(s: string): Date {
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) throw new Error(`invalid date ${s}`);
  return d;
}

/** Truncates to whole seconds, as an inner-meta round trip does. */
export function truncateToSeconds(d: Date): Date {
  return new Date(Math.floor(d.getTime() / 1000) * 1000);
}
