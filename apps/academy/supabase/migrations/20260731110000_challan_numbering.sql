-- FR-K10: gap-free challan numbering.
--
-- Same reasoning as GR numbers (FR-C01) and employee codes (FR-D01): NOT
-- a Postgres SEQUENCE. Sequences gap on rollback, and a bank or auditor
-- reading a gap in a challan sequence reads it as a missing — or hidden —
-- challan. challan_counter is a row-locked counter (SELECT ... FOR
-- UPDATE, then UPDATE, the exact pattern app.fn_allocate_gr_number and
-- app.fn_next_employee_code already use) so concurrent generation workers
-- serialise correctly; throughput cost is irrelevant at a few thousand
-- rows a month.
--
-- challan_check_digit() uses the EAN-13/UPC check-digit algorithm (odd
-- positions from the right weighted 3x, summed, 10's complement mod 10)
-- — a standard, well-known, bank-compatible scheme for exactly this
-- "serial number with a scannable checksum" shape, not a bespoke one.
--
-- Scope cut: fee_challan_no_uq (unique index on fee_challan.challan_no)
-- is not created here — fee_challan itself is FR-K09, not built yet.
-- next_challan_no() and challan_check_digit() are both fully testable
-- without it; the uniqueness index binds in once K09 ships the table.
--
-- next_challan_no() is service_role only, matching challan_counter's own
-- RLS intent from the FR's object list — it's meant to be called by the
-- monthly generation job (FR-K09's cron), never directly by a logged-in
-- user.

create table public.challan_counter (
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  session_id uuid not null references public.academic_session(id) on delete cascade,
  last_no    bigint not null default 0,
  primary key (tenant_id, campus_id, session_id)
);

create or replace function public.challan_check_digit(p_digits text)
returns int
language plpgsql
immutable
as $$
declare
  v_sum   int := 0;
  v_digit int;
  v_len   int := length(p_digits);
  i       int;
begin
  for i in 1..v_len loop
    v_digit := substring(p_digits from i for 1)::int;
    if (v_len - i) % 2 = 0 then
      v_sum := v_sum + v_digit * 3;
    else
      v_sum := v_sum + v_digit;
    end if;
  end loop;

  return (10 - (v_sum % 10)) % 10;
end;
$$;

revoke execute on function public.challan_check_digit(text) from public, anon;
grant execute on function public.challan_check_digit(text) to authenticated;

create or replace function public.next_challan_no(p_tenant_id uuid, p_campus_id uuid, p_session_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   public.challan_counter%rowtype;
  v_next  bigint;
  v_base  text;
  v_check int;
begin
  insert into public.challan_counter (tenant_id, campus_id, session_id, last_no)
  values (p_tenant_id, p_campus_id, p_session_id, 0)
  on conflict (tenant_id, campus_id, session_id) do nothing;

  select * into v_row from public.challan_counter
   where tenant_id = p_tenant_id and campus_id = p_campus_id and session_id = p_session_id
   for update;

  v_next := v_row.last_no + 1;
  update public.challan_counter set last_no = v_next
   where tenant_id = p_tenant_id and campus_id = p_campus_id and session_id = p_session_id;

  v_base := lpad(v_next::text, 11, '0');
  v_check := public.challan_check_digit(v_base);

  return v_base || v_check::text;
end;
$$;

revoke execute on function public.next_challan_no(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.next_challan_no(uuid, uuid, uuid) to service_role;

alter table public.challan_counter enable row level security;
-- No policies at all: service-role only, per the FR's own RLS intent —
-- bypasses RLS entirely rather than needing a permissive policy, and
-- authenticated correctly sees zero rows.
