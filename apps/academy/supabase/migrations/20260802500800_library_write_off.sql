-- FR-O08: lost copy write-off and recovery charge.
--
-- write_off_copy() declares a copy lost for good, in one transaction:
--   * the charge = replacement cost (basis purchase_cost; market = a value the librarian types;
--     multiple = purchase cost x multiplier, default 1.5 or tenant_setting
--     'library.replacement_multiplier') + the borrower's accrued late fines on that loan;
--   * for a student borrower the charge is posted as ONE debit on the same fee ledger the challan
--     prints from (public.fee_ledger, head LIB_RECOVERY, created on first use), never to a shadow
--     ledger the accounts office would have to reconcile by hand;
--   * the loan is closed, the loan's outstanding fines are marked settled by the write-off (they
--     are inside the charge), and the copy becomes written_off. Its accession number stays
--     reserved forever (the unique index and the no-delete trigger of FR-O02);
--   * a staff borrower is not on a fee ledger: the write-off row records the amount to recover
--     (payroll deduction is handled by the Accountant) and nothing is posted. A copy lost from the
--     shelf with no open loan is written off at no charge.
--
-- reverse_write_off() (the book was found) never deletes anything: it inserts a reversal
-- write-off row, stamps reversed_at on the original, posts a CREDIT NOTE on the fee ledger that
-- references the original charge (reversal_of_id), restores the loan's fines to outstanding and
-- returns the copy to the shelf. The original and the reversal both stay visible.
--
-- Only librarian / principal / owner / super_admin may write off. A refused attempt (for example a
-- teacher) is not raised as an exception, because the rollback would also roll back the audit
-- record: write_off_copy returns {ok: false, error: 'FORBIDDEN'} after recording the attempt in
-- audit_log (table_name 'library_write_off:denied').

create type public.library_write_off_basis as enum ('purchase_cost', 'market', 'multiple');

alter table public.library_loan drop constraint if exists library_loan_return_condition_check;
alter table public.library_loan add constraint library_loan_return_condition_check
  check (return_condition is null or return_condition in ('good', 'damaged', 'lost'));

create table public.library_write_off (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  copy_id          uuid not null references public.library_copy(id),
  loan_id          uuid references public.library_loan(id),
  borrower_id      uuid,
  declared_by      uuid not null references public.app_user(user_id),
  declared_at      timestamptz not null default clock_timestamp(),
  basis            public.library_write_off_basis not null,
  multiplier       numeric(6, 2) not null default 1 check (multiplier > 0),
  base_amount      bigint not null default 0 check (base_amount >= 0),
  fine_component   bigint not null default 0 check (fine_component >= 0),
  charge_amount    bigint not null default 0 check (charge_amount >= 0),
  fee_ledger_id    uuid references public.fee_ledger(id),
  reversal_ledger_id uuid references public.fee_ledger(id),
  reversal_of      uuid references public.library_write_off(id),
  reversed_at      timestamptz,
  reason           text,
  recovery_note    text,
  created_at       timestamptz not null default now(),
  constraint chk_write_off_charge check (charge_amount = base_amount + fine_component or reversal_of is not null)
);

create unique index uq_write_off_live_per_copy on public.library_write_off (copy_id) where reversal_of is null and reversed_at is null;
create unique index uq_write_off_single_reversal on public.library_write_off (reversal_of) where reversal_of is not null;
create index idx_library_write_off_campus on public.library_write_off (tenant_id, campus_id, declared_at desc);
create index idx_library_write_off_borrower on public.library_write_off (borrower_id);

create trigger trg_audit_library_write_off after insert or update or delete on public.library_write_off
  for each row execute function app.tg_audit_row();

alter table public.library_write_off enable row level security;
revoke insert, update, delete on public.library_write_off from authenticated, anon;
create policy library_write_off_campus_scope on public.library_write_off for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'librarian', 'accountant') and app.fn_library_campus_ok(campus_id));
create policy library_write_off_parent_read on public.library_write_off for select to authenticated
  using (tenant_id = app.auth_tenant_id() and borrower_id = any (app.auth_guardian_student_ids()));

-- fines settled by a write-off remember which one, so a reversal can restore them
alter table public.library_fine add constraint library_fine_write_off_fk foreign key (write_off_id) references public.library_write_off(id);

-- ── write off ────────────────────────────────────────────────────────────────

