-- FR-J11: next-term fee slip with the report card.
--
-- "As an Accountant, I want the next term's challan handed over with the report
-- card, so that collection starts on the day parents come to collect results."
--
-- ── What this module is, and what it must not be ────────────────────────
--
-- The packet is the issued report card (FR-J09) followed by the 3-copy challan
-- (bank / school / student) for the next fee cycle (FR-K), one PDF. Everything
-- in it already exists; this FR only decides WHICH challan and WHEN.
--
-- The Notes are the whole risk: "The amount must be read live from the fee
-- module and never re-derived here, or the two printed documents disagree and
-- the accounts counter loses the argument in front of a queue." So:
--
--   * the challan section is rendered from app.fn_challan_payload() — the very
--     function the standalone challan PDF uses — and nothing in this module
--     sums, discounts or rounds a fee. A 25% sibling discount is already in
--     fee_challan.net_paisa when the fee module generated the challan;
--   * report_card_packet.payable_paisa is a COPY of fee_challan.net_paisa read
--     at assembly, kept so the register can show what was printed; it is
--     rewritten from the fee module on every re-assembly and never computed;
--   * the challan itself stays the fee module's: a packet only references it.
--
-- ── Which challan is "the next cycle" ───────────────────────────────────
--
-- exam_term carries no dates, so the cycle is named by whoever assembles the
-- packet (p_billing_period, any date in the month). Left out, it is the first
-- non-cancelled challan whose month is AFTER the month the card was issued —
-- results are handed over in the closing weeks of one cycle for the next.
--
-- ── The three outcomes (AC2, AC4) ───────────────────────────────────────
--
--   with_challan  card + challan.
--   card_only     the card is issued but the fee module has generated no
--                 challan for the cycle: the packet is the card alone, and the
--                 batch plan counts these candidates and lists them so the
--                 accountant can generate their challans and re-assemble.
--   withheld      a withheld result (FR-J08) produces NEITHER the card nor the
--                 packet: begin_report_card_packet() refuses with the same
--                 sentence the card gate uses. The challan is unaffected — it
--                 stays available from the fee module, which is the point of
--                 keeping it a reference rather than a part of the packet.
--
-- ── Where the PDF is made ───────────────────────────────────────────────
--
-- Postgres cannot render a PDF. As FR-J09 does, the database reserves the row
-- and the storage path in one transaction (begin_report_card_packet), the app
-- server (lib/report-cards/packet.ts — the "render-report-card-packet" the FR
-- names, in this repo's server runtime rather than an edge function) renders
-- and uploads, and attach_report_card_packet() seals it with the digest.

create table public.report_card_packet (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  exam_term_id   uuid not null references public.exam_term(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  report_card_id uuid not null references public.report_card(id) on delete cascade,
  -- Null = the card alone (no challan generated for the cycle).
  challan_id     uuid references public.fee_challan(id) on delete set null,
  billing_period date,
  -- A copy of fee_challan.net_paisa read live at assembly. Never computed here.
  payable_paisa  bigint,
  storage_path   text not null,
  checksum       text,
  assembled_by   uuid references public.app_user(user_id),
  assembled_at   timestamptz,
  created_at     timestamptz not null default now(),
  constraint chk_packet_challan_amount check ((challan_id is null) = (payable_paisa is null))
);
create unique index uq_packet on public.report_card_packet (report_card_id);
create index idx_packet_campus_term on public.report_card_packet (tenant_id, campus_id, exam_term_id);
create index idx_packet_enrolment on public.report_card_packet (enrolment_id);
create index idx_packet_challan on public.report_card_packet (challan_id);

create trigger report_card_packet_audit after insert or update or delete on public.report_card_packet
  for each row execute function app.tg_audit_row();

comment on table public.report_card_packet is
  'FR-J11: the report card followed by the next cycle''s 3-copy challan, one PDF. payable_paisa is a copy of the fee module''s fee_challan.net_paisa, never a computation.';

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.report_card_packet enable row level security;

create policy packet_campus_scope on public.report_card_packet
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller',
                            'class_teacher', 'accountant')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()))
  );

-- A parent gets their own child's packet, and nothing while the result is
-- withheld — the same anti-join report_card_parent_own_child carries.
create policy packet_parent_own_child on public.report_card_packet
  for select to authenticated
  using (
    assembled_at is not null
    and enrolment_id in (select id from public.enrolment where student_id = any (app.auth_guardian_student_ids()))
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
  );

-- No DML policy: begin_/attach_report_card_packet are the only writers.

