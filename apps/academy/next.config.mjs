/** @type {import('next').NextConfig} */
const nextConfig = {
  distDir: process.env.NEXT_DIST_DIR || '.next',
  reactStrictMode: true,
  images: {
    remotePatterns: [{ protocol: 'https', hostname: '**.supabase.co' }],
  },
  // FR-F15: the timetable PDF renderer launches the headless Chromium
  // Playwright already ships (lib/timetable-export/pdf.ts). Playwright
  // resolves its own browser binaries and driver relative to its package on
  // disk, so it must be required at runtime rather than traced into the
  // server bundle.
  // Leave applications carry up to 10 MB of attachments through a server action.
  experimental: { serverActions: { bodySizeLimit: '12mb' } },
  serverExternalPackages: ['@playwright/test', 'playwright', 'playwright-core'],
};

export default nextConfig;
