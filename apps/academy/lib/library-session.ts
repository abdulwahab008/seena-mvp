import { supabaseServer } from '@/lib/supabase/server';

export const LIBRARY_STAFF_ROLES = ['super_admin', 'owner', 'principal', 'librarian'] as const;

/** Who is looking at the library pages. Presentation only: the RPCs re-check the role. */
export async function libraryViewer() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: me } = await supabase.from('app_user').select('app_role, tenant_id').eq('user_id', user!.id).maybeSingle();
  const role = me?.app_role ?? null;
  return { supabase, userId: user!.id, tenantId: me?.tenant_id ?? null, role, isStaff: role !== null && (LIBRARY_STAFF_ROLES as readonly string[]).includes(role) };
}
