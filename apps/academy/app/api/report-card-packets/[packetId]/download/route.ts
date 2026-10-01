import { NextResponse, type NextRequest } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-J11: the only way an assembled packet leaves this system.
 *
 * The FR's bucket is private and the packet is fetched AS THE SIGNED-IN USER,
 * so report_card_packet's RLS — including the parent anti-join that hides a
 * withheld child's packet — and the bucket's read policy decide who may read
 * it. The bytes are re-hashed against the digest sealed at assembly and a
 * mismatch is a 409 with no bytes, the same stance the report card download
 * takes.
 */
export async function GET(_request: NextRequest, { params }: { params: Promise<{ packetId: string }> }) {
  const { packetId } = await params;
  if (!z.string().uuid().safeParse(packetId).success) return NextResponse.json({ error: 'Invalid packet.' }, { status: 400 });
  const supabase = await supabaseServer();

  const { data: packet } = await supabase
    .from('report_card_packet')
    .select('id, storage_path, checksum, assembled_at, enrolment_id')
    .eq('id', packetId)
    .maybeSingle();
  if (!packet || !packet.assembled_at) return NextResponse.json({ error: 'Packet not found.' }, { status: 404 });

  const { data: blob } = await supabase.storage.from('report-cards').download(packet.storage_path);
  if (!blob) return NextResponse.json({ error: 'The packet is not in storage.' }, { status: 404 });

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const verdict = verifyPdfDigest(bytes, packet.checksum);
  if (verdict.status === 'mismatch') {
    return NextResponse.json(
      { error: 'This packet has changed since it was assembled. Assemble it again.', expectedSha256: verdict.expected, observedSha256: verdict.observed },
      { status: 409, headers: { 'x-pdf-digest-status': 'mismatch', 'cache-control': 'no-store' } },
    );
  }
  return new NextResponse(bytes, {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="report-card-packet-${packet.id}.pdf"`,
      'cache-control': 'no-store',
      'x-pdf-digest-status': verdict.status,
      'x-pdf-sha256': verdict.observed,
    },
  });
}
