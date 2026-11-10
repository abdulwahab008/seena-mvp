import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { formatDatePk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { Badge } from '@/components/ui/badge';
import { DecideButtons } from '@/components/decide-buttons';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { decideTransportRequest } from './actions';

export const dynamic = 'force-dynamic';

const ROLES = ['owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'];
const KIND = { start: 'Start bus', stop: 'Stop bus', change_route: 'Change route', change_stop: 'Change stop' } as const;
const STATUS_TONE = { pending: 'warning', approved: 'success', rejected: 'destructive' } as const;

export default async function TransportRequestsPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const { status: raw } = await searchParams;
  const status = raw && raw in STATUS_TONE ? (raw as keyof typeof STATUS_TONE) : 'pending';
  const supabase = await supabaseServer();
  const { data: requests, error } = await supabase
    .from('transport_request')
    .select('id, kind, note, status, decision_note, created_at, route:route_id(code, name), student:student_id(id, name_en, gr_number)')
    .eq('status', status)
    .order('created_at', { ascending: status === 'pending' })
    .limit(200);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Transport requests</h1>
        <p className="text-sm text-muted-foreground">
          Parents ask from the portal to start, stop or change the school bus. Approve here, then make the change under Student Allocation.
        </p>
      </div>
      <nav className="flex flex-wrap gap-2" aria-label="Status">
        {Object.keys(STATUS_TONE).map((s) => (
          <Link
            key={s}
            href={`/transport/requests?status=${s}`}
            aria-current={s === status ? 'page' : undefined}
            className={cn('rounded-full border px-3 py-1 text-sm capitalize', s === status ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted')}
          >
            {s}
          </Link>
        ))}
      </nav>
      {error ? (
        <p className="text-sm text-destructive">Could not load requests. Try again.</p>
      ) : (requests ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No {status} requests.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Student</TableHead>
              <TableHead>Request</TableHead>
              <TableHead>Details</TableHead>
              <TableHead>Asked on</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>{status === 'pending' ? 'Decide' : 'Note'}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(requests ?? []).map((r, i) => {
              const s = one(r.student);
              const route = one(r.route);
              return (
                <TableRow key={r.id} data-testid="transport-request-row">
                  <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                  <TableCell>
                    {s && (
                      <Link href={`/students/${s.id}`} className="font-medium hover:underline">
                        {s.name_en} <span className="text-muted-foreground">({s.gr_number})</span>
                      </Link>
                    )}
                  </TableCell>
                  <TableCell>{KIND[r.kind as keyof typeof KIND] ?? r.kind}</TableCell>
                  <TableCell className="max-w-xs">{[route ? `${route.code} ${route.name}` : null, r.note].filter(Boolean).join(' · ')}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(r.created_at.slice(0, 10))}</TableCell>
                  <TableCell>
                    <Badge variant={STATUS_TONE[r.status as keyof typeof STATUS_TONE] ?? 'outline'}>{r.status}</Badge>
                  </TableCell>
                  <TableCell>
                    {r.status === 'pending' ? (
                      <DecideButtons id={r.id} action={decideTransportRequest} approvedText="Request approved." rejectedText="Request rejected." />
                    ) : (
                      (r.decision_note ?? '')
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
