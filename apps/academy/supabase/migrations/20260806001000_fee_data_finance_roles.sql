-- Fee data is for the people who handle fees.
--
-- Found by signing in as every role: a class teacher, subject teacher, librarian or nurse could open
-- /fees and read every family's challans, ledger, payments and receipts, download any challan PDF,
-- see each student's balance and fee plan on the student profile, and read the same tables through
-- the API. The newer finance tables (settlements, bank statements, gateway payments, reminders,
-- deposits) already limit reads to the owner, super admin, accountant and principal; the core fee
-- tables only asked for "a campus the caller is assigned to", which is every colleague.
--
--  * app.fn_fee_staff() is the one place that says who: super admin, owner, principal and accountant,
--    exactly the roles the newer finance tables use. app.fn_fee_balance_viewer() adds the vice
--    principal and the exam controller, who run the result withholds that depend on what a family
--    owes (the withhold sheet shows each balance by design).
--  * The root read policy of each core fee table (challans and batches, ledger, payments, receipts,
--    fee plans, fee structure, concession awards, late fee rules, sibling groups, the challan
--    template, admission fee payments and waivers) now requires one of those roles, on top of the
--    campus rule it already had. Their line and detail tables read through the root table, so they
--    follow. Parent and student sessions keep exactly what they had (the portal boundary decides
--    that); the admissions officer keeps concession awards and sibling groups, which they request
--    and detect, and admission fee payments and waivers stay readable by the admissions staff.
--  * The challan PDF and the student balance functions ask the same question for staff, so a teacher
--    can no longer download a family's challan or read a child's balance through them.
--  * fn_withhold_sheet() lists what every family owes and had no role check at all; it refuses
--    anyone who cannot see balances instead of quietly listing nobody.
--
-- A new fee table has to say who reads it; a pgTAP test lists the ones that matter.

create or replace function app.fn_fee_staff()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant');
$$;

create or replace function app.fn_fee_balance_viewer()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'accountant', 'vice_principal', 'exam_controller');
$$;

revoke all on function app.fn_fee_staff() from public, anon;
revoke all on function app.fn_fee_balance_viewer() from public, anon;
grant execute on function app.fn_fee_staff() to authenticated;
grant execute on function app.fn_fee_balance_viewer() to authenticated;

-- ── the root read policies ───────────────────────────────────────────────────────
-- Rebuilt from the policy as it stands, so a later change to it is kept.

do $$
declare
  r record;
  v_expr text;
begin
  for r in
    select * from (values
      ('fee_challan',            'fee_challan_campus_scope',          ''),
      ('fee_challan_batch',      'fee_challan_batch_campus_scope',    ''),
      ('fee_ledger',             'fee_ledger_select_campus_scope',    ''),
      ('fee_payment',            'fee_payment_campus_scope',          ''),
      ('fee_receipt',            'fee_receipt_campus_scope',          ''),
      ('fee_plan',               'fee_plan_campus_scope',             ''),
      ('late_fee_rule',          'late_fee_rule_campus_scope',        ''),
      ('fee_structure',          'fee_structure_campus_scope',        ' or app.auth_role() in (''parent'', ''student'')'),
      ('challan_template',       'challan_template_campus_scope',     ' or app.auth_role() in (''parent'', ''student'')'),
      ('concession_award',       'concession_award_campus_scope',     ' or app.auth_role() = ''admissions_officer'''),
      ('sibling_group',          'sibling_group_campus_scope',        ' or app.auth_role() = ''admissions_officer'''),
      ('admission_fee_payment',  'admission_fee_payment_tenant_read', ' or app.auth_role() in (''vice_principal'', ''admissions_officer'', ''receptionist'')'),
      ('admission_fee_waiver',   'admission_fee_waiver_tenant_read',  ' or app.auth_role() in (''vice_principal'', ''admissions_officer'', ''receptionist'')')
    ) as x(tbl, pol, extra)
  loop
    select pg_get_expr(p.polqual, p.polrelid) into v_expr
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
     where c.relnamespace = 'public'::regnamespace and c.relname = r.tbl and p.polname = r.pol;
    if v_expr is null then
      raise exception 'policy % on % not found', r.pol, r.tbl;
    end if;
    if v_expr !~ 'fn_fee_staff' then
      execute format(
        'alter policy %I on public.%I using ((%s) and (app.fn_fee_staff()%s))',
        r.pol, r.tbl, v_expr, r.extra
      );
    end if;
  end loop;
end $$;

-- ── the functions that answer "may this caller see this family's fees?" ──────────────

