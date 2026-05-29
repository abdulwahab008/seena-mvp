import { Queue } from 'bullmq';
import IORedis from 'ioredis';
import { env } from './env';

declare global {
  // eslint-disable-next-line no-var
  var __redis: IORedis | undefined;
  // eslint-disable-next-line no-var
  var __queues: Record<string, Queue> | undefined;
}

export function redis(): IORedis {
  if (globalThis.__redis) return globalThis.__redis;
  const c = new IORedis(env().REDIS_URL, { maxRetriesPerRequest: null });
  globalThis.__redis = c;
  return c;
}

export const QUEUE_NAMES = {
  bookProcess: 'book-process',
  bookRechunk: 'book-rechunk',
  examExport: 'exam-export',
} as const;

export type BookProcessJob = {
  bookId: string;
  orgId: string;
};

export type BookRechunkJob = {
  chunkingId: string;
  bookId: string;
  orgId: string;
};

export type ExamExportJob = {
  examId: string;
  orgId: string;
  format: 'pdf' | 'docx';
};

export function getQueue(name: string): Queue {
  globalThis.__queues ??= {};
  if (!globalThis.__queues[name]) {
    globalThis.__queues[name] = new Queue(name, { connection: redis() });
  }
  return globalThis.__queues[name]!;
}

export function bookProcessQueue() {
  return getQueue(QUEUE_NAMES.bookProcess);
}

export function bookRechunkQueue() {
  return getQueue(QUEUE_NAMES.bookRechunk);
}

export function examExportQueue() {
  return getQueue(QUEUE_NAMES.examExport);
}
