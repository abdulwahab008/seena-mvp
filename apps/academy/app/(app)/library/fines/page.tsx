import { libraryViewer } from '@/lib/library-session';
import { formatPkrCompact } from '@/lib/format-money';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { FineActions } from './fine-actions';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function LibraryFinesPage() {
  const { supabase, role } = await libraryViewer();
  const canSettle = role !== null && ['accountant', 'principal', 'owner', 'super_admin'].includes(role);

  const [{ data: outstanding }, { data: fines }] = await Promise.all([
    supabase.from('v_borrower_outstanding_fine').select('borrower_id, outstanding_paisa, loans_with_fines, block_threshold, is_blocked').order('outstanding_paisa', { ascending: false }),
    supabase
      .from('library_fine')
      .select('loan_id, amount, status, accrual_date, loan:loan_id(due_on, returned_at, copy:copy_id(title:title_id(title)))')
      .order('accrual_date', { ascending: false })
      .limit(1000),
  ]);

  const ids = (outstanding ?? []).map((o) => o.borrower_id!);
  const [{ data: students }, { data: staff }] = await Promise.all([
    ids.length ? supabase.from('student').select('id, name_en, gr_number').in('id', ids) : Promise.resolve({ data: [] as { id: string; name_en: string; gr_number: string }[] }),
    ids.length ? supabase.from('app_user').select('user_id, full_name').in('user_id', ids) : Promise.resolve({ data: [] as { user_id: string; full_name: string }[] }),
  ]);
  const names = new Map<string, string>([...(students ?? []).map((s) => [s.id, `${s.name_en} (GR ${s.gr_number})`] as const), ...(staff ?? []).map((s) => [s.user_id, s.full_name] as const)]);

  const perLoan = new Map<string, { title: string; dueOn: string; total: number; outstanding: number; days: number }>();
  for (const f of fines ?? []) {
    const loan = one(f.loan);
    const title = loan ? one(one(loan.copy)?.title ?? null)?.title : '';
    const cur = perLoan.get(f.loan_id) ?? { title: title ?? '', dueOn: loan?.due_on ?? '', total: 0, outstanding: 0, days: 0 };
    cur.total += f.amount;
    cur.days += 1;
    if (f.status === 'outstanding') cur.outstanding += f.amount;
    perLoan.set(f.loan_id, cur);
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title="Library fines"
        description="FR-O07. Overdue fines accrue every night at 02:00 Karachi time, one row per late day, capped per loan. Borrowers whose unpaid fines reach the campus block threshold cannot borrow. Fines are settled or waived with a reason, never deleted."
      />
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Unpaid fines by borrower</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="fine-table">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Borrower</th>
                <th className="pr-3">Outstanding</th>
                <th className="pr-3">Loans</th>
                <th className="pr-3">Block at</th>
                <th className="pr-3">Status</th>
                {canSettle && <th />}
              </tr>
            </thead>
            <tbody>
              {(outstanding ?? []).map((o) => (
                <tr key={o.borrower_id!} className="border-t" data-testid="fine-row">
                  <td className="py-1 pr-3">{names.get(o.borrower_id!) ?? 'You / your child'}</td>
                  <td className="pr-3 font-medium">{formatPkrCompact(o.outstanding_paisa ?? 0)}</td>
                  <td className="pr-3">{o.loans_with_fines}</td>
                  <td className="pr-3">{o.block_threshold != null ? formatPkrCompact(o.block_threshold) : 'Never'}</td>
                  <td className="pr-3">{o.is_blocked ? <Badge variant="destructive">Blocked</Badge> : <Badge variant="outline">Can borrow</Badge>}</td>
                  {canSettle && (
                    <td>
                      <FineActions borrowerId={o.borrower_id!} name={names.get(o.borrower_id!) ?? 'borrower'} />
                    </td>
                  )}
                </tr>
              ))}
              {(outstanding ?? []).length === 0 && (
                <tr>
                  <td colSpan={6} className="py-3 text-muted-foreground">
                    No unpaid library fines.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Fine register by loan</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="loan-fine-table">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Title</th>
                <th className="pr-3">Due</th>
                <th className="pr-3">Days fined</th>
                <th className="pr-3">Total fine</th>
                <th className="pr-3">Still unpaid</th>
              </tr>
            </thead>
            <tbody>
              {[...perLoan.entries()].map(([loanId, l]) => (
                <tr key={loanId} className="border-t">
                  <td className="py-1 pr-3">{l.title}</td>
                  <td className="pr-3">{l.dueOn}</td>
                  <td className="pr-3">{l.days}</td>
                  <td className="pr-3">{formatPkrCompact(l.total)}</td>
                  <td className="pr-3">{formatPkrCompact(l.outstanding)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
