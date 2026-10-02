import { describe, expect, it, vi } from 'vitest';
import {
  OFFLINE_QUEUE_KEY,
  dequeue,
  enqueue,
  flushQueue,
  queueDepth,
  readQueue,
  recordAttempt,
  type QueueStore,
  type QueuedRegister,
  type SyncOutcome,
} from './offline-queue';

function memoryStore(initial?: string): QueueStore {
  const map = new Map<string, string>();
  if (initial !== undefined) map.set(OFFLINE_QUEUE_KEY, initial);
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => {
      map.set(k, v);
    },
  };
}

const CAPTURE = {
  sectionId: '11111111-1111-4111-8111-111111111111',
  attendanceDate: '2026-08-13',
  exceptions: [{ enrolmentId: '22222222-2222-4222-8222-222222222222', status: 'absent' }],
  capturedAt: '2026-08-13T03:20:00.000Z',
};

describe('offline queue storage', () => {
  it('starts empty and survives a corrupted payload', () => {
    expect(queueDepth(memoryStore())).toBe(0);
    expect(readQueue(memoryStore('not json'))).toEqual([]);
    expect(readQueue(memoryStore('{"not":"an array"}'))).toEqual([]);
  });

  // AC1: "the queue depth increments by 1".
  it('enqueue increments the depth by one and preserves the capture', () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });

    expect(queueDepth(store)).toBe(1);
    const [entry] = readQueue(store);
    expect(entry?.idempotencyKey).toBe('key-1');
    expect(entry?.capturedAt).toBe('2026-08-13T03:20:00.000Z');
    expect(entry?.exceptions).toEqual(CAPTURE.exceptions);
    expect(entry?.attempts).toBe(0);
  });

  it('queues a different section and date separately', () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    enqueue(store, { ...CAPTURE, attendanceDate: '2026-08-14', idempotencyKey: 'key-2' });

    expect(queueDepth(store)).toBe(2);
  });

  it('re-submitting the same register while still offline replaces the earlier capture', () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    enqueue(store, {
      ...CAPTURE,
      idempotencyKey: 'key-2',
      exceptions: [{ enrolmentId: '22222222-2222-4222-8222-222222222222', status: 'late' }],
    });

    expect(queueDepth(store)).toBe(1);
    expect(readQueue(store)[0]?.idempotencyKey).toBe('key-2');
    expect(readQueue(store)[0]?.exceptions[0]?.status).toBe('late');
  });

  it('dequeue removes exactly the named entry', () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    enqueue(store, { ...CAPTURE, attendanceDate: '2026-08-14', idempotencyKey: 'key-2' });

    dequeue(store, 'key-1');
    expect(readQueue(store).map((e) => e.idempotencyKey)).toEqual(['key-2']);
  });

  it('recordAttempt counts the try and keeps the entry queued', () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });

    recordAttempt(store, 'key-1', 'Failed to fetch');
    expect(queueDepth(store)).toBe(1);
    expect(readQueue(store)[0]?.attempts).toBe(1);
    expect(readQueue(store)[0]?.lastError).toBe('Failed to fetch');
  });
});

describe('flushQueue', () => {
  it('uploads a queued register and empties the queue', async () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    const send = vi.fn<(entry: QueuedRegister) => Promise<SyncOutcome>>().mockResolvedValue({ kind: 'applied', saved: 3 });

    const report = await flushQueue(store, send);

    expect(send).toHaveBeenCalledTimes(1);
    expect(report).toMatchObject({ applied: 1, remaining: 0 });
    expect(queueDepth(store)).toBe(0);
  });

  // AC2, client half: the network flaps, the client retries, and every
  // retry carries the SAME idempotency key — that reuse is the only
  // reason the server can answer the 2nd and 3rd calls from its ledger.
  it('retries a network failure with the same idempotency key and keeps the depth at 1', async () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    const send = vi
      .fn<(entry: QueuedRegister) => Promise<SyncOutcome>>()
      .mockResolvedValue({ kind: 'failed', retryable: true, error: 'Failed to fetch' });

    for (let i = 0; i < 3; i += 1) {
      const report = await flushQueue(store, send);
      expect(report).toMatchObject({ retrying: 1, remaining: 1 });
    }

    expect(send).toHaveBeenCalledTimes(3);
    expect(new Set(send.mock.calls.map(([entry]) => entry.idempotencyKey))).toEqual(new Set(['key-1']));
    expect(queueDepth(store)).toBe(1);
    expect(readQueue(store)[0]?.attempts).toBe(3);

    send.mockResolvedValue({ kind: 'applied', saved: 3 });
    const final = await flushQueue(store, send);
    expect(final).toMatchObject({ applied: 1, remaining: 0 });
    expect(queueDepth(store)).toBe(0);
  });

  // AC4, client half: the server turned the submission into correction
  // requests, so the entry is done — retrying would only be refused again.
  it('dequeues a locked-date rejection and reports the corrections raised', async () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    const send = vi
      .fn<(entry: QueuedRegister) => Promise<SyncOutcome>>()
      .mockResolvedValue({ kind: 'rejected_locked', correctionsRequested: 3 });

    const report = await flushQueue(store, send);

    expect(report).toMatchObject({ locked: 1, applied: 0, remaining: 0 });
    expect(queueDepth(store)).toBe(0);
  });

  it('dequeues a stale rejection and a non-retryable failure, surfacing the error', async () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    enqueue(store, { ...CAPTURE, attendanceDate: '2026-08-14', idempotencyKey: 'key-2' });
    const send = vi
      .fn<(entry: QueuedRegister) => Promise<SyncOutcome>>()
      .mockResolvedValueOnce({ kind: 'rejected_stale' })
      .mockResolvedValueOnce({ kind: 'failed', retryable: false, error: 'This is a declared holiday.' });

    const report = await flushQueue(store, send);

    expect(report).toMatchObject({ stale: 1, remaining: 0, dropped: ['This is a declared holiday.'] });
    expect(queueDepth(store)).toBe(0);
  });

  it('drains multiple queued registers oldest-first', async () => {
    const store = memoryStore();
    enqueue(store, { ...CAPTURE, idempotencyKey: 'key-1' });
    enqueue(store, { ...CAPTURE, attendanceDate: '2026-08-14', idempotencyKey: 'key-2' });
    const send = vi.fn<(entry: QueuedRegister) => Promise<SyncOutcome>>().mockResolvedValue({ kind: 'applied', saved: 3 });

    const report = await flushQueue(store, send);

    expect(send.mock.calls.map(([entry]) => entry.idempotencyKey)).toEqual(['key-1', 'key-2']);
    expect(report).toMatchObject({ applied: 2, remaining: 0 });
  });
});
