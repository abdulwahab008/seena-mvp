import Link from 'next/link';
import {
  ArrowRight,
  BadgeCheck,
  CalendarClock,
  ClipboardList,
  GraduationCap,
  LayoutGrid,
  UserCog,
  Users,
  Wallet,
} from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { PageHeader, Stat } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';

export const dynamic = 'force-dynamic';

function formatPkr(paisa: number) {
  return new Intl.NumberFormat('en-PK', {
    style: 'currency',
    currency: 'PKR',
    maximumFractionDigits: 0,
  }).format(paisa / 100);
}

const QUICK_LINKS = [
  { href: '/attendance/register', label: 'Mark attendance', icon: BadgeCheck },
  { href: '/fees/counter', label: 'Collect fees', icon: Wallet },
  { href: '/students', label: 'Find a student', icon: Users },
  { href: '/exams/marks', label: 'Enter marks', icon: GraduationCap },
];

export default async function DashboardPage() {
  const supabase = await supabaseServer();
  const today = new Date().toISOString().slice(0, 10);

  // RLS scopes every one of these to the caller's tenant and campuses, so the
  // dashboard needs no tenant filter of its own.
  const [students, staff, sections, attendanceToday, unpaid, recentStudents] = await Promise.all([
    supabase.from('student').select('id', { count: 'exact', head: true }).eq('status', 'active'),
    supabase.from('staff').select('id', { count: 'exact', head: true }).eq('employment_status', 'active'),
    supabase.from('class_section').select('id', { count: 'exact', head: true }).eq('is_active', true),
    supabase.from('attendance_day').select('status').eq('attendance_date', today),
    supabase.from('fee_challan').select('net_paisa, status').neq('status', 'paid').is('deleted_at', null),
    supabase
      .from('student')
      .select('id, name_en, gr_number, created_at')
      .is('deleted_at', null)
      .order('created_at', { ascending: false })
      .limit(6),
  ]);

  const marks = attendanceToday.data ?? [];
  const presentish = marks.filter((m) => ['present', 'late', 'half_day'].includes(m.status)).length;
  const attendancePct = marks.length > 0 ? Math.round((presentish / marks.length) * 1000) / 10 : null;

  const outstandingPaisa = (unpaid.data ?? []).reduce((sum, c) => sum + (c.net_paisa ?? 0), 0);
  const unpaidCount = unpaid.data?.length ?? 0;

  const attendanceTone = attendancePct === null ? 'default' : attendancePct >= 90 ? 'success' : attendancePct >= 75 ? 'warning' : 'destructive';

  return (
    <>
      <PageHeader
        title="Dashboard"
        description="Today at a glance — enrolment, staffing, attendance and outstanding fees."
      />

      <section aria-label="Key figures" className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="Active students" value={students.count ?? 0} icon={Users} hint="Currently enrolled" />
        <Stat label="Active staff" value={staff.count ?? 0} icon={UserCog} hint="On the payroll" />
        <Stat label="Sections" value={sections.count ?? 0} icon={LayoutGrid} hint="Across all campuses" />
        <Stat
          label="Attendance today"
          value={attendancePct === null ? '—' : `${attendancePct}%`}
          tone={attendanceTone}
          icon={BadgeCheck}
          hint={marks.length === 0 ? 'No registers marked yet' : `${presentish} of ${marks.length} marked present`}
        />
      </section>

      <div className="mt-6 grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader className="flex-row items-center justify-between space-y-0 pb-3">
            <CardTitle className="text-base">Outstanding fees</CardTitle>
            <Button asChild variant="ghost" size="sm">
              <Link href="/fees/challans">
                View challans
                <ArrowRight className="ml-1.5 h-3.5 w-3.5" />
              </Link>
            </Button>
          </CardHeader>
          <CardContent>
            {unpaidCount === 0 ? (
              <EmptyState
                icon={Wallet}
                title="Nothing outstanding"
                description="Every generated challan has been settled."
                className="border-0 py-8"
              />
            ) : (
              <div className="flex flex-wrap items-end justify-between gap-4">
                <div>
                  <p className="tabular text-3xl font-semibold tracking-tight text-foreground">
                    {formatPkr(outstandingPaisa)}
                  </p>
                  <p className="mt-1 text-sm text-muted-foreground">
                    across <span className="tabular font-medium text-foreground">{unpaidCount}</span> unpaid{' '}
                    {unpaidCount === 1 ? 'challan' : 'challans'}
                  </p>
                </div>
                <Button asChild size="sm">
                  <Link href="/fees/counter">Open cash counter</Link>
                </Button>
              </div>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Quick actions</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2">
            {QUICK_LINKS.map(({ href, label, icon: Icon }) => (
              <Link
                key={href}
                href={href}
                className="flex items-center gap-3 rounded-md border px-3 py-2.5 text-sm transition-colors hover:border-primary/40 hover:bg-primary-muted"
              >
                <Icon className="h-4 w-4 shrink-0 text-primary" aria-hidden />
                <span className="flex-1">{label}</span>
                <ArrowRight className="h-3.5 w-3.5 shrink-0 text-muted-foreground" aria-hidden />
              </Link>
            ))}
          </CardContent>
        </Card>
      </div>

      <Card className="mt-4">
        <CardHeader className="flex-row items-center justify-between space-y-0 pb-3">
          <CardTitle className="text-base">Recently added students</CardTitle>
          <Button asChild variant="ghost" size="sm">
            <Link href="/students">
              All students
              <ArrowRight className="ml-1.5 h-3.5 w-3.5" />
            </Link>
          </Button>
        </CardHeader>
        <CardContent>
          {(recentStudents.data?.length ?? 0) === 0 ? (
            <EmptyState
              icon={ClipboardList}
              title="No students yet"
              description="Admit your first student, or bring your existing register in with a bulk import."
              className="border-0 py-8"
              action={
                <div className="flex flex-wrap justify-center gap-2">
                  <Button asChild size="sm">
                    <Link href="/students/import">Bulk import</Link>
                  </Button>
                  <Button asChild size="sm" variant="outline">
                    <Link href="/admissions/enquiries">Admissions</Link>
                  </Button>
                </div>
              }
            />
          ) : (
            <ul className="divide-y">
              {recentStudents.data!.map((s) => (
                <li key={s.id}>
                  <Link
                    href={`/students/${s.id}`}
                    className="-mx-2 flex items-center gap-3 rounded-md px-2 py-2.5 transition-colors hover:bg-muted"
                  >
                    <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-muted text-xs font-semibold text-muted-foreground">
                      {(s.name_en ?? '?').slice(0, 1).toUpperCase()}
                    </span>
                    <span className="min-w-0 flex-1 truncate text-sm font-medium">{s.name_en}</span>
                    <Badge variant="outline" className="tabular shrink-0 font-mono">
                      {s.gr_number}
                    </Badge>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      <p className="mt-6 flex items-center gap-1.5 text-xs text-muted-foreground">
        <CalendarClock className="h-3.5 w-3.5" aria-hidden />
        Figures reflect the campuses your account can see.
      </p>
    </>
  );
}
