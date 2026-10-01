-- FR-J10: class teacher remarks capture.
--
-- A class teacher writes one short remark per student per exam term, in
-- English or Urdu, picking from a saved library where one fits. It is the
-- text that prints in the "Class teacher's remark" box of the report card.
--
-- Naming: the spec calls the table student_remark. That name already belongs
-- to FR-N08 (the moderated, versioned remark a teacher posts to a parent at
-- any time of year, with its own approval flow). This is a different thing --
-- the single end-of-term line on the report card -- so it is term_remark, keyed
-- (enrolment, exam term) exactly as the spec's uq_remark.
--
-- Rules:
--   * 250 characters, enforced by chk_remark_len on the table (the screen
--     stops input at 250 with a live counter; the database refuses beyond it);
--   * one remark per (enrolment, term): saving again replaces it;
--   * only the section's class teacher (on the day) -- or school leadership --
--     can write; the class teacher reads only their own section;
--   * a parent reads their child's remark only once a report card for that
--     term has been issued, so a half-written remark is never visible;
--   * the saved library is per campus (category, English, Urdu);
--   * remarks_required (a campus_setting, like FR-J05's rank_policy) makes
--     bulk report-card generation REFUSE a batch while any student in scope has
--     no remark, naming their GR numbers. It is enforced by a trigger on the
--     batch row, so FR-J12's start_report_card_batch() is not touched, and the
--     saved remarks flow into the batch items automatically.
--
-- How the remark prints (Nastaliq, right-to-left, mixed English and digits) is
-- the report-card renderer's job: lib/report-cards/html.ts remarkMarkup().

create type public.remark_lang as enum ('en', 'ur');

create table public.remark_library (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  category   text not null check (category in ('praise', 'improvement', 'behaviour', 'attendance', 'general')),
  text_en    text not null check (char_length(btrim(text_en)) between 1 and 250),
  text_ur    text check (text_ur is null or char_length(btrim(text_ur)) between 1 and 250),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint uq_remark_library unique (campus_id, category, text_en)
);
create index idx_remark_library_campus on public.remark_library (campus_id, category);
create index idx_remark_library_tenant on public.remark_library (tenant_id);

create table public.term_remark (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  enrolment_id uuid not null references public.enrolment(id) on delete cascade,
  exam_term_id uuid not null references public.exam_term(id) on delete cascade,
  remark_text  text not null,
  remark_lang  public.remark_lang not null default 'en',
  library_id   uuid references public.remark_library(id) on delete set null,
  author_id    uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint chk_remark_len check (char_length(remark_text) <= 250 and char_length(btrim(remark_text)) > 0),
  constraint uq_remark unique (enrolment_id, exam_term_id)
);
create index idx_term_remark_term on public.term_remark (exam_term_id);
create index idx_term_remark_tenant on public.term_remark (tenant_id, campus_id);
create index idx_term_remark_library on public.term_remark (library_id);

create trigger term_remark_audit after insert or update or delete on public.term_remark
  for each row execute function app.tg_audit_row();

alter table public.remark_library enable row level security;
alter table public.term_remark enable row level security;

create policy remark_library_read on public.remark_library for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none', 'accountant')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- Is this enrolment's section taught (as class teacher) by the caller today?
create or replace function app.fn_is_class_teacher_of(p_enrolment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.enrolment e
      join public.section_class_teacher ct on ct.section_id = e.section_id
     where e.id = p_enrolment_id and ct.staff_id = (select auth.uid()) and ct.validity @> app.fn_karachi_today());
$$;
revoke execute on function app.fn_is_class_teacher_of(uuid) from public, anon, authenticated;
grant execute on function app.fn_is_class_teacher_of(uuid) to authenticated;

create or replace function app.fn_remark_published(p_enrolment_id uuid, p_exam_term_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.report_card rc
                  where rc.enrolment_id = p_enrolment_id and rc.exam_term_id = p_exam_term_id and rc.status in ('issued', 'superseded'));
$$;
revoke execute on function app.fn_remark_published(uuid, uuid) from public, anon, authenticated;
grant execute on function app.fn_remark_published(uuid, uuid) to authenticated;

create policy remark_class_teacher_own_section on public.term_remark for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_is_class_teacher_of(enrolment_id));
create policy remark_staff_read on public.term_remark for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy remark_parent_read on public.term_remark for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and exists (select 1 from public.enrolment e where e.id = enrolment_id and e.student_id = any (app.auth_guardian_student_ids()))
         and app.fn_remark_published(enrolment_id, exam_term_id));

