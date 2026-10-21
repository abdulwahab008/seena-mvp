import { headers } from 'next/headers';
import { redirect } from 'next/navigation';
import { canOpenFeesPath, FEES_DENIED_HOME } from '@/lib/auth/fee-access';
import { PATHNAME_HEADER } from '@/lib/auth/redirect';
import { supabaseServer } from '@/lib/supabase/server';

// Fee data is for the people who handle fees. The database enforces it (the core fee tables ask for
// a finance role), so a session without one would only see empty tables here; this sends it home
// instead. The role is read off the verified token, the same claim the database policies read. See
// lib/auth/fee-access.ts.
export default async function FeesLayout({ children }: { children: React.ReactNode }) {
  const supabase = await supabaseServer();
  const { data: verified } = await supabase.auth.getClaims();
  const pathname = ((await headers()).get(PATHNAME_HEADER) ?? '').split('?')[0] ?? '';
  if (!canOpenFeesPath(verified?.claims.app_role, pathname)) redirect(FEES_DENIED_HOME);
  return children;
}
