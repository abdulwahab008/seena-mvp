import type { SupabaseClient } from '@supabase/supabase-js';

// GoTrue's admin list endpoint pages, and `listUsers()` with no arguments
// asks for exactly one page of 50 — so a spec that scanned it for its own
// leftover fixture row worked only on a freshly reset database and started
// failing (createUser: "Phone number already registered") the moment the
// local DB accumulated more than 50 auth users, which it does within a
// couple of full e2e runs.
//
// There is no targeted lookup to use instead: GoTrue exposes GET
// /admin/users/{id} (needs the id we're trying to find) and a `filter`
// query param that matches on EMAIL ONLY — verified against the local
// v2.185.0 instance, where filtering on an existing user's exact phone
// returns zero rows — and PostgREST cannot reach auth.users, since
// config.toml exposes only the public and graphql_public schemas. So
// walking the pages is the correct answer, and `nextPage` (GoTrue's own
// Link header, not a guess at the total) is what ends the walk.
const PER_PAGE = 1000;

export async function deleteAuthUserByPhone(admin: SupabaseClient, phone: string): Promise<boolean> {
  for (let page = 1; ; ) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: PER_PAGE });
    if (error) throw error;

    const stale = data.users.find((u) => u.phone === phone);
    if (stale) {
      const { error: deleteError } = await admin.auth.admin.deleteUser(stale.id);
      if (deleteError) throw deleteError;
      return true;
    }

    if (!data.nextPage) return false;
    page = data.nextPage;
  }
}
