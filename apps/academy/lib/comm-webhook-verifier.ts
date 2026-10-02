import crypto from 'crypto';
import { createServerClient } from '@supabase/ssr';

// No fallback: a secret that ships in source is not a secret. Unset or short
// means every signature fails (fail closed), never "accept the default".
function webhookSecret(): string | null {
  const secret = process.env.COMM_WEBHOOK_SECRET;
  return secret && secret.length >= 16 ? secret : null;
}

export function verifyWebhookSignature(rawBody: string, signatureHeader: string | null): boolean {
  const secret = webhookSecret();
  if (!secret || !signatureHeader || !signatureHeader.trim()) {
    return false;
  }

  try {
    const cleanSignature = signatureHeader.replace(/^sha256=/, '').trim();
    const expectedSignature = crypto
      .createHmac('sha256', secret)
      .update(rawBody, 'utf8')
      .digest('hex');

    if (
      cleanSignature.length === expectedSignature.length &&
      crypto.timingSafeEqual(Buffer.from(cleanSignature, 'hex'), Buffer.from(expectedSignature, 'hex'))
    ) {
      return true;
    }

    // Try trimmed version
    const expectedTrimmed = crypto
      .createHmac('sha256', secret)
      .update(rawBody.trim(), 'utf8')
      .digest('hex');

    if (
      cleanSignature.length === expectedTrimmed.length &&
      crypto.timingSafeEqual(Buffer.from(cleanSignature, 'hex'), Buffer.from(expectedTrimmed, 'hex'))
    ) {
      return true;
    }

    return false;
  } catch {
    return false;
  }
}

export function createAdminSupabaseClient() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || 'http://127.0.0.1:54321';
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || 'service-role-key-default';

  return createServerClient(supabaseUrl, serviceKey, {
    cookies: {
      getAll() {
        return [];
      },
      setAll() {},
    },
  });
}
