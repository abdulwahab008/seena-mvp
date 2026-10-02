import QRCode from 'qrcode';

// FR-Q03: what the printed gate pass's QR code encodes and how it is drawn.

/** The record a gate scan opens. Staff must be signed in to see it. */
export function gatePassPath(passId: string): string {
  return `/hostel/gate-passes/${passId}`;
}

export function gatePassUrl(origin: string, passId: string): string {
  return `${origin.replace(/\/+$/, '')}${gatePassPath(passId)}`;
}

/** An inline SVG QR code (error correction M) for the given text. */
export function qrSvg(text: string, size = 168): Promise<string> {
  return QRCode.toString(text, { type: 'svg', errorCorrectionLevel: 'M', margin: 1, width: size });
}

/** Datetime-local values are wall-clock Pakistan time; the database wants an instant. */
export function karachiLocalToIso(local: string): string {
  return `${local}:00+05:00`;
}
