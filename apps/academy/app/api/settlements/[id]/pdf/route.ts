import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { RendererUnavailableError } from '@/lib/pdf/render';
import { renderHrPdf, MissingGlyphsError } from '@/lib/hr/render';
import { buildStatementDocument, type StatementData } from '@/lib/settlements/statement';
import { collectHrDocumentStrings } from '@/lib/hr/print';
import { getOrRenderSealedPdf, type PdfResult } from '@/lib/hr/pdf-store';

export const maxDuration = 60;

/**
 * FR-D17 (render-settlement-pdf): the only way a settlement statement leaves the system. Access is
 * decided by the caller's own session (settlement RLS: Accountant, HR, Owner); the bytes are then
 * served from - or, the first time, rendered into - the private staff-settlements bucket with the
 * service role, and sealed with their SHA-256.
 */
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();

  const { data: s } = await supabase
    .from('staff_settlement')
    .select('id, tenant_id, exit_id, version, status, net_payable_paisa, approved_at, approved_by, pdf_storage_path, pdf_sha256')
    .eq('id', id)
    .maybeSingle();
  if (!s) return NextResponse.json({ error: 'Settlement not found.' }, { status: 404 });
  if (s.status === 'draft') return NextResponse.json({ error: 'Only an approved settlement has a PDF.' }, { status: 409 });

  const admin = supabaseServiceRole();
  const storagePath = `${s.tenant_id}/${s.id}.pdf`;

  let result: PdfResult;
  try {
    result = await getOrRenderSealedPdf({ pdfStoragePath: s.pdf_storage_path, pdfSha256: s.pdf_sha256 }, storagePath, {
    download: async (path) => {
      const { data } = await admin.storage.from('staff-settlements').download(path);
      return data ? new Uint8Array(await data.arrayBuffer()) : null;
    },
    upload: async (path, bytes) => {
      const { error } = await admin.storage.from('staff-settlements').upload(path, bytes, { contentType: 'application/pdf', upsert: false });
      return !error;
    },
    seal: async (path, sha256) => {
      const { error } = await admin.rpc('store_settlement_pdf', { p_settlement_id: s.id, p_storage_path: path, p_sha256: sha256 });
      return !error;
    },
    reload: async () => {
      const { data } = await admin.from('staff_settlement').select('pdf_storage_path, pdf_sha256').eq('id', s.id).single();
      return { pdfStoragePath: data?.pdf_storage_path ?? null, pdfSha256: data?.pdf_sha256 ?? null };
    },
    render: async () => {
      const [{ data: lines }, { data: exit }, { data: tenant }, { data: approver }] = await Promise.all([
        supabase.from('staff_settlement_line').select('line_type, description, amount_paisa, sign, sort_order').eq('settlement_id', s.id).order('sort_order'),
        supabase.from('staff_exit').select('exit_type, notice_date, last_working_date, staff:staff_id(full_name, employee_code)').eq('id', s.exit_id).single(),
        supabase.from('tenant').select('name, name_ur').eq('id', s.tenant_id).single(),
        s.approved_by ? supabase.from('app_user').select('full_name').eq('user_id', s.approved_by).maybeSingle() : Promise.resolve({ data: null }),
      ]);
      const staff = Array.isArray(exit?.staff) ? exit?.staff[0] : exit?.staff;
      const data: StatementData = {
        schoolName: tenant?.name ?? '',
        schoolNameUr: tenant?.name_ur ?? null,
        staffName: staff?.full_name ?? '',
        employeeCode: staff?.employee_code ?? '',
        exitType: exit?.exit_type ?? '',
        noticeDate: exit?.notice_date ?? null,
        lastWorkingDate: exit?.last_working_date ?? '',
        version: s.version,
        approvedAt: s.approved_at,
        approvedByName: approver?.full_name ?? null,
        lines: (lines ?? []).map((l) => ({ lineType: l.line_type, description: l.description, amountPaisa: Number(l.amount_paisa), sign: l.sign === -1 ? -1 : 1 })),
        netPayablePaisa: Number(s.net_payable_paisa),
      };
      const strings = collectHrDocumentStrings({ title: 'Final Settlement Statement', schoolName: data.schoolName, schoolNameUr: data.schoolNameUr, bodyHtml: data.lines.map((l) => l.description).join(' ') });
      return renderHrPdf((font) => buildStatementDocument(data, font), strings, new Date(s.approved_at ?? Date.now()));
    },
  });
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'No PDF renderer is available on this server.' }, { status: 503 });
    if (e instanceof MissingGlyphsError) return NextResponse.json({ error: 'The Urdu font is missing characters used in this document.', missing: e.missing }, { status: 422 });
    return NextResponse.json({ error: 'Could not produce the statement.' }, { status: 500 });
  }

  if (result.status === 'missing') return NextResponse.json({ error: 'The stored statement is missing.' }, { status: 404 });
  if (result.status === 'tampered') {
    return NextResponse.json(
      { error: 'This statement has been altered since it was approved and cannot be downloaded.', expectedSha256: result.expected, observedSha256: result.observed },
      { status: 409, headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' } },
    );
  }
  return new NextResponse(Buffer.from(result.bytes), {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="settlement-${s.id}.pdf"`,
      'cache-control': 'no-store',
      'x-pdf-sha256': result.sha256,
      'x-pdf-source': result.status,
    },
  });
}
