import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { DecideTransfer, TransferRequestForm } from './transfer-forms';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function TransfersPage() {
  const supabase = await supabaseServer();
  const [{ data: transfers }, { data: sections }, { data: campuses }] = await Promise.all([
    supabase
      .from('campus_transfer')
      .select('id, reason, status, decision_note, requested_at, to_campus_id, student(name_en, gr_number), from:campus!campus_transfer_from_campus_id_fkey(name), to:campus!campus_transfer_to_campus_id_fkey(name), section:class_section!campus_transfer_to_section_id_fkey(name)')
      .order('requested_at', { ascending: false })
      .limit(200),
    supabase.from('class_section').select('id, name, campus_id, class_level(name_en, ordinal)').eq('is_active', true),
    supabase.from('campus').select('id, name').eq('status', 'active').order('name'),
  ]);
  const campusName = new Map((campuses ?? []).map((c) => [c.id, c.name]));
  const sectionOptions = (sections ?? [])
    .map((s) => ({ s, level: one(s.class_level) }))
    .sort((a, b) => (campusName.get(a.s.campus_id) ?? '').localeCompare(campusName.get(b.s.campus_id) ?? '') || (a.level?.ordinal ?? 0) - (b.level?.ordinal ?? 0))
    .map(({ s, level }) => ({ id: s.id, label: `${campusName.get(s.campus_id) ?? ''} · ${level?.name_en ?? ''} ${s.name}` }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Campus transfers</h1>
        <p className="text-sm text-muted-foreground">
          Move a student to another campus of the school. The sending campus asks; the receiving campus&apos;s principal approves, and the student moves into the chosen section the same day. Challans already issued stay with the campus that issued them.
        </p>
      </div>
      {(campuses ?? []).length > 1 ? (
        <TransferRequestForm sections={sectionOptions} />
      ) : (
        <p className="text-sm text-muted-foreground">The school has one campus, so there is nowhere to transfer to.</p>
      )}
      {(transfers ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No transfers yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Student</TableHead>
              <TableHead>From</TableHead>
              <TableHead>To</TableHead>
              <TableHead>Requested</TableHead>
              <TableHead>Status</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(transfers ?? []).map((t) => {
              const s = one(t.student);
              return (
                <TableRow key={t.id} data-testid="transfer-row">
                  <TableCell>
                    {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                    <span className="block text-xs text-muted-foreground">{t.reason}</span>
                  </TableCell>
                  <TableCell>{one(t.from)?.name}</TableCell>
                  <TableCell>
                    {one(t.to)?.name} · {one(t.section)?.name}
                  </TableCell>
                  <TableCell>{formatDatePk(t.requested_at.slice(0, 10))}</TableCell>
                  <TableCell>
                    {t.status === 'requested' ? (
                      <DecideTransfer id={t.id} />
                    ) : (
                      <>
                        <Badge variant={t.status === 'approved' ? 'success' : 'outline'}>{t.status === 'approved' ? 'Transferred' : 'Declined'}</Badge>
                        {t.decision_note && <span className="block text-xs text-muted-foreground">{t.decision_note}</span>}
                      </>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
