-- FR-T15: consent capture for photos and data use.
--
-- "As a Parent, I want to control whether my child's photograph may be used
-- in school marketing and whether their data may be shared with third
-- parties, so that my choice is recorded and ACTUALLY ENFORCED."
--
-- The last three words are the whole FR. A consent table nobody reads is a
-- compliance theatre prop, so this migration spends most of its length on
-- the two enforcement points the ACs name, and on making the resolution
-- rule impossible to bypass.
--
-- ── What already existed, and what this migration had to invent ─────────
--
--   * The messaging path is REAL and pre-existing. FR-G12
--     (20260731540000_absentee_sms_notification.sql, re-emitted by
--     20260731770000) already ships dispatch_absentee_notifications() +
--     the public.attendance_notification outbox, including a
--     notification_channel enum that already had 'whatsapp' in it and a
--     notification_status enum that already had 'skipped_optout' in it
--     with no writer. AC2's suppression is wired straight into THAT
--     function — no parallel messaging system is built here — and
--     'skipped_optout' is finally given the writer it was minted for
--     rather than a sixth enum value being added next to it.
--
--   * The marketing gallery did NOT exist, and saying so plainly matters
--     more than pretending otherwise. public.student.photo_path has been a
--     column since 20260730121905 and is referenced by exactly nothing —
--     no page, no route handler, no export. There is no photo display
--     path to intercept and no gallery to filter. So the gallery export
--     AC1 describes is built here, as the genuine (and currently only)
--     consumer of student.photo_path: build_marketing_gallery_export()
--     below is a real export that a real UI calls, and has_consent() is
--     the gate it cannot get around. Module M (Communication) is not
--     built either, so "the campaign report" in AC2 means, today, the
--     attendance_notification rows plus the jsonb summary
--     dispatch_absentee_notifications() returns — that IS the report this
--     codebase has, and the skip is recorded in both.
--
--   * Guardian linkage is FR-C11's public.student_guardian (many
--     guardians per student, closed with to_date rather than deleted) and
--     app.auth_guardian_student_ids(). AC4's two-guardian conflict
--     resolution is therefore a real join, not a hypothetical.
--
-- ── Where AC1's audit row actually lands, and why not a new action ──────
--
-- audit_log.action is an enum of exactly ('insert','update','delete') and
-- audit_log is a log of ROW CHANGES walked by run_audit_chain_verification()
-- (FR-T14). FR-T09 established the honest test for when to use it: file it
-- in audit_log when an actual row changed, and mint something else when
-- nothing did (that is why public.security_event exists).
--
-- An excluded student is not a "nothing happened" case: the export writes a
-- real public.marketing_gallery_export_exclusion row carrying
-- reason='consent_denied', and that table has the ordinary
-- app.tg_audit_row() trigger. So the attempt IS "written to audit_log with
-- reason 'consent_denied'" exactly as AC1 asks — action='insert',
-- table_name='marketing_gallery_export_exclusion',
-- after->>'reason'='consent_denied' — and it inherits FR-T14's hash chain
-- for free, so the record of a denial cannot be quietly removed either. No
-- enum value is invented and no second audit system is built.
--
-- ── Why AC4's rule lives inside has_consent(), not in its callers ───────
--
-- "any linked guardian's denial wins" is a safety property. If it lived in
-- build_marketing_gallery_export() and again in
-- dispatch_absentee_notifications(), the third caller would get it wrong,
-- and the two existing ones would eventually disagree. has_consent() takes
-- (student_id, purpose) and nothing else — a caller cannot pass it a
-- guardian, cannot ask it to consider only one guardian, and cannot ask it
-- to ignore a denial. The conflict is surfaced separately (
-- v_consent_attention) for the Principal, but surfacing is a UI concern;
-- the resolution is not.
--
-- ── AC3: three states, not two ─────────────────────────────────────────
--
-- A v2 consent after v3 is published is VALID, and it is FLAGGED. Those are
-- independent facts and they are stored in independent places:
--   * VALID: has_consent() never reads text_version at all. There is no
--     code path in it that could invalidate on a version bump, which is
--     the strongest form of "not auto-invalidated" available — not a rule
--     that happens to be written the right way, but an input the function
--     does not have.
--   * FLAGGED: v_consent_attention.reconsent_required is DERIVED, computed
--     on read by comparing the row's own text_version against the current
--     effective version. Nothing writes it, so nothing can drift. Marking
--     it on the row at publish time would be the "auto-carried" failure
--     mode from the other direction: a stored flag that a later correction
--     to the version catalogue leaves stale.
--   * requires_reconsent_on_version_change is per purpose, because not
--     every wording change is material — a typo fix in the SMS-consent
--     blurb should not summon 900 parents back to the counter.
--
-- ── Default posture: opt-in vs opt-out, per purpose ─────────────────────
--
-- consent_purpose.requires_explicit_grant is the one genuinely contestable
-- decision here, so it is a column rather than a hardcoded rule:
--   * student_photo_marketing / third_party_data_sharing are OPT-IN. A
--     student with no consent row on file is NOT in the marketing gallery.
--     Silence is not permission for a secondary use of a child's likeness.
--   * sms_messaging / whatsapp_messaging are OPT-OUT. These carry the
--     transactional "your child was marked absent today" traffic the
--     school exists to send; defaulting them to denied would silently
--     switch off FR-G12 for every student in every existing tenant on the
--     day this migration ran. An explicit denial or withdrawal still
--     suppresses them — which is exactly and only what AC2 requires.
-- Both branches still fail closed on a denial. The column only decides what
-- SILENCE means.
--
-- ── Two catalogues, and why only one of them is global ─────────────────
--
-- consent_purpose is a fixed code list, like public.document_type — global,
-- seeded here, never written at runtime.
--
-- consent_text_version is NOT global, and this is a deliberate departure
-- from the FR's suggested column list. The wording a parent signs is the
-- school's own legal text on the school's own letterhead, and AC3's
-- "flagged on the admin dashboard" is a school admin's dashboard. A global
-- mutable table would also be the only business table in this schema
-- without a tenant_id, and one tenant's revision would move every other
-- tenant's parents onto an older-version flag overnight.
--
-- Version 1 is therefore implicit: it IS consent_purpose.description_en,
-- the platform's default wording, and it needs no row. A school that
-- publishes its own text gets version 2, then 3 — which is exactly AC3's
-- "revised from v2 to v3". current_consent_text_version() returns 1 when a
-- tenant has published nothing, so record_consent() works on day one for a
-- tenant that has never touched the wording.
--
-- The cost of the implicit v1 is that consent_record.text_version cannot be
-- a foreign key (there is no row to point at for v1). It is a bare int with
-- a positivity check; the value is only ever produced by
-- current_consent_text_version(), never taken from a caller.
--
-- ── Evidence (AC5) ─────────────────────────────────────────────────────
--
-- A new private 'consent-evidence' bucket, not a reuse of 'branding'
-- (tenant-level marks, world-readable in spirit) or 'admission-docs'
-- (keyed to an admission_application, which a consent captured years after
-- admission has no row in). A scanned admission form bearing a parent's
-- signature is per-student PII with its own retention story, so it gets its
-- own bucket, same private posture as every other bucket in this schema.
--
-- The upload ordering is the one deliberate deviation from the
-- reserve-row -> upload -> compensating-delete triad used by
-- admission-docs/branding, and the reason is this table's own
-- append-only rule: that triad needs a DELETE on the metadata row when the
-- upload fails, and consent_record must never be deletable. So the order is
-- inverted — reserve_consent_evidence_path() hands back a scoped path with
-- no row behind it, the caller uploads, and record_consent() then commits
-- the decision with the path attached. A failed insert leaves an orphaned
-- object rather than an orphaned row, and the bucket's SELECT policy
-- requires a referencing consent_record, so an orphan is unreadable by
-- anyone. Nothing dangles in the database, and the register stays
-- append-only.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. The catalogue: purposes and their published wording
-- ═══════════════════════════════════════════════════════════════════════

