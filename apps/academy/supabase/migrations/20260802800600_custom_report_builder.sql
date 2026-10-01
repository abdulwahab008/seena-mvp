-- FR-S07: custom report builder.
--
-- A user composes a report (columns, filters, grouping) from a PUBLISHED dataset and
-- saves it. The dangerous shortcut is to accept a SQL string from the client; this
-- builder never does. A saved definition is JSON, and the SQL is assembled here from
-- the dataset's server-side column whitelist: identifiers come only from that
-- whitelist (quoted with %I), operators from a fixed map, and every filter VALUE
-- travels as a bind parameter ($1 -> n) cast to the column's declared type.
--
-- The runner is SECURITY INVOKER over security_invoker base views, so the caller's
-- own RLS (tenant, campus) bounds every row: a report shared with a Principal of
-- another campus returns that Principal's campus, with the saved definition untouched.
-- A SECURITY DEFINER runner would bypass every policy in the product and turn one saved
-- report into a cross-tenant leak. The single place that has to run as definer is the
-- asynchronous export worker (it has no user session); there the same planner is used
-- with the requester's claims AND explicit tenant/campus predicates, mirroring the other
-- export readers (FR-S08).
--
-- Column access is per role (allowed_columns_json[].roles): the picker only offers what
-- the caller may see, and a definition that names anything else — hand-edited, or
-- saved by a more privileged colleague and shared — is refused with column_not_permitted
-- at save time AND at run time.

alter table public.report_dataset
  add column if not exists base_view text,
  add column if not exists allowed_columns_json jsonb,
  add column if not exists default_filters_json jsonb not null default '[]'::jsonb,
  add column if not exists max_preview_rows int not null default 1000 check (max_preview_rows between 1 and 10000),
  add column if not exists async_threshold_rows int not null default 50000 check (async_threshold_rows >= 1);

-- ── published datasets and their base views ───────────────────────────────

create view public.v_ds_student_enrolment with (security_invoker = true) as
select e.tenant_id, e.campus_id,
       st.gr_number, st.name_en as student_name, st.name_ur as student_name_ur, st.father_name_en as father_name, st.gender::text as gender, st.dob,
       st.religion, st.nationality, st.blood_group, st.b_form_no, st.status::text as student_status,
       cl.code as class_code, cl.name_en as class_name, sm.code as group_code, sm.name_en as group_name, sec.name as section_name, e.roll_no,
       e.status::text as enrolment_status, e.joined_on, e.left_on, se.name as session_name, ca.name as campus_name,
       g.name_en as guardian_name, g.relationship::text as guardian_relationship, g.cnic as guardian_cnic, g.phone_e164 as guardian_phone, g.email as guardian_email,
       sec.medium::text as section_medium
  from public.enrolment e
  join public.student st on st.id = e.student_id
  join public.class_level cl on cl.id = e.class_level_id
  join public.class_section sec on sec.id = e.section_id
  left join public.stream sm on sm.id = sec.stream_id
  join public.academic_session se on se.id = e.session_id
  join public.campus ca on ca.id = e.campus_id
  left join lateral (
    select gg.name_en, sg.relationship, gg.cnic, gg.phone_e164, gg.email
      from public.student_guardian sg join public.guardian gg on gg.id = sg.guardian_id
     where sg.student_id = st.id and sg.to_date is null order by sg.is_primary desc, sg.priority asc limit 1
  ) g on true
 where e.deleted_at is null;

create view public.v_ds_fee_ledger with (security_invoker = true) as
select l.tenant_id, l.campus_id,
       l.value_date, l.entry_type::text as entry_type, l.direction::text as direction, l.amount_paisa, l.posted_at,
       st.gr_number, st.name_en as student_name, cl.name_en as class_name, sec.name as section_name, ca.name as campus_name,
       ch.challan_no, fh.code as fee_head_code, fh.name_en as fee_head_name, l.reason
  from public.fee_ledger l
  join public.enrolment e on e.id = l.enrolment_id
  join public.student st on st.id = e.student_id
  join public.class_level cl on cl.id = e.class_level_id
  join public.class_section sec on sec.id = e.section_id
  join public.campus ca on ca.id = l.campus_id
  left join public.fee_challan ch on ch.id = l.challan_id
  left join public.fee_head fh on fh.id = l.fee_head_id;

