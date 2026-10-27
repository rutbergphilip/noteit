import type { Bytes } from '../src/bytes.js';
import { StorageError } from '../src/errors.js';
import type { PutOptions, RemoteObject, StorageBackend } from '../src/storage/backend.js';
import type { InMemoryBackend } from '../src/storage/memory.js';

/**
 * Port of the Swift test ScriptedBackend (Tests/NoteItSyncTests/Support/ScriptedBackend.swift): wraps an
 * InMemoryBackend and injects the faults of the v2 engine traces. A crash is a fatal error that aborts `sync()`, as
 * a process dying mid-request; a fresh SyncEngine over the same state store models the restart.
 */
export const isTestCrash = (e: unknown): boolean => e instanceof StorageError && e.message.includes('TestCrash');

/** A request the caller saw time out; `release()` applies it later, evaluating its preconditions then. */
export class HeldRequest {
  private work: (() => Promise<unknown>) | undefined;
  arm(work: () => Promise<unknown>): void {
    this.work = work;
  }
  async release(): Promise<unknown> {
    const work = this.work;
    this.work = undefined;
    if (!work) return undefined;
    try {
      await work();
      return undefined;
    } catch (e) {
      return e;
    }
  }
}

type Fault = { type: 'crashDuring' } | { type: 'landThenFail' } | { type: 'hold'; held: HeldRequest };

export class ScriptedBackend implements StorageBackend {
  private faults: { op: 'put' | 'delete'; pattern: string; fault: Fault }[] = [];

  constructor(readonly inner: InMemoryBackend) {}

  /** Arms `fault` for the next `op` request whose key contains `pattern`. */
  on(op: 'put' | 'delete', pattern: string, fault: Fault): void {
    this.faults.push({ op, pattern, fault });
  }

  private take(op: 'put' | 'delete', key: string): Fault | undefined {
    const i = this.faults.findIndex((f) => f.op === op && key.includes(f.pattern));
    if (i < 0) return undefined;
    return this.faults.splice(i, 1)[0]!.fault;
  }

  private async run<T>(op: 'put' | 'delete', key: string, apply: () => Promise<T>): Promise<T> {
    const fault = this.take(op, key);
    if (fault?.type === 'crashDuring') throw new StorageError('unauthorized', 'TestCrash');
    if (fault?.type === 'hold') {
      fault.held.arm(apply);
      throw new StorageError('network', `timed out: ${key}`);
    }
    const result = await apply();
    if (fault?.type === 'landThenFail') throw new StorageError('network', `lost response: ${key}`);
    return result;
  }

  list(prefix: string): Promise<RemoteObject[]> {
    return this.inner.list(prefix);
  }
  get(key: string): Promise<{ data: Bytes; etag: string }> {
    return this.inner.get(key);
  }
  put(key: string, data: Uint8Array, opts?: PutOptions): Promise<string> {
    return this.run('put', key, () => this.inner.put(key, data, opts));
  }
  delete(key: string, opts?: { ifMatch?: string }): Promise<void> {
    return this.run('delete', key, () => this.inner.delete(key, opts));
  }
  probe(): Promise<void> {
    return this.inner.probe();
  }
  atomicConditionalWrites(): Promise<boolean> {
    return this.inner.atomicConditionalWrites();
  }
  atomicConditionalDelete(): Promise<boolean> {
    return this.inner.atomicConditionalDelete();
  }
}
