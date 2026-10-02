import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { buildChallanHtml, challanPayloadSchema } from '@/lib/challan/html';
import { renderPdf, RendererUnavailableError } from '@/lib/pdf/render';

// Parents download their own child's challan; staff any challan in their
// scope. Who may see it is decided in the database (portal_challan_payload),
// not here — this route only renders what the caller was allowed to read.
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) return NextResponse.json({ error: 'Invalid challan.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('portal_challan_payload', { p_challan_id: id });
  if (error) return NextResponse.json({ error: 'Challan not found.' }, { status: 404 });
  const payload = challanPayloadSchema.safeParse(data);
  if (!payload.success) return NextResponse.json({ error: 'Challan data is incomplete.' }, { status: 500 });

  try {
    const pdf = await renderPdf({ html: buildChallanHtml(payload.data), pageFormat: 'A4', landscape: false });
    return new NextResponse(new Uint8Array(pdf), {
      headers: {
        'content-type': 'application/pdf',
        'content-disposition': `attachment; filename="challan-${payload.data.challan_no}.pdf"`,
        'cache-control': 'private, no-store',
      },
    });
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'PDF rendering is unavailable right now. Use the printable slip.' }, { status: 503 });
    throw e;
  }
}
