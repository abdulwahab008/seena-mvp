'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import type { InviteDelivery } from '@/lib/staff-invite';
import { getInvitationLink, resendInvitation, revokeInvitation } from './actions';
import { InviteLinkPanel } from './invite-link-panel';

export function InvitationRow({ id, email, role, expires }: { id: string; email: string; role: string; expires: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [delivery, setDelivery] = useState<InviteDelivery | null>(null);
  const [confirmRevoke, setConfirmRevoke] = useState(false);

  const run = (fn: () => Promise<{ error: string | null; delivery?: InviteDelivery | null }>) =>
    startTransition(async () => {
      const r = await fn();
      if (r.error) toast.error(r.error);
      else if (r.delivery) setDelivery(r.delivery);
    });

  return (
    <Card data-testid={`invite-row-${email}`}>
      <CardContent className="space-y-2 p-3 text-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <span>
            <span className="font-medium">{email}</span> · {role}
          </span>
          <span className="text-muted-foreground">Expires {expires}</span>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => run(() => getInvitationLink(id))}>
            Show link
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => run(() => resendInvitation(id))}>
            Resend email
          </Button>
          {confirmRevoke ? (
            <>
              <Button
                type="button"
                size="sm"
                variant="destructive"
                disabled={pending}
                onClick={() =>
                  startTransition(async () => {
                    const r = await revokeInvitation(id);
                    if (r.error) toast.error(r.error);
                    else {
                      toast.success(`Invitation for ${email} revoked.`);
                      router.refresh();
                    }
                  })
                }
              >
                Confirm revoke
              </Button>
              <Button type="button" size="sm" variant="ghost" onClick={() => setConfirmRevoke(false)}>
                Keep
              </Button>
            </>
          ) : (
            <Button type="button" size="sm" variant="ghost" disabled={pending} onClick={() => setConfirmRevoke(true)}>
              Revoke
            </Button>
          )}
        </div>
        {delivery && <InviteLinkPanel email={email} delivery={delivery} />}
      </CardContent>
    </Card>
  );
}
