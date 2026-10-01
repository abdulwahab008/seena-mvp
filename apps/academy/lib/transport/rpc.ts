// Shared plumbing for the transport and hostel server actions and pages.
//
// The Database type is generated from the live schema; tables and functions
// added by these modules are reached through a loosely typed client so the
// pages compile before (and regardless of) a types regeneration. Every rule
// is enforced by the database; the actions only validate shape (zod) and map
// error codes to sentences a clerk can act on.
import type { SupabaseClient } from '@supabase/supabase-js';
import type { ZodTypeAny, z } from 'zod';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type LooseClient = SupabaseClient<any, 'public', any>;

export function loose(client: unknown): LooseClient {
  return client as LooseClient;
}

export type ActionResult = { error: string | null; message?: string };

const COMMON: Record<string, string> = {
  FORBIDDEN: 'You do not have permission to do this.',
  CAMPUS_NOT_FOUND: 'That campus was not found.',
};

/** First known error code found in the database message, else a generic line. */
export function rpcError(message: string, map: Record<string, string> = {}): string {
  for (const [code, text] of Object.entries({ ...map, ...COMMON })) {
    if (message.includes(code)) return text;
  }
  return 'Something went wrong. Please try again.';
}

/** Parse form values with a zod schema; first issue becomes the error. */
export function parseValues<S extends ZodTypeAny>(schema: S, values: unknown): { ok: true; data: z.output<S> } | { ok: false; error: string } {
  const p = schema.safeParse(values);
  if (!p.success) return { ok: false, error: p.error.issues[0]?.message ?? 'Invalid input.' };
  return { ok: true, data: p.data };
}

export const rupeesToPaisa = (rupees: number): number => Math.round(rupees * 100);
export const paisaToRupees = (paisa: number | string | null | undefined): string =>
  paisa == null ? '-' : (Number(paisa) / 100).toLocaleString('en-PK', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
export const pkr = (paisa: number | string | null | undefined): string => (paisa == null ? '-' : `PKR ${paisaToRupees(paisa)}`);

export const todayPk = (): string => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

/** The campus a page works on: ?campus_id= when it is one the user can see, else the first. */
export async function pickCampus(supabase: LooseClient, requested?: string): Promise<{ id: string; name: string } | null> {
  const { data } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const rows = (data ?? []) as { id: string; name: string }[];
  return rows.find((c) => c.id === requested) ?? rows[0] ?? null;
}

export async function currentRole(supabase: LooseClient): Promise<string> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return 'none';
  const { data } = await supabase.from('app_user').select('app_role').eq('user_id', user.id).maybeSingle();
  return (data as { app_role?: string } | null)?.app_role ?? 'none';
}

export const TRANSPORT_STAFF = ['owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'];
export const HOSTEL_STAFF = ['owner', 'super_admin', 'principal', 'vice_principal'];
