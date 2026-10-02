-- FR-K03: fee structure versioning and effective dating.
--
-- Accounting-specific care:
--   * "published structures are immutable; create version 2" (the AC's
--     own words) is enforced twice, on purpose: add_structure_line()
--     already only permits inserts on a draft (FR-K02), and
--     fee_structure_line has never had an UPDATE/DELETE RLS policy for
--     authenticated at all — so a published line was already
--     unreachable by any code path. fee_structure_immutable_bu adds a
--     third layer, a trigger that fires regardless of caller or future
--     code path, with the exact message the AC quotes, rather than
--     leaving "immutable" as an emergent property of what happens to be
--     missing.
--   * create_next_structure_version() is "copy, then revise" — the new
--     draft starts as an exact clone of the prior published structure's
--     lines (same amounts), and update_structure_line_amount() is the
--     one function that can then change a DRAFT line's price. Cloning
--     first means an accountant revising 2 of 40 lines doesn't have to
--     re-enter the other 38 from scratch, and it's what makes "average
--     increase across the whole structure" (the regulator-cap check
--     below) a meaningful comparison against a matched prior version.
--   * The regulator cap check (fee_policy.max_fee_increase_pct) reuses
--     FR-K08's fee_policy table rather than a new one — it's the same
--     kind of thing, one more tenant-wide financial-policy knob.
--     Matching lines by (class_id, fee_head_id, coalesce(group_code,''))
--     mirrors fee_structure_line_uq's own uniqueness key exactly, so
--     "the corresponding line in the prior version" has one unambiguous
--     definition already used elsewhere in this schema. Brand-new lines
--     with no prior counterpart are excluded from the average — they are
--     new charges, not a price increase on an existing one.
--   * resolve_fee_structure(campus, session, period_start) is what makes
--     "the December challan used version 1's amounts, the January
--     challan used version 2's" possible: it picks whichever version
--     (published OR superseded) was actually effective on a given
--     historical date, not just "whatever's published now".
--
-- Scope cut, stated plainly: resolve_fee_structure() is built and fully
-- tested here, but FR-K09's generate_challans() is NOT changed in this
-- migration to call it. Today, generate_challans() still charges
-- whatever amount_paisa FR-K04 snapshotted onto fee_plan_line at
-- enrolment time — a deliberate, already-tested design (FR-K04's own
-- migration) that a later structure edit must never silently rewrite.
-- Making per-period billing actually resolve a different structure
-- version for different billing months means changing what
-- fee_plan_line represents and how challan generation reads it — a
-- real, cross-cutting change to FR-K04's own boundary, not a side
-- effect this migration should sneak in. resolve_fee_structure() is the
-- correct building block for that future integration; wiring it into
-- the generation loop is left for the FR that owns that decision.

alter table public.fee_structure add column supersedes_id uuid references public.fee_structure(id);
alter table public.fee_structure add column regulator_reference text;
alter table public.fee_structure add column approved_by uuid references public.app_user(user_id);

alter table public.fee_policy add column max_fee_increase_pct numeric(5, 2)
  check (max_fee_increase_pct is null or (max_fee_increase_pct >= 0 and max_fee_increase_pct <= 1000));

create table public.fee_increase_approval (
  id                uuid primary key default gen_random_uuid(),
  structure_id      uuid not null references public.fee_structure(id),
  approver_id       uuid references public.app_user(user_id),
  avg_increase_pct  numeric(7, 2) not null,
  regulator_reference text not null,
  approved_at       timestamptz not null default clock_timestamp(),
  constraint chk_fee_increase_regulator_reference_length check (length(btrim(regulator_reference)) >= 4)
);

create index idx_fee_increase_approval_structure on public.fee_increase_approval (structure_id);

-- No role check, no exception for who's calling — a published line is
-- immutable, full stop. Same posture as FR-K14/K15's fee_ledger_no_mutate.
create or replace function app.tg_fee_structure_line_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.fee_structure_status;
begin
  select status into v_status from public.fee_structure where id = coalesce(old.structure_id, new.structure_id);
  if v_status = 'published' then
    raise exception 'published structures are immutable; create version 2' using errcode = '42501';
  end if;
  -- Draft: let the write through. A BEFORE UPDATE trigger must return
  -- NEW to let the update apply (returning OLD here would silently
  -- discard every legitimate draft-line edit, not just block published
  -- ones) — DELETE has no NEW row, so OLD is correct there.
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger fee_structure_line_immutable_bu before update or delete on public.fee_structure_line
  for each row execute function app.tg_fee_structure_line_immutable();

