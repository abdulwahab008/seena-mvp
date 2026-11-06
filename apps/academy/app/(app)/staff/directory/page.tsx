import { supabaseServer } from '@/lib/supabase/server';
import { StaffDirectorySearch } from './staff-directory-search';
import { AddStaffModal } from '../add-staff-modal';
import type { StaffDirectoryRow } from './actions';
import { pickActiveCampus } from '@/lib/campus-context';
import { getCurrentActor } from '@/lib/hr/current-role';

// Who register_staff_member() allows.
const STAFF_REGISTRAR_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager'];

export const dynamic = 'force-dynamic';

export default async function StaffDirectoryPage() {
  const supabase = await supabaseServer();
  const actor = await getCurrentActor();
  const [{ data }, { data: campuses }, { data: subjects }, { data: departments }] = await Promise.all([
    supabase.rpc('search_staff', { p_include_former: false }),
    supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
    supabase.from('subject').select('id, name_en, code').order('name_en'),
    supabase.from('department').select('id, name_en, code').order('code'),
  ]);

  const firstCampus = (await pickActiveCampus(campuses));

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Staff Directory</h1>
          <p className="text-sm text-muted-foreground">
            Search staff by name or employee code. Mobile numbers and ID documents are shown only to leadership and HR.
          </p>
        </div>
        {firstCampus && actor && STAFF_REGISTRAR_ROLES.includes(actor.role) && (
          <AddStaffModal
            campusId={firstCampus.id}
            campusName={firstCampus.name}
            subjects={subjects ?? []}
            departments={departments ?? []}
          />
        )}
      </div>
      <StaffDirectorySearch
        initialResults={(data as StaffDirectoryRow[]) ?? []}
        departments={departments ?? []}
      />
    </div>
  );
}
