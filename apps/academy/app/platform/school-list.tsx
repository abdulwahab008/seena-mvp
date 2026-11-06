'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { resendOwnerInvite, setSchoolStatus } from './actions';
import { InviteLinkPanel } from '@/app/(app)/staff/invite-link-panel';
import type { InviteDelivery } from '@/lib/staff-invite';
import type { Database } from '@/lib/database.types';
import { formatDatePk, formatDateTimePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';

type School = Database['public']['Functions']['platform_list_tenants']['Returns'][number];
type Target = 'active' | 'suspended' | 'closed';

const STATUS_BADGE = {
  active: { label: 'Active', variant: 'success' },
  suspended: { label: 'Suspended', variant: 'warning' },
  closed: { label: 'Closed', variant: 'destructive' },
  provisioning: { label: 'Setting up', variant: 'outline' },
} as const;

const ACTION_COPY: Record<Target, { title: string; button: string; effect: string }> = {
  active: { title: 'Reactivate', button: 'Reactivate', effect: 'Everyone in the school can sign in again.' },
  suspended: { title: 'Suspend', button: 'Suspend', effect: 'Staff lose access at once; parents and students within the hour. You can reactivate later.' },
  closed: { title: 'Close', button: 'Close school', effect: 'Nobody in the school can sign in again, and a closed school cannot be reopened.' },
};

export function SchoolList({ schools }: { schools: School[] }) {
  const [pending, startTransition] = useTransition();
  const [changing, setChanging] = useState<{ school: School; to: Target } | null>(null);
  const [invite, setInvite] = useState<{ email: string; delivery: InviteDelivery } | null>(null);

  if (schools.length === 0) {
    return <EmptyState title="No schools yet" description="Create the first school with the form on this page." />;
  }

  const confirm = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!changing) return;
    const reason = String(new FormData(e.currentTarget).get('reason') ?? '');
    startTransition(async () => {
      const r = await setSchoolStatus({ tenantId: changing.school.id, status: changing.to, reason });
      if (r.error) {
        toast.error(r.error);
        return;
      }
      toast.success(`${changing.school.name}: ${STATUS_BADGE[changing.to].label.toLowerCase()}.`);
      setChanging(null);
    });
  };

  const resend = (school: School) =>
    startTransition(async () => {
      const r = await resendOwnerInvite(school.id);
      if (r.error || !r.delivery) {
        toast.error(r.error ?? 'Could not create the invitation link.');
        return;
      }
      toast.success(r.delivery.emailed ? `Invitation emailed to ${school.owner_email}.` : 'Invitation link ready.');
      setInvite({ email: school.owner_email ?? '', delivery: r.delivery });
    });

  return (
    <div className="space-y-2">
      {invite && <InviteLinkPanel email={invite.email} delivery={invite.delivery} />}
      {schools.map((s) => (
        <Card key={s.id} data-testid={`school-${s.slug}`}>
          <CardContent className="flex flex-wrap items-start justify-between gap-3 p-4">
            <div className="min-w-0 space-y-1">
              <p className="font-medium">
                {s.name} <span className="text-muted-foreground">({s.slug})</span>{' '}
                <Badge variant={STATUS_BADGE[s.status].variant} data-testid="school-status">
                  {STATUS_BADGE[s.status].label}
                </Badge>
              </p>
              <p className="text-sm text-muted-foreground">
                Owner: {s.owner_name ?? 'not joined yet'}
                {s.owner_email ? ` · ${s.owner_email}` : ''}
              </p>
              <p className="text-sm text-muted-foreground">
                {s.students} students · {s.logins} staff logins · {s.campuses} {s.campuses === 1 ? 'campus' : 'campuses'} · created{' '}
                {formatDatePk(s.created_at)}
                {s.last_sign_in_at ? ` · last sign-in ${formatDateTimePk(s.last_sign_in_at)}` : ''}
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              {s.owner_invite_id && s.status === 'active' && (
                <Button variant="outline" size="sm" disabled={pending} onClick={() => resend(s)}>
                  Resend owner invite
                </Button>
              )}
              {s.status === 'active' && (
                <Button variant="outline" size="sm" disabled={pending} onClick={() => setChanging({ school: s, to: 'suspended' })}>
                  Suspend
                </Button>
              )}
              {s.status === 'suspended' && (
                <Button variant="outline" size="sm" disabled={pending} onClick={() => setChanging({ school: s, to: 'active' })}>
                  Reactivate
                </Button>
              )}
              {s.status !== 'closed' && (
                <Button variant="ghost" size="sm" disabled={pending} onClick={() => setChanging({ school: s, to: 'closed' })}>
                  Close
                </Button>
              )}
            </div>
          </CardContent>
        </Card>
      ))}

      <Modal
        open={changing !== null}
        onClose={() => setChanging(null)}
        title={changing ? `${ACTION_COPY[changing.to].title} ${changing.school.name}?` : ''}
        description={changing ? ACTION_COPY[changing.to].effect : undefined}
        size="sm"
        footer={
          <>
            <Button variant="outline" onClick={() => setChanging(null)} disabled={pending}>
              Cancel
            </Button>
            <Button
              variant={changing?.to === 'active' ? 'default' : 'destructive'}
              type="submit"
              form="status-form"
              disabled={pending}
              data-testid="confirm-status"
            >
              {changing ? ACTION_COPY[changing.to].button : ''}
            </Button>
          </>
        }
      >
        <form id="status-form" onSubmit={confirm} className="space-y-2">
          <Label htmlFor="status-reason">Reason (kept in the school&apos;s audit log)</Label>
          <Textarea id="status-reason" name="reason" required maxLength={500} />
        </form>
      </Modal>
    </div>
  );
}
