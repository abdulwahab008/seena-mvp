'use server';

import { searchStaffSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type StaffDirectoryRow = {
  staff_id: string;
  employee_code: string;
  full_name: string;
  full_name_ur: string | null;
  designation: string | null;
  department: string | null;
  gender: string;
  employment_status: string;
  is_former: boolean;
  mobile: string | null;
  identity_document_number: string | null;
};

export type SearchStaffState = { error: string | null; results: StaffDirectoryRow[] | null };

// FR-D19: search_staff() itself decides whether mobile/identity_document_number
// are populated, based on the caller's role — nothing to gate here.
export async function searchStaffDirectory(_prev: SearchStaffState, formData: FormData): Promise<SearchStaffState> {
  const parsed = searchStaffSchema.safeParse({
    q: formData.get('q') || undefined,
    includeFormer: formData.get('includeFormer') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', results: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('search_staff', {
    p_q: parsed.data.q,
    p_include_former: parsed.data.includeFormer ?? false,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to search the staff directory.', results: null };
    return { error: 'Could not search the staff directory.', results: null };
  }

  return { error: null, results: (data as StaffDirectoryRow[]) ?? [] };
}
