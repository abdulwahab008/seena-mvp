'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { compareStock, type AuditResult } from '@/lib/library-stock-audit';

const schema = z.object({
  campusId: z.string().uuid(),
  scanned: z.string().max(200_000),
  shelf: z.string().trim().max(50).optional(),
});

export async function runStockAudit(input: z.input<typeof schema>): Promise<{ error: string | null; result?: AuditResult }> {
  const p = schema.safeParse(input);
  if (!p.success) return { error: 'Check the form.' };
  const scanned = p.data.scanned.split(/[\s,;]+/).filter(Boolean);
  if (scanned.length === 0) return { error: 'Scan at least one barcode.' };

  const supabase = await supabaseServer();
  let query = supabase.from('library_copy').select('barcode, status, accession_no, shelf, title:title_id(title)').eq('campus_id', p.data.campusId);
  if (p.data.shelf) query = query.eq('shelf', p.data.shelf);
  const { data, error } = await query.limit(20000);
  if (error) return { error: 'Could not read the copy register.' };

  const copies = (data ?? []).map((c) => ({
    barcode: c.barcode,
    status: c.status,
    accession_no: c.accession_no,
    shelf: c.shelf,
    title: (Array.isArray(c.title) ? c.title[0] : c.title)?.title ?? '',
  }));
  return { error: null, result: compareStock(scanned, copies) };
}
