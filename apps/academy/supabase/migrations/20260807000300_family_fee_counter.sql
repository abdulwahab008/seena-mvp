-- Family accounts and family fee collection.
--
-- family_group (guardians_and_families.sql) already links siblings. This gives
-- each family a short number the counter can type, a way to find a family by
-- that number, a parent's CNIC or mobile, or any child's GR number, and one
-- payment that is split across the children's dues, oldest first.
--
-- The split does not re-implement collection: each child's share goes through
-- collect_cash_payment(), so the role check, campus scope, open counter shift,
-- idempotency, ledger and receipt numbering are exactly the single-child ones.
-- One family payment therefore yields one receipt per child it touched.

alter table public.family_group add column family_no int;

update public.family_group f
   set family_no = n.rn
  from (select id, row_number() over (partition by tenant_id order by created_at, id) as rn from public.family_group) n
 where n.id = f.id;

alter table public.family_group alter column family_no set not null;
create unique index uq_family_group_no on public.family_group (tenant_id, family_no);

create or replace function app.tg_family_group_number()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.family_no is null then
    perform pg_advisory_xact_lock(hashtext('family_no:' || new.tenant_id::text));
    select coalesce(max(family_no), 0) + 1 into new.family_no from public.family_group where tenant_id = new.tenant_id;
  end if;
  return new;
end;
$$;

create trigger family_group_number before insert on public.family_group
  for each row execute function app.tg_family_group_number();

-- ── find a family and its dues ────────────────────────────────────────────

