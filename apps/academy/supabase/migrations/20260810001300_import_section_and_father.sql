-- The student import now takes the things a school needs on day one, so an imported student is linked
-- like an admitted one: an optional section (otherwise the least-filled section of the class, as before)
-- and the father's CNIC and phone, linked through import_guardian_contacts() so siblings share a guardian.
create or replace function public.commit_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_batch         public.import_batch%rowtype;
  v_row           record;
  v_row_no        int;
  v_sections      jsonb;
  v_section_id    uuid;
  v_prefix        text;
  v_pad_width     int;
  v_before        bigint;
  v_after         bigint;
  v_next          bigint;
  v_max_supplied  bigint;
  v_auto_count    int;
  v_gr            text;
  v_student_id    uuid;
  v_enrolment_id  uuid;
  v_committed     int := 0;
  v_report_path   text;
  v_now           timestamptz := now();
  v_failed        boolean := false;
  v_message       text;
  v_detail        text;
  v_sqlstate      text;
  v_guardians     jsonb := '{}'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- FOR UPDATE, not an advisory lock: AC2's "the same batch id submitted
  -- twice" is two transactions racing on this exact row, and the second
  -- one must see the first one's status once it lands.
  select * into v_batch from public.import_batch
   where id = p_batch_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'IMPORT_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_batch.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC2: the second call is rejected outright, before anything is written.
  if v_batch.status = 'committed' then
    raise exception 'IMPORT_BATCH_ALREADY_COMMITTED' using errcode = '55000',
      detail = format('committed_at=%s committed_rows=%s', v_batch.committed_at, v_batch.committed_rows);
  end if;
  if v_batch.status = 'undone' then
    raise exception 'IMPORT_BATCH_UNDONE' using errcode = '55000';
  end if;
  if v_batch.status <> 'validated' then
    raise exception 'IMPORT_BATCH_NOT_VALIDATED' using errcode = '55000';
  end if;
  if v_batch.ok_rows = 0 then
    raise exception 'IMPORT_BATCH_HAS_NO_IMPORTABLE_ROWS' using errcode = '55000';
  end if;

  -- A retry starts from a clean slate; a stale failure marking left next
  -- to a successful commit would be unreadable.
  update public.import_batch
     set failed_at = null, failed_row_no = null, failed_message = null
   where id = p_batch_id;

  begin
    -- Free seats per section, read once. Kept in a jsonb map rather than a
    -- temp table (no cross-call lifetime to manage inside a pooled
    -- connection) and decremented as rows are placed, so the greedy
    -- least-filled rule fn_auto_balance_sections/execute_rollover_batch
    -- already use costs one `group by` for the whole batch instead of one
    -- per student.
    select coalesce(jsonb_agg(jsonb_build_object(
             'section_id',         cs.id,
             'class_level_id',     cs.class_level_id,
             'name',               cs.name,
             'gender_restriction', cs.gender_restriction,
             'seats_free',         cs.capacity - coalesce(cnt.c, 0)
           )), '[]'::jsonb)
      into v_sections
      from public.class_section cs
      left join (
        select section_id, count(*)::int as c
          from public.enrolment
         where status = 'active' and deleted_at is null
         group by section_id
      ) cnt on cnt.section_id = cs.id
     where cs.campus_id = v_batch.campus_id
       and cs.session_id = v_batch.session_id
       and cs.is_active;

    -- ── the whole GR block, in one UPDATE ────────────────────────────────
    select prefix, pad_width, next_value
      into v_prefix, v_pad_width, v_before
      from public.gr_sequence
     where campus_id = v_batch.campus_id
     for update;
    if not found then
      raise exception 'GR_SEQUENCE_NOT_CONFIGURED' using errcode = 'P0002';
    end if;

    select count(*) filter (where nullif(r.normalised ->> 'gr_number', '') is null)::int,
           max(app.fn_gr_ordinal(v_prefix, nullif(r.normalised ->> 'gr_number', '')))
      into v_auto_count, v_max_supplied
      from public.import_row r
     where r.batch_id = p_batch_id and r.severity <> 'error';

    v_next  := greatest(v_before, coalesce(v_max_supplied + 1, 0));
    v_after := v_next + v_auto_count;

    update public.gr_sequence set next_value = v_after where campus_id = v_batch.campus_id;

    -- ── the rows ─────────────────────────────────────────────────────────
    for v_row in
      select r.id, r.row_no, r.normalised
        from public.import_row r
       where r.batch_id = p_batch_id and r.severity <> 'error'
       order by r.row_no
    loop
      v_row_no := v_row.row_no;

      v_gr := nullif(v_row.normalised ->> 'gr_number', '');
      if v_gr is null then
        v_gr  := v_prefix || '-' || lpad(v_next::text, v_pad_width, '0');
        v_next := v_next + 1;
      end if;

      -- Same guard create_student() applies (FR-A15's GR_NUMBER_IN_USE):
      -- the register can gain a student between validating and committing.
      if exists (select 1 from public.student where tenant_id = v_tenant_id and gr_number = v_gr) then
        raise exception 'GR_NUMBER_IN_USE' using errcode = '23505', detail = format('gr_number=%s', v_gr);
      end if;

      insert into public.student (
        tenant_id, campus_id, gr_number, name_en, name_ur, father_name_en, father_name_ur,
        dob, gender, religion, nationality, b_form_no, blood_group
      ) values (
        v_tenant_id, v_batch.campus_id, v_gr,
        v_row.normalised ->> 'name_en',
        nullif(v_row.normalised ->> 'name_ur', ''),
        nullif(v_row.normalised ->> 'father_name_en', ''),
        nullif(v_row.normalised ->> 'father_name_ur', ''),
        (v_row.normalised ->> 'dob')::date,
        (v_row.normalised ->> 'gender')::public.gender,
        nullif(v_row.normalised ->> 'religion', ''),
        coalesce(nullif(v_row.normalised ->> 'nationality', ''), 'PK'),
        nullif(v_row.normalised ->> 'b_form_no', ''),
        nullif(v_row.normalised ->> 'blood_group', '')
      )
      returning id into v_student_id;

      -- AC3: a school-supplied historical number lands in the permanent
      -- register exactly like an allocated one.
      insert into public.gr_ledger (campus_id, gr_number, student_id, allocated_by)
      values (v_batch.campus_id, v_gr, v_student_id, auth.uid());

      v_section_id := nullif(v_row.normalised ->> 'section_id', '')::uuid;
      if v_section_id is not null and not exists (
           select 1 from jsonb_array_elements(v_sections) as e
            where (e.value ->> 'section_id')::uuid = v_section_id
              and e.value ->> 'class_level_id' = v_row.normalised ->> 'class_level_id') then
        raise exception 'SECTION_NOT_IN_CLASS' using errcode = '23514', detail = format('section_id=%s', v_section_id);
      end if;
      if v_section_id is null then
      select (e.value ->> 'section_id')::uuid
        into v_section_id
        from jsonb_array_elements(v_sections) as e
       where e.value ->> 'class_level_id' = v_row.normalised ->> 'class_level_id'
         and (e.value ->> 'seats_free')::int > 0
         and (e.value ->> 'gender_restriction' is null
              or e.value ->> 'gender_restriction' = v_row.normalised ->> 'gender')
       order by (e.value ->> 'seats_free')::int desc, e.value ->> 'name'
       limit 1;

      if v_section_id is null then
        raise exception 'NO_SECTION_SEAT_FOR_CLASS' using errcode = '23514',
          detail = format('class_level_id=%s', v_row.normalised ->> 'class_level_id');
      end if;
      end if;

      select jsonb_agg(
               case when (e.value ->> 'section_id')::uuid = v_section_id
                 then jsonb_set(e.value, '{seats_free}', to_jsonb((e.value ->> 'seats_free')::int - 1))
                 else e.value
               end)
        into v_sections
        from jsonb_array_elements(v_sections) as e;

      insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
      values (
        v_tenant_id, v_batch.campus_id, v_batch.session_id, v_student_id,
        (v_row.normalised ->> 'class_level_id')::uuid, v_section_id
      )
      returning id into v_enrolment_id;

      insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
      values (v_enrolment_id, v_section_id, current_date, auth.uid(), 'bulk import');

      update public.import_row
         set student_id = v_student_id, enrolment_id = v_enrolment_id
       where id = v_row.id;

      v_committed := v_committed + 1;
    end loop;

    -- Fathers given in the file are linked the same way the guardian import links them, so siblings
    -- with one father's CNIC share one guardian from day one.
    select public.import_guardian_contacts(coalesce(jsonb_agg(jsonb_build_object(
             'row', r.row_no, 'gr_number', s.gr_number,
             'father_cnic', r.normalised ->> 'father_cnic', 'father_phone', r.normalised ->> 'father_phone')
             order by r.row_no), '[]'::jsonb))
      into v_guardians
      from public.import_row r
      join public.student s on s.id = r.student_id
     where r.batch_id = p_batch_id
       and coalesce(r.normalised ->> 'father_cnic', r.normalised ->> 'father_phone') is not null;

    if v_batch.error_rows > 0 then
      v_report_path := v_tenant_id::text || '/' || p_batch_id::text || '/failures_' || p_batch_id::text || '.csv';
    end if;

    update public.import_batch
       set status               = 'committed',
           dry_run              = false,
           committed_at         = v_now,
           committed_by         = auth.uid(),
           committed_rows       = v_committed,
           undo_deadline        = v_now + interval '24 hours',
           gr_next_value_before = v_before,
           gr_next_value_after  = v_after,
           error_report_path    = v_report_path
     where id = p_batch_id;

  exception
    -- AC4. Reaching here has already rolled the block above back to its
    -- implicit savepoint: no student, no enrolment, no gr_ledger row, and
    -- gr_sequence.next_value is back where it started.
    when others then
      get stacked diagnostics
        v_message  = message_text,
        v_detail   = pg_exception_detail,
        v_sqlstate = returned_sqlstate;
      v_failed := true;
  end;

  if v_failed then
    -- Outside the rolled-back block, in the still-live outer transaction:
    -- this is the write that has to survive, so the function returns
    -- instead of re-raising.
    update public.import_batch
       set failed_at      = clock_timestamp(),
           failed_row_no  = v_row_no,
           failed_message = left(
             v_message || case when coalesce(v_detail, '') = '' then '' else ' (' || v_detail || ')' end,
             500)
     where id = p_batch_id;

    return jsonb_build_object(
      'ok', false,
      'batch_id', p_batch_id,
      'committed_rows', 0,
      'failed_row_no', v_row_no,
      'sqlstate', v_sqlstate,
      'message', v_message
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'batch_id', p_batch_id,
    'status', 'committed',
    'committed_rows', v_committed,
    'blocked_rows', v_batch.error_rows,
    'committed_at', v_now,
    'undo_deadline', v_now + interval '24 hours',
    'error_report_path', v_report_path,
    'gr_next_value', v_after,
    'guardians_linked', coalesce((v_guardians ->> 'linked')::int, 0)
  );
end;
$$;

revoke execute on function public.commit_import_batch(uuid) from public, anon;
grant execute on function public.commit_import_batch(uuid) to authenticated;
