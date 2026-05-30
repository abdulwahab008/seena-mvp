# Deploying Seena Exams

Architecture in production:

```
Vercel        →  Next.js web app (apps/web)        [serverless]
Render        →  BullMQ worker (apps/worker)        [always-on background worker]
Render Redis  →  BullMQ queue                       [persistent, BullMQ-friendly]
Supabase      →  Postgres (DATABASE_URL) + Storage (book PDFs + exports)
Pinecone      →  vector DB
OpenRouter    →  LLM + embeddings + vision OCR
Clerk         →  auth
```

Why Render (not Upstash) for the worker's Redis: BullMQ holds blocking reads on Redis, which burns through Upstash's per-command free tier fast. A persistent Redis (Render Key Value / Railway) is the right fit. The web app doesn't touch Redis directly except to enqueue jobs, so it shares the same URL.

---

## 0. Prerequisites (accounts)
- GitHub (`abdulwahab008`)
- Vercel (free) — sign in with GitHub
- Render (free) — sign in with GitHub
- Supabase project (already have it) — its Postgres + Storage
- Pinecone index `seena-exams` (already have it)
- OpenRouter key (already have it)
- Clerk app (already have it) — currently a **development** instance

---

## 1. Push to GitHub
```bash
cd "/Users/apple/Desktop/Seena Exams"
git remote add origin https://github.com/abdulwahab008/seena-exams.git
git push -u origin main
```
Create the empty **private** repo first at github.com/new (no README/gitignore/license).

---

## 2. Production Postgres (Supabase)
You already have a Supabase Postgres. Get its connection string:
- Supabase dashboard → Project → **Connect** → **ORM / Drizzle** or **Connection string**
- Use the **Transaction pooler** string for Vercel (serverless), port 6543, looks like:
  `postgresql://postgres.<ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres`
- Use the **Session/direct** string (port 5432) for running migrations.

Run migrations against it (one-time, and after every schema change):
```bash
cd apps/web
DATABASE_URL='<supabase-direct-5432-url>' npx drizzle-kit migrate
```

---

## 3. Redis (Render Key Value)
- Render dashboard → **New** → **Key Value** (Redis) → free plan → create.
- Copy its **Internal** connection URL (for the worker, same Render network) and the
  **External** URL (`rediss://…`, for Vercel).

---

## 4. Deploy the worker (Render → Background Worker)
- Render → **New** → **Background Worker** → connect the GitHub repo.
- Settings:
  - **Root Directory:** leave blank (repo root — it's a monorepo)
  - **Runtime:** Node
  - **Build Command:** `npm install -g pnpm@11.0.9 && pnpm install --filter @seena/worker... --frozen-lockfile`
  - **Start Command:** `pnpm --filter @seena/worker start`
  - (Or choose **Docker** and point at `apps/worker/Dockerfile` — build context = repo root.)
- **Environment variables** (Render → Environment):
  ```
  DATABASE_URL              = <supabase direct 5432 url>
  REDIS_URL                 = <Render Key Value INTERNAL url>
  OPENROUTER_API_KEY        = <your key>
  OPENROUTER_BASE_URL       = https://openrouter.ai/api/v1
  OPENROUTER_EMBEDDING_MODEL= openai/text-embedding-3-large
  OPENROUTER_VISION_MODEL   = google/gemini-3.5-flash
  OPENROUTER_APP_NAME       = Seena Exams
  OPENROUTER_APP_URL        = https://<your-vercel-domain>
  PINECONE_API_KEY          = <your key>
  PINECONE_INDEX            = seena-exams
  SUPABASE_URL              = https://<ref>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY = <your service role key>
  SUPABASE_BUCKET           = books
  WORKER_CONCURRENCY        = 2
  NODE_ENV                  = production
  ```

---

## 5. Deploy the web app (Vercel)
- Vercel → **Add New Project** → import the GitHub repo.
- Settings:
  - **Root Directory:** `apps/web`
  - Toggle **Include files outside the root directory** ON (needed for `@seena/shared`).
  - **Framework:** Next.js (auto-detected)
  - **Install Command:** `pnpm install` (Vercel runs it from repo root for workspaces)
  - **Build Command:** `pnpm --filter @seena/web build` (or leave default `next build`)
- **Environment variables** (Vercel → Settings → Environment Variables):
  ```
  DATABASE_URL                       = <supabase TRANSACTION pooler 6543 url>
  REDIS_URL                          = <Render Key Value EXTERNAL rediss:// url>
  CLERK_SECRET_KEY                   = <clerk secret>
  NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY  = <clerk publishable>
  OPENROUTER_API_KEY                 = <your key>
  OPENROUTER_BASE_URL                = https://openrouter.ai/api/v1
  OPENROUTER_MODEL                   = anthropic/claude-sonnet-4.5
  OPENROUTER_EMBEDDING_MODEL         = openai/text-embedding-3-large
  OPENROUTER_RERANK_MODEL            = google/gemini-3.5-flash
  OPENROUTER_APP_NAME                = Seena Exams
  OPENROUTER_APP_URL                 = https://<your-vercel-domain>
  PINECONE_API_KEY                   = <your key>
  PINECONE_INDEX                     = seena-exams
  SUPABASE_URL                       = https://<ref>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY          = <your service role key>
  SUPABASE_BUCKET                    = books
  NODE_ENV                           = production
  ```
- Deploy. Note the assigned domain (e.g. `seena-exams.vercel.app`).

---

## 6. Point Clerk at the production domain
Dev Clerk keys work on any localhost but NOT a real domain. Two options:
- **Quick (staging):** Clerk dashboard → your app → add `https://<vercel-domain>` to allowed origins. Dev keys keep working for testing.
- **Proper (launch):** Clerk → **Deploy to Production** → create a production instance → get `pk_live_…` / `sk_live_…` → set those in Vercel → configure the production domain + DNS. Required before real users.

---

## 7. Post-deploy smoke test
1. Open `https://<vercel-domain>` → sign up.
2. Upload a small PDF → confirm worker logs on Render show it processing → status `ready`.
3. `/chat` → generate an exam → confirm it returns.
4. Open the exam → **Export PDF** → confirm the signed Supabase URL opens.
5. Dashboard → confirm "This month" usage counter increments.

---

## Gotchas
- **Supabase auto-pause:** free Supabase projects pause after ~7 days idle (DNS goes NXDOMAIN). Keep it warm or upgrade before launch.
- **Migrations:** run `drizzle-kit migrate` against the Supabase **direct** (5432) URL after every schema change. Vercel does NOT run migrations automatically.
- **Storage bucket:** the `books` bucket must exist in the production Supabase project (it does if it's the same project we used in dev).
- **Pinecone namespaces:** existing dev vectors live under `org_<dev-org-id>__emb_…`. New production orgs get fresh namespaces automatically — no migration needed.
- **OPENROUTER_APP_URL** should match the live domain (used as the HTTP-Referer for OpenRouter analytics; cosmetic, non-blocking).
- **Worker can't be on Vercel** — Vercel is serverless and kills long-running processes. The BullMQ worker must be the Render Background Worker.
