'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { formatPkrCompact } from '@/lib/format-money';
import { libraryErrorMessage } from '@/lib/library';

export type Borrower = { id: string; role: string; name: string; detail: string; openLoans: number; outstandingPaisa: number };
export type IssueResult = { error: string | null; loan?: { title: string; dueOn: string; borrower: string; openLoans: number; maxLoans: number; accessionNo: string } };

export async function findBorrowers(query: string): Promise<{ error: string | null; borrowers: Borrower[] }> {
  const q = query.trim();
  if (q.length < 2) return { error: null, borrowers: [] };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('find_library_borrowers', { p_query: q });
  if (error) return { error: libraryErrorMessage(error.message), borrowers: [] };
  return {
    error: null,
    borrowers: (data ?? []).map((b) => ({ id: b.borrower_id, role: b.borrower_role, name: b.display_name, detail: b.detail, openLoans: b.open_loans, outstandingPaisa: Number(b.outstanding_paisa) })),
  };
}

function describe(message: string, details: string | null | undefined): string {
  if (message.includes('BORROWER_BLOCKED') && details) return libraryErrorMessage(message, `outstanding ${formatPkrCompact(Number(details))}`);
  return libraryErrorMessage(message, details);
}

export async function issueCopy(barcode: string, borrowerId: string): Promise<IssueResult> {
  if (!z.string().uuid().safeParse(borrowerId).success) return { error: 'Choose the borrower first.' };
  if (barcode.trim() === '') return { error: 'Scan the barcode.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('issue_copy', { p_barcode: barcode.trim(), p_borrower_id: borrowerId });
  if (error) return { error: describe(error.message, error.details) };
  const r = data as unknown as { title: string; due_on: string; borrower_name: string; open_loans: number; max_loans: number; accession_no: string };
  revalidatePath('/library/circulation');
  return { error: null, loan: { title: r.title, dueOn: r.due_on, borrower: r.borrower_name, openLoans: r.open_loans, maxLoans: r.max_loans, accessionNo: r.accession_no } };
}
