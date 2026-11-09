import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { todayPk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Breakdown, KpiGrid } from '@/components/module-dashboard';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'transport_manager', 'accountant'];

export default async function TransportDashboardPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const today = todayPk();
  const allocated = () =>
    supabase.from('transport_allocation').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).lte('starts_on', today).or(`ends_on.is.null,ends_on.gte.${today}`);
  const boardingToday = (state: 'boarded' | 'absent') =>
    supabase.from('transport_boarding_event').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).eq('state', state).gte('marked_at', `${today}T00:00:00+05:00`).lte('marked_at', `${today}T23:59:59.999+05:00`);

  const [{ data: vehicles }, { data: routes }, students, boarded, absent] = await Promise.all([
    supabase.from('transport_vehicle').select('seat_capacity').eq('campus_id', campus.id).eq('active', true),
    supabase.from('transport_route').select('id, code, name').eq('campus_id', campus.id).eq('active', true).order('code'),
    allocated(),
    boardingToday('boarded'),
    boardingToday('absent'),
  ]);
  const perRoute = await Promise.all((routes ?? []).map((r) => allocated().eq('route_id', r.id)));

  const seats = (vehicles ?? []).reduce((sum, v) => sum + v.seat_capacity, 0);
  const riders = students.count ?? 0;
  const routeRows = (routes ?? []).map((r, i) => ({ key: r.id, label: `${r.code} · ${r.name}`, value: perRoute[i]?.count ?? 0 }));

  return (
    <>
      <PageHeader title="Transport dashboard" description={`Fleet, routes, students riding and today's boarding at ${campus.name}.`} />
      <KpiGrid
        prefix="transport"
        kpis={[
          { id: 'vehicles', label: 'Active vehicles', value: (vehicles ?? []).length },
          { id: 'routes', label: 'Active routes', value: (routes ?? []).length },
          { id: 'allocated', label: 'Students allocated', value: riders },
          { id: 'seats-free', label: 'Seats free across the fleet', value: Math.max(0, seats - riders) },
          { id: 'boarded', label: 'Boarded today', value: boarded.count ?? 0 },
          { id: 'absent', label: 'Marked absent today', value: absent.count ?? 0 },
        ]}
      />
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Breakdown title="Students per route" rows={routeRows} empty="No active routes yet." bars />
      </div>
    </>
  );
}
