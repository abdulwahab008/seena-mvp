import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { env } from './env';

declare global {
  // eslint-disable-next-line no-var
  var __supabase: SupabaseClient | undefined;
}

export function supabaseAdmin(): SupabaseClient {
  if (globalThis.__supabase) return globalThis.__supabase;
  const e = env();
  const client = createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  globalThis.__supabase = client;
  return client;
}

export async function createSignedUploadUrl(orgId: string, filename: string) {
  const e = env();
  const safe = filename.replace(/[^\w.\-]+/g, '_');
  const key = `org_${orgId}/${Date.now()}_${safe}`;
  const { data, error } = await supabaseAdmin()
    .storage.from(e.SUPABASE_BUCKET)
    .createSignedUploadUrl(key);
  if (error || !data) throw error ?? new Error('failed to create signed upload url');
  return { key, signedUrl: data.signedUrl, token: data.token };
}

export async function downloadObject(key: string): Promise<Buffer> {
  const e = env();
  const { data, error } = await supabaseAdmin().storage.from(e.SUPABASE_BUCKET).download(key);
  if (error || !data) throw error ?? new Error('download failed');
  const ab = await data.arrayBuffer();
  return Buffer.from(ab);
}

export async function getSignedReadUrl(key: string, expiresInSeconds = 60 * 60): Promise<string> {
  const e = env();
  const { data, error } = await supabaseAdmin()
    .storage.from(e.SUPABASE_BUCKET)
    .createSignedUrl(key, expiresInSeconds);
  if (error || !data) throw error ?? new Error('failed to create signed read url');
  return data.signedUrl;
}

export async function uploadBuffer(key: string, buffer: Buffer, contentType: string) {
  const e = env();
  const { error } = await supabaseAdmin()
    .storage.from(e.SUPABASE_BUCKET)
    .upload(key, buffer, { contentType, upsert: true });
  if (error) throw error;
}

export async function deleteObject(key: string): Promise<void> {
  const e = env();
  const { error } = await supabaseAdmin().storage.from(e.SUPABASE_BUCKET).remove([key]);
  if (error) throw error;
}
