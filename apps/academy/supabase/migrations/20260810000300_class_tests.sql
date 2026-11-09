-- Class tests (coursework): a quick test a teacher sets for one section in one
-- subject, marks entered per student, and the results texted to parents.
-- Separate from term exams, which carry weightage and report cards.

create table public.class_test (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  section_id   uuid not null references public.class_section(id) on delete cascade,
  subject_id   uuid references public.subject(id) on delete set null,
  title        text not null check (length(btrim(title)) between 1 and 100),
  test_date    date not null,
  total_marks  numeric(6, 2) not null check (total_marks > 0 and total_marks <= 1000),
  results_sent_at timestamptz,
  created_by   uuid default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index idx_class_test_scope on public.class_test (tenant_id, campus_id, test_date desc);
create index idx_class_test_section on public.class_test (section_id, test_date desc);
create index idx_class_test_subject on public.class_test (subject_id);

create table public.class_test_mark (
  test_id    uuid not null references public.class_test(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  marks      numeric(6, 2) check (marks is null or marks >= 0),
  absent     boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (test_id, student_id)
);
create index idx_class_test_mark_student on public.class_test_mark (student_id);
create index idx_class_test_mark_tenant on public.class_test_mark (tenant_id);

create trigger class_test_audit after insert or update or delete on public.class_test
  for each row execute function app.tg_audit_row();
create trigger class_test_mark_audit after insert or update or delete on public.class_test_mark
  for each row execute function app.tg_audit_row();

create or replace function app.fn_class_test_role()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department', 'exam_controller', 'class_teacher', 'subject_teacher');
$$;

alter table public.class_test enable row level security;
alter table public.class_test_mark enable row level security;
create policy class_test_read on public.class_test for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_class_test_role()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy class_test_mark_read on public.class_test_mark for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.class_test t where t.id = test_id));
select app.fn_block_portal_roles('public.class_test');
select app.fn_block_portal_roles('public.class_test_mark');

-- Returns the test row if the caller may work on it, else raises.
create or replace function app.fn_class_test_for_write(p_test_id uuid)
returns public.class_test
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v public.class_test;
begin
  if not app.fn_class_test_role() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v from public.class_test
   where id = p_test_id and tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()));
  if not found then
    raise exception 'TEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v;
end;
$$;
revoke execute on function app.fn_class_test_for_write(uuid) from public, anon, authenticated;

create or replace function public.create_class_test(p_section_id uuid, p_subject_id uuid, p_title text, p_test_date date, p_total_marks numeric)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section;
  v_id uuid;
begin
  if not app.fn_class_test_role() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_section from public.class_section
   where id = p_section_id and tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()));
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_subject_id is not null and not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.class_test (tenant_id, campus_id, section_id, subject_id, title, test_date, total_marks)
  values (v_section.tenant_id, v_section.campus_id, p_section_id, p_subject_id, btrim(p_title), p_test_date, p_total_marks)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_class_test(uuid, uuid, text, date, numeric) from public, anon;
grant execute on function public.create_class_test(uuid, uuid, text, date, numeric) to authenticated;

-- p_rows: [{"student_id": uuid, "marks": number|null, "absent": bool}]
create or replace function public.save_class_test_marks(p_test_id uuid, p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_test public.class_test := app.fn_class_test_for_write(p_test_id);
  v_row jsonb;
  v_student uuid;
  v_marks numeric;
  v_absent boolean;
  v_count int := 0;
begin
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_student := (v_row ->> 'student_id')::uuid;
    v_absent := coalesce((v_row ->> 'absent')::boolean, false);
    v_marks := case when v_absent then null else (v_row ->> 'marks')::numeric end;
    if v_marks is not null and (v_marks < 0 or v_marks > v_test.total_marks) then
      raise exception 'MARKS_OUT_OF_RANGE' using errcode = '22003';
    end if;
    if not exists (select 1 from public.enrolment e where e.student_id = v_student and e.section_id = v_test.section_id and e.status = 'active' and e.deleted_at is null) then
      raise exception 'STUDENT_NOT_IN_SECTION' using errcode = 'P0002';
    end if;
    insert into public.class_test_mark (test_id, student_id, tenant_id, marks, absent)
    values (p_test_id, v_student, v_test.tenant_id, v_marks, v_absent)
    on conflict (test_id, student_id) do update set marks = excluded.marks, absent = excluded.absent, updated_at = now();
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke execute on function public.save_class_test_marks(uuid, jsonb) from public, anon;
grant execute on function public.save_class_test_marks(uuid, jsonb) to authenticated;

-- Texts each parent their child's result through the outbox.
create or replace function public.send_class_test_results(p_test_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_test public.class_test := app.fn_class_test_for_write(p_test_id);
  v_school text;
  v_subject text;
  v_batch uuid;
  v_queued int := 0;
  v_skipped int := 0;
  r record;
begin
  select name into v_school from public.tenant where id = v_test.tenant_id;
  select name_en into v_subject from public.subject where id = v_test.subject_id;
  insert into public.message_batch (tenant_id, campus_id, title, channel, created_by, metadata)
  values (v_test.tenant_id, v_test.campus_id, 'Class test results', 'sms', auth.uid(), jsonb_build_object('template', 'class_test_result', 'test_id', p_test_id))
  returning id into v_batch;

  for r in
    select m.student_id, m.marks, m.absent, s.name_en,
           (select public.normalize_pk_phone(g.phone_e164) from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
             where sg.student_id = m.student_id and (sg.to_date is null or sg.to_date >= current_date) and g.phone_e164 is not null
             order by sg.is_primary desc, sg.priority limit 1) as phone
      from public.class_test_mark m
      join public.student s on s.id = m.student_id
     where m.test_id = p_test_id and (m.absent or m.marks is not null)
  loop
    if r.phone is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    insert into public.message (tenant_id, campus_id, batch_id, recipient_type, recipient_id, recipient_phone, channel, body, status, idempotency_key, metadata)
    values (v_test.tenant_id, v_test.campus_id, v_batch, 'guardian', r.student_id, r.phone, 'sms',
            left(v_school || ': ' || r.name_en || case when r.absent then ' was absent in ' else ' scored ' || (case when r.marks = trunc(r.marks) then trunc(r.marks)::bigint::text else trim(trailing '0' from r.marks::text) end) || '/' || (case when v_test.total_marks = trunc(v_test.total_marks) then trunc(v_test.total_marks)::bigint::text else trim(trailing '0' from v_test.total_marks::text) end) || ' in ' end
                 || coalesce(v_subject || ' ', '') || v_test.title || ' (' || to_char(v_test.test_date, 'DD Mon') || ').', 640),
            'queued', 'class-test:' || p_test_id || ':' || r.student_id || ':' || v_batch, jsonb_build_object('template', 'class_test_result'));
    v_queued := v_queued + 1;
  end loop;

  update public.message_batch set total_count = v_queued, queued_count = v_queued where id = v_batch;
  update public.class_test set results_sent_at = now() where id = p_test_id;
  return jsonb_build_object('queued', v_queued, 'skipped', v_skipped);
end;
$$;
revoke execute on function public.send_class_test_results(uuid) from public, anon;
grant execute on function public.send_class_test_results(uuid) to authenticated;
