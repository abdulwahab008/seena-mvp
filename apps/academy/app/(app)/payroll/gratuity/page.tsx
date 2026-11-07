import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { ProvidentFundForm } from './pf-form';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'hr_manager', 'accountant'];

export default async function GratuityPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const [{ data: rows }, { data: pf }] = await Promise.all([
    supabase.rpc('gratuity_liability', {}),
    supabase.from('salary_component').select('code, calc_pct').in('code', ['PF_EE', 'PF_ER']).is('effective_to', null),
  ]);
  const total = (rows ?? []).reduce((n, r) => n + r.gratuity_paisa, 0);
  const pct = (code: string) => pf?.find((c) => c.code === code)?.calc_pct;

  return (
    <>
      <PageHeader title="Gratuity and provident fund" description="Gratuity owed to staff today (one month's basic per completed year of service), and provident fund setup." />
      <Card className="mb-6">
        <CardHeader>
          <CardTitle className="text-base">Provident fund</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {pf && pf.length > 0 ? (
            <p data-testid="pf-status">
              Deducted from pay: {pct('PF_EE') ?? 0}% of basic · paid by the school: {pct('PF_ER') ?? 0}% of basic. Change these under Salary Components.
            </p>
          ) : (
            <div className="space-y-3">
              <p className="text-muted-foreground">Not set up. Each payroll run will deduct the employee&apos;s share and record the school&apos;s matching share.</p>
              <ProvidentFundForm />
            </div>
          )}
        </CardContent>
      </Card>
      {(rows ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No current staff.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Staff</TableHead>
              <TableHead>Joined</TableHead>
              <TableHead className="text-right">Years</TableHead>
              <TableHead className="text-right">Basic</TableHead>
              <TableHead className="text-right">Gratuity</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(rows ?? []).map((r) => (
              <TableRow key={r.staff_id} data-testid="gratuity-row">
                <TableCell>
                  {r.full_name} <span className="text-xs text-muted-foreground">{r.employee_code}</span>
                </TableCell>
                <TableCell>{formatDatePk(r.doj)}</TableCell>
                <TableCell className="text-right">{r.years_completed}</TableCell>
                <TableCell className="text-right">{r.basic_paisa ? formatPkr(r.basic_paisa) : 'No salary structure'}</TableCell>
                <TableCell className="text-right">{formatPkr(r.gratuity_paisa)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={4} className="font-medium">
                Total gratuity owed
              </TableCell>
              <TableCell className="text-right font-medium" data-testid="gratuity-total">
                {formatPkr(total)}
              </TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      )}
    </>
  );
}
