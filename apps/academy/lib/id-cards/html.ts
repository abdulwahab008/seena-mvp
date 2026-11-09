import { code128bSvg, BarcodeError } from '@/lib/challan/barcode';
import { escapeHtml } from '@/lib/challan/html';

// Who prints cards: leadership, the front office and HR.
export const ID_CARD_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist', 'hr_manager'];

export type IdCard = {
  name: string;
  code: string;
  lines: { label: string; value: string | null }[];
};

export type IdCardSheet = {
  schoolName: string;
  logoDataUri: string | null;
  kindLabel: string;
  validUntil: string;
  cards: IdCard[];
  orientation?: 'landscape' | 'portrait';
  side?: 'front' | 'back' | 'both';
  color?: string;
};

function barcode(code: string): string {
  try {
    return code128bSvg(code, { moduleWidth: 1, height: 22 });
  } catch (e) {
    if (e instanceof BarcodeError) return '';
    throw e;
  }
}

// CR80 cards (85.6 x 54 mm): landscape 2 x 5 per A4, portrait 3 x 3, with a hairline cut border.
const CSS = (color: string) => `
@page { size: A4 portrait; margin: 10mm 12mm; }
* { box-sizing: border-box; }
body { margin: 0; font-family: 'Inter', Arial, sans-serif; color: #111; }
.sheet { display: grid; grid-template-columns: repeat(2, 85.6mm); grid-auto-rows: 54mm; gap: 4mm 6mm; }
.card { border: 0.2mm solid #999; border-radius: 3mm; overflow: hidden; display: flex; flex-direction: column; break-inside: avoid; }
.head { background: ${color}; color: #fff; padding: 1.5mm 3mm; display: flex; align-items: center; gap: 2mm; }
.head img { height: 7mm; width: 7mm; object-fit: contain; background: #fff; border-radius: 1mm; }
.head .school { font-weight: 700; font-size: 8.5pt; line-height: 1.1; }
.head .kind { font-size: 6.5pt; opacity: .85; }
.body { flex: 1; display: flex; gap: 2.5mm; padding: 2mm 3mm 0; }
.photo { width: 18mm; height: 22mm; border: 0.2mm dashed #888; font-size: 5.5pt; color: #888; display: flex; align-items: center; justify-content: center; text-align: center; flex-shrink: 0; }
.info { font-size: 7pt; line-height: 1.35; min-width: 0; }
.info .name { font-weight: 700; font-size: 8.5pt; margin-bottom: .5mm; }
.info span { color: #555; }
.foot { display: flex; align-items: flex-end; justify-content: space-between; padding: 0 3mm 1.5mm; font-size: 6pt; color: #444; }
.foot svg { height: 6mm; }
.portrait { grid-template-columns: repeat(3, 54mm); grid-auto-rows: 85.6mm; gap: 4mm 6mm; }
.portrait .head { flex-direction: column; text-align: center; padding: 2mm; }
.portrait .body { flex-direction: column; align-items: center; text-align: center; }
.portrait .foot { flex-direction: column; align-items: center; gap: 1mm; }
.back .body { display: block; font-size: 6.5pt; line-height: 1.4; padding-top: 3mm; }
.back .sign { margin-top: 6mm; border-top: 0.2mm solid #555; padding-top: .5mm; width: 30mm; font-size: 6pt; }
`;

export function buildIdCardsHtml(sheet: IdCardSheet): string {
  const logo = sheet.logoDataUri ? `<img src="${escapeHtml(sheet.logoDataUri)}" alt="">` : '';
  const side = sheet.side ?? 'front';
  const back = `<div class="card back">
  <div class="head">${logo}<div><div class="school">${escapeHtml(sheet.schoolName)}</div></div></div>
  <div class="body"><p>This card is the property of ${escapeHtml(sheet.schoolName)} and must be shown on request.</p><p>If found, please return it to the school office.</p><div class="sign">Principal</div></div>
  <div class="foot"><div>Valid until ${escapeHtml(sheet.validUntil)}</div></div>
</div>`;
  const cards = sheet.cards
    .map(
      (c) => side === 'back' ? back : `<div class="card">
  <div class="head">${logo}<div><div class="school">${escapeHtml(sheet.schoolName)}</div><div class="kind">${escapeHtml(sheet.kindLabel)}</div></div></div>
  <div class="body"><div class="photo">Photo</div><div class="info"><div class="name">${escapeHtml(c.name)}</div>${c.lines
    .filter((l) => l.value)
    .map((l) => `<div><span>${escapeHtml(l.label)}:</span> ${escapeHtml(l.value)}</div>`)
    .join('')}</div></div>
  <div class="foot"><div>Valid until ${escapeHtml(sheet.validUntil)}</div>${barcode(c.code)}</div>
</div>${side === 'both' ? back : ''}`,
    )
    .join('\n');
  return `<!doctype html><html><head><meta charset="utf-8"><style>${CSS(/^#[0-9a-f]{6}$/i.test(sheet.color ?? '') ? sheet.color! : '#1e3a8a')}</style></head><body><div class="sheet ${sheet.orientation === 'portrait' ? 'portrait' : ''}">${cards}</div></body></html>`;
}
