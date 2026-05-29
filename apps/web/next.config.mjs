/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  experimental: {
    serverActions: { bodySizeLimit: '50mb' },
  },
  serverExternalPackages: ['pdf-parse'],
  transpilePackages: ['@seena/shared'],
  images: {
    remotePatterns: [
      { protocol: 'https', hostname: '**.supabase.co' },
      { protocol: 'https', hostname: 'img.clerk.com' },
    ],
  },
  webpack: (config) => {
    // Resolve TS source files when the import path uses `.js` (NodeNext style),
    // as @seena/shared does for compatibility with the worker.
    config.resolve.extensionAlias = {
      '.js': ['.ts', '.tsx', '.js', '.jsx'],
    };
    return config;
  },
};

export default nextConfig;
