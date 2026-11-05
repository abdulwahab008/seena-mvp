import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { RendererUnavailableError } from '@/lib/pdf/render';
import { MissingGlyphsError } from '@/lib/hr/render';
import { generatePayslip } from '@/lib/payroll/payslip-store';

export const maxDuration = 300;

/** FR-L08: render a payslip for every employee on a locked run. A run still in draft returns 409 and writes nothing. */
export async function POST(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: lines, error } = await supabase.rpc('payslip_run_lines', { p_run_id: id });
  if (error) {
    if (error.message.includes('run_not_locked')) return NextResponse.json({ error: 'run_not_locked' }, { status: 409 });
    if (error.message.includes('RUN_NOT_FOUND')) return NextResponse.json({ error: 'Run not found.' }, { status: 404 });
    if (error.message.includes('FORBIDDEN')) return NextResponse.json({ error: 'Forbidden.' }, { status: 403 });
    return NextResponse.json({ error: 'Could not list the run.' }, { status: 500 });
  }

  const { data: auth } = await supabase.auth.getUser();
  const admin = supabaseServiceRole();
  let created = 0;
  try {
    for (const l of lines ?? []) {
      const f = await generatePayslip(supabase, admin, l.line_id, auth.user?.id ?? null);
      if (f.created) created += 1;
    }
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'No PDF renderer is available on this server.' }, { status: 503 });
    if (e instanceof MissingGlyphsError) return NextResponse.json({ error: 'The Urdu font is missing characters used in a payslip.', missing: e.missing }, { status: 422 });
    return NextResponse.json({ error: 'Could not produce the payslips.' }, { status: 500 });
  }
  return NextResponse.json({ total: lines?.length ?? 0, created });
}
