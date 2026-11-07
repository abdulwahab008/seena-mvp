'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only HR and leadership can manage recruitment.';
  if (m.includes('OPENING_CLOSED')) return 'This opening is closed.';
  if (m.includes('APPLICATION_CLOSED')) return 'This application is already finished.';
  if (m.includes('INTERVIEW_TIME_REQUIRED')) return 'Choose an interview time.';
  if (m.includes('uq_job_application_cnic')) return 'This CNIC has already applied for this opening.';
  return 'Something went wrong. Try again.';
}

const openingSchema = z.object({
  campusId: z.string().uuid(),
  title: z.string().trim().min(1, 'Enter a title').max(150),
  positions: z.coerce.number().int().min(1).max(100),
  salaryRange: z.string().trim().max(100).optional(),
  description: z.string().trim().max(4000).optional(),
  closesOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional().or(z.literal('')),
});

export async function saveOpening(input: unknown): Promise<{ error: string | null; id?: string }> {
  const p = openingSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_job_opening', {
    p_campus_id: v.campusId,
    p_title: v.title,
    p_department_id: null,
    p_positions: v.positions,
    p_salary_range: v.salaryRange ?? null,
    p_description: v.description ?? null,
    p_closes_on: v.closesOn || null,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/staff/recruitment');
  return { error: null, id: data };
}

const applicantSchema = z.object({
  jobOpeningId: z.string().uuid(),
  candidateName: z.string().trim().min(1, 'Enter a name').max(200),
  phone: z.string().trim().max(30).optional(),
  email: z.string().trim().email('Enter a valid email').optional().or(z.literal('')),
  cnic: z.string().trim().max(15).optional(),
  qualification: z.string().trim().max(300).optional(),
  experienceYrs: z.coerce.number().min(0).max(60).optional().or(z.literal('').transform(() => undefined)),
  source: z.string().trim().max(100).optional(),
});

export async function addApplicant(input: unknown): Promise<{ error: string | null }> {
  const p = applicantSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_job_application', {
    p_job_opening_id: v.jobOpeningId,
    p_candidate_name: v.candidateName,
    p_phone: v.phone ?? null,
    p_email: v.email || null,
    p_cnic: v.cnic ?? null,
    p_qualification: v.qualification ?? null,
    p_experience_yrs: v.experienceYrs ?? null,
    p_source: v.source ?? null,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/staff/recruitment');
  return { error: null };
}

const moveSchema = z.object({
  applicationId: z.string().uuid(),
  stage: z.enum(['shortlisted', 'interview', 'offered', 'hired', 'rejected', 'withdrawn']),
  note: z.string().trim().max(1000).optional(),
  interviewAt: z.string().optional(),
});

export async function moveApplicant(input: z.input<typeof moveSchema>): Promise<{ error: string | null }> {
  const p = moveSchema.safeParse(input);
  if (!p.success) return { error: 'Check the form.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('move_job_application', {
    p_application_id: v.applicationId,
    p_stage: v.stage,
    p_note: v.note ?? null,
    p_interview_at: v.interviewAt || null,
    p_rating: null,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/staff/recruitment');
  return { error: null };
}
