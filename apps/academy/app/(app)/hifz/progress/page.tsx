import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { formatDatePk, todayPk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const TYPES = { sabaq: 'Sabaq', sabqi: 'Sabqi', manzil: 'Manzil' } as const;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

export default async function HifzProgressPage({ searchParams }: { searchParams: Promise<{ halqa?: string; type?: string; from?: string; to?: string; q?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const f = await searchParams;
  const to = f.to && DATE.test(f.to) ? f.to : todayPk();
  const from = f.from && DATE.test(f.from) ? f.from : new Date(Date.parse(to) - 6 * 86_400_000).toISOString().slice(0, 10);

  const supabase = await supabaseServer();
  let query = supabase
    .from('hifz_lesson')
    .select('id, lesson_date, lesson_type, para_from, para_to, portion, lines, mistakes, tajweed_mistakes, grade, halqa:halqa_id(name), student:student_id!inner(id, name_en, gr_number)')
    .gte('lesson_date', from)
    .lte('lesson_date', to)
    .order('lesson_date', { ascending: false })
    .limit(500);
  if (f.halqa) query = query.eq('halqa_id', f.halqa);
  if (f.type && f.type in TYPES) query = query.eq('lesson_type', f.type);
  if (f.q?.trim()) query = query.ilike('student.name_en', `%${f.q.trim().replace(/[\\%_]/g, (c) => `\\${c}`)}%`);
  const [{ data: lessons, error }, { data: halqas }] = await Promise.all([query, supabase.from('halqa').select('id, name').eq('is_active', true).order('name')]);
  const select = 'h-9 rounded-md border bg-background px-2';

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Hifz progress register</h1>
          <p className="text-sm text-muted-foreground">
            Every sabaq, sabqi and manzil recorded from {formatDatePk(from)} to {formatDatePk(to)}.
          </p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/hifz" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            Halqas
          </Link>
          <PrintButton />
        </div>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 rounded-lg border p-4 text-sm print:hidden">
        <select name="halqa" defaultValue={f.halqa ?? ''} aria-label="Halqa" className={select}>
          <option value="">All halqas</option>
          {(halqas ?? []).map((h) => (
            <option key={h.id} value={h.id}>
              {h.name}
            </option>
          ))}
        </select>
        <select name="type" defaultValue={f.type ?? ''} aria-label="Lesson type" className={select}>
          <option value="">All lesson types</option>
          {Object.entries(TYPES).map(([k, label]) => (
            <option key={k} value={k}>
              {label}
            </option>
          ))}
        </select>
        <input type="date" name="from" defaultValue={from} aria-label="From" className={select} />
        <input type="date" name="to" defaultValue={to} aria-label="To" className={select} />
        <input name="q" defaultValue={f.q ?? ''} placeholder="Student name" aria-label="Student name" className="h-9 min-w-40 flex-1 rounded-md border bg-background px-3" />
        <Button type="submit" size="sm">
          Search
        </Button>
      </form>
      {error ? (
        <p className="text-sm text-destructive">Could not load lessons. Try again.</p>
      ) : (lessons ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No lessons recorded for these filters.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Date</TableHead>
              <TableHead>Student</TableHead>
              <TableHead>Halqa</TableHead>
              <TableHead>Lesson</TableHead>
              <TableHead>Portion</TableHead>
              <TableHead className="text-right">Lines</TableHead>
              <TableHead>Grade</TableHead>
              <TableHead className="text-right">Mistakes</TableHead>
              <TableHead className="text-right">Tajweed</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(lessons ?? []).map((l, i) => {
              const s = one(l.student);
              const paras = l.para_from ? (l.para_to && l.para_to !== l.para_from ? `Para ${l.para_from}–${l.para_to}` : `Para ${l.para_from}`) : '';
              return (
                <TableRow key={l.id} data-testid="hifz-lesson-row">
                  <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(l.lesson_date)}</TableCell>
                  <TableCell>
                    {s && (
                      <Link href={`/students/${s.id}`} className="font-medium hover:underline">
                        {s.name_en}
                      </Link>
                    )}
                  </TableCell>
                  <TableCell>{one(l.halqa)?.name ?? ''}</TableCell>
                  <TableCell>{TYPES[l.lesson_type as keyof typeof TYPES] ?? l.lesson_type}</TableCell>
                  <TableCell>{[paras, l.portion].filter(Boolean).join(', ')}</TableCell>
                  <TableCell className="tabular text-right">{l.lines ?? ''}</TableCell>
                  <TableCell className="capitalize">{l.grade ?? ''}</TableCell>
                  <TableCell className="tabular text-right">{l.mistakes}</TableCell>
                  <TableCell className="tabular text-right">{l.tajweed_mistakes}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
