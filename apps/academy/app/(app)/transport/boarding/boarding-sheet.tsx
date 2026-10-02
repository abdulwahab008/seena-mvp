'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { buildBatch, enqueueBatch, flushQueue, manifestKey, readQueue, type BoardingEvent } from '@/lib/transport/boarding-queue';
import { completeLeg, syncBoarding } from './actions';

export type ManifestRow = { student_id: string; name: string; gr_number: string; stop: string; stop_seq: number; state: string | null; boarded_at_pickup: boolean };

/**
 * Mark-all-then-exceptions boarding sheet. The manifest is written to
 * localStorage as soon as the sheet opens (before the bus leaves the gate);
 * submitting builds one batch with client-generated event ids, queues it and
 * sends it. If the phone is offline the batch stays queued and is re-sent,
 * unchanged, when the connection returns.
 */
export function BoardingSheet({ legId, legType, rows }: { legId: string; legType: 'pickup' | 'drop'; rows: ManifestRow[] }) {
  const router = useRouter();
  const okState = legType === 'pickup' ? 'boarded' : 'dropped';
  const okLabel = legType === 'pickup' ? 'boarded' : 'dropped';
  const [exceptions, setExceptions] = useState<Set<string>>(new Set());
  const [allMarked, setAllMarked] = useState(rows.length > 0 && rows.every((r) => r.state));
  const [pending, setPending] = useState(0);
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    try {
      window.localStorage.setItem(manifestKey(legId), JSON.stringify(rows));
    } catch {
      /* private mode: the sheet still works online */
    }
    setPending(readQueue(window.localStorage).length);
  }, [legId, rows]);

  const send = useCallback(async (events: BoardingEvent[]) => {
    const r = await syncBoarding(events);
    return r.error ? { ok: false, error: r.error } : { ok: true };
  }, []);

  const flush = useCallback(async () => {
    const r = await flushQueue(window.localStorage, send);
    setPending(r.pending);
    if (r.pending === 0 && r.sent > 0) {
      setStatus('Saved on the server.');
      router.refresh();
    } else if (r.pending > 0) {
      setStatus(`Offline: ${r.pending} batch(es) saved on this phone and will be sent when the connection returns.`);
    }
  }, [send, router]);

  useEffect(() => {
    const onOnline = () => void flush();
    window.addEventListener('online', onOnline);
    return () => window.removeEventListener('online', onOnline);
  }, [flush]);

  const toggle = (id: string) =>
    setExceptions((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const eligible = useMemo(() => rows.filter((r) => legType === 'pickup' || r.boarded_at_pickup || r.state), [rows, legType]);

  const submit = async () => {
    setBusy(true);
    const events = buildBatch(legId, eligible.map((r) => r.student_id), exceptions, okState, new Date(), () => crypto.randomUUID());
    enqueueBatch(window.localStorage, crypto.randomUUID(), events);
    await flush();
    setBusy(false);
  };

  const label = (r: ManifestRow) => {
    if (allMarked) return exceptions.has(r.student_id) ? 'absent' : okLabel;
    return r.state ?? 'unmarked';
  };

  return (
    <div className="space-y-4" data-testid="boarding-sheet">
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" size="sm" onClick={() => setAllMarked(true)} data-testid="mark-all">
          Mark all {okLabel}
        </Button>
        <Button type="button" size="sm" disabled={!allMarked || busy} onClick={submit} data-testid="submit-batch">
          Submit {eligible.length} students
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          onClick={async () => {
            const r = await completeLeg(legId);
            setStatus(r.error ?? 'Trip marked complete.');
          }}
        >
          Finish trip
        </Button>
        {pending > 0 && <span className="text-xs text-muted-foreground">{pending} batch(es) waiting on this phone</span>}
      </div>
      {status && (
        <p role="status" className="text-sm" data-testid="boarding-status">
          {status}
        </p>
      )}
      <ul className="divide-y text-sm">
        {eligible.map((r) => (
          <li key={r.student_id} className="flex items-center justify-between gap-3 py-2" data-testid="manifest-row">
            <span>
              <span className="font-medium">{r.name}</span> <span className="text-muted-foreground">GR {r.gr_number} · {r.stop}</span>
            </span>
            <button
              type="button"
              disabled={!allMarked}
              onClick={() => toggle(r.student_id)}
              className={`rounded-md border px-3 py-1 text-xs ${label(r) === 'absent' ? 'border-destructive text-destructive' : ''}`}
              data-testid={`student-${r.gr_number}`}
              aria-label={`${r.name}: ${label(r)}. Tap to toggle absent`}
            >
              {label(r)}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
