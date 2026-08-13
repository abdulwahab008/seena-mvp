'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { breakGlassUnlock, rejectMarkUnlock, relockExpiredUnlocks } from './actions';
import type { MarkUnlockException, MarkUnlockRequestRow } from '@/lib/exams/mark-query';
import { DEFAULT_UNLOCK_WINDOW_MINUTES, unlockMinutesLeft } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

/**
 * FR-I17's board.
 *
 * Three lists, and they are separate on purpose:
 *
 *   pending  — what a Principal has to decide. The Approve control is hidden
 *              on a request the signed-in user raised, because the database
 *              refuses it (UNLOCK_SELF_APPROVAL) and a button that always
 *              fails is worse than no button.
 *   open     — windows that are running right now, with the minutes left. The
 *              countdown is decoration: the deadline is enforced server-side
 *              on every write, so a stale tab cannot buy a single extra edit.
 *   history  — AC4's exceptions report, which is the whole reason the reason
 *              field is mandatory.
 */
type Props = {
  currentUserId: string;
  canDecide: boolean;
  pending: MarkUnlockRequestRow[];
  open: MarkUnlockRequestRow[];
  decided: MarkUnlockRequestRow[];
  exceptions: MarkUnlockException[];
};

const label = (r: MarkUnlockRequestRow) =>
  `${r.class_name ?? ''} ${r.section_name ?? ''} · ${r.subject_name ?? ''}`.trim();

