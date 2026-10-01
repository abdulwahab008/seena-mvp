import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { loose, pkr } from '@/lib/transport/rpc';
import { PrintButton } from './print-button';

export const dynamic = 'force-dynamic';

// The printed route sheet: one page, every stop in order with its pickup and
// drop time. The parent portal shows the same rows from the same view.
export default async function RouteSheetPage({ params }: { params: Promise<{ routeId: string }> }) {
  const { routeId } = await params;
  const supabase = loose(await supabaseServer());
  const { data: route } = await supabase.from('transport_route').select('id, code, name, shift').eq('id', routeId).maybeSingle();
  if (!route) notFound();
  const { data: stops } = await supabase
    .from('v_transport_route_sheet')
    .select('stop_id, seq, stop_name, stop_name_ur, pickup_time, drop_time, slab_code, monthly_amount_paisa')
    .eq('route_id', routeId)
    .order('seq');
  const { data: assignment } = await supabase
    .from('v_transport_route_crew')
    .select('vehicle_reg_no, driver_name, driver_phone, driver_cnic, conductor_name, attendant_name')
    .eq('route_id', routeId)
    .limit(1);
  const crew = ((assignment ?? []) as { vehicle_reg_no: string; driver_name: string; driver_phone: string | null; driver_cnic: string | null; conductor_name: string | null; attendant_name: string | null }[])[0];

  return (
    <div className="mx-auto max-w-3xl space-y-4 p-4 print:p-0" data-testid="route-sheet">
      <div className="flex items-center justify-between print:hidden">
        <h1 className="text-xl font-semibold">Route sheet</h1>
        <PrintButton />
      </div>
      <header className="space-y-1">
        <h2 className="text-2xl font-semibold">
          {route.code} · {route.name}
        </h2>
        <p className="text-sm">Shift: {route.shift}</p>
        {crew && (
          <p className="text-sm" data-testid="sheet-crew">
            Vehicle {crew.vehicle_reg_no} · Driver {crew.driver_name} {crew.driver_phone ?? ''} · CNIC {crew.driver_cnic ?? '-'}
            {crew.conductor_name ? ` · Conductor ${crew.conductor_name}` : ''}
            {crew.attendant_name ? ` · Attendant ${crew.attendant_name}` : ''}
          </p>
        )}
      </header>
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr className="border-b text-left">
            <th className="py-1">#</th>
            <th>Stop</th>
            <th>Pickup</th>
            <th>Drop</th>
            <th>Monthly fare</th>
          </tr>
        </thead>
        <tbody>
          {((stops ?? []) as { stop_id: string; seq: number; stop_name: string; stop_name_ur: string | null; pickup_time: string | null; drop_time: string | null; slab_code: string | null; monthly_amount_paisa: number | null }[]).map((s) => (
            <tr key={s.stop_id} className="border-b" data-testid="sheet-row">
              <td className="py-1">{s.seq}</td>
              <td>
                {s.stop_name}
                {s.stop_name_ur && (
                  <span className="ms-2" dir="rtl">
                    {s.stop_name_ur}
                  </span>
                )}
              </td>
              <td data-testid="sheet-pickup">{s.pickup_time?.slice(0, 5) ?? '-'}</td>
              <td data-testid="sheet-drop">{s.drop_time?.slice(0, 5) ?? '-'}</td>
              <td>{s.slab_code ? `${s.slab_code} · ${pkr(s.monthly_amount_paisa)}` : '-'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
