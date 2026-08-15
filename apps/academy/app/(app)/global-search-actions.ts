'use server';

import { globalSearchSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type GlobalSearchHit = {
  entity_type: string;
  entity_id: string;
  campus_id: string | null;
  display_label: string;
  subtitle: string | null;
  match_field: string;
  href: string | null;
  rank: number;
  truncated: boolean;
};

export type GlobalSearchState = {
  error: string | null;
  results: GlobalSearchHit[] | null;
  truncated: boolean;
};

const EMPTY: GlobalSearchState = { error: null, results: [], truncated: false };

// FR-A20: global_search() is SECURITY INVOKER, so the caller's RLS is the
// authorization gate — there is nothing to re-check here, and re-checking
// would be a second copy of the rules to drift.
export async function globalSearch(query: string): Promise<GlobalSearchState> {
  const parsed = globalSearchSchema.safeParse({ q: query });
  if (!parsed.success) return EMPTY;

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('global_search', { p_q: parsed.data.q });

  if (error) {
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to search.', results: null, truncated: false };
    }
    return { error: 'Could not run the search.', results: null, truncated: false };
  }

  const results = (data as GlobalSearchHit[]) ?? [];
  // Every row carries the same flag; it describes the result set, not the row.
  return { error: null, results, truncated: results.some((r) => r.truncated) };
}
