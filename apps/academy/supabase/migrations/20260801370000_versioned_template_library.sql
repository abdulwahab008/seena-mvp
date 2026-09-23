-- Migration: 20260801370000_versioned_template_library.sql
-- Module M: Communication (FR-M03: Versioned template library, FR-M04: Urdu bodies & SMS segment costing)

-- ── 1. Enhance public.message_template ──────────────────────────────────────
-- Non-destructively alter existing message_template table to support the unified
-- communication template catalog while keeping legacy admissions reminder compatibility.

alter table public.message_template
  alter column code drop not null,
  alter column channel drop not null,
  alter column locale drop not null,
  alter column template_id drop not null;

alter table public.message_template
  add column if not exists name text not null default '',
  add column if not exists audience_entity public.comm_recipient_type not null default 'student',
  add column if not exists category text not null default 'general',
  add column if not exists description text,
  add column if not exists is_active boolean not null default true,
  add column if not exists created_at timestamptz not null default clock_timestamp(),
  add column if not exists updated_at timestamptz not null default clock_timestamp();

create index if not exists idx_message_template_tenant_audience
  on public.message_template (tenant_id, audience_entity, is_active);

-- ── 2. Create public.message_template_version ───────────────────────────────
create table if not exists public.message_template_version (
  id              uuid primary key default gen_random_uuid(),
  template_id     uuid not null references public.message_template(id) on delete cascade,
  version_no      integer not null check (version_no >= 1),
  message_class   text not null default 'transactional' check (message_class in ('transactional', 'promotional', 'emergency', 'reminder')),
  body_en         text not null,
  body_ur         text,
  sms_encoding    text not null default 'auto' check (sms_encoding in ('auto', 'gsm7', 'ucs2')),
  is_published    boolean not null default false,
  published_at    timestamptz,
  published_by    uuid references auth.users(id),
  change_summary  text,
  created_at      timestamptz not null default clock_timestamp(),
  constraint uq_message_template_version unique (template_id, version_no)
);

create index if not exists idx_message_template_version_published
  on public.message_template_version (template_id, is_published, version_no desc);

-- ── 3. Create public.template_placeholder (Whitelist catalog) ───────────────
create table if not exists public.template_placeholder (
  id              uuid primary key default gen_random_uuid(),
  entity          public.comm_recipient_type not null,
  token           text not null,
  description     text not null,
  sample_value    text not null,
  is_required     boolean not null default false,
  created_at      timestamptz not null default clock_timestamp(),
  constraint uq_template_placeholder unique (entity, token)
);

create index if not exists idx_template_placeholder_entity
  on public.template_placeholder (entity, token);

-- ── 4. SMS Segment Calculation Function (FR-M04, IMMUTABLE) ─────────────────
create or replace function public.sms_segment_count(
  p_body text,
  p_encoding text default 'auto'
)
returns integer
language plpgsql
immutable
as $$
declare
  v_len integer;
  v_is_ucs2 boolean;
begin
  if p_body is null or length(p_body) = 0 then
    return 0;
  end if;

  v_len := length(p_body);

  if p_encoding = 'ucs2' then
    v_is_ucs2 := true;
  elsif p_encoding = 'gsm7' then
    v_is_ucs2 := false;
  else
    -- auto-detect: if text contains any character outside standard GSM 03.38 set
    v_is_ucs2 := (p_body ~ '[^\x20-\x7E\r\n\t£\$¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¡ÄÖÑÜ§¿äöñüà€]');
  end if;

  if v_is_ucs2 then
    if v_len <= 70 then
      return 1;
    else
      return ceil(v_len::numeric / 67.0)::integer;
    end if;
  else
    if v_len <= 160 then
      return 1;
    else
      return ceil(v_len::numeric / 153.0)::integer;
    end if;
  end if;
end;
$$;

-- Add generated segment_count and template_version_id to public.message
alter table public.message
  add column if not exists template_version_id uuid references public.message_template_version(id) on delete set null;