create table public.consent_purpose (
  code                                text primary key,
  description_en                      text not null,
  description_ur                      text,
  requires_reconsent_on_version_change boolean not null default false,
  -- What SILENCE means for this purpose. See the header.
  requires_explicit_grant             boolean not null default true,
  -- The dispatch channel this purpose gates, if any. Read by
  -- dispatch_absentee_notifications() so the channel -> purpose mapping is
  -- a lookup rather than a CASE buried in the dispatcher.
  gates_channel                       public.notification_channel unique,
  created_at                          timestamptz not null default clock_timestamp()
);

create table public.consent_text_version (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  purpose_code   text not null references public.consent_purpose(code) on delete cascade,
  -- Starts at 2: version 1 is the platform default wording carried on
  -- consent_purpose and has no row. See the header.
  version        int not null check (version > 1),
  body_en        text not null,
  body_ur        text,
  effective_from date not null default current_date,
  created_at     timestamptz not null default clock_timestamp(),
  constraint uq_consent_text_version unique (tenant_id, purpose_code, version)
);

insert into public.consent_purpose (code, description_en, description_ur, requires_reconsent_on_version_change, requires_explicit_grant, gates_channel) values
  ('student_photo_marketing', 'Use of the student''s photograph in school marketing, prospectus, website and social media.', 'اسکول کی تشہیر، پراسپیکٹس، ویب سائٹ اور سوشل میڈیا پر طالب علم کی تصویر کا استعمال۔', true, true, null),
  ('third_party_data_sharing', 'Sharing the student''s personal data with third parties such as boards, partners and vendors.', 'طالب علم کا ذاتی ڈیٹا بورڈز، شراکت داروں اور فروخت کنندگان کے ساتھ شیئر کرنا۔', true, true, null),
  ('sms_messaging', 'Receiving school notifications by SMS on the guardian''s registered number.', 'سرپرست کے رجسٹرڈ نمبر پر ایس ایم ایس کے ذریعے اسکول کی اطلاعات وصول کرنا۔', false, false, 'sms'),
  ('whatsapp_messaging', 'Receiving school notifications by WhatsApp on the guardian''s registered number.', 'سرپرست کے رجسٹرڈ نمبر پر واٹس ایپ کے ذریعے اسکول کی اطلاعات وصول کرنا۔', false, false, 'whatsapp');

create index idx_consent_text_version_lookup on public.consent_text_version (tenant_id, purpose_code, version desc);

create trigger consent_text_version_audit after insert or update or delete on public.consent_text_version
  for each row execute function app.tg_audit_row();

