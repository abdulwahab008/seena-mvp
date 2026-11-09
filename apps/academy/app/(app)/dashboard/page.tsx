import Link from 'next/link';
import {
  ArrowRight,
  BadgeCheck,
  BookOpen,
  Bus,
  Cake,
  CalendarClock,
  ClipboardList,
  GraduationCap,
  HandCoins,
  Home,
  LayoutGrid,
  MessageSquare,
  Receipt,
  UserCog,
  Users,
  Wallet,
} from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { PageHeader, Stat } from '@/components/ui/page-header';
import { canCollectFees, hasFeeAccess } from '@/lib/auth/fee-access';
import { Badge } from '@/components/ui/badge';
import { todayPk } from '@/lib/dates';
import { formatPkrCompact } from '@/lib/format-money';

type Summary = {
  students_active: number;
  students_total: number;
  staff_active: number;
  staff_total: number;
  families: number;
  classes: number;
  library_copies: number;
  transportees: number;
  birthdays_today: { id: string; name: string; gr: string }[];
  fee_month_paisa: number;
  fee_received_month_paisa: number;
  fee_received_today_paisa: number;
  fee_postings_today: number;
  receivable_paisa: number;
  bad_debt_month_paisa: number;
  bad_debt_total_paisa: number;
  salary_month_paisa: number;
  salary_last_month_paisa: number;
  salary_paid_month_paisa: number;
  salary_payable_paisa: number;
  expenses_today_paisa: number;
  expenses_month_paisa: number;
  shop_sales_month_paisa: number;
  messages_month: Partial<Record<'sms' | 'whatsapp' | 'email' | 'push', number>>;
  commitments_today: { name: string; gr: string; class: string | null; amount_paisa: number }[];
  receivable_by_month: { month: string; paisa: number }[];
};

const MONTH = new Intl.DateTimeFormat('en-PK', { month: 'long', year: 'numeric', timeZone: 'UTC' });

export const dynamic = 'force-dynamic';

const QUICK_LINKS = [
  { href: '/attendance/register', label: 'Mark attendance', icon: BadgeCheck },
  { href: '/fees/counter', label: 'Collect fees', icon: Wallet, collectorsOnly: true },
  { href: '/students', label: 'Find a student', icon: Users },
  { href: '/exams/marks', label: 'Enter marks', icon: GraduationCap },
];

