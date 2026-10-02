'use server';

import { revalidatePath } from 'next/cache';
import { issueCharacterCertificateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { renderAndStoreCertificate, type IssuedCertificate } from '@/lib/certificates/issue';

/**
 * FR-T05: the Character Certificate issuing action.
 *
 * Same two-phase shape as FR-T03 and for the same reason — the database
 * transaction allocates the serial and writes the register row, the render
 * happens here afterwards, and a render failure voids the row while KEEPING
 * its serial (lib/certificates/issue.ts).
 *
 * The attendance period is NOT sent unless the officer typed one:
 * issue_character_certificate() derives it from the student's whole
 * enrolment history, which is the only place that fact actually lives.
 */

const PATH = '/certificates/issue/character';

export type IssueCharacterCertificateState = {
  error: string | null;
  serialNo?: string;
  downloadUrl?: string;
  periodFrom?: string;
  periodTo?: string;
};

/** What student_attendance_span() returns, for the form to show before issuing. */
export type AttendanceSpan = { periodFrom: string | null; periodTo: string | null; enrolmentCount: number };

function issueErrorMessage(message: string): string | null {
  if (message.includes('CONDUCT_GRADE_INVALID')) {
    return 'Conduct must be one of Excellent, Very Good, Good or Satisfactory.';
  }
  if (message.includes('ATTENDANCE_PERIOD_UNKNOWN')) {
    return 'This student has no enrolment history to derive the attendance period from — state it explicitly.';
  }
  if (message.includes('PERIOD_END_BEFORE_START')) return 'The attendance period cannot end before it starts.';
  if (message.includes('PERIOD_IN_FUTURE')) return 'A certificate cannot certify conduct that has not happened yet.';
  if (message.includes('TEMPLATE_NOT_FOUND')) {
    return 'No active Character Certificate template for this campus, board and language. Design and activate one first.';
  }
  if (message.includes('ACADEMIC_SESSION_NOT_FOUND')) {
    return 'This campus has no current academic session to number the certificate against.';
  }
  if (message.includes('STUDENT_NOT_FOUND')) return 'Student not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to issue certificates here.';
  return null;
}

export async function attendanceSpan(studentId: string): Promise<AttendanceSpan | null> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('student_attendance_span', { p_student_id: studentId });
  if (error || !data) return null;
  const span = data as unknown as { period_from: string | null; period_to: string | null; enrolment_count: number };
  return { periodFrom: span.period_from, periodTo: span.period_to, enrolmentCount: span.enrolment_count };
}

export async function issueCharacterCertificate(formData: FormData): Promise<IssueCharacterCertificateState> {
  const parsed = issueCharacterCertificateSchema.safeParse({
    studentId: formData.get('studentId'),
    conduct: formData.get('conduct'),
    periodFrom: formData.get('periodFrom') ?? '',
    periodTo: formData.get('periodTo') ?? '',
    remarks: formData.get('remarks') ?? '',
    boardCode: formData.get('boardCode') ?? '',
    language: formData.get('language'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('issue_character_certificate', {
    p_student_id: parsed.data.studentId,
    p_conduct: parsed.data.conduct,
    p_period_from: parsed.data.periodFrom || undefined,
    p_period_to: parsed.data.periodTo || undefined,
    p_remarks: parsed.data.remarks || undefined,
    p_board_code: parsed.data.boardCode || undefined,
    p_language: parsed.data.language,
  });

  if (error || !data) {
    return { error: (error && issueErrorMessage(error.message)) ?? 'Could not issue the certificate.' };
  }

  const issued = data as unknown as IssuedCertificate & { period_from: string; period_to: string };
  const stored = await renderAndStoreCertificate(supabase, issued);
  revalidatePath(PATH);
  if (stored.error) return { error: stored.error };

  return {
    error: null,
    serialNo: issued.serial_no,
    downloadUrl: stored.downloadUrl,
    periodFrom: issued.period_from,
    periodTo: issued.period_to,
  };
}
