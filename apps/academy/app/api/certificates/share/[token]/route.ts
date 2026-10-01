import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyPdfDigest } from '@/lib/certificates/seal';

/**
 * FR-T06: the link a guardian opens from WhatsApp.
 *
 * It must work in WhatsApp's in-app browser with no login, so it is an opaque
 * random token (stored only as a hash, valid 7 days) rather than a portal
 * redirect. The token is resolved in the database; the PDF is read with the
 * service role because the caller carries no session at all. The stored bytes
 * are re-hashed against the digest sealed at issue (FR-T09) exactly as the
 * authenticated download route does, so a tampered file is never served.
 *
 * An unknown, expired or revoked token gets one generic 404: nothing says which.
 */
export async function GET(_request: NextRequest, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const notFound = () => NextResponse.json({ error: 'This link is not valid or has expired.' }, { status: 404, headers: { 'cache-control': 'no-store' } });
  if (!/^[A-Za-z0-9_-]{20,64}$/.test(token)) return notFound();

  const admin = supabaseServiceRole();
  const { data: link } = await admin.rpc('resolve_certificate_share_link', { p_token: token });
  const resolved = link as unknown as { pdf_path: string; serial_no: string; pdf_sha256: string | null } | null;
  if (!resolved) return notFound();

  const { data: blob } = await admin.storage.from('certificates').download(resolved.pdf_path);
  if (!blob) return notFound();
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const verdict = verifyPdfDigest(bytes, resolved.pdf_sha256);
  if (verdict.status === 'mismatch') {
    return NextResponse.json({ error: 'This certificate cannot be shown. Please contact the school office.' }, { status: 409, headers: { 'cache-control': 'no-store' } });
  }

  return new NextResponse(bytes, {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="bonafide-${resolved.serial_no.replace(/\//g, '-')}.pdf"`,
      'cache-control': 'private, no-store',
    },
  });
}
