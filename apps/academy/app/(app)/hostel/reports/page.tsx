import { supabaseServer } from '@/lib/supabase/server';
import { allRows } from '@/lib/supabase/all-rows';
import { one } from '@/lib/hr/current-role';
import { formatDatePk, todayPk } from '@/lib/dates';
import { pkr } from '@/lib/rpc-action';
import { PrintButton } from '@/components/print-button';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

export default async function HostelReportsPage({ searchParams }: { searchParams: Promise<{ owing?: string }> }) {
  const owingOnly = (await searchParams).owing === '1';
  const today = todayPk();
  const supabase = await supabaseServer();
  const [{ data: beds }, { data: stays }] = await Promise.all([
    supabase.from('hostel_bed').select('id, status, room:room_id(block:block_id(id, name))'),
    supabase
      .from('hostel_allocation')
      .select('enrolment_id, starts_on, student:student_id(id, name_en, gr_number), enrolment:enrolment_id(section:section_id(name, class_level:class_level_id(name_en))), bed:bed_id(bed_code, room:room_id(room_no, block:block_id(name)))')
      .lte('starts_on', today)
      .or(`ends_on.is.null,ends_on.gte.${today}`),
  ]);
  const enrolmentIds = (stays ?? []).map((s) => s.enrolment_id);
  const { data: ledger } = enrolmentIds.length
    ? await allRows((from, to) => supabase.from('fee_ledger').select('enrolment_id, direction, amount_paisa').in('enrolment_id', enrolmentIds).order('id').range(from, to))
    : { data: [] };
  const balance = new Map<string, number>();
  for (const l of ledger) balance.set(l.enrolment_id, (balance.get(l.enrolment_id) ?? 0) + (l.direction === 'debit' ? l.amount_paisa : -l.amount_paisa));

  const residents = (stays ?? [])
    .map((s) => {
      const st = one(s.student);
      const sec = one(one(s.enrolment)?.section);
      const bed = one(s.bed);
      return {
        id: st?.id ?? s.enrolment_id,
        name: st?.name_en ?? '',
        gr: st?.gr_number ?? '',
        cls: `${one(sec?.class_level)?.name_en ?? ''} ${sec?.name ?? ''}`.trim(),
        block: one(one(bed?.room)?.block)?.name ?? '',
        bed: bed?.bed_code ?? '',
        since: s.starts_on,
        owes: balance.get(s.enrolment_id) ?? 0,
      };
    })
    .sort((a, b) => a.bed.localeCompare(b.bed, undefined, { numeric: true }));
  const shown = owingOnly ? residents.filter((r) => r.owes > 0) : residents;

  const blocks = new Map<string, { name: string; beds: number; occupied: number }>();
  for (const b of beds ?? []) {
    const block = one(one(b.room)?.block);
    if (!block) continue;
    const e = blocks.get(block.id) ?? { name: block.name, beds: 0, occupied: 0 };
    e.beds++;
    if (b.status === 'occupied') e.occupied++;
    blocks.set(block.id, e);
  }
  const occ = [...blocks.values()].sort((a, b) => a.name.localeCompare(b.name));
  const totalBeds = occ.reduce((t, b) => t + b.beds, 0);
  const totalOcc = occ.reduce((t, b) => t + b.occupied, 0);

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Hostel reports</h1>
          <p className="text-sm text-muted-foreground">Who lives where, how full each block is, and what residents owe.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-4">
        <Stat label="Residents" value={residents.length} />
        <Stat label="Beds" value={totalBeds} />
        <Stat label="Occupancy" value={totalBeds ? `${Math.round((totalOcc / totalBeds) * 100)}%` : '—'} hint={`${totalOcc} of ${totalBeds} beds`} />
        <Stat label="Residents owing" value={residents.filter((r) => r.owes > 0).length} tone={residents.some((r) => r.owes > 0) ? 'warning' : 'default'} />
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Occupancy by block</h2>
        {occ.length === 0 ? (
          <p className="text-sm text-muted-foreground">No hostel blocks yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Block</TableHead>
                <TableHead className="text-right">Beds</TableHead>
                <TableHead className="text-right">Occupied</TableHead>
                <TableHead className="text-right">Free</TableHead>
                <TableHead className="text-right">Occupancy</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {occ.map((b) => (
                <TableRow key={b.name} data-testid="occupancy-row">
                  <TableCell className="font-medium">{b.name}</TableCell>
                  <TableCell className="tabular text-right">{b.beds}</TableCell>
                  <TableCell className="tabular text-right">{b.occupied}</TableCell>
                  <TableCell className="tabular text-right">{b.beds - b.occupied}</TableCell>
                  <TableCell className="tabular text-right">{b.beds ? `${Math.round((b.occupied / b.beds) * 100)}%` : ''}</TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell>Total</TableCell>
                <TableCell className="tabular text-right">{totalBeds}</TableCell>
                <TableCell className="tabular text-right">{totalOcc}</TableCell>
                <TableCell className="tabular text-right">{totalBeds - totalOcc}</TableCell>
                <TableCell />
              </TableRow>
            </TableFooter>
          </Table>
        )}
      </section>

      <section className="space-y-2">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-lg font-semibold">Resident register and dues</h2>
          <form method="get" className="flex items-center gap-2 text-sm print:hidden">
            <label className="flex items-center gap-2">
              <input type="checkbox" name="owing" value="1" defaultChecked={owingOnly} /> Only residents who owe
            </label>
            <button type="submit" className="h-8 rounded-md border px-3">
              Show
            </button>
          </form>
        </div>
        {shown.length === 0 ? (
          <p className="text-sm text-muted-foreground">{residents.length === 0 ? 'No residents yet.' : 'Nobody owes anything.'}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-10">#</TableHead>
                <TableHead>Resident</TableHead>
                <TableHead>GR no.</TableHead>
                <TableHead>Class</TableHead>
                <TableHead>Block</TableHead>
                <TableHead>Bed</TableHead>
                <TableHead>Since</TableHead>
                <TableHead className="text-right">Fee balance</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((r, i) => (
                <TableRow key={r.id} data-testid="resident-row">
                  <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                  <TableCell className="font-medium">{r.name}</TableCell>
                  <TableCell className="tabular font-mono">{r.gr}</TableCell>
                  <TableCell>{r.cls}</TableCell>
                  <TableCell>{r.block}</TableCell>
                  <TableCell className="tabular">{r.bed}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(r.since)}</TableCell>
                  <TableCell className={`tabular text-right ${r.owes > 0 ? 'font-medium text-destructive' : ''}`}>{pkr(r.owes)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>
    </div>
  );
}
