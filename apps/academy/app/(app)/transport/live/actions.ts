'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { loose, parseValues, rpcError } from '@/lib/transport/rpc';

const schema = z.object({ label: z.string().trim().min(1, 'Name this key, e.g. the vendor').max(80) });

/** Returns the device key ONCE; only its hash is stored. */
export async function createGpsKey(values: Record<string, string>): Promise<{ error: string | null; key?: string }> {
  const p = parseValues(schema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('create_gps_credential', { p_label: p.data.label });
  if (error) return { error: rpcError(error.message) };
  return { error: null, key: data as string };
}
