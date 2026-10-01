import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  DevStubPaperWorker,
  HttpPaperWorker,
  UnconfiguredPaperWorker,
  dispatchDueJobs,
  resolvePaperWorker,
  signCallbackBody,
  verifyCallbackSignature,
  type PaperJobPayload,
  type PaperWorker,
} from './paper-worker';
import { diffPaperAgainstPattern, type GeneratedPaperSet, type PaperPattern } from './paper-pattern';

const SECRET = 'a-callback-secret-of-16+chars';
const pattern: PaperPattern = {
  code: 'P',
  board: 'FBISE',
  total_marks: 6,
  sections: [
    { no: 1, name: 'A', type: 'mcq', count: 4, marks_each: 1 },
    { no: 2, name: 'B', type: 'short', count: 1, marks_each: 2 },
  ],
};
const job: PaperJobPayload = { jobId: 'job-1', tenantId: 't', examSubjectId: 'es', pattern, chapters: ['Ch.1'], totalMarks: 6, setCount: 2, title: 'P paper' };

describe('callback signature', () => {
  const body = JSON.stringify({ job_id: 'job-1', payload: { sets: [] } });

  it('accepts the signature the worker computed', () => {
    expect(verifyCallbackSignature(body, signCallbackBody(body, SECRET), SECRET)).toBe(true);
    expect(verifyCallbackSignature(body, `sha256=${signCallbackBody(body, SECRET)}`, SECRET)).toBe(true);
  });

  it('rejects a tampered body, a wrong secret and garbage', () => {
    const sig = signCallbackBody(body, SECRET);
    expect(verifyCallbackSignature(`${body} `, sig, SECRET)).toBe(false);
    expect(verifyCallbackSignature(body, signCallbackBody(body, 'another-secret-also-16-chars'), SECRET)).toBe(false);
    expect(verifyCallbackSignature(body, 'not-hex', SECRET)).toBe(false);
    expect(verifyCallbackSignature(body, '', SECRET)).toBe(false);
    expect(verifyCallbackSignature(body, null, SECRET)).toBe(false);
  });

  it('fails closed when the secret is unset or short', () => {
    expect(verifyCallbackSignature(body, signCallbackBody(body, 'short'), 'short')).toBe(false);
    expect(verifyCallbackSignature(body, signCallbackBody(body, SECRET), undefined)).toBe(false);
  });
});

describe('resolvePaperWorker', () => {
  const ingest = async () => {};
  it('uses the HTTP worker when it is configured', () => {
    expect(resolvePaperWorker(ingest, { EXAM_WORKER_URL: 'https://w', EXAM_WORKER_TOKEN: 't', NODE_ENV: 'production' } as NodeJS.ProcessEnv).name).toBe('http');
  });
  it('falls back to the development stub outside production', () => {
    expect(resolvePaperWorker(ingest, { NODE_ENV: 'development' } as NodeJS.ProcessEnv).name).toBe('dev-stub');
  });
  it('is unconfigured, never the stub, in production without a worker', async () => {
    const w = resolvePaperWorker(ingest, { NODE_ENV: 'production' } as NodeJS.ProcessEnv);
    expect(w).toBeInstanceOf(UnconfiguredPaperWorker);
    await expect(w.submit(job)).rejects.toThrow(/no paper generation worker/);
  });
});

describe('HttpPaperWorker', () => {
  it('posts the job with the bearer token and the callback url', async () => {
    const fetchImpl = vi.fn(async () => new Response('{}', { status: 202 }));
    await new HttpPaperWorker('https://worker/gen', 'tok', 'https://app/api/exam-paper/callback', fetchImpl as unknown as typeof fetch).submit(job);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://worker/gen');
    expect((init.headers as Record<string, string>).authorization).toBe('Bearer tok');
    expect(JSON.parse(init.body as string)).toMatchObject({ job: { jobId: 'job-1' }, callback_url: 'https://app/api/exam-paper/callback' });
  });

  it('throws when the worker refuses, so the attempt is recorded as failed', async () => {
    const fetchImpl = vi.fn(async () => new Response('no', { status: 503 }));
    await expect(new HttpPaperWorker('https://w', 't', 'https://c', fetchImpl as unknown as typeof fetch).submit(job)).rejects.toThrow('worker answered 503');
  });
});

describe('DevStubPaperWorker', () => {
  it('ingests a pattern-conforming paper for every requested set', async () => {
    let received: { sets: GeneratedPaperSet[] } | null = null;
    await new DevStubPaperWorker(async (_id, payload) => {
      received = payload as { sets: GeneratedPaperSet[] };
    }).submit(job);
    expect(received!.sets.map((s) => s.set_code)).toEqual(['A', 'B']);
    for (const s of received!.sets) expect(diffPaperAgainstPattern(pattern, s.questions)).toBeNull();
  });
});

describe('dispatchDueJobs', () => {
  const row = { id: 'job-1', tenant_id: 't', exam_subject_id: 'es', pattern_snapshot: pattern, chapters: ['Ch.1'], total_marks: 6, set_count: 1 };
  const fakeAdmin = (jobs: unknown[]) => {
    const calls: { fn: string; args: unknown }[] = [];
    const admin = {
      rpc: vi.fn(async (fn: string, args: unknown) => {
        calls.push({ fn, args });
        return { data: fn === 'fn_claim_paper_jobs' ? jobs : null, error: null };
      }),
    } as unknown as SupabaseClient;
    return { admin, calls };
  };

  it('submits each claimed job to the worker', async () => {
    const { admin, calls } = fakeAdmin([row]);
    const worker: PaperWorker = { name: 'x', submit: vi.fn(async () => {}) };
    expect(await dispatchDueJobs(admin, worker)).toEqual({ claimed: 1, submitted: 1, failed: 0 });
    expect(calls.map((c) => c.fn)).toEqual(['fn_fail_stalled_paper_jobs', 'fn_claim_paper_jobs']);
  });

  it('records an unreachable worker as a failed attempt instead of throwing', async () => {
    const { admin, calls } = fakeAdmin([row]);
    const worker: PaperWorker = { name: 'x', submit: async () => { throw new Error('ECONNREFUSED'); } };
    expect(await dispatchDueJobs(admin, worker)).toEqual({ claimed: 1, submitted: 0, failed: 1 });
    expect(calls.at(-1)).toEqual({ fn: 'fn_record_paper_job_failure', args: { p_job_id: 'job-1', p_error: 'ECONNREFUSED' } });
  });

  it('does nothing when no job is due', async () => {
    const { admin } = fakeAdmin([]);
    expect(await dispatchDueJobs(admin, { name: 'x', submit: vi.fn() })).toEqual({ claimed: 0, submitted: 0, failed: 0 });
  });
});
