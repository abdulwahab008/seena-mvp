import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { CHALLAN_CSS, challanCopiesHtml, challanPayloadSchema } from '@/lib/challan/html';
import { renderPdf, RendererUnavailableError } from '@/lib/pdf/render';

export const maxDuration = 300;

const MAX_CHALLANS = 400;
const query = z.object({ campus: z.string().uuid(), period: z.string().regex(/^\d{4}-\d{2}-01$/) });

// Audit BUG-09: one print-ready file of every challan a campus generated for a billing month,
// one A4 page (bank, school and student copies) per challan. Access is the caller's own: the
// challan list is read under RLS and each page comes from portal_challan_payload().
export async function GET(req: NextRequest) {
  const parsed = query.safeParse({ campus: req.nextUrl.searchParams.get('campus'), period: req.nextUrl.searchParams.get('period') });
  if (!parsed.success) return NextResponse.json({ error: 'Choose a campus and billing month.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data: rows, error } = await supabase
    .from('fee_challan')
    .select('id')
    .eq('campus_id', parsed.data.campus)
    .eq('billing_period', parsed.data.period)
    .is('deleted_at', null)
    .order('challan_no')
    .limit(MAX_CHALLANS + 1);
  if (error) return NextResponse.json({ error: 'Could not read the challans.' }, { status: 500 });
  if (!rows || rows.length === 0) return NextResponse.json({ error: 'No challans for that month.' }, { status: 404 });
  if (rows.length > MAX_CHALLANS) return NextResponse.json({ error: `More than ${MAX_CHALLANS} challans; print by section.` }, { status: 413 });

  const pages: string[] = [];
  for (const r of rows) {
    const { data } = await supabase.rpc('portal_challan_payload', { p_challan_id: r.id });
    const payload = challanPayloadSchema.safeParse(data);
    if (payload.success) pages.push(`<div class="challan-page">${challanCopiesHtml(payload.data)}</div>`);
  }
  if (pages.length === 0) return NextResponse.json({ error: 'No printable challans.' }, { status: 404 });

  const html = `<!doctype html><html><head><meta charset="utf-8"><title>Challans ${parsed.data.period}</title>
<style>${CHALLAN_CSS}
.challan-page { break-after: page; }
.challan-page:last-child { break-after: auto; }</style></head><body>${pages.join('')}</body></html>`;
  try {
    const pdf = await renderPdf({ html, pageFormat: 'A4', landscape: false });
    return new NextResponse(new Uint8Array(pdf), {
      headers: {
        'content-type': 'application/pdf',
        'content-disposition': `attachment; filename="challans-${parsed.data.period.slice(0, 7)}.pdf"`,
        'cache-control': 'private, no-store',
      },
    });
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'PDF rendering is unavailable right now.' }, { status: 503 });
    throw e;
  }
}
