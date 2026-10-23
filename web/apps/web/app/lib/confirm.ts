import ConfirmDialog from '~/components/ConfirmDialog.vue';

// Not in composables/: auto-imports are also typed into the server tsc program, which can't resolve .vue.
type ConfirmOptions = { title: string; description?: string; confirmLabel?: string; danger?: boolean; typeToConfirm?: string };

/** An awaitable confirmation in a Nuxt UI modal, in place of window.confirm/prompt. Call in setup. */
export function useConfirm(): (options: ConfirmOptions) => Promise<boolean> {
  const overlay = useOverlay();
  const modal = overlay.create(ConfirmDialog, { destroyOnClose: true });
  return async (options) => Boolean(await modal.open(options).result);
}