create view public.v_ds_exam_result with (security_invoker = true) as
select sr.tenant_id, sr.campus_id,
       st.gr_number, st.name_en as student_name, cl.name_en as class_name, sec.name as section_name, ca.name as campus_name,
       t.code as term_code, t.name as term_name, sub.name_en as subject_name, sr.obtained, sr.max_marks, sr.pct, sr.grade_label, sr.is_pass, sr.report_symbol
  from public.subject_result sr
  join public.enrolment e on e.id = sr.enrolment_id
  join public.student st on st.id = e.student_id
  join public.class_level cl on cl.id = e.class_level_id
  join public.class_section sec on sec.id = sr.section_id
  join public.campus ca on ca.id = sr.campus_id
  join public.exam_term t on t.id = sr.exam_term_id
  join public.subject sub on sub.id = sr.subject_id;

grant select on public.v_ds_student_enrolment, public.v_ds_fee_ledger, public.v_ds_exam_result to authenticated;

insert into public.report_dataset (dataset_key, display_name, base_view, allowed_roles, columns, allowed_columns_json) values
  ('ds_student_enrolment', 'Student Enrolment', 'v_ds_student_enrolment',
   array['owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer', 'accountant', 'exam_controller'], '[]'::jsonb,
   '[{"key":"gr_number","label":"GR number","type":"text"},{"key":"student_name","label":"Student name","type":"text"},{"key":"student_name_ur","label":"Student name (Urdu)","type":"text"},
     {"key":"father_name","label":"Father name","type":"text"},{"key":"gender","label":"Gender","type":"text"},{"key":"dob","label":"Date of birth","type":"date"},
     {"key":"religion","label":"Religion","type":"text"},{"key":"nationality","label":"Nationality","type":"text"},{"key":"blood_group","label":"Blood group","type":"text"},
     {"key":"b_form_no","label":"B-Form no","type":"text","roles":["owner","super_admin","principal","admissions_officer"]},
     {"key":"student_status","label":"Student status","type":"text"},{"key":"class_code","label":"Class code","type":"text"},{"key":"class_name","label":"Class","type":"text"},
     {"key":"group_code","label":"Group code","type":"text"},{"key":"group_name","label":"Group","type":"text"},{"key":"section_name","label":"Section","type":"text"},
     {"key":"roll_no","label":"Roll no","type":"int"},{"key":"enrolment_status","label":"Enrolment status","type":"text"},{"key":"joined_on","label":"Joined on","type":"date"},
     {"key":"left_on","label":"Left on","type":"date"},{"key":"session_name","label":"Session","type":"text"},{"key":"campus_name","label":"Campus","type":"text"},
     {"key":"guardian_name","label":"Guardian","type":"text"},{"key":"guardian_relationship","label":"Guardian relationship","type":"text"},
     {"key":"guardian_cnic","label":"Guardian CNIC","type":"text","roles":["owner","super_admin","principal"]},
     {"key":"guardian_phone","label":"Guardian phone","type":"text","roles":["owner","super_admin","principal","admissions_officer"]},
     {"key":"guardian_email","label":"Guardian email","type":"text","roles":["owner","super_admin","principal","admissions_officer"]},
     {"key":"section_medium","label":"Medium","type":"text"}]'::jsonb),
  ('ds_fee_ledger', 'Fee Ledger', 'v_ds_fee_ledger', array['owner', 'super_admin', 'principal', 'accountant'], '[]'::jsonb,
   '[{"key":"value_date","label":"Value date","type":"date"},{"key":"posted_at","label":"Posted at","type":"timestamptz"},{"key":"entry_type","label":"Entry type","type":"text"},
     {"key":"direction","label":"Direction","type":"text"},{"key":"amount_paisa","label":"Amount (PKR)","type":"money"},{"key":"gr_number","label":"GR number","type":"text"},
     {"key":"student_name","label":"Student name","type":"text"},{"key":"class_name","label":"Class","type":"text"},{"key":"section_name","label":"Section","type":"text"},
     {"key":"campus_name","label":"Campus","type":"text"},{"key":"challan_no","label":"Challan no","type":"text"},{"key":"fee_head_code","label":"Fee head code","type":"text"},
     {"key":"fee_head_name","label":"Fee head","type":"text"},{"key":"reason","label":"Reason","type":"text"}]'::jsonb),
  ('ds_exam_result', 'Exam Results', 'v_ds_exam_result', array['owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller'], '[]'::jsonb,
   '[{"key":"gr_number","label":"GR number","type":"text"},{"key":"student_name","label":"Student name","type":"text"},{"key":"class_name","label":"Class","type":"text"},
     {"key":"section_name","label":"Section","type":"text"},{"key":"campus_name","label":"Campus","type":"text"},{"key":"term_code","label":"Term code","type":"text"},
     {"key":"term_name","label":"Term","type":"text"},{"key":"subject_name","label":"Subject","type":"text"},{"key":"obtained","label":"Marks obtained","type":"numeric"},
     {"key":"max_marks","label":"Maximum marks","type":"int"},{"key":"pct","label":"Percentage","type":"numeric"},{"key":"grade_label","label":"Grade","type":"text"},
     {"key":"is_pass","label":"Passed","type":"bool"},{"key":"report_symbol","label":"Report symbol","type":"text"}]'::jsonb)
