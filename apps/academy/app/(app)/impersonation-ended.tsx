'use client';

import * as React from 'react';
import { ShieldOff } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { returnToSelf } from './impersonation/actions';

/**
 * FR-A16 AC4. app.assert_impersonation_live() is a per-request lookup, so the
 * first read after the Owner withdraws consent — or after the window closes —
 * raises PT401 and the shell has nothing to render. The token still carries
 * `imp` until it is re-minted, which is exactly what the button below does.
 */
export function ImpersonationEnded() {
  const [pending, startTransition] = React.useTransition();

  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <EmptyState
        icon={ShieldOff}
        className="max-w-md bg-card"
        title="Impersonation session ended"
        description="The school withdrew consent, the consent expired, or the 60-minute window closed. This account can no longer be viewed. Nothing you did was lost — it is all recorded against your own account."
        data-testid="impersonation-ended"
        titleTestId="impersonation-ended-heading"
        descriptionTestId="impersonation-ended-message"
        action={
          <Button
            type="button"
            disabled={pending}
            onClick={() => startTransition(() => returnToSelf())}
            data-testid="impersonation-return-to-self"
          >
            {pending ? 'Returning…' : 'Return to your own account'}
          </Button>
        }
      />
    </div>
  );
}
