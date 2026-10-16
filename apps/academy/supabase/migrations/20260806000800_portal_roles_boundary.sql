-- Parents and students are not staff: they read their own family's data and nothing else.
--
-- Parent and student tokens carry campus_ids (the campuses their children study at), and most
-- row-level security policies in this schema say "owner OR campus_id = any (token campus ids)".
-- So every parent and every student could read, through the API, whatever staff of that campus
-- can read: the staff register with CNIC numbers, employee bank details, every family's fee ledger,
-- payments and concession awards, other families' admission enquiries, the messaging queue and
-- inbound WhatsApp messages, the school's internal policies; and, for a handful of tables whose
-- policy covers every command (messages, message batches, trigger rules, student remarks, student
-- portal accounts, campus portal policy), could also insert, change and delete rows. The portal
-- itself never reads or writes most of this: it reads a short list of tables and views, and every
-- write goes through a SECURITY DEFINER function.
--
-- This puts the boundary where it belongs, in one place instead of two hundred policies:
--  * app.fn_portal_tables() is the list of tables parents and students may read (their own rows
--    only, as each table's own policies decide). Every other table in public gets a RESTRICTIVE
--    policy, portal_roles_blocked, that refuses the parent and student roles for every command.
--    A restrictive policy is ANDed with whatever permissive policies exist, so nothing else changes
--    for staff, the service role or anyone signed out.
--  * The tables on the list get restrictive insert/update/delete policies too, so a parent or a
--    student can never write one directly (the portal never does).
--  * The result tables whose staff policy only excluded parents ("role <> 'parent'") are closed to
--    the student role as well; students read their own results through subject_result and
--    result_position.
--  * Four policies on listed tables that applied to every command and let in the whole campus
--    (student remarks, remark versions, student portal accounts, campus portal policy) now exclude
--    the portal roles, so a parent sees only the remarks their own policy gives them.
--
-- A new table has to be classified: either it goes on the list in app.fn_portal_tables() (and
-- gets app.fn_restrict_portal_writes) or it gets app.fn_block_portal_roles(). A pgTAP test fails
-- until it does.

create or replace function app.fn_portal_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
      -- the portal's own reads (pages, views, embedded relations, download routes and the tables
      -- their policies and storage policies look at), and every table that has a policy for
      -- guardians or students of its own: those policies decide what a parent or student sees
      'academic_session', 'academic_term', 'annual_result', 'app_user', 'attendance_day',
      'bell_calendar_rule', 'bell_template', 'branding_asset', 'campus', 'campus_branding', 'campus_event',
      'campus_event_override', 'campus_portal_policy', 'certificate_issue', 'certificate_request',
      'certificate_request_purpose', 'challan_template', 'circular', 'circular_attachment',
      'circular_read_receipt', 'class_level', 'class_section', 'class_subject', 'consent_purpose',
      'consent_record', 'consent_text_version', 'datesheet_slot_snapshot', 'datesheet_version', 'enrolment',
      'exam_subject', 'exam_term', 'feature_flag', 'fee_challan', 'fee_challan_line', 'fee_head',
      'fee_structure', 'grading_band', 'grading_scheme', 'guardian', 'holiday_calendar', 'homework',
      'homework_attachment', 'homework_feedback_history', 'homework_submission', 'homework_submission_file',
      'homework_submission_version', 'hostel_allocation', 'hostel_gate_pass', 'hostel_mess_menu',
      'hostel_mess_off', 'hostel_security_deposit', 'house', 'house_point', 'house_setting', 'inv_sale',
      'inv_student_entitlement', 'library_copy', 'library_fine', 'library_loan', 'library_reservation',
      'library_title', 'library_write_off', 'payment_gateway_config', 'payment_intent', 'permission', 'plan',
      'plan_feature', 'ptm_booking', 'ptm_event', 'ptm_waitlist', 'question_response_mark', 'report_card',
      'report_card_batch', 'report_card_packet', 'result_position', 'result_withhold', 'room', 'stream',
      'student', 'student_guardian', 'student_house_history', 'student_leave_application',
      'student_leave_attachment', 'student_portal_account', 'student_remark', 'student_remark_version',
      'subject', 'subject_result', 'support_ticket', 'tax_slab', 'tax_slab_version', 'tenant',
      'tenant_feature_override', 'tenant_setting', 'tenant_theme', 'term_remark', 'ticket_attachment',
      'ticket_message', 'timetable_slot', 'timetable_version', 'transcript_issue', 'transport_allocation',
      'transport_boarding_event', 'transport_fare_slab', 'transport_route', 'transport_stop',
      'transport_trip_leg', 'transport_vehicle_position_latest'
  ]::text[];
$$;

