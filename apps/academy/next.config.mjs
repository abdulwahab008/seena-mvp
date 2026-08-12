/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  images: {
    remotePatterns: [{ protocol: 'https', hostname: '**.supabase.co' }],
  },
  // FR-F15: the timetable PDF renderer launches the headless Chromium
  // Playwright already ships (lib/timetable-export/pdf.ts). Playwright
  // resolves its own browser binaries and driver relative to its package on
  // disk, so it must be required at runtime rather than traced into the
  // server bundle.
  serverExternalPackages: ['@playwright/test', 'playwright', 'playwright-core'],
};

export default nextConfig;
