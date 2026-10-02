import type { supabaseServer } from '@/lib/supabase/server';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont, type ResolvedFont } from '@/lib/pdf/font';
import {
  RendererUnavailableError,
  pdfPageCount,
  renderPdf,
  stampPdfTimestamps,
  type PrintDocument,
} from '@/lib/pdf/render';
import { sha256Hex } from '@/lib/certificates/seal';
import { CHALLAN_CSS, challanCopiesHtml, challanPayloadSchema, escapeHtml, type ChallanPayload } from '@/lib/challan/html';
import {
  collectReportCardStrings,
  reportCardBodyHtml,
  reportCardCss,
  type ReportCardAssets,
  type ReportCardSnapshot,
} from './html';
import { reportCardAssets } from './render';

/**
 * FR-J11: the report card followed by the next cycle's 3-copy challan, one PDF.
 *
 * The render half of the "render-report-card-packet" the FR names. The
 * database reserves the row and the storage path (begin_report_card_packet);
 * this module renders, uploads and seals (attach_report_card_packet) — the
 * order FR-J09 settled on, for FR-J09's reason: Postgres cannot make a PDF.
 *
 * Nothing in here computes a fee. The challan section is
 * challanCopiesHtml(payload) — the same function the standalone challan PDF
 * prints — over the payload app.fn_challan_payload() produced, so the amount
 * on the second page is the fee module's, to the paisa. If a challan was not
 * generated the payload is null and the packet is the card alone.
 */
type ServerClient = Awaited<ReturnType<typeof supabaseServer>>;

export type ReservedPacket = {
  packet_id: string;
  report_card_id: string;
  challan_id: string | null;
  with_challan: boolean;
  payable_paisa: number | null;
  storage_path: string;
  snapshot: ReportCardSnapshot;
  challan: unknown;
};

export type StoredPacket = {
  error: string | null;
  packetId?: string;
  withChallan?: boolean;
  downloadUrl?: string;
  checksum?: string;
  pageCount?: number;
};

/** The challan's own @page rule would fight the card's margins; the card wins. */
const challanCssWithoutPage = () => CHALLAN_CSS.replace(/@page\s*\{[^}]*\}/, '').replace(/body\s*\{[^}]*\}/, '');

const packetCss = `
.card { position: relative; }
.card .stamp { position: absolute; }
.challan-page { break-before: page; page-break-before: always; font: 11px/1.4 system-ui, sans-serif; color: #111; }
.challan-page h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.3mm; color: #444; margin: 0 0 2mm; }`;

export function packetDownloadPath(packetId: string): string {
  return `/api/report-card-packets/${packetId}/download`;
}

/** The document, from the snapshot and the challan payload and nothing else. */
export function buildReportCardPacketHtml(
  snapshot: ReportCardSnapshot,
  challan: ChallanPayload | null,
  font: ResolvedFont | null,
  assets: ReportCardAssets,
): PrintDocument {
  const challanPage = challan
    ? `<section class="challan-page" data-challan-page><h2>Fee challan — ${escapeHtml(challan.billing_period)}</h2>${challanCopiesHtml(challan)}</section>`
    : '';
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(snapshot.student.name_en)} — ${escapeHtml(snapshot.term.name)}</title><style>${reportCardCss(font)}${packetCss}${challan ? challanCssWithoutPage() : ''}</style></head><body>
<section class="card" data-report-card>${reportCardBodyHtml(snapshot, assets)}</section>
${challanPage}
</body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}

export async function renderAndStorePacket(supabase: ServerClient, reserved: ReservedPacket): Promise<StoredPacket> {
  let challan: ChallanPayload | null = null;
  if (reserved.challan) {
    const parsed = challanPayloadSchema.safeParse(reserved.challan);
    if (!parsed.success) return { error: 'The challan data is incomplete, so no packet was produced.' };
    challan = parsed.data;
  }

  const font = resolveNastaliqFont();
  const coverage = font ? checkGlyphCoverage(collectReportCardStrings(reserved.snapshot), parseCmapRanges(font.bytes)) : null;
  if (coverage && coverage.missing.length > 0) {
    return { error: `The packet cannot be typeset — ${coverage.missing.length} character(s) are missing from the Urdu font.` };
  }

  const doc = buildReportCardPacketHtml(reserved.snapshot, challan, font, await reportCardAssets(supabase, reserved.snapshot));

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    return {
      error:
        cause instanceof RendererUnavailableError
          ? 'No PDF renderer is available on this server, so no packet was produced.'
          : 'The packet could not be rendered.',
    };
  }
  const bytes = stampPdfTimestamps(new Uint8Array(pdf), new Date(reserved.snapshot.rendered_at));

  // upsert: re-assembling after a challan was generated replaces the object
  // under the same path (the packet is a convenience copy; the sealed card and
  // the fee module's challan are the records).
  const { error: uploadError } = await supabase.storage
    .from('report-cards')
    .upload(reserved.storage_path, bytes, { contentType: 'application/pdf', upsert: true });
  if (uploadError) return { error: 'The packet could not be stored.' };

  const { data: stored } = await supabase.storage.from('report-cards').download(reserved.storage_path);
  if (!stored) return { error: 'The stored packet could not be read back.' };
  const storedBytes = new Uint8Array(await stored.arrayBuffer());
  const checksum = sha256Hex(storedBytes);
  if (checksum !== sha256Hex(bytes)) return { error: 'The stored packet does not match what was rendered.' };

  const { error: sealError } = await supabase.rpc('attach_report_card_packet', {
    p_packet_id: reserved.packet_id,
    p_sha256: checksum,
  });
  if (sealError) return { error: 'The packet could not be sealed.' };

  return {
    error: null,
    packetId: reserved.packet_id,
    withChallan: reserved.with_challan,
    downloadUrl: packetDownloadPath(reserved.packet_id),
    checksum,
    pageCount: pdfPageCount(storedBytes),
  };
}