export function UnlockBoard({ currentUserId, canDecide, pending, open, decided, exceptions }: Props) {
  const router = useRouter();
  const [pendingTransition, startTransition] = useTransition();
  const [windows, setWindows] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState('');

  const onApprove = async (r: MarkUnlockRequestRow) => {
    setBusy(r.id);
    const result = await breakGlassUnlock({
      requestId: r.id,
      windowMinutes: windows[r.id] ?? DEFAULT_UNLOCK_WINDOW_MINUTES,
    });
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`Glass broken on ${label(r)} — the window closes on its own.`);
    startTransition(() => router.refresh());
  };

  const onReject = async (r: MarkUnlockRequestRow) => {
    setBusy(r.id);
    const result = await rejectMarkUnlock({ requestId: r.id });
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`Refused — ${label(r)} stays locked.`);
    startTransition(() => router.refresh());
  };

  const onSweep = async () => {
    setBusy('sweep');
    const result = await relockExpiredUnlocks();
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(result.relocked === 0 ? 'No window had lapsed.' : `${result.relocked} window(s) re-locked.`);
    startTransition(() => router.refresh());
  };

  return (
    <div className="space-y-8">
      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Awaiting a decision</h2>
        {pending.length === 0 && (
          <p className="text-sm text-muted-foreground" data-testid="unlock-no-pending">
            No break-glass request is waiting.
          </p>
        )}
        {pending.map((r) => {
          const own = r.requested_by === currentUserId;
          return (
            <div key={r.id} className="space-y-3 rounded-md border p-4" data-testid={`unlock-pending-${r.id}`}>
              <div className="flex flex-wrap items-center gap-3">
                <span className="font-medium">{label(r)}</span>
                <span className="text-xs text-muted-foreground">
                  raised by {r.requested_by_name ?? 'someone'} on {new Date(r.requested_at).toLocaleString()}
                </span>
              </div>
              <p className="text-sm" data-testid={`unlock-reason-${r.id}`}>
                &ldquo;{r.reason}&rdquo;
              </p>
              {!canDecide && (
                <p className="text-xs text-muted-foreground">Waiting on a Principal, Owner or Super Admin.</p>
              )}
              {canDecide && own && (
                <p className="text-xs text-destructive" data-testid={`unlock-self-${r.id}`}>
                  You raised this one — someone else has to decide it.
                </p>
              )}
              {canDecide && !own && (
                <div className="flex flex-wrap items-end gap-3">
                  <div className="space-y-1">
                    <Label htmlFor={`window-${r.id}`}>Window (minutes)</Label>
                    <Input
                      id={`window-${r.id}`}
                      type="number"
                      min={1}
                      max={240}
                      className="w-28"
                      data-testid={`unlock-window-${r.id}`}
                      value={windows[r.id] ?? String(DEFAULT_UNLOCK_WINDOW_MINUTES)}
                      onChange={(e) => setWindows((prev) => ({ ...prev, [r.id]: e.target.value }))}
                    />
                  </div>
                  <Button
                    disabled={busy === r.id || pendingTransition}
                    data-testid={`unlock-approve-${r.id}`}
                    onClick={() => void onApprove(r)}
                  >
                    Break the glass
                  </Button>
                  <Button
                    variant="outline"
                    disabled={busy === r.id || pendingTransition}
                    data-testid={`unlock-reject-${r.id}`}
                    onClick={() => void onReject(r)}
                  >
                    Refuse
                  </Button>
                </div>
              )}
            </div>
          );
        })}
      </section>

      <section className="space-y-3">
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="text-lg font-semibold">Windows open now</h2>
          <Button
            variant="outline"
            className="ml-auto"
            disabled={busy === 'sweep' || pendingTransition}
            data-testid="unlock-run-sweep"
            onClick={() => void onSweep()}
          >
            Re-lock anything lapsed
          </Button>
        </div>
        {open.length === 0 && (
          <p className="text-sm text-muted-foreground" data-testid="unlock-no-open">
            Nothing is unlocked. Every signed-off mark set is read-only.
          </p>
        )}
        {open.map((r) => (
          <div key={r.id} className="rounded-md border border-destructive p-4" data-testid={`unlock-open-${r.id}`}>
            <div className="flex flex-wrap items-center gap-3">
              <span className="font-medium">{label(r)}</span>
              <span className="text-xs" data-testid={`unlock-expiry-${r.id}`}>
                closes in {unlockMinutesLeft(r.expires_at) ?? 0} min
              </span>
              <span className="ml-auto text-xs text-muted-foreground">
                {r.edit_count} mark{r.edit_count === 1 ? '' : 's'} changed so far
              </span>
            </div>
            <p className="mt-2 text-sm">&ldquo;{r.reason}&rdquo;</p>
            <p className="mt-1 text-xs text-muted-foreground">
              raised by {r.requested_by_name ?? 'someone'}, granted by {r.approved_by_name ?? 'someone'}
            </p>
          </div>
        ))}
      </section>

      <section className="space-y-3">
        <h2 className="text-lg font-semibold">Exceptions report</h2>
        <p className="text-sm text-muted-foreground">
          Every paper whose signed-off marks were reopened, with why and by whom. A subject appearing here repeatedly is
          the pattern this report exists to make visible.
        </p>
        {exceptions.length === 0 && (
          <p className="text-sm text-muted-foreground" data-testid="unlock-no-exceptions">
            No signed-off mark set has ever been reopened.
          </p>
        )}
        {exceptions.map((e) => (
          <div key={e.exam_subject_id} className="rounded-md border p-4" data-testid={`unlock-exception-${e.subject_name}`}>
            <div className="flex flex-wrap items-center gap-3">
              <span className="font-medium">
                {e.class_name} &middot; {e.subject_name}
              </span>
              <span className="text-xs text-muted-foreground">{e.exam_term_name}</span>
              <span
                className="rounded-full border px-2 py-0.5 text-xs"
                data-testid={`unlock-count-${e.subject_name}`}
              >
                {e.unlock_count} unlock{e.unlock_count === 1 ? '' : 's'}
              </span>
              <span className="text-xs text-muted-foreground">
                {e.windows_with_edits} changed a mark &middot; sections {e.sections.join(', ')}
              </span>
            </div>
            <ul className="mt-2 list-disc space-y-1 pl-5 text-sm" data-testid={`unlock-reasons-${e.subject_name}`}>
              {e.reasons.map((reason, i) => (
                <li key={`${e.exam_subject_id}-${i}`}>{reason}</li>
              ))}
            </ul>
            <p className="mt-2 text-xs text-muted-foreground" data-testid={`unlock-approvers-${e.subject_name}`}>
              approved by {e.approvers.join(', ')} &middot; requested by {e.requesters.join(', ')}
            </p>
          </div>
        ))}
      </section>

      {decided.length > 0 && (
        <section className="space-y-3">
          <h2 className="text-lg font-semibold">Refused</h2>
          {decided.map((r) => (
            <div key={r.id} className="rounded-md border border-dashed p-4 text-sm" data-testid={`unlock-refused-${r.id}`}>
              <span className="font-medium">{label(r)}</span> &mdash; &ldquo;{r.reason}&rdquo; refused by{' '}
              {r.approved_by_name ?? 'someone'}
              {r.decision_note ? `: ${r.decision_note}` : ''}
            </div>
          ))}
        </section>
      )}
    </div>
  );
}
