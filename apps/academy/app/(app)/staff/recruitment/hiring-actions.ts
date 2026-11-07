'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

type Result = { error: string | null };

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only HR and leadership can manage recruitment.';
  if (m.includes('APPLICATION_CLOSED')) return 'This application is already finished.';
  if (m.includes('NOT_OFFERED')) return 'Make an offer before hiring.';
  if (m.includes('CNIC_REQUIRED')) return 'Enter the CNIC.';
  if (m.includes('chk_staff_cnic_format')) return 'Enter the CNIC as 12345-1234567-1.';
  if (m.includes('uq_staff_active_cnic')) return 'A current staff member already has this CNIC.';
  if (m.includes('employee_code')) return 'That employee code is already used.';
  return 'Something went wrong. Try again.';
}

async function finish(error: { message: string } | null): Promise<Result> {
  if (error) return { error: message(error.message) };
  revalidatePath('/staff/recruitment');
  return { error: null };
}

const score = z.coerce.number().int().min(1).max(5);
const scoreSchema = z.object({
  applicationId: z.string().uuid(),
  subjectKnowledge: score, communication: score, teachingDemo: score, attitude: score,
  recommendation: z.enum(['hire', 'hold', 'reject']),
  comment: z.string().trim().max(1000),
});

export async function saveScore(input: unknown): Promise<Result> {
  const p = scoreSchema.safeParse(input);
  if (!p.success) return { error: 'Score each area from 1 to 5.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_interview_score', {
    p_application_id: p.data.applicationId, p_subject_knowledge: p.data.subjectKnowledge, p_communication: p.data.communication,
    p_teaching_demo: p.data.teachingDemo, p_attitude: p.data.attitude, p_recommendation: p.data.recommendation, p_comment: p.data.comment,
  });
  return finish(error);
}

const offerSchema = z.object({ applicationId: z.string().uuid(), salary: z.coerce.number().positive('Enter the monthly salary'), joiningOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the joining date') });

export async function makeOffer(input: unknown): Promise<Result> {
  const p = offerSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the offer.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('make_job_offer', { p_application_id: p.data.applicationId, p_salary_paisa: Math.round(p.data.salary * 100), p_joining_on: p.data.joiningOn });
  return finish(error);
}

const hireSchema = z.object({ applicationId: z.string().uuid(), employeeCode: z.string().trim().min(1, 'Enter an employee code').max(30), gender: z.enum(['male', 'female']), cnic: z.string().trim().max(15) });

export async function hire(input: unknown): Promise<Result> {
  const p = hireSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('hire_applicant', { p_application_id: p.data.applicationId, p_employee_code: p.data.employeeCode, p_gender: p.data.gender, p_cnic: p.data.cnic || undefined });
  return finish(error);
}
