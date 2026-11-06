'use client';

import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import type { InviteDelivery } from '@/lib/staff-invite';

export function InviteLinkPanel({ email, delivery }: { email: string; delivery: InviteDelivery }) {
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(delivery.link);
      toast.success('Invite link copied.');
    } catch {
      toast.error('Could not copy. Select the link and copy it yourself.');
    }
  };
  return (
    <div className="space-y-2 rounded-md border bg-background p-3 text-sm" data-testid="invite-link-panel">
      <p>
        {delivery.emailed
          ? `Invitation emailed to ${email}. You can also share this link with them:`
          : `${delivery.note ?? 'No email was sent.'} Send this link to ${email} yourself:`}
      </p>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
        <code className="min-w-0 flex-1 select-all break-all rounded bg-muted px-2 py-1 text-xs" data-testid="invite-link">
          {delivery.link}
        </code>
        <Button type="button" size="sm" variant="outline" onClick={copy}>
          Copy link
        </Button>
      </div>
    </div>
  );
}
