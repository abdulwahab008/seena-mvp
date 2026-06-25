# Seena Exams — Project Status & Plan

_Snapshot: 2026-06-24. Audited the running codebase (web + worker + shared), local infra, and deploy docs._

**One-line state:** The product is **code-complete for the MVP** and **compiles clean** (typecheck 3/3). Local Postgres + Redis are up and migrated. The only thing stopping a full local boot is the **`.env.local` secrets** (Clerk/OpenRouter/Pinecone/Supabase) — which already exist per `DEPLOY.md`, they're just not dropped into this worktree.

---

## 1. Stack (what we're actually using)

| Layer | Tech | Notes |
|---|---|---|
| Monorepo | pnpm workspaces + Turborepo | `apps/web`, `apps/worker`, `packages/shared` |
| Frontend | Next.js 15 (App Router), React 19, Tailwind, shadcn-style UI | `apps/web/app` |
| Forms / data | React Hook Form + Zod, TanStack Query, sonner (toasts) | |
| Auth | **Clerk** | org-aware; middleware-protected routes |
| DB | Postgres + **Drizzle ORM** | 12 tables, 5 migrations applied |
| Storage | **Supabase Storage** (presigned uploads) | bucket `books` — PDFs + exports |
| Vector DB | **Pinecone** serverless | namespace per `org × embedding-model` |
| LLM | **Claude Sonnet 4.5 via OpenRouter** | chat-completions + tool use |
| Embeddings | OpenAI `text-embedding-3-large` (3072-d) via OpenRouter | |
| Rerank | **LLM-as-judge** (Gemini Flash via OpenRouter) | _not_ a true cross-encoder |
| OCR | Vision-LLM via OpenRouter (default) **or** Google Document AI (optional) | |
| Queue | **BullMQ + Redis** | 3 queues: `book-process`, `book-rechunk`, `grade-submission` |
| PDF | `@react-pdf/renderer` | question paper + answer key |
| Hosting (planned) | Vercel (web) + Render (worker + Redis) + Supabase + Pinecone | see `DEPLOY.md` |

No LangChain / LlamaIndex — direct provider SDK calls.

> **Doc drift to fix:** `turbo.json` `globalEnv` still lists `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`, but the code is fully OpenRouter-based (`apps/web/lib/env.ts`). Harmless but stale.

### Architecture

```
Browser ──> Next.js (apps/web) ──> Postgres (Drizzle)
                │  │                  Pinecone (retrieval)
                │  │                  OpenRouter (LLM/embed/rerank/OCR)
                │  └── enqueue ──> Redis ──> Worker (apps/worker)
                │                              ├─ book-process  (extract→OCR→chunk→embed→upsert)
                │                              ├─ book-rechunk  (re-embed w/ new strategy)
                │                              └─ grade-submission (OCR→LLM grade→store)
                └── Supabase Storage (PDF in / exports out)
```

---

## 2. How to run it locally (the only "missing" piece is config)

Already done in this worktree:
- ✅ `pnpm install` (deps installed)
- ✅ Postgres `:5433` + Redis `:6380` running (`infra-postgres-1`, `infra-redis-1`)
- ✅ All 12 tables migrated
- ✅ `pnpm typecheck` → 3/3 pass

**Remaining to boot the UI + flows:**
1. Create `apps/web/.env.local` and `apps/worker/.env` from `infra/env.example` and fill keys (you have them per `DEPLOY.md`): Clerk (`pk_test`/`sk_test`), `OPENROUTER_API_KEY`, `PINECONE_API_KEY`/`PINECONE_INDEX`, `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`.
2. `pnpm dev` (web on :3000) and `pnpm --filter @seena/worker dev` (worker).
3. Smoke test: sign up → upload a PDF → wait for `ready` → `/chat` "Generate FBISE 9th Physics paper from Chapter 2" → open exam → Export PDF.

> Without Clerk keys the root layout's `<ClerkProvider>` throws, so even the landing page won't render — keys are the gate, not code.

External resources that must exist (they do, in dev): Supabase `books` bucket; Pinecone index `seena-exams` (dim 3072, cosine, serverless). Optional: Google Document AI, Sentry, PostHog.

---

## 3. What's built — status by subsystem

Audited depth: **REAL** = fully wired, **PARTIAL** = works w/ gaps, **STUB** = placeholder.

