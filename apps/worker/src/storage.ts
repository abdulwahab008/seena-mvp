import { createClient } from '@supabase/supabase-js';
import { env } from './env.js';

let _client: ReturnType<typeof createClient> | null = null;

export function supabaseAdmin() {
  if (_client) return _client;
  _client = createClient(env().SUPABASE_URL, env().SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  return _client;
}

export async function downloadObject(key: string): Promise<Buffer> {
  const { data, error } = await supabaseAdmin().storage.from(env().SUPABASE_BUCKET).download(key);
  if (error || !data) throw error ?? new Error('download failed');
  return Buffer.from(await data.arrayBuffer());
}
