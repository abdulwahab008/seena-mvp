'use client';

import * as React from 'react';
import { usePathname } from 'next/navigation';
import { ShieldAlert } from 'lucide-react';
import { formatCountdown } from '@/lib/impersonation';
import { endSession, noteImpersonationPageView, type ImpersonationActionState } from './impersonation/actions';

export type ImpersonationBannerProps = {
  sessionId: string;
  targetName: string;
  targetRole: string;
  /** The engineer's own account — the one every write is still attributed to. */
  engineerEmail: string;
  /** The session deadline, straight off the token's `imp.exp`. */
  endsAt: string;
};

const INITIAL: ImpersonationActionState = { error: null };

/**
 * FR-A16's "the UI must make it impossible to forget you are impersonating".
 *
 * Three things carry that, because one is a thing people stop seeing:
 *   - a fixed strip the page cannot scroll away from, naming who is being
 *     acted as and how long is left;
 *   - a border drawn around the entire viewport, so every screen of the
 *     product looks different for the whole session, not just the top of it;
 *   - a live countdown, because the window is 60 minutes and an engineer who
 *     does not know that will be surprised by the refusal instead of by the
 *     clock.
 *
 * Rendered from the (app) layout, so it is on every route in the shell.
 */
export function ImpersonationBanner({
  sessionId,
  targetName,
  targetRole,
  engineerEmail,
  endsAt,
}: ImpersonationBannerProps) {
  const pathname = usePathname();
  const [state, formAction, pending] = React.useActionState(endSession, INITIAL);

  // Computed in an effect rather than during render: the server and the client
  // read different clocks, and a countdown is the one thing guaranteed to
  // differ between them.
  const [remaining, setRemaining] = React.useState<number | null>(null);
  React.useEffect(() => {
    const tick = () => setRemaining(Date.parse(endsAt) - Date.now());
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [endsAt]);

  // AC6's read count. The layout is a server component that Next does not
  // re-render on a client-side navigation, so the count has to be driven from
  // here, where the pathname actually changes.
  React.useEffect(() => {
    void noteImpersonationPageView();
  }, [pathname]);

  const expired = remaining !== null && remaining <= 0;

  return (
    <>
      <div
        role="status"
        aria-label="Impersonation session"
        data-testid="impersonation-banner"
        className="fixed inset-x-0 top-0 z-50 flex h-11 items-center gap-3 bg-destructive px-4 text-destructive-foreground shadow-md sm:px-6"
      >
        <ShieldAlert className="h-4 w-4 shrink-0 animate-pulse" aria-hidden />
        <p className="min-w-0 flex-1 truncate text-sm">
          <span className="font-semibold uppercase tracking-wide">Impersonating</span>
          <span aria-hidden className="px-2 opacity-60">
            |
          </span>
          You are acting as{' '}
          <span className="font-semibold" data-testid="impersonation-banner-target">
            {targetName}
          </span>{' '}
          ({targetRole.replace(/_/g, ' ')}).{' '}
          <span className="hidden opacity-90 md:inline">
            Every change is still recorded against {engineerEmail}.
          </span>
        </p>
        <span
          className="shrink-0 rounded-full bg-black/20 px-2.5 py-0.5 font-mono text-xs tabular-nums"
          data-testid="impersonation-remaining"
        >
          {remaining === null ? '--:--' : expired ? 'expired' : `ends in ${formatCountdown(remaining)}`}
        </span>
        <form action={formAction} className="shrink-0">
          <input type="hidden" name="sessionId" value={sessionId} />
          <button
            type="submit"
            disabled={pending}
            data-testid="end-impersonation"
            className="rounded-md bg-destructive-foreground/15 px-3 py-1 text-xs font-medium ring-1 ring-inset ring-destructive-foreground/40 transition-colors hover:bg-destructive-foreground/25 disabled:opacity-60"
          >
            {pending ? 'Ending…' : 'End session'}
          </button>
        </form>
      </div>

      {/* The whole product looks different for the whole session, not just its top edge. */}
      <div
        aria-hidden
        className="pointer-events-none fixed inset-0 z-40 border-[3px] border-destructive"
        data-testid="impersonation-frame"
      />

      {state?.error ? (
        <p role="alert" className="fixed inset-x-0 top-11 z-50 bg-destructive-muted px-4 py-1.5 text-xs text-destructive">
          {state.error}
        </p>
      ) : null}
    </>
  );
}
