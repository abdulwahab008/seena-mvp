import { redirect } from 'next/navigation';
import { Building2 } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';
import { hasNoCampusAssigned } from '@/lib/campus-scope';
import { EmptyState } from '@/components/ui/empty-state';
import { AppHeader } from './app-header';
import { Sidebar } from './sidebar';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: appUser } = await supabase
    .from('app_user')
    .select('app_role, tenant_id')
    .eq('user_id', user.id)
    .single();

  // FR-A12 AC4: a campus-scoped role (i.e. not owner/super_admin, whose
  // access is role-based, not user_campus-based) with zero active
  // user_campus rows has nothing to see anywhere — every campus-scoped RLS
  // policy already returns zero rows for them (campus_id = any('{}') is
  // never true), so this is purely a friendlier "why is everything empty"
  // screen, not an additional access-control layer.
  if (appUser) {
    const { data: activeCampuses } = await supabase
      .from('user_campus')
      .select('campus_id')
      .eq('user_id', user.id)
      .eq('is_active', true);

    if (hasNoCampusAssigned(appUser.app_role, activeCampuses?.length ?? 0)) {
      return (
        <div className="flex min-h-screen items-center justify-center p-6">
          <EmptyState
            icon={Building2}
            className="max-w-md bg-card"
            title="No campus assigned"
            description="Your account isn't assigned to any campus yet. Ask your school's Owner or Principal to grant you access to one."
            data-testid="no-campus-assigned"
          />
        </div>
      );
    }
  }

  const { data: tenant } = await supabase.from('tenant').select('name').limit(1).single();
  const schoolName = tenant?.name ?? 'Your school';

  return (
    <div className="flex min-h-screen bg-background">
      <Sidebar schoolName={schoolName} />
      <div className="flex min-w-0 flex-1 flex-col">
        <AppHeader
          email={user.email ?? 'Signed in'}
          role={appUser?.app_role ?? 'member'}
          schoolName={schoolName}
        />
        <main className="mx-auto w-full max-w-[90rem] flex-1 px-4 py-6 sm:px-6 lg:px-8">
          {children}
        </main>
      </div>
    </div>
  );
}
