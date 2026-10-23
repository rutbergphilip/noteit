/** Nuxt UI theme: the design's palette (see assets/app.css) and the component defaults NoteIt uses everywhere. */
export default defineAppConfig({
  ui: {
    colors: {
      primary: 'brand',
      neutral: 'ink',
    },
    button: {
      slots: { base: 'font-semibold transition-colors duration-150' },
    },
    input: {
      slots: { root: 'w-full' },
    },
    formField: {
      slots: { label: 'font-medium' },
    },
    modal: {
      slots: { overlay: 'bg-(--scrim)! backdrop-blur-[1px]', content: 'shadow-(--shadow-dialog) ring-0' },
    },
    tooltip: {
      slots: { content: 'shadow-(--shadow-card)' },
    },
  },
});
