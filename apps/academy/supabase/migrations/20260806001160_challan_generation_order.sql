-- Challan numbers came out in whatever order the database returned enrolments, so a run did
-- not number challans by class and admission and two identical runs could number differently.
-- Generate them in class order, then by GR number.

CREATE OR REPLACE FUNCTION public.generate_challans(p_campus_id uuid, p_session_id uuid, p_period date, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_batch_id       uuid;
  v_month          int := extract(month from p_period)::int;
  v_period_start   date := date_trunc('month', p_period)::date;
  v_period_end     date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_generated      int := 0;
  v_skipped        int := 0;
  v_failed         int := 0;
  v_enrol          record;
  v_gross          bigint;
  v_concession     bigint;
  v_anc_gross      bigint;
  v_anc_conc       bigint;
  v_arrears        bigint;
  v_arrears_source jsonb;
  v_gap_head       text;
  v_challan_id     uuid;
  v_challan_no     text;
  v_preview        jsonb := '{}'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not p_dry_run then
    insert into public.fee_challan_batch (tenant_id, campus_id, session_id, billing_period, requested_by)
    values (v_tenant_id, p_campus_id, p_session_id, v_period_start, auth.uid())
    returning id into v_batch_id;
  end if;

  for v_enrol in
    select e.id as enrolment_id, e.class_level_id, fp.id as plan_id, cl.name_en as class_name
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.class_level cl on cl.id = e.class_level_id
      left join public.fee_plan fp on fp.enrolment_id = e.id
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_session_id
       and e.status = 'active' and s.status = 'active'
       and e.deleted_at is null and s.deleted_at is null
     order by cl.ordinal, s.gr_number, e.id
  loop
    if exists (
      select 1 from public.fee_challan
       where enrolment_id = v_enrol.enrolment_id and session_id = p_session_id
         and billing_period = v_period_start and status <> 'cancelled'
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if v_enrol.plan_id is null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'NO_FEE_PLAN');
      end if;
      continue;
    end if;

    select fh.code into v_gap_head
      from public.fee_head fh
     where fh.tenant_id = v_tenant_id and fh.is_mandatory
       and not exists (
         select 1 from public.fee_plan_line fpl where fpl.plan_id = v_enrol.plan_id and fpl.fee_head_id = fh.id
       )
     limit 1;
    if v_gap_head is not null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'MANDATORY_HEAD_COVERAGE_GAP: ' || v_gap_head);
      end if;
      continue;
    end if;

    select coalesce(sum(amount_paisa), 0), coalesce(sum(concession_paisa), 0)
      into v_gross, v_concession
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

    -- Transport / hostel / mess / library recovery already on the ledger and not yet on a challan.
    if not p_dry_run then
      perform pg_advisory_xact_lock(hashtextextended('challan-ancillary:' || v_enrol.enrolment_id::text, 0));
    end if;
    select coalesce(sum(a.gross_paisa), 0), coalesce(sum(a.concession_paisa), 0)
      into v_anc_gross, v_anc_conc
      from app.fn_ancillary_challan_lines(v_enrol.enrolment_id, v_period_end) a;

    if v_gross + v_anc_gross = 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if p_dry_run then
      v_preview := jsonb_set(
        v_preview, array[v_enrol.class_name],
        to_jsonb(coalesce((v_preview ->> v_enrol.class_name)::bigint, 0) + (v_gross + v_anc_gross - v_concession - v_anc_conc))
      );
      v_generated := v_generated + 1;
      continue;
    end if;

    -- Read before any of this period's own charge/concession entries are posted below. What this
    -- challan bills on its own ancillary lines is excluded: it is not "carried forward".
    select coalesce(sum(b.amount_paisa), 0)::bigint,
           coalesce(jsonb_agg(jsonb_build_object(
             'enrolment_id', b.source_enrolment_id,
             'session_id', b.source_session_id,
             'amount_paisa', b.amount_paisa
           ) order by b.amount_paisa desc), '[]'::jsonb)
      into v_arrears, v_arrears_source
      from app.fn_arrears_breakdown_excl(v_enrol.enrolment_id, v_anc_gross - v_anc_conc) b;

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    begin
      insert into public.fee_challan (
        tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
        due_date, gross_paisa, concession_paisa, arrears_paisa, arrears_source, net_paisa, batch_id
      ) values (
        v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
        v_period_end + 10, v_gross + v_anc_gross, v_concession + v_anc_conc, v_arrears, v_arrears_source,
        v_gross + v_anc_gross - v_concession - v_anc_conc + v_arrears, v_batch_id
      ) returning id into v_challan_id;

      insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type, applied_award_ids)
      select v_challan_id, fee_head_id, amount_paisa, concession_paisa, amount_paisa - concession_paisa, 'charge', applied_award_ids
        from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

      insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type)
      select v_challan_id, a.fee_head_id, a.gross_paisa, a.concession_paisa, a.gross_paisa - a.concession_paisa, 'charge'
        from app.fn_ancillary_challan_lines(v_enrol.enrolment_id, v_period_end) a
       where a.gross_paisa > 0;

      insert into public.fee_challan_ledger_link (ledger_id, challan_id, tenant_id, fee_head_id, amount_paisa, direction)
      select l.id, v_challan_id, v_tenant_id, l.fee_head_id, l.amount_paisa, l.direction
        from app.fn_ancillary_challan_lines(v_enrol.enrolment_id, v_period_end) a
        join public.fee_ledger l on l.id = any (a.ledger_ids);

      -- Only the plan charge is posted: the ancillary debits are already on the ledger.
      if v_gross > 0 then
        perform public.post_ledger_entry(
          v_enrol.enrolment_id, 'charge', v_gross, 'debit', null, v_period_start, 'fee_challan', v_challan_id
        );
      end if;
      if v_concession > 0 then
        perform public.post_ledger_entry(
          v_enrol.enrolment_id, 'concession', v_concession, 'credit', null, v_period_start, 'fee_challan', v_challan_id
        );
      end if;

      perform public.apply_advance_credit(v_enrol.enrolment_id, v_challan_id);

      v_generated := v_generated + 1;
    exception
      when unique_violation then
        v_skipped := v_skipped + 1;
    end;
  end loop;

  if not p_dry_run then
    update public.fee_challan_batch
       set generated_count = v_generated, skipped_count = v_skipped, failed_count = v_failed, completed_at = now()
     where id = v_batch_id;
  end if;

  return jsonb_build_object(
    'batch_id', v_batch_id, 'generated', v_generated, 'skipped', v_skipped, 'failed', v_failed,
    'dry_run', p_dry_run, 'preview_by_class', v_preview
  );
end;
$function$;
