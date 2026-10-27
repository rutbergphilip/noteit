// The web client is a pure SPA: the server only serves static assets, /api and /s3, and never renders notes.
// The control plane is nuxt-safe-action actions (server/actions → /api/_actions/*); sync stays plain routes.
export default defineNuxtConfig({
  modules: ['@nuxt/ui', 'nuxt-safe-action'],
  ui: {
    // System fonts only (design): nothing fetched from a font CDN, which the CSP would refuse anyway.
    fonts: false,
  },
  icon: {
    // Lucide ships in the bundle: the CSP allows no third-party connect-src, so no Iconify API at runtime.
    provider: 'none',
    clientBundle: { scan: { globInclude: ['app/**/*.{vue,ts}'] }, icons: [] },
    serverBundle: false,
  },
  colorMode: {
    // The theme menu's choice; 'system' follows the OS.
    storageKey: 'noteit.theme',
    classSuffix: '',
  },
  compatibilityDate: '2026-09-01',
  // Reproducible client (signed release manifest, scripts/build-web-release.mjs): a fixed build id instead of a
  // random one, and no app manifest (its builds/latest.json carries a build timestamp).
  ...(process.env.NOTEIT_BUILD_ID ? { buildId: process.env.NOTEIT_BUILD_ID } : {}),
  experimental: { appManifest: false },
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
