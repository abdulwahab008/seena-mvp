import { Queue, Worker, type Job } from 'bullmq';
import { Redis } from 'ioredis';
import { env } from './env.js';
import { processBook, type BookProcessJob } from './jobs/book-process.js';
import { rechunkBook, type BookRechunkJob } from './jobs/book-rechunk.js';
import { gradeSubmission, type GradeSubmissionJob } from './jobs/grade-submission.js';
import { purgeOldSubmissions } from './jobs/retention.js';

const connection = new Redis(env().REDIS_URL, { maxRetriesPerRequest: null });

// OCR + embedding holds the event loop for tens of seconds at a time, so the
// default 30s BullMQ lock isn't long enough — we extend it to 10 minutes and
// only re-attempt stalled jobs once.
const LONG_JOB_OPTS = {
  lockDuration: 600_000,
  stalledInterval: 60_000,
  maxStalledCount: 1,
};

const bookWorker = new Worker<BookProcessJob>(
  'book-process',
  async (job: Job<BookProcessJob>) => {
    await processBook(job.data);
  },
  {
    connection,
    concurrency: env().WORKER_CONCURRENCY,
    ...LONG_JOB_OPTS,
  },
);

bookWorker.on('completed', (job) => {
  console.log(`[worker] book-process ${job.id} ✓`);
});

bookWorker.on('failed', (job, err) => {
  console.error(`[worker] book-process ${job?.id ?? '?'} ✗`, err.message);
});

const rechunkWorker = new Worker<BookRechunkJob>(
  'book-rechunk',
  async (job: Job<BookRechunkJob>) => {
    await rechunkBook(job.data);
  },
  {
    connection,
    concurrency: env().WORKER_CONCURRENCY,
    ...LONG_JOB_OPTS,
  },
);

rechunkWorker.on('completed', (job) => {
  console.log(`[worker] book-rechunk ${job.id} ✓`);
});

rechunkWorker.on('failed', (job, err) => {
  console.error(`[worker] book-rechunk ${job?.id ?? '?'} ✗`, err.message);
});

const gradeWorker = new Worker<GradeSubmissionJob>(
  'grade-submission',
  async (job: Job<GradeSubmissionJob>) => {
    await gradeSubmission(job.data);
  },
  {
    connection,
    concurrency: env().WORKER_CONCURRENCY,
    ...LONG_JOB_OPTS,
  },
);

gradeWorker.on('completed', (job) => {
  console.log(`[worker] grade-submission ${job.id} ✓`);
});

gradeWorker.on('failed', (job, err) => {
  console.error(`[worker] grade-submission ${job?.id ?? '?'} ✗`, err.message);
});

// Daily retention purge (no-op unless SUBMISSION_RETENTION_DAYS is set).
const retentionQueue = new Queue('retention', { connection });
void retentionQueue
  .add('purge', {}, { repeat: { pattern: '0 3 * * *' }, removeOnComplete: true, removeOnFail: 10 })
  .catch((e) => console.error('[worker] failed to schedule retention purge', e));
const retentionWorker = new Worker(
  'retention',
  async () => {
    await purgeOldSubmissions();
  },
  { connection },
);
retentionWorker.on('failed', (job, err) => {
  console.error(`[worker] retention ${job?.id ?? '?'} ✗`, err.message);
});

console.log(`[worker] online — concurrency=${env().WORKER_CONCURRENCY}`);

// A stray rejection/exception must not silently take down all three workers.
process.on('unhandledRejection', (reason) => {
  console.error('[worker] unhandledRejection', reason);
});
process.on('uncaughtException', (err) => {
  console.error('[worker] uncaughtException', err);
});

async function shutdown(signal: string) {
  console.log(`[worker] received ${signal}, draining…`);
  await Promise.all([
    bookWorker.close(),
    rechunkWorker.close(),
    gradeWorker.close(),
    retentionWorker.close(),
  ]);
  await connection.quit();
  process.exit(0);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
