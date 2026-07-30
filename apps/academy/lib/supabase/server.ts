import { createServerClient } from '@supabase/ssr';
import { createClient } from '@supabase/supabase-js';
import { cookies } from 'next/headers';
import { env } from '../env';
import type { Database } from '../database.types';

/**
 * Server client for Server Components / Route Handlers / Server Actions.
 * Runs as the signed-in user (RLS-enforced via their JWT) — never use the
 * service-role key here.
 */
export async function supabaseServer() {
  const cookieStore = await cookies();
  return createServerClient<Database>(
    env().NEXT_PUBLIC_SUPABASE_URL,
    env().NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (cookiesToSet) => {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component (not a Route Handler/Action) —
            // middleware refreshes the session instead. Safe to ignore.
          }
        },
      },
    },
  );
}

/**
 * Service-role client. Bypasses RLS entirely — only for trusted server-side
 * operations that must cross tenant boundaries (e.g. tenant provisioning
 * before any user has an assigned tenant_id). Never expose to a request
 * handler that echoes untrusted input straight into a query.
 */
export function supabaseServiceRole() {
  return createClient<Database>(env().NEXT_PUBLIC_SUPABASE_URL, env().SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
}