export default async function DashboardPage() {
  const supabase = await supabaseServer();
  const today = todayPk();

  // Fee figures are for the people who handle fees (the database returns nothing to anyone else, which
  // would read as "nothing outstanding"), so the card and the cash-counter link are theirs alone.
  const { data: verified } = await supabase.auth.getClaims();
  const role = verified?.claims.app_role;
  const showFees = hasFeeAccess(role);
  const quickLinks = QUICK_LINKS.filter((l) => !l.collectorsOnly || canCollectFees(role));

  // RLS scopes every one of these to the caller's tenant and campuses, so the
  // dashboard needs no tenant filter of its own.
  const [summary, sections, attendanceToday, recentStudents] = await Promise.all([
    supabase.rpc('dashboard_summary'),
    supabase.from('class_section').select('id', { count: 'exact', head: true }).eq('is_active', true),
    supabase.from('attendance_day').select('status').eq('attendance_date', today),
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

  const sum = summary.data as Summary | null;
  const n = (v: number | undefined) => Number(v ?? 0);
  const receivedPct = n(sum?.fee_month_paisa) > 0 ? Math.round((n(sum?.fee_received_month_paisa) / n(sum?.fee_month_paisa)) * 100) : null;
  const cashIn = n(sum?.fee_received_month_paisa) + n(sum?.shop_sales_month_paisa);
  const cashOut = n(sum?.expenses_month_paisa) + n(sum?.salary_paid_month_paisa);
  const messages = sum?.messages_month ?? {};
  const yearStart = `${today.slice(0, 4)}-01-01`;

  const attendanceTone = attendancePct === null ? 'default' : attendancePct >= 90 ? 'success' : attendancePct >= 75 ? 'warning' : 'destructive';

  return (
    <>
      <PageHeader
        title="Dashboard"
        description={
          showFees
            ? 'Today at a glance — enrolment, fees, salaries, cash and messages.'
            : 'Today at a glance — enrolment, staffing and attendance.'
        }
      />

      <section aria-label="Key figures" className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat label="Active students" value={n(sum?.students_active)} icon={Users} hint={`Total students: ${n(sum?.students_total)}`} />
        <Stat label="Active staff" value={n(sum?.staff_active)} icon={UserCog} hint={`Total staff: ${n(sum?.staff_total)}`} />
        <Stat label="Families" value={n(sum?.families)} icon={Home} hint="Linked by father's CNIC" />
        <Stat
          label="Attendance today"
          value={attendancePct === null ? '—' : `${attendancePct}%`}
          tone={attendanceTone}
          icon={BadgeCheck}
          hint={marks.length === 0 ? 'No registers marked yet' : `${presentish} of ${marks.length} marked present`}
        />
      </section>

      <div className="mt-4 grid gap-4 xl:grid-cols-3">
        <div className="grid content-start gap-4 sm:grid-cols-2 xl:col-span-2 xl:grid-cols-3">
          {showFees && (
            <>
              <Stat label="Fee this month" value={formatPkrCompact(n(sum?.fee_month_paisa))} icon={Wallet} hint={`Bad debts this month: ${formatPkrCompact(n(sum?.bad_debt_month_paisa))}`} />
              <Stat
                label="Received this month"
                value={formatPkrCompact(n(sum?.fee_received_month_paisa))}
                tone="success"
                icon={HandCoins}
                hint={receivedPct === null ? 'No challans this month' : `${receivedPct}% of this month's fee`}
              />
              <Stat label="Receivable" value={formatPkrCompact(n(sum?.receivable_paisa))} tone="warning" icon={Receipt} hint={`Written off so far: ${formatPkrCompact(n(sum?.bad_debt_total_paisa))}`} />
              <Stat label="Salary this month" value={formatPkrCompact(n(sum?.salary_month_paisa))} icon={UserCog} hint={`Last month: ${formatPkrCompact(n(sum?.salary_last_month_paisa))}`} />
              <Stat label="Salary paid this month" value={formatPkrCompact(n(sum?.salary_paid_month_paisa))} icon={HandCoins} hint="Payroll runs marked paid" />
              <Stat label="Salary payable" value={formatPkrCompact(n(sum?.salary_payable_paisa))} tone="warning" icon={Wallet} hint="Approved, not yet paid" />
              <Stat label="Today's collection" value={formatPkrCompact(n(sum?.fee_received_today_paisa))} icon={HandCoins} hint={`${n(sum?.fee_postings_today)} payments today`} />
              <Stat label="Today's expenses" value={formatPkrCompact(n(sum?.expenses_today_paisa))} icon={Receipt} hint={`This month: ${formatPkrCompact(n(sum?.expenses_month_paisa))}`} />
            </>
          )}
          <Stat
            label="Birthdays today"
            value={sum?.birthdays_today.length ?? 0}
            icon={Cake}
            hint={(sum?.birthdays_today ?? []).slice(0, 3).map((b) => b.name).join(', ') || 'No birthdays today'}
          />
          <Stat label="Classes" value={n(sum?.classes)} icon={LayoutGrid} hint={`${sections.count ?? 0} sections`} />
          <Stat label="Library books" value={n(sum?.library_copies)} icon={BookOpen} hint="Copies on the shelves and issued" />
          <Stat label="Transport" value={n(sum?.transportees)} icon={Bus} hint="Students using school transport" />
        </div>

        <div className="grid content-start gap-4">
          <Card>
            <CardHeader className="pb-3">
              <CardTitle className="flex items-center gap-2 text-base">
                <MessageSquare className="h-4 w-4 text-primary" aria-hidden />
                Messages this month
              </CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-3 gap-2 text-center">
              {(['sms', 'whatsapp', 'email'] as const).map((c) => (
                <div key={c} className="rounded-md border p-2">
                  <p className="tabular text-xl font-semibold">{messages[c] ?? 0}</p>
                  <p className="text-xs text-muted-foreground">{c === 'sms' ? 'SMS' : c === 'whatsapp' ? 'WhatsApp' : 'Email'}</p>
                </div>
              ))}
            </CardContent>
          </Card>

          {showFees && (
            <Card>
              <CardHeader className="flex-row items-center justify-between space-y-0 pb-3">
                <CardTitle className="text-base">Today&apos;s fee commitments</CardTitle>
                <Button asChild variant="ghost" size="sm">
                  <Link href="/fees/commitments">
                    View all
                    <ArrowRight className="ml-1.5 h-3.5 w-3.5" />
                  </Link>
                </Button>
              </CardHeader>
              <CardContent>
                {(sum?.commitments_today.length ?? 0) === 0 ? (
                  <p className="text-sm text-muted-foreground">No promises fall due today.</p>
                ) : (
                  <ul className="divide-y text-sm">
                    {sum!.commitments_today.slice(0, 10).map((c, i) => (
                      <li key={`${c.gr}-${i}`} className="flex items-center justify-between gap-3 py-1.5">
                        <span className="min-w-0 truncate">
                          <span className="tabular text-muted-foreground">{c.gr}</span> {c.name}
                          {c.class ? <span className="text-muted-foreground"> · {c.class}</span> : null}
                        </span>
                        <span className="tabular shrink-0 font-medium">{formatPkrCompact(c.amount_paisa)}</span>
                      </li>
                    ))}
                  </ul>
                )}
                {(sum?.commitments_today.length ?? 0) > 0 && (
                  <p className="mt-2 text-xs text-muted-foreground">{sum!.commitments_today.length} promises due today</p>
                )}
              </CardContent>
            </Card>
          )}

          {showFees && (
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">Fee receivable by month</CardTitle>
              </CardHeader>
              <CardContent>
                {(sum?.receivable_by_month.length ?? 0) === 0 ? (
                  <p className="text-sm text-muted-foreground">No unpaid challans.</p>
                ) : (
                  <table className="w-full text-sm">
                    <tbody>
                      {sum!.receivable_by_month.map((r) => (
                        <tr key={r.month} className="border-b last:border-0">
                          <td className="py-1.5">{r.month < yearStart ? 'Previous balance' : MONTH.format(new Date(r.month))}</td>
                          <td className="tabular py-1.5 text-right font-medium">{formatPkrCompact(r.paisa)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
                <p className="mt-2 text-xs text-muted-foreground">Unpaid and part-paid challans by billing month.</p>
              </CardContent>
            </Card>
          )}
        </div>
      </div>

      {showFees && (
        <Card className="mt-4">
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Cash in / out this month</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-4 sm:grid-cols-3">
            <div>
              <p className="text-sm text-muted-foreground">Cash in</p>
              <p className="tabular text-2xl font-semibold text-success">{formatPkrCompact(cashIn)}</p>
              <p className="text-xs text-muted-foreground">
                Fees {formatPkrCompact(n(sum?.fee_received_month_paisa))} · Shop {formatPkrCompact(n(sum?.shop_sales_month_paisa))}
              </p>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">Cash out</p>
              <p className="tabular text-2xl font-semibold text-destructive">{formatPkrCompact(cashOut)}</p>
              <p className="text-xs text-muted-foreground">
                Expenses {formatPkrCompact(n(sum?.expenses_month_paisa))} · Salaries {formatPkrCompact(n(sum?.salary_paid_month_paisa))}
              </p>
            </div>
            <div>
              <p className="text-sm text-muted-foreground">Net</p>
              <p className="tabular text-2xl font-semibold">{formatPkrCompact(cashIn - cashOut)}</p>
              <p className="text-xs text-muted-foreground">Cash in minus cash out</p>
            </div>
          </CardContent>
        </Card>
      )}

      <div className="mt-4 grid gap-4 lg:grid-cols-3">
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-base">Quick actions</CardTitle>
          </CardHeader>
          <CardContent className="grid gap-2">
            {quickLinks.map(({ href, label, icon: Icon }) => (
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

      <Card className="lg:col-span-2">
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
      </div>

      <p className="mt-6 flex items-center gap-1.5 text-xs text-muted-foreground">
        <CalendarClock className="h-3.5 w-3.5" aria-hidden />
        Figures reflect the campuses your account can see.
      </p>
    </>
  );
}
