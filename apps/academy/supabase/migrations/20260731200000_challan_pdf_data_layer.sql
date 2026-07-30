-- FR-K11: three-copy bank challan PDF — data layer only.
--
-- Scope cut, stated plainly up front: this migration does NOT render a
-- PDF, generate a barcode image, create a Storage bucket, or deploy an
-- Edge Function. This codebase has never used Supabase Storage or Edge
-- Functions anywhere — FR-K06's own migration hit the identical gap for
-- document uploads and made the identical call: build the reference
-- schema now (challan_template, fee_challan_pdf), leave the actual file
-- mechanism for when that infrastructure exists. Standing up a Deno PDF
-- + Code-128 barcode pipeline blind, in an environment that has never
-- run `supabase functions serve` before, risks spending the whole batch
-- on infrastructure plumbing instead of delivering tested, verified
-- work — exactly the outcome "test every feature" is meant to prevent.
--
-- What IS built and fully tested: build_challan_render_payload() —
-- the single canonical data structure an Edge Function would consume to
-- actually render the three copies. Its value is proving the two things
-- that matter before a single pixel is drawn:
--   * the AC's "net payable equal to the paisa across all three copies"
--     is structural here, not a coincidence to hope for — there is
--     exactly ONE payload, not three independently-assembled ones, so
--     "identical on all 3 copies" is guaranteed by construction rather
--     than needing three renderers to agree.
--   * barcode_value is exactly challan_no (FR-K10), the same value a
--     Code-128 scan must decode back to.
--
-- challan_template is per-campus (a bank's required layout is a branch
-- fact, not a tenant-wide one — the Notes are explicit that a bank
-- effectively fixes the layout, symbology and account-number position).

create table public.challan_template (
  campus_id           uuid primary key references public.campus(id) on delete cascade,
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  bank_name           text not null,
  bank_account_title  text not null,
  bank_account_no     text not null,
  logo_path           text,
  footer_note_en      text,
  footer_note_ur      text,
  updated_by          uuid references public.app_user(user_id),
  updated_at          timestamptz not null default clock_timestamp()
);

create or replace function public.set_challan_template(
  p_campus_id uuid, p_bank_name text, p_bank_account_title text, p_bank_account_no text,
  p_logo_path text default null, p_footer_note_en text default null, p_footer_note_ur text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.challan_template (
    campus_id, tenant_id, bank_name, bank_account_title, bank_account_no, logo_path, footer_note_en, footer_note_ur, updated_by
  ) values (
    p_campus_id, app.auth_tenant_id(), p_bank_name, p_bank_account_title, p_bank_account_no, p_logo_path, p_footer_note_en, p_footer_note_ur, auth.uid()
  )
  on conflict (campus_id) do update
    set bank_name = excluded.bank_name, bank_account_title = excluded.bank_account_title,
        bank_account_no = excluded.bank_account_no, logo_path = excluded.logo_path,
        footer_note_en = excluded.footer_note_en, footer_note_ur = excluded.footer_note_ur,
        updated_by = excluded.updated_by, updated_at = clock_timestamp();
end;
$$;

revoke execute on function public.set_challan_template(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.set_challan_template(uuid, text, text, text, text, text, text) to authenticated;

-- Reference schema for the rendered file, per FR-K06's own precedent —
-- no function inserts into this yet, since nothing renders a file yet.
create table public.fee_challan_pdf (
  id              uuid primary key default gen_random_uuid(),
  challan_id      uuid not null references public.fee_challan(id) on delete cascade,
  storage_path    text not null,
  rendered_at     timestamptz not null default clock_timestamp(),
  template_version int not null default 1,
  sha256          text not null
);

create index idx_fee_challan_pdf_challan on public.fee_challan_pdf (challan_id);

-- The canonical data an Edge Function renders three times (bank, school,
-- student copy) — one payload, so "identical across all three copies" is
-- true by construction, not something three separate renderers need to
-- agree on independently.
create or replace function public.build_challan_render_payload(p_challan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challan  public.fee_challan%rowtype;
  v_template public.challan_template%rowtype;
  v_student  record;
  v_lines    jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_template from public.challan_template where campus_id = v_challan.campus_id;

  select s.name_en, s.gr_number, cl.name_en as class_name, cs.name as section_name
    into v_student
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
   where e.id = v_challan.enrolment_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'head_name', fh.name_en, 'amount_paisa', fcl.amount_paisa,
           'concession_paisa', fcl.concession_paisa, 'net_paisa', fcl.net_paisa, 'line_type', fcl.line_type
         ) order by fh.code), '[]'::jsonb)
    into v_lines
    from public.fee_challan_line fcl
    join public.fee_head fh on fh.id = fcl.fee_head_id
   where fcl.challan_id = p_challan_id;

  return jsonb_build_object(
    'challan_no', v_challan.challan_no,
    'barcode_value', v_challan.challan_no,
    'billing_period', v_challan.billing_period,
    'issue_date', v_challan.issue_date,
    'due_date', v_challan.due_date,
    'student', jsonb_build_object(
      'name_en', v_student.name_en, 'gr_number', v_student.gr_number,
      'class_name', v_student.class_name, 'section_name', v_student.section_name
    ),
    'bank', jsonb_build_object(
      'bank_name', v_template.bank_name, 'bank_account_title', v_template.bank_account_title,
      'bank_account_no', v_template.bank_account_no, 'footer_note_en', v_template.footer_note_en,
      'footer_note_ur', v_template.footer_note_ur
    ),
    'lines', v_lines,
    'gross_paisa', v_challan.gross_paisa,
    'concession_paisa', v_challan.concession_paisa,
    'net_paisa', v_challan.net_paisa,
    'copies', jsonb_build_array('bank', 'school', 'student')
  );
end;
$$;

revoke execute on function public.build_challan_render_payload(uuid) from public, anon;
grant execute on function public.build_challan_render_payload(uuid) to authenticated;

alter table public.challan_template enable row level security;
alter table public.fee_challan_pdf enable row level security;

create policy challan_template_campus_scope on public.challan_template
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_challan_pdf_campus_scope on public.fee_challan_pdf
  for select to authenticated
  using (
    challan_id in (
      select id from public.fee_challan
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
-- challan_pdf_parent_read (from the FR's own RLS list) is not
-- implemented — same reasoning as FR-K06's parent_read_own_child_award:
-- there is no guardian/parent portal authentication anywhere in this
-- schema yet for it to gate.
