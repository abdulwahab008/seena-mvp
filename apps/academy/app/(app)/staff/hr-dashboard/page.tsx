import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatDatePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CnicExpiryForm } from './cnic-expiry-form';

export const dynamic = 'force-dynamic';

const HR = ['super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager'];
type Dashboard = {
  headcount: number;
  joiners_90d: number;
  leavers_90d: number;
  by_department: { department: string; count: number }[];
  birthdays: { name: string; day: number }[];
  cnic_expiring: { name: string; expires_on: string }[];
};

export default async function HrDashboardPage() {
  const actor = await getCurrentActor();
  if (!actor || !HR.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('hr_dashboard', {});
  const d = data as Dashboard | null;
  if (!d) return <p className="text-sm text-muted-foreground">The HR dashboard could not be loaded.</p>;
  const month = new Intl.DateTimeFormat('en-PK', { month: 'long', timeZone: 'Asia/Karachi' }).format(new Date());

  return (
    <>
      <PageHeader title="HR dashboard" description="Headcount, joiners and leavers, this month's birthdays and CNICs about to expire." />
      <div className="grid gap-4 sm:grid-cols-3">
        {[
          { label: 'Staff', value: d.headcount, id: 'headcount' },
          { label: 'Joined in the last 90 days', value: d.joiners_90d, id: 'joiners' },
          { label: 'Left in the last 90 days', value: d.leavers_90d, id: 'leavers' },
        ].map((k) => (
          <Card key={k.id}>
            <CardHeader className="pb-1">
              <CardTitle className="text-sm font-normal text-muted-foreground">{k.label}</CardTitle>
            </CardHeader>
            <CardContent className="text-2xl font-semibold" data-testid={`hr-kpi-${k.id}`}>
              {k.value}
            </CardContent>
          </Card>
        ))}
      </div>
      <div className="mt-6 grid gap-6 lg:grid-cols-3">
        <section className="space-y-2">
          <h2 className="font-medium">By department</h2>
          {d.by_department.length === 0 ? (
            <p className="text-sm text-muted-foreground">No staff yet.</p>
          ) : (
            d.by_department.map((x) => (
              <p key={x.department} className="flex justify-between text-sm">
                <span>{x.department}</span>
                <span className="text-muted-foreground">{x.count}</span>
              </p>
            ))
          )}
        </section>
        <section className="space-y-2">
          <h2 className="font-medium">Birthdays in {month}</h2>
          {d.birthdays.length === 0 ? (
            <p className="text-sm text-muted-foreground">None this month.</p>
          ) : (
            d.birthdays.map((b) => (
              <p key={`${b.name}-${b.day}`} className="text-sm" data-testid="hr-birthday">
                {b.day} {month} · {b.name}
              </p>
            ))
          )}
        </section>
        <section className="space-y-2">
          <h2 className="font-medium">CNICs expiring within 60 days</h2>
          {d.cnic_expiring.length === 0 ? (
            <p className="text-sm text-muted-foreground">None.</p>
          ) : (
            d.cnic_expiring.map((c) => (
              <p key={`${c.name}-${c.expires_on}`} className="text-sm" data-testid="hr-cnic-expiring">
                {c.name} · {formatDatePk(c.expires_on)}
              </p>
            ))
          )}
          <CnicExpiryForm />
        </section>
      </div>
    </>
  );
}
