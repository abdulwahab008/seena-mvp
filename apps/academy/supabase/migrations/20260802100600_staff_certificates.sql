-- FR-D18: experience and service certificate generation.
--
-- issue_staff_certificate() allocates the number, snapshots EVERYTHING the
-- certificate says (designation spans, total service, school names) into
-- payload jsonb and stores one staff_certificate row. A reprint renders from that
-- snapshot, so it reproduces exactly what was signed and stamped even if the
-- designation history or the template changes afterwards, and it consumes no new
-- number.
--
--   * Numbers come from staff_certificate_counter (tenant, type, year) with one
--     upsert that takes the row lock, so two concurrent issuances can never
--     receive the same number and a reprint never touches the counter. Format is
--     the template's number_format, default EXP-{year}-{seq4}.
--   * Designation spans need a history, which the schema did not keep:
--     staff_designation_history (filled by a trigger on staff.designation_id,
--     seeded from the current designation at the date of joining) and
--     record_designation_change() for HR to date a promotion.
--   * An experience certificate is blocked while the staff member has an OPEN
--     termination for misconduct (FR-D15: a termination row that no later row
--     supersedes). Only the Owner can override, with a written reason; the
--     override is its own audited row (staff_certificate_override -> audit_log).
--   * The PDF (Noto Nastaliq embedded for the Urdu school name) is rendered by
--     /api/staff-certificates/[id]/pdf into the private staff-certificates
--     bucket and sealed once, the same way the settlement statement is.

-- ── designation history ───────────────────────────────────────────────────

create table public.staff_designation_history (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  staff_id         uuid not null references public.staff(id) on delete cascade,
  designation_id   uuid references public.designation(id) on delete set null,
  designation_name text not null,
  from_date        date not null,
  to_date          date,
  created_at       timestamptz not null default now(),
  constraint chk_designation_span check (to_date is null or to_date >= from_date)
);
create index idx_designation_history_staff on public.staff_designation_history (staff_id, from_date);
create index idx_designation_history_tenant on public.staff_designation_history (tenant_id);
create unique index uq_designation_history_open on public.staff_designation_history (staff_id) where to_date is null;
create trigger staff_designation_history_audit after insert or update or delete on public.staff_designation_history
  for each row execute function app.tg_audit_row();
alter table public.staff_designation_history enable row level security;
create policy designation_history_read on public.staff_designation_history for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal')
              or exists (select 1 from public.staff s where s.id = staff_id and s.user_id = (select auth.uid()))));
revoke insert, update, delete on public.staff_designation_history from authenticated, anon;

create or replace function app.tg_staff_designation_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if tg_op = 'UPDATE' and new.designation_id is not distinct from old.designation_id then
    return new;
  end if;
  -- record_designation_change() writes the dated span itself and sets this flag for its own transaction
  if current_setting('app.skip_designation_history', true) = '1' then
    return new;
  end if;
  update public.staff_designation_history
     set to_date = greatest(from_date, case when tg_op = 'INSERT' then new.doj else app.fn_karachi_today() - 1 end)
   where staff_id = new.id and to_date is null;
  if new.designation_id is not null then
    select name_en into v_name from public.designation where id = new.designation_id;
    insert into public.staff_designation_history (tenant_id, staff_id, designation_id, designation_name, from_date)
    values (new.tenant_id, new.id, new.designation_id, coalesce(v_name, 'Staff Member'), case when tg_op = 'INSERT' then new.doj else app.fn_karachi_today() end);
  end if;
  return new;
end;
$$;
create trigger trg_staff_designation_history after insert or update of designation_id on public.staff
  for each row execute function app.tg_staff_designation_history();

insert into public.staff_designation_history (tenant_id, staff_id, designation_id, designation_name, from_date)
select s.tenant_id, s.id, s.designation_id, d.name_en, s.doj
  from public.staff s join public.designation d on d.id = s.designation_id
 where not exists (select 1 from public.staff_designation_history h where h.staff_id = s.id);

