import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const uuid = z.string().uuid();

export type RegisterFilters = { session?: string; class?: string };

export function parseRegisterFilters(sp: Record<string, string | null | undefined>): RegisterFilters {
  return {
    session: uuid.safeParse(sp.session).success ? sp.session! : undefined,
    class: uuid.safeParse(sp.class).success ? sp.class! : undefined,
  };
}

export async function loadAdmissionRegister(f: RegisterFilters) {
  const supabase = await supabaseServer();
  return supabase.rpc('admission_register', { p_session_id: f.session, p_class_level_id: f.class });
}