create or replace function public.family_fee_lookup(p_query text)
returns table (
  family_group_id uuid,
  family_no       int,
  guardian_name   text,
  guardian_phone  text,
  student_id      uuid,
  student_name    text,
  gr_number       text,
  class_name      text,
  enrolment_id    uuid,
  balance_paisa   bigint,
  oldest_due_date date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_q         text := btrim(coalesce(p_query, ''));
  v_family    uuid;
  v_cnic      text;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer', 'receptionist') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_q = '' then
    return;
  end if;
  if length(app.digits(v_q)) = 13 then
    v_cnic := app.fn_normalize_pk_id(v_q);
  end if;

  select f.id into v_family
    from public.family_group f
   where f.tenant_id = v_tenant_id
     and (
       (v_q ~ '^[0-9]{1,9}$' and f.family_no = v_q::int)
       or f.father_cnic = v_cnic
       or exists (select 1 from public.student s where s.family_group_id = f.id and s.tenant_id = v_tenant_id and upper(s.gr_number) = upper(v_q))
       or exists (select 1 from public.student s
                    join public.student_guardian sg on sg.student_id = s.id and sg.to_date is null
                    join public.guardian g on g.id = sg.guardian_id
                   where s.family_group_id = f.id
                     and (g.cnic = v_cnic
                          or (length(app.digits(v_q)) >= 10 and right(app.digits(g.phone_e164), 10) = right(app.digits(v_q), 10))))
     )
   order by (v_q ~ '^[0-9]{1,9}$' and f.family_no = v_q::int) desc
   limit 1;

  if v_family is null then
    return;
  end if;

  return query
  select f.id, f.family_no,
         coalesce(pg.name_en, fg.name_en),
         coalesce(pg.phone_e164, fg.phone_e164),
         s.id, s.name_en, s.gr_number,
         trim(coalesce(cl.name_en, '') || ' ' || coalesce(cs.name, '')),
         e.id,
         app.fn_enrolment_ledger_balance(e.id),
         (select min(c.due_date) from public.fee_challan c
           where c.enrolment_id = e.id and c.deleted_at is null and c.status in ('unpaid', 'part_paid'))
    from public.family_group f
    join public.student s on s.family_group_id = f.id and s.status = 'active'
    join public.enrolment e on e.student_id = s.id and e.status = 'active'
    left join public.class_level cl on cl.id = e.class_level_id
    left join public.class_section cs on cs.id = e.section_id
    left join public.guardian pg on pg.id = f.primary_guardian_id
    left join lateral (
      select g.name_en, g.phone_e164
        from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
       where sg.student_id = s.id and sg.to_date is null
       order by sg.is_primary desc limit 1
    ) fg on true
   where f.id = v_family
     and (app.auth_role() in ('super_admin', 'owner') or e.campus_id = any(app.auth_campus_ids()))
   order by 11 nulls last, s.name_en;
end;
$$;
revoke execute on function public.family_fee_lookup(text) from public, anon;
grant execute on function public.family_fee_lookup(text) to authenticated;

-- ── one payment for the whole family ──────────────────────────────────────

create or replace function public.collect_family_payment(
  p_family_group_id        uuid,
  p_amount_paisa           bigint,
  p_client_idempotency_key text,
  p_mode                   public.fee_payment_mode default 'cash',
  p_reference_no           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_left      bigint := p_amount_paisa;
  v_total     bigint;
  v_share     bigint;
  v_challan   uuid;
  v_result    jsonb;
  v_receipts  jsonb := '[]'::jsonb;
  r           record;
begin
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'AMOUNT_INVALID' using errcode = '22023';
  end if;
  if p_client_idempotency_key is null or btrim(p_client_idempotency_key) = '' then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED' using errcode = '23514';
  end if;
  if not exists (select 1 from public.family_group where id = p_family_group_id and tenant_id = v_tenant_id) then
    raise exception 'FAMILY_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Lock the family so two counters cannot split the same dues at once.
  perform 1 from public.family_group where id = p_family_group_id for update;

  -- A retried submit returns what the first one did instead of re-splitting
  -- against balances that first payment already reduced.
  select coalesce(jsonb_agg(jsonb_build_object('receipt_id', fr.id, 'receipt_no', fr.receipt_no, 'payment_id', fr.payment_id,
                                               'is_replay', true, 'student_name', s.name_en, 'amount_paisa', fp.amount_paisa)
                            order by fr.receipt_no), '[]'::jsonb)
    into v_receipts
    from public.fee_receipt fr
    join public.fee_payment fp on fp.id = fr.payment_id
    join public.enrolment e on e.id = fp.enrolment_id
    join public.student s on s.id = e.student_id
   where fr.tenant_id = v_tenant_id and fr.client_idempotency_key like p_client_idempotency_key || ':%';
  if jsonb_array_length(v_receipts) > 0 then
    return jsonb_build_object('receipts', v_receipts, 'unallocated_paisa', 0);
  end if;

  select coalesce(sum(greatest(app.fn_enrolment_ledger_balance(e.id), 0)), 0) into v_total
    from public.student s
    join public.enrolment e on e.student_id = s.id and e.status = 'active'
   where s.family_group_id = p_family_group_id and s.status = 'active';
  if v_total = 0 then
    raise exception 'NOTHING_DUE' using errcode = '22023';
  end if;
  if p_amount_paisa > v_total then
    raise exception 'AMOUNT_EXCEEDS_DUES' using errcode = '22023', detail = v_total::text;
  end if;

  for r in
    select s.name_en, e.id as enrolment_id, app.fn_enrolment_ledger_balance(e.id) as balance,
           (select min(c.due_date) from public.fee_challan c
             where c.enrolment_id = e.id and c.deleted_at is null and c.status in ('unpaid', 'part_paid')) as oldest
      from public.student s
      join public.enrolment e on e.student_id = s.id and e.status = 'active'
     where s.family_group_id = p_family_group_id and s.status = 'active'
     order by oldest nulls last, s.created_at
  loop
    exit when v_left = 0;
    continue when r.balance <= 0;
    v_share := least(v_left, r.balance);

    select c.id into v_challan
      from public.fee_challan c
     where c.enrolment_id = r.enrolment_id and c.deleted_at is null and c.status in ('unpaid', 'part_paid')
     order by c.due_date, c.billing_period
     limit 1;
    if v_challan is null then
      select c.id into v_challan from public.fee_challan c
       where c.enrolment_id = r.enrolment_id and c.deleted_at is null
       order by c.billing_period desc limit 1;
    end if;
    continue when v_challan is null;

    v_result := public.collect_cash_payment(v_challan, v_share, p_client_idempotency_key || ':' || r.enrolment_id, p_mode, p_reference_no);
    v_receipts := v_receipts || jsonb_build_array(v_result || jsonb_build_object('student_name', r.name_en, 'amount_paisa', v_share));
    v_left := v_left - v_share;
  end loop;

  return jsonb_build_object('receipts', v_receipts, 'unallocated_paisa', v_left);
end;
$$;
revoke execute on function public.collect_family_payment(uuid, bigint, text, public.fee_payment_mode, text) from public, anon;
grant execute on function public.collect_family_payment(uuid, bigint, text, public.fee_payment_mode, text) to authenticated;