-- ── the setting ──────────────────────────────────────────────────────────
create or replace function app.fn_remarks_required(p_campus_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select (s.value #>> '{}')::boolean from public.campus_setting s where s.campus_id = p_campus_id and s.key = 'remarks_required'), false);
$$;
revoke execute on function app.fn_remarks_required(uuid) from public, anon, authenticated;
grant execute on function app.fn_remarks_required(uuid) to authenticated;

create or replace function public.set_remarks_required(p_campus_id uuid, p_required boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
     or (app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.campus_setting (campus_id, key, value) values (p_campus_id, 'remarks_required', to_jsonb(p_required))
  on conflict (campus_id, key) do update set value = excluded.value;
end;
$$;
revoke execute on function public.set_remarks_required(uuid, boolean) from public, anon;
grant execute on function public.set_remarks_required(uuid, boolean) to authenticated;

-- ── writing remarks ──────────────────────────────────────────────────────
create or replace function app.fn_remark_guard(p_enrolment_id uuid, p_exam_term_id uuid)
returns public.enrolment
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_e public.enrolment%rowtype;
begin
  select * into v_e from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.exam_term t where t.id = p_exam_term_id and t.tenant_id = v_e.tenant_id and t.campus_id = v_e.campus_id and t.session_id = v_e.session_id) then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('owner', 'super_admin') then
    return v_e;
  end if;
  if app.auth_role() in ('principal', 'vice_principal') and v_e.campus_id = any (app.auth_campus_ids()) then
    return v_e;
  end if;
  if app.fn_is_class_teacher_of(p_enrolment_id) then
    return v_e;
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501';
end;
$$;
revoke execute on function app.fn_remark_guard(uuid, uuid) from public, anon, authenticated;

create or replace function app.fn_remark_lang(p_text text, p_lang public.remark_lang)
returns public.remark_lang
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_lang, case when p_text ~ '[؀-ۿݐ-ݿ]' then 'ur'::public.remark_lang else 'en'::public.remark_lang end);
$$;

create or replace function app.fn_save_remark(p_e public.enrolment, p_exam_term_id uuid, p_text text, p_lang public.remark_lang, p_library_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_text text := btrim(coalesce(p_text, ''));
  v_id   uuid;
begin
  if v_text = '' then
    raise exception 'REMARK_EMPTY' using errcode = '22023';
  end if;
  if char_length(v_text) > 250 then
    raise exception 'REMARK_TOO_LONG' using errcode = '23514', detail = format('length=%s max=250', char_length(v_text));
  end if;
  if p_library_id is not null and not exists (select 1 from public.remark_library where id = p_library_id and campus_id = p_e.campus_id) then
    raise exception 'LIBRARY_ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.term_remark (tenant_id, campus_id, enrolment_id, exam_term_id, remark_text, remark_lang, library_id, author_id)
  values (p_e.tenant_id, p_e.campus_id, p_e.id, p_exam_term_id, v_text, app.fn_remark_lang(v_text, p_lang), p_library_id, (select auth.uid()))
  on conflict (enrolment_id, exam_term_id) do update
     set remark_text = excluded.remark_text, remark_lang = excluded.remark_lang, library_id = excluded.library_id, author_id = excluded.author_id, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function app.fn_save_remark(public.enrolment, uuid, text, public.remark_lang, uuid) from public, anon, authenticated;

create or replace function public.save_term_remark(p_enrolment_id uuid, p_exam_term_id uuid, p_text text, p_lang public.remark_lang default null, p_library_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e public.enrolment%rowtype;
begin
  v_e := app.fn_remark_guard(p_enrolment_id, p_exam_term_id);
  return app.fn_save_remark(v_e, p_exam_term_id, p_text, p_lang, p_library_id);
end;
$$;
revoke execute on function public.save_term_remark(uuid, uuid, text, public.remark_lang, uuid) from public, anon;
grant execute on function public.save_term_remark(uuid, uuid, text, public.remark_lang, uuid) to authenticated;

-- "Apply to selected": the same remark for many students at once.
create or replace function public.apply_term_remark(p_exam_term_id uuid, p_enrolment_ids uuid[], p_text text, p_lang public.remark_lang default null, p_library_id uuid default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_e  public.enrolment%rowtype;
  v_n  int := 0;
begin
  if p_enrolment_ids is null or cardinality(p_enrolment_ids) = 0 or cardinality(p_enrolment_ids) > 300 then
    raise exception 'SELECTION_MUST_BE_1_TO_300' using errcode = '22023';
  end if;
  for v_id in select distinct x from unnest(p_enrolment_ids) x loop
    v_e := app.fn_remark_guard(v_id, p_exam_term_id);
    perform app.fn_save_remark(v_e, p_exam_term_id, p_text, p_lang, p_library_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.apply_term_remark(uuid, uuid[], text, public.remark_lang, uuid) from public, anon;
grant execute on function public.apply_term_remark(uuid, uuid[], text, public.remark_lang, uuid) to authenticated;

create or replace function public.clear_term_remark(p_enrolment_id uuid, p_exam_term_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e public.enrolment%rowtype;
begin
  v_e := app.fn_remark_guard(p_enrolment_id, p_exam_term_id);
  delete from public.term_remark where enrolment_id = p_enrolment_id and exam_term_id = p_exam_term_id;
end;
$$;
revoke execute on function public.clear_term_remark(uuid, uuid) from public, anon;
grant execute on function public.clear_term_remark(uuid, uuid) to authenticated;

-- The sheet a class teacher works from: every active student of the section, remark or not.
create or replace function public.section_remark_sheet(p_section_id uuid, p_exam_term_id uuid)
returns table (enrolment_id uuid, student_id uuid, gr_number text, name_en text, name_ur text, roll_no int, remark_text text, remark_lang public.remark_lang, library_id uuid, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sec public.class_section%rowtype;
begin
  select * into v_sec from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (app.auth_role() in ('owner', 'super_admin')
          or (app.auth_role() in ('principal', 'vice_principal', 'exam_controller') and v_sec.campus_id = any (app.auth_campus_ids()))
          or exists (select 1 from public.section_class_teacher ct where ct.section_id = p_section_id and ct.staff_id = (select auth.uid()) and ct.validity @> app.fn_karachi_today())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
  select e.id, st.id, st.gr_number, st.name_en, st.name_ur, e.roll_no, r.remark_text, r.remark_lang, r.library_id, r.updated_at
    from public.enrolment e
    join public.student st on st.id = e.student_id
    left join public.term_remark r on r.enrolment_id = e.id and r.exam_term_id = p_exam_term_id
   where e.section_id = p_section_id and e.status = 'active' and e.deleted_at is null and st.deleted_at is null
   order by e.roll_no nulls last, st.name_en;
end;
$$;
revoke execute on function public.section_remark_sheet(uuid, uuid) from public, anon;
grant execute on function public.section_remark_sheet(uuid, uuid) to authenticated;

-- ── the library ──────────────────────────────────────────────────────────
create or replace function app.fn_library_guard(p_campus_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id();
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'class_teacher')
     or (app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_tenant;
end;
$$;
revoke execute on function app.fn_library_guard(uuid) from public, anon, authenticated;

create or replace function public.add_remark_library_entry(p_campus_id uuid, p_category text, p_text_en text, p_text_ur text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_library_guard(p_campus_id);
  v_id     uuid;
begin
  insert into public.remark_library (tenant_id, campus_id, category, text_en, text_ur, created_by)
  values (v_tenant, p_campus_id, p_category, btrim(p_text_en), nullif(btrim(p_text_ur), ''), (select auth.uid()))
  on conflict (campus_id, category, text_en) do update set text_ur = coalesce(excluded.text_ur, public.remark_library.text_ur)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_remark_library_entry(uuid, text, text, text) from public, anon;
grant execute on function public.add_remark_library_entry(uuid, text, text, text) to authenticated;

create or replace function public.delete_remark_library_entry(p_entry_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l public.remark_library%rowtype;
begin
  select * into v_l from public.remark_library where id = p_entry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LIBRARY_ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_library_guard(v_l.campus_id);
  if app.auth_role() = 'class_teacher' and v_l.created_by is distinct from (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  delete from public.remark_library where id = p_entry_id;
end;
$$;
revoke execute on function public.delete_remark_library_entry(uuid) from public, anon;
grant execute on function public.delete_remark_library_entry(uuid) to authenticated;

-- A starter set so a new campus is not staring at an empty dropdown.
create or replace function public.seed_default_remark_library(p_campus_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_library_guard(p_campus_id);
  v_n      int;
begin
  insert into public.remark_library (tenant_id, campus_id, category, text_en, text_ur, created_by)
  select v_tenant, p_campus_id, d.category, d.en, d.ur, (select auth.uid())
    from (values
      ('praise', 'Excellent performance this term. Keep it up!', 'اس ٹرم میں شاندار کارکردگی۔ اسی طرح محنت جاری رکھیں!'),
      ('praise', 'A hardworking and well-behaved student.', 'محنتی اور باادب طالب علم۔'),
      ('praise', 'Shows great improvement and enthusiasm.', 'نمایاں بہتری اور شوق کا مظاہرہ کیا۔'),
      ('improvement', 'Needs to work harder to reach his or her potential.', 'اپنی صلاحیت کے مطابق نتیجہ حاصل کرنے کے لیے مزید محنت درکار ہے۔'),
      ('improvement', 'Should practise regularly at home, especially Mathematics.', 'گھر پر باقاعدگی سے مشق کریں، خاص طور پر ریاضی۔'),
      ('behaviour', 'Should pay more attention in class.', 'کلاس میں مزید توجہ دینے کی ضرورت ہے۔'),
      ('attendance', 'Attendance must improve. Please ensure regular attendance.', 'حاضری بہتر بنانے کی ضرورت ہے۔ براہ کرم باقاعدہ حاضری یقینی بنائیں۔'),
      ('general', 'A satisfactory term. Keep working steadily.', 'اطمینان بخش ٹرم۔ مسلسل محنت جاری رکھیں۔')
    ) as d(category, en, ur)
  on conflict (campus_id, category, text_en) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.seed_default_remark_library(uuid) from public, anon;
grant execute on function public.seed_default_remark_library(uuid) to authenticated;

-- ── bulk report-card generation (FR-J12) ─────────────────────────────────
-- With remarks_required on, a batch whose scope holds students without a
-- remark is refused up front and names their GR numbers, rather than printing
-- empty remark boxes or skipping them one by one.
create or replace function app.tg_batch_remarks_required()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_term    public.exam_term%rowtype;
  v_missing text[];
begin
  if not app.fn_remarks_required(new.campus_id) then
    return new;
  end if;
  select * into v_term from public.exam_term where id = new.exam_term_id;
  select array_agg(st.gr_number order by st.gr_number) into v_missing
    from public.enrolment e
    join public.student st on st.id = e.student_id
    join public.class_section cs on cs.id = e.section_id
   where e.session_id = v_term.session_id and e.campus_id = v_term.campus_id and e.status = 'active' and e.deleted_at is null and st.deleted_at is null
     and cs.campus_id = v_term.campus_id
     and ((new.scope = 'section' and e.section_id = new.target_id) or (new.scope = 'class' and e.class_level_id = new.target_id) or (new.scope = 'campus'))
     and not exists (select 1 from public.term_remark r where r.enrolment_id = e.id and r.exam_term_id = new.exam_term_id);
  if v_missing is not null then
    raise exception 'REMARKS_MISSING' using errcode = '23514', detail = 'gr_numbers=' || array_to_string(v_missing, ',');
  end if;
  return new;
end;
$$;
create trigger trg_batch_remarks_required before insert on public.report_card_batch
  for each row execute function app.tg_batch_remarks_required();

-- The remark the class teacher saved is the one the card prints, unless the
-- screen supplied its own.
create or replace function app.tg_batch_item_term_remark()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.remark is null then
    select r.remark_text into new.remark
      from public.report_card_batch b
      join public.term_remark r on r.exam_term_id = b.exam_term_id and r.enrolment_id = new.enrolment_id
     where b.id = new.batch_id;
  end if;
  return new;
end;
$$;
create trigger trg_batch_item_term_remark before insert on public.report_card_batch_item
  for each row execute function app.tg_batch_item_term_remark();