-- HR dates a promotion or correction: closes the open span the day before and opens the new one.
create or replace function public.record_designation_change(p_staff_id uuid, p_designation_id uuid, p_effective_from date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff public.staff%rowtype;
  v_name  text;
  v_open  public.staff_designation_history%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_staff from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  select name_en into v_name from public.designation where id = p_designation_id and tenant_id = v_staff.tenant_id;
  if v_name is null then
    raise exception 'DESIGNATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_open from public.staff_designation_history where staff_id = p_staff_id and to_date is null;
  if found and p_effective_from <= v_open.from_date then
    raise exception 'EFFECTIVE_DATE_BEFORE_CURRENT_SPAN' using errcode = '22023';
  end if;
  if found then
    update public.staff_designation_history set to_date = p_effective_from - 1 where id = v_open.id;
  end if;
  insert into public.staff_designation_history (tenant_id, staff_id, designation_id, designation_name, from_date)
  values (v_staff.tenant_id, p_staff_id, p_designation_id, v_name, p_effective_from);
  -- keep staff.designation_id in step without the trigger writing a second span
  perform set_config('app.skip_designation_history', '1', true);
  update public.staff set designation_id = p_designation_id where id = p_staff_id;
  perform set_config('app.skip_designation_history', '0', true);
end;
$$;
revoke execute on function public.record_designation_change(uuid, uuid, date) from public, anon;
grant execute on function public.record_designation_change(uuid, uuid, date) to authenticated;

-- ── templates, counter, certificates ──────────────────────────────────────

create type public.staff_certificate_type as enum ('experience', 'service', 'noc');

create table public.staff_certificate_template (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  cert_type             public.staff_certificate_type not null,
  title                 text not null,
  body_html             text not null,
  letterhead_path       text,
  number_format         text not null default 'EXP-{year}-{seq4}' check (number_format like '%{seq4}%'),
  requires_override_when jsonb not null default '{}'::jsonb,
  updated_at            timestamptz not null default now(),
  constraint uq_staff_cert_template unique (tenant_id, cert_type)
);
create trigger staff_certificate_template_audit after insert or update or delete on public.staff_certificate_template
  for each row execute function app.tg_audit_row();
alter table public.staff_certificate_template enable row level security;
create policy staff_cert_template_read on public.staff_certificate_template for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal'));

create or replace function app.tg_seed_staff_certificate_templates()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.staff_certificate_template (tenant_id, cert_type, title, body_html, number_format, requires_override_when) values
    (new.id, 'experience', 'Experience Certificate',
     '<p>This is to certify that <strong>{{staff_name}}</strong> (Employee No. {{employee_code}}) served {{school_name}} from {{service_from}} to {{service_to}}, a total service of <strong>{{total_service}}</strong>.</p><p>Positions held: {{positions}}.</p><p>During this period the conduct and performance of {{staff_name}} were found satisfactory. We wish them every success.</p><p>Certificate No. {{certificate_no}}, issued on {{issued_on}}.</p>',
     'EXP-{year}-{seq4}', '{"open_termination": true}'),
    (new.id, 'service', 'Service Certificate',
     '<p>This is to certify that <strong>{{staff_name}}</strong> (Employee No. {{employee_code}}) has been in the service of {{school_name}} since {{service_from}}, presently as {{designation_current}}, a total service of <strong>{{total_service}}</strong> up to {{service_to}}.</p><p>Certificate No. {{certificate_no}}, issued on {{issued_on}}.</p>',
     'SVC-{year}-{seq4}', '{}'),
    (new.id, 'noc', 'No Objection Certificate',
     '<p>{{school_name}} has no objection to <strong>{{staff_name}}</strong> (Employee No. {{employee_code}}), {{designation_current}}, serving since {{service_from}}, pursuing the purpose they have applied for.</p><p>Certificate No. {{certificate_no}}, issued on {{issued_on}}.</p>',
     'NOC-{year}-{seq4}', '{}')
  on conflict do nothing;
  return new;
end;
$$;
create trigger tenant_seed_staff_certificate_templates after insert on public.tenant
  for each row execute function app.tg_seed_staff_certificate_templates();

insert into public.staff_certificate_template (tenant_id, cert_type, title, body_html, number_format, requires_override_when)
select t.id, v.cert_type::public.staff_certificate_type, v.title, v.body, v.fmt, v.rule::jsonb
  from public.tenant t
 cross join (values
   ('experience', 'Experience Certificate',
    '<p>This is to certify that <strong>{{staff_name}}</strong> (Employee No. {{employee_code}}) served {{school_name}} from {{service_from}} to {{service_to}}, a total service of <strong>{{total_service}}</strong>.</p><p>Positions held: {{positions}}.</p><p>During this period the conduct and performance of {{staff_name}} were found satisfactory. We wish them every success.</p><p>Certificate No. {{certificate_no}}, issued on {{issued_on}}.</p>',
    'EXP-{year}-{seq4}', '{"open_termination": true}'),
   ('service', 'Service Certificate',
    '<p>This is to certify that <strong>{{staff_name}}</strong> (Employee No. {{employee_code}}) has been in the service of {{school_name}} since {{service_from}}, presently as {{designation_current}}, a total service of <strong>{{total_service}}</strong> up to {{service_to}}.</p><p>Certificate No. {{certificate_no}}, issued on {{issued_on}}.</p>',
    'SVC-{year}-{seq4}', '{}'),
   ('noc', 'No Objection Certificate',
    '<p>{{school_name}} has no objection to <strong>{{staff_name}}</strong> (Employee No. {{employee_code}}), {{designation_current}}, serving since {{service_from}}, pursuing the purpose they have applied for.</p><p>Certificate No. {{certificate_no}}, issued on {{issued_on}}.</p>',
    'NOC-{year}-{seq4}', '{}')
 ) as v(cert_type, title, body, fmt, rule)
on conflict do nothing;

create table public.staff_certificate_counter (
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  cert_type  public.staff_certificate_type not null,
  year       smallint not null,
  last_value integer not null default 0 check (last_value >= 0),
  primary key (tenant_id, cert_type, year)
);
alter table public.staff_certificate_counter enable row level security;

create table public.staff_certificate_override (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid references public.campus(id) on delete set null,
  staff_id      uuid not null references public.staff(id) on delete cascade,
  cert_type     public.staff_certificate_type not null,
  reason        text not null check (char_length(btrim(reason)) >= 10),
  overridden_by uuid not null references public.app_user(user_id),
  created_at    timestamptz not null default now()
);
create index idx_cert_override_tenant on public.staff_certificate_override (tenant_id);
create index idx_cert_override_staff on public.staff_certificate_override (staff_id);
create trigger staff_certificate_override_audit after insert or update or delete on public.staff_certificate_override
  for each row execute function app.tg_audit_row();
alter table public.staff_certificate_override enable row level security;
create policy cert_override_read on public.staff_certificate_override for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager'));
revoke insert, update, delete on public.staff_certificate_override from authenticated, anon;

create table public.staff_certificate (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  staff_id         uuid not null references public.staff(id),
  cert_type        public.staff_certificate_type not null,
  certificate_no   text not null,
  template_id      uuid references public.staff_certificate_template(id) on delete set null,
  payload          jsonb not null,
  override_id      uuid references public.staff_certificate_override(id),
  issued_by        uuid references public.app_user(user_id),
  issued_at        timestamptz not null default now(),
  storage_path     text,
  pdf_sha256       text check (pdf_sha256 is null or pdf_sha256 ~ '^[0-9a-f]{64}$'),
  constraint uq_staff_certificate_no unique (tenant_id, certificate_no),
  constraint chk_staff_cert_pdf_pair check ((storage_path is null) = (pdf_sha256 is null))
);
create index idx_staff_certificate_staff on public.staff_certificate (staff_id, issued_at desc);
create index idx_staff_certificate_tenant on public.staff_certificate (tenant_id, issued_at desc);
create index idx_staff_certificate_campus on public.staff_certificate (campus_id);
create trigger staff_certificate_audit after insert or update or delete on public.staff_certificate
  for each row execute function app.tg_audit_row();

-- An issued certificate is a record: nothing but the one-time PDF seal may change.
create or replace function app.tg_staff_certificate_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_strip text[] := array['storage_path', 'pdf_sha256'];
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then
      return old;
    end if;
    raise exception 'CERTIFICATE_IMMUTABLE' using errcode = '42501';
  end if;
  if (to_jsonb(new) - v_strip) is distinct from (to_jsonb(old) - v_strip) then
    raise exception 'CERTIFICATE_IMMUTABLE' using errcode = '42501';
  end if;
  if old.pdf_sha256 is not null and (new.pdf_sha256 is distinct from old.pdf_sha256 or new.storage_path is distinct from old.storage_path) then
    raise exception 'CERTIFICATE_PDF_SEALED' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger staff_certificate_immutable before update or delete on public.staff_certificate
  for each row execute function app.tg_staff_certificate_immutable();

alter table public.staff_certificate enable row level security;
create policy certificate_hr_read on public.staff_certificate for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal')
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids())));
create policy certificate_self_read on public.staff_certificate for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.staff s where s.id = staff_id and s.user_id = (select auth.uid())));
revoke insert, update, delete on public.staff_certificate from authenticated, anon;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staff-certificates', 'staff-certificates', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;

