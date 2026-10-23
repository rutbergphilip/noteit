import { nextTick, onBeforeUnmount, onMounted, type Ref } from 'vue';

const MAX_FRAMES = 90;

/**
 * Focuses the first input inside `root` once it's on screen, instead of the `autofocus` attribute: a field mounted
 * while the splash fades out, or before the tab has focus on a first load or reload, misses the attribute and the
 * page is left on <body>. Retries each frame until the field is visible and holds focus (about 1.5 s), and stops
 * as soon as the person focuses something else.
 */
export function useFocusWhenShown(root: Ref<HTMLElement | null | undefined>, enabled: () => boolean = () => true): void {
  let frame = 0;
  let stopped = false;
  const stop = () => {
    stopped = true;
    if (frame) cancelAnimationFrame(frame);
  };
  const attempt = (left: number) => {
    if (stopped || !enabled()) return;
    const el = root.value?.matches('input, textarea') ? root.value : root.value?.querySelector<HTMLElement>('input, textarea');
    const active = document.activeElement;
    // Someone else (the person, or a dialog) took focus: leave it.
    if (active && active !== document.body && active !== el) return;
    if (el && el.isConnected && (el.checkVisibility?.({ opacityProperty: true, visibilityProperty: true }) ?? el.offsetParent !== null)) {
      el.focus({ preventScroll: true });
      if (document.activeElement === el && document.hasFocus()) return;
    }
    if (left > 0) frame = requestAnimationFrame(() => attempt(left - 1));
  };
  const onWindowFocus = () => attempt(0);
  onMounted(() => {
    window.addEventListener('focus', onWindowFocus, { once: true });
    void nextTick(() => attempt(MAX_FRAMES));
  });
  onBeforeUnmount(() => {
    stop();
    window.removeEventListener('focus', onWindowFocus);
  });
}