create or replace function app.fn_can_view_challan(p_challan_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
      from public.fee_challan c
      join public.enrolment e on e.id = c.enrolment_id
     where c.id = p_challan_id and c.tenant_id = app.auth_tenant_id()
       and (
         (app.auth_role() = 'parent' and e.student_id = any(app.auth_guardian_student_ids()))
         or (app.auth_role() not in ('parent', 'student')
             and app.fn_fee_staff()
             and (app.auth_role() in ('owner', 'super_admin') or c.campus_id = any(app.auth_campus_ids())))
       )
  );
$function$;

create or replace function app.fn_can_view_enrolment(p_enrolment_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
      from public.enrolment e
     where e.id = p_enrolment_id and e.tenant_id = app.auth_tenant_id()
       and (
         (app.auth_role() = 'parent' and e.student_id = any (app.auth_guardian_student_ids()))
         or (app.auth_role() = 'student' and e.student_id = public.my_student_id())
         or (app.auth_role() not in ('parent', 'student', 'none')
             and app.fn_fee_balance_viewer()
             and (app.auth_role() in ('owner', 'super_admin') or e.campus_id = any (app.auth_campus_ids())))
       )
  );
$function$;

create or replace function public.fn_withhold_sheet(p_exam_term_id uuid, p_class_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_term      record;
  v_role      text := app.auth_role();
  v_threshold bigint;
  v_rows      jsonb;
begin
  -- The sheet lists what each family owes: for the people who handle withholds and fees only.
  if app.auth_tenant_id() is not null and not app.fn_fee_balance_viewer() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select t.id, t.tenant_id, t.campus_id, t.session_id, t.name into v_term
    from public.exam_term t where t.id = p_exam_term_id;
  if v_term.id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_term.tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner')
       and not (v_term.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  v_threshold := app.fn_withhold_threshold_paisa(v_term.campus_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'enrolment_id',   c.enrolment_id,
           'student_name',   c.student_name,
           'gr_number',      c.gr_number,
           'roll_no',        c.roll_no,
           'section_name',   c.section_name,
           'balance_paisa',  c.balance_paisa,
           'is_withheld',    c.withhold_id is not null,
           'withhold_id',    c.withhold_id,
           'reason',         c.reason,
           'cutoff_date',    c.cutoff_date,
           'amount_outstanding_paisa', c.amount_outstanding_paisa,
           'threshold_paisa',          c.threshold_paisa,
           'message',        c.message,
           'is_debarred',    c.is_debarred,
           'last_release_kind',   c.last_release_kind,
           'last_release_reason', c.last_release_reason
         ) order by c.section_name, c.roll_no nulls last, c.student_name), '[]'::jsonb)
    into v_rows
    from (
      select e.id as enrolment_id,
             st.name_en as student_name,
             st.gr_number,
             e.roll_no,
             sec.name as section_name,
             greatest(coalesce(public.outstanding_balance_as_of(e.id, clock_timestamp()), 0), 0) as balance_paisa,
             w.id as withhold_id,
             w.reason,
             w.cutoff_date,
             w.amount_outstanding_paisa,
             w.threshold_paisa,
             case when w.id is not null then app.fn_withhold_message(w) end as message,
             exists (
               select 1 from public.subject_result sr
                where sr.enrolment_id = e.id and sr.exam_term_id = p_exam_term_id and sr.is_blocked
             ) as is_debarred,
             rel.release_kind as last_release_kind,
             rel.release_reason as last_release_reason
        from public.enrolment e
        join public.student st on st.id = e.student_id
        join public.class_section sec on sec.id = e.section_id
        left join lateral (
          select * from app.fn_open_withhold(e.id, p_exam_term_id)
        ) w on true
        left join lateral (
          select r.release_kind, r.release_reason
            from public.result_withhold r
           where r.enrolment_id = e.id and r.exam_term_id = p_exam_term_id
             and r.released_at is not null
           order by r.released_at desc
           limit 1
        ) rel on true
       where e.session_id = v_term.session_id
         and e.campus_id = v_term.campus_id
         and e.class_level_id = p_class_id
         and e.status = 'active'
         and e.deleted_at is null
    ) c;

  return jsonb_build_object(
    'exam_term_id',    p_exam_term_id,
    'exam_term_name',  v_term.name,
    'class_level_id',  p_class_id,
    'threshold_paisa', v_threshold,
    'can_sync',        v_role in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant'),
    'can_release',     v_role in ('super_admin', 'owner', 'principal', 'vice_principal'),
    'candidates',      v_rows
  );
end;
$function$;
