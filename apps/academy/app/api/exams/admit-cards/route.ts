import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { admitCardBatchSchema, buildAdmitCardsHtml } from '@/lib/exams/admit-card-html';
import { renderPdf, RendererUnavailableError } from '@/lib/pdf/render';

const QuerySchema = z.object({ termId: z.string().uuid(), sectionId: z.string().uuid() });

// admit_card_batch() decides who may print and for which campus; this route only renders.
export async function GET(req: NextRequest) {
  const q = QuerySchema.safeParse(Object.fromEntries(req.nextUrl.searchParams));
  if (!q.success) return NextResponse.json({ error: 'Choose a term and a section.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('admit_card_batch', { p_exam_term_id: q.data.termId, p_section_id: q.data.sectionId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return NextResponse.json({ error: 'Not allowed.' }, { status: 403 });
    if (error.message.includes('DATESHEET_NOT_PUBLISHED')) return NextResponse.json({ error: 'Publish the datesheet first.' }, { status: 409 });
    return NextResponse.json({ error: 'Term or section not found.' }, { status: 404 });
  }
  const batch = admitCardBatchSchema.safeParse(data);
  if (!batch.success) return NextResponse.json({ error: 'Admit card data is incomplete.' }, { status: 500 });
  if (batch.data.students.length === 0) return NextResponse.json({ error: 'No students in this section.' }, { status: 404 });

  const { data: section } = await supabase.from('class_section').select('campus:campus_id(name)').eq('id', q.data.sectionId).maybeSingle();
  const campus = Array.isArray(section?.campus) ? section?.campus[0] : section?.campus;

  try {
    const pdf = await renderPdf({ html: buildAdmitCardsHtml(batch.data, campus?.name ?? ''), pageFormat: 'A4', landscape: false });
    return new NextResponse(new Uint8Array(pdf), {
      headers: { 'content-type': 'application/pdf', 'content-disposition': 'inline; filename="admit-cards.pdf"', 'cache-control': 'private, no-store' },
    });
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'PDF rendering is unavailable right now.' }, { status: 503 });
    throw e;
  }
}