alter table public.message
  add column if not exists segment_count integer generated always as (public.sms_segment_count(body, 'auto')) stored;

-- ── 5. Token Validation Function (FR-M03 AC 1) ──────────────────────────────
create or replace function public.validate_template_tokens(p_version_id uuid)
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entity public.comm_recipient_type;
  v_body_en text;
  v_body_ur text;
  v_combined text;
begin
  select t.audience_entity, v.body_en, v.body_ur
  into v_entity, v_body_en, v_body_ur
  from public.message_template_version v
  join public.message_template t on t.id = v.template_id
  where v.id = p_version_id;

  if not found then
    raise exception 'Template version % not found', p_version_id using errcode = 'P0002';
  end if;

  v_combined := coalesce(v_body_en, '') || ' ' || coalesce(v_body_ur, '');

  return query
  with extracted as (
    select distinct (m)[1] as token
    from regexp_matches(v_combined, '\{\{([a-zA-Z0-9_]+)\}\}', 'g') as m
  )
  select e.token
  from extracted e
  where not exists (
    select 1
    from public.template_placeholder tp
    where tp.entity = v_entity
      and tp.token = e.token
  );
end;
$$;

-- ── 6. Publish Template Version Function (FR-M03 AC 1) ──────────────────────
create or replace function public.publish_template_version(p_version_id uuid)
returns public.message_template_version
language plpgsql
security definer
set search_path = public
as $$
declare
  v_version public.message_template_version;
  v_invalid_tokens text[];
begin
  select * into v_version from public.message_template_version where id = p_version_id;
  if not found then
    raise exception 'Template version % not found', p_version_id using errcode = 'P0002';
  end if;

  select array_agg(t) into v_invalid_tokens
  from public.validate_template_tokens(p_version_id) t;

  if v_invalid_tokens is not null and array_length(v_invalid_tokens, 1) > 0 then
    raise exception 'Cannot publish template version: unresolvable placeholder token(s): %',
      array_to_string(v_invalid_tokens, ', ')
      using errcode = '22023';
  end if;

  update public.message_template_version
  set is_published = true,
      published_at = coalesce(published_at, clock_timestamp()),
      published_by = coalesce(published_by, auth.uid())
  where id = p_version_id
  returning * into v_version;

  return v_version;
end;
$$;

-- ── 7. Immutability Trigger (FR-M03 AC 4) ───────────────────────────────────
create or replace function public.fn_enforce_template_version_immutable()
returns trigger
language plpgsql
as $$
begin
  -- If already published, prohibit altering content or version properties
  if OLD.is_published = true then
    if NEW.body_en is distinct from OLD.body_en or
       NEW.body_ur is distinct from OLD.body_ur or
       NEW.message_class is distinct from OLD.message_class or
       NEW.sms_encoding is distinct from OLD.sms_encoding or
       NEW.version_no is distinct from OLD.version_no or
       NEW.template_id is distinct from OLD.template_id then
      raise exception 'Published template versions are immutable. Create a new version instead.'
        using errcode = '23514';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_template_version_immutable on public.message_template_version;
create trigger trg_template_version_immutable
before update on public.message_template_version
for each row
execute function public.fn_enforce_template_version_immutable();

