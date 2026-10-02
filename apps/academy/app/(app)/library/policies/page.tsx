import { libraryViewer } from '@/lib/library-session';
import { formatPkrCompact } from '@/lib/format-money';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PolicyForm } from './policy-form';

export default async function LibraryPoliciesPage() {
  const { supabase, role } = await libraryViewer();
  const canEdit = role !== null && ['principal', 'super_admin', 'owner'].includes(role);

  const [{ data: policies }, { data: campusRows }, { data: levels }] = await Promise.all([
    supabase.from('library_borrower_policy').select('*').order('role').order('effective_from', { ascending: false }),
    supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
    supabase.from('class_level').select('ordinal, name_en').order('ordinal'),
  ]);
  const campuses = (campusRows ?? []).map((c) => ({ id: c.id, name: c.name }));
  const classes = (levels ?? []).map((l) => ({ ordinal: l.ordinal, name: l.name_en }));
  const className = (o: number) => classes.find((c) => c.ordinal === o)?.name ?? `Level ${o}`;
  const campusName = (id: string | null) => (id ? (campuses.find((c) => c.id === id)?.name ?? 'Campus') : 'All campuses');

  return (
    <div className="space-y-6">
      <PageHeader
        title="Borrowing policy"
        description="FR-O03. Loan limits, periods, renewals and fines per borrower role and class band. A class band beats the role-wide row, a campus row beats the school-wide row, and the latest effective date wins. Each loan keeps a snapshot of the policy it was issued under."
      />
      {canEdit && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add or change a policy</CardTitle>
          </CardHeader>
          <CardContent>
            <PolicyForm campuses={campuses} classes={classes} />
          </CardContent>
        </Card>
      )}
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Policies in force and scheduled</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="policy-table">
            <thead className="text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Role</th>
                <th className="pr-3">Band</th>
                <th className="pr-3">Campus</th>
                <th className="pr-3">Loans</th>
                <th className="pr-3">Days</th>
                <th className="pr-3">Renewals</th>
                <th className="pr-3">Fine / day</th>
                <th className="pr-3">Cap</th>
                <th className="pr-3">Block at</th>
                <th className="pr-3">Effective</th>
              </tr>
            </thead>
            <tbody>
              {(policies ?? []).map((p) => (
                <tr key={p.id} className="border-t" data-testid="policy-row">
                  <td className="py-1 pr-3 capitalize">{p.role}</td>
                  <td className="pr-3">{p.class_band_from != null && p.class_band_to != null ? `${className(p.class_band_from)} to ${className(p.class_band_to)}` : 'All'}</td>
                  <td className="pr-3">{campusName(p.campus_id)}</td>
                  <td className="pr-3">{p.max_loans}</td>
                  <td className="pr-3">{p.loan_days}</td>
                  <td className="pr-3">{p.max_renewals}</td>
                  <td className="pr-3">{formatPkrCompact(p.fine_per_day)}</td>
                  <td className="pr-3">{p.fine_cap != null ? formatPkrCompact(p.fine_cap) : 'None'}</td>
                  <td className="pr-3">{p.block_threshold != null ? formatPkrCompact(p.block_threshold) : 'Never'}</td>
                  <td className="pr-3">{p.effective_from}</td>
                </tr>
              ))}
              {(policies ?? []).length === 0 && (
                <tr>
                  <td colSpan={10} className="py-3 text-muted-foreground">
                    No policy yet: nobody can borrow until the Principal sets one.
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