on conflict (dataset_key) do nothing;
-- the dataset's `columns` (what exports and the PII audit see) is the whole whitelist
update public.report_dataset set columns = allowed_columns_json where base_view is not null and columns = '[]'::jsonb;

-- ── saved reports ─────────────────────────────────────────────────────────

create table public.saved_report (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  owner_user_id   uuid not null references auth.users(id) on delete cascade,
  name            text not null check (char_length(btrim(name)) between 1 and 120),
  dataset_key     text not null references public.report_dataset(dataset_key),
  definition_json jsonb not null check (jsonb_typeof(definition_json) = 'object'),
  is_shared       boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_saved_report_tenant on public.saved_report (tenant_id, is_shared);
create index idx_saved_report_owner on public.saved_report (owner_user_id);
create trigger saved_report_audit after insert or update or delete on public.saved_report
  for each row execute function app.tg_audit_row();
alter table public.saved_report enable row level security;
-- saved_report_owner_or_shared
create policy saved_report_owner_or_shared on public.saved_report for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (owner_user_id = (select auth.uid()) or is_shared));

-- ── the planner: the only place SQL is assembled ──────────────────────────

create or replace function app.fn_report_type_sql(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type when 'text' then 'text' when 'int' then 'int' when 'numeric' then 'numeric' when 'date' then 'date'
                     when 'bool' then 'boolean' when 'timestamptz' then 'timestamptz' when 'money' then 'bigint' end;
$$;

-- Columns the CURRENT role may use in this dataset (the picker, and the run-time check).
create or replace function app.fn_report_permitted_columns(p_dataset_key text)
returns table (key text, label text, type text)
language sql
stable
set search_path = ''
as $$
  select c ->> 'key', c ->> 'label', c ->> 'type'
    from public.report_dataset d, jsonb_array_elements(d.allowed_columns_json) with ordinality as t(c, ord)
   where d.dataset_key = p_dataset_key and d.base_view is not null and app.auth_role() = any (d.allowed_roles)
     and (c -> 'roles' is null or app.auth_role() = any (array(select jsonb_array_elements_text(c -> 'roles'))))
   order by ord;
$$;

create or replace function public.fn_report_columns(p_dataset_key text)
returns table (key text, label text, type text)
language sql
stable
set search_path = ''
as $$
  select * from app.fn_report_permitted_columns(p_dataset_key);
$$;
revoke execute on function public.fn_report_columns(text) from public, anon;
grant execute on function public.fn_report_columns(text) to authenticated;

create or replace function public.fn_report_datasets()
returns table (dataset_key text, display_name text, column_count int)
language sql
stable
set search_path = ''
as $$
  select d.dataset_key, d.display_name, (select count(*)::int from app.fn_report_permitted_columns(d.dataset_key))
    from public.report_dataset d where d.base_view is not null and app.auth_role() = any (d.allowed_roles) order by d.display_name;
$$;
revoke execute on function public.fn_report_datasets() from public, anon;
grant execute on function public.fn_report_datasets() to authenticated;

-- Validates a definition against the caller's permitted columns and returns the plan:
-- { select_sql, from_view, where_sql, group_sql, order_sql, params (jsonb array), out_columns }.
-- Nothing in the plan comes from the client except whitelisted identifiers and bind values.
create or replace function app.fn_report_plan(p_dataset_key text, p_definition jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_ds        public.report_dataset%rowtype;
  v_perm      jsonb;
  v_cols      jsonb;
  v_group     jsonb := coalesce(p_definition -> 'group_by', '[]'::jsonb);
  v_measures  jsonb := coalesce(p_definition -> 'measures', '[]'::jsonb);
  v_filters   jsonb := coalesce(p_definition -> 'filters', '[]'::jsonb);
  v_order     jsonb := coalesce(p_definition -> 'order_by', '[]'::jsonb);
  v_select    text[] := '{}';
  v_out       jsonb := '[]'::jsonb;
  v_where     text[] := '{}';
  v_groupby   text[] := '{}';
  v_orderby   text[] := '{}';
  v_params    jsonb := '[]'::jsonb;
  v_key       text;
  v_type      text;
  v_label     text;
  v_f         jsonb;
  v_m         jsonb;
  v_i         int := 0;
  v_op        text;
  v_sqltype   text;
  v_alias     text;
  v_fn        text;
begin
  select * into v_ds from public.report_dataset where dataset_key = p_dataset_key and base_view is not null;
  if not found or not (app.auth_role() = any (v_ds.allowed_roles)) then
    raise exception 'DATASET_NOT_AVAILABLE' using errcode = '42501';
  end if;
  if jsonb_typeof(p_definition) <> 'object' or jsonb_typeof(v_group) <> 'array' or jsonb_typeof(v_measures) <> 'array' or jsonb_typeof(v_filters) <> 'array' or jsonb_typeof(v_order) <> 'array'
     or jsonb_typeof(coalesce(p_definition -> 'columns', '[]'::jsonb)) <> 'array' then
    raise exception 'DEFINITION_INVALID' using errcode = '22023';
  end if;
  select coalesce(jsonb_object_agg(k, jsonb_build_object('label', l, 'type', t)), '{}'::jsonb) into v_perm from app.fn_report_permitted_columns(p_dataset_key) as p(k, l, t);

  -- every column named anywhere must be one this role may use
  for v_key in
    select jsonb_array_elements_text(coalesce(p_definition -> 'columns', '[]'::jsonb))
    union all select jsonb_array_elements_text(v_group)
    union all select x ->> 'column' from jsonb_array_elements(v_measures) x
    union all select x ->> 'column' from jsonb_array_elements(v_filters) x
    union all select x ->> 'column' from jsonb_array_elements(v_order) x
  loop
    if v_key is null or not (v_perm ? v_key) then
      raise exception 'column_not_permitted' using errcode = '42501', detail = coalesce(v_key, '(missing column)');
    end if;
  end loop;

  if jsonb_array_length(v_group) > 0 then
    -- grouped: the group columns, then a row count, then any measures
    for v_key in select jsonb_array_elements_text(v_group) loop
      v_select := v_select || format('%I', v_key);
      v_groupby := v_groupby || format('%I', v_key);
      v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'label', v_perm -> v_key ->> 'label', 'type', v_perm -> v_key ->> 'type'));
    end loop;
    v_select := v_select || 'count(*)::bigint as row_count'::text;
    v_out := v_out || jsonb_build_array(jsonb_build_object('key', 'row_count', 'label', 'Rows', 'type', 'int'));
    for v_m in select * from jsonb_array_elements(v_measures) loop
      v_fn := v_m ->> 'fn';
      v_key := v_m ->> 'column';
      v_type := v_perm -> v_key ->> 'type';
      if v_fn not in ('count', 'sum', 'avg', 'min', 'max') or (v_fn in ('sum', 'avg') and v_type not in ('int', 'numeric', 'money')) then
        raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'measure ' || coalesce(v_fn, '?') || ' on ' || v_key;
      end if;
      v_alias := v_fn || '_' || v_key;
      v_select := v_select || format('%s(%I) as %I', v_fn, v_key, v_alias);
      v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_alias, 'label', initcap(v_fn) || ' of ' || (v_perm -> v_key ->> 'label'),
                 'type', case when v_fn = 'count' then 'int' when v_fn = 'avg' then 'numeric' else v_type end));
    end loop;
  else
    if jsonb_array_length(coalesce(p_definition -> 'columns', '[]'::jsonb)) = 0 then
      raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'choose at least one column';
    end if;
    for v_key in select jsonb_array_elements_text(p_definition -> 'columns') loop
      v_select := v_select || format('%I', v_key);
      v_out := v_out || jsonb_build_array(jsonb_build_object('key', v_key, 'label', v_perm -> v_key ->> 'label', 'type', v_perm -> v_key ->> 'type'));
    end loop;
  end if;

  for v_f in select * from jsonb_array_elements(v_filters) loop
    v_key := v_f ->> 'column';
    v_op := v_f ->> 'op';
    v_type := v_perm -> v_key ->> 'type';
    v_sqltype := app.fn_report_type_sql(v_type);
    if v_op in ('is_null', 'not_null') then
      v_where := v_where || format('%I is %s', v_key, case when v_op = 'is_null' then 'null' else 'not null' end);
      continue;
    end if;
    if v_f -> 'value' is null or jsonb_typeof(v_f -> 'value') = 'null' then
      raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'filter on ' || v_key || ' needs a value';
    end if;
    v_params := v_params || jsonb_build_array(v_f -> 'value');
    v_i := jsonb_array_length(v_params) - 1;
    if v_op = 'in' then
      if jsonb_typeof(v_f -> 'value') <> 'array' then
        raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'in needs a list';
      end if;
      v_where := v_where || format('%I = any (array(select jsonb_array_elements_text($1 -> %s)::%s))', v_key, v_i, v_sqltype);
    elsif v_op = 'contains' then
      if v_type <> 'text' then
        raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'contains works on text columns';
      end if;
      v_where := v_where || format($f$%I ilike '%%' || replace(replace(replace(($1 ->> %s), '\', '\\'), '%%', '\%%'), '_', '\_') || '%%'$f$, v_key, v_i);
    elsif v_op in ('eq', 'neq', 'lt', 'lte', 'gt', 'gte') then
      v_where := v_where || format('%I %s ($1 ->> %s)::%s', v_key,
        case v_op when 'eq' then '=' when 'neq' then '<>' when 'lt' then '<' when 'lte' then '<=' when 'gt' then '>' else '>=' end, v_i, v_sqltype);
    else
      raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'unknown operator ' || coalesce(v_op, '?');
    end if;
  end loop;

  for v_f in select * from jsonb_array_elements(v_order) loop
    v_key := v_f ->> 'column';
    if jsonb_array_length(v_group) > 0 and not (v_group ? v_key) then
      raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'a grouped report can only be ordered by a group column';
    end if;
    if jsonb_array_length(v_group) = 0 and not ((p_definition -> 'columns') ? v_key) then
      raise exception 'DEFINITION_INVALID' using errcode = '22023', detail = 'order by a column that is in the report';
    end if;
    v_orderby := v_orderby || format('%I %s', v_key, case when lower(coalesce(v_f ->> 'dir', 'asc')) = 'desc' then 'desc' else 'asc' end);
  end loop;
  if cardinality(v_orderby) = 0 then
    v_orderby := case when cardinality(v_groupby) > 0 then v_groupby else v_select[1:1] end;
  end if;

  return jsonb_build_object(
    'select_sql', array_to_string(v_select, ', '), 'from_view', v_ds.base_view,
    'where_sql', coalesce(nullif(array_to_string(v_where, ' and '), ''), 'true'),
    'group_sql', array_to_string(v_groupby, ', '), 'order_sql', array_to_string(v_orderby, ', '),
    'params', v_params, 'out_columns', v_out, 'max_preview_rows', v_ds.max_preview_rows, 'async_threshold_rows', v_ds.async_threshold_rows,
    'selected', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (
        select jsonb_array_elements_text(coalesce(p_definition -> 'columns', '[]'::jsonb)) x
        union all select jsonb_array_elements_text(v_group)
        union all select x ->> 'column' from jsonb_array_elements(v_measures) x) s));
end;
$$;

-- Executes a plan. p_scope (export path only) adds explicit tenant/campus predicates.
create or replace function app.fn_report_execute(p_plan jsonb, p_offset int, p_limit int, p_scope jsonb default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_where    text := p_plan ->> 'where_sql';
  v_from     text := format('public.%I', p_plan ->> 'from_view');
  v_params   jsonb := p_plan -> 'params';
  v_group    text := p_plan ->> 'group_sql';
  v_threshold int := (p_plan ->> 'async_threshold_rows')::int;
  v_cap      int := (p_plan ->> 'max_preview_rows')::int;
  v_scope_sql text := '';
  v_inner    text;
  v_count    int;
  v_capped   boolean;
  v_limit    int;
  v_rows     jsonb;
begin
  if p_scope is not null then
    v_scope_sql := ' and "tenant_id" = ' || quote_literal(p_scope ->> 'tenant_id') || '::uuid'
      || case when p_scope -> 'campus_ids' is not null and jsonb_typeof(p_scope -> 'campus_ids') = 'array'
              then ' and "campus_id" = any (array(select jsonb_array_elements_text(' || quote_literal((p_scope -> 'campus_ids')::text) || '::jsonb)::uuid))' else '' end;
  end if;
  v_inner := format('select %s from %s where %s%s%s', p_plan ->> 'select_sql', v_from, v_where, v_scope_sql,
                    case when v_group <> '' then ' group by ' || v_group else '' end);
  v_limit := least(greatest(p_limit, 1), 100000);
  if p_scope is not null then
    -- export path: page straight through, no count, no cap
    execute format('select coalesce(jsonb_agg(to_jsonb(q)), %L::jsonb) from (select * from (%s) z order by %s offset %s limit %s) q',
                   '[]', v_inner, p_plan ->> 'order_sql', greatest(p_offset, 0), v_limit) into v_rows using v_params;
    return jsonb_build_object('rows', v_rows, 'columns', p_plan -> 'out_columns');
  end if;
  -- One scan serves both the count and the page whenever the result fits under the async
  -- threshold: the rows are read once (at most threshold+1 of them), counted, sorted and paged.
  execute format('with r as materialized (%s limit %s), c as (select count(*)::int as n from r), '
                 || 'p as (select * from r order by %s offset %s limit %s) '
                 || 'select (select n from c), (select coalesce(jsonb_agg(to_jsonb(p)), %L::jsonb) from p)',
                 v_inner, v_threshold + 1, p_plan ->> 'order_sql', greatest(p_offset, 0), v_limit, '[]')
    into v_count, v_rows using v_params;
  v_capped := v_count > v_threshold;
  if v_capped then
    -- over the threshold: the screen shows only the first max_preview_rows in the report's order
    v_limit := greatest(least(v_limit, v_cap - p_offset), 0);
    if v_limit = 0 then
      v_rows := '[]'::jsonb;
    else
      execute format('select coalesce(jsonb_agg(to_jsonb(q)), %L::jsonb) from (select * from (%s) z order by %s offset %s limit %s) q',
                     '[]', v_inner, p_plan ->> 'order_sql', greatest(p_offset, 0), v_limit) into v_rows using v_params;
    end if;
  end if;
  return jsonb_build_object('rows', v_rows, 'total_rows', case when v_capped then v_cap else v_count end, 'capped', v_capped,
                            'counted_over', case when v_capped then v_threshold else v_count end, 'columns', p_plan -> 'out_columns');
end;
$$;

-- ── public API ────────────────────────────────────────────────────────────

-- Save-time validation: the same planner, so an invalid or non-permitted definition never persists.
create or replace function public.save_report(p_name text, p_dataset_key text, p_definition jsonb, p_is_shared boolean default false, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
begin
  if v_uid is null or app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  perform app.fn_report_plan(p_dataset_key, p_definition);   -- raises column_not_permitted / DEFINITION_INVALID
  if p_id is null then
    insert into public.saved_report (tenant_id, owner_user_id, name, dataset_key, definition_json, is_shared)
    values (app.auth_tenant_id(), v_uid, btrim(p_name), p_dataset_key, p_definition, coalesce(p_is_shared, false))
    returning id into v_id;
  else
    update public.saved_report set name = btrim(p_name), dataset_key = p_dataset_key, definition_json = p_definition, is_shared = coalesce(p_is_shared, false), updated_at = now()
     where id = p_id and owner_user_id = v_uid and tenant_id = app.auth_tenant_id()
     returning id into v_id;
    if v_id is null then
      raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.save_report(text, text, jsonb, boolean, uuid) from public, anon;
grant execute on function public.save_report(text, text, jsonb, boolean, uuid) to authenticated;

create or replace function public.delete_saved_report(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.saved_report where id = p_id and owner_user_id = (select auth.uid()) and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.delete_saved_report(uuid) from public, anon;
grant execute on function public.delete_saved_report(uuid) to authenticated;

-- SECURITY INVOKER, deliberately: RLS of the base views' tables is what scopes the rows.
create or replace function public.fn_run_saved_report(saved_report_id uuid, page int default 1, page_size int default 100)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_def   public.saved_report%rowtype;
  v_plan  jsonb;
  v_size  int := least(greatest(coalesce(page_size, 100), 1), 1000);
  v_page  int := greatest(coalesce(page, 1), 1);
  v_start timestamptz := clock_timestamp();
  v_res   jsonb;
begin
  select * into v_def from public.saved_report s where s.id = fn_run_saved_report.saved_report_id;
  if not found then
    raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_plan := app.fn_report_plan(v_def.dataset_key, v_def.definition_json);
  v_res := app.fn_report_execute(v_plan, (v_page - 1) * v_size, v_size);
  return v_res || jsonb_build_object('page', v_page, 'page_size', v_size, 'dataset_key', v_def.dataset_key, 'name', v_def.name,
                                    'elapsed_ms', round(extract(epoch from (clock_timestamp() - v_start)) * 1000),
                                    'notice', case when (v_res ->> 'capped')::boolean
                                              then format('This report matches more than %s rows. The preview shows the first %s; use the asynchronous export for the full result.',
                                                          v_plan ->> 'async_threshold_rows', v_plan ->> 'max_preview_rows') end);
end;
$$;
revoke execute on function public.fn_run_saved_report(uuid, int, int) from public, anon;
grant execute on function public.fn_run_saved_report(uuid, int, int) to authenticated;

-- Ad-hoc preview of an unsaved definition (the builder's live preview): same planner, same RLS.
create or replace function public.fn_preview_report(p_dataset_key text, p_definition jsonb, page int default 1, page_size int default 100)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_plan  jsonb := app.fn_report_plan(p_dataset_key, p_definition);
  v_size  int := least(greatest(coalesce(page_size, 100), 1), 1000);
  v_page  int := greatest(coalesce(page, 1), 1);
  v_start timestamptz := clock_timestamp();
  v_res   jsonb := app.fn_report_execute(v_plan, (greatest(coalesce(page, 1), 1) - 1) * v_size, v_size);
begin
  return v_res || jsonb_build_object('page', v_page, 'page_size', v_size, 'dataset_key', p_dataset_key,
                                    'elapsed_ms', round(extract(epoch from (clock_timestamp() - v_start)) * 1000),
                                    'notice', case when (v_res ->> 'capped')::boolean
                                              then format('This report matches more than %s rows. The preview shows the first %s; use the asynchronous export for the full result.',
                                                          v_plan ->> 'async_threshold_rows', v_plan ->> 'max_preview_rows') end);
end;
$$;
revoke execute on function public.fn_preview_report(text, jsonb, int, int) from public, anon;
grant execute on function public.fn_preview_report(text, jsonb, int, int) to authenticated;

-- ── asynchronous export of a saved report ─────────────────────────────────

create or replace function public.request_saved_report_export(p_saved_report_id uuid, p_format text default 'xlsx', p_reason text default null, p_ip text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_def   public.saved_report%rowtype;
  v_plan  jsonb;
  v_hash  text;
  v_exist uuid;
  v_audit uuid;
  v_job   uuid;
begin
  if v_uid is null or app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if p_format not in ('xlsx', 'pdf') then
    raise exception 'FORMAT_INVALID' using errcode = '22023';
  end if;
  select * into v_def from public.saved_report where id = p_saved_report_id and tenant_id = app.auth_tenant_id() and (owner_user_id = v_uid or is_shared);
  if not found then
    raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_plan := app.fn_report_plan(v_def.dataset_key, v_def.definition_json);   -- column permissions of the REQUESTER, now

  v_hash := encode(extensions.digest(v_def.dataset_key || '|' || p_saved_report_id::text || '|' || v_def.updated_at::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || v_hash || p_format, 0));
  select id into v_exist from public.report_export_job
   where requested_by = v_uid and params_hash = v_hash and format = p_format and created_at > now() - interval '60 seconds' order by created_at desc limit 1;
  if v_exist is not null then
    return jsonb_build_object('job_id', v_exist, 'deduplicated', true);
  end if;

  v_audit := public.record_report_run('saved_report:' || v_def.name, v_def.dataset_key, v_plan -> 'selected',
                                      jsonb_build_object('saved_report_id', p_saved_report_id, 'filters', coalesce(v_def.definition_json -> 'filters', '[]'::jsonb)),
                                      0, p_reason, p_format, p_ip);
  insert into public.report_export_job (tenant_id, requested_by, dataset_key, params, params_hash, format, claims, audit_id)
  values (app.auth_tenant_id(), v_uid, v_def.dataset_key, jsonb_build_object('saved_report_id', p_saved_report_id), v_hash, p_format,
          jsonb_build_object('sub', v_uid, 'tenant_id', app.auth_tenant_id(), 'app_role', app.auth_role(), 'campus_ids', to_jsonb(app.auth_campus_ids())), v_audit)
  returning id into v_job;
  return jsonb_build_object('job_id', v_job, 'deduplicated', false);
end;
$$;
revoke execute on function public.request_saved_report_export(uuid, text, text, text) from public, anon;
grant execute on function public.request_saved_report_export(uuid, text, text, text) to authenticated;

-- Worker side. Runs under the job's claims (set by export_job_page); explicit tenant and
-- campus predicates replace the RLS a definer function would otherwise skip.
create or replace function app.fn_export_saved_report(p_params jsonb, p_offset int, p_limit int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_def   public.saved_report%rowtype;
  v_plan  jsonb;
  v_scope jsonb;
begin
  select * into v_def from public.saved_report
   where id = (p_params ->> 'saved_report_id')::uuid and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'REPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_plan := app.fn_report_plan(v_def.dataset_key, v_def.definition_json);
  v_scope := jsonb_build_object('tenant_id', app.auth_tenant_id(),
                                'campus_ids', case when app.auth_role() in ('owner', 'super_admin') then null else to_jsonb(app.auth_campus_ids()) end);
  -- the export is not capped: the preview cap exists only for the screen
  return app.fn_report_execute(v_plan, p_offset, p_limit, v_scope) -> 'rows';
end;
$$;
revoke execute on function app.fn_export_saved_report(jsonb, int, int) from public, anon, authenticated;

create or replace function app.fn_job_columns(p_dataset_key text, p_params jsonb, p_claims jsonb, p_default jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_prev text := current_setting('request.jwt.claims', true);
  v_def  public.saved_report%rowtype;
  v_cols jsonb;
begin
  if p_params ->> 'saved_report_id' is null then
    return p_default;
  end if;
  select * into v_def from public.saved_report where id = (p_params ->> 'saved_report_id')::uuid;
  if not found then
    return p_default;
  end if;
  perform set_config('request.jwt.claims', p_claims::text, true);
  v_cols := app.fn_report_plan(v_def.dataset_key, v_def.definition_json) -> 'out_columns';
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_cols;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function app.fn_job_columns(text, jsonb, jsonb, jsonb) from public, anon, authenticated;

-- claim_export_job: the columns of a saved-report job are the report's own, in its own order.
drop function if exists public.claim_export_job();
create function public.claim_export_job()
returns table (job_id uuid, tenant_id uuid, requested_by uuid, dataset_key text, params jsonb, columns jsonb, display_name text, requester_name text, format text, campus_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select j.id into v_id from public.report_export_job j
   where (j.status = 'queued' or (j.status = 'running' and j.started_at < now() - interval '10 minutes')) and j.attempts < 3
   order by j.created_at
   for update skip locked limit 1;
  if v_id is null then
    return;
  end if;
  update public.report_export_job set status = 'running', started_at = now(), attempts = attempts + 1 where id = v_id;

  return query
  select j.id, j.tenant_id, j.requested_by, j.dataset_key, j.params,
         app.fn_job_columns(j.dataset_key, j.params, j.claims, d.columns),
         coalesce((select 'Saved report: ' || s.name from public.saved_report s where s.id = nullif(j.params ->> 'saved_report_id', '')::uuid), d.display_name),
         coalesce((select u.full_name from public.app_user u where u.user_id = j.requested_by), 'unknown'),
         j.format,
         coalesce(nullif(j.params ->> 'campus_id', '')::uuid, nullif(j.claims -> 'campus_ids' ->> 0, '')::uuid)
    from public.report_export_job j join public.report_dataset d on d.dataset_key = j.dataset_key where j.id = v_id;
end;
$$;
revoke execute on function public.claim_export_job() from public, anon, authenticated;
grant execute on function public.claim_export_job() to service_role;

-- export_job_page learns the saved-report dataset family
create or replace function public.export_job_page(p_job_id uuid, p_offset int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
  v_prev text := current_setting('request.jwt.claims', true);
  v_rows jsonb;
begin
  select * into v_job from public.report_export_job where id = p_job_id and status = 'running';
  if not found then
    raise exception 'JOB_NOT_RUNNING' using errcode = '55000';
  end if;
  perform set_config('request.jwt.claims', v_job.claims::text, true);
  v_rows := case
    when v_job.params ? 'saved_report_id' then app.fn_export_saved_report(v_job.params, p_offset, p_limit)
    when v_job.dataset_key = 'students' then app.fn_export_students(v_job.params, p_offset, p_limit)
    when v_job.dataset_key = 'fee_collection' then app.fn_export_fee_collection(v_job.params, p_offset, p_limit)
    when v_job.dataset_key like 'drilldown\_%' then app.fn_export_drilldown(v_job.dataset_key, v_job.params, p_offset, p_limit)
    else null end;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  if v_rows is null then
    raise exception 'DATASET_NOT_IMPLEMENTED' using errcode = '0A000';
  end if;
  return v_rows;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function public.export_job_page(uuid, int, int) from public, anon, authenticated;
grant execute on function public.export_job_page(uuid, int, int) to service_role;
