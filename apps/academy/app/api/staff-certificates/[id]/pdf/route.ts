import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { RendererUnavailableError } from '@/lib/pdf/render';
import { renderHrPdf, MissingGlyphsError } from '@/lib/hr/render';
import { getOrRenderSealedPdf, type PdfResult } from '@/lib/hr/pdf-store';
import { buildCertificateDocument, certificateStrings, type StaffCertificatePayload } from '@/lib/staff-certificates/document';

export const maxDuration = 60;

/**
 * FR-D18 (render-staff-certificate): print or reprint an issued certificate. Access is the caller's own
 * session (certificate RLS: HR, Principal, Owner, or the staff member themselves). The PDF is rendered
 * from the payload snapshot the first time, with the Noto Nastaliq face embedded for the Urdu school
 * name, then stored and sealed; every later request serves the stored bytes. A reprint never touches
 * the numbering counter.
 */
export async function GET(_req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: c } = await supabase
    .from('staff_certificate')
    .select('id, tenant_id, certificate_no, payload, issued_at, storage_path, pdf_sha256')
    .eq('id', id)
    .maybeSingle();
  if (!c) return NextResponse.json({ error: 'Certificate not found.' }, { status: 404 });

  const admin = supabaseServiceRole();
  const path = `${c.tenant_id}/${c.id}.pdf`;
  const payload = c.payload as unknown as StaffCertificatePayload;

  let result: PdfResult;
  try {
    result = await getOrRenderSealedPdf({ pdfStoragePath: c.storage_path, pdfSha256: c.pdf_sha256 }, path, {
      download: async (p) => {
        const { data } = await admin.storage.from('staff-certificates').download(p);
        return data ? new Uint8Array(await data.arrayBuffer()) : null;
      },
      upload: async (p, bytes) => {
        const { error } = await admin.storage.from('staff-certificates').upload(p, bytes, { contentType: 'application/pdf', upsert: false });
        return !error;
      },
      seal: async (p, sha256) => {
        const { error } = await admin.rpc('store_staff_certificate_pdf', { p_certificate_id: c.id, p_storage_path: p, p_sha256: sha256 });
        return !error;
      },
      reload: async () => {
        const { data } = await admin.from('staff_certificate').select('storage_path, pdf_sha256').eq('id', c.id).single();
        return { pdfStoragePath: data?.storage_path ?? null, pdfSha256: data?.pdf_sha256 ?? null };
      },
      render: () => renderHrPdf((font) => buildCertificateDocument(payload, font), certificateStrings(payload), new Date(c.issued_at)),
    });
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'No PDF renderer is available on this server.' }, { status: 503 });
    if (e instanceof MissingGlyphsError) return NextResponse.json({ error: 'The Urdu font is missing characters used in this certificate.', missing: e.missing }, { status: 422 });
    return NextResponse.json({ error: 'Could not produce the certificate.' }, { status: 500 });
  }

  if (result.status === 'missing') return NextResponse.json({ error: 'The stored certificate is missing.' }, { status: 404 });
  if (result.status === 'tampered') {
    return NextResponse.json(
      { error: 'This certificate has been altered since it was issued and cannot be downloaded.', expectedSha256: result.expected, observedSha256: result.observed },
      { status: 409, headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' } },
    );
  }
  return new NextResponse(Buffer.from(result.bytes), {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="${c.certificate_no}.pdf"`,
      'cache-control': 'no-store',
      'x-pdf-sha256': result.sha256,
      'x-pdf-source': result.status,
    },
  });
}
