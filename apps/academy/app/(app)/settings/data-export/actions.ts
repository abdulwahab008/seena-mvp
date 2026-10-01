'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type RequestTenantExportResult = { error: string | null };

// FR-A19. The Edge Function the design names (start-data-export) is this server action: it enqueues
// the request through the database (which enforces tenant.export) and nudges the long-running worker.
export async function requestTenantExport(): Promise<RequestTenantExportResult> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('request_tenant_export');
  if (error) {
    if (error.message.includes('PERMISSION_DENIED')) return { error: 'Only the school owner can export all school data.' };
    return { error: 'Could not start the export. Please try again.' };
  }
  void data;
  const h = await headers();
  const secret = process.env.EXPORT_WORKER_SECRET;
  const host = h.get('host');
  if (secret && host) {
    const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
    void fetch(`${proto}://${host}/api/internal/exports/run`, { method: 'POST', headers: { 'x-worker-secret': secret } }).catch(() => undefined);
  }
  revalidatePath('/settings/data-export');
  return { error: null };
}
