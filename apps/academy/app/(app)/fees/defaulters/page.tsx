import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { formatPkrCompact } from '@/lib/format-money';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { ExportDefaultersButton } from './export-button';

const PAGE = 50;
const BUCKETS = ['1-30', '31-60', '61-90', '90+'] as const;
type Bucket = (typeof BUCKETS)[number];
type SearchParams = { bucket?: string; class?: string; hardship?: string; offset?: string };

export default async function DefaultersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const bucket = BUCKETS.find((b) => b === sp.bucket) as Bucket | undefined;
  const includeHardship = sp.hardship === 'show';
  const offset = Math.max(0, Number(sp.offset ?? 0) || 0);
  const supabase = await supabaseServer();

  let q = supabase
    .from('v_fee_defaulter')
    .select('enrolment_id, gr_number, student_name, guardian_phone, outstanding_paisa, oldest_due_date, days_overdue, bucket, has_active_concession, refreshed_at, class_id', { count: 'exact' })
    .order('days_overdue', { ascending: false })
    .range(offset, offset + PAGE - 1);
  if (bucket) q = q.eq('bucket', bucket);
  if (sp.class) q = q.eq('class_id', sp.class);
  if (!includeHardship) q = q.eq('has_active_concession', false);

  const [{ data: rows, count }, { data: totals }, { data: classes }] = await Promise.all([
    q,
    supabase.rpc('fn_defaulter_bucket_totals', { p_include_hardship: includeHardship }),
    supabase.from('class_level').select('id, name_en').order('ordinal'),
  ]);

  const receivable = (totals ?? []).reduce((s, t) => s + Number(t.outstanding_paisa), 0);
  const refreshed = rows?.[0]?.refreshed_at ?? null;
  const qs = (extra: Record<string, string | undefined>) => {
    const p = new URLSearchParams({ ...(bucket ? { bucket } : {}), ...(sp.class ? { class: sp.class } : {}), ...(includeHardship ? { hardship: 'show' } : {}), ...extra } as Record<string, string>);
    for (const [k, v] of [...p.entries()]) if (!v) p.delete(k);
    return p.toString();
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee defaulters</h1>
        <p className="text-sm text-muted-foreground">
          FR-K25 — days overdue are counted from the oldest unpaid challan. Rebuilt nightly{refreshed ? `; as of ${new Date(refreshed).toLocaleString()}` : ''}. Students on an approved hardship concession are hidden unless you ask.
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-5" data-testid="bucket-totals">
        {(totals ?? []).map((t) => (
          <Link key={t.bucket} href={`?${qs({ bucket: t.bucket, offset: undefined })}`}>
            <Card className={t.bucket === bucket ? 'border-primary' : ''}>
              <CardHeader className="p-3 pb-1">
                <CardDescription>{t.bucket} days</CardDescription>
                <CardTitle className="text-lg">{formatPkrCompact(Number(t.outstanding_paisa))}</CardTitle>
                <p className="text-xs text-muted-foreground">{t.students} students</p>
              </CardHeader>
            </Card>
          </Link>
        ))}
        <Card>
          <CardHeader className="p-3 pb-1">
            <CardDescription>Total receivable</CardDescription>
            <CardTitle className="text-lg" data-testid="receivable">
              {formatPkrCompact(receivable)}
            </CardTitle>
          </CardHeader>
        </Card>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span>Class</span>
          <select name="class" defaultValue={sp.class ?? ''} className="h-9 rounded-md border bg-background px-2">
            <option value="">All</option>
            {(classes ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name_en}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span>Bucket</span>
          <select name="bucket" defaultValue={bucket ?? ''} className="h-9 rounded-md border bg-background px-2">
            <option value="">All</option>
            {BUCKETS.map((b) => (
              <option key={b}>{b}</option>
            ))}
          </select>
        </label>
        <label className="flex items-center gap-2">
          <input type="checkbox" name="hardship" value="show" defaultChecked={includeHardship} /> Include hardship
        </label>
        <button className="h-9 rounded-md border px-3 hover:bg-accent">Apply</button>
      </form>

      {(rows ?? []).length === 0 ? (
        <EmptyState title="No defaulters match" description="Nothing is overdue for this filter." />
      ) : (
        <div className="overflow-x-auto rounded-md border" data-testid="defaulter-table">
          <table className="w-full min-w-[760px] text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="p-2">GR</th>
                <th className="p-2">Student</th>
                <th className="p-2">Outstanding</th>
                <th className="p-2">Oldest due</th>
                <th className="p-2">Days</th>
                <th className="p-2">Bucket</th>
                <th className="p-2">Guardian</th>
              </tr>
            </thead>
            <tbody>
              {(rows ?? []).map((r) => (
                <tr key={r.enrolment_id} className="border-t" data-testid="defaulter-row">
                  <td className="p-2">{r.gr_number}</td>
                  <td className="p-2">
                    {r.student_name} {r.has_active_concession && <Badge variant="info">hardship concession</Badge>}
                  </td>
                  <td className="p-2">{formatPkrCompact(Number(r.outstanding_paisa))}</td>
                  <td className="p-2">{r.oldest_due_date}</td>
                  <td className="p-2">{r.days_overdue}</td>
                  <td className="p-2">{r.bucket}</td>
                  <td className="p-2">{r.guardian_phone ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="flex items-center justify-between text-sm">
        <span className="text-muted-foreground">
          Showing {offset + 1}–{offset + (rows ?? []).length} of {count ?? 0}
        </span>
        <span className="flex gap-3">
          {offset > 0 && <Link href={`?${qs({ offset: String(Math.max(0, offset - PAGE)) })}`}>Previous</Link>}
          {offset + PAGE < (count ?? 0) && <Link href={`?${qs({ offset: String(offset + PAGE) })}`}>Next</Link>}
        </span>
      </div>

      <ExportDefaultersButton classId={sp.class || undefined} bucket={bucket} hideHardship={!includeHardship} />
    </div>
  );
}
