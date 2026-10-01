import { libraryViewer } from '@/lib/library-session';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { IssueDesk } from './issue-desk';
import { ReturnDesk } from './return-desk';
import { RenewButton } from '../reservations/reservation-forms';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const todayIso = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

export default async function LibraryCirculationPage() {
  const { supabase, isStaff } = await libraryViewer();
  if (!isStaff) {
    return (
      <div className="space-y-6">
        <PageHeader title="Circulation desk" description="The circulation desk is for library staff. Your own loans are in the portal." />
      </div>
    );
  }

  const { data: loans } = await supabase
    .from('library_loan')
    .select('id, borrower_id, borrower_role, issued_at, due_on, copy:copy_id(accession_no, title:title_id(title))')
    .is('returned_at', null)
    .order('due_on')
    .limit(200);
  const ids = [...new Set((loans ?? []).map((l) => l.borrower_id))];
  const [{ data: students }, { data: staff }] = await Promise.all([
    ids.length ? supabase.from('student').select('id, name_en').in('id', ids) : Promise.resolve({ data: [] as { id: string; name_en: string }[] }),
    ids.length ? supabase.from('app_user').select('user_id, full_name').in('user_id', ids) : Promise.resolve({ data: [] as { user_id: string; full_name: string }[] }),
  ]);
  const names = new Map<string, string>([...(students ?? []).map((s) => [s.id, s.name_en] as const), ...(staff ?? []).map((s) => [s.user_id, s.full_name] as const)]);
  const today = todayIso();

  return (
    <div className="space-y-6">
      <PageHeader title="Circulation desk" description="FR-O04. Look up the borrower by card or name, then scan the book. Limits, unpaid-fine blocks and due dates (rolled past holidays) are enforced by the database." />
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Issue a book</CardTitle>
        </CardHeader>
        <CardContent>
          <IssueDesk />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Return a book (FR-O05)</CardTitle>
        </CardHeader>
        <CardContent>
          <ReturnDesk />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Open loans ({loans?.length ?? 0})</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="open-loans">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Title</th>
                <th className="pr-3">Accession</th>
                <th className="pr-3">Borrower</th>
                <th className="pr-3">Due</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {(loans ?? []).map((l) => {
                const copy = one(l.copy);
                const title = copy ? one(copy.title) : null;
                return (
                  <tr key={l.id} className="border-t" data-testid="loan-row">
                    <td className="py-1 pr-3">{title?.title}</td>
                    <td className="pr-3 font-mono">{copy?.accession_no}</td>
                    <td className="pr-3">{names.get(l.borrower_id) ?? l.borrower_role}</td>
                    <td className="pr-3">
                      {l.due_on} {l.due_on < today && <Badge variant="destructive">Overdue</Badge>}
                    </td>
                    <td>
                      <RenewButton loanId={l.id} />
                    </td>
                  </tr>
                );
              })}
              {(loans ?? []).length === 0 && (
                <tr>
                  <td colSpan={5} className="py-3 text-muted-foreground">
                    No books are out.
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
