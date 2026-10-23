/** A minimal promise wrapper over IndexedDB: three object stores keyed by string. */
export type StoreName = 'kv' | 'records' | 'pending';

function req<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

export class Idb {
  private constructor(private readonly db: IDBDatabase) {}

  static open(name: string): Promise<Idb> {
    return new Promise((resolve, reject) => {
      const r = indexedDB.open(name, 1);
      r.onupgradeneeded = () => {
        for (const s of ['kv', 'records', 'pending']) if (!r.result.objectStoreNames.contains(s)) r.result.createObjectStore(s);
      };
      r.onsuccess = () => {
        // Another page (a newer version, or a deletion) needs the database: let go rather than block it.
        r.result.onversionchange = () => r.result.close();
        resolve(new Idb(r.result));
      };
      r.onerror = () => reject(r.error);
      // Blocked by a connection that hasn't closed yet (a page being unloaded): success follows once it does.
    });
  }

  static delete(name: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const r = indexedDB.deleteDatabase(name);
      r.onsuccess = () => resolve();
      r.onerror = () => reject(r.error);
      r.onblocked = () => resolve();
    });
  }

  close(): void {
    this.db.close();
  }

  get<T>(store: StoreName, key: string): Promise<T | undefined> {
    return req(this.db.transaction(store).objectStore(store).get(key)) as Promise<T | undefined>;
  }

  async all<T>(store: StoreName): Promise<[string, T][]> {
    const tx = this.db.transaction(store);
    const [keys, values] = await Promise.all([req(tx.objectStore(store).getAllKeys()), req(tx.objectStore(store).getAll())]);
    return keys.map((k, i) => [String(k), values[i] as T]);
  }

  put(store: StoreName, key: string, value: unknown): Promise<void> {
    const tx = this.db.transaction(store, 'readwrite');
    tx.objectStore(store).put(value, key);
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  delete(store: StoreName, key: string): Promise<void> {
    const tx = this.db.transaction(store, 'readwrite');
    tx.objectStore(store).delete(key);
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  /** Increments kv `generation` in one transaction; resolves with the value it replaced. */
  bump(): Promise<number> {
    const tx = this.db.transaction('kv', 'readwrite');
    const store = tx.objectStore('kv');
    let before = 0;
    const r = store.get('generation');
    r.onsuccess = () => {
      before = typeof r.result === 'number' ? r.result : 0;
      store.put(before + 1, 'generation');
    };
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve(before);
      tx.onerror = () => reject(tx.error);
    });
  }

  clear(store: StoreName): Promise<void> {
    const tx = this.db.transaction(store, 'readwrite');
    tx.objectStore(store).clear();
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }
}