create or replace function public.write_off_copy(
  p_copy_id uuid, p_basis text default 'multiple', p_multiplier numeric default null, p_market_value bigint default null, p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_actor    uuid := (select auth.uid());
  v_copy     public.library_copy%rowtype;
  v_loan     public.library_loan%rowtype;
  v_basis    public.library_write_off_basis;
  v_mult     numeric := 1;
  v_base     bigint := 0;
  v_fine     bigint := 0;
  v_id       uuid := gen_random_uuid();
  v_head     uuid;
  v_enrol    public.enrolment%rowtype;
  v_ledger   uuid;
  v_note     text;
  v_title    text;
begin
  if v_tenant is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if app.auth_role() not in ('librarian', 'principal', 'owner', 'super_admin') then
    insert into public.audit_log (tenant_id, actor_user_id, actor_role, action, table_name, row_id, after)
    values (v_tenant, v_actor, nullif(app.auth_role(), 'none')::public.app_role, 'insert', 'library_write_off:denied', p_copy_id,
            jsonb_build_object('attempt', 'write_off_copy', 'copy_id', p_copy_id, 'basis', p_basis, 'denied', true));
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  if p_basis not in ('purchase_cost', 'market', 'multiple') then
    raise exception 'BASIS_INVALID' using errcode = '22023';
  end if;
  v_basis := p_basis::public.library_write_off_basis;

  select * into v_copy from public.library_copy where id = p_copy_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'COPY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_library_campus_ok(v_copy.campus_id) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if v_copy.status = 'written_off' then
    raise exception 'WRITE_OFF_EXISTS' using errcode = '23505';
  end if;

  select * into v_loan from public.library_loan where copy_id = v_copy.id and returned_at is null for update;

  -- replacement cost
  if v_basis = 'market' then
    if p_market_value is null or p_market_value <= 0 then
      raise exception 'MARKET_VALUE_REQUIRED' using errcode = '22023';
    end if;
    v_base := p_market_value;
  else
    if v_copy.purchase_cost is null then
      raise exception 'PURCHASE_COST_MISSING' using errcode = '22023';
    end if;
    if v_basis = 'multiple' then
      v_mult := coalesce(p_multiplier, (select (s.value #>> '{}')::numeric from public.tenant_setting s where s.tenant_id = v_tenant and s.key = 'library.replacement_multiplier'), 1.5);
      if v_mult <= 0 then
        raise exception 'BASIS_INVALID' using errcode = '22023';
      end if;
    end if;
    v_base := round(v_copy.purchase_cost * v_mult)::bigint;
  end if;

  if v_loan.id is null then
    -- lost from the shelf: nobody to bill
    v_base := 0;
    v_note := 'No open loan: written off at no charge.';
  else
    perform app.fn_library_accrue_loan(v_loan.id, app.fn_karachi_today());
    select coalesce(sum(f.amount), 0)::bigint into v_fine from public.library_fine f where f.loan_id = v_loan.id and f.status = 'outstanding';
  end if;

  insert into public.library_write_off (id, tenant_id, campus_id, copy_id, loan_id, borrower_id, declared_by, basis, multiplier, base_amount, fine_component, charge_amount, reason, recovery_note)
  values (v_id, v_tenant, v_copy.campus_id, v_copy.id, v_loan.id, v_loan.borrower_id, v_actor, v_basis, v_mult, v_base, v_fine, v_base + v_fine, nullif(btrim(p_reason), ''), v_note);

  if v_loan.id is not null then
    update public.library_fine set status = 'settled', settled_by = v_actor, settled_at = clock_timestamp(), write_off_id = v_id
     where loan_id = v_loan.id and status = 'outstanding';
    update public.library_loan set returned_at = clock_timestamp(), return_condition = 'lost', received_by = v_actor where id = v_loan.id;

    if v_loan.borrower_role = 'student' and v_base + v_fine > 0 then
      select * into v_enrol from public.enrolment e where e.student_id = v_loan.borrower_id and e.tenant_id = v_tenant and e.status = 'active' order by e.joined_on desc limit 1;
      if not found then
        raise exception 'NO_FEE_LEDGER' using errcode = 'P0002';
      end if;
      insert into public.fee_head (tenant_id, code, name_en, name_ur, is_refundable, default_frequency, created_by)
      values (v_tenant, 'LIB_RECOVERY', 'Library Recovery', 'لائبریری ریکوری', false, 'one_time', v_actor)
      on conflict (tenant_id, lower(code)) do nothing;
      select id into v_head from public.fee_head where tenant_id = v_tenant and lower(code) = 'lib_recovery';
      insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reason, created_by)
      values (v_tenant, v_enrol.campus_id, v_enrol.id, v_enrol.session_id, 'charge', v_head, v_base + v_fine, 'debit', app.fn_karachi_today(), 'library_write_off', v_id,
              coalesce(nullif(btrim(p_reason), ''), 'Lost library book written off'), v_actor)
      returning id into v_ledger;
      update public.library_write_off set fee_ledger_id = v_ledger where id = v_id;
    elsif v_loan.borrower_role <> 'student' then
      update public.library_write_off set recovery_note = 'Staff borrower: recover PKR ' || to_char((v_base + v_fine) / 100.0, 'FM999,999,990') || ' outside the student fee ledger.' where id = v_id;
    end if;
  end if;

  update public.library_copy set status = 'written_off' where id = v_copy.id;

  if v_loan.id is not null then
    select t.title into v_title from public.library_title t where t.id = v_copy.title_id;
    perform app.fn_library_notify(v_tenant, v_copy.campus_id, v_loan.borrower_id, 'library_write_off', 'Lost library book',
                                  v_title || ' has been written off as lost. A recovery charge of PKR ' || to_char((v_base + v_fine) / 100.0, 'FM999,999,990') || ' has been added to the fee account.',
                                  'library_writeoff:' || v_id);
  end if;

  return jsonb_build_object('ok', true, 'write_off_id', v_id, 'charge_amount', v_base + v_fine, 'replacement_amount', v_base, 'fine_component', v_fine, 'fee_ledger_id', v_ledger);
end;
$$;
revoke execute on function public.write_off_copy(uuid, text, numeric, bigint, text) from public, anon;
grant execute on function public.write_off_copy(uuid, text, numeric, bigint, text) to authenticated;

-- ── reverse ──────────────────────────────────────────────────────────────────

create or replace function public.reverse_write_off(p_write_off_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_actor  uuid := (select auth.uid());
  v_w      public.library_write_off%rowtype;
  v_led    public.fee_ledger%rowtype;
  v_rev    uuid := gen_random_uuid();
  v_credit uuid;
begin
  if app.auth_role() not in ('librarian', 'principal', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_w from public.library_write_off where id = p_write_off_id and tenant_id = v_tenant for update;
  if not found or v_w.reversal_of is not null then
    raise exception 'WRITE_OFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_library_campus_ok(v_w.campus_id) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if v_w.reversed_at is not null then
    raise exception 'ALREADY_REVERSED' using errcode = '55000';
  end if;

  insert into public.library_write_off (id, tenant_id, campus_id, copy_id, loan_id, borrower_id, declared_by, basis, multiplier, base_amount, fine_component, charge_amount, reversal_of, reason)
  values (v_rev, v_tenant, v_w.campus_id, v_w.copy_id, v_w.loan_id, v_w.borrower_id, v_actor, v_w.basis, v_w.multiplier, v_w.base_amount, v_w.fine_component, v_w.charge_amount, v_w.id, nullif(btrim(p_reason), ''));

  if v_w.fee_ledger_id is not null then
    select * into v_led from public.fee_ledger where id = v_w.fee_ledger_id;
    insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reason, created_by, reversal_of_id)
    values (v_led.tenant_id, v_led.campus_id, v_led.enrolment_id, v_led.session_id, 'reversal', v_led.fee_head_id, v_led.amount_paisa, 'credit', app.fn_karachi_today(), 'reversal', v_led.id,
            'Library write-off reversed, book found: ' || coalesce(nullif(btrim(p_reason), ''), 'copy recovered'), v_actor, v_led.id)
    returning id into v_credit;
  end if;

  update public.library_write_off set reversed_at = clock_timestamp(), reversal_ledger_id = v_credit where id = v_w.id;
  -- the late fines that were rolled into the charge are owed again
  update public.library_fine set status = 'outstanding', settled_by = null, settled_at = null, write_off_id = null where write_off_id = v_w.id;
  update public.library_copy set status = 'available' where id = v_w.copy_id and status = 'written_off';

  return jsonb_build_object('ok', true, 'reversal_id', v_rev, 'credit_note_id', v_credit, 'charge_reversed', v_w.charge_amount);
end;
$$;
revoke execute on function public.reverse_write_off(uuid, text) from public, anon;
grant execute on function public.reverse_write_off(uuid, text) to authenticated;
