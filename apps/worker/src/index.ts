import { Worker, type Job } from 'bullmq';
import { Redis } from 'ioredis';
import { env } from './env.js';
import { processBook, type BookProcessJob } from './jobs/book-process.js';
import { rechunkBook, type BookRechunkJob } from './jobs/book-rechunk.js';

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

console.log(`[worker] online — concurrency=${env().WORKER_CONCURRENCY}`);

async function shutdown(signal: string) {
  console.log(`[worker] received ${signal}, draining…`);
  await Promise.all([bookWorker.close(), rechunkWorker.close()]);
  await connection.quit();
  process.exit(0);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
