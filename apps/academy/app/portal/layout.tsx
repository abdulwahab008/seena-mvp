import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';

// The parent/guardian portal. Deliberately separate from (app)'s layout —
// that one's nav links (Campuses, Fees, Staff...) are all staff surfaces a
// parent's own RLS would mostly return empty on; this is the one guardians
// (FR-C11) actually land in.
export default async function PortalLayout({ children }: { children: React.ReactNode }) {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  return (
    <div className="mx-auto max-w-2xl p-6">
      <h1 className="mb-6 text-lg font-semibold">Parent Portal</h1>
      {children}
    </div>
  );
}
