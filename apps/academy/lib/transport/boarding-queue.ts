// FR-P05: the device-side half of boarding attendance.
//
// The conductor marks the manifest on a cheap Android phone that may lose signal
// for 25 minutes. A batch is built ONCE, with a client-generated
// device_event_id per student, persisted to localStorage and re-sent unchanged
// on every retry. The server keys on that id (unique index), so a batch sent
// three times stores one event per student. Same limits as the attendance queue
// in offline-queue.ts: localStorage, no service worker, so the open page keeps
// the queue across drops of signal but not across a hard reload while offline.
//
// Every function takes its store explicitly so the logic is unit testable
// without a DOM.

export type BoardingState = 'boarded' | 'absent' | 'dropped';

export type BoardingEvent = {
  device_event_id: string;
  trip_leg_id: string;
  student_id: string;
  state: BoardingState;
  marked_at: string;
};

export type QueuedBatch = { batchId: string; events: BoardingEvent[]; attempts: number; lastError: string | null };

export interface QueueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const BOARDING_QUEUE_KEY = 'seena.transport.boarding-queue.v1';
export const manifestKey = (legId: string) => `seena.transport.manifest.${legId}`;

/**
 * "Mark all boarded, tap the exceptions": every student on the manifest becomes
 * `okState` except those in `exceptions`, who are absent. Four taps for a
 * 40-student leg with three absentees: mark all, then three exceptions.
 */
export function buildBatch(
  legId: string,
  studentIds: string[],
  exceptions: ReadonlySet<string>,
  okState: 'boarded' | 'dropped',
  now: Date,
  newId: () => string,
): BoardingEvent[] {
  const markedAt = now.toISOString();
  return studentIds.map((student_id) => ({
    device_event_id: newId(),
    trip_leg_id: legId,
    student_id,
    state: exceptions.has(student_id) ? 'absent' : okState,
    marked_at: markedAt,
  }));
}

export function readQueue(store: QueueStore): QueuedBatch[] {
  const raw = store.getItem(BOARDING_QUEUE_KEY);
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as QueuedBatch[]) : [];
  } catch {
    return [];
  }
}

function write(store: QueueStore, batches: QueuedBatch[]): QueuedBatch[] {
  store.setItem(BOARDING_QUEUE_KEY, JSON.stringify(batches));
  return batches;
}

export function enqueueBatch(store: QueueStore, batchId: string, events: BoardingEvent[]): QueuedBatch[] {
  const q = readQueue(store);
  if (q.some((b) => b.batchId === batchId)) return q;
  return write(store, [...q, { batchId, events, attempts: 0, lastError: null }]);
}

export type SendResult = { ok: boolean; error?: string };

/**
 * Sends each queued batch in order. A batch the server accepted leaves the
 * queue; one that failed stays, unchanged, to be retried with the same event ids.
 */
export async function flushQueue(store: QueueStore, send: (events: BoardingEvent[]) => Promise<SendResult>): Promise<{ sent: number; pending: number }> {
  let sent = 0;
  for (const batch of readQueue(store)) {
    let result: SendResult;
    try {
      result = await send(batch.events);
    } catch (e) {
      result = { ok: false, error: e instanceof Error ? e.message : 'network' };
    }
    const current = readQueue(store);
    if (result.ok) {
      write(store, current.filter((b) => b.batchId !== batch.batchId));
      sent += 1;
    } else {
      write(store, current.map((b) => (b.batchId === batch.batchId ? { ...b, attempts: b.attempts + 1, lastError: result.error ?? 'failed' } : b)));
    }
  }
  return { sent, pending: readQueue(store).length };
}