-- ═══════════════════════════════════════════════════════════════════════
-- Which challan
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_packet_challan(
  p_enrolment_id   uuid,
  p_card_issued_at timestamptz,
  p_billing_period date
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
    from public.fee_challan c
   where c.enrolment_id = p_enrolment_id
     and c.deleted_at is null
     and c.status <> 'cancelled'
     and (
       (p_billing_period is not null
        and date_trunc('month', c.billing_period) = date_trunc('month', p_billing_period))
       or
       (p_billing_period is null
        and date_trunc('month', c.billing_period) > date_trunc('month', p_card_issued_at at time zone 'Asia/Karachi'))
     )
   order by c.billing_period, c.created_at desc
   limit 1;
$$;
revoke execute on function app.fn_packet_challan(uuid, timestamptz, date) from public, anon, authenticated;

create or replace function app.fn_packet_roles_ok()
returns boolean
language sql
stable
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller',
                             'class_teacher', 'accountant');
$$;
revoke execute on function app.fn_packet_roles_ok() from public, anon;
grant execute on function app.fn_packet_roles_ok() to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Batch plan (AC2's "batch summary lists the affected candidate count")
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_report_card_packet_plan(
  p_exam_term_id   uuid,
  p_section_id     uuid,
  p_billing_period date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_sec    record;
  v_rows   jsonb;
begin
  if v_tenant is null or not app.fn_packet_roles_ok() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select id, tenant_id, campus_id, name into v_sec from public.class_section where id = p_section_id;
  if v_sec.id is null or v_sec.tenant_id <> v_tenant then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_sec.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.exam_term where id = p_exam_term_id and tenant_id = v_tenant) then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(r.row order by r.roll_no nulls last, r.student_name), '[]'::jsonb)
    into v_rows
    from (
      select e.roll_no, st.name_en as student_name,
             jsonb_build_object(
               'enrolment_id', e.id, 'student_name', st.name_en, 'gr_number', st.gr_number, 'roll_no', e.roll_no,
               'report_card_id', rc.id, 'challan_id', ch.id, 'challan_no', ch.challan_no,
               'payable_paisa', ch.net_paisa, 'due_date', ch.due_date,
               'packet_id', pk.id, 'assembled', pk.assembled_at is not null,
               'status', case
                 when app.fn_result_withheld(e.id, p_exam_term_id) then 'withheld'
                 when rc.id is null then 'no_card'
                 when ch.id is null then 'card_only'
                 else 'with_challan' end) as row
        from public.enrolment e
        join public.student st on st.id = e.student_id
        left join lateral (
          select r.id, r.rendered_at from public.report_card r
           where r.enrolment_id = e.id and r.exam_term_id = p_exam_term_id and r.status = 'issued'
           order by r.revision_no desc limit 1
        ) rc on true
        left join public.fee_challan ch
               on ch.id = app.fn_packet_challan(e.id, rc.rendered_at, p_billing_period)
        left join public.report_card_packet pk on pk.report_card_id = rc.id
       where e.section_id = p_section_id and e.status = 'active' and e.deleted_at is null
    ) r;

  return jsonb_build_object(
    'exam_term_id', p_exam_term_id,
    'section_id', p_section_id,
    'billing_period', p_billing_period,
    'total', jsonb_array_length(v_rows),
    'with_challan_count', (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'status' = 'with_challan'),
    'card_only_count',    (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'status' = 'card_only'),
    'withheld_count',     (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'status' = 'withheld'),
    'no_card_count',      (select count(*) from jsonb_array_elements(v_rows) x where x ->> 'status' = 'no_card'),
    'card_only', (select coalesce(jsonb_agg(x -> 'student_name'), '[]'::jsonb)
                    from jsonb_array_elements(v_rows) x where x ->> 'status' = 'card_only'),
    'candidates', v_rows);
