-- FR-K07: sibling detection and discount proposal.
--
-- Accounting-specific care:
--   * "Never auto-approve" (the Notes' own words) is enforced by routing
--     every proposal through request_concession_award() — the exact same
--     entry point a human uses from the student page — so a proposed
--     sibling award starts 'pending' and needs a real approval decision
--     through FR-K06's existing workflow. detect_sibling_groups() has no
--     path to concession_award.status = 'approved' at all.
--   * CNIC matching reuses app.fn_normalize_pk_id() (FR-C10) so
--     '35202-1234567-8' and '3520212345678' resolve to the same family —
--     the Notes call out dashes and Excel-stripped leading zeros as the
--     actual failure mode, not a hypothetical.
--   * Rank -> discount is a scheme lookup (sibling_discount_scheme_rank),
--     not a raw percentage baked into this migration: the AC's "10% and
--     15%" are this tenant's configured rates, not a universal constant,
--     and reusing concession_scheme means a proposed award still goes
--     through that scheme's own value/max_value/applicable_head_ids
--     validation — the same machinery every other concession in this
--     module already relies on.
--   * "Flags the remaining siblings for re-ranking, does not silently
--     keep the 3rd-child rate" (the eldest-withdraws AC): ranking here is
--     always computed fresh from the CURRENT active roster, never cached
--     — the moment the eldest is no longer 'active', they drop out of the
--     ranking and everyone else's rank shifts on the very next scan, the
--     same statelessness v_sibling_rank (FR-C08) already relies on.
--     Where this can't fully resolve on its own: an existing award whose
--     scheme no longer matches a member's new rank is not silently
--     edited or replaced — that decision needs a human, per the same
--     "never auto-approve" principle extended to "never auto-revise". It
--     is surfaced in the return payload's needs_review list instead.
--
-- Scope cuts:
--   * Proposed awards default to a 1-year effective window from today —
--     there is no natural "session end date" column on academic_session
--     to anchor to instead.
--   * The actual cron wiring (fees_sibling_scan, nightly 04:00) is not
--     created — no pg_cron locally, same as every other cron-shaped FR.
--     Unlike the purely-system FRs (K10, K13), this one's own actor list
--     names Accountant and Admissions Officer alongside System, so
--     detect_sibling_groups() is callable directly by those roles too,
--     not service_role-only — it is a real on-demand action as well as a
--     future scheduled one.

-- request_concession_award() (FR-K06) is the single entry point
-- detect_sibling_groups() reuses below rather than duplicating its own
-- value/date validation — but its role list didn't include
-- admissions_officer, one of THIS FR's own named actors. Widening it here
-- (same signature, CREATE OR REPLACE) rather than routing around it with
-- a second, parallel insert path.
create or replace function public.request_concession_award(
  p_enrolment_id uuid, p_scheme_id uuid, p_value numeric, p_effective_from date, p_effective_to date,
  p_document_paths text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment public.enrolment%rowtype;
  v_scheme    public.concession_scheme%rowtype;
  v_award_id  uuid;
  v_path      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_scheme from public.concession_scheme where id = p_scheme_id and tenant_id = app.auth_tenant_id() and is_active;
  if not found then
    raise exception 'CONCESSION_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_scheme.calc_type = 'percentage' and p_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  if v_scheme.requires_document and coalesce(array_length(p_document_paths, 1), 0) = 0 then
    raise exception 'DOCUMENT_REQUIRED' using errcode = '23514';
  end if;

  if p_effective_to <= p_effective_from then
    raise exception 'EFFECTIVE_TO_MUST_FOLLOW_FROM' using errcode = '23514';
  end if;

  insert into public.concession_award (
    tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, requested_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_scheme_id, v_scheme.calc_type, p_value, p_effective_from, p_effective_to, auth.uid()
  )
  returning id into v_award_id;

  foreach v_path in array p_document_paths loop
    insert into public.concession_award_document (award_id, storage_path, uploaded_by) values (v_award_id, v_path, auth.uid());
  end loop;

  return v_award_id;
end;
$$;

create table public.sibling_group (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  session_id           uuid not null references public.academic_session(id) on delete cascade,
  guardian_cnic_norm   text not null,
  member_enrolment_ids uuid[] not null,
  last_scanned_at      timestamptz not null default clock_timestamp()
);

create unique index uq_sibling_group_cnic on public.sibling_group (tenant_id, campus_id, session_id, guardian_cnic_norm);

create table public.sibling_discount_scheme_rank (
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  sibling_rank smallint not null check (sibling_rank >= 2),
  scheme_id    uuid not null references public.concession_scheme(id),
  primary key (tenant_id, sibling_rank)
);

create or replace function public.set_sibling_discount_scheme(p_sibling_rank smallint, p_scheme_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.concession_scheme where id = p_scheme_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CONCESSION_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.sibling_discount_scheme_rank (tenant_id, sibling_rank, scheme_id)
  values (app.auth_tenant_id(), p_sibling_rank, p_scheme_id)
  on conflict (tenant_id, sibling_rank) do update set scheme_id = excluded.scheme_id;
end;
$$;

revoke execute on function public.set_sibling_discount_scheme(smallint, uuid) from public, anon;
grant execute on function public.set_sibling_discount_scheme(smallint, uuid) to authenticated;

create or replace function public.detect_sibling_groups(p_campus_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_max_rank       smallint;
  v_group          record;
  v_member         record;
  v_rank           int;
  v_scheme_id      uuid;
  v_groups_found   int := 0;
  v_proposals      int := 0;
  v_needs_review   jsonb := '[]'::jsonb;
  v_existing_award public.concession_award%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select max(sibling_rank) into v_max_rank from public.sibling_discount_scheme_rank where tenant_id = v_tenant_id;

  for v_group in
    select app.fn_normalize_pk_id(g.cnic) as cnic_norm, array_agg(e.id order by s.created_at) as enrolment_ids
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.student_guardian sg on sg.student_id = s.id and sg.to_date is null and sg.relationship = 'father'
      join public.guardian g on g.id = sg.guardian_id and g.cnic is not null
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_session_id
       and e.status = 'active' and s.status = 'active'
     group by app.fn_normalize_pk_id(g.cnic)
    having count(*) >= 2
  loop
    v_groups_found := v_groups_found + 1;

    insert into public.sibling_group (tenant_id, campus_id, session_id, guardian_cnic_norm, member_enrolment_ids)
    values (v_tenant_id, p_campus_id, p_session_id, v_group.cnic_norm, v_group.enrolment_ids)
    on conflict (tenant_id, campus_id, session_id, guardian_cnic_norm)
      do update set member_enrolment_ids = excluded.member_enrolment_ids, last_scanned_at = clock_timestamp();

    v_rank := 0;
    for v_member in select unnest(v_group.enrolment_ids) as enrolment_id loop
      v_rank := v_rank + 1;

      -- The scheme this member's CURRENT rank is entitled to — null for
      -- the eldest (rank 1) or if no scheme is configured that high.
      -- Checked for every member, rank 1 included: a member whose rank
      -- just dropped to 1 (an elder sibling left) still needs their old
      -- award inspected, not silently skipped.
      v_scheme_id := null;
      if v_rank >= 2 and v_max_rank is not null then
        select scheme_id into v_scheme_id
          from public.sibling_discount_scheme_rank
         where tenant_id = v_tenant_id and sibling_rank = least(v_rank, v_max_rank)::smallint;
      end if;

      select * into v_existing_award
        from public.concession_award
       where enrolment_id = v_member.enrolment_id
         and scheme_id in (select scheme_id from public.sibling_discount_scheme_rank where tenant_id = v_tenant_id)
         and status in ('pending', 'approved')
       limit 1;

      if found then
        if v_existing_award.scheme_id <> v_scheme_id or v_scheme_id is null then
          -- Existing award's scheme no longer matches this rank (or this
          -- rank no longer qualifies at all) — the rank shifted. Flagged
          -- for a human, not silently changed.
          v_needs_review := v_needs_review || jsonb_build_object(
            'enrolment_id', v_member.enrolment_id, 'current_rank', v_rank, 'existing_award_id', v_existing_award.id
          );
        end if;
        -- Correct scheme already pending/approved: nothing to do.
        continue;
      end if;

      if v_scheme_id is null then
        continue;
      end if;

      perform public.request_concession_award(
        v_member.enrolment_id, v_scheme_id,
        (select value from public.concession_scheme where id = v_scheme_id),
        current_date, (current_date + interval '1 year')::date
      );
      v_proposals := v_proposals + 1;
    end loop;
  end loop;

  return jsonb_build_object(
    'groups_found', v_groups_found, 'proposals_created', v_proposals, 'needs_review', v_needs_review
  );
end;
$$;

revoke execute on function public.detect_sibling_groups(uuid, uuid) from public, anon;
grant execute on function public.detect_sibling_groups(uuid, uuid) to authenticated;

alter table public.sibling_group enable row level security;
alter table public.sibling_discount_scheme_rank enable row level security;

create policy sibling_group_campus_scope on public.sibling_group
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy sibling_discount_scheme_rank_tenant_read on public.sibling_discount_scheme_rank
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
