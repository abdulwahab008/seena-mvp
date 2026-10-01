-- FR-I15: head of department moderation.
--
-- A bad paper should not punish a section, but moderation is also the loophole
-- that destroys a result audit trail ("every school asks for it after locking").
-- So it is bounded on every side:
--
--   * PRE-APPROVAL ONLY. Once any of the section's marks is approved/locked (or a
--     mark_lock exists, or the term is frozen) it is refused with MARKS_APPROVED;
--     after that the only path is FR-I17's break-glass unlock.
--   * BOUNDED. |delta| may not exceed exam_settings.max_moderation_delta (marks,
--     default 5), nor max_moderation_pct of the component maximum when that is
--     set. The refusal names the cap.
--   * REASONED. A reason of at least 20 characters, stored with the actor.
--   * ONCE. The partial unique index uq_moderation_open makes a second moderation
--     of the same section and subject impossible while the first stands; it must
--     be explicitly reversed first.
--   * REVERSIBLE and TRACEABLE. The pre-moderation value of every mark is kept in
--     mark_moderation_entry, so a reversal restores exactly what was there and the
--     audit trail never loses the original.
--
-- It applies to the PRESENT candidates of the section who have a mark for the
-- component (absent, exempt and debarred candidates have no mark to move). Each
-- mark is moved by delta, never above the component maximum nor below zero; the
-- candidates who hit a bound are returned so the controller can see who capped.
-- Moved marks become status 'moderated'.

create table public.mark_moderation (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  exam_subject_id  uuid not null references public.exam_subject(id) on delete cascade,
  section_id       uuid not null references public.class_section(id),
  component_code   public.mark_component_code not null default 'theory',
  delta            numeric(6,2) not null check (delta <> 0),
  reason           text not null constraint chk_moderation_reason check (char_length(reason) >= 20),
  section_mean_pct numeric(5,2),
  class_mean_pct   numeric(5,2),
  affected_count   int not null default 0,
  capped_count     int not null default 0,
  applied_by       uuid not null references auth.users(id),
  applied_at       timestamptz not null default now(),
  reversed_at      timestamptz,
  reversed_by      uuid references auth.users(id),
  reverse_reason   text,
  constraint chk_moderation_reversal check ((reversed_at is null) = (reversed_by is null))
);
-- Double application is structurally impossible: one open moderation per section and subject.
create unique index uq_moderation_open on public.mark_moderation (exam_subject_id, section_id) where reversed_at is null;
create index idx_mark_moderation_scope on public.mark_moderation (tenant_id, campus_id);
create index idx_mark_moderation_section on public.mark_moderation (section_id);
create index idx_mark_moderation_applied_by on public.mark_moderation (applied_by);

create table public.mark_moderation_entry (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  moderation_id    uuid not null references public.mark_moderation(id) on delete cascade,
  -- Deliberately no foreign key: mark_entry is guarded by a BEFORE TRUNCATE statement trigger,
  -- and a table referencing it would make Postgres refuse a truncate before that trigger names the table.
  mark_entry_id    uuid not null,
  enrolment_id     uuid not null references public.enrolment(id),
  before_marks     numeric(6,2) not null,
  after_marks      numeric(6,2) not null,
  before_status    public.mark_status not null,
  capped           boolean not null default false,
  restored         boolean not null default false,
  constraint uq_moderation_entry unique (moderation_id, mark_entry_id)
);
create index idx_moderation_entry_tenant on public.mark_moderation_entry (tenant_id);
create index idx_moderation_entry_mark on public.mark_moderation_entry (mark_entry_id);
create index idx_moderation_entry_enrolment on public.mark_moderation_entry (enrolment_id);

create trigger mark_moderation_audit after insert or update or delete on public.mark_moderation
  for each row execute function app.tg_audit_row();

alter table public.mark_moderation enable row level security;
alter table public.mark_moderation_entry enable row level security;
create policy moderation_controller_only on public.mark_moderation for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy moderation_entry_controller_only on public.mark_moderation_entry for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.mark_moderation m where m.id = moderation_id));

