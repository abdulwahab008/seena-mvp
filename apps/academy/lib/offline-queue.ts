// FR-G05: the device-side half of offline attendance capture.
//
// Deliberately localStorage, not IndexedDB and not a service worker. The
// user story is a teacher who marks the register in a classroom with no
// signal and walks to the staff room — one open tab, minutes apart, a
// payload of a few kB. localStorage covers exactly that in a few dozen
// synchronous lines with no new dependency, and Playwright can drive it
// end to end via context.setOffline(). What it does NOT do, and is not
// claimed to: survive a hard reload while still offline. Without a
// service worker there is no cached app shell, so a refresh with no
// network shows the browser's own offline page. The queued registers
// themselves survive that (they are in localStorage, not memory) and
// upload once the page is loaded again online — but the teacher cannot
// keep marking until then.
//
// Every function here takes its store explicitly so the queue is unit
// testable without a DOM, and so nothing in this module touches window.

export type QueuedMark = { enrolmentId: string; status: string; arrivalTime?: string };

export type QueuedRegister = {
  // Doubles as the server's idempotency key: it is minted once, at
  // capture time, and reused on every retry — that reuse is what makes
  // the exactly-once guarantee in rpc_bulk_mark_attendance() reachable.
  idempotencyKey: string;
  sectionId: string;
  attendanceDate: string;
  exceptions: QueuedMark[];
  capturedAt: string;
  attempts: number;
  lastError: string | null;
};

export interface QueueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const OFFLINE_QUEUE_KEY = 'seena.attendance.offline-queue.v1';

export function readQueue(store: QueueStore): QueuedRegister[] {
  const raw = store.getItem(OFFLINE_QUEUE_KEY);
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as QueuedRegister[]) : [];
  } catch {
    // A corrupted queue is unrecoverable either way — an empty queue at
    // least keeps the register screen usable instead of throwing on load.
    return [];
  }
}

function writeQueue(store: QueueStore, entries: QueuedRegister[]): QueuedRegister[] {
  store.setItem(OFFLINE_QUEUE_KEY, JSON.stringify(entries));
  return entries;
}

export function queueDepth(store: QueueStore): number {
  return readQueue(store).length;
}

// One queued submission per (section, date): re-submitting the same
// register while still offline replaces the earlier capture rather than
// stacking a second one the server would have to reconcile. The new
// entry carries a new idempotency key because it is genuinely a new
// submission — the one it replaces was never sent.
export function enqueue(
  store: QueueStore,
  entry: Omit<QueuedRegister, 'attempts' | 'lastError'>
): QueuedRegister[] {
  const rest = readQueue(store).filter(
    (e) => !(e.sectionId === entry.sectionId && e.attendanceDate === entry.attendanceDate)
  );
  return writeQueue(store, [...rest, { ...entry, attempts: 0, lastError: null }]);
}

export function dequeue(store: QueueStore, idempotencyKey: string): QueuedRegister[] {
  return writeQueue(
    store,
    readQueue(store).filter((e) => e.idempotencyKey !== idempotencyKey)
  );
}

export function recordAttempt(store: QueueStore, idempotencyKey: string, error: string | null): QueuedRegister[] {
  return writeQueue(
    store,
    readQueue(store).map((e) =>
      e.idempotencyKey === idempotencyKey ? { ...e, attempts: e.attempts + 1, lastError: error } : e
    )
  );
}

export type SyncOutcome =
  | { kind: 'applied'; saved: number }
  | { kind: 'rejected_locked'; correctionsRequested: number }
  | { kind: 'rejected_stale' }
  | { kind: 'failed'; retryable: boolean; error: string };

export type FlushReport = {
  applied: number;
  locked: number;
  stale: number;
  // Rejected by the server for a reason no retry can change, so no longer
  // queued — the caller must surface these or the capture vanishes.
  dropped: string[];
  // Still queued after failing to reach the server; the next flush retries.
  retrying: number;
  remaining: number;
};

// Drains the queue oldest-first, one at a time — order matters, since two
// captures for the same date must reach the server in the order they were
// made for rpc_bulk_mark_attendance()'s stale check to mean anything.
//
// Every outcome the SERVER produced is terminal and dequeues, including
// its two rejections: a rejected_locked submission has already been
// turned into correction requests server-side (nothing is lost by
// dropping the queue entry), and a rejected_stale one has been
// definitively superseded. Only a failure to reach the server at all is
// retried, with the same idempotency key, on the next flush.
export async function flushQueue(
  store: QueueStore,
  send: (entry: QueuedRegister) => Promise<SyncOutcome>
): Promise<FlushReport> {
  const report: FlushReport = { applied: 0, locked: 0, stale: 0, dropped: [], retrying: 0, remaining: 0 };

  for (const entry of readQueue(store)) {
    const outcome = await send(entry);
    if (outcome.kind === 'failed' && outcome.retryable) {
      recordAttempt(store, entry.idempotencyKey, outcome.error);
      report.retrying += 1;
      continue;
    }
    dequeue(store, entry.idempotencyKey);
    if (outcome.kind === 'applied') report.applied += 1;
    else if (outcome.kind === 'rejected_locked') report.locked += 1;
    else if (outcome.kind === 'rejected_stale') report.stale += 1;
    else report.dropped.push(outcome.error);
  }

  report.remaining = queueDepth(store);
  return report;
}
