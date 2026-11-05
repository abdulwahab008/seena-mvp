import type { SupabaseClient } from '@supabase/supabase-js';
import { sha256Hex } from '@/lib/certificates/seal';
import { renderHrPdf } from '@/lib/hr/render';
import { buildPayslipDocument, payslipStrings, type PayslipPayload } from './payslip-document';
import type { Database } from '@/lib/database.types';

type Db = SupabaseClient<Database>;

export class PayslipError extends Error {
  constructor(public readonly code: 'run_not_locked' | 'forbidden' | 'not_found' | 'failed') {
    super(code);
  }
}

export type PayslipFile = { path: string; version: number; sha256: string; bytes: Uint8Array; created: boolean };

/**
 * Renders one line's payslip and stores it. The render is deterministic (PDF dates pinned to the run
 * lock time), so identical content adds no version; changed content adds version N+1 and keeps the
 * earlier file. `user` reads the payload under the caller's own session (RLS decides who may);
 * `admin` writes storage and the ledger.
 */
export async function generatePayslip(user: Db, admin: Db, lineId: string, userId: string | null): Promise<PayslipFile> {
  const { data, error } = await user.rpc('payslip_payload', { p_run_line_id: lineId });
  if (error) {
    if (error.message.includes('run_not_locked')) throw new PayslipError('run_not_locked');
    if (error.message.includes('FORBIDDEN')) throw new PayslipError('forbidden');
    throw new PayslipError('failed');
  }
  const p = data as unknown as PayslipPayload;
  const bytes = await renderHrPdf((font) => buildPayslipDocument(p, font), payslipStrings(p), new Date(p.run_locked_at ?? Date.now()));
  const sha256 = sha256Hex(bytes);

  const { data: latest } = await admin.from('payslip').select('version, sha256, storage_path').eq('run_line_id', lineId).order('version', { ascending: false }).limit(1).maybeSingle();
  if (latest && latest.sha256 === sha256) return { path: latest.storage_path, version: latest.version, sha256, bytes, created: false };

  const version = (latest?.version ?? 0) + 1;
  const path = `${p.tenant_id}/${p.run_id}/${p.staff_id}-v${version}.pdf`;
  const up = await admin.storage.from('payslips').upload(path, bytes, { contentType: 'application/pdf', upsert: false });
  if (up.error) throw new PayslipError('failed');
  const reg = await admin.rpc('register_payslip', { p_run_line_id: lineId, p_version: version, p_storage_path: path, p_sha256: sha256, p_generated_by: userId ?? undefined });
  if (reg.error) throw new PayslipError('failed');
  return { path, version, sha256, bytes, created: true };
}