-- ── 8. Render Template Function (FR-M03 AC 3) ───────────────────────────────
create or replace function public.render_template(
  p_version_id uuid,
  p_ctx jsonb,
  p_lang text default 'en'
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text;
  v_rendered text;
  v_rec record;
  v_val text;
begin
  select 
    case 
      when p_lang = 'ur' and body_ur is not null and length(trim(body_ur)) > 0 then body_ur
      else body_en
    end
  into v_body
  from public.message_template_version
  where id = p_version_id;

  if not found then
    raise exception 'Template version % not found', p_version_id using errcode = 'P0002';
  end if;

  v_rendered := v_body;

  -- Extract all tokens and replace them
  for v_rec in 
    select distinct (m)[1] as token
    from regexp_matches(v_body, '\{\{([a-zA-Z0-9_]+)\}\}', 'g') as m
  loop
    v_val := p_ctx->>v_rec.token;
    -- AC 3: If rendering produces a null or empty value, reject to prevent sending literal {{token}}
    if v_val is null or length(trim(v_val)) = 0 then
      raise exception 'Template rendering failed: token "{{%}}" is missing or null in context', v_rec.token
        using errcode = '22004';
    end if;

    v_rendered := replace(v_rendered, '{{' || v_rec.token || '}}', v_val);
  end loop;

  return v_rendered;
end;
$$;

-- ── 9. Pick Body Function (FR-M04) ──────────────────────────────────────────
create or replace function public.pick_body(
  p_version_id uuid,
  p_lang text default 'en'
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_body text;
begin
  select 
    case 
      when p_lang = 'ur' and body_ur is not null and length(trim(body_ur)) > 0 then body_ur
      else body_en
    end
  into v_body
  from public.message_template_version
  where id = p_version_id;

  return v_body;
end;
$$;

-- ── 10. Row-Level Security ──────────────────────────────────────────────────
alter table public.message_template enable row level security;
alter table public.message_template_version enable row level security;
alter table public.template_placeholder enable row level security;

-- message_template policies
drop policy if exists message_template_tenant_read on public.message_template;
create policy message_template_tenant_read on public.message_template
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists message_template_tenant_write on public.message_template;
create policy message_template_tenant_write on public.message_template
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id() and
    app.auth_role() = any (array['super_admin', 'owner', 'principal', 'admin', 'staff'])
  );

drop policy if exists message_template_tenant_update on public.message_template;
create policy message_template_tenant_update on public.message_template
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id() and
    app.auth_role() = any (array['super_admin', 'owner', 'principal', 'admin', 'staff'])
  );

-- message_template_version policies
drop policy if exists message_template_version_read on public.message_template_version;
create policy message_template_version_read on public.message_template_version
  for select to authenticated
  using (
    template_id in (
      select mt.id from public.message_template mt where mt.tenant_id = app.auth_tenant_id()
    )
  );

drop policy if exists message_template_version_insert on public.message_template_version;
create policy message_template_version_insert on public.message_template_version
  for insert to authenticated
  with check (
    template_id in (
      select mt.id from public.message_template mt where mt.tenant_id = app.auth_tenant_id()
    ) and
    app.auth_role() = any (array['super_admin', 'owner', 'principal', 'admin', 'staff'])
  );

drop policy if exists message_template_version_update on public.message_template_version;
create policy message_template_version_update on public.message_template_version
  for update to authenticated
  using (
    template_id in (
      select mt.id from public.message_template mt where mt.tenant_id = app.auth_tenant_id()
    ) and
    app.auth_role() = any (array['super_admin', 'owner', 'principal', 'admin', 'staff'])
  );

-- template_placeholder policies (whitelist catalog readable to all staff)
drop policy if exists template_placeholder_read on public.template_placeholder;
create policy template_placeholder_read on public.template_placeholder
  for select to authenticated
  using (true);

