'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { donationSchema, donorSchema, sponsorshipSchema } from './schema';

type Result = { error: string | null };
const paisa = (rupees: string) => Math.round(Number(rupees) * 100);

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only the accountant or owner can do this.';
  if (m.includes('DATE_INVALID')) return 'The date cannot be in the future.';
  if (m.includes('NOT_FOUND')) return 'Check the donor and the student.';
  return 'Something went wrong. Try again.';
}

async function done(error: { message: string } | null): Promise<Result> {
  if (error) return { error: message(error.message) };
  revalidatePath('/fees/donors');
  return { error: null };
}

export async function addDonor(input: unknown): Promise<Result> {
  const p = donorSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_donor', { p_name: p.data.name, p_phone: p.data.phone });
  return done(error);
}

export async function addDonation(input: unknown): Promise<Result> {
  const p = donationSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('record_donation', {
    p_donor_id: p.data.donorId, p_amount_paisa: paisa(p.data.amount), p_received_on: p.data.receivedOn,
    p_mode: p.data.mode, p_purpose: p.data.purpose, p_reference: p.data.reference,
  });
  return done(error);
}

export async function addSponsorship(input: unknown): Promise<Result> {
  const p = sponsorshipSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: student } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber).is('deleted_at', null).maybeSingle();
  if (!student) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('save_sponsorship', { p_donor_id: p.data.donorId, p_student_id: student.id, p_monthly_paisa: paisa(p.data.monthly) });
  return done(error);
}

export async function endSponsorship(id: string): Promise<Result> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid sponsorship.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('end_sponsorship', { p_id: id });
  return done(error);
}

export async function applySponsorships(month: string): Promise<{ error: string | null; paid?: number; totalPaisa?: number }> {
  if (!/^\d{4}-\d{2}$/.test(month)) return { error: 'Choose a month.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('apply_sponsorships', { p_month: `${month}-01` });
  if (error) return { error: message(error.message) };
  revalidatePath('/fees/donors');
  const r = data as { paid: number; total_paisa: number };
  return { error: null, paid: r.paid, totalPaisa: r.total_paisa };
}
