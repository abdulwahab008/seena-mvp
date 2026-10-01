import { headers } from 'next/headers';
import QRCode from 'qrcode';
import { env } from '@/lib/env';
import { buildVerifyUrl } from './verify-core';

/** The public origin certificates are verified at: the configured site URL, else the host this request arrived on. */
async function publicOrigin(): Promise<string | null> {
  const configured = env().NEXT_PUBLIC_SITE_URL;
  if (configured) return configured;
  const h = await headers();
  const host = h.get('host');
  if (!host) return null;
  const proto = h.get('x-forwarded-proto') ?? (host.startsWith('localhost') || host.startsWith('127.') ? 'http' : 'https');
  return `${proto}://${host}`;
}

/** The QR for an issued certificate, as inline SVG so it stays vector in the PDF. */
export async function verifyQrFor(token: string): Promise<{ svg: string; url: string } | null> {
  const origin = await publicOrigin();
  if (!origin) return null;
  const url = buildVerifyUrl(origin, token);
  const svg = await QRCode.toString(url, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });
  return { svg, url };
}
