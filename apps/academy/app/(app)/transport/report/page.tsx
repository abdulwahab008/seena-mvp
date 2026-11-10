import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { todayPk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const pkr = (paisa: number) => new Intl.NumberFormat('en-PK', { maximumFractionDigits: 0 }).format(paisa / 100);
const OTHER = [
  { href: '/transport/allocations', label: 'Passengers list' },
  { href: '/transport/fleet', label: 'Vehicles report' },
  { href: '/transport/routes', label: 'Routes and stops' },
  { href: '/transport/boarding', label: 'Boarding attendance' },
  { href: '/transport/requests', label: 'Parent requests' },
];

export default async function TransportReportPage() {
  const today = todayPk();
  const supabase = await supabaseServer();
  const [{ data: routes }, { data: allocations }, { data: assignments }] = await Promise.all([
    supabase.from('transport_route').select('id, code, name, shift').eq('active', true).order('code'),
    supabase
      .from('transport_allocation')
      .select('route_id, fare_slab:fare_slab_id(monthly_amount_paisa)')
      .lte('starts_on', today)
      .or(`ends_on.is.null,ends_on.gte.${today}`),
    supabase
      .from('transport_trip_assignment')
      .select('route_id, vehicle:vehicle_id(reg_no, seat_capacity)')
      .lte('effective_from', today)
      .or(`effective_to.is.null,effective_to.gte.${today}`),
  ]);
  const rows = (routes ?? []).map((r) => {
    const riders = (allocations ?? []).filter((a) => a.route_id === r.id);
    const vehicle = one((assignments ?? []).find((a) => a.route_id === r.id)?.vehicle);
    const fares = riders.reduce((t, a) => t + (one(a.fare_slab)?.monthly_amount_paisa ?? 0), 0);
    const seats = vehicle?.seat_capacity ?? 0;
    return { ...r, riders: riders.length, vehicle: vehicle?.reg_no ?? '', seats, fares, occupancy: seats ? Math.round((riders.length / seats) * 100) : null };
  });
  const riders = rows.reduce((t, r) => t + r.riders, 0);
  const seats = rows.reduce((t, r) => t + r.seats, 0);
  const fares = rows.reduce((t, r) => t + r.fares, 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Transport reports</h1>
          <p className="text-sm text-muted-foreground">Riders, seats and the monthly fare each route brings in today.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-4">
        <Stat label="Active routes" value={rows.length} />
        <Stat label="Students riding" value={riders} />
        <Stat label="Seat occupancy" value={seats ? `${Math.round((riders / seats) * 100)}%` : '—'} hint={`${riders} of ${seats} seats`} />
        <Stat label="Monthly fares" value={`PKR ${pkr(fares)}`} />
      </section>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No active routes yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Route</TableHead>
              <TableHead>Shift</TableHead>
              <TableHead>Vehicle</TableHead>
              <TableHead className="text-right">Seats</TableHead>
              <TableHead className="text-right">Riders</TableHead>
              <TableHead className="text-right">Occupancy</TableHead>
              <TableHead className="text-right">Monthly fares (PKR)</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={r.id} data-testid="route-report-row">
                <TableCell className="font-medium">
                  {r.code} {r.name}
                </TableCell>
                <TableCell className="capitalize">{r.shift}</TableCell>
                <TableCell>{r.vehicle}</TableCell>
                <TableCell className="tabular text-right">{r.seats || ''}</TableCell>
                <TableCell className="tabular text-right">{r.riders}</TableCell>
                <TableCell className={`tabular text-right ${r.occupancy !== null && r.occupancy > 100 ? 'font-medium text-destructive' : ''}`}>{r.occupancy === null ? '' : `${r.occupancy}%`}</TableCell>
                <TableCell className="tabular text-right">{pkr(r.fares)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={3}>Total</TableCell>
              <TableCell className="tabular text-right">{seats}</TableCell>
              <TableCell className="tabular text-right">{riders}</TableCell>
              <TableCell />
              <TableCell className="tabular text-right">{pkr(fares)}</TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      )}
      <section className="space-y-2 print:hidden">
        <h2 className="text-lg font-semibold">More transport reports</h2>
        <ul className="divide-y rounded-lg border">
          {OTHER.map((r, i) => (
            <li key={r.href} className="flex items-center gap-3 px-4 py-2.5 text-sm">
              <span className="tabular w-6 text-muted-foreground">{i + 1}</span>
              <span className="flex-1">{r.label}</span>
              <Link href={r.href} className="font-medium text-primary hover:underline">
                View
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
