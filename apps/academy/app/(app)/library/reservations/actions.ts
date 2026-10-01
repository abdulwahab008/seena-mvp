'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { libraryErrorMessage } from '@/lib/library';

type Result = { error: string | null };

export async function searchTitles(query: string): Promise<{ id: string; title: string; titleUr: string | null }[]> {
  if (query.trim().length < 2) return [];
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('search_library_titles', { p_query: query.trim(), p_limit: 8 });
  return (data ?? []).map((t) => ({ id: t.id, title: t.title, titleUr: t.title_ur }));
}

export async function reserveTitle(titleId: string, borrowerId?: string): Promise<Result & { position?: number }> {
  if (!z.string().uuid().safeParse(titleId).success) return { error: 'Choose a title.' };
  if (borrowerId && !z.string().uuid().safeParse(borrowerId).success) return { error: 'Choose a borrower.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('reserve_title', { p_title_id: titleId, p_borrower_id: borrowerId });
  if (error) {
    if (error.message.includes('NO_COPIES_AT_CAMPUS')) return { error: 'This campus has no copy of that title to reserve.' };
    return { error: libraryErrorMessage(error.message) };
  }
  revalidatePath('/library/reservations');
  revalidatePath('/library/titles');
  return { error: null, position: (data as unknown as { queue_position: number }).queue_position };
}

export async function cancelReservation(reservationId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(reservationId).success) return { error: 'Invalid reservation.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('cancel_reservation', { p_reservation_id: reservationId });
  if (error) return { error: libraryErrorMessage(error.message) };
  revalidatePath('/library/reservations');
  return { error: null };
}

export async function renewLoan(loanId: string): Promise<Result & { dueOn?: string }> {
  if (!z.string().uuid().safeParse(loanId).success) return { error: 'Invalid loan.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('renew_loan', { p_loan_id: loanId });
  if (error) return { error: libraryErrorMessage(error.message) };
  revalidatePath('/library/circulation');
  return { error: null, dueOn: data as unknown as string };
}
