import { describe, expect, it } from 'vitest';
import { buildBatch, enqueueBatch, flushQueue, readQueue, type BoardingEvent, type QueueStore } from './boarding-queue';

const memoryStore = (): QueueStore & { data: Map<string, string> } => {
  const data = new Map<string, string>();
  return { data, getItem: (k) => data.get(k) ?? null, setItem: (k, v) => void data.set(k, v) };
};
let n = 0;
const newId = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;
const students = Array.from({ length: 40 }, (_, i) => `student-${i + 1}`);

describe('buildBatch (FR-P05 AC1)', () => {
  it('marks a 40-student manifest from mark-all plus three exceptions', () => {
    const events = buildBatch('leg-1', students, new Set(['student-5', 'student-6', 'student-7']), 'boarded', new Date('2026-09-14T01:50:00Z'), newId);
    expect(events).toHaveLength(40);
    expect(events.filter((e) => e.state === 'absent').map((e) => e.student_id)).toEqual(['student-5', 'student-6', 'student-7']);
    expect(events.filter((e) => e.state === 'boarded')).toHaveLength(37);
    expect(new Set(events.map((e) => e.device_event_id)).size).toBe(40);
    expect(events[0]!.marked_at).toBe('2026-09-14T01:50:00.000Z');
  });
  it('uses dropped on a drop leg', () => {
    const events = buildBatch('leg-2', ['a', 'b'], new Set(['b']), 'dropped', new Date(), newId);
    expect(events.map((e) => e.state)).toEqual(['dropped', 'absent']);
  });
});

describe('flushQueue (FR-P05 AC2)', () => {
  it('keeps a failed batch with the SAME event ids and clears it once the server accepts', async () => {
    const store = memoryStore();
    const events = buildBatch('leg-1', students, new Set(), 'boarded', new Date(), newId);
    enqueueBatch(store, 'batch-1', events);
    const seen: BoardingEvent[][] = [];
    const offline = async (e: BoardingEvent[]) => {
      seen.push(e);
      return { ok: false, error: 'offline' };
    };
    await flushQueue(store, offline);
    await flushQueue(store, offline);
    await flushQueue(store, offline);
    expect(readQueue(store)).toHaveLength(1);
    expect(readQueue(store)[0]!.attempts).toBe(3);
    expect(seen).toHaveLength(3);
    expect(seen.every((s) => s.map((e) => e.device_event_id).join() === events.map((e) => e.device_event_id).join())).toBe(true);
    const r = await flushQueue(store, async () => ({ ok: true }));
    expect(r).toEqual({ sent: 1, pending: 0 });
  });
  it('treats a thrown network error as a failure, not a loss', async () => {
    const store = memoryStore();
    enqueueBatch(store, 'b', buildBatch('l', ['a'], new Set(), 'boarded', new Date(), newId));
    await flushQueue(store, async () => {
      throw new Error('Failed to fetch');
    });
    expect(readQueue(store)[0]!.lastError).toBe('Failed to fetch');
  });
  it('does not enqueue the same batch twice and survives a corrupted store', () => {
    const store = memoryStore();
    const events = buildBatch('l', ['a'], new Set(), 'boarded', new Date(), newId);
    enqueueBatch(store, 'b', events);
    enqueueBatch(store, 'b', events);
    expect(readQueue(store)).toHaveLength(1);
    store.setItem('seena.transport.boarding-queue.v1', '{not json');
    expect(readQueue(store)).toEqual([]);
  });
});
