import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Button } from '@/components/ui/button';
import { NewStudentForm } from './new-student-form';
import { StudentList, type StudentRow } from './student-list';
import { getCurrentActor } from '@/lib/hr/current-role';

export const dynamic = 'force-dynamic';

// Who create_student() lets admit; everyone else sees the roster only.
const ADMITTING_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer'];
const PAGE_SIZE = 50;
const SEARCH_BY = { name: 'Student name', father: 'Father name', gr: 'GR number', phone: 'Parent phone', cnic: 'Parent CNIC' } as const;
type SearchBy = keyof typeof SEARCH_BY;

type Filters = { q?: string; by?: string; cls?: string; gender?: string; category?: string; status?: string; page?: string };

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
const likeEscape = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

export default async function StudentsPage({ searchParams }: { searchParams: Promise<Filters> }) {
  const f = await searchParams;
  const by: SearchBy = f.by && f.by in SEARCH_BY ? (f.by as SearchBy) : 'name';
  const status = f.status ?? 'active';
  const page = Math.max(1, Number(f.page) || 1);
  const supabase = await supabaseServer();
  const actor = await getCurrentActor();

  // FR-A15 AC1: an explicit deleted_at filter, not just RLS — an Owner/Super Admin
  // also matches student_recycle_bin_read (the two SELECT policies are OR'd), so an
  // unfiltered query would silently readmit soft-deleted students into this roster.
  let query = supabase
    .from('student')
    .select(
      'id, name_en, father_name_en, gr_number, status, category:student_lookup!student_category_id_fkey(name), enrolment(status, class_level_id, section_id, section:section_id(name), class_level:class_level_id(name_en)), student_guardian(is_primary, guardian(phone_e164, phone_last10, cnic_digits))',
      { count: 'exact' },
    )
    .is('deleted_at', null)
    .eq('enrolment.status', 'active');

  if (status !== 'all') query = query.eq('status', status as 'active');
  if (f.gender) query = query.eq('gender', f.gender as 'male');
  if (f.category) query = query.eq('category_id', f.category);
  if (f.cls?.startsWith('c:')) query = query.eq('enrolment.class_level_id', f.cls.slice(2)).not('enrolment', 'is', null);
  if (f.cls?.startsWith('s:')) query = query.eq('enrolment.section_id', f.cls.slice(2)).not('enrolment', 'is', null);

  const q = f.q?.trim();
  if (q) {
    const digits = q.replace(/\D/g, '');
    if (by === 'name') query = query.ilike('name_en', `%${likeEscape(q)}%`);
    if (by === 'father') query = query.ilike('father_name_en', `%${likeEscape(q)}%`);
    if (by === 'gr') query = query.ilike('gr_number', `%${likeEscape(q)}%`);
    if (by === 'phone') query = query.eq('student_guardian.guardian.phone_last10', digits.slice(-10)).not('student_guardian.guardian', 'is', null).not('student_guardian', 'is', null);
    if (by === 'cnic') query = query.eq('student_guardian.guardian.cnic_digits', digits).not('student_guardian.guardian', 'is', null).not('student_guardian', 'is', null);
  }

  const from = (page - 1) * PAGE_SIZE;
  const [{ data: campuses }, { data, count }, { data: sections }, { data: categories }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    query.order('gr_number').range(from, from + PAGE_SIZE - 1),
    supabase.from('class_section').select('id, name, class_level:class_level_id(id, name_en, ordinal)').eq('is_active', true),
    supabase.from('student_lookup').select('id, name').eq('kind', 'category').eq('is_active', true).order('name'),
  ]);

  const students: StudentRow[] = (data ?? []).map((s) => {
    const enrolment = one(s.enrolment);
    const guardians = s.student_guardian ?? [];
    const primary = guardians.find((g) => g.is_primary) ?? guardians[0];
    return {
      id: s.id,
      name_en: s.name_en,
      father_name_en: s.father_name_en,
      gr_number: s.gr_number,
      status: s.status,
      className: enrolment ? `${one(enrolment.class_level)?.name_en ?? ''} ${one(enrolment.section)?.name ?? ''}`.trim() : '',
      phone: one(primary?.guardian)?.phone_e164 ?? null,
      category: one(s.category)?.name ?? null,
    };
  });

  const classes = new Map<string, { name: string; ordinal: number; sections: { id: string; name: string }[] }>();
  for (const s of sections ?? []) {
    const cl = one(s.class_level);
    if (!cl) continue;
    const entry = classes.get(cl.id) ?? { name: cl.name_en, ordinal: cl.ordinal, sections: [] };
    entry.sections.push({ id: s.id, name: s.name });
    classes.set(cl.id, entry);
  }
  const classOptions = [...classes.entries()].sort((a, b) => a[1].ordinal - b[1].ordinal);

  const total = count ?? 0;
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const hrefFor = (p: number) => `/students?${new URLSearchParams({ ...Object.fromEntries(Object.entries(f).filter((e): e is [string, string] => Boolean(e[1]))), page: String(p) })}`;
  const select = 'h-9 rounded-md border bg-background px-2';

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Students</h1>
        <p className="text-sm text-muted-foreground">Student profiles, each with a permanent GR number from admission.</p>
      </div>
      {actor && ADMITTING_ROLES.includes(actor.role) && <NewStudentForm campuses={campuses ?? []} />}

      <form method="get" className="space-y-3 rounded-lg border p-4 text-sm print:hidden" data-testid="student-filters">
        <div className="flex flex-wrap items-end gap-2">
          <select name="by" defaultValue={by} aria-label="Search by" className={select}>
            {Object.entries(SEARCH_BY).map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
          <input name="q" defaultValue={q ?? ''} placeholder="Search" aria-label="Search text" className="h-9 min-w-56 flex-1 rounded-md border bg-background px-3" />
          <Button type="submit" size="sm">
            Search
          </Button>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <select name="cls" defaultValue={f.cls ?? ''} aria-label="Class" className={select}>
            <option value="">All classes</option>
            {classOptions.map(([id, c]) => (
              <optgroup key={id} label={c.name}>
                <option value={`c:${id}`}>{c.name}, all sections</option>
                {c.sections
                  .sort((a, b) => a.name.localeCompare(b.name))
                  .map((s) => (
                    <option key={s.id} value={`s:${s.id}`}>
                      {c.name} {s.name}
                    </option>
                  ))}
              </optgroup>
            ))}
          </select>
          <select name="gender" defaultValue={f.gender ?? ''} aria-label="Gender" className={select}>
            <option value="">All genders</option>
            <option value="male">Male</option>
            <option value="female">Female</option>
          </select>
          <select name="category" defaultValue={f.category ?? ''} aria-label="Category" className={select}>
            <option value="">All categories</option>
            {(categories ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
          <select name="status" defaultValue={status} aria-label="Status" className={select}>
            <option value="active">Active</option>
            <option value="inactive">Inactive</option>
            <option value="left">Left</option>
            <option value="all">All statuses</option>
          </select>
          {Object.values(f).some(Boolean) && (
            <Link href="/students" className="h-9 px-2 leading-9 text-muted-foreground underline">
              Clear
            </Link>
          )}
        </div>
        <p className="text-muted-foreground">
          There are <span className="tabular font-medium text-foreground">{total}</span> students matching.
        </p>
      </form>

      <StudentList students={students} offset={from} />

      {pages > 1 && (
        <nav className="flex items-center justify-between text-sm print:hidden" aria-label="Pages">
          <span className="text-muted-foreground">
            Page {page} of {pages}
          </span>
          <div className="flex gap-2">
            {page > 1 && (
              <Button asChild size="sm" variant="outline">
                <Link href={hrefFor(page - 1)}>Previous</Link>
              </Button>
            )}
            {page < pages && (
              <Button asChild size="sm" variant="outline">
                <Link href={hrefFor(page + 1)}>Next</Link>
              </Button>
            )}
          </div>
        </nav>
      )}
    </div>
  );
}