| Subsystem | Status | Evidence |
|---|---|---|
| Book upload (presigned → DB → queue) | REAL | `api/books/*`, `components/book-uploader` |
| PDF extract + OCR fallback | REAL | `worker/extract-pipeline.ts`, `jobs/vision-ocr.ts` (batched, retry, resume) |
| Chunk + embed + Pinecone upsert | REAL | `worker/jobs/book-process.ts` (cap 1500 chunks, batch 100) |
| Re-chunking / re-embedding | REAL | `worker/jobs/book-rechunk.ts` (+ legacy backfill) |
| Retrieval (dual-phase + metadata filter) | REAL | `web/lib/rag/retrieve.ts` |
| Reranking (LLM-as-judge) | REAL | `web/lib/rag/rerank.ts` — Gemini Flash, vector-order fallback |
| Intent parsing (chat → structured) | REAL | `web/lib/generation/parse-intent.ts` |
| Pattern resolution | REAL | `web/lib/patterns/resolver.ts` + `shared/patterns/*` (FBISE/Punjab/Pindi/Cambridge) |
| Exam generation (tool-use) | REAL | `web/lib/generation/generate-exam.ts` + `exam-tool.ts` |
| Copyright guard (15-gram verbatim filter) | REAL, wired | `web/lib/generation/copyright-guard.ts` |
| Exam view / edit / regenerate question | REAL | `components/exam-builder/exam-view.tsx`, `api/exams/[id]/regenerate-question` |
| PDF export (paper + answer key) | REAL | `web/lib/pdf/exam-pdf.tsx` |
| Auto-grading (OCR → LLM → marks) | REAL | `worker/jobs/grade-submission.ts` (clamped marks, Zod-validated) |
| Custom patterns CRUD | REAL | `api/patterns/*`, `settings/patterns/*` |
| Quota (monthly exam count + USD cap) | REAL | `web/lib/quota.ts` |
| Rate limiting (Redis fixed-window) | REAL | `web/lib/ratelimit.ts` |
| Cost telemetry (`generations` table) | REAL | per-call tokens/latency/cost logged |
| Org settings / billing UI | STUB | `/settings` just redirects to patterns |
| Team / invite / role UI | MISSING | Clerk handles auth; no in-app member mgmt |
| Notifications (book ready / graded) | MISSING | status is poll/refresh only |

**No TODO/FIXME/stub markers anywhere in the codebase.** Quality debt is in coverage and a few specific gaps (§5), not half-built features.

---

## 4. User journeys

### J1 — Teacher onboarding
Sign up (Clerk) → user + org auto-provisioned on first request (`lib/auth.ts`) → lands on dashboard with usage counter.
**State:** REAL. **Gap:** every member is created as `admin` (role hardcoded — see §5).

### J2 — Upload a textbook
`/books/new` → pick PDF + tag (subject/grade/board) → presigned upload to Supabase → `book-process` job: extract → OCR if sparse → chunk → embed → Pinecone → status `ready`.
**State:** REAL. **Gap:** progress is poll/refresh (no live status, no email when ready).

