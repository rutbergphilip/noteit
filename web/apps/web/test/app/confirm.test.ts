import { describe, expect, it, vi } from 'vitest';

vi.mock('~/components/ConfirmDialog.vue', () => ({ default: {} }));

/** A stand-in for Nuxt UI's useOverlay with its destroy-on-close behaviour. */
function fakeOverlay(answers: boolean[]) {
  const live = new Set<number>();
  let next = 0;
  return {
    create: (_component: unknown, opts: { destroyOnClose?: boolean }) => {
      const id = next++;
      live.add(id);
      return {
        open: () => {
          if (!live.has(id)) throw new Error('Overlay not found');
          if (opts.destroyOnClose) live.delete(id);
          return { result: Promise.resolve(answers.shift() ?? false) };
        },
      };
    },
  };
}

describe('useConfirm', () => {
  it('opens again after a dismissal (each confirmation gets its own overlay)', async () => {
    vi.stubGlobal('useOverlay', () => fakeOverlay([false, true, false]));
    const { useConfirm } = await import('../../app/lib/confirm');
    const confirm = useConfirm();
    expect(await confirm({ title: 'Delete?' })).toBe(false);
    expect(await confirm({ title: 'Delete?' })).toBe(true);
    expect(await confirm({ title: 'Delete?' })).toBe(false);
  });
});
