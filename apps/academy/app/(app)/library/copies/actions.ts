'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { libraryCopySchema, type LibraryCopyInput } from '@/lib/validation';
import { libraryErrorMessage, parseCopyCsv, pkrToPaisa } from '@/lib/library';
import { parseCsv } from '@/lib/student-import';

type Result = { error: string | null };

export async function registerCopy(input: LibraryCopyInput): Promise<Result> {
  const p = libraryCopySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('register_library_copy', {
    p_title_id: p.data.titleId,
    p_campus_id: p.data.campusId,
    p_accession_no: p.data.accessionNo,
    p_barcode: p.data.barcode,
    p_shelf: p.data.shelf || undefined,
    p_purchase_cost: pkrToPaisa(p.data.purchaseCostPkr),
    p_acquired_on: p.data.acquiredOn || undefined,
  });
  if (error) return { error: libraryErrorMessage(error.message) };
  revalidatePath('/library/copies');
  return { error: null };
}

export type ImportReport = { ok: boolean; imported: number; problems: string[] };

export async function importCopies(campusId: string, csvText: string): Promise<ImportReport> {
  if (!z.string().uuid().safeParse(campusId).success) return { ok: false, imported: 0, problems: ['Choose a campus.'] };
  const parsed = parseCopyCsv(parseCsv(csvText));
  if (parsed.errors.length > 0) {
    return { ok: false, imported: 0, problems: parsed.errors.map((e) => (e.row === 0 ? e.message : `Row ${e.row}: ${e.message}`)) };
  }
  if (parsed.rows.length === 0) return { ok: false, imported: 0, problems: ['The file has no rows.'] };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('import_library_copies', { p_campus_id: campusId, p_rows: parsed.rows });
  if (error) return { ok: false, imported: 0, problems: [error.message.includes('IMPORT_TOO_LARGE') ? 'At most 5000 rows per import.' : libraryErrorMessage(error.message)] };
  const report = data as unknown as { ok: boolean; imported: number; errors: { row: number; code: string }[] };
  if (!report.ok) {
    const text: Record<string, string> = {
      DUPLICATE_BARCODE: 'barcode is already used',
      DUPLICATE_ACCESSION: 'accession number is already used',
      MISSING_FIELD: 'accession_no and barcode are required',
      TITLE_NOT_FOUND: 'no catalogued title matches the isbn / title_id',
    };
    return { ok: false, imported: 0, problems: report.errors.map((e) => `Row ${e.row}: ${text[e.code] ?? e.code}`) };
  }
  revalidatePath('/library/copies');
  return { ok: true, imported: report.imported, problems: [] };
}

export async function setCopyStatus(copyId: string, status: 'available' | 'in_repair' | 'lost'): Promise<Result> {
  if (!z.string().uuid().safeParse(copyId).success) return { error: 'Invalid copy.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_library_copy_status', { p_copy_id: copyId, p_status: status });
  if (error) return { error: libraryErrorMessage(error.message) };
  revalidatePath('/library/copies');
  return { error: null };
}
