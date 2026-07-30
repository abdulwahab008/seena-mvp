'use server';

import { revalidatePath } from 'next/cache';
import { createStudentSchema, linkGuardianSchema, enrolStudentSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type CreateStudentState = { error: string | null; studentId: string | null };

// FR-C04: create a student profile. GR allocation (FR-C01), B-Form
// normalization and duplicate detection all happen inside create_student()
// itself — this action only shapes the client-facing error.
export async function createStudent(_prev: CreateStudentState, formData: FormData): Promise<CreateStudentState> {
  const parsed = createStudentSchema.safeParse({
    campusId: formData.get('campusId'),
    nameEn: formData.get('nameEn'),
    nameUr: formData.get('nameUr') || undefined,
    dob: formData.get('dob'),
    gender: formData.get('gender'),
    fatherNameEn: formData.get('fatherNameEn') || undefined,
    fatherNameUr: formData.get('fatherNameUr') || undefined,
    bFormNo: formData.get('bFormNo') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', studentId: null };

  const supabase = await supabaseServer();
  const { data: studentId, error } = await supabase.rpc('create_student', {
    p_campus_id: parsed.data.campusId,
    p_name_en: parsed.data.nameEn,
    p_dob: parsed.data.dob,
    p_gender: parsed.data.gender,
    p_name_ur: parsed.data.nameUr,
    p_father_name_en: parsed.data.fatherNameEn,
    p_father_name_ur: parsed.data.fatherNameUr,
    p_b_form_no: parsed.data.bFormNo,
  });

  if (error) {
    if (error.message.includes('BFORM_INVALID_FORMAT')) return { error: 'B-Form number must resolve to 13 digits.', studentId: null };
    if (error.message.includes('BFORM_DUPLICATE')) return { error: 'Another student already holds this B-Form number.', studentId: null };
    if (error.message.includes('chk_dob_reasonable'))
      return { error: 'Date of birth must be in the past and imply an age under 25.', studentId: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to admit students at this campus.', studentId: null };
    return { error: 'Could not save the student.', studentId: null };
  }

  revalidatePath('/students');
  return { error: null, studentId };
}

export type LinkGuardianState = { error: string | null };

// FR-C09/C10: find-or-create the guardian by CNIC (dedup), then link them
// to the student. Both RPCs enforce their own authorization and business
// rules (billing-recipient requirement, primary-guardian exclusivity).
export async function linkGuardianToStudent(studentId: string, _prev: LinkGuardianState, formData: FormData): Promise<LinkGuardianState> {
  const parsed = linkGuardianSchema.safeParse({
    nameEn: formData.get('nameEn'),
    cnic: formData.get('cnic') || undefined,
    phone: formData.get('phone') || undefined,
    relationship: formData.get('relationship'),
    isPrimary: formData.get('isPrimary') === 'on',
    receivesBilling: formData.get('receivesBilling') === 'on',
    mayCollectChild: formData.get('mayCollectChild') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data: guardianId, error: findError } = await supabase.rpc('fn_find_or_create_guardian', {
    p_name_en: parsed.data.nameEn,
    p_cnic: parsed.data.cnic,
    p_phone_e164: parsed.data.phone,
  });
  if (findError) {
    if (findError.message.includes('ID_INVALID_FORMAT')) return { error: 'CNIC must resolve to 13 digits.' };
    return { error: 'Could not save the guardian.' };
  }

  const { error: linkError } = await supabase.rpc('link_guardian', {
    p_student_id: studentId,
    p_guardian_id: guardianId,
    p_relationship: parsed.data.relationship,
    p_is_primary: parsed.data.isPrimary,
    p_receives_billing: parsed.data.receivesBilling,
    p_may_collect_child: parsed.data.mayCollectChild,
  });
  if (linkError) {
    if (linkError.message.includes('PRIMARY_GUARDIAN_EXISTS')) return { error: 'This student already has a primary guardian.' };
    if (linkError.message.includes('fee notices')) return { error: 'At least one guardian must receive fee notices.' };
    return { error: 'Could not link the guardian.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}

export type EnrolStudentState = { error: string | null };

// FR-E03/C02: enrol into a section. Capacity, gender restriction and the
// advisory-lock race guard all live inside enrol_student() itself.
export async function enrolStudentIntoSection(studentId: string, _prev: EnrolStudentState, formData: FormData): Promise<EnrolStudentState> {
  const parsed = enrolStudentSchema.safeParse({ sectionId: formData.get('sectionId') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('enrol_student', { p_section_id: parsed.data.sectionId, p_student_id: studentId });

  if (error) {
    if (error.message.includes('SECTION_FULL')) return { error: 'This section is full.' };
    if (error.message.includes('SECTION_GENDER_RESTRICTED')) return { error: 'This section does not admit this student’s gender.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to enrol students at this campus.' };
    return { error: 'Could not enrol the student.' };
  }

  revalidatePath(`/students/${studentId}`);
  return { error: null };
}
