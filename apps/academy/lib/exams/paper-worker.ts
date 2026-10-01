import { createHmac, timingSafeEqual } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
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
 * Two implementations behind one interface:
 *   * HttpPaperWorker      the real worker, configured by EXAM_WORKER_URL and
 *                          EXAM_WORKER_TOKEN. Nothing is invented: unset means
 *                          this class is not used.
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

export class UnconfiguredPaperWorker implements PaperWorker {
  readonly name = 'unconfigured';
  async submit(): Promise<void> {
    throw new Error('no paper generation worker is configured (set EXAM_WORKER_URL and EXAM_WORKER_TOKEN)');
  }
}

export function resolvePaperWorker(ingest: IngestFn, env: NodeJS.ProcessEnv = process.env): PaperWorker {
  if (env.EXAM_WORKER_URL && env.EXAM_WORKER_TOKEN) {
    const site = env.NEXT_PUBLIC_SITE_URL ?? 'http://localhost:3011';
    return new HttpPaperWorker(env.EXAM_WORKER_URL, env.EXAM_WORKER_TOKEN, `${site}/api/exam-paper/callback`);
  }
  if (env.NODE_ENV !== 'production') return new DevStubPaperWorker(ingest);
  return new UnconfiguredPaperWorker();
}

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
  let submitted = 0;
  let failed = 0;
  for (const j of jobs) {
    try {
      await w.submit({
        jobId: j.id,
        tenantId: j.tenant_id,
        examSubjectId: j.exam_subject_id,
        pattern: j.pattern_snapshot as PaperPattern,
        chapters: j.chapters,
        totalMarks: j.total_marks,
        setCount: j.set_count,
        title: `${(j.pattern_snapshot as PaperPattern).code} paper`,
      });
      submitted += 1;
    } catch (cause) {
      failed += 1;
      await admin.rpc('fn_record_paper_job_failure', { p_job_id: j.id, p_error: cause instanceof Error ? cause.message : 'worker submit failed' });
    }
  }
  return { claimed: jobs.length, submitted, failed };
}
