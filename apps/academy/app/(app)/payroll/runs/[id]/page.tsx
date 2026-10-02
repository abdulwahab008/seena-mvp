import { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getPayrollRunDetails } from '../../actions';
import { RunDetailDesk } from './run-detail-desk';

export const metadata: Metadata = {
  title: 'Payroll Run Breakdown | Seena Academy',
};

type Params = { id: string };

export default async function PayrollRunDetailPage({
  params,
}: {
  params: Promise<Params>;
}) {
  const resolvedParams = await params;
  const { run, lines } = await getPayrollRunDetails(resolvedParams.id);

  if (!run) {
    notFound();
  }

  return (
    <div className="space-y-6">
      <RunDetailDesk run={run} lines={lines} />
    </div>
  );
}
