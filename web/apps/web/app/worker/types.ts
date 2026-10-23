import type { BodyContainer } from '@noteit/doc';

export type NoteKind = 'doc' | 'legacy' | 'locked';

export interface NoteRow {
  id: string;
  /** The record revision; every write mints a new one. */
  revision: string;
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
  /** Synced (organise): the template new notes in this notebook start from. */
  defaultTemplateID?: string;
}

/** A saved search (native SmartFolder), synced as `smart-folders/<ID>.json`. */
export interface SmartFolderRow {
  id: string;
  name: string;
  query: string;
  symbol: string;
  sortIndex: number;
}

export interface Snapshot {
  notes: NoteRow[];
  notebooks: NotebookRow[];
  smartFolders: SmartFolderRow[];
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
