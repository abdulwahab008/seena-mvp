import Link from 'next/link';
import { notFound } from 'next/navigation';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { ActionButton } from '@/components/spec-form';
import { renumberAlphabetically } from './actions';
import { RollInput } from './roll-input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;

export default async function ClassListPage({ searchParams }: { searchParams: Promise<{ section?: string }> }) {
  const section = z.string().uuid().safeParse((await searchParams).section);
  if (!section.success) notFound();
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const [{ data: sec }, { data: rows }, { data: appUser }] = await Promise.all([
    supabase.from('class_section').select('name, session_id, class_level:class_level_id(name_en)').eq('id', section.data).maybeSingle(),
    supabase
      .from('enrolment')
      .select('id, roll_no, student:student_id!inner(id, name_en, father_name_en, gr_number, gender, dob)')
      .eq('section_id', section.data)
      .eq('status', 'active')
      .is('deleted_at', null),
    supabase.from('app_user').select('app_role').eq('user_id', user!.id).single(),
  ]);
  // Mirrors fn_set_roll_no()'s roles.
  const canEditRolls = ['super_admin', 'owner', 'principal', 'class_teacher'].includes(appUser?.app_role ?? '');
  if (!sec) notFound();
  const students = (rows ?? [])
    .map((r) => ({ id: r.id, roll: r.roll_no, s: one(r.student)! }))
    .sort((a, b) => (a.roll ?? 9999) - (b.roll ?? 9999) || a.s.name_en.localeCompare(b.s.name_en));

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">
            Class list: {one(sec.class_level)?.name_en} {sec.name}
          </h1>
          <p className="text-sm text-muted-foreground">{students.length} students</p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/academic-setup/class-reports" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            Back
          </Link>
          {canEditRolls && students.length > 0 && (
            <ActionButton
              label="Renumber A to Z"
              testId="renumber-rolls"
              confirm="Give every student in this section a new roll number in alphabetical order?"
              action={renumberAlphabetically}
              args={[section.data, sec.session_id]}
            />
          )}
          <PrintButton />
        </div>
      </div>
      {students.length === 0 ? (
        <p className="text-sm text-muted-foreground">No students in this section.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>Roll no.</TableHead>
              <TableHead>GR no.</TableHead>
              <TableHead>Name</TableHead>
              <TableHead>Father name</TableHead>
              <TableHead>Gender</TableHead>
              <TableHead>Date of birth</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {students.map(({ id, roll, s }, i) => (
              <TableRow key={id} data-testid="class-list-row">
                <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                <TableCell className="tabular">{canEditRolls ? <RollInput key={`${id}-${roll}`} enrolmentId={id} roll={roll} name={s.name_en} /> : (roll ?? '')}</TableCell>
                <TableCell className="tabular font-mono">{s.gr_number}</TableCell>
                <TableCell className="font-medium">{s.name_en}</TableCell>
                <TableCell>{s.father_name_en ?? ''}</TableCell>
                <TableCell className="capitalize">{s.gender}</TableCell>
                <TableCell>{formatDatePk(s.dob)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