create or replace function public.create_next_structure_version(p_prior_structure_id uuid, p_effective_from date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prior public.fee_structure%rowtype;
  v_new_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_prior from public.fee_structure where id = p_prior_structure_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STRUCTURE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_prior.status <> 'published' then
    raise exception 'PRIOR_STRUCTURE_NOT_PUBLISHED' using errcode = '55000';
  end if;

  insert into public.fee_structure (
    tenant_id, campus_id, session_id, version_no, supersedes_id, effective_from, created_by
  ) values (
    v_prior.tenant_id, v_prior.campus_id, v_prior.session_id, v_prior.version_no + 1, v_prior.id, p_effective_from, auth.uid()
  )
  returning id into v_new_id;

  insert into public.fee_structure_line (structure_id, class_id, group_code, fee_head_id, amount_paisa, frequency, billing_month_mask)
  select v_new_id, class_id, group_code, fee_head_id, amount_paisa, frequency, billing_month_mask
    from public.fee_structure_line
   where structure_id = p_prior_structure_id;

  return v_new_id;
end;
$$;

revoke execute on function public.create_next_structure_version(uuid, date) from public, anon;
grant execute on function public.create_next_structure_version(uuid, date) to authenticated;

create or replace function public.update_structure_line_amount(p_line_id uuid, p_amount_paisa bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.fee_structure_status;
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select fs.status, fs.tenant_id into v_status, v_tenant_id
    from public.fee_structure_line fsl join public.fee_structure fs on fs.id = fsl.structure_id
   where fsl.id = p_line_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STRUCTURE_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'STRUCTURE_NOT_DRAFT' using errcode = '55000';
  end if;

  update public.fee_structure_line set amount_paisa = p_amount_paisa where id = p_line_id;
end;
$$;

revoke execute on function public.update_structure_line_amount(uuid, bigint) from public, anon;
grant execute on function public.update_structure_line_amount(uuid, bigint) to authenticated;

-- Widened: publish_fee_structure() now takes an optional regulator
-- reference, needed only when the revision's average increase exceeds
-- the tenant's configured cap. New parameter, so a new overload rather
-- than a same-signature replace — drop the old one first, same pattern
-- as every other widened function in this module.
drop function if exists public.publish_fee_structure(uuid);

create or replace function public.publish_fee_structure(p_structure_id uuid, p_regulator_reference text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_structure public.fee_structure%rowtype;
  v_gaps      text;
  v_avg_pct   numeric(7, 2);
  v_cap_pct   numeric(5, 2);
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_structure from public.fee_structure where id = p_structure_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STRUCTURE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_structure.status <> 'draft' then
    raise exception 'STRUCTURE_NOT_DRAFT' using errcode = '55000';
  end if;

  select string_agg(cl.name_en || '/' || fh.code, ', ')
    into v_gaps
    from public.class_level cl
    cross join public.fee_head fh
   where cl.tenant_id = app.auth_tenant_id() and cl.is_active
     and fh.tenant_id = app.auth_tenant_id() and fh.is_mandatory
     and not exists (
       select 1 from public.fee_structure_line l
        where l.structure_id = p_structure_id and l.class_id = cl.id and l.fee_head_id = fh.id
     );
  if v_gaps is not null then
    raise exception 'MANDATORY_HEAD_COVERAGE_GAP' using errcode = '55000', detail = v_gaps;
  end if;

  if v_structure.supersedes_id is not null then
    select avg((new_l.amount_paisa - old_l.amount_paisa)::numeric / old_l.amount_paisa * 100)
      into v_avg_pct
      from public.fee_structure_line new_l
      join public.fee_structure_line old_l
        on old_l.structure_id = v_structure.supersedes_id
       and old_l.class_id = new_l.class_id
       and coalesce(old_l.group_code, '') = coalesce(new_l.group_code, '')
       and old_l.fee_head_id = new_l.fee_head_id
       and old_l.amount_paisa > 0
     where new_l.structure_id = p_structure_id;

    select max_fee_increase_pct into v_cap_pct from public.fee_policy where tenant_id = app.auth_tenant_id();

    if v_avg_pct is not null and v_cap_pct is not null and v_avg_pct > v_cap_pct then
      if app.auth_role() not in ('super_admin', 'owner') then
        raise exception 'FORBIDDEN' using errcode = '42501';
      end if;
      if p_regulator_reference is null or length(btrim(p_regulator_reference)) < 4 then
        raise exception 'REGULATOR_REFERENCE_REQUIRED' using errcode = '23514';
      end if;

      insert into public.fee_increase_approval (structure_id, approver_id, avg_increase_pct, regulator_reference)
      values (p_structure_id, auth.uid(), v_avg_pct, p_regulator_reference);

      update public.fee_structure
         set regulator_reference = p_regulator_reference, approved_by = auth.uid()
       where id = p_structure_id;
    end if;
  end if;

  update public.fee_structure
     set status = 'superseded'
   where campus_id = v_structure.campus_id and session_id = v_structure.session_id and status = 'published';

  update public.fee_structure
     set status = 'published', published_by = auth.uid(), published_at = now()
   where id = p_structure_id;
end;
$$;

revoke execute on function public.publish_fee_structure(uuid, text) from public, anon;
grant execute on function public.publish_fee_structure(uuid, text) to authenticated;

-- Picks whichever version (published OR superseded — a superseded
-- version is still the historically correct one for a period before its
-- successor's effective_from) was actually in force on a given date.
create or replace function public.resolve_fee_structure(p_campus_id uuid, p_session_id uuid, p_period_start date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.fee_structure
   where campus_id = p_campus_id and session_id = p_session_id
     and tenant_id = app.auth_tenant_id()
     and status in ('published', 'superseded')
     and effective_from <= p_period_start
   order by effective_from desc, version_no desc
   limit 1;
$$;

revoke execute on function public.resolve_fee_structure(uuid, uuid, date) from public, anon;
grant execute on function public.resolve_fee_structure(uuid, uuid, date) to authenticated;

alter table public.fee_increase_approval enable row level security;

create policy fee_increase_approval_owner_read on public.fee_increase_approval
  for select to authenticated
  using (
    structure_id in (
      select id from public.fee_structure
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
