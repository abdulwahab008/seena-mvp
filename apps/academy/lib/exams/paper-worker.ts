import { createHmac, timingSafeEqual } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { buildStubPaperSets, type PaperPattern } from './paper-pattern';

/**
 * FR-I05. The seam between the school system and the paper generation worker
 * (Seena Exams, which runs outside Supabase on Render).
 *
 *   job queued in the database
 *     -> dispatchDueJobs() claims it and hands it to a PaperWorker
 *     -> the worker generates and POSTs a signed callback to
 *        /api/exam-paper/callback
 *     -> fn_ingest_generated_paper() validates and stores it (idempotent on job id)
 *
 * Implementations behind one interface, chosen in this order:
 *   * HttpPaperWorker      the real worker, configured by EXAM_WORKER_URL and
 *                          EXAM_WORKER_TOKEN. Nothing is invented: unset means
 *                          this class is not used.
 *   * AiPaperWorker        writes the questions with a language model through
 *                          OpenRouter (OPENROUTER_API_KEY), inside this app, and
 *                          ingests through the same database function.
 *   * DevStubPaperWorker   development only. Builds a pattern-conforming placeholder
 *                          paper and ingests it through the SAME database function
 *                          the signed callback uses, so the whole path is exercised
 *                          without a generation service. It is never selected in
 *                          production.
 * With neither available the worker is Unconfigured and every submit fails, which
 * the database turns into retries and finally a 'failed' job with a retry action.
 */
export type PaperJobPayload = {
  jobId: string;
  tenantId: string;
  examSubjectId: string;
  pattern: PaperPattern;
  chapters: string[];
  totalMarks: number;
  setCount: number;
  title: string;
  subject?: string;
  className?: string;
};

export interface PaperWorker {
  readonly name: string;
  /** Accepts the job. Throwing means the worker is unreachable or refused it. */
  submit(job: PaperJobPayload): Promise<void>;
}

/** Hex HMAC-SHA256 of the raw callback body, as the worker signs it. */
export function signCallbackBody(rawBody: string, secret: string): string {
  return createHmac('sha256', secret).update(rawBody, 'utf8').digest('hex');
}

/** Fails closed: an unset or short secret verifies nothing. */
export function verifyCallbackSignature(rawBody: string, header: string | null | undefined, secret: string | undefined = process.env.EXAM_PAPER_CALLBACK_SECRET): boolean {
  if (!secret || secret.length < 16 || !header) return false;
  const given = header.replace(/^sha256=/, '').trim();
  const expected = signCallbackBody(rawBody, secret);
  if (given.length !== expected.length || !/^[0-9a-f]+$/i.test(given)) return false;
  return timingSafeEqual(Buffer.from(given, 'hex'), Buffer.from(expected, 'hex'));
}