-- ── 11. Seed Placeholder Whitelist Catalog ───────────────────────────────────
insert into public.template_placeholder (entity, token, description, sample_value, is_required)
values
  -- Student audience tokens
  ('student', 'student_name', 'Student full name', 'Muhammad Ali', true),
  ('student', 'first_name', 'Student given name', 'Ali', false),
  ('student', 'roll_no', 'Student roll number / identifier', 'SEC-042', false),
  ('student', 'grade_level', 'Current class/grade name', 'Grade 9', false),
  ('student', 'section_name', 'Current section name', 'Rose', false),
  ('student', 'campus_name', 'Campus name', 'Main Campus', true),
  ('student', 'attendance_date', 'Date of attendance event (YYYY-MM-DD)', '2026-09-23', false),
  ('student', 'term_name', 'Academic term name', 'Mid-Term 2026', false),
  ('student', 'overall_grade', 'Exam overall grade (A+, A, B...)', 'A+', false),
  ('student', 'overall_percentage', 'Exam score percentage', '91.5%', false),
  ('student', 'portal_link', 'Portal URL', 'https://portal.seenaacademy.edu.pk', false),

  -- Parent / Guardian audience tokens
  ('parent', 'guardian_name', 'Parent/Guardian full name', 'Tariq Mehmood', false),
  ('parent', 'student_name', 'Child full name', 'Muhammad Ali', true),
  ('parent', 'roll_no', 'Child roll number', 'SEC-042', false),
  ('parent', 'grade_level', 'Child class name', 'Grade 9', false),
  ('parent', 'section_name', 'Child section name', 'Rose', false),
  ('parent', 'campus_name', 'Campus name', 'Main Campus', true),
  ('parent', 'challan_no', 'Fee challan invoice number', 'CHL-2026-00421', false),
  ('parent', 'amount_due', 'Outstanding fee amount in PKR', '18,500 PKR', false),
  ('parent', 'due_date', 'Fee challan due date', '2026-10-10', false),
  ('parent', 'fee_month', 'Billing month and year', 'October 2026', false),
  ('parent', 'attendance_date', 'Date of absence/attendance event', '2026-09-23', false),
  ('parent', 'portal_link', 'Parent portal direct link', 'https://portal.seenaacademy.edu.pk', false),
  ('parent', 'school_phone', 'School administrative helpline', '+92 51 111 222 333', false),
  ('parent', 'notice_title', 'Title of circular / notice', 'School Timings Adjustment', false),
  ('parent', 'date', 'Event date', '2026-09-23', false),

  -- Guardian audience tokens (synonymous with parent)
  ('guardian', 'guardian_name', 'Guardian full name', 'Tariq Mehmood', false),
  ('guardian', 'student_name', 'Child full name', 'Muhammad Ali', true),
  ('guardian', 'roll_no', 'Child roll number', 'SEC-042', false),
  ('guardian', 'grade_level', 'Child class name', 'Grade 9', false),
  ('guardian', 'section_name', 'Child section name', 'Rose', false),
  ('guardian', 'campus_name', 'Campus name', 'Main Campus', true),
  ('guardian', 'challan_no', 'Fee challan invoice number', 'CHL-2026-00421', false),
  ('guardian', 'amount_due', 'Outstanding fee amount in PKR', '18,500 PKR', false),
  ('guardian', 'due_date', 'Fee challan due date', '2026-10-10', false),
  ('guardian', 'fee_month', 'Billing month and year', 'October 2026', false),
  ('guardian', 'attendance_date', 'Date of absence/attendance event', '2026-09-23', false),
  ('guardian', 'portal_link', 'Guardian portal direct link', 'https://portal.seenaacademy.edu.pk', false),
  ('guardian', 'school_phone', 'School administrative helpline', '+92 51 111 222 333', false),
  ('guardian', 'notice_title', 'Title of circular / notice', 'School Timings Adjustment', false),
  ('guardian', 'date', 'Event date', '2026-09-23', false),

  -- Staff audience tokens
  ('staff', 'staff_name', 'Staff member name', 'Amina Khan', true),
  ('staff', 'employee_id', 'Staff badge/identifier', 'EMP-108', false),
  ('staff', 'department', 'Staff department', 'Science', false),
  ('staff', 'campus_name', 'Campus name', 'Main Campus', true),
  ('staff', 'date', 'Effective date', '2026-09-23', false),
  ('staff', 'action_required', 'Action or instruction description', 'Submit lesson plans by Friday', false),

  -- Custom / Generic audience tokens
  ('custom', 'name', 'Recipient name', 'Recipient Name', false),
  ('custom', 'campus_name', 'Campus name', 'Main Campus', true),
  ('custom', 'notice_title', 'Announcement title', 'Notice', false),
  ('custom', 'date', 'Date', '2026-09-23', false),
  ('custom', 'contact_number', 'School contact phone', '+92 51 111 222 333', false)
