# Worker image — runs the BullMQ background processor (book-process + book-rechunk).
# Build context must be the REPO ROOT (the monorepo), not apps/worker:
#   docker build -f apps/worker/Dockerfile -t seena-worker .
FROM node:22-slim

# pdf-parse / protobufjs are pure-JS; no native toolchain needed.
RUN npm install -g pnpm@11.0.9

WORKDIR /app

# Install deps using only the manifests first (better layer caching).
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml .npmrc ./
COPY packages/shared/package.json packages/shared/package.json
COPY apps/worker/package.json apps/worker/package.json
RUN pnpm install --filter @seena/worker... --frozen-lockfile

# Copy source.
COPY packages/shared packages/shared
COPY apps/worker apps/worker

WORKDIR /app/apps/worker
ENV NODE_ENV=production
# Env vars (DATABASE_URL, REDIS_URL, OPENROUTER_*, PINECONE_*, SUPABASE_*) are
# injected by the platform — NOT baked into the image.
CMD ["pnpm", "start"]
