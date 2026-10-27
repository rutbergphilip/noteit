import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { defineConfig, devices } from '@playwright/test';

/**
 * End-to-end tests against the production build (`node .output/server/index.mjs`; run `pnpm build` first).
 *
 * Every browser gets its own server and a fresh data directory, so the first-admin setup runs once per browser and
 * the three projects never share accounts. Ports: E2E_PORT_BASE + 1..3 (default 3711–3713). Each project depends on
 * its `setup-*` project, which walks the setup wizard and saves the admin's session for the other specs.
 */
const BASE = Number(process.env.E2E_PORT_BASE ?? 3710);
// The runner loads this file first and its workers inherit the environment, so the data dir is fixed per run.
process.env.NOTEIT_E2E_RUN ??= `${Date.now()}`;
export const E2E_ROOT = join(process.env.E2E_DATA_ROOT ?? tmpdir(), `noteit-e2e-${process.env.NOTEIT_E2E_RUN}`);
export const SETUP_TOKEN = 'e2e-setup-token-0123456789';

const browsers = [
  { name: 'chromium', use: devices['Desktop Chrome'] },
  { name: 'firefox', use: devices['Desktop Firefox'] },
  { name: 'webkit', use: devices['Desktop Safari'] },
] as const;

const only = process.env.E2E_BROWSERS?.split(',');
const enabled = browsers.filter((b) => !only || only.includes(b.name));

export default defineConfig({
  testDir: './e2e',
  outputDir: './e2e/.results',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : 4,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: process.env.CI ? [['list'], ['html', { open: 'never', outputFolder: './e2e/.report' }]] : 'list',
  use: {
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: enabled.flatMap((b) => {
    const baseURL = `http://127.0.0.1:${BASE + 1 + browsers.indexOf(b)}`;
    return [
      { name: `setup-${b.name}`, testMatch: /setup\.setup\.ts/, use: { ...b.use, baseURL } },
      { name: b.name, testMatch: /.*\.spec\.ts/, dependencies: [`setup-${b.name}`], use: { ...b.use, baseURL } },
    ];
  }),
  webServer: enabled.map((b) => {
    const port = BASE + 1 + browsers.indexOf(b);
    const dataDir = join(E2E_ROOT, b.name);
    return {
      command: `node e2e/server.mjs`,
      url: `http://127.0.0.1:${port}/api/_actions/server-info`,
      reuseExistingServer: false,
      timeout: 60_000,
      stdout: 'ignore' as const,
      stderr: 'pipe' as const,
      env: {
        PORT: String(port),
        HOST: '127.0.0.1',
        NITRO_HOST: '127.0.0.1',
        NITRO_PORT: String(port),
        NOTEIT_DATA_DIR: dataDir,
        NOTEIT_SETUP_TOKEN: SETUP_TOKEN,
        // Lets each test sign in from its own X-Forwarded-For address, so the per-IP sign-in limit (10 a minute)
        // doesn't throttle a suite that signs in dozens of fresh accounts. The limit itself is tested in vitest.
        NOTEIT_TRUST_PROXY: 'true',
      },
    };
  }),
});