-- ── numbering ─────────────────────────────────────────────────────────────

-- One statement: the upsert takes the counter row's lock, so concurrent issuances serialise and
-- each gets its own number. Never called for a reprint.
create or replace function public.next_certificate_no(p_tenant uuid, p_cert_type text, p_year smallint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type   public.staff_certificate_type := p_cert_type::public.staff_certificate_type;
  v_format text;
  v_n      integer;
begin
  insert into public.staff_certificate_counter as c (tenant_id, cert_type, year, last_value)
  values (p_tenant, v_type, p_year, 1)
  on conflict (tenant_id, cert_type, year) do update set last_value = c.last_value + 1
  returning c.last_value into v_n;
  select number_format into v_format from public.staff_certificate_template where tenant_id = p_tenant and cert_type = v_type;
  return replace(replace(coalesce(v_format, upper(left(p_cert_type, 3)) || '-{year}-{seq4}'), '{year}', p_year::text), '{seq4}', lpad(v_n::text, 4, '0'));
end;
$$;
revoke execute on function public.next_certificate_no(uuid, text, smallint) from public, anon, authenticated;

-- ── the snapshot ──────────────────────────────────────────────────────────

create or replace function app.fn_staff_service_payload(p_staff_id uuid, p_end date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_staff  public.staff%rowtype;
  v_spans  jsonb;
  v_total  interval;
  v_years  integer;
  v_months integer;
begin
  select * into v_staff from public.staff where id = p_staff_id;
  select coalesce(jsonb_agg(jsonb_build_object(
           'designation', x.designation_name, 'from', x.f, 'to', x.t,
           'years', extract(year from age(x.t + 1, x.f))::int, 'months', extract(month from age(x.t + 1, x.f))::int) order by x.f), '[]'::jsonb)
    into v_spans
    from (
      select h.designation_name, greatest(h.from_date, v_staff.doj) as f, least(coalesce(h.to_date, p_end), p_end) as t
        from public.staff_designation_history h
       where h.staff_id = p_staff_id and h.from_date <= p_end and coalesce(h.to_date, p_end) >= v_staff.doj
    ) x
   where x.t >= x.f;
  if jsonb_array_length(v_spans) = 0 then
    v_spans := jsonb_build_array(jsonb_build_object(
      'designation', coalesce((select name_en from public.designation where id = v_staff.designation_id), 'Staff Member'),
      'from', v_staff.doj, 'to', p_end,
      'years', extract(year from age(p_end + 1, v_staff.doj))::int, 'months', extract(month from age(p_end + 1, v_staff.doj))::int));
  end if;
  v_total := age(p_end + 1, v_staff.doj);
  v_years := extract(year from v_total)::int;
  v_months := extract(month from v_total)::int;
  return jsonb_build_object(
    'spans', v_spans, 'service_from', v_staff.doj, 'service_to', p_end,
    'total_years', v_years, 'total_months', v_months,
    'total_service', format('%s year%s %s month%s', v_years, case when v_years = 1 then '' else 's' end, v_months, case when v_months = 1 then '' else 's' end));
end;
$$;
revoke execute on function app.fn_staff_service_payload(uuid, date) from public, anon, authenticated;

-- ── issuing ───────────────────────────────────────────────────────────────

create or replace function public.issue_staff_certificate(p_staff_id uuid, p_cert_type public.staff_certificate_type, p_override_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff    public.staff%rowtype;
  v_tpl      public.staff_certificate_template%rowtype;
  v_tenant   public.tenant%rowtype;
  v_end      date;
  v_payload  jsonb;
  v_year     smallint := extract(year from app.fn_karachi_today())::smallint;
  v_no       text;
  v_blocked  boolean := false;
  v_override uuid;
  v_id       uuid;
  v_spans_text text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_staff from public.staff where id = p_staff_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() = 'hr_manager' and not (v_staff.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_tpl from public.staff_certificate_template where tenant_id = v_staff.tenant_id and cert_type = p_cert_type;
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_tenant from public.tenant where id = v_staff.tenant_id;

  -- an open termination for misconduct blocks the certificate unless the Owner overrides it
  if coalesce((v_tpl.requires_override_when ->> 'open_termination')::boolean, false) then
    v_blocked := exists (
      select 1 from public.staff_disciplinary d
       where d.staff_id = p_staff_id and d.action_type = 'termination'
         and not exists (select 1 from public.staff_disciplinary succ where succ.supersedes_id = d.id));
  end if;
  if v_blocked then
    if app.auth_role() not in ('owner', 'super_admin') or char_length(btrim(coalesce(p_override_reason, ''))) < 10 then
      raise exception 'CERTIFICATE_BLOCKED_PENDING_OWNER_OVERRIDE' using errcode = '55000';
    end if;
    insert into public.staff_certificate_override (tenant_id, campus_id, staff_id, cert_type, reason, overridden_by)
    values (v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_cert_type, btrim(p_override_reason), (select auth.uid()))
    returning id into v_override;
  end if;

  select coalesce((select e.last_working_date from public.staff_exit e where e.staff_id = p_staff_id order by e.initiated_at desc limit 1), app.fn_karachi_today()) into v_end;
  v_payload := app.fn_staff_service_payload(p_staff_id, v_end);
  v_no := public.next_certificate_no(v_staff.tenant_id, p_cert_type::text, v_year);

  select string_agg(format('%s (%s to %s)', s ->> 'designation', to_char((s ->> 'from')::date, 'DD Mon YYYY'), to_char((s ->> 'to')::date, 'DD Mon YYYY')), '; ' order by s ->> 'from')
    into v_spans_text from jsonb_array_elements(v_payload -> 'spans') s;

  v_payload := v_payload || jsonb_build_object(
    'certificate_no', v_no, 'cert_type', p_cert_type, 'title', v_tpl.title, 'body_html', v_tpl.body_html,
    'staff_name', v_staff.full_name, 'employee_code', v_staff.employee_code,
    'school_name', v_tenant.name, 'school_name_ur', v_tenant.name_ur,
    'issued_on', to_char(app.fn_karachi_today(), 'DD Mon YYYY'),
    'designation_current', v_payload -> 'spans' -> (jsonb_array_length(v_payload -> 'spans') - 1) ->> 'designation',
    'positions', v_spans_text,
    'values', jsonb_build_object(
      'staff_name', v_staff.full_name, 'employee_code', v_staff.employee_code, 'school_name', v_tenant.name, 'school_name_ur', coalesce(v_tenant.name_ur, ''),
      'service_from', to_char((v_payload ->> 'service_from')::date, 'DD Mon YYYY'), 'service_to', to_char((v_payload ->> 'service_to')::date, 'DD Mon YYYY'),
      'total_service', v_payload ->> 'total_service', 'certificate_no', v_no, 'issued_on', to_char(app.fn_karachi_today(), 'DD Mon YYYY'),
      'designation_current', v_payload -> 'spans' -> (jsonb_array_length(v_payload -> 'spans') - 1) ->> 'designation', 'positions', v_spans_text));

  insert into public.staff_certificate (tenant_id, campus_id, staff_id, cert_type, certificate_no, template_id, payload, override_id, issued_by)
  values (v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_cert_type, v_no, v_tpl.id, v_payload, v_override, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.issue_staff_certificate(uuid, public.staff_certificate_type, text) from public, anon;
grant execute on function public.issue_staff_certificate(uuid, public.staff_certificate_type, text) to authenticated;

-- Whether an experience certificate for this person would be blocked (so the UI can ask the Owner for an override).
create or replace function public.staff_certificate_blocked(p_staff_id uuid, p_cert_type public.staff_certificate_type)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tpl public.staff_certificate_template%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select t.* into v_tpl from public.staff_certificate_template t join public.staff s on s.tenant_id = t.tenant_id
   where s.id = p_staff_id and s.tenant_id = app.auth_tenant_id() and t.cert_type = p_cert_type;
  if not found then
    return false;
  end if;
  return coalesce((v_tpl.requires_override_when ->> 'open_termination')::boolean, false) and exists (
    select 1 from public.staff_disciplinary d
     where d.staff_id = p_staff_id and d.action_type = 'termination'
       and not exists (select 1 from public.staff_disciplinary succ where succ.supersedes_id = d.id));
end;
$$;
revoke execute on function public.staff_certificate_blocked(uuid, public.staff_certificate_type) from public, anon;
grant execute on function public.staff_certificate_blocked(uuid, public.staff_certificate_type) to authenticated;

create or replace function public.upsert_staff_certificate_template(p_cert_type public.staff_certificate_type, p_title text, p_body_html text, p_number_format text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_number_format not like '%{seq4}%' then
    raise exception 'NUMBER_FORMAT_NEEDS_SEQ' using errcode = '22023';
  end if;
  update public.staff_certificate_template
     set title = btrim(p_title), body_html = p_body_html, number_format = p_number_format, updated_at = now()
   where tenant_id = app.auth_tenant_id() and cert_type = p_cert_type;
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.upsert_staff_certificate_template(public.staff_certificate_type, text, text, text) from public, anon;
grant execute on function public.upsert_staff_certificate_template(public.staff_certificate_type, text, text, text) to authenticated;

-- A reprint renders from the stored snapshot and allocates nothing: this returns the snapshot and writes nothing.
create or replace function public.reprint_staff_certificate(p_certificate_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_c public.staff_certificate%rowtype;
begin
  select * into v_c from public.staff_certificate where id = p_certificate_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CERTIFICATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'principal')
     and not exists (select 1 from public.staff s where s.id = v_c.staff_id and s.user_id = (select auth.uid())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return v_c.payload;
end;
$$;
revoke execute on function public.reprint_staff_certificate(uuid) from public, anon;
grant execute on function public.reprint_staff_certificate(uuid) to authenticated;

-- ── the one-time PDF seal (service role, called by the render route) ──────

create or replace function public.store_staff_certificate_pdf(p_certificate_id uuid, p_storage_path text, p_sha256 text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.staff_certificate%rowtype;
begin
  select * into v_c from public.staff_certificate where id = p_certificate_id for update;
  if not found then
    raise exception 'CERTIFICATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_c.pdf_sha256 is not null then
    raise exception 'CERTIFICATE_PDF_SEALED' using errcode = '42501';
  end if;
  update public.staff_certificate set storage_path = p_storage_path, pdf_sha256 = lower(p_sha256) where id = p_certificate_id;
end;
$$;
revoke execute on function public.store_staff_certificate_pdf(uuid, text, text) from public, anon, authenticated;
grant execute on function public.store_staff_certificate_pdf(uuid, text, text) to service_role;