### J3 — Generate an exam (chat)
`/chat` "Generate FBISE 9th Physics from Ch.2" → parse intent → resolve pattern → retrieve+rerank → LLM tool-call builds on-pattern paper → copyright filter → saved → link to `/exams/[id]`.
**State:** REAL. **Gap:** no confirm-before-spend step (user can't preview the resolved pattern/difficulty before the LLM call).

### J4 — Review / edit / export
`/exams/[id]` → edit title/questions, regenerate a single question (RAG-grounded), then Export PDF (paper + teacher answer key w/ source-page citations).
**State:** REAL. **Gap:** PDF-only (no DOCX); no "clone exam"; delete exists on detail but not on the list.

### J5 — Grade student answer sheets
On an exam → upload student PDF(s) → `grade-submission` job: OCR sheet → build answer key → LLM grades each Q with partial credit → marks clamped to `[0,max]` → stored + shown.
**State:** REAL. **Gap:** teacher can't override a mark or add rubric comments after grading; no per-student bulk upload UX.

### J6 — Custom exam patterns
`/settings/patterns/new` → define sections (type/count/marks) → reusable in generation; soft-delete (archive) supported.
**State:** REAL.

### J7 — Admin / cost control (implicit)
Per-org monthly exam limit (default 100) + USD cap (default $15) enforced before every paid call; rate limits per route.
**State:** REAL (backend). **Gap:** no UI to view/change limits or see cost breakdown.

---

## 5. Known gaps / what's missing (prioritized)

**P0 — before any real users**
1. **Auth role bug** — `lib/auth.ts:70` sets `desiredRole` to `'admin'` in _both_ ternary branches, so every member becomes admin and Clerk's `org:admin` role is ignored. Fix the ternary; decide default role.
2. **Zero automated tests** — no vitest/jest, no `*.test.*`. The money/correctness paths (grading marks, copyright guard, pattern resolution, quota math) have no regression net. Add a minimal suite first.
3. **Env/secrets** — drop in `.env.local` (web) + `.env` (worker) to run; rotate to Clerk `pk_live`/`sk_live` before launch (`DEPLOY.md §6`).

**P1 — launch polish**
4. No "confirm before generate" (cost/UX) in chat.
5. No teacher mark override / rubric comments after grading.
6. Exam delete missing on list view; no bulk ops; no "clone exam".
7. Settings page is a stub — no org config (limits, branding, billing) UI.
8. Notifications: book-ready / graded are refresh-only.

**P2 — scale / nice-to-have**
9. DOCX export (schema enum already supports it; renderer is PDF-only).
10. Team/invite UI in-app (currently Clerk-only).
11. Eval harness for retrieval + generation quality (see §6).
12. Observability: `SENTRY_DSN` / `POSTHOG_KEY` are accepted but confirm they're actually wired.
13. `turbo.json` `globalEnv` cleanup (stale Anthropic/OpenAI keys).

---

## 6. Evaluation criteria (how we judge it's working)

| Dimension | Metric / bar | How to check |
|---|---|---|
| **Ingestion** | Book reaches `ready`; `chunkCount > 0`; OCR only triggers when text density < 100 chars/page | Upload a text PDF and a scanned PDF; inspect `books`/`chunks_meta` |
| **Retrieval relevance** | Top-K chunks actually match the requested chapter/exercise | Spot-check retrieved context vs. the exam's `source_pages` |
| **Pattern fidelity** | Generated paper matches the spec exactly (section count, Q-count, marks/Q, total marks) | Compare exam payload to `shared/patterns/*` |
| **Content quality** | Questions answerable from the book; answer key correct; difficulty honored | Manual review by a teacher on a known chapter |
| **Copyright safety** | No verbatim ≥15-word spans from source in prompts/answers | `copyright-guard` runs post-gen; audit a sample |
| **Grading accuracy** | LLM marks vs. human marks within tolerance; MCQ exact, free-text partial credit; never > max | Grade 10–20 sheets, compare to a teacher's marking |
| **Cost & latency** | Generation ≈ 30–60s; cost logged per call; org stays under monthly cap | `generations` table; dashboard counter |
| **Reliability** | Jobs survive long OCR (10-min lock); retries on transient errors; idempotent reruns | Re-run a job; kill mid-OCR and confirm resume |
| **Tenant isolation** | No cross-org data leakage | Every query filters by `orgId`; verify with 2 orgs |

**Suggested first eval gate (P0/P1):** a fixed set of 3 textbooks × 3 patterns → assert structure matches spec 100% of the time, copyright filter catches planted verbatim, and grading matches a human key within ±1 mark/question on a 20-sheet sample.

---

## 7. Roadmap / sequencing

No fabricated dates — ordered by dependency. Rough sizing in (S/M/L).

- **Now → boot & smoke test (S):** add env files, `pnpm dev` + worker, run the J2→J5 smoke path end-to-end against real keys. _This is the immediate next step._
- **Phase 0 — correctness net (S–M):** fix auth role bug; add a focused test suite (copyright guard, pattern resolver, quota math, grading clamp); wire the §6 first eval gate.
- **Phase 1 — launch readiness (M):** Clerk production instance; deploy web (Vercel) + worker (Render) per `DEPLOY.md`; confirm-before-generate; exam delete on list; teacher mark override.
- **Phase 2 — admin & UX (M–L):** org settings UI (limits/branding/cost breakdown); notifications (book ready / graded); team/invite UI; "clone exam".
- **Phase 3 — scale & quality (L):** DOCX export; standing eval harness + quality dashboard; observability (Sentry/PostHog) confirmed; reranker upgrade if relevance falls short.
