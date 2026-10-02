import { libraryViewer } from '@/lib/library-session';
import { formatPkrCompact } from '@/lib/format-money';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ReverseButton, WriteOffForm } from './write-off-forms';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const BASIS: Record<string, string> = { purchase_cost: 'Purchase cost', market: 'Market value', multiple: 'Cost x multiplier' };

export default async function LibraryWriteOffsPage() {
  const { supabase, role } = await libraryViewer();
  const canWrite = role !== null && ['librarian', 'principal', 'owner', 'super_admin'].includes(role);

  const { data: rows } = await supabase
    .from('library_write_off')
    .select('id, borrower_id, declared_at, basis, multiplier, base_amount, fine_component, charge_amount, reversal_of, reversed_at, reason, recovery_note, copy:copy_id(accession_no, title:title_id(title))')
    .order('declared_at', { ascending: false })
    .limit(200);
  const ids = [...new Set((rows ?? []).map((r) => r.borrower_id).filter((x): x is string => !!x))];
  const [{ data: students }, { data: staff }] = await Promise.all([
    ids.length ? supabase.from('student').select('id, name_en').in('id', ids) : Promise.resolve({ data: [] as { id: string; name_en: string }[] }),
    ids.length ? supabase.from('app_user').select('user_id, full_name').in('user_id', ids) : Promise.resolve({ data: [] as { user_id: string; full_name: string }[] }),
  ]);
  const names = new Map<string, string>([...(students ?? []).map((s) => [s.id, s.name_en] as const), ...(staff ?? []).map((s) => [s.user_id, s.full_name] as const)]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Lost copies and write-offs"
        description="FR-O08. A lost copy is written off and the replacement cost plus accrued fines is posted once to the student's fee ledger under LIB_RECOVERY. A found copy is reversed with a credit note: nothing is deleted and the accession number is never reused."
      />
      {canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Declare a copy lost</CardTitle>
          </CardHeader>
          <CardContent>
            <WriteOffForm />
          </CardContent>
        </Card>
      )}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Write-off register</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="write-off-table">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Date</th>
                <th className="pr-3">Title</th>
                <th className="pr-3">Accession</th>
                <th className="pr-3">Borrower</th>
                <th className="pr-3">Basis</th>
                <th className="pr-3">Fine</th>
                <th className="pr-3">Charge</th>
                <th className="pr-3">State</th>
                {canWrite && <th />}
              </tr>
            </thead>
            <tbody>
              {(rows ?? []).map((r) => {
                const copy = one(r.copy);
                const isReversal = !!r.reversal_of;
                return (
                  <tr key={r.id} className="border-t" data-testid="write-off-row">
                    <td className="py-1 pr-3">{new Date(r.declared_at).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })}</td>
                    <td className="pr-3">{one(copy?.title ?? null)?.title}</td>
                    <td className="pr-3 font-mono">{copy?.accession_no}</td>
                    <td className="pr-3">{r.borrower_id ? (names.get(r.borrower_id) ?? 'Borrower') : 'None (lost from shelf)'}</td>
                    <td className="pr-3">{BASIS[r.basis]}{r.basis === 'multiple' ? ` x ${r.multiplier}` : ''}</td>
                    <td className="pr-3">{formatPkrCompact(r.fine_component)}</td>
                    <td className="pr-3 font-medium">{isReversal ? `-${formatPkrCompact(r.charge_amount)}` : formatPkrCompact(r.charge_amount)}</td>
                    <td className="pr-3">
                      {isReversal ? <Badge variant="info">Reversal (credit note)</Badge> : r.reversed_at ? <Badge variant="outline">Reversed</Badge> : <Badge variant="destructive">Written off</Badge>}
                      {r.recovery_note && <span className="ml-2 text-xs text-muted-foreground">{r.recovery_note}</span>}
                    </td>
                    {canWrite && <td>{!isReversal && !r.reversed_at && <ReverseButton writeOffId={r.id} />}</td>}
                  </tr>
                );
              })}
              {(rows ?? []).length === 0 && (
                <tr>
                  <td colSpan={9} className="py-3 text-muted-foreground">
                    Nothing has been written off.
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
