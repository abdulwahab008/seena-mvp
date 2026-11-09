import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkr } from '@/lib/challan/html';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { PayScaleForm } from './pay-scale-form';

export const dynamic = 'force-dynamic';

const READ_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager', 'accountant'];
const WRITE_ROLES = ['super_admin', 'owner', 'hr_manager'];

export default async function PayScalesPage({ searchParams }: { searchParams: Promise<{ edit?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !READ_ROLES.includes(actor.role)) notFound();
  const { edit } = await searchParams;
  const canWrite = WRITE_ROLES.includes(actor.role);
  const supabase = await supabaseServer();
  const { data: scales } = await supabase.from('pay_scale').select('id, code, name, min_basic_paisa, max_basic_paisa, annual_increment_paisa').order('code');
  const editing = canWrite ? (scales ?? []).find((s) => s.id === edit) : undefined;

  return (
    <>
      <PageHeader title="Pay scales" description="Basic-pay bands (BPS grades) with their yearly increment. A salary structure on a scale must keep its basic inside the band." />
      {canWrite && (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle className="text-base">{editing ? `Edit ${editing.code}` : 'Add a pay scale'}</CardTitle>
          </CardHeader>
          <CardContent>
            <PayScaleForm
              key={editing?.id ?? 'new'}
              initial={
                editing && {
                  id: editing.id,
                  code: editing.code,
                  name: editing.name,
                  minPkr: String(editing.min_basic_paisa / 100),
                  maxPkr: String(editing.max_basic_paisa / 100),
                  incrementPkr: String(editing.annual_increment_paisa / 100),
                }
              }
            />
          </CardContent>
        </Card>
      )}
      {(scales ?? []).length === 0 ? (
        <EmptyState title="No pay scales yet" description={canWrite ? 'Add the grades your school pays on, e.g. BPS-14.' : 'HR has not added any pay scales.'} />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Code</TableHead>
              <TableHead>Name</TableHead>
              <TableHead className="text-right">Minimum</TableHead>
              <TableHead className="text-right">Maximum</TableHead>
              <TableHead className="text-right">Annual increment</TableHead>
              <TableHead className="text-right">Stages</TableHead>
              {canWrite && <TableHead />}
            </TableRow>
          </TableHeader>
          <TableBody>
            {(scales ?? []).map((s) => (
              <TableRow key={s.id} data-testid="pay-scale-row">
                <TableCell className="font-medium">{s.code}</TableCell>
                <TableCell>{s.name}</TableCell>
                <TableCell className="text-right">{formatPkr(s.min_basic_paisa)}</TableCell>
                <TableCell className="text-right">{formatPkr(s.max_basic_paisa)}</TableCell>
                <TableCell className="text-right">{formatPkr(s.annual_increment_paisa)}</TableCell>
                <TableCell className="text-right">{s.annual_increment_paisa > 0 ? Math.floor((s.max_basic_paisa - s.min_basic_paisa) / s.annual_increment_paisa) : '—'}</TableCell>
                {canWrite && (
                  <TableCell className="text-right">
                    <Link href={`/payroll/pay-scales?edit=${s.id}`} className="text-sm underline">
                      Edit
                    </Link>
                  </TableCell>
                )}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </>
  );
}
