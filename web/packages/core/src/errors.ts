export type StorageErrorKind =
  | 'notFound'
  | 'preconditionFailed'
  | 'unauthorized'
  | 'clockSkew'
  | 'insecureConnectionBlocked'
  | 'network'
  | 'invalidResponse'
  | 'io'
  | 'quotaExceeded'
  | 'conditionalDeleteUnsupported';

export class StorageError extends Error {
  constructor(
    readonly kind: StorageErrorKind,
    readonly detail: string = '',
  ) {
    super(`${kind}${detail ? `: ${detail}` : ''}`);
    this.name = 'StorageError';
  }
}

export type SyncErrorKind =
  | 'wrongPassphrase'
  | 'passphraseRequired'
  | 'unsupportedFormat'
  | 'unsupportedFeature'
  | 'keyChanged'
  | 'rekeyInProgress'
  | 'rekeyIncomplete'
  | 'manifestChangedConcurrently'
  | 'invalidManifest'
  | 'legacyStore'
  | 'invalidPayload'
  | 'cleanupUnavailable'
  | 'storeMissing';

export class SyncError extends Error {
  constructor(
    readonly kind: SyncErrorKind,
    readonly detail?: string,
    readonly formatVersion?: number,
  ) {
    super(`${kind}${detail ? `: ${detail}` : ''}`);
    this.name = 'SyncError';
  }
}

/** Errors that would fail every request, so a pass stops instead of collecting one per record. */
export function isFatal(e: StorageError): boolean {
  return e.kind === 'unauthorized' || e.kind === 'clockSkew' || e.kind === 'insecureConnectionBlocked';
}

/** Thrown by a local store for a record it can't export or apply yet: skipped quietly, retried next pass. */
export class RecordDeferred extends Error {}

/** Thrown by a local store for a remote record it can't keep; reported, not re-fetched until it changes. */
export class RecordRefused extends Error {}
