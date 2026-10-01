import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';

export const FRESH_OWNER_PASSWORD = 'Password123!';

export type FreshOwner = { email: string; password: string; tenantId: string };

// A brand-new tenant (default class levels, message templates, campus and
// current session come from provision_tenant) with one signed-in-able owner.
//
// Several older specs signed in as a hardcoded `owner@seena.academy` that
// only ever existed in one developer's long-lived local database. On any
// database built from the migrations alone (CI's `supabase db reset`, a
// verification stack) that user does not exist and sign-in bounces back to
// /login, so those specs failed for a reason unrelated to what they test.
// Seeding a fresh owner per run is the same isolation every other spec in
// this suite already uses, and it also stops runs from piling state (wallet
// credit, circulars, WhatsApp windows) onto one shared tenant.
export async function seedFreshOwner(label: string): Promise<FreshOwner> {
  const admin = createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
    auth: { persistSession: false },
  });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@${label}.test`;

  const { data: tenantId, error: provisionError } = await admin.rpc('provision_tenant', {
    p_slug: `${label}-${runId}`,
    p_legal_name: `${label} E2E School ${runId}`,
    p_owner_email: email,
  });
  if (provisionError) throw provisionError;

  const { data: created, error: userError } = await admin.auth.admin.createUser({
    email,
    password: FRESH_OWNER_PASSWORD,
    email_confirm: true,
  });
  if (userError || !created.user) throw userError ?? new Error('user creation failed');

  const { error: appUserError } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (appUserError) throw appUserError;

  return { email, password: FRESH_OWNER_PASSWORD, tenantId: tenantId as string };
}