on conflict (entity, token) do nothing;

-- ── 12. Seeding Helper Function for Tenant Templates ────────────────────────
create or replace function public.seed_default_versioned_templates(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tmpl_id uuid;
  v_v1_id uuid;
begin
  -- 1. Student Absence Alert
  insert into public.message_template (tenant_id, name, audience_entity, category, description, is_active)
  values (
    p_tenant_id,
    'Student Absence Alert',
    'guardian',
    'attendance',
    'Automated notification sent to parents when a student is marked absent.',
    true
  )
  returning id into v_tmpl_id;

  insert into public.message_template_version (
    template_id, version_no, message_class, body_en, body_ur, sms_encoding, is_published, published_at, change_summary
  ) values (
    v_tmpl_id,
    1,
    'transactional',
    'Dear Guardian, {{student_name}} (Roll No: {{roll_no}}) of {{grade_level}} - {{section_name}} was marked absent on {{attendance_date}}. If this was unexpected, please contact {{campus_name}}.',
    'محترم والدین، آپ کے بچے {{student_name}} (رول نمبر: {{roll_no}}) جماعت {{grade_level}} - {{section_name}} کو بتاریخ {{attendance_date}} غیر حاضر شمار کیا گیا ہے۔ معلومات کے لیے {{campus_name}} سے رابطہ فرمائیں۔',
    'auto',
    true,
    clock_timestamp(),
    'Initial published version'
  );

  -- 2. Monthly Fee Challan Due Notice
  insert into public.message_template (tenant_id, name, audience_entity, category, description, is_active)
  values (
    p_tenant_id,
    'Monthly Fee Challan Due Notice',
    'guardian',
    'fee',
    'Billing reminder containing invoice number, amount, and due date.',
    true
  )
  returning id into v_tmpl_id;

  insert into public.message_template_version (
    template_id, version_no, message_class, body_en, body_ur, sms_encoding, is_published, published_at, change_summary
  ) values (
    v_tmpl_id,
    1,
    'transactional',
    'Dear Guardian, Fee Challan {{challan_no}} for {{student_name}} amounting to {{amount_due}} for {{fee_month}} is due on {{due_date}}. Please pay before the due date to avoid late charges. Portal: {{portal_link}}',
    'محترم والدین، {{student_name}} کا فیس چالان {{challan_no}} برائے {{fee_month}} بمبلغ {{amount_due}} واجب الادا ہے۔ آخری تاریخ {{due_date}} ہے۔ برائے مہربانی بروقت ادا فرمائیں۔ رابطہ: {{portal_link}}',
    'auto',
    true,
    clock_timestamp(),
    'Initial published version'
  );

  -- 3. General Circular Notice
  insert into public.message_template (tenant_id, name, audience_entity, category, description, is_active)
  values (
    p_tenant_id,
    'Campus General Notice',
    'guardian',
    'general',
    'Standard notification for circulars, events, and school notices.',
    true
  )
  returning id into v_tmpl_id;

  insert into public.message_template_version (
    template_id, version_no, message_class, body_en, body_ur, sms_encoding, is_published, published_at, change_summary
  ) values (
    v_tmpl_id,
    1,
    'transactional',
    'Dear Guardian, important announcement from {{campus_name}} regarding {{notice_title}} on {{date}}. Please check the portal or contact {{school_phone}} for queries.',
    'محترم والدین، {{campus_name}} کی طرف سے {{notice_title}} بتاریخ {{date}} کے حوالے سے اہم اطلاع۔ مزید معلومات کے لیے {{school_phone}} پر رابطہ کریں۔',
    'auto',
    true,
    clock_timestamp(),
    'Initial published version'
  );
end;
$$;
