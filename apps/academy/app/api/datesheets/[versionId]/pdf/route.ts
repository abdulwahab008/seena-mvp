import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { buildDatesheetHtml, collectDatesheetStrings, type DatesheetPdfRow } from '@/lib/datesheet/html';
import { NASTALIQ_FONT_FAMILY, checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, embeddedFontNames, renderPdf, stampPdfTimestamps } from '@/lib/pdf/render';

/**
 * FR-I04: the PDF of one published datesheet version.
 *
 * Access is decided by the caller's own session: datesheet_version is read
 * through RLS, so a parent gets a version only when it schedules a paper of
 * their child's class and a draft has no version row at all. A version is
 * immutable, so its PDF is rendered once and cached in the private
 * "datesheets" bucket; ?format=link returns a 7-day signed URL to that file
 * (the bucket has no read policy, so the signed URL is the only way in).
 *
 * The response carries the AC4 evidence in headers: the cmap check over the
 * exact strings typeset (x-missing-glyph-count) and the font names actually
 * embedded in the produced file (x-embedded-fonts).
 */
const SEVEN_DAYS = 7 * 24 * 60 * 60;

export async function GET(request: NextRequest, { params }: { params: Promise<{ versionId: string }> }) {
  const { versionId } = await params;
  const supabase = await supabaseServer();

  const { data: version } = await supabase
    .from('datesheet_version')
    .select('id, tenant_id, campus_id, datesheet_id, version_no, note, published_at, pdf_path, datesheet:datesheet_id(title)')
    .eq('id', versionId)
    .maybeSingle();
  if (!version) return NextResponse.json({ error: 'Datesheet version not found.' }, { status: 404 });

  const wantLink = new URL(request.url).searchParams.get('format') === 'link';
  const admin = supabaseServiceRole();
  const path = `${version.tenant_id}/${version.datesheet_id}/v${version.version_no}.pdf`;

  let bytes: Uint8Array | null = null;
  let missing: string[] = [];
  let fonts: string[] = [];

  if (version.pdf_path) {
    const { data: cached } = await admin.storage.from('datesheets').download(version.pdf_path);
    if (cached) {
      bytes = new Uint8Array(await cached.arrayBuffer());
      fonts = embeddedFontNames(bytes);
    }
  }

  if (!bytes) {
    const [{ data: snapshots }, { data: campus }] = await Promise.all([
      supabase
        .from('datesheet_slot_snapshot')
        .select('class_name, subject_name_en, subject_name_ur, start_at, end_at, hall_name, change_kind, previous_start_at')
        .eq('version_id', versionId)
        .order('start_at'),
      supabase.from('campus').select('name, timezone').eq('id', version.campus_id).maybeSingle(),
    ]);
    const datesheet = Array.isArray(version.datesheet) ? version.datesheet[0] : version.datesheet;
    const payload = {
      campusName: campus?.name ?? 'Campus',
      title: datesheet?.title ?? 'Datesheet',
      versionNo: version.version_no,
      publishedAt: version.published_at,
      note: version.note,
      timezone: campus?.timezone ?? 'Asia/Karachi',
      rows: (snapshots ?? []) as DatesheetPdfRow[],
    };
    const font = resolveNastaliqFont();
    missing = font ? checkGlyphCoverage(collectDatesheetStrings(payload), parseCmapRanges(font.bytes)).missing : [];
    try {
      const pdf = await renderPdf(buildDatesheetHtml(payload, font));
      bytes = stampPdfTimestamps(new Uint8Array(pdf), new Date(version.published_at));
    } catch (cause) {
      const message = cause instanceof RendererUnavailableError ? 'No PDF renderer is available on this server.' : 'Could not render the datesheet.';
      return NextResponse.json({ error: message }, { status: 503 });
    }
    fonts = embeddedFontNames(bytes);
    const { error: uploadError } = await admin.storage.from('datesheets').upload(path, bytes, { contentType: 'application/pdf', upsert: true });
    if (!uploadError && !version.pdf_path) {
      // Only the exam office may record it; for anyone else the file is simply cached for next time.
      await supabase.rpc('record_datesheet_pdf', { p_version_id: versionId, p_path: path });
    }
  }

  if (wantLink) {
    const { data: signed, error } = await admin.storage.from('datesheets').createSignedUrl(version.pdf_path ?? path, SEVEN_DAYS);
    if (error || !signed) return NextResponse.json({ error: 'Could not create a download link.' }, { status: 502 });
    return NextResponse.json({ url: signed.signedUrl, expiresInSeconds: SEVEN_DAYS, versionNo: version.version_no });
  }

  return new NextResponse(new Uint8Array(bytes), {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="datesheet-v${version.version_no}.pdf"`,
      'cache-control': 'private, no-store',
      'x-datesheet-version': String(version.version_no),
      'x-missing-glyph-count': String(missing.length),
      'x-missing-glyphs': missing.join(','),
      'x-font-family': NASTALIQ_FONT_FAMILY,
      'x-embedded-fonts': fonts.join(','),
    },
  });
}
