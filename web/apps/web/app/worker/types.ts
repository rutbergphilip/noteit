import type { BodyContainer } from '@noteit/doc';

export type NoteKind = 'doc' | 'legacy' | 'locked';

export interface NoteRow {
  id: string;
  title: string;
  preview: string;
  tags: string[];
  isPinned: boolean;
  notebookID?: string;
  createdAt: string;
  updatedAt: string;
  deletedAt?: string;
  conflictSource?: string;
  conflictOriginalID?: string;
  kind: NoteKind;
}

export interface NotebookRow {
  id: string;
  name: string;
  colorHex: string;
  symbol: string;
  sortIndex: number;
  parent?: string;
}

export interface Snapshot {
  notes: NoteRow[];
  notebooks: NotebookRow[];
}

export type SyncPhase = 'locked' | 'idle' | 'syncing' | 'offline' | 'error' | 'legacy';

export interface SyncStatus {
  phase: SyncPhase;
  lastSync?: number;
  detail?: string;
  /** Per-record errors from the last pass (retried next pass). */
  recordErrors: { id?: string; message: string }[];
  pending: number;
}

export interface OpenedNote {
  row: NoteRow;
  container?: BodyContainer;
  readOnly?: string;
}

export type UnlockResult = { status: 'ok'; created: boolean } | { status: 'noStore' } | { status: 'legacy' } | { status: 'error'; kind: string; message: string };

export interface DeviceView {
  deviceID: string;
  name: string;
  lastSync: number;
  platform?: string;
  current: boolean;
}

/** Messages the worker posts on its own. */
export type WorkerEvent = { type: 'changed' } | { type: 'status'; status: SyncStatus };
