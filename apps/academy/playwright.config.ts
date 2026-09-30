import { defineConfig, devices } from '@playwright/test';

// Node 20.6+ native .env loader — makes NEXT_PUBLIC_SUPABASE_URL /
// SUPABASE_SERVICE_ROLE_KEY available to test files' Node-side setup code
// (Next.js loads .env.local itself for the spawned `pnpm start`, but
// Playwright's own process does not).
try {
  process.loadEnvFile('.env.local');
} catch {
  // Missing .env.local (e.g. CI providing real env vars directly) is fine.
}

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  // CI additionally writes an HTML report so a failure is debuggable from
  // the uploaded artifact, not just the log — 'list' alone (still used
  // locally) prints nothing to disk.
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL: 'http://127.0.0.1:3011',
    trace: 'on-first-retry',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'pnpm start',
    url: 'http://127.0.0.1:3011',
    // Refusing to bind a busy port fails loudly unless REUSE_EXISTING_SERVER is explicitly set
    reuseExistingServer: process.env.REUSE_EXISTING_SERVER === 'true',
    timeout: 60_000,
  },
});
