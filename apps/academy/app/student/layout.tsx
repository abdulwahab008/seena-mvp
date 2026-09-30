import Link from 'next/link';
import { requireSession } from '@/lib/auth/require-session';
import { supabaseServer } from '@/lib/supabase/server';
import { ForcePasswordChange } from './force-password-change';
import { Button } from '@/components/ui/button';
import { Calendar, BookOpen, Clock, Award, LogOut, GraduationCap } from 'lucide-react';

const STUDENT_NAV_LINKS = [
  { href: '/student/timetable', label: 'Timetable', icon: Clock },
  { href: '/student/homework', label: 'Homework', icon: BookOpen },
  { href: '/student/attendance', label: 'Attendance', icon: Calendar },
  { href: '/student/results', label: 'Results', icon: Award },
];

export default async function StudentPortalLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const sessionUser = await requireSession();
  const supabase = await supabaseServer();

  // Query student portal account linked to current user
  const { data: portalAccount } = await supabase
    .from('student_portal_account')
    .select('id, status, must_change_password, student:student_id(id, name_en, gr_number)')
    .eq('user_id', sessionUser.id)
    .maybeSingle();

  if (!portalAccount || portalAccount.status !== 'active') {
    return (
      <div className="flex min-h-[80vh] items-center justify-center p-6">
        <div className="max-w-md text-center">
          <GraduationCap className="mx-auto h-12 w-12 text-muted-foreground mb-4" />
          <h1 className="text-xl font-bold">Portal Access Unavailable</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Your student portal account is inactive or has been deprovisioned. Please contact your school administrator or campus office.
          </p>
        </div>
      </div>
    );
  }

  const student = Array.isArray(portalAccount.student)
    ? portalAccount.student[0]
    : portalAccount.student;

  // AC 4: First login forces password change before any screen renders
  if (portalAccount.must_change_password) {
    return <ForcePasswordChange studentName={student?.name_en} />;
  }

  return (
    <div className="min-h-screen bg-background">
      <header className="border-b bg-card">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary">
              <GraduationCap className="h-6 w-6" />
            </div>
            <div>
              <h1 className="text-base font-semibold leading-none">Student Portal</h1>
              <p className="mt-1 text-xs text-muted-foreground">
                {student?.name_en} · GR: {student?.gr_number}
              </p>
            </div>
          </div>

          <form action="/api/auth/sign-out" method="POST">
            <Button variant="ghost" size="sm" type="submit" className="gap-2 text-muted-foreground hover:text-foreground">
              <LogOut className="h-4 w-4" />
              Sign Out
            </Button>
          </form>
        </div>

        <div className="mx-auto max-w-5xl px-6">
          <nav className="flex gap-6 text-sm">
            {STUDENT_NAV_LINKS.map((link) => {
              const Icon = link.icon;
              return (
                <Link
                  key={link.href}
                  href={link.href}
                  className="flex items-center gap-2 border-b-2 border-transparent py-3 font-medium text-muted-foreground transition-colors hover:border-primary hover:text-foreground"
                >
                  <Icon className="h-4 w-4" />
                  {link.label}
                </Link>
              );
            })}
          </nav>
        </div>
      </header>

      <main className="mx-auto max-w-5xl p-6">
        {children}
      </main>
    </div>
  );
}
