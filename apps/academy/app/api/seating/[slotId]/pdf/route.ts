import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { buildSeatingChartHtml, buildSeatSlipsHtml, collectSeatingStrings, type SeatingChart } from '@/lib/exams/seating-html';
import { NASTALIQ_FONT_FAMILY, checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf } from '@/lib/pdf/render';

/**
 * FR-I09 (the render-seating-chart-pdf function): the hall map (?kind=chart,
 * the default) or one slip per candidate (?kind=slips). Rendered on demand from
 * fn_seating_chart(), as the signed-in user, so the database's own role and
 * campus checks decide who may print a plan. Nothing is stored: a plan can be
 * regenerated, and a stale PDF of one is worse than none.
 */
export async function GET(request: NextRequest, { params }: { params: Promise<{ slotId: string }> }) {
  const { slotId } = await params;
  const kind = new URL(request.url).searchParams.get('kind') === 'slips' ? 'slips' : 'chart';
  const supabase = await supabaseServer();

  const { data, error } = await supabase.rpc('fn_seating_chart', { p_slot_id: slotId });
  if (error || !data) {
    const status = error?.message.includes('FORBIDDEN') ? 403 : 404;
    return NextResponse.json({ error: 'Seating plan not available.' }, { status });
  }
  const chart = data as unknown as SeatingChart;
  if (chart.allocations.length === 0) {
    return NextResponse.json({ error: 'No seats have been allocated for this paper yet.' }, { status: 409 });
  }

  const font = resolveNastaliqFont();
  const missing = font ? checkGlyphCoverage(collectSeatingStrings(chart), parseCmapRanges(font.bytes)).missing : [];
  const doc = kind === 'slips' ? buildSeatSlipsHtml(chart, font) : buildSeatingChartHtml(chart, font);

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    const message = cause instanceof RendererUnavailableError ? 'No PDF renderer is available on this server.' : 'Could not render the seating plan.';
    return NextResponse.json({ error: message }, { status: 503 });
  }

  return new NextResponse(new Uint8Array(pdf), {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="seating-${kind}-${slotId}.pdf"`,
      'cache-control': 'private, no-store',
      'x-missing-glyph-count': String(missing.length),
      'x-font-family': font ? NASTALIQ_FONT_FAMILY : '',
      'x-seat-count': String(chart.allocations.length),
    },
  });
}