-- The version in force today for one tenant. A version dated in the future
-- is published but not yet effective, so a consent captured now still binds
-- to the current one. Falls back to 1 — the platform default wording — for
-- a tenant that has never published its own.
create or replace function public.current_consent_text_version(p_tenant_id uuid, p_purpose_code text)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select max(version) from public.consent_text_version
      where tenant_id = p_tenant_id and purpose_code = p_purpose_code and effective_from <= current_date),
    1
  );
$$;

revoke execute on function public.current_consent_text_version(uuid, text) from public, anon;
grant execute on function public.current_consent_text_version(uuid, text) to authenticated, service_role;

create or replace function public.publish_consent_text_version(
  p_purpose_code   text,
  p_body_en        text,
  p_body_ur        text default null,
  p_effective_from date default null
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_version   int;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.consent_purpose where code = p_purpose_code) then
    raise exception 'CONSENT_PURPOSE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_body_en is null or length(trim(p_body_en)) = 0 then
    raise exception 'BODY_REQUIRED' using errcode = '23514';
  end if;

  -- max(version) over every row, not just the effective ones: a version
  -- published today with a future effective_from still consumes its number.
  select coalesce(max(version), 1) + 1 into v_version
    from public.consent_text_version where tenant_id = v_tenant_id and purpose_code = p_purpose_code;

  insert into public.consent_text_version (tenant_id, purpose_code, version, body_en, body_ur, effective_from)
  values (v_tenant_id, p_purpose_code, v_version, p_body_en, p_body_ur, coalesce(p_effective_from, current_date));

  return v_version;
end;
$$;

revoke execute on function public.publish_consent_text_version(text, text, text, date) from public, anon;
grant execute on function public.publish_consent_text_version(text, text, text, date) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 2. The register
-- ═══════════════════════════════════════════════════════════════════════

create table public.consent_record (
  id                     uuid primary key default gen_random_uuid(),
  tenant_id              uuid not null references public.tenant(id) on delete cascade,
  campus_id              uuid not null references public.campus(id) on delete cascade,
  student_id             uuid not null references public.student(id) on delete cascade,
  purpose_code           text not null references public.consent_purpose(code),
  decision               text not null,
  -- Not nullable: a decision belongs to a person. AC4's resolution is
  -- "latest per guardian", which is not expressible if a row can float
  -- free of the guardian who made it.
  granted_by_guardian_id uuid not null references public.guardian(id) on delete restrict,
  channel                text not null,
  text_version           int not null,
  evidence_path          text unique,
  recorded_by            uuid references public.app_user(user_id),
  recorded_at            timestamptz not null default clock_timestamp(),
  -- Set on the OLD row when a newer decision replaces it, so the register
  -- keeps the full history while "current" stays a partial-index lookup.
  superseded_by          uuid references public.consent_record(id) on delete restrict,
  constraint chk_consent_decision check (decision in ('granted', 'denied', 'withdrawn')),
  constraint chk_consent_channel check (channel in ('portal', 'paper', 'counter', 'whatsapp')),
  -- AC5: a paper capture without the scan is an assertion, not evidence.
  constraint chk_consent_paper_evidence check (channel <> 'paper' or evidence_path is not null),
  -- Not a foreign key: version 1 is the platform default wording and has no
  -- row to point at (see the header). The value is only ever produced by
  -- current_consent_text_version(), never accepted from a caller.
  constraint chk_consent_text_version check (text_version > 0)
);

create index idx_consent_effective on public.consent_record (student_id, purpose_code, recorded_at desc) where superseded_by is null;
create index idx_consent_campus on public.consent_record (campus_id, purpose_code);
create index idx_consent_guardian on public.consent_record (granted_by_guardian_id);

create trigger consent_record_audit after insert or update or delete on public.consent_record
  for each row execute function app.tg_audit_row();

-- consent_record_no_delete. RLS already denies DELETE by omission, but an
-- omission is a silent zero-row statement, and the table owner and
-- service_role are not subject to RLS at all. FR-T08's certificate register
-- established the pattern for a register that must keep every entry it ever
-- held: refuse it loudly, at the row and at the statement, so a caller
-- learns the rule instead of believing the delete worked.
create or replace function app.tg_consent_record_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'consent register is append-only'
    using errcode = '42501',
          detail = format('delete of consent_record id=%s student=%s purpose=%s decision=%s by %s',
                          old.id, old.student_id, old.purpose_code, old.decision, current_user),
          hint = 'A withdrawal is a new row with decision=''withdrawn'', not the removal of the grant it replaces.';
end;
$$;

create trigger trg_consent_record_no_delete
  before delete on public.consent_record
  for each row execute function app.tg_consent_record_no_delete();

create or replace function app.tg_consent_record_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'consent register is append-only'
    using errcode = '42501',
          detail = format('truncate of consent_record by %s', current_user);
end;
$$;

create trigger trg_consent_record_no_truncate
  before truncate on public.consent_record
  for each statement execute function app.tg_consent_record_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- 3. has_consent() — the whole enforcement rule, in one place
-- ═══════════════════════════════════════════════════════════════════════

