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
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:3011',
    trace: 'on-first-retry',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'pnpm start',
    url: 'http://127.0.0.1:3011',
    // Always false, deliberately: this machine runs multiple projects and
    // port collisions are real (a totally unrelated backend on 3001 once
    // got silently "reused" as this app, and every test failed against the
    // wrong server with no obvious clue why). Refusing to bind a busy port
    // fails loudly and immediately instead.
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