end;
$$;
revoke execute on function public.fn_report_card_packet_plan(uuid, uuid, date) from public, anon;
grant execute on function public.fn_report_card_packet_plan(uuid, uuid, date) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Reserve
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.begin_report_card_packet(
  p_enrolment_id   uuid,
  p_exam_term_id   uuid,
  p_billing_period date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_enr     record;
  v_card    public.report_card%rowtype;
  v_challan public.fee_challan%rowtype;
  v_challan_id uuid;
  v_path    text;
  v_id      uuid;
begin
  if v_tenant is null or not app.fn_packet_roles_ok() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select e.id, e.tenant_id, e.campus_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enr.tenant_id <> v_tenant
     or (app.auth_role() not in ('super_admin', 'owner') and not (v_enr.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.exam_term where id = p_exam_term_id and tenant_id = v_tenant) then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- AC4: a withheld result produces neither the card nor the packet. FR-J08's
  -- own gate, so the sentence a person reads is the one the card gate prints.
  begin
    perform public.fn_assert_result_disclosable(p_enrolment_id, p_exam_term_id);
  exception when check_violation then
    raise exception '%', sqlerrm using errcode = '23514', detail = 'result_withheld';
  end;

  select * into v_card from public.report_card rc
   where rc.enrolment_id = p_enrolment_id and rc.exam_term_id = p_exam_term_id and rc.status = 'issued'
   order by rc.revision_no desc limit 1;
  if v_card.id is null then
    raise exception 'REPORT_CARD_NOT_ISSUED' using errcode = '23514',
      hint = 'Issue the report card first; the packet is that card followed by the challan.';
  end if;

  v_challan_id := app.fn_packet_challan(p_enrolment_id, v_card.rendered_at, p_billing_period);
  if v_challan_id is not null then
    select * into v_challan from public.fee_challan where id = v_challan_id;
  end if;

  v_path := format('%s/%s/%s/packet-%s.pdf', v_card.tenant_id, v_card.campus_id, v_card.exam_term_id, v_card.enrolment_id);

  -- Re-assembling (a challan generated since) rewrites the same row and the
  -- same object; the amount is read from the fee module again, never carried.
  insert into public.report_card_packet (tenant_id, campus_id, exam_term_id, enrolment_id, report_card_id,
                                         challan_id, billing_period, payable_paisa, storage_path, assembled_by)
  values (v_card.tenant_id, v_card.campus_id, v_card.exam_term_id, v_card.enrolment_id, v_card.id,
          v_challan_id, case when v_challan_id is not null then v_challan.billing_period end,
          case when v_challan_id is not null then v_challan.net_paisa end, v_path, (select auth.uid()))
  on conflict (report_card_id) do update
    set challan_id = excluded.challan_id,
        billing_period = excluded.billing_period,
        payable_paisa = excluded.payable_paisa,
        assembled_by = excluded.assembled_by,
        assembled_at = null,
        checksum = null
  returning id into v_id;

  return jsonb_build_object(
    'packet_id', v_id,
    'report_card_id', v_card.id,
    'challan_id', v_challan_id,
    'with_challan', v_challan_id is not null,
    'payable_paisa', v_challan.net_paisa,
    'storage_path', v_path,
    'snapshot', v_card.payload_snapshot,
    'challan', case when v_challan_id is not null then app.fn_challan_payload(v_challan_id) end);
end;
$$;
revoke execute on function public.begin_report_card_packet(uuid, uuid, date) from public, anon;
grant execute on function public.begin_report_card_packet(uuid, uuid, date) to authenticated;

create or replace function public.attach_report_card_packet(p_packet_id uuid, p_sha256 text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or not app.fn_packet_roles_ok() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'CHECKSUM_INVALID' using errcode = '22023';
  end if;
  update public.report_card_packet
     set checksum = p_sha256, assembled_at = clock_timestamp()
   where id = p_packet_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'PACKET_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.attach_report_card_packet(uuid, text) from public, anon;
grant execute on function public.attach_report_card_packet(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Storage: the packet shares the report-cards bucket
-- ═══════════════════════════════════════════════════════════════════════

create policy report_cards_insert_packet on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'report-cards'
    and app.fn_packet_roles_ok()
    and exists (select 1 from public.report_card_packet p
                 where p.storage_path = objects.name and p.tenant_id = app.auth_tenant_id())
  );

-- Re-assembly overwrites the object under the same path.
create policy report_cards_update_packet on storage.objects
  for update to authenticated
  using (
    bucket_id = 'report-cards'
    and app.fn_packet_roles_ok()
    and exists (select 1 from public.report_card_packet p
                 where p.storage_path = objects.name and p.tenant_id = app.auth_tenant_id())
  )
  with check (
    bucket_id = 'report-cards'
    and exists (select 1 from public.report_card_packet p
                 where p.storage_path = objects.name and p.tenant_id = app.auth_tenant_id())
  );

-- Read follows the packet register's own visibility (including the parent
-- anti-join), since the subquery is subject to report_card_packet's RLS.
create policy report_cards_read_packet on storage.objects
  for select to authenticated
  using (
    bucket_id = 'report-cards'
    and exists (select 1 from public.report_card_packet p where p.storage_path = objects.name)
  );
