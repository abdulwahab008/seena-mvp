-- Sibling rank (which child pays full fee and which get the sibling discount) was decided by when each
-- student record was created, so after a bulk import the "eldest" was whichever row came first in the file.
-- Rank is now by date of birth, eldest first; creation time only breaks ties (twins).
CREATE OR REPLACE FUNCTION public.detect_sibling_groups(p_campus_id uuid, p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select max(sibling_rank) into v_max_rank from public.sibling_discount_scheme_rank where tenant_id = v_tenant_id;

  for v_group in
    select app.fn_normalize_pk_id(g.cnic) as cnic_norm, array_agg(e.id order by s.dob, s.created_at) as enrolment_ids
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
$function$;
