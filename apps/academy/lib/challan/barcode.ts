/**
 * Code 128 (subset B) as inline SVG.
 *
 * FR-K10 put `barcode_value` (exactly the challan number) on the challan
 * payload and left drawing it to "a Code-128 pipeline". FR-J11's packet is the
 * first document that has to carry one, and the encoding is small enough to
 * own: a lookup table, a checksum and a row of rects. No dependency, no font,
 * and the output is deterministic text, so the packet's bytes are too.
 *
 * Subset B covers printable ASCII (32-126), which is every character a challan
 * number is made of.
 */

// Bar/space widths for symbol values 0..106, starting with a bar. 103-105 are
// the start codes (A, B, C); 106 is the stop, which carries a 7th element.
const PATTERNS: readonly string[] = [
  '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312', '132212', '221213',
  '221312', '231212', '112232', '122132', '122231', '113222', '123122', '123221', '223211', '221132',
  '221231', '213212', '223112', '312131', '311222', '321122', '321221', '312212', '322112', '322211',
  '212123', '212321', '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
  '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121', '313121', '211331',
  '231131', '213113', '213311', '213131', '311123', '311321', '331121', '312113', '312311', '332111',
  '314111', '221411', '431111', '111224', '111422', '121124', '121421', '141122', '141221', '112214',
  '112412', '122114', '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
  '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112', '421211', '212141',
  '214121', '412121', '111143', '111341', '131141', '114113', '114311', '411113', '411311', '113141',
  '114131', '311141', '411131', '211412', '211214', '211232', '2331112',
];

const START_B = 104;
const STOP = 106;

export class BarcodeError extends Error {}

/** Symbol values for `text`, including the start code, checksum and stop. */
export function code128bValues(text: string): number[] {
  if (text.length === 0) throw new BarcodeError('Nothing to encode');
  const data: number[] = [];
  for (const ch of text) {
    const code = ch.charCodeAt(0);
    if (ch.length !== 1 || code < 32 || code > 126) {
      throw new BarcodeError(`"${ch}" cannot be encoded in Code 128 subset B`);
    }
    data.push(code - 32);
  }
  const checksum = data.reduce((sum, v, i) => sum + v * (i + 1), START_B) % 103;
  return [START_B, ...data, checksum, STOP];
}

/** The module widths (alternating bar, space, ...) for the whole symbol. */
export function code128bWidths(text: string): number[] {
  return code128bValues(text)
    .flatMap((v) => PATTERNS[v]!.split(''))
    .map(Number);
}

/** The symbol's total width in modules, excluding the 10-module quiet zones. */
export function code128bModules(text: string): number {
  return code128bWidths(text).reduce((a, b) => a + b, 0);
}

/**
 * A self-contained SVG. `moduleWidth` is in CSS pixels; a 10-module quiet zone
 * is left either side, which scanners need.
 */
export function code128bSvg(text: string, opts: { moduleWidth?: number; height?: number } = {}): string {
  const mw = opts.moduleWidth ?? 1.5;
  const height = opts.height ?? 40;
  const quiet = 10 * mw;
  const widths = code128bWidths(text);
  let x = quiet;
  const bars: string[] = [];
  widths.forEach((w, i) => {
    if (i % 2 === 0) bars.push(`<rect x="${round(x)}" y="0" width="${round(w * mw)}" height="${height}"/>`);
    x += w * mw;
  });
  const total = round(x + quiet);
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${height}" width="${total}" height="${height}" role="img" aria-label="Barcode ${escapeAttr(text)}" fill="#000">${bars.join('')}</svg>`;
}

const round = (n: number) => Math.round(n * 100) / 100;
const escapeAttr = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
