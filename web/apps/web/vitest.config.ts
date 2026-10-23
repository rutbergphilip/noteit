import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    // What the nuxt-safe-action module aliases inside Nuxt, so the harness can serve the real actions.
    alias: { '~': fileURLToPath(new URL('./app', import.meta.url)), '#safe-action': fileURLToPath(new URL('./node_modules/nuxt-safe-action/dist/runtime/server/index.js', import.meta.url)) },
  },
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
    testTimeout: 30_000,
  },
});
