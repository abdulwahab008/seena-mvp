import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { hasNoCampusAssigned } from '@/lib/campus-scope';
import { AppNav } from './nav';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user.id).single();

  // FR-A12 AC4: a campus-scoped role (i.e. not owner/super_admin, whose
  // access is role-based, not user_campus-based) with zero active
  // user_campus rows has nothing to see anywhere — every campus-scoped RLS
  // policy already returns zero rows for them (campus_id = any('{}') is
  // never true), so this is purely a friendlier "why is everything empty"
  // screen, not an additional access-control layer.
  if (appUser) {
    const { data: activeCampuses } = await supabase.from('user_campus').select('campus_id').eq('user_id', user.id).eq('is_active', true);

    if (hasNoCampusAssigned(appUser.app_role, activeCampuses?.length ?? 0)) {
      return (
        <div className="mx-auto flex min-h-screen max-w-md flex-col items-center justify-center gap-3 p-6 text-center">
          <h1 className="text-xl font-semibold" data-testid="no-campus-assigned-heading">
            No campus assigned
          </h1>
          <p className="text-sm text-muted-foreground" data-testid="no-campus-assigned-message">
            Your account isn&apos;t assigned to any campus yet. Ask your school&apos;s Owner or Principal to grant you access to
            one.
          </p>
        </div>
      );
    }
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <AppNav />
      {children}
    </div>
  );
}
