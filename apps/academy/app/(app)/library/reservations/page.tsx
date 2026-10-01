import { libraryViewer } from '@/lib/library-session';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CancelReservationButton, ReserveForBorrower } from './reservation-forms';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function LibraryReservationsPage() {
  const { supabase, isStaff } = await libraryViewer();

  const [{ data: reservations }, { data: queue }] = await Promise.all([
    supabase
      .from('library_reservation')
      .select('id, borrower_id, status, queued_at, hold_expires_at, title:title_id(title), copy:held_copy_id(accession_no)')
      .in('status', ['waiting', 'held'])
      .order('queued_at'),
    supabase.from('v_library_queue').select('id, queue_position'),
  ]);
  const position = new Map((queue ?? []).map((q) => [q.id!, q.queue_position]));
  const ids = [...new Set((reservations ?? []).map((r) => r.borrower_id))];
  const [{ data: students }, { data: staff }] = await Promise.all([
    isStaff && ids.length ? supabase.from('student').select('id, name_en').in('id', ids) : Promise.resolve({ data: [] as { id: string; name_en: string }[] }),
    isStaff && ids.length ? supabase.from('app_user').select('user_id, full_name').in('user_id', ids) : Promise.resolve({ data: [] as { user_id: string; full_name: string }[] }),
  ]);
  const names = new Map<string, string>([...(students ?? []).map((s) => [s.id, s.name_en] as const), ...(staff ?? []).map((s) => [s.user_id, s.full_name] as const)]);

  return (
    <div className="space-y-6">
      <PageHeader
        title={isStaff ? 'Reservations' : 'My reservations'}
        description="FR-O06. First come, first served. When a copy is returned it is held for the next reader for 48 hours; an uncollected hold lapses and passes to the next in line."
      />
      {isStaff && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Reserve for a borrower</CardTitle>
          </CardHeader>
          <CardContent>
            <ReserveForBorrower />
          </CardContent>
        </Card>
      )}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Waiting and held ({reservations?.length ?? 0})</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="reservation-table">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Title</th>
                {isStaff && <th className="pr-3">Borrower</th>}
                <th className="pr-3">Status</th>
                <th className="pr-3">Detail</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {(reservations ?? []).map((r) => (
                <tr key={r.id} className="border-t" data-testid="reservation-row">
                  <td className="py-1 pr-3">{one(r.title)?.title}</td>
                  {isStaff && <td className="pr-3">{names.get(r.borrower_id) ?? ''}</td>}
                  <td className="pr-3">
                    <Badge variant={r.status === 'held' ? 'success' : 'outline'}>{r.status === 'held' ? 'Held for collection' : 'Waiting'}</Badge>
                  </td>
                  <td className="pr-3 text-muted-foreground">
                    {r.status === 'waiting' ? `Queue position ${position.get(r.id) ?? '?'}` : `Collect ${one(r.copy)?.accession_no ?? ''} before ${new Date(r.hold_expires_at!).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}`}
                  </td>
                  <td>
                    <CancelReservationButton reservationId={r.id} />
                  </td>
                </tr>
              ))}
              {(reservations ?? []).length === 0 && (
                <tr>
                  <td colSpan={5} className="py-3 text-muted-foreground">
                    No active reservations.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
