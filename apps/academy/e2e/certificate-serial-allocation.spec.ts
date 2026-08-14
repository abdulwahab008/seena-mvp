import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T02, through the whole stack. The pgTAP suite proves the invariant in
// the database; what this adds is twenty allocations fired as twenty REAL
// concurrent HTTP requests — twenty PostgREST connections, twenty separate
// backends contending for the same advisory lock — and the register page a
// Principal actually reads afterwards.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const CLERKS = 20;

function seqOf(serial: string): number {
  return Number(serial.split('-')[2]);
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@certserial-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `certserial-e2e-${runId}`,
    p_legal_name: `Cert Serial E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (error) throw error;

  const { data: campus } = await admin.from('campus').select('id, code').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin
    .from('academic_session')
    .select('id, starts_on')
    .eq('tenant_id', tenantId as string)
    .single();

  const { data: created, error: userError } = await admin.auth.admin.createUser({
    email: ownerEmail,
    password: PASSWORD,
    email_confirm: true,
  });
  if (userError || !created.user) throw userError ?? new Error('owner creation failed');
  const { error: appUserError } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (appUserError) throw appUserError;
  const { error: campusError } = await admin
    .from('user_campus')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (campusError) throw campusError;

  return {
    admin,
    ownerEmail,
    campus: campus!,
    session: session!,
    year: new Date(`${session!.starts_on}T00:00:00Z`).getUTCFullYear(),
  };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('AC1: twenty clerks issuing at once get twenty consecutive serials, and the register shows the run', async ({
  page,
}) => {
  const { admin, ownerEmail, campus, session, year } = await seed();

  await signIn(page, ownerEmail);
  await page.goto('/certificates/serials');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Certificate serial register' })).toBeVisible();
  await expect(page.getByTestId('cert-serial-empty')).toBeVisible();

  // Twenty requests in flight at once, each its own connection and its own
  // transaction. Nothing here serialises them but the allocator.
  const results = await Promise.all(
    Array.from({ length: CLERKS }, () =>
      admin.rpc('allocate_certificate_serial', {
        p_campus_id: campus.id,
        p_certificate_type: 'transfer',
        p_session_id: session.id,
      }),
    ),
  );

  const failures = results.filter((r) => r.error);
  expect(failures.map((f) => f.error!.message)).toEqual([]);

  const serials = results.map((r) => r.data as string);
  expect(new Set(serials).size).toBe(CLERKS);

  const seqs = serials.map(seqOf).sort((a, b) => a - b);
  expect(Math.max(...seqs) - Math.min(...seqs) + 1).toBe(seqs.length);
  expect(seqs[0]).toBe(1);
  expect(seqs.at(-1)).toBe(CLERKS);
  expect(serials).toContain(`TC-${year}-${String(CLERKS).padStart(6, '0')}`);

  await page.reload();
  await page.waitForLoadState('networkidle');
  const row = page.getByTestId(`cert-serial-row-${campus.code}-transfer`);
  await expect(row).toBeVisible();
  await expect(page.getByTestId(`cert-serial-count-${campus.code}-transfer`)).toHaveText(String(CLERKS));
  await expect(page.getByTestId(`cert-serial-last-${campus.code}-transfer`)).toHaveText(
    `TC-${year}-${String(CLERKS).padStart(6, '0')}`,
  );
  await expect(page.getByTestId(`cert-serial-next-${campus.code}-transfer`)).toHaveText(
    `TC-${year}-${String(CLERKS + 1).padStart(6, '0')}`,
  );
});

test('AC4: a signed-in Owner can read the register but cannot move a counter or allocate a number', async () => {
  const { admin, ownerEmail, campus, session } = await seed();

  await admin.rpc('allocate_certificate_serial', {
    p_campus_id: campus.id,
    p_certificate_type: 'transfer',
    p_session_id: session.id,
  });

  const owner = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await owner.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  const { data: visible } = await owner
    .from('v_certificate_serial_register')
    .select('current_value, next_serial')
    .eq('campus_id', campus.id);
  expect(visible).toHaveLength(1);
  expect(visible![0]!.current_value).toBe(1);

  // RLS has no write policy for authenticated, so the UPDATE matches
  // nothing at all rather than reaching the row.
  const { error: updateError } = await owner
    .from('certificate_serial_counter')
    .update({ current_value: 9999 })
    .eq('campus_id', campus.id);
  expect(updateError).toBeNull();

  // And allocation is not a signed-in user's to call: a serial with no
  // certificate behind it is precisely the gap this FR forbids.
  const { error: rpcError } = await owner.rpc('allocate_certificate_serial', {
    p_campus_id: campus.id,
    p_certificate_type: 'transfer',
    p_session_id: session.id,
  });
  expect(rpcError).not.toBeNull();

  const { data: after } = await admin
    .from('certificate_serial_counter')
    .select('current_value')
    .eq('campus_id', campus.id)
    .eq('certificate_type', 'transfer');
  expect(after![0]!.current_value).toBe(1);
});