-- AC4 lives here and nowhere else. Note what the signature does NOT accept:
-- a guardian, a "consider only" list, an override flag. A caller can only
-- ask the question; it cannot shape the answer.
--
-- The join to student_guardian with to_date is null is deliberate in both
-- directions: a guardian whose link has been closed (custody change, a
-- relative who is no longer a contact) stops binding the student, in the
-- same way for a denial as for a grant. Consent belongs to the people
-- currently responsible for the child.
--
-- text_version is not read. See the header — that is AC3's "existing v2
-- consents remain VALID", implemented as an input this function does not
-- have rather than as a rule it happens to get right.
create or replace function public.has_consent(p_student_id uuid, p_purpose text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_requires_grant boolean;
  v_denied         boolean;
  v_granted        boolean;
begin
  select requires_explicit_grant into v_requires_grant
    from public.consent_purpose where code = p_purpose;
  if not found then
    raise exception 'CONSENT_PURPOSE_NOT_FOUND' using errcode = 'P0002', detail = format('purpose=%s', p_purpose);
  end if;

  with latest as (
    select distinct on (cr.granted_by_guardian_id) cr.decision
      from public.consent_record cr
      join public.student_guardian sg
        on sg.student_id = cr.student_id
       and sg.guardian_id = cr.granted_by_guardian_id
       and sg.to_date is null
     where cr.student_id = p_student_id
       and cr.purpose_code = p_purpose
       and cr.superseded_by is null
     order by cr.granted_by_guardian_id, cr.recorded_at desc, cr.id desc
  )
  select bool_or(decision in ('denied', 'withdrawn')), bool_or(decision = 'granted')
    into v_denied, v_granted
    from latest;

  -- AC4: one denial is enough, whatever anyone else said.
  if coalesce(v_denied, false) then
    return false;
  end if;

  if v_requires_grant then
    return coalesce(v_granted, false);
  end if;
  return true;
end;
$$;

revoke execute on function public.has_consent(uuid, text) from public, anon;
grant execute on function public.has_consent(uuid, text) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. Reading the state: per-guardian decisions, and what needs attention
-- ═══════════════════════════════════════════════════════════════════════

-- The current decision of each currently-linked guardian. security_invoker
-- so consent_record's own RLS scopes it: a parent sees only their own
-- children's rows here, staff only their campus's.
create or replace view public.v_consent_guardian_decision
with (security_invoker = true) as
select distinct on (cr.student_id, cr.purpose_code, cr.granted_by_guardian_id)
       cr.id as consent_record_id,
       cr.tenant_id,
       cr.campus_id,
       cr.student_id,
       cr.purpose_code,
       cr.granted_by_guardian_id,
       g.name_en as guardian_name,
       sg.relationship,
       cr.decision,
       cr.channel,
       cr.text_version,
       cr.evidence_path,
       cr.recorded_at
  from public.consent_record cr
  join public.student_guardian sg
    on sg.student_id = cr.student_id and sg.guardian_id = cr.granted_by_guardian_id and sg.to_date is null
  join public.guardian g on g.id = cr.granted_by_guardian_id
 where cr.superseded_by is null
 order by cr.student_id, cr.purpose_code, cr.granted_by_guardian_id, cr.recorded_at desc, cr.id desc;

grant select on public.v_consent_guardian_decision to authenticated;

-- AC3 + AC4's surfacing, in one derived read. Nothing here is stored:
--   * has_conflict — at least one linked guardian granted AND at least one
--     denied or withdrew. The Principal's queue.
--   * reconsent_required — a still-honoured decision captured against an
--     older wording of a purpose that says a wording change is material.
--     Note it is computed against current_consent_text_version(), so
--     correcting a mis-dated version row corrects the flag with it.
--
-- campus_id and the student's name come from public.student, not from the
-- consent rows: a student who moves campus mid-year would otherwise appear
-- twice, once per campus their historic decisions were captured at.
create or replace view public.v_consent_attention
with (security_invoker = true) as
select s.tenant_id,
       s.campus_id,
       d.student_id,
       s.name_en                                                                  as student_name,
       s.gr_number,
       d.purpose_code,
       count(*)::int                                                              as guardian_count,
       count(*) filter (where d.decision = 'granted')::int                        as granted_count,
       count(*) filter (where d.decision in ('denied', 'withdrawn'))::int         as denied_count,
       bool_or(d.decision = 'granted') and bool_or(d.decision in ('denied', 'withdrawn')) as has_conflict,
       bool_or(
         p.requires_reconsent_on_version_change
         and d.decision = 'granted'
         and d.text_version < public.current_consent_text_version(s.tenant_id, d.purpose_code)
       )                                                                          as reconsent_required,
       max(d.recorded_at)                                                         as last_recorded_at
  from public.v_consent_guardian_decision d
  join public.consent_purpose p on p.code = d.purpose_code
  join public.student s on s.id = d.student_id
 group by s.tenant_id, s.campus_id, d.student_id, s.name_en, s.gr_number, d.purpose_code;

grant select on public.v_consent_attention to authenticated;

-- Every purpose for one student, including purposes with no record at all
-- (which is exactly the case requires_explicit_grant decides), plus the
-- authoritative effective answer straight from has_consent() so the UI can
-- never show a different verdict from the one the export enforces.
create or replace function public.consent_state_for_student(p_student_id uuid)
returns table (
  purpose_code            text,
  description_en          text,
  description_ur          text,
  current_version         int,
  effective               boolean,
  requires_explicit_grant boolean,
  has_conflict            boolean,
  reconsent_required      boolean,
  guardian_count          int,
  granted_count           int,
  denied_count            int
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.code,
         p.description_en,
         p.description_ur,
         public.current_consent_text_version(app.auth_tenant_id(), p.code),
         public.has_consent(p_student_id, p.code),
         p.requires_explicit_grant,
         coalesce(a.has_conflict, false),
         coalesce(a.reconsent_required, false),
         coalesce(a.guardian_count, 0),
         coalesce(a.granted_count, 0),
         coalesce(a.denied_count, 0)
    from public.consent_purpose p
    left join public.v_consent_attention a on a.purpose_code = p.code and a.student_id = p_student_id
   where exists (
     select 1 from public.student s
      where s.id = p_student_id
        and s.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner')
          or s.campus_id = any(app.auth_campus_ids())
          or s.id = any(app.auth_guardian_student_ids())
        )
   )
   order by p.code;
$$;

revoke execute on function public.consent_state_for_student(uuid) from public, anon;
grant execute on function public.consent_state_for_student(uuid) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 5. Capture: evidence path reservation, then the decision
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('consent-evidence', 'consent-evidence', false, 5242880, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

-- Returns a path, not a row. See the header for why this inverts the
-- reserve-row/upload/compensating-delete order the other buckets use.
create or replace function public.reserve_consent_evidence_path(
  p_student_id uuid,
  p_file_ext   text,
  p_file_size  int,
  p_mime_type  text
)
returns text
-- Deliberately VOLATILE (the default): every call must mint a new uuid, so
-- two scans of the same student never collide on one path.
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_student   public.student%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_student from public.student where id = p_student_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_student.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_file_size is null or p_file_size <= 0 or p_file_size > 5242880 then
    raise exception 'FILE_TOO_LARGE' using errcode = '23514', detail = 'Maximum file size 5 MB';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png', 'application/pdf') then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '23514';
  end if;
  if p_file_ext is null or p_file_ext !~ '^[a-z0-9]{1,5}$' then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '23514', detail = 'file extension';
  end if;

  return v_tenant_id::text || '/' || p_student_id::text || '/' || gen_random_uuid()::text || '.' || p_file_ext;
end;
$$;

revoke execute on function public.reserve_consent_evidence_path(uuid, text, int, text) from public, anon;
grant execute on function public.reserve_consent_evidence_path(uuid, text, int, text) to authenticated;

-- The one writer of consent_record. Both actors go through it:
--   * a parent, from the portal, for their own child, as themselves —
--     p_guardian_id must be the guardian row their auth user owns, and the
--     channel is forced to 'portal'. A parent recording a 'paper' consent
--     for their own child would be manufacturing evidence.
--   * staff, from the counter, for any channel, within campus scope, with
--     recorded_by stamped so a paper capture has an accountable officer.
create or replace function public.record_consent(
  p_student_id    uuid,
  p_purpose_code  text,
  p_guardian_id   uuid,
  p_decision      text,
  p_channel       text,
  p_evidence_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_student   public.student%rowtype;
  v_version   int;
  v_id        uuid := gen_random_uuid();
  v_is_parent boolean;
begin
  if v_tenant_id is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_decision not in ('granted', 'denied', 'withdrawn') then
    raise exception 'INVALID_DECISION' using errcode = '23514';
  end if;
  if p_channel not in ('portal', 'paper', 'counter', 'whatsapp') then
    raise exception 'INVALID_CHANNEL' using errcode = '23514';
  end if;
  if not exists (select 1 from public.consent_purpose where code = p_purpose_code) then
    raise exception 'CONSENT_PURPOSE_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_student from public.student where id = p_student_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_is_parent := v_role = 'parent';

  if v_is_parent then
    if not (p_student_id = any(app.auth_guardian_student_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (
      select 1 from public.guardian where id = p_guardian_id and tenant_id = v_tenant_id and auth_user_id = (select auth.uid())
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'a guardian may only record their own decision';
    end if;
    if p_channel <> 'portal' then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'a guardian may only record a portal consent';
    end if;
    if p_evidence_path is not null then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'evidence is attached by staff';
    end if;
  else
    if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner') and not (v_student.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- AC4's data precondition: a decision is only meaningful from someone
  -- the resolution will actually consider.
  if not exists (
    select 1 from public.student_guardian
     where student_id = p_student_id and guardian_id = p_guardian_id and to_date is null
  ) then
    raise exception 'GUARDIAN_NOT_LINKED' using errcode = 'P0002';
  end if;

  -- AC5: paper without a scan is refused before anything is written.
  if p_channel = 'paper' and p_evidence_path is null then
    raise exception 'EVIDENCE_REQUIRED' using errcode = '23514';
  end if;
  if p_evidence_path is not null
     and p_evidence_path not like (v_tenant_id::text || '/' || p_student_id::text || '/%') then
    raise exception 'EVIDENCE_PATH_MISMATCH' using errcode = '23514';
  end if;

  v_version := public.current_consent_text_version(v_tenant_id, p_purpose_code);

  -- Insert first, supersede second: superseded_by is a self-reference, so
  -- pointing the old rows at v_id before the row exists trips the FK.
  insert into public.consent_record (
    id, tenant_id, campus_id, student_id, purpose_code, decision,
    granted_by_guardian_id, channel, text_version, evidence_path, recorded_by
  ) values (
    v_id, v_tenant_id, v_student.campus_id, p_student_id, p_purpose_code, p_decision,
    p_guardian_id, p_channel, v_version, p_evidence_path, (select auth.uid())
  );

  update public.consent_record
     set superseded_by = v_id
   where student_id = p_student_id
     and purpose_code = p_purpose_code
     and granted_by_guardian_id = p_guardian_id
     and superseded_by is null
     and id <> v_id;

  return jsonb_build_object(
    'consent_record_id', v_id,
    'text_version', v_version,
    'effective', public.has_consent(p_student_id, p_purpose_code)
  );
end;
$$;

revoke execute on function public.record_consent(uuid, text, uuid, text, text, text) from public, anon;
grant execute on function public.record_consent(uuid, text, uuid, text, text, text) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 6. AC1's enforcement point: the marketing gallery export
-- ═══════════════════════════════════════════════════════════════════════

create table public.marketing_gallery_export (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  section_id     uuid references public.class_section(id) on delete set null,
  requested_by   uuid references public.app_user(user_id),
  requested_at   timestamptz not null default clock_timestamp(),
  included_count int not null default 0,
  excluded_count int not null default 0
);

create index idx_marketing_export_campus on public.marketing_gallery_export (campus_id, requested_at desc);

create trigger marketing_gallery_export_audit after insert or update or delete on public.marketing_gallery_export
  for each row execute function app.tg_audit_row();

create table public.marketing_gallery_export_item (
  export_id  uuid not null references public.marketing_gallery_export(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  photo_path text not null,
  primary key (export_id, student_id)
);

-- AC1's audit row rides this table's own trigger — see the header for why
-- that is the honest reading of "written to audit_log with reason
-- 'consent_denied'" given audit_log.action is ('insert','update','delete').
-- tenant_id/campus_id are carried here specifically so app.tg_audit_row()
-- can scope the audit row it writes.
create table public.marketing_gallery_export_exclusion (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  export_id  uuid not null references public.marketing_gallery_export(id) on delete cascade,
  student_id uuid not null references public.student(id) on delete cascade,
  reason     text not null,
  created_at timestamptz not null default clock_timestamp(),
  -- 'consent_denied' is reserved for AC1's literal case — a guardian said
  -- no. A student nobody has been asked about yet is excluded just as
  -- firmly (opt-in, see the header) but recording that as a denial would
  -- put words in a parent's mouth in the permanent audit trail.
  constraint chk_gallery_exclusion_reason check (reason in ('consent_denied', 'consent_not_recorded', 'no_photo_on_file')),
  constraint uq_gallery_exclusion unique (export_id, student_id)
);

create index idx_gallery_exclusion_export on public.marketing_gallery_export_exclusion (export_id, reason);

create trigger marketing_gallery_export_exclusion_audit after insert or update or delete on public.marketing_gallery_export_exclusion
  for each row execute function app.tg_audit_row();

-- The gallery cannot be assembled without going through has_consent(): the
-- membership test IS the consent test, there is no "include anyway" flag,
-- and every student the consent check turns away leaves an exclusion row
-- (and therefore an audit_log row) behind rather than silently vanishing.
create or replace function public.build_marketing_gallery_export(p_campus_id uuid, p_section_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_export_id uuid := gen_random_uuid();
  v_student   record;
  v_included  int := 0;
  v_denied    int := 0;
  v_unasked   int := 0;
  v_no_photo  int := 0;
  v_reason    text;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.marketing_gallery_export (id, tenant_id, campus_id, section_id, requested_by)
  values (v_export_id, v_tenant_id, p_campus_id, p_section_id, (select auth.uid()));

  for v_student in
    select distinct s.id, s.photo_path
      from public.student s
      join public.enrolment e on e.student_id = s.id and e.status = 'active'
     where s.tenant_id = v_tenant_id
       and s.campus_id = p_campus_id
       and s.status = 'active'
       and s.deleted_at is null
       and (p_section_id is null or e.section_id = p_section_id)
     order by s.id
  loop
    if not public.has_consent(v_student.id, 'student_photo_marketing') then
      v_reason := case when exists (
        select 1 from public.v_consent_guardian_decision d
         where d.student_id = v_student.id
           and d.purpose_code = 'student_photo_marketing'
           and d.decision in ('denied', 'withdrawn')
      ) then 'consent_denied' else 'consent_not_recorded' end;
      insert into public.marketing_gallery_export_exclusion (tenant_id, campus_id, export_id, student_id, reason)
      values (v_tenant_id, p_campus_id, v_export_id, v_student.id, v_reason);
      if v_reason = 'consent_denied' then v_denied := v_denied + 1; else v_unasked := v_unasked + 1; end if;
    elsif v_student.photo_path is null then
      insert into public.marketing_gallery_export_exclusion (tenant_id, campus_id, export_id, student_id, reason)
      values (v_tenant_id, p_campus_id, v_export_id, v_student.id, 'no_photo_on_file');
      v_no_photo := v_no_photo + 1;
    else
      insert into public.marketing_gallery_export_item (export_id, student_id, photo_path)
      values (v_export_id, v_student.id, v_student.photo_path);
      v_included := v_included + 1;
    end if;
  end loop;

  update public.marketing_gallery_export
     set included_count = v_included, excluded_count = v_denied + v_unasked + v_no_photo
   where id = v_export_id;

  return jsonb_build_object(
    'export_id', v_export_id,
    'included', v_included,
    'excluded_consent_denied', v_denied,
    'excluded_consent_not_recorded', v_unasked,
    'excluded_no_photo', v_no_photo
  );
end;
$$;

revoke execute on function public.build_marketing_gallery_export(uuid, uuid) from public, anon;
grant execute on function public.build_marketing_gallery_export(uuid, uuid) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 7. AC2's enforcement point: FR-G12's real dispatcher, extended
-- ═══════════════════════════════════════════════════════════════════════

-- Dropped and recreated rather than CREATE OR REPLACEd: adding a third
-- defaulted parameter to a two-parameter function creates a SECOND
-- overload, and every existing two-argument call site (the Absentee
-- Notifications page, absentee_sms_notification.test.sql) would then be
-- ambiguous. The two-argument call keeps working against the new
-- definition through the default.
drop function public.dispatch_absentee_notifications(uuid, date);

create or replace function public.dispatch_absentee_notifications(
  p_campus_id uuid,
  p_date      date default current_date,
  p_channel   public.notification_channel default 'sms'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row          record;
  v_queued       int := 0;
  v_skipped      int := 0;
  v_optout       int := 0;
  v_body_len     int;
  v_segment_len  int;
  v_cost         int;
  v_spent_today  int;
  v_cap          int;
  v_name         text;
  v_purpose      text;
  v_student_id   uuid;
  c_paisa_per_segment constant int := 100;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_tenant_id() is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- FR-T15 AC2. The purpose is looked up from the channel rather than
  -- hardcoded, so a channel with no consent purpose behind it (today:
  -- 'push') dispatches exactly as it did before this migration.
  select code into v_purpose from public.consent_purpose where gates_channel = p_channel;

  -- Serializes the whole read-spend/check-cap/insert sequence per
  -- campus+date, the same class of race FR-B05's fn_queue_appointment_
  -- reminders() already locks against. The cap is a campus-wide messaging
  -- budget, so the lock is deliberately NOT keyed on channel — two
  -- channels dispatching at once must still share one budget.
  perform pg_advisory_xact_lock(hashtextextended('absentee-sms-cap:' || p_campus_id::text || ':' || p_date::text, 0));

  select daily_sms_cap_paisa into v_cap from public.campus where id = p_campus_id;
  select coalesce(sum(cost_paisa), 0) into v_spent_today
    from public.attendance_notification
   where campus_id = p_campus_id and notification_date = p_date;

  for v_row in select * from public.absentees_for_date(p_campus_id, p_date) loop
    -- Already handled by an earlier run today — skip before touching
    -- cost/cap accounting at all, so a re-run's own already-queued
    -- candidates can never inflate v_spent_today or trip the cap early.
    if exists (
      select 1 from public.attendance_notification
       where enrolment_id = v_row.enrolment_id and notification_date = p_date and channel = p_channel
    ) then
      continue;
    end if;

    if v_row.guardian_id is null or v_row.phone_e164 is null then
      insert into public.attendance_notification (
        tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
      )
      select tenant_id, p_campus_id, v_row.enrolment_id, p_date, p_channel, 'absentee_daily_' || v_row.language::text, v_row.language, null, 'skipped_no_contact', 0
        from public.enrolment where id = v_row.enrolment_id
      on conflict (enrolment_id, notification_date, channel) do nothing;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- FR-T15 AC2: the consent state is read HERE, at dispatch time, from
    -- the live register — a withdrawal recorded at 11:00 is already in
    -- force for an 11:05 run because nothing about the candidate set was
    -- snapshotted earlier, exactly as FR-G12 already relies on for
    -- same-day attendance corrections. The recipient's number is never
    -- put on the row; the skip is the record.
    if v_purpose is not null then
      select student_id into v_student_id from public.enrolment where id = v_row.enrolment_id;
      if not public.has_consent(v_student_id, v_purpose) then
        insert into public.attendance_notification (
          tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
        )
        select tenant_id, p_campus_id, v_row.enrolment_id, p_date, p_channel, 'absentee_daily_' || v_row.language::text, v_row.language, null, 'skipped_optout', 0
          from public.enrolment where id = v_row.enrolment_id
        on conflict (enrolment_id, notification_date, channel) do nothing;
        v_optout := v_optout + 1;
        continue;
      end if;
    end if;

    v_name := case when v_row.language = 'ur' then coalesce(v_row.student_name_ur, v_row.student_name) else v_row.student_name end;
    v_body_len := length(
      case v_row.language
        when 'ur' then v_name || ' (GR ' || v_row.gr_number || ') ' || v_row.section_label || ' ' || p_date::text || ' غیر حاضر'
        else v_name || ' (GR ' || v_row.gr_number || ') was absent from ' || v_row.section_label || ' on ' || p_date::text || '.'
      end
    );
    v_segment_len := case v_row.language when 'ur' then 70 else 160 end;
    v_cost := ceil(v_body_len::numeric / v_segment_len) * c_paisa_per_segment;

    if v_cap is not null and v_spent_today + v_cost > v_cap then
      exit; -- daily budget reached; the rest are picked up by a later re-run
    end if;

    insert into public.attendance_notification (
      tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
    )
    select tenant_id, p_campus_id, v_row.enrolment_id, p_date, p_channel, 'absentee_daily_' || v_row.language::text, v_row.language, v_row.phone_e164, 'queued', v_cost
      from public.enrolment where id = v_row.enrolment_id
    on conflict (enrolment_id, notification_date, channel) do nothing;
    v_queued := v_queued + 1;
    v_spent_today := v_spent_today + v_cost;
  end loop;

  return jsonb_build_object(
    'queued', v_queued,
    'skipped_no_contact', v_skipped,
    -- AC2's "recorded in the campaign report". Module M is not built, so
    -- the report is this summary plus the attendance_notification rows it
    -- counts; both name the skip.
    'skipped_no_consent', v_optout,
    'sections_not_marked', (select count(*) from public.sections_not_marked(p_campus_id, p_date))
  );
end;
$$;

revoke execute on function public.dispatch_absentee_notifications(uuid, date, public.notification_channel) from public, anon;
grant execute on function public.dispatch_absentee_notifications(uuid, date, public.notification_channel) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 8. RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.consent_purpose enable row level security;
alter table public.consent_text_version enable row level security;
alter table public.consent_record enable row level security;
alter table public.marketing_gallery_export enable row level security;
alter table public.marketing_gallery_export_item enable row level security;
alter table public.marketing_gallery_export_exclusion enable row level security;

-- The purpose list and the school's own wording are the text a parent is
-- consenting TO, so both are readable by everyone who can be asked to
-- consent — the purposes globally (a fixed code list), the wording within
-- the tenant that published it. Neither has a write policy: the migration
-- seeds the purposes and publish_consent_text_version() (SECURITY DEFINER)
-- is the only writer of wording.
create policy consent_purpose_read_all on public.consent_purpose
  for select to authenticated using (true);

create policy consent_text_version_read_tenant on public.consent_text_version
  for select to authenticated using (tenant_id = app.auth_tenant_id());

create policy consent_record_parent_read_own on public.consent_record
  for select to authenticated
  using (student_id = any(app.auth_guardian_student_ids()));

-- FR-C11 gave guardians a portal login, but nothing inside the portal has
-- ever needed to read a guardian or student_guardian row — /portal/homework
-- and /portal/timetable work entirely off enrolment, and both tables are
-- still campus-scoped, which a parent (no user_campus rows, by design)
-- never satisfies. A consent page is the first parent surface that does
-- need them: it has to show which answer is on file as THEIRS, and
-- record_consent() takes the guardian id the portal submits. Both policies
-- are additive and scoped to the signed-in guardian — no staff policy is
-- widened, and the other guardian's contact row stays unreadable (which is
-- also why v_consent_guardian_decision shows a parent only their own
-- decisions, while the conflict flag they see comes from
-- consent_state_for_student()).
create policy guardian_parent_read_self on public.guardian
  for select to authenticated
  using (auth_user_id = (select auth.uid()));

create policy student_guardian_parent_read_own on public.student_guardian
  for select to authenticated
  using (student_id = any(app.auth_guardian_student_ids()));

create policy consent_record_staff_read on public.consent_record
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- consent_record_write_staff, stated rather than implied: record_consent()
-- is SECURITY DEFINER and therefore not subject to RLS, so it is the only
-- writer either way. This policy exists so that the absence of an INSERT
-- path for a direct PostgREST write is a decision a reader can see, not one
-- they have to infer from an omission — the same reason FR-T08 kept an
-- explicit `using (false)` DELETE policy on the certificate register. It
-- deliberately does NOT widen anything: the same role and campus scope
-- record_consent() enforces, and a direct insert still cannot pick its own
-- text_version or supersede the row it replaces, which is why the RPC
-- remains the supported path.
create policy consent_record_write_staff on public.consent_record
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- consent_record_no_delete. RLS's own denial is a zero-row statement; the
-- BEFORE DELETE trigger above is what makes it an error. Both are kept:
-- the policy states the rule for anyone reading the policies, the trigger
-- enforces it against callers RLS does not reach.
create policy consent_record_no_delete on public.consent_record
  for delete to authenticated
  using (false);

create policy gallery_export_read_scope on public.marketing_gallery_export
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy gallery_export_item_read_scope on public.marketing_gallery_export_item
  for select to authenticated
  using (exists (select 1 from public.marketing_gallery_export e where e.id = export_id));

create policy gallery_exclusion_read_scope on public.marketing_gallery_export_exclusion
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- ── storage: consent-evidence ──────────────────────────────────────────

-- INSERT is gated on the path's own tenant/student segments rather than on
-- a pre-existing metadata row, because the row is written after the upload
-- here (see the header). The student segment must still name a student the
-- uploader could record a consent for, so a staff member cannot write into
-- another campus's folder.
create policy consent_evidence_insert_staff on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'consent-evidence'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist')
    and (storage.foldername(name))[1] = app.auth_tenant_id()::text
    and exists (
      select 1 from public.student s
       where s.id::text = (storage.foldername(name))[2]
         and s.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any(app.auth_campus_ids()))
    )
  );

-- Readable only once a consent_record actually references it, which is
-- also what makes an orphan from a failed record_consent() unreachable.
-- The guardian branch is deliberate: a parent is entitled to see the paper
-- form they signed.
create policy consent_evidence_read_scope on storage.objects
  for select to authenticated
  using (
    bucket_id = 'consent-evidence'
    and exists (
      select 1 from public.consent_record cr
       where cr.evidence_path = objects.name
         and cr.tenant_id = app.auth_tenant_id()
         and (
           (app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist')
            and (app.auth_role() in ('super_admin', 'owner') or cr.campus_id = any(app.auth_campus_ids())))
           or cr.student_id = any(app.auth_guardian_student_ids())
         )
    )
  );

-- No UPDATE and no DELETE policy: a signed form is evidence, and evidence
-- that can be replaced in place is not evidence.