export class HttpPaperWorker implements PaperWorker {
  readonly name = 'http';
  constructor(
    private readonly url: string,
    private readonly token: string,
    private readonly callbackUrl: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async submit(job: PaperJobPayload): Promise<void> {
    const res = await this.fetchImpl(this.url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${this.token}` },
      body: JSON.stringify({ job, callback_url: this.callbackUrl }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) throw new Error(`worker answered ${res.status}`);
  }
}

export type IngestFn = (jobId: string, payload: unknown) => Promise<void>;

export class DevStubPaperWorker implements PaperWorker {
  readonly name = 'dev-stub';
  constructor(private readonly ingest: IngestFn) {}

  async submit(job: PaperJobPayload): Promise<void> {
    const sets = buildStubPaperSets(job.pattern, job.chapters, job.setCount, job.title);
    await this.ingest(job.jobId, { sets });
  }
}

const AiAnswer = z.object({
  questions: z.array(
    z.object({
      id: z.string(),
      text: z.string().trim().min(1).max(2000),
      options: z.array(z.string().trim().min(1).max(500)).optional(),
      answer: z.string().trim().max(2000).optional(),
    }),
  ),
});

const AI_SYSTEM_PROMPT = `You write exam questions for schools in Pakistan.
You are given numbered slots. Write exactly one question for every slot id, on that slot's chapter and of that slot's type.
- mcq: a question with exactly 4 options (text only, no "A)" prefixes) and "answer" set to the letter of the correct option: A, B, C or D.
- short: a question answerable in a few lines. Put a brief model answer in "answer".
- long: a question that needs a detailed answer worth its marks. Put the key points of the answer in "answer".
Write original questions in your own words; never copy passages from a textbook.
Questions in different sets must be different questions, not rewordings of each other.
Reply with JSON only: {"questions":[{"id":"...","text":"...","options":["...","...","...","..."],"answer":"..."}]}`;

/**
 * The paper's structure (sets, sections, marks, chapter per question) comes from
 * the pattern, exactly as the development stub builds it, so it always passes the
 * database's pattern and set-blueprint checks. The model only writes the text.
 * An incomplete or unparseable answer throws, which the database turns into a retry.
 */
export class AiPaperWorker implements PaperWorker {
  readonly name = 'ai';
  constructor(
    private readonly ingest: IngestFn,
    private readonly apiKey: string,
    private readonly model: string,
    private readonly baseUrl: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async submit(job: PaperJobPayload): Promise<void> {
    const sets = buildStubPaperSets(job.pattern, job.chapters, job.setCount, job.title);
    const slots = sets.flatMap((s) =>
      s.questions.map((q) => ({ id: `${s.set_code}-${q.section_no}-${q.question_no}`, set: s.set_code, type: q.type, marks: q.marks, chapter: q.chapter })),
    );
    const brief = [
      `Subject: ${job.subject ?? 'not given'}`,
      `Class: ${job.className ?? 'not given'}`,
      `Board: ${job.pattern.board}`,
      `Chapters: ${job.chapters.join(', ')}`,
      `Slots: ${JSON.stringify(slots)}`,
    ].join('\n');

    const res = await this.fetchImpl(`${this.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${this.apiKey}` },
      body: JSON.stringify({
        model: this.model,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: AI_SYSTEM_PROMPT },
          { role: 'user', content: brief },
        ],
      }),
      signal: AbortSignal.timeout(240_000),
    });
    if (!res.ok) throw new Error(`AI service answered ${res.status}`);
    const body = (await res.json()) as { choices?: { message?: { content?: string } }[] };
    const content = (body.choices?.[0]?.message?.content ?? '').replace(/^\s*```(?:json)?|```\s*$/g, '');
    let parsed: z.infer<typeof AiAnswer>;
    try {
      parsed = AiAnswer.parse(JSON.parse(content));
    } catch {
      throw new Error('the AI answer was not in the expected format');
    }
    const written = new Map(parsed.questions.map((q) => [q.id, q]));

    for (const s of sets) {
      for (const q of s.questions) {
        const id = `${s.set_code}-${q.section_no}-${q.question_no}`;
        const w = written.get(id);
        if (!w) throw new Error(`the AI did not write question ${id}`);
        q.text = w.text;
        q.answer = w.answer || undefined;
        if (q.type === 'mcq') {
          if (w.options?.length !== 4 || !/^[A-D]$/.test(w.answer ?? '')) throw new Error(`question ${id} needs 4 options and an answer letter`);
          q.options = w.options;
        }
      }
    }
    await this.ingest(job.jobId, { sets });
  }
}

export class UnconfiguredPaperWorker implements PaperWorker {
  readonly name = 'unconfigured';
  async submit(): Promise<void> {
    throw new Error('no paper generator is configured (set OPENROUTER_API_KEY, or EXAM_WORKER_URL and EXAM_WORKER_TOKEN)');
  }
}

export function resolvePaperWorker(ingest: IngestFn, env: NodeJS.ProcessEnv = process.env): PaperWorker {
  if (env.EXAM_WORKER_URL && env.EXAM_WORKER_TOKEN) {
    const site = env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3011';
    return new HttpPaperWorker(env.EXAM_WORKER_URL, env.EXAM_WORKER_TOKEN, `${site}/api/exam-paper/callback`);
  }
  if (env.OPENROUTER_API_KEY) {
    return new AiPaperWorker(
      ingest,
      env.OPENROUTER_API_KEY,
      env.OPENROUTER_MODEL ?? 'anthropic/claude-sonnet-4.5',
      env.OPENROUTER_BASE_URL ?? 'https://openrouter.ai/api/v1',
    );
  }
  if (env.NODE_ENV !== 'production') return new DevStubPaperWorker(ingest);
  return new UnconfiguredPaperWorker();
}

type ExamSubjectNames = { id: string; class_subject: { subject: { name_en: string } | null; class_level: { name_en: string } | null } | null };

type JobRow = {
  id: string;
  tenant_id: string;
  exam_subject_id: string;
  pattern_snapshot: unknown;
  chapters: string[];
  total_marks: number;
  set_count: number;
};

/**
 * Claims due jobs and submits each to the worker. A submit that throws is
 * recorded as a failed attempt; the database re-queues it with backoff or ends
 * it 'failed' after the third retry. Returns what happened, for the caller and
 * the cron response.
 */
export async function dispatchDueJobs(admin: SupabaseClient, worker?: PaperWorker, limit = 5): Promise<{ claimed: number; submitted: number; failed: number }> {
  const ingest: IngestFn = async (jobId, payload) => {
    const { error } = await admin.rpc('fn_ingest_generated_paper', { p_job_id: jobId, p_payload: payload });
    if (error) throw new Error(error.message);
  };
  const w = worker ?? resolvePaperWorker(ingest);
  await admin.rpc('fn_fail_stalled_paper_jobs', { p_minutes: 15 });
  const { data, error } = await admin.rpc('fn_claim_paper_jobs', { p_limit: limit });
  if (error) throw new Error(error.message);
  const jobs = (data ?? []) as JobRow[];
  const names = new Map<string, { subject?: string; className?: string }>();
  if (jobs.length > 0) {
    const { data: ctx } = await admin
      .from('exam_subject')
      .select('id, class_subject(subject(name_en), class_level(name_en))')
      .in('id', jobs.map((j) => j.exam_subject_id));
    for (const row of (ctx ?? []) as unknown as ExamSubjectNames[]) {
      names.set(row.id, { subject: row.class_subject?.subject?.name_en, className: row.class_subject?.class_level?.name_en });
    }
  }
  let submitted = 0;
  let failed = 0;
  for (const j of jobs) {
    const { subject, className } = names.get(j.exam_subject_id) ?? {};
    try {
      await w.submit({
        jobId: j.id,
        tenantId: j.tenant_id,
        examSubjectId: j.exam_subject_id,
        pattern: j.pattern_snapshot as PaperPattern,
        chapters: j.chapters,
        totalMarks: j.total_marks,
        setCount: j.set_count,
        title: [subject, className, `${(j.pattern_snapshot as PaperPattern).code} paper`].filter(Boolean).join(' · '),
        subject,
        className,
      });
      submitted += 1;
    } catch (cause) {
      failed += 1;
      await admin.rpc('fn_record_paper_job_failure', { p_job_id: j.id, p_error: cause instanceof Error ? cause.message : 'worker submit failed' });
    }
  }
  return { claimed: jobs.length, submitted, failed };
}
