/** Nuxt UI theme: the design's palette (see assets/app.css) and the component defaults NoteIt uses everywhere. */
export default defineAppConfig({
  ui: {
    colors: {
      primary: 'brand',
      neutral: 'ink',
    },
    button: {
      slots: { base: 'font-semibold transition-colors duration-150' },
      // Hover and press use the deeper accent (--acct) instead of fading the primary to 75%, which drops a white
      // label (or violet link text) under 4.5:1.
      compoundVariants: [
        { color: 'primary', variant: 'solid', class: 'hover:bg-(--acct) active:bg-(--acct)' },
        { color: 'primary', variant: 'link', class: 'hover:text-(--acct) active:text-(--acct)' },
      ],
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
