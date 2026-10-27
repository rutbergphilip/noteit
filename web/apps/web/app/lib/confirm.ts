import ConfirmDialog from '~/components/ConfirmDialog.vue';

// Not in composables/: auto-imports are also typed into the server tsc program, which can't resolve .vue.
type ConfirmOptions = { title: string; description?: string; confirmLabel?: string; danger?: boolean; typeToConfirm?: string; cancelDefault?: boolean };

/**
 * An awaitable confirmation in a Nuxt UI modal, in place of window.confirm/prompt. Call in setup.
 *
 * Each call creates its own overlay: one created once with `destroyOnClose` is gone after its first close, and every
 * later open() failed with "Overlay not found".
 */
export function useConfirm(): (options: ConfirmOptions) => Promise<boolean> {
  const overlay = useOverlay();
  return async (options) => {
    const modal = overlay.create(ConfirmDialog, { destroyOnClose: true });
    return Boolean(await modal.open(options).result);
  };
}
