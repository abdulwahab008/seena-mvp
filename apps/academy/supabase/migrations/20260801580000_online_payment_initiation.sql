-- FR-K21: online payment initiation (JazzCash / EasyPaisa / 1LINK).
--
-- Secrets never enter the database: payment_gateway_config holds only the
-- NAME of the server environment variable that carries the signing secret
-- (secret_ref). Checkout signing happens in a server-only Next.js action.
-- The database owns the parts that must be correct regardless of the UI: who
-- may pay which challan, the balance-only amount, the 30-minute intent
-- window, one live intent per challan+gateway (idempotent initiation), and
-- the reference a 1LINK voucher must carry (the challan number).

create table public.payment_gateway_config (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid references public.campus(id) on delete cascade,
  gateway     text not null check (gateway in ('jazzcash', 'easypaisa', 'onelink')),
  merchant_id text not null check (length(btrim(merchant_id)) > 0),
  is_live     boolean not null default false,
  is_enabled  boolean not null default true,
  secret_ref  text not null check (secret_ref ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint uq_payment_gateway_tenant unique (tenant_id, gateway)
);
create unique index uq_payment_gateway_merchant on public.payment_gateway_config (gateway, merchant_id);
create index idx_payment_gateway_tenant on public.payment_gateway_config (tenant_id);

create table public.payment_intent (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  challan_id    uuid not null references public.fee_challan(id) on delete cascade,
  gateway       text not null check (gateway in ('jazzcash', 'easypaisa', 'onelink')),
  gateway_ref   text not null,
  amount_paisa  bigint not null check (amount_paisa > 0),
  status        text not null default 'initiated' check (status in ('initiated', 'pending', 'succeeded', 'failed', 'expired')),
  expires_at    timestamptz not null,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index uq_payment_intent_gateway_ref on public.payment_intent (gateway, gateway_ref);
create unique index uq_payment_intent_live on public.payment_intent (challan_id, gateway) where status in ('initiated', 'pending');
create index idx_payment_intent_scope on public.payment_intent (tenant_id, campus_id, status);
create index idx_payment_intent_enrolment on public.payment_intent (enrolment_id);
create index idx_payment_intent_expiry on public.payment_intent (expires_at) where status in ('initiated', 'pending');

create trigger payment_intent_audit after insert or update or delete on public.payment_intent
  for each row execute function app.tg_audit_row();

alter table public.payment_gateway_config enable row level security;
alter table public.payment_intent enable row level security;

create policy payment_gateway_config_finance_read on public.payment_gateway_config
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));

create policy payment_intent_finance_read on public.payment_intent
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

create policy payment_intent_parent_own_child on public.payment_intent
  for select to authenticated
  using (
    app.auth_role() = 'parent'
    and enrolment_id in (select id from public.enrolment where student_id = any(app.auth_guardian_student_ids()))
  );

