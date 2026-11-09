import { notFound } from 'next/navigation';
import { libraryViewer } from '@/lib/library-session';
import { formatPkrCompact } from '@/lib/format-money';
import { todayPk, toPkDate } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Breakdown, KpiGrid } from '@/components/module-dashboard';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'librarian'];
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const COPY_STATUS = [
  { value: 'available', label: 'On the shelf' },
  { value: 'issued', label: 'Issued' },
  { value: 'reserved_hold', label: 'Held for a reservation' },
  { value: 'in_repair', label: 'In repair' },
  { value: 'lost', label: 'Lost' },
] as const;

export default async function LibraryDashboardPage() {
  const { supabase, role } = await libraryViewer();
  if (!role || !ROLES.includes(role)) notFound();
  const today = todayPk();
  const since = toPkDate(new Date(Date.now() - 30 * 86_400_000));

  const [titles, copies, issued, overdue, { data: fines }, { data: recent }, ...byStatus] = await Promise.all([
    supabase.from('library_title').select('id', { count: 'exact', head: true }),
    supabase.from('library_copy').select('id', { count: 'exact', head: true }).neq('status', 'written_off'),
    supabase.from('library_loan').select('id', { count: 'exact', head: true }).is('returned_at', null),
    supabase.from('library_loan').select('id', { count: 'exact', head: true }).is('returned_at', null).lt('due_on', today),
    supabase.from('v_borrower_outstanding_fine').select('outstanding_paisa, is_blocked'),
    supabase.from('library_loan').select('copy:copy_id(title:title_id(id, title))').gte('issued_at', `${since}T00:00:00+05:00`).order('issued_at', { ascending: false }),
    ...COPY_STATUS.map((s) => supabase.from('library_copy').select('id', { count: 'exact', head: true }).eq('status', s.value)),
  ]);

  const outstanding = (fines ?? []).reduce((sum, f) => sum + (f.outstanding_paisa ?? 0), 0);
  const blocked = (fines ?? []).filter((f) => f.is_blocked).length;
  const borrowed = new Map<string, { title: string; count: number }>();
  for (const loan of recent ?? []) {
    const title = one(one(loan.copy)?.title ?? null);
    if (!title) continue;
    const row = borrowed.get(title.id) ?? { title: title.title, count: 0 };
    row.count += 1;
    borrowed.set(title.id, row);
  }
  const topBorrowed = [...borrowed.entries()]
    .sort((a, b) => b[1].count - a[1].count || a[1].title.localeCompare(b[1].title))
    .slice(0, 8)
    .map(([id, r]) => ({ key: id, label: r.title, value: r.count }));
  const statusRows = COPY_STATUS.map((s, i) => ({ key: s.value, label: s.label, value: byStatus[i]?.count ?? 0 }));

  return (
    <>
      <PageHeader title="Library dashboard" description="Catalogue size, books out on loan, overdue loans and unpaid fines." />
      <KpiGrid
        prefix="library"
        kpis={[
          { id: 'titles', label: 'Titles', value: titles.count ?? 0 },
          { id: 'copies', label: 'Copies (excluding written off)', value: copies.count ?? 0 },
          { id: 'issued', label: 'Issued now', value: issued.count ?? 0 },
          { id: 'overdue', label: 'Overdue', value: overdue.count ?? 0 },
          { id: 'fines', label: 'Fines outstanding', value: formatPkrCompact(outstanding) },
          { id: 'blocked', label: 'Borrowers blocked by fines', value: blocked },
        ]}
      />
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Breakdown title="Most borrowed in the last 30 days" rows={topBorrowed} empty="Nothing borrowed in the last 30 days." bars />
        <Breakdown title="Copies by status" rows={statusRows} empty="No copies yet." bars />
      </div>
    </>
  );
}
