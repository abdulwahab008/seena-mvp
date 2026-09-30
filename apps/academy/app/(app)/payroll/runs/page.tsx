import { Metadata } from 'next';
import { supabaseServer } from '@/lib/supabase/server';
import { getPayrollRuns } from '../actions';
import { RunsDesk } from './runs-desk';

export const metadata: Metadata = {
  title: 'Payroll Runs & Approvals | Payroll | Seena Academy',
};

type SearchParams = { campus?: string };

export default async function PayrollRunsPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const campusId = params.campus || null;

  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data: campuses } = await (supabase as any)
    .from('campus')
    .select('id, code, name')
    .order('name');

  const runs = await getPayrollRuns(campusId);

  return (
    <div className="space-y-6">
      <RunsDesk
        initialRuns={runs}
        campuses={campuses || []}
        selectedCampusId={campusId}
      />
    </div>
  );
}
