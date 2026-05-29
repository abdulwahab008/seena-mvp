# Seena Exams

AI exam generator. Teachers upload textbooks; the system retrieves relevant content and generates board-pattern exam papers (FBISE, Punjab, BISE Rawalpindi, Cambridge IGCSE, Cambridge O Level) with answer keys, exportable as branded PDFs.

This is the **MVP** scope per the build plan at `~/.claude/plans/ai-powered-exam-smooth-owl.md`.

## What's in the box

```
apps/
  web/                Next.js 15 app (UI + API routes)
  worker/             BullMQ worker (PDF extract + chunk + embed + Pinecone upsert)
packages/
  shared/             zod schemas, exam pattern specs, Drizzle schema, chunker
infra/
  docker-compose.yml  local Postgres + Redis
  env.example
```

## Stack

- **Frontend**: Next.js 15 (App Router) + Tailwind + shadcn-style components
- **Auth**: Clerk
- **DB**: Postgres (Supabase or local) + Drizzle ORM
- **Storage**: Supabase Storage (presigned uploads)
- **Vector DB**: Pinecone serverless (namespace per org × embedding model)
- **LLM**: Claude Sonnet 4.5 via OpenRouter (chat completions + structured tool use)
- **Embeddings**: OpenAI `text-embedding-3-large` (3072-dim) via OpenRouter
- **Reranker** (optional): Cohere Rerank v3.5 — cross-encoder over top-50 → top-K
- **Queue**: BullMQ + Redis
- **PDF**: `@react-pdf/renderer`
- **OCR (optional)**: Google Document AI for scanned PDFs, or vision-LLM via OpenRouter (default)

No LangChain / LlamaIndex — direct provider SDK calls.

## Prerequisites

- Node 20+
- pnpm 9+ (`npm i -g pnpm`)
- Docker (for local Postgres + Redis)
- Accounts: Clerk, Anthropic, OpenAI, Pinecone, Supabase

## Setup

```bash
# 1. Install dependencies
pnpm install

# 2. Start Postgres + Redis
docker compose -f infra/docker-compose.yml up -d

# 3. Configure env
cp infra/env.example apps/web/.env.local
cp infra/env.example apps/worker/.env
# fill in keys in both files

# 4. Create Pinecone index
#    - dimension: 3072  (matches text-embedding-3-large)
#    - metric: cosine
#    - serverless

# 5. Create Supabase Storage bucket "books" (private)

# 6. Run migrations
pnpm db:generate
pnpm db:migrate

# 7. Start everything
pnpm dev
# in another terminal:
pnpm --filter @seena/worker dev
```

Web on `http://localhost:3000`, worker logs to stdout.

## End-to-end smoke test

1. Sign up at `/sign-up`.
2. Go to `/books/new`, upload a Physics 9 PDF, tag it (Physics, grade 9, Punjab Board).
3. Wait for status `ready` (refresh `/books`).
4. Go to `/chat`, type:
   > Generate FBISE 9th Physics paper from Chapter 2.
5. The chat returns a link to the generated exam.
6. Open it, edit a question or regenerate one, then click **Export PDF**.

## Pattern specs

Defined in `packages/shared/src/patterns/`. Each pattern declares its sections with question type, count, and marks per question. The generator follows them exactly.

| Pattern ID | Board | Grade | Total marks |
|---|---|---|---|
| `fbise-ssc-physics` | FBISE | 9 | 60 |
| `fbise-ssc-generic` | FBISE | 9 | 75 |
| `fbise-hssc-generic` | FBISE | 11 | 85 |
| `punjab-ssc-generic` | PUNJAB | 9 | 75 |
| `punjab-hssc-generic` | PUNJAB | 11 | 85 |
| `pindi-ssc-generic` | PINDI | 9 | 75 |
| `cambridge-igcse-generic` | CAMBRIDGE_IGCSE | 10 | 80 |
| `cambridge-o-level-generic` | CAMBRIDGE_O_LEVEL | 10 | 80 |

These are starting points — verify against the latest official scheme of studies for each subject before relying on them in production.

## Quality safeguards

- Every generated question must include `source_pages` (Pinecone metadata → cited in UI + PDF).
- Post-generation copyright guard rejects any question whose prompt or answer contains a 15+ word verbatim span from the retrieved context.
- Cost telemetry per generation in `generations` table (model, tokens, latency, USD).

## Costs (rough)

- Per book ingest: ~$0.05 (embeddings) + ~$0.20 if OCR triggered
- Per exam generation: ~$0.10–0.30 (Claude Sonnet 4.6 in/out tokens)
- Per teacher / month (3 books, 20 exams): ~$3–7

## Out of scope for v1

Student attempts, Urdu OCR, bilingual paper output, auto-checking, diagram generation, white-label, multi-agent orchestration, drag-and-drop visual builder. See plan file for full deferrals.

## Production deployment

- **Web**: Vercel (Next.js)
- **Worker**: Render / Fly.io / Railway (separate Node service)
- **DB**: Supabase
- **Redis**: Upstash
- **Vector**: Pinecone serverless
- **Storage**: Supabase Storage (or migrate to S3 + Cloudfront)

Set the same env vars in each environment. Worker concurrency tuned via `WORKER_CONCURRENCY`.
