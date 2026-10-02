import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-T09 AC2: the only way an issued certificate leaves this system.
 *
 * Certificates used to be handed out as raw signed bucket URLs, which is a
 * path that cannot check anything — the bytes go straight from storage to
 * the browser. This handler stands in the middle: it fetches the object as
 * the signed-in user (so FR-T03's storage policies and certificate_issue's
 * RLS are still exactly what decides who may read it), re-hashes what came
 * back, and compares against the digest sealed onto the register row at
 * issue.
 *
 *   * equal — the bytes are served, and the digest goes out in a header so
 *     the recipient can repeat the check themselves,
 *   * not equal — HTTP 409, NO bytes, and a security_event row naming both
 *     digests. A conflict is the honest status: what is stored is no longer
 *     the document the register says was issued.
 *
 * The alert is written BEFORE the error is returned and nothing raises, so
 * unlike FR-T08's delete-denial trigger there is no rollback to work around
 * — the INSERT is its own committed statement and the 409 is just a return
 * value.
 *
 * A row with no digest at all is 'unverifiable', not a mismatch: it predates
 * this FR, and refusing to serve a document because the tamper check did not
 * exist when it was issued would be inventing a forgery rather than catching
 * one. It is served with the header saying so.
 */

export async function GET(_request: NextRequest, { params }: { params: Promise<{ issueId: string }> }) {
  const { issueId } = await params;
  const supabase = await supabaseServer();

  const { data: issue } = await supabase
    .from('certificate_issue')
    .select('id, serial_no, certificate_type, status, pdf_path, pdf_sha256')
    .eq('id', issueId)
    .maybeSingle();
  if (!issue) return NextResponse.json({ error: 'Certificate not found.' }, { status: 404 });

  const { data: blob } = await supabase.storage.from('certificates').download(issue.pdf_path);
  if (!blob) {
    // A voided issue never had its bytes uploaded; anything else is a
    // document that has gone missing, which is itself worth saying plainly.
    return NextResponse.json(
      { error: 'The document for this certificate is not in storage.', serialNo: issue.serial_no, status: issue.status },
      { status: 404 },
    );
  }

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const verdict = verifyPdfDigest(bytes, issue.pdf_sha256);

  if (verdict.status === 'mismatch') {
    await supabase.rpc('log_certificate_digest_mismatch', {
      p_issue_id: issue.id,
      p_observed_sha256: verdict.observed,
      p_observed_bytes: verdict.bytes,
    });

    return NextResponse.json(
      {
        error: 'This certificate has been altered since it was issued and cannot be downloaded.',
        serialNo: issue.serial_no,
        expectedSha256: verdict.expected,
        observedSha256: verdict.observed,
      },
      {
        status: 409,
        headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' },
      },
    );
  }

  const fileName = `${issue.certificate_type}-${issue.serial_no.replace(/\//g, '-')}.pdf`;
  return new NextResponse(bytes, {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="${fileName}"`,
      'cache-control': 'no-store',
      'x-pdf-digest-status': verdict.status,
      'x-pdf-sha256': verdict.observed,
    },
  });
}
