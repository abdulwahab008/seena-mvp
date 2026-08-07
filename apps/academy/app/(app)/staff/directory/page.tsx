import { supabaseServer } from '@/lib/supabase/server';
import { StaffDirectorySearch } from './staff-directory-search';
import type { StaffDirectoryRow } from './actions';

export default async function StaffDirectoryPage() {
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('search_staff', { p_include_former: false });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff directory</h1>
        <p className="text-sm text-muted-foreground">
          FR-D19 — search staff by name or employee code. Mobile numbers and identity document numbers are visible to HR and Principal roles only.
        </p>
      </div>
      <StaffDirectorySearch initialResults={(data as StaffDirectoryRow[]) ?? []} />
    </div>
  );
}