-- Config is written only through this RPC: it can carry a variable NAME, never a secret value.
create or replace function public.upsert_payment_gateway_config(
  p_gateway text, p_merchant_id text, p_secret_ref text, p_is_live boolean default false, p_is_enabled boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_secret_ref !~ '^[A-Z][A-Z0-9_]{2,63}$' then
    raise exception 'SECRET_REF_MUST_BE_AN_ENV_VAR_NAME' using errcode = '22023';
  end if;

  insert into public.payment_gateway_config (tenant_id, gateway, merchant_id, secret_ref, is_live, is_enabled)
  values (app.auth_tenant_id(), p_gateway, btrim(p_merchant_id), p_secret_ref, p_is_live, p_is_enabled)
  on conflict (tenant_id, gateway) do update
    set merchant_id = excluded.merchant_id, secret_ref = excluded.secret_ref,
        is_live = excluded.is_live, is_enabled = excluded.is_enabled, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke execute on function public.upsert_payment_gateway_config(text, text, text, boolean, boolean) from public, anon;
grant execute on function public.upsert_payment_gateway_config(text, text, text, boolean, boolean) to authenticated;

-- What is still owed on a challan: net minus everything allocated to it.
create or replace function app.fn_challan_balance(p_challan_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select c.net_paisa - coalesce((select sum(a.amount_paisa) from public.fee_payment_allocation a where a.challan_id = c.id), 0)
    from public.fee_challan c
   where c.id = p_challan_id and c.status <> 'cancelled';
$$;
revoke execute on function app.fn_challan_balance(uuid) from public, anon, authenticated;

create or replace function public.create_payment_intent(p_challan_id uuid, p_gateway text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_challan   record;
  v_intent    public.payment_intent%rowtype;
  v_balance   bigint;
  v_ref       text;
begin
  if app.auth_role() not in ('parent', 'accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select c.id, c.campus_id, c.enrolment_id, c.challan_no, c.status, e.student_id
    into v_challan
    from public.fee_challan c
    join public.enrolment e on e.id = c.enrolment_id
   where c.id = p_challan_id and c.tenant_id = v_tenant_id and c.deleted_at is null;
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() = 'parent' and not exists (
    select 1 from public.student_guardian sg
      join public.guardian g on g.id = sg.guardian_id
     where g.auth_user_id = (select auth.uid()) and sg.student_id = v_challan.student_id
       and sg.to_date is null and sg.portal_access and sg.receives_billing
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_challan.status in ('paid', 'cancelled') then
    raise exception 'CHALLAN_ALREADY_SETTLED' using errcode = '55000';
  end if;
  v_balance := app.fn_challan_balance(p_challan_id);
  if v_balance is null or v_balance <= 0 then
    raise exception 'CHALLAN_ALREADY_SETTLED' using errcode = '55000';
  end if;

  if not exists (select 1 from public.payment_gateway_config where tenant_id = v_tenant_id and gateway = p_gateway and is_enabled) then
    raise exception 'GATEWAY_NOT_CONFIGURED' using errcode = '22023';
  end if;

  -- Idempotent: an unexpired live intent for this challan+gateway is returned as-is.
  update public.payment_intent set status = 'expired', updated_at = now()
   where challan_id = p_challan_id and gateway = p_gateway and status in ('initiated', 'pending') and expires_at <= now();

  select * into v_intent from public.payment_intent
   where challan_id = p_challan_id and gateway = p_gateway and status in ('initiated', 'pending');

  if not found then
    -- 1LINK vouchers must carry the challan number so the settlement file matches.
    v_ref := case when p_gateway = 'onelink' then v_challan.challan_no
                  else upper(left(p_gateway, 2)) || '-' || encode(extensions.gen_random_bytes(9), 'hex') end;
    insert into public.payment_intent (tenant_id, campus_id, enrolment_id, challan_id, gateway, gateway_ref, amount_paisa, expires_at, created_by)
    values (v_tenant_id, v_challan.campus_id, v_challan.enrolment_id, p_challan_id, p_gateway, v_ref, v_balance, now() + interval '30 minutes', (select auth.uid()))
    returning * into v_intent;
  end if;

  return jsonb_build_object(
    'intent_id', v_intent.id, 'gateway', v_intent.gateway, 'gateway_ref', v_intent.gateway_ref,
    'amount_paisa', v_intent.amount_paisa, 'expires_at', v_intent.expires_at
  );
end;
$$;

revoke execute on function public.create_payment_intent(uuid, text) from public, anon;
grant execute on function public.create_payment_intent(uuid, text) to authenticated;

-- Abandoned flows: parents start JazzCash, fail OTP, pay cash at the counter.
-- The intent must stop being live so it cannot be mistaken for a pending payment.
create or replace function public.expire_payment_intents(p_as_of timestamptz default now())
returns integer
language sql
security definer
set search_path = ''
as $$
  with e as (
    update public.payment_intent set status = 'expired', updated_at = now()
     where status in ('initiated', 'pending') and expires_at <= p_as_of
    returning 1
  )
  select count(*)::int from e;
$$;

revoke execute on function public.expire_payment_intents(timestamptz) from public, anon, authenticated;
grant execute on function public.expire_payment_intents(timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('fees-expire-payment-intents', '*/15 * * * *', 'select public.expire_payment_intents();');
  end if;
exception
  when others then null;
end;
$$;
