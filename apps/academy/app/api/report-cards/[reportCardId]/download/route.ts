import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-J09: the only way an issued report card leaves this system.
 *
 * The FR's Supabase Objects ask for 30-day signed bucket URLs. This handler
 * replaces them for FR-T09's reason: a signed URL sends bytes straight from
 * storage to the browser and can check nothing, which would make the checksum
 * on the register a number nobody ever compares against. Here the object is
 * fetched AS THE SIGNED-IN USER — so report_card's RLS (including FR-J08's
 * withhold anti-join for a parent) and the bucket's own read policy are still
 * exactly what decide who may read it — re-hashed, and compared against the
 * digest sealed at issue.
 *
 * A mismatch is 409 and no bytes. Unlike FR-T09 it does NOT write a
 * security_event: a certificate is a statutory document with no successor, so
 * a mismatch there is a forgery signal a registrar must act on; a report card
 * has a documented remedy — issue the next revision — so the honest response
 * is to refuse the stale bytes and name both digests, not to raise an alert
 * nobody has an action for.
 *
 * A row with no checksum is 'unverifiable' rather than a mismatch, and can
 * only be a card that was still 'pending' when it was asked for.
 */

export async function GET(_request: NextRequest, { params }: { params: Promise<{ reportCardId: string }> }) {
  const { reportCardId } = await params;
  const supabase = await supabaseServer();

  const { data: card } = await supabase
    .from('report_card')
    .select('id, revision_no, status, storage_path, checksum, enrolment_id, exam_term_id')
    .eq('id', reportCardId)
    .maybeSingle();
  if (!card) return NextResponse.json({ error: 'Report card not found.' }, { status: 404 });

  const { data: blob } = await supabase.storage.from('report-cards').download(card.storage_path);
  if (!blob) {
    return NextResponse.json(
      { error: 'The document for this report card is not in storage.', revisionNo: card.revision_no, status: card.status },
      { status: 404 },
    );
  }

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const verdict = verifyPdfDigest(bytes, card.checksum);

  if (verdict.status === 'mismatch') {
    return NextResponse.json(
      {
        error: 'This report card has been altered since it was issued and cannot be downloaded.',
        revisionNo: card.revision_no,
        expectedSha256: verdict.expected,
        observedSha256: verdict.observed,
      },
      { status: 409, headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' } },
    );
  }

  return new NextResponse(bytes, {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="report-card-r${card.revision_no}.pdf"`,
      'cache-control': 'no-store',
      'x-pdf-digest-status': verdict.status,
      'x-pdf-sha256': verdict.observed,
      'x-report-card-revision': String(card.revision_no),
    },
  });
}
