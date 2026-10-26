import { ref, watch, type Ref } from 'vue';

/**
 * A key that changes each time an overlay opens, for `<UModal :key>` / `<USlideover :key>`. Nuxt UI's overlays have
 * no z-index and stack in DOM order, and a Teleport stays where it was first mounted: a modal mounted at startup sits
 * before the sidebar drawer (mounted when it opens) in <body>, so at tablet widths it would show behind the drawer.
 * Remounting on each opening gives it a fresh portal at the end of <body>, as useConfirm's dialogs get.
 */
export function useOpeningKey(open: () => unknown): Ref<number> {
  const key = ref(0);
  watch(
    () => !!open(),
    (o) => {
      if (o) key.value++;
    },
  );
  return key;
}