create or replace function app.fn_block_portal_roles(p_table regclass)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format('drop policy if exists portal_roles_blocked on %s', p_table);
  execute format($f$
    create policy portal_roles_blocked on %s as restrictive for all to authenticated
      using ((select app.auth_role()) not in ('parent', 'student'))
      with check ((select app.auth_role()) not in ('parent', 'student'))
  $f$, p_table);
end;
$$;

create or replace function app.fn_restrict_portal_writes(p_table regclass)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format('drop policy if exists portal_roles_no_insert on %s', p_table);
  execute format('drop policy if exists portal_roles_no_update on %s', p_table);
  execute format('drop policy if exists portal_roles_no_delete on %s', p_table);
  execute format($f$
    create policy portal_roles_no_insert on %s as restrictive for insert to authenticated
      with check ((select app.auth_role()) not in ('parent', 'student'))
  $f$, p_table);
  execute format($f$
    create policy portal_roles_no_update on %s as restrictive for update to authenticated
      using ((select app.auth_role()) not in ('parent', 'student'))
      with check ((select app.auth_role()) not in ('parent', 'student'))
  $f$, p_table);
  execute format($f$
    create policy portal_roles_no_delete on %s as restrictive for delete to authenticated
      using ((select app.auth_role()) not in ('parent', 'student'))
  $f$, p_table);
end;
$$;

revoke all on function app.fn_block_portal_roles(regclass) from public, anon, authenticated;
revoke all on function app.fn_restrict_portal_writes(regclass) from public, anon, authenticated;

-- ── apply to every table that exists now ─────────────────────────────────────────────

do $$
declare
  r record;
begin
  for r in
    select c.oid::regclass as tbl, c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and c.relrowsecurity
       and not c.relispartition
     order by c.relname
  loop
    if r.relname = any (app.fn_portal_tables()) then
      perform app.fn_restrict_portal_writes(r.tbl);
    else
      perform app.fn_block_portal_roles(r.tbl);
    end if;
  end loop;
end $$;

-- ── results and the staff directory: not for the student role either ──────────────────
-- Their staff policy only said "role <> 'parent'" (parents read their own child's through a
-- separate policy), which let every student read the whole campus's report cards and results.

do $$
declare
  t text;
begin
  foreach t in array array['annual_result', 'app_user', 'report_card', 'report_card_batch', 'result_withhold'] loop
    execute format('drop policy if exists students_blocked on public.%I', t);
    execute format($f$
      create policy students_blocked on public.%I as restrictive for select to authenticated
        using ((select app.auth_role()) <> 'student')
    $f$, t);
  end loop;
end $$;

-- ── listed tables whose all-commands staff policy admitted the whole campus ──────────────
-- Rebuilt from the policy as it stands, so a later change to it is kept.

do $$
declare
  r record;
  v_expr text;
begin
  for r in
    select * from (values
      ('student_remark', 'remark_staff_all'),
      ('student_remark_version', 'remark_version_staff_read'),
      ('student_portal_account', 'student_portal_account_staff'),
      ('campus_portal_policy', 'campus_portal_policy_staff')
    ) as x(tbl, pol)
  loop
    select pg_get_expr(p.polqual, p.polrelid) into v_expr
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
     where c.relnamespace = 'public'::regnamespace and c.relname = r.tbl and p.polname = r.pol;
    if v_expr is not null and v_expr !~ '''parent''' then
      execute format(
        'alter policy %I on public.%I using ((%s) and (select app.auth_role()) not in (''parent'', ''student''))',
        r.pol, r.tbl, v_expr
      );
    end if;
  end loop;
end $$;

-- ── students read the campus portal policy (their rank policy looks at it) ──────────────
-- position_student_own asks campus_portal_policy whether ranks are shown. Students used to pass that
-- check only because the staff policy admitted anyone with the campus; they now get a policy of their own.

drop policy if exists campus_portal_policy_student on public.campus_portal_policy;
create policy campus_portal_policy_student on public.campus_portal_policy for select to authenticated
  using (exists (
    select 1
      from public.student s
     where s.campus_id = campus_portal_policy.campus_id
       and s.id = (select public.my_student_id())
  ));

-- ── the one portal function that wrote a table as the parent ─────────────────────────────
-- submit_certificate_request() ran with the caller's rights and relied on a parent insert policy. The
-- portal roles no longer write tables directly, so it runs as the owner; its own check (the child must
-- be one of the caller's) is unchanged.

create or replace function public.submit_certificate_request(p_student_id uuid, p_purpose text, p_justification text default null::text)
returns setof uuid
language plpgsql
security definer
set search_path = ''
as $function$
begin
  return query
  with ins as (
    insert into public.certificate_request (tenant_id, campus_id, student_id, requested_by_user, purpose, justification)
    select s.tenant_id, s.campus_id, s.id, (select auth.uid()), p_purpose, nullif(btrim(p_justification), '')
      from public.student s
     where s.id = p_student_id and s.id = any (app.auth_guardian_student_ids())
    returning id
  )
  select id from ins;
end;
$function$;
