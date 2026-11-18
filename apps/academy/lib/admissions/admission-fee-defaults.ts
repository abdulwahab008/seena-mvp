import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@/lib/database.types';

export const admissionFeeKey = (campusId: string, sessionId: string, classId: string) => `${campusId}:${sessionId}:${classId}`;

// The ADMISSION line of each campus/session's published fee structure, in rupees, keyed by
// admissionFeeKey(). Offers and walk-ins start from this instead of a number typed (or hard-coded) per child.
export async function loadAdmissionFeeDefaults(supabase: SupabaseClient<Database>): Promise<Record<string, number>> {
  const { data } = await supabase
    .from('fee_structure_line')
    .select('class_id, amount_paisa, group_code, fee_head!inner(code), fee_structure!inner(campus_id, session_id, status)')
    .eq('fee_head.code', 'ADMISSION')
    .eq('fee_structure.status', 'published');

  const out: Record<string, number> = {};
  for (const l of data ?? []) {
    const s = Array.isArray(l.fee_structure) ? l.fee_structure[0] : l.fee_structure;
    if (!s) continue;
    const key = admissionFeeKey(s.campus_id, s.session_id, l.class_id);
    // A group-specific line (Class 9-12) only wins when the class has no general line.
    if (l.group_code && key in out) continue;
    out[key] = l.amount_paisa / 100;
  }
  return out;
}
