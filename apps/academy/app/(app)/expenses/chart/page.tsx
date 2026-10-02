import { supabaseServer } from '@/lib/supabase/server';
import { ExpenseChartDesk } from './expense-chart-desk';
import { getExpenseChartData } from './actions';

/**
 * FR-L10 — Expense Head Chart of Accounts with Monthly Budgets.
 *
 * Renders the hierarchical expense head tree with budget vs. actual
 * overlay. Accountants and Principals can add/edit heads and set
 * monthly budgets from this page.
 */

const ALLOWED_ROLES = ['super_admin', 'owner', 'principal', 'accountant'];

type SearchParams = { campus?: string; session?: string; month?: string };

export default async function ExpenseChartPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: appUser } = await supabase
    .from('app_user')
    .select('app_role')
    .eq('user_id', user!.id)
    .single();

  const role = appUser?.app_role ?? 'none';

  if (!ALLOWED_ROLES.includes(role)) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Expense Chart &amp; Budgets</h1>
        <p className="text-sm text-muted-foreground" data-testid="expense-chart-forbidden">
          Only an Accountant, Principal, Owner or Super Admin can manage the
          chart of accounts.
        </p>
      </div>
    );
  }

  // Load campuses and sessions for the filter dropdowns.
  const [{ data: campusRows }, { data: sessionRows }] = await Promise.all([
    supabase
      .from('campus')
      .select('id, code, name')
      .eq('status', 'active')
      .order('code'),
    supabase
      .from('academic_session')
      .select('id, name, status')
      .order('start_date', { ascending: false })
      .limit(10),
  ]);

  const campuses = campusRows ?? [];
  const sessions = sessionRows ?? [];

  // Resolve active filters
  const campusId = campuses.some((c) => c.id === params.campus)
    ? params.campus!
    : campuses[0]?.id ?? null;
  const sessionId = sessions.some((s) => s.id === params.session)
    ? params.session!
    : sessions.find((s) => s.status === 'active')?.id ?? sessions[0]?.id ?? null;
  const month = params.month ?? new Date().toISOString().slice(0, 7); // YYYY-MM

  // Load the chart data server-side for the initial render.
  let heads: Awaited<ReturnType<typeof getExpenseChartData>> = [];
  try {
    heads = await getExpenseChartData(campusId, sessionId, `${month}-01`);
  } catch {
    // Heads array stays empty; error will surface in the client.
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Expense Chart &amp; Budgets</h1>
        <p className="text-sm text-muted-foreground">
          FR-L10 — Hierarchical chart of expense heads with monthly budget
          allocation and spend tracking. Only leaf-level heads can have vouchers
          charged against them.
        </p>
      </div>

      <ExpenseChartDesk
        role={role}
        campuses={campuses}
        sessions={sessions}
        initialHeads={heads}
        initialCampusId={campusId}
        initialSessionId={sessionId}
        initialMonth={month}
      />
    </div>
  );
}
