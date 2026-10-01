import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ActionButton, SpecForm } from '@/components/spec-form';
import { loose, pickCampus, todayPk } from '@/lib/transport/rpc';
import { allocateBed, transferBed, vacate } from './actions';

export const dynamic = 'force-dynamic';

type Row = {
  id: string; starts_on: string; ends_on: string | null;
  student: { name_en: string; gr_number: string } | { name_en: string; gr_number: string }[] | null;
  bed: { bed_code: string } | { bed_code: string }[] | null;
};
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function HostelAllocationsPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const campus = await pickCampus(supabase, sp.campus_id);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const today = todayPk();
  const [{ data: rows }, { data: free }] = await Promise.all([
    supabase
      .from('hostel_allocation')
      .select('id, starts_on, ends_on, student:student_id(name_en, gr_number), bed:bed_id(bed_code)')
      .eq('campus_id', campus.id)
      .or(`ends_on.is.null,ends_on.gte.${today}`)
      .order('starts_on', { ascending: false }),
    supabase.from('hostel_bed').select('bed_code, room:room_id(status)').eq('campus_id', campus.id).eq('status', 'available').order('bed_code').limit(60),
  ]);
  const freeBeds = ((free ?? []) as { bed_code: string; room: { status: string } | { status: string }[] | null }[]).filter((b) => one(b.room)?.status === 'in_service');

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Bed allocation</h1>
        <p className="text-sm text-muted-foreground">
          FR-Q02 — a bed can hold one student at a time and a student one bed at a time; the database refuses a double booking even when two clerks submit at once.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Allocate a bed</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <SpecForm
            testId="bed-form"
            submitLabel="Allocate"
            action={allocateBed}
            columns={4}
            fields={[
              { name: 'grNumber', label: 'Student GR number', required: true },
              { name: 'bedCode', label: 'Bed code', required: true, placeholder: 'IQ-105-B3' },
              { name: 'from', label: 'Starts on', type: 'date', required: true, defaultValue: today },
              { name: 'to', label: 'Last night (blank = open)', type: 'date' },
            ]}
          />
          <p className="text-muted-foreground" data-testid="free-beds">
            Free beds: {freeBeds.length === 0 ? 'none' : freeBeds.map((b) => b.bed_code).join(', ')}
            {freeBeds.length === 60 ? ' …' : ''}
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Current stays</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="stay-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Student</th>
                <th>Bed</th>
                <th>From</th>
                <th>Last night</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {((rows ?? []) as Row[]).map((r) => (
                <tr key={r.id} className="border-t" data-testid="stay-row">
                  <td className="py-1">
                    {one(r.student)?.name_en} <span className="text-muted-foreground">({one(r.student)?.gr_number})</span>
                  </td>
                  <td>{one(r.bed)?.bed_code}</td>
                  <td>{r.starts_on}</td>
                  <td>{r.ends_on ?? 'open'}</td>
                  <td>{!r.ends_on && <ActionButton label="End today" variant="ghost" confirm="End this student's hostel stay tonight?" action={() => vacate(r.id)} />}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Transfer to another bed</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm">
          <p className="text-muted-foreground">The old stay ends the night before and the new one starts on the date you choose, in one step.</p>
          <SpecForm
            testId="transfer-form"
            submitLabel="Transfer"
            action={transferBed}
            columns={4}
            fields={[
              { name: 'grNumber', label: 'Student GR number', required: true },
              { name: 'bedCode', label: 'New bed code', required: true, placeholder: 'IQ-210-B1' },
              { name: 'from', label: 'Moves on', type: 'date', required: true, defaultValue: today },
              { name: 'reason', label: 'Reason' },
            ]}
          />
        </CardContent>
      </Card>
    </div>
  );
}