-- The moderation of a section is immutable except to record its reversal.
create or replace function app.tg_mark_moderation_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then
      return old;
    end if;
    raise exception 'a moderation record cannot be deleted' using errcode = '42501';
  end if;
  -- The counts are filled in once, by the function that applied the moderation, after its entries exist.
  if (new.id, new.tenant_id, new.campus_id, new.exam_subject_id, new.section_id, new.component_code, new.delta, new.reason, new.applied_by, new.applied_at)
     is distinct from
     (old.id, old.tenant_id, old.campus_id, old.exam_subject_id, old.section_id, old.component_code, old.delta, old.reason, old.applied_by, old.applied_at)
     or (old.affected_count <> 0 and (new.affected_count, new.capped_count) is distinct from (old.affected_count, old.capped_count))
     or (old.reversed_at is not null and (new.reversed_at is distinct from old.reversed_at)) then
    raise exception 'a moderation record is immutable once applied' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger trg_mark_moderation_guard before update or delete on public.mark_moderation
  for each row execute function app.tg_mark_moderation_guard();

-- ═══════════════════════════════════════════════════════════════════════
-- Context: what the controller needs to see before moderating
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_moderation_scope(p_exam_subject_id uuid, p_section_id uuid)
returns table (tenant_id uuid, campus_id uuid, term_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
    select es.tenant_id, es.campus_id, es.exam_term_id
      from public.exam_subject es
      join public.class_subject cs on cs.id = es.class_subject_id
      join public.class_section sec on sec.id = p_section_id and sec.class_level_id = cs.class_level_id and sec.session_id = cs.session_id and sec.campus_id = es.campus_id
     where es.id = p_exam_subject_id and es.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_SUBJECT_MISMATCH' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function app.fn_moderation_scope(uuid, uuid) from public, anon, authenticated;

create or replace function public.fn_moderation_context(p_exam_subject_id uuid, p_section_id uuid, p_component public.mark_component_code default 'theory')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_scope   record;
  v_max     int;
  v_sec     numeric;
  v_cls     numeric;
  v_n       int;
  v_cap     numeric;
  v_pct     numeric;
  v_open    uuid;
  v_locked  boolean;
begin
  select * into v_scope from app.fn_moderation_scope(p_exam_subject_id, p_section_id);
  perform app.fn_exam_office(v_scope.campus_id);
  select max_marks into v_max from public.exam_subject_component where exam_subject_id = p_exam_subject_id and component = p_component;
  if v_max is null then
    raise exception 'COMPONENT_NOT_CONFIGURED' using errcode = 'P0002';
  end if;
  select count(*)::int, round(avg(m.marks_obtained) * 100 / v_max, 2) into v_n, v_sec
    from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id
   where m.exam_subject_id = p_exam_subject_id and m.component_code = p_component and e.section_id = p_section_id and e.deleted_at is null
     and not exists (select 1 from public.exam_attendance a where a.exam_subject_id = m.exam_subject_id and a.enrolment_id = m.enrolment_id and a.status <> 'present');
  select round(avg(m.marks_obtained) * 100 / v_max, 2) into v_cls
    from public.mark_entry m
   where m.exam_subject_id = p_exam_subject_id and m.component_code = p_component
     and not exists (select 1 from public.exam_attendance a where a.exam_subject_id = m.exam_subject_id and a.enrolment_id = m.enrolment_id and a.status <> 'present');
  select x.max_moderation_delta, x.max_moderation_pct into v_cap, v_pct from public.exam_settings x where x.campus_id = v_scope.campus_id;
  select id into v_open from public.mark_moderation where exam_subject_id = p_exam_subject_id and section_id = p_section_id and reversed_at is null;
  v_locked := exists (select 1 from public.mark_lock l where l.exam_subject_id = p_exam_subject_id and l.section_id = p_section_id)
              or exists (select 1 from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id
                          where m.exam_subject_id = p_exam_subject_id and e.section_id = p_section_id and m.status in ('approved', 'locked'))
              or app.fn_exam_term_weight_frozen(v_scope.term_id);
  return jsonb_build_object('component', p_component, 'max_marks', v_max, 'present_with_marks', v_n, 'section_mean_pct', v_sec, 'class_mean_pct', v_cls,
                            'cap_delta', coalesce(v_cap, 5), 'cap_pct', v_pct, 'open_moderation_id', v_open, 'approved', v_locked);
end;
$$;
revoke execute on function public.fn_moderation_context(uuid, uuid, public.mark_component_code) from public, anon;
grant execute on function public.fn_moderation_context(uuid, uuid, public.mark_component_code) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Apply
-- ═══════════════════════════════════════════════════════════════════════

-- Returns {"moderation_id", "affected", "capped_count", "capped": [{enrolment_id, gr_number, name, before, after}]}.
create or replace function public.fn_apply_moderation(
  p_exam_subject_id uuid, p_section_id uuid, p_delta numeric, p_reason text, p_component public.mark_component_code default 'theory'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_scope     record;
  v_max       int;
  v_cap       numeric;
  v_pct       numeric;
  v_precision smallint;
  v_reason    text := btrim(coalesce(p_reason, ''));
  v_ctx       jsonb;
  v_id        uuid;
  v_affected  int := 0;
  v_capped    jsonb := '[]'::jsonb;
  v_ncapped   int := 0;
  r           record;
  v_new       numeric;
begin
  select * into v_scope from app.fn_moderation_scope(p_exam_subject_id, p_section_id);
  perform app.fn_exam_office(v_scope.campus_id);
  select max_marks into v_max from public.exam_subject_component where exam_subject_id = p_exam_subject_id and component = p_component;
  if v_max is null then
    raise exception 'COMPONENT_NOT_CONFIGURED' using errcode = 'P0002';
  end if;
  if p_delta is null or p_delta = 0 then
    raise exception 'DELTA_REQUIRED' using errcode = '22023';
  end if;
  if char_length(v_reason) < 20 then
    raise exception 'REASON_TOO_SHORT' using errcode = '23514', detail = 'Record why the paper was unfair: at least 20 characters.';
  end if;
  select x.max_moderation_delta, x.max_moderation_pct into v_cap, v_pct from public.exam_settings x where x.campus_id = v_scope.campus_id;
  v_cap := coalesce(v_cap, 5);
  if abs(p_delta) > v_cap then
    raise exception 'MODERATION_CAP_EXCEEDED: %', trim_scale(v_cap) using errcode = '22023', detail = format('The maximum moderation is %s marks.', trim_scale(v_cap));
  end if;
  if v_pct is not null and abs(p_delta) * 100 > v_pct * v_max then
    raise exception '%', format('MODERATION_CAP_EXCEEDED: %s%%', trim_scale(v_pct)) using errcode = '22023', detail = format('The maximum moderation is %s%% of the component maximum (%s marks).', trim_scale(v_pct), v_max);
  end if;
  v_precision := app.fn_mark_precision(v_scope.campus_id);
  if p_delta <> round(p_delta, v_precision) then
    raise exception 'MODERATION_PRECISION' using errcode = '22023', detail = format('This campus records marks to %s decimal place(s).', v_precision);
  end if;

  -- Only before approval; afterwards the path is break-glass.
  v_ctx := public.fn_moderation_context(p_exam_subject_id, p_section_id, p_component);
  if (v_ctx ->> 'approved')::boolean then
    raise exception 'MARKS_APPROVED' using errcode = '42501', detail = 'These marks are approved. Moderation after approval needs a break-glass unlock.';
  end if;
  if v_ctx ->> 'open_moderation_id' is not null then
    raise exception 'MODERATION_EXISTS' using errcode = '23505', detail = 'This section and subject were already moderated. Reverse that moderation first.';
  end if;

  begin
    insert into public.mark_moderation (tenant_id, campus_id, exam_subject_id, section_id, component_code, delta, reason, section_mean_pct, class_mean_pct, applied_by)
    values (v_scope.tenant_id, v_scope.campus_id, p_exam_subject_id, p_section_id, p_component, p_delta, v_reason,
            (v_ctx ->> 'section_mean_pct')::numeric, (v_ctx ->> 'class_mean_pct')::numeric, (select auth.uid()))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'MODERATION_EXISTS' using errcode = '23505';
  end;

  for r in
    select m.id as mark_id, m.enrolment_id, m.marks_obtained, m.status, st.gr_number, st.name_en
      from public.mark_entry m
      join public.enrolment e on e.id = m.enrolment_id
      join public.student st on st.id = e.student_id
     where m.exam_subject_id = p_exam_subject_id and m.component_code = p_component and e.section_id = p_section_id and e.deleted_at is null
       and not exists (select 1 from public.exam_attendance a where a.exam_subject_id = m.exam_subject_id and a.enrolment_id = m.enrolment_id and a.status <> 'present')
     order by st.gr_number
  loop
    v_new := least(v_max, greatest(0, r.marks_obtained + p_delta));
    insert into public.mark_moderation_entry (tenant_id, moderation_id, mark_entry_id, enrolment_id, before_marks, after_marks, before_status, capped)
    values (v_scope.tenant_id, v_id, r.mark_id, r.enrolment_id, r.marks_obtained, v_new, r.status, v_new <> r.marks_obtained + p_delta);
    update public.mark_entry set marks_obtained = v_new, status = 'moderated' where id = r.mark_id;
    v_affected := v_affected + 1;
    if v_new <> r.marks_obtained + p_delta then
      v_ncapped := v_ncapped + 1;
      v_capped := v_capped || jsonb_build_array(jsonb_build_object('enrolment_id', r.enrolment_id, 'gr_number', r.gr_number, 'name', r.name_en, 'before', r.marks_obtained, 'after', v_new));
    end if;
  end loop;
  if v_affected = 0 then
    raise exception 'NO_MARKS_TO_MODERATE' using errcode = '22023', detail = 'No present candidate of this section has a mark for the component yet.';
  end if;
  update public.mark_moderation set affected_count = v_affected, capped_count = v_ncapped where id = v_id;
  return jsonb_build_object('moderation_id', v_id, 'affected', v_affected, 'capped_count', v_ncapped, 'capped', v_capped);
end;
$$;
revoke execute on function public.fn_apply_moderation(uuid, uuid, numeric, text, public.mark_component_code) from public, anon;
grant execute on function public.fn_apply_moderation(uuid, uuid, numeric, text, public.mark_component_code) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Reverse
-- ═══════════════════════════════════════════════════════════════════════

-- Puts back the pre-moderation value of every mark the moderation moved, unless
-- the mark has been edited since (it is then left as the teacher set it and
-- counted as skipped). Allowed only while the marks are still unapproved.
create or replace function public.fn_reverse_moderation(p_moderation_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m          public.mark_moderation%rowtype;
  v_ctx      jsonb;
  v_restored int := 0;
  v_skipped  int := 0;
  e          record;
begin
  select * into m from public.mark_moderation where id = p_moderation_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'MODERATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(m.campus_id);
  if m.reversed_at is not null then
    raise exception 'MODERATION_ALREADY_REVERSED' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'REASON_TOO_SHORT' using errcode = '23514', detail = 'Record why the moderation is being reversed: at least 10 characters.';
  end if;
  v_ctx := public.fn_moderation_context(m.exam_subject_id, m.section_id, m.component_code);
  if (v_ctx ->> 'approved')::boolean then
    raise exception 'MARKS_APPROVED' using errcode = '42501', detail = 'These marks are approved. Reversing after approval needs a break-glass unlock.';
  end if;
  for e in select * from public.mark_moderation_entry where moderation_id = p_moderation_id loop
    if exists (select 1 from public.mark_entry x where x.id = e.mark_entry_id and x.marks_obtained = e.after_marks and x.status = 'moderated') then
      update public.mark_entry set marks_obtained = e.before_marks, status = e.before_status where id = e.mark_entry_id;
      update public.mark_moderation_entry set restored = true where id = e.id;
      v_restored := v_restored + 1;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;
  update public.mark_moderation set reversed_at = now(), reversed_by = (select auth.uid()), reverse_reason = btrim(p_reason) where id = p_moderation_id;
  return jsonb_build_object('restored', v_restored, 'skipped', v_skipped);
end;
$$;
revoke execute on function public.fn_reverse_moderation(uuid, text) from public, anon;
grant execute on function public.fn_reverse_moderation(uuid, text) to authenticated;
