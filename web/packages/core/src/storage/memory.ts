import { type Bytes, copyBytes } from '../bytes.js';
import { StorageError } from '../errors.js';
import { assertListablePrefix, assertReadableKey, assertValidKey, type PutOptions, type RemoteObject, type StorageBackend } from './backend.js';

interface Stored {
  data: Bytes;
  etag: string;
  lastModified: number;
}

/** An in-memory store for tests and the engine vectors. ETags are a counter, so equal bytes still get a new ETag. */
export class InMemoryBackend implements StorageBackend {
  readonly objects = new Map<string, Stored>();
  private counter = 0;
  private failures: { op: string; err: StorageError }[] = [];
  private landThenFailPatterns: { op: 'put' | 'delete'; re: RegExp }[] = [];
  readonly log: string[] = [];

  constructor(private readonly opts: { atomic?: boolean; atomicDelete?: boolean; now?: () => Date } = {}) {}

  /** The next `op` call throws `err` without touching the store. */
  failNext(op: 'get' | 'put' | 'delete' | 'list', err: StorageError): void {
    this.failures.push({ op, err });
  }

  /** The next matching write is applied, then reported as a network error (a lost response). */
  landThenFail(op: 'put' | 'delete', keyPattern: RegExp): void {
    this.landThenFailPatterns.push({ op, re: keyPattern });
  }

  private takeFailure(op: string): void {
    const i = this.failures.findIndex((f) => f.op === op);
    if (i >= 0) {
      const [f] = this.failures.splice(i, 1);
      throw f!.err;
    }
  }

  private takeLandThenFail(op: 'put' | 'delete', key: string): boolean {
    const i = this.landThenFailPatterns.findIndex((p) => p.op === op && p.re.test(key));
    if (i < 0) return false;
    this.landThenFailPatterns.splice(i, 1);
    return true;
  }

  private now(): number {
    return (this.opts.now?.() ?? new Date()).getTime();
  }

  async list(prefix: string): Promise<RemoteObject[]> {
    assertListablePrefix(prefix);
    this.takeFailure('list');
    return [...this.objects.entries()]
      .filter(([k]) => k.startsWith(prefix))
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([key, o]) => ({ key, etag: o.etag, size: o.data.length, lastModified: o.lastModified }));
  }

  async get(key: string): Promise<{ data: Bytes; etag: string }> {
    assertReadableKey(key);
    this.takeFailure('get');
    const o = this.objects.get(key);
    if (!o) throw new StorageError('notFound', key);
    return { data: copyBytes(o.data), etag: o.etag };
  }

  async put(key: string, data: Uint8Array, opts: PutOptions = {}): Promise<string> {
    assertValidKey(key);
    this.takeFailure('put');
    const current = this.objects.get(key);
    if (opts.ifNoneMatch && current) throw new StorageError('preconditionFailed', key);
    if (opts.ifMatch !== undefined && current?.etag !== opts.ifMatch) throw new StorageError('preconditionFailed', key);
    const etag = `e${(++this.counter).toString(16).padStart(8, '0')}`;
    this.objects.set(key, { data: copyBytes(data), etag, lastModified: this.now() });
    this.log.push(`PUT ${key}`);
    if (this.takeLandThenFail('put', key)) throw new StorageError('network', 'lost response');
    return etag;
  }

  async delete(key: string, opts: { ifMatch?: string } = {}): Promise<void> {
    assertValidKey(key);
    this.takeFailure('delete');
    const current = this.objects.get(key);
    if (opts.ifMatch !== undefined && this.opts.atomicDelete === false) {
      throw new StorageError('conditionalDeleteUnsupported', key);
    }
    if (!current) throw new StorageError('notFound', key);
    if (opts.ifMatch !== undefined && current.etag !== opts.ifMatch) throw new StorageError('preconditionFailed', key);
    this.objects.delete(key);
    this.log.push(`DELETE ${key}`);
    if (this.takeLandThenFail('delete', key)) throw new StorageError('network', 'lost response');
  }

  async probe(): Promise<void> {}

  async atomicConditionalWrites(): Promise<boolean> {
    return this.opts.atomic ?? true;
  }

  async atomicConditionalDelete(): Promise<boolean> {
    return this.opts.atomicDelete ?? true;
  }
}
