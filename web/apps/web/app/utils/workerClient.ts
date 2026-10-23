import type { WorkerApi } from '~/worker/sync.worker';
import type { WorkerEvent } from '~/worker/types';

type Remote = { [K in keyof WorkerApi]: (...args: Parameters<WorkerApi[K]>) => Promise<Awaited<ReturnType<WorkerApi[K]>>> };

/** A typed proxy over postMessage to the sync worker (crypto, IndexedDB and the engine all live there). */
export function createWorkerClient(onEvent: (e: WorkerEvent) => void): Remote {
  const worker = new Worker(new URL('../worker/sync.worker.ts', import.meta.url), { type: 'module', name: 'noteit-sync' });
  let next = 1;
  const waiting = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  worker.onmessage = (m: MessageEvent<{ id?: number; result?: unknown; error?: string; event?: WorkerEvent }>) => {
    if (m.data.event) return onEvent(m.data.event);
    const w = m.data.id !== undefined ? waiting.get(m.data.id) : undefined;
    if (!w) return;
    waiting.delete(m.data.id!);
    if (m.data.error !== undefined) w.reject(new Error(m.data.error));
    else w.resolve(m.data.result);
  };
  return new Proxy({} as Remote, {
    get: (_t, method: string) =>
      (...args: unknown[]) =>
        new Promise((resolve, reject) => {
          const id = next++;
          waiting.set(id, { resolve, reject });
          worker.postMessage({ id, method, args: JSON.parse(JSON.stringify(args)) as unknown[] });
        }),
  });
}
