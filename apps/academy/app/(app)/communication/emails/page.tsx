import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatDateTimePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import type { Database } from '@/lib/database.types';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist'];
const DATE = /^\d{4}-\d{2}-\d{2}$/;

type Status = Database['public']['Enums']['message_status'];
const GROUPS = {
  sent: { label: 'Sent', statuses: ['sent', 'submitted', 'delivered'], variant: 'success' },
  failed: { label: 'Failed', statuses: ['failed', 'exhausted', 'expired'], variant: 'destructive' },
  pending: { label: 'Pending', statuses: ['queued', 'claimed', 'sending', 'unknown'], variant: 'warning' },
  cancelled: { label: 'Cancelled', statuses: ['cancelled'], variant: 'outline' },
} as const satisfies Record<string, { label: string; statuses: Status[]; variant: string }>;
type Group = keyof typeof GROUPS;
const groupOf = (s: Status) => (Object.keys(GROUPS) as Group[]).find((g) => (GROUPS[g].statuses as readonly Status[]).includes(s)) ?? 'pending';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export default async function EmailLogPage({ searchParams }: { searchParams: Promise<{ status?: string; from?: string; to?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const params = await searchParams;
  const status = params.status && params.status in GROUPS ? (params.status as Group) : null;
  const from = params.from && DATE.test(params.from) ? params.from : '';
  const to = params.to && DATE.test(params.to) ? params.to : '';

  const supabase = await supabaseServer();
  let query = supabase
    .from('message')
    .select('id, recipient_email, subject, status, created_at, updated_at, attempts:message_attempt(attempt_number, error_message)')
    .eq('channel', 'email')
    .order('created_at', { ascending: false })
    .limit(200);
  if (status) query = query.in('status', [...GROUPS[status].statuses]);
  if (from) query = query.gte('created_at', `${from}T00:00:00+05:00`);
  if (to) query = query.lte('created_at', `${to}T23:59:59.999+05:00`);
  const { data: rows, error } = await query;

  const lastError = (attempts: { attempt_number: number; error_message: string | null }[]) =>
    [...attempts].sort((a, b) => b.attempt_number - a.attempt_number).find((a) => a.error_message)?.error_message ?? null;

  return (
    <>
      <PageHeader title="Email log" description="Emails the school has sent, or tried to send, from the message outbox. Latest 200 shown." />
      <form method="get" className="mb-6 grid gap-2 sm:grid-cols-[12rem_10rem_10rem_auto] sm:items-end">
        <div className="space-y-1">
          <Label htmlFor="el-status">Status</Label>
          <select id="el-status" name="status" defaultValue={status ?? ''} className={SELECT}>
            <option value="">All</option>
            {(Object.keys(GROUPS) as Group[]).map((g) => (
              <option key={g} value={g}>
                {GROUPS[g].label}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="el-from">From</Label>
          <Input id="el-from" name="from" type="date" defaultValue={from} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="el-to">To</Label>
          <Input id="el-to" name="to" type="date" defaultValue={to} />
        </div>
        <Button type="submit" variant="outline">
          Filter
        </Button>
      </form>
      {error ? (
        <EmptyState title="Could not load the email log" description="Refresh the page to try again." />
      ) : (rows ?? []).length === 0 ? (
        <EmptyState title="No emails" description={status || from || to ? 'Nothing matches these filters.' : 'No email has been queued yet.'} />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>To</TableHead>
              <TableHead>Subject</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Queued</TableHead>
              <TableHead>Last update</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(rows ?? []).map((m) => {
              const g = groupOf(m.status);
              const err = g === 'failed' ? lastError(m.attempts) : null;
              return (
                <TableRow key={m.id} data-testid="email-row">
                  <TableCell>{m.recipient_email}</TableCell>
                  <TableCell>
                    {m.subject ?? <span className="text-muted-foreground">No subject</span>}
                    {err && <span className="block text-xs text-destructive">{err}</span>}
                  </TableCell>
                  <TableCell>
                    <Badge variant={GROUPS[g].variant}>{m.status}</Badge>
                  </TableCell>
                  <TableCell className="whitespace-nowrap">{formatDateTimePk(m.created_at)}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDateTimePk(m.updated_at)}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </>
  );
}
