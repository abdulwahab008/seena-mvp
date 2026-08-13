'use server';

import { revalidatePath } from 'next/cache';
import {
  recordConsentSchema,
  buildGalleryExportSchema,
  MAX_DOCUMENT_FILE_SIZE,
  ALLOWED_DOCUMENT_MIME_TYPES,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

const PATH = '/consent';

export type RecordConsentState = { error: string | null; consentRecordId?: string; effective?: boolean };

function consentError(message: string): string | null {
  if (message.includes('GUARDIAN_NOT_LINKED')) return 'That guardian is not currently linked to this student.';
  if (message.includes('EVIDENCE_REQUIRED')) return 'A paper capture needs the signed form attached.';
  if (message.includes('EVIDENCE_PATH_MISMATCH')) return 'The scan does not belong to this student.';
  if (message.includes('FILE_TOO_LARGE')) return 'Maximum file size 5 MB.';
  if (message.includes('UNSUPPORTED_FILE_TYPE')) return 'Only JPEG, PNG and PDF scans are accepted.';
  if (message.includes('CONSENT_PURPOSE_NOT_FOUND')) return 'That consent purpose no longer exists.';
  if (message.includes('STUDENT_NOT_FOUND')) return 'Student not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to record this consent.';
  return null;
}

// FR-T15 AC5. The evidence is uploaded BEFORE the decision row is written,
// which is the reverse of the reserve-row/upload/compensating-delete order
// branding and admission-docs use — consent_record is append-only, so there
// is no row to delete when an upload fails. See the migration header. A
// failed record_consent() here leaves an object nobody can read (the
// bucket's SELECT policy needs a consent_record pointing at it), never a
// half-written decision.
export async function recordConsent(_prev: RecordConsentState, formData: FormData): Promise<RecordConsentState> {
  const parsed = recordConsentSchema.safeParse({
    studentId: formData.get('studentId'),
    purposeCode: formData.get('purposeCode'),
    guardianId: formData.get('guardianId'),
    decision: formData.get('decision'),
    channel: formData.get('channel'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const file = formData.get('evidence');
  const hasFile = file instanceof File && file.size > 0;
  if (parsed.data.channel === 'paper' && !hasFile) return { error: 'A paper capture needs the signed form attached.' };

  const supabase = await supabaseServer();
  let evidencePath: string | undefined;

  if (hasFile) {
    const upload = file as File;
    if (upload.size > MAX_DOCUMENT_FILE_SIZE) return { error: 'Maximum file size 5 MB.' };
    if (!ALLOWED_DOCUMENT_MIME_TYPES.includes(upload.type as (typeof ALLOWED_DOCUMENT_MIME_TYPES)[number])) {
      return { error: 'Only JPEG, PNG and PDF scans are accepted.' };
    }
    const ext = upload.name.includes('.') ? upload.name.split('.').pop()!.toLowerCase() : 'bin';

    const { data: path, error: reserveError } = await supabase.rpc('reserve_consent_evidence_path', {
      p_student_id: parsed.data.studentId,
      p_file_ext: ext,
      p_file_size: upload.size,
      p_mime_type: upload.type,
    });
    if (reserveError || !path) return { error: consentError(reserveError?.message ?? '') ?? 'Could not prepare the scan upload.' };

    const { error: uploadError } = await supabase.storage
      .from('consent-evidence')
      .upload(path, upload, { contentType: upload.type, upsert: false });
    if (uploadError) return { error: 'Upload failed. Please try again.' };
    evidencePath = path;
  }

  const { data, error } = await supabase.rpc('record_consent', {
    p_student_id: parsed.data.studentId,
    p_purpose_code: parsed.data.purposeCode,
    p_guardian_id: parsed.data.guardianId,
    p_decision: parsed.data.decision,
    p_channel: parsed.data.channel,
    p_evidence_path: evidencePath,
  });
  if (error) return { error: consentError(error.message) ?? 'Could not record the consent.' };

  const result = data as { consent_record_id: string; effective: boolean };
  revalidatePath(PATH);
  return { error: null, consentRecordId: result.consent_record_id, effective: result.effective };
}

export type GalleryExportState = {
  error: string | null;
  included?: number;
  excludedConsentDenied?: number;
  excludedNotRecorded?: number;
  excludedNoPhoto?: number;
};

// FR-T15 AC1. There is no "include anyway" switch here on purpose: the
// membership test inside build_marketing_gallery_export() IS
// has_consent(), and every student it turns away leaves an exclusion row
// (and therefore an audit_log row) behind.
export async function buildGalleryExport(_prev: GalleryExportState, formData: FormData): Promise<GalleryExportState> {
  const parsed = buildGalleryExportSchema.safeParse({
    campusId: formData.get('campusId'),
    sectionId: formData.get('sectionId') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('build_marketing_gallery_export', {
    p_campus_id: parsed.data.campusId,
    p_section_id: parsed.data.sectionId || undefined,
  });
  if (error) {
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to build a marketing gallery.' };
    return { error: 'Could not build the gallery export.' };
  }

  const result = data as {
    included: number;
    excluded_consent_denied: number;
    excluded_consent_not_recorded: number;
    excluded_no_photo: number;
  };
  revalidatePath(PATH);
  return {
    error: null,
    included: result.included,
    excludedConsentDenied: result.excluded_consent_denied,
    excludedNotRecorded: result.excluded_consent_not_recorded,
    excludedNoPhoto: result.excluded_no_photo,
  };
}

export type ConsentStateRow = {
  purpose_code: string;
  description_en: string;
  description_ur: string | null;
  current_version: number;
  effective: boolean;
  requires_explicit_grant: boolean;
  has_conflict: boolean;
  reconsent_required: boolean;
  guardian_count: number;
  granted_count: number;
  denied_count: number;
};

export type GuardianDecisionRow = {
  consent_record_id: string;
  purpose_code: string;
  granted_by_guardian_id: string;
  guardian_name: string;
  relationship: string;
  decision: string;
  channel: string;
  text_version: number;
  evidence_path: string | null;
  recorded_at: string;
};

export type StudentConsentDetail = {
  error: string | null;
  purposes?: ConsentStateRow[];
  decisions?: GuardianDecisionRow[];
  guardians?: Array<{ id: string; name: string; relationship: string }>;
};

export async function loadStudentConsent(studentId: string): Promise<StudentConsentDetail> {
  const supabase = await supabaseServer();

  const [{ data: purposes, error: purposeError }, { data: decisions }, { data: links }] = await Promise.all([
    supabase.rpc('consent_state_for_student', { p_student_id: studentId }),
    supabase
      .from('v_consent_guardian_decision')
      .select('consent_record_id, purpose_code, granted_by_guardian_id, guardian_name, relationship, decision, channel, text_version, evidence_path, recorded_at')
      .eq('student_id', studentId),
    supabase.from('student_guardian').select('guardian_id, relationship, guardian:guardian_id(name_en)').eq('student_id', studentId).is('to_date', null),
  ]);

  if (purposeError) return { error: 'Could not load this student’s consent state.' };

  const guardians = (links ?? []).map((l) => {
    const g = Array.isArray(l.guardian) ? l.guardian[0] : l.guardian;
    return { id: l.guardian_id, name: g?.name_en ?? 'Guardian', relationship: l.relationship as string };
  });

  return {
    error: null,
    purposes: (purposes ?? []) as ConsentStateRow[],
    decisions: (decisions ?? []) as GuardianDecisionRow[],
    guardians,
  };
}

export async function getConsentEvidenceUrl(path: string): Promise<{ url: string | null }> {
  const supabase = await supabaseServer();
  const { data } = await supabase.storage.from('consent-evidence').createSignedUrl(path, 900);
  return { url: data?.signedUrl ?? null };
}
