import type { supabaseServer } from '@/lib/supabase/server';
import type { CertificateType } from '@/lib/validation';
import type { RegisterContinuity, RegisterRow } from './register-html';

/**
 * FR-T08: the one read the register page and the register PDF both make.
 *
 * It lives here rather than in the page or the server action so the printed
 * register and the register on screen cannot drift into being two different
 * queries — an inspector comparing the screen with the printout has to see
 * the same page.
 */

export type RegisterFilters = { campusId: string; certificateType: CertificateType; academicYear: number };

export const CERTIFICATE_TYPE_LABELS: Record<CertificateType, string> = {
  transfer: 'Transfer Certificate',
  character: 'Character Certificate',
  bonafide: 'Bonafide Certificate',
};

/**
 * v_certificate_register already carries the frozen student identity, the
 * cancellation annotation and BOTH halves of the replacement
 * cross-reference, so a register of any size is one query with no per-row
 * lookup behind it.
 */
export const REGISTER_COLUMNS =
  'id, serial_seq, serial_no, status, issued_at, gr_number, student_name, class_name, section_name, ' +
  'campus_id, campus_code, certificate_type, academic_year, student_id, ' +
  'cancelled_at, cancelled_reason, cancelled_by_name, replaced_by_issue_id, replaced_by_serial_no, ' +
  'replaces_issue_id, replaces_serial_no';

export type RegisterViewRow = RegisterRow & {
  id: string;
  campus_id: string;
  campus_code: string;
  certificate_type: CertificateType;
  academic_year: number;
  student_id: string;
  section_name: string | null;
  replaced_by_issue_id: string | null;
  replaces_issue_id: string | null;
};

/**
 * With one campus chosen there is exactly one series; with "All campuses"
 * the per-series rows are summed, so the statement printed at the top of
 * the register still describes what is actually on the page.
 */
function foldContinuity(series: RegisterContinuity[]): RegisterContinuity | null {
  if (series.length === 0) return null;
  return series.reduce<RegisterContinuity>(
    (acc, s) => ({
      expected_count: acc.expected_count + Number(s.expected_count),
      present_count: acc.present_count + Number(s.present_count),
      unnumbered_count: acc.unnumbered_count + Number(s.unnumbered_count),
      counter_value: acc.counter_value + Number(s.counter_value),
      missing_seq: [...acc.missing_seq, ...(s.missing_seq ?? [])],
      first_serial: acc.first_serial ?? s.first_serial,
      last_serial: s.last_serial ?? acc.last_serial,
    }),
    {
      expected_count: 0,
      present_count: 0,
      unnumbered_count: 0,
      counter_value: 0,
      missing_seq: [],
      first_serial: null,
      last_serial: null,
    },
  );
}

export async function readRegister(
  supabase: Awaited<ReturnType<typeof supabaseServer>>,
  filters: RegisterFilters,
): Promise<{ rows: RegisterViewRow[]; continuity: RegisterContinuity | null }> {
  let query = supabase
    .from('v_certificate_register')
    .select(REGISTER_COLUMNS)
    .eq('certificate_type', filters.certificateType)
    .eq('academic_year', filters.academicYear)
    .order('serial_seq', { nullsFirst: false });
  if (filters.campusId) query = query.eq('campus_id', filters.campusId);

  const [{ data }, { data: continuityRows }] = await Promise.all([
    query,
    supabase.rpc('certificate_register_continuity', {
      p_campus_id: filters.campusId || undefined,
      p_certificate_type: filters.certificateType,
      p_academic_year: filters.academicYear,
    }),
  ]);

  return {
    rows: (data ?? []) as unknown as RegisterViewRow[],
    continuity: foldContinuity((continuityRows ?? []) as unknown as RegisterContinuity[]),
  };
}
