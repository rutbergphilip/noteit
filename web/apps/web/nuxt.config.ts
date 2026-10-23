// The web client is a pure SPA: the server only serves static assets, /api and /s3, and never renders notes.
export default defineNuxtConfig({
  compatibilityDate: '2026-09-01',
  ssr: false,
  devtools: { enabled: false },
  telemetry: false,
  css: ['~/assets/app.css'],
  app: {
    head: {
      title: 'NoteIt',
      htmlAttrs: { lang: 'en' },
      meta: [
        { name: 'viewport', content: 'width=device-width, initial-scale=1, viewport-fit=cover' },
        { name: 'color-scheme', content: 'light dark' },
        { name: 'referrer', content: 'no-referrer' },
      ],
      link: [{ rel: 'icon', type: 'image/png', href: '/noteit-icon.png' }],
    },
  },
  nitro: {
    preset: 'node-server',
    externals: { inline: ['@noteit/core', '@noteit/doc'] },
  },
  vite: {
    worker: { format: 'es' },
  },
  typescript: { strict: true },
});
