import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { RendererUnavailableError } from '@/lib/pdf/render';
import { MissingGlyphsError } from '@/lib/hr/render';
import { generatePayslip, PayslipError } from '@/lib/payroll/payslip-store';

export const maxDuration = 60;

/**
 * FR-L08: download one payslip. The caller's own session decides access (HR roles, or the employee
 * themself); anyone else gets 403 and the attempt is written to the audit log.
 */
export async function GET(_req: NextRequest, { params }: { params: Promise<{ lineId: string }> }) {
  const { lineId } = await params;
  const supabase = await supabaseServer();
  const { data: auth } = await supabase.auth.getUser();
  try {
    const f = await generatePayslip(supabase, supabaseServiceRole(), lineId, auth.user?.id ?? null);
    return new NextResponse(Buffer.from(f.bytes), {
      status: 200,
      headers: {
        'content-type': 'application/pdf',
        'content-disposition': `inline; filename="payslip-v${f.version}.pdf"`,
        'cache-control': 'no-store',
        'x-pdf-sha256': f.sha256,
      },
    });
  } catch (e) {
    if (e instanceof PayslipError && e.code === 'forbidden') {
      await supabase.rpc('record_payslip_denied', { p_payslip_id: lineId });
      return NextResponse.json({ error: 'Forbidden.' }, { status: 403 });
    }
    if (e instanceof PayslipError && e.code === 'run_not_locked') return NextResponse.json({ error: 'run_not_locked' }, { status: 409 });
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'No PDF renderer is available on this server.' }, { status: 503 });
    if (e instanceof MissingGlyphsError) return NextResponse.json({ error: 'The Urdu font is missing characters used in this payslip.', missing: e.missing }, { status: 422 });
    return NextResponse.json({ error: 'Could not produce the payslip.' }, { status: 500 });
  }
}
