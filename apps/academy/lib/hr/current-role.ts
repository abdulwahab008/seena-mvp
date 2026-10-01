import { supabaseServer } from '@/lib/supabase/server';

export type CurrentActor = { userId: string; role: string; fullName: string; tenantId: string };

/**
 * The signed-in user's tenant role, read from app_user (RLS lets a user read
 * their own row). Pages use it to decide which controls to RENDER; it is
 * never the authorisation — every RPC re-checks the JWT role in the database.
 */
export async function getCurrentActor(): Promise<CurrentActor | null> {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data } = await supabase.from('app_user').select('user_id, app_role, full_name, tenant_id').eq('user_id', user.id).maybeSingle();
  if (!data) return null;
  return { userId: data.user_id, role: data.app_role, fullName: data.full_name, tenantId: data.tenant_id };
}

export const HR_WRITE_ROLES = ['super_admin', 'owner', 'hr_manager'] as const;
export function isHrWriter(role: string | undefined | null): boolean {
  return !!role && (HR_WRITE_ROLES as readonly string[]).includes(role);
}

export function one<T>(v: T | T[] | null | undefined): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : (v ?? null);
}

export const todayKarachi = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
