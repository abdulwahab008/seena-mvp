'use server';

import { revalidatePath } from 'next/cache';
import { collectionReportSchema, finaliseCashBookDaySchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ReportDay = { value_date: string; by_mode: Record<string, { count: number; amount_paisa: number }>; day_total_paisa: number };
export type ReportResult = { error: string | null; grandTotalPaisa?: number; byDay?: ReportDay[] };

type ReportResponse = { grand_total_paisa: number; by_day: ReportDay[] };

// FR-K29: pulls the same jsonb payload a future PDF/XLSX exporter would
// consume — see the migration header for why there's no exporter yet.
export async function buildCollectionReport(_prev: ReportResult, formData: FormData): Promise<ReportResult> {
  const parsed = collectionReportSchema.safeParse({
    campusId: formData.get('campusId'),
    from: formData.get('from'),
    to: formData.get('to'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  // FR-A12 AC2: '' is the "All campuses" filter option — omitting
  // p_campus_id entirely lets it fall to the RPC's own `default null`,
  // which means "aggregate across every campus in my scope".
  const { data, error } = await supabase.rpc('build_collection_report_payload', {
    p_campus_id: parsed.data.campusId || undefined,
    p_from: parsed.data.from,
    p_to: parsed.data.to,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to view collection reports.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    return { error: 'Could not build the report.' };
  }

  const result = data as ReportResponse;
  return { error: null, grandTotalPaisa: result.grand_total_paisa, byDay: result.by_day };
}

export type FinaliseResult = {
  error: string | null;
  openingPaisa?: number;
  receiptsPaisa?: number;
  disbursementsPaisa?: number;
  closingPaisa?: number;
};

type CashBookDayResponse = {
  opening_paisa: number;
  receipts_paisa: number;
  disbursements_paisa: number;
  closing_paisa: number;
};

// FR-K29: closes a day's cash book. Refuses to run twice for the same
// day — see finalise_cash_book_day()'s own comment for why a signed-off
// day must never be rewritten.
export async function finaliseCashBookDay(_prev: FinaliseResult, formData: FormData): Promise<FinaliseResult> {
  const parsed = finaliseCashBookDaySchema.safeParse({
    campusId: formData.get('campusId'),
    bookDate: formData.get('bookDate'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('finalise_cash_book_day', {
    p_campus_id: parsed.data.campusId,
    p_book_date: parsed.data.bookDate,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to finalise the cash book.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    if (error.message.includes('ALREADY_FINALISED')) return { error: 'This day has already been finalised and cannot be redone.' };
    return { error: 'Could not finalise the cash book.' };
  }

  revalidatePath('/fees/reports');
  const result = data as CashBookDayResponse;
  return {
    error: null,
    openingPaisa: result.opening_paisa,
    receiptsPaisa: result.receipts_paisa,
    disbursementsPaisa: result.disbursements_paisa,
    closingPaisa: result.closing_paisa,
  };
}
