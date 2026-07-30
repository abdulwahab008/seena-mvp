import { createBrowserClient } from '@supabase/ssr';
import type { Database } from '../database.types';

/**
 * Browser client. Reads NEXT_PUBLIC_* directly (not via lib/env.ts) so
 * Next.js's build-time static replacement can inline them into the client
 * bundle — an indirected/dynamic env lookup would not be inlined.
 */
export function supabaseBrowser() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}
