-- FR-T03: Transfer Certificate issuance workflow.
--
-- "As an Admissions Officer, I want to issue a Transfer Certificate that
-- carries the student's GR number, dates, conduct and last class passed,
-- so that the receiving school can legally admit the child."
--
-- Third of module T's certificates cluster, and the point where the first
-- two converge: FR-T01
-- (20260731860000_certificate_template_designer.sql) authored the wording
-- and left resolve_certificate_template() as the documented entry point;
-- FR-T02 (20260731870000_certificate_serial_allocation.sql) built the
-- gapless allocator and left it grantable only to service_role so that the
-- ONLY way to consume a number is from inside the transaction that writes
-- the certificate behind it. This migration is that transaction.
--
-- ── Where the transaction boundary actually is ─────────────────────────
--
-- T02's header asks that allocate_certificate_serial() be called inline,
-- "in the same transaction as the PDF render, so a render failure returns
-- the number". Postgres cannot render a PDF, so the literal reading is
-- unbuildable; what is buildable — and is what that requirement is
-- protecting — is that NOTHING which can fail is left between the
-- allocation and the commit. So:
--
--   * issue_transfer_certificate() is one transaction and does every
--     fallible thing it can BEFORE it allocates: role and campus scope,
--     enrolment and student state, the duplicate check, the leaving date,
--     template resolution, and the whole merge payload. The allocation is
--     the second-to-last statement; only the certificate_issue insert and
--     the enrolment update follow it. Any failure in those — the
--     uq_one_active_tc race backstop, a constraint, a trigger — rolls the
--     counter back with them, exactly as T02's AC2 requires, because the
--     increment is an ordinary transactional UPDATE and not a nextval().
--
--   * The PDF render therefore happens AFTER that commit, in the server
--     action, and is deliberately NOT on the issuance transaction's
--     critical path. If it fails, the action calls
--     void_certificate_issue(), which reverts the enrolment and marks the
--     row 'void' while KEEPING its serial. That is the one thing T02
--     forbids relaxing: the counter is never rewound, because a rewound
--     number is a number that gets printed twice. A void row is a number
--     the register accounts for; a rewind is a number the register lies
--     about.
--
-- ── payload_snapshot is what makes T01's promise real ──────────────────
--
-- T01 guarantees an activated template version is never mutated and never
-- deleted, so template_id + template_version alone would already pin the
-- wording. The snapshot goes further and freezes the RESOLVED VALUES too —
-- the student's name as it read that day, the class they were in, the
-- serial, the words of their date of birth, the branding paths — because
-- the wording is only half of what a reprint has to reproduce. A student
-- renamed, moved section or re-admitted next year must not change what
-- their 2026 Transfer Certificate says. The issued PDF itself is stored
-- and served verbatim; the snapshot is the evidence of what those bytes
-- say, the input any reconstruction renders from, and what FR-T09 will
-- hash against.
--
-- ── AC1: rosters, via left_on and nothing else ─────────────────────────
--
-- Every point-in-time roster in this schema is already
-- `e.joined_on <= d and (e.left_on is null or e.left_on >= d)`
-- (FR-G13's check_unmarked_attendance, FR-G14's compute_month_attendance,
-- absentee_sms's section_register_submitted), and every "current roster"
-- is `e.status = 'active'`. Setting left_on = the leaving date and status
-- = 'transferred' therefore satisfies AC1 through the mechanisms that
-- already exist: the student stays on the roster up to and including the
-- leaving date and is off it the day after, and is off every current
-- roster immediately. No parallel exclusion mechanism is introduced, and
-- none is needed.
--
-- student.status is deliberately NOT changed. The point-in-time rosters
-- read TODAY's student status (`s.status = 'active'`) rather than a dated
-- one, so marking the student 'transferred' would retroactively empty
-- every historical register they ever appeared in — the opposite of "no
-- longer appears for dates AFTER the leaving date". Moving the student
-- record itself is fn_change_student_status()'s job (it requires a
-- Principal and a document for 'active' -> 'transferred'), and it is a
-- separate decision from issuing the certificate.
--
-- FR-A15's soft delete and FR-A06's rollover both stay sane: a deleted
-- enrolment or student cannot be issued a TC at all, and rollover's
-- eligibility scan already requires e.status = 'active', so a transferred
-- enrolment is skipped rather than promoted. enrolment's
-- `unique (student_id, session_id)` is untouched — re-admitting a
-- transferred student INTO THE SAME SESSION is still blocked, which is
-- pre-existing behaviour and not this FR's to change.
--
-- ── dob_to_words: English only, and that is a decision, not a gap ──────
--
-- AC3 pins the English form exactly ('Fourth March Two Thousand Eleven').
-- Urdu is implemented as NULL rather than as English text: T01 established
-- that a request for an Urdu certificate must never silently produce an
-- English one, and an Urdu date-in-words needs a numeral lexicon
-- (ordinals, the irregular 1-99 cardinals) that has to be reviewed by
-- someone who reads Urdu before it goes on a board document. An
-- unreviewed guess printed on a statutory certificate is worse than the
-- visible `[student.dob_words]` gap lib/certificates/merge.ts renders for
-- a missing value. student.dob_words is not a required field on transfer
-- templates, so nothing else depends on it.
--
-- ── Dates print as DD-MM-YYYY ──────────────────────────────────────────
--
-- AC3 spells the figure form of the date of birth out as '04-03-2011'.
-- T01's catalogue previews dates in the long form ('04 March 2012'), but
-- those are sample values for a template preview, not a format contract,
-- and two date formats on one statutory page is worse than either. Every
-- date on an issued certificate is therefore DD-MM-YYYY.
--
-- ── What the rest of the cluster adds (NOT built here) ─────────────────
--
--   * FR-T05 (Character Certificates): reuses certificate_issue with
--     certificate_type = 'character'. It gets an independent serial series
--     for free (certificate_type is part of T02's counter key), and
--     uq_one_active_tc is deliberately partial on certificate_type =
--     'transfer' so a student may hold many character certificates. Its
--     conduct-grade check constraint belongs on its own issuing function
--     or as a further table constraint; transfer.conduct is free text here
--     because a TC's conduct line is board wording, not a graded scale.
--   * FR-T08 (statutory register): the 'cancelled' status value and
--     replaced_by_issue_id already exist for it — shipped now because
--     ALTER TYPE ... ADD VALUE cannot share a migration with a statement
--     that uses the new value, and T08 should not need two files for one
--     enum label. T08 adds the append-only triggers (no UPDATE except
--     through the sanctioned transitions, no DELETE at all) and
--     v_certificate_register, which is why no view of that name is created
--     here.
--   * FR-T09 (digital signature/stamp): adds pdf_sha256 and
--     signing_identity_id to certificate_issue. Until it lands,
--     signatory.name / signatory.designation resolve to the issuing user
--     and their role, which is what the paper document is signed by
--     anyway.
--   * Duplicate issuance ("use Duplicate instead") is a separate FR.
--     original_issue_id is shaped for it: a duplicate is a new row with a
--     new serial of its own pointing back at the original, so the register
--     shows both and the original keeps its number. Nothing here builds
--     it, and uq_one_active_tc is on enrolment_id so a duplicate will need
--     to be a status other than 'issued' or to carry original_issue_id
--     into that index's predicate — noted, not decided.
--
-- Every function below has its full signature fixed. Adding a defaulted
-- argument with CREATE OR REPLACE creates a DISTINCT overload and makes
-- existing calls ambiguous (FR-G05 hit exactly this) — drop and recreate,
-- and re-issue the grants.

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the date of birth in words
-- ═══════════════════════════════════════════════════════════════════════

-- 0..99. Enough for both halves of a date in words: the day never exceeds
-- 31 and the year is written as a century word plus its remainder.
create or replace function app.int_to_words_en(p_n int)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_n is null or p_n < 0 or p_n > 99 then null
    when p_n < 20 then (array[
      'Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
      'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
      'Seventeen', 'Eighteen', 'Nineteen'])[p_n + 1]
    else (array['Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'])[p_n / 10 - 1]
         || case when p_n % 10 = 0 then ''
                 else ' ' || (array['One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'])[p_n % 10]
            end
  end;
$$;

-- Pure lexicon, no data access. Granted to authenticated the same way
-- every other app.* helper is, because dob_to_words() is SECURITY INVOKER
-- and would otherwise fail for the role that calls it. Schema app is not
-- exposed through PostgREST, so this is not an API surface.
revoke execute on function app.int_to_words_en(int) from public, anon;
grant execute on function app.int_to_words_en(int) to authenticated;

-- The day of a date in words is an ORDINAL on an English certificate
-- ('Fourth March ...'), which is why this is a table rather than
-- int_to_words_en() with a suffix rule: 'First', 'Second', 'Third',
-- 'Twelfth' and 'Twentieth' are all irregular.
create or replace function app.day_ordinal_words_en(p_day int)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_day between 1 and 31 then (array[
    'First', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'Seventh', 'Eighth', 'Ninth', 'Tenth',
    'Eleventh', 'Twelfth', 'Thirteenth', 'Fourteenth', 'Fifteenth', 'Sixteenth', 'Seventeenth',
    'Eighteenth', 'Nineteenth', 'Twentieth', 'Twenty First', 'Twenty Second', 'Twenty Third',
    'Twenty Fourth', 'Twenty Fifth', 'Twenty Sixth', 'Twenty Seventh', 'Twenty Eighth',
    'Twenty Ninth', 'Thirtieth', 'Thirty First'])[p_day] end;
$$;

revoke execute on function app.day_ordinal_words_en(int) from public, anon;
grant execute on function app.day_ordinal_words_en(int) to authenticated;

-- AC3: 2011-03-04 -> 'Fourth March Two Thousand Eleven'.
--
-- The month name comes from a literal array rather than to_char(d,
-- 'FMMonth'): to_char is lc_time-dependent and therefore only STABLE, and
-- a statutory document must not word itself differently because the
-- server's locale changed.
--
-- p_lang mirrors public.certificate_language. 'ur' returns NULL on
-- purpose — see the header.
create or replace function public.dob_to_words(p_date date, p_lang text default 'en')
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_year  int;
  v_rest  int;
  v_years text;
begin
  if p_date is null or coalesce(p_lang, 'en') <> 'en' then
    return null;
  end if;

  v_year := extract(year from p_date)::int;
  v_rest := v_year % 100;
  v_years := case
    when v_year between 2000 and 2099 then
      'Two Thousand' || case when v_rest = 0 then '' else ' ' || app.int_to_words_en(v_rest) end
    when v_year between 1900 and 1999 then
      'Nineteen ' || case when v_rest = 0 then 'Hundred' else app.int_to_words_en(v_rest) end
  end;
  if v_years is null then
    return null;
  end if;

  return app.day_ordinal_words_en(extract(day from p_date)::int)
         || ' '
         || (array['January', 'February', 'March', 'April', 'May', 'June', 'July',
                   'August', 'September', 'October', 'November', 'December'])[extract(month from p_date)::int]
         || ' '
         || v_years;
end;
$$;

revoke execute on function public.dob_to_words(date, text) from public, anon;
grant execute on function public.dob_to_words(date, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- certificate_issue — the bound register
-- ═══════════════════════════════════════════════════════════════════════

-- 'void' is an issue whose document never came into existence (the render
-- or the upload failed); it keeps its serial so the series has no hole.
-- 'cancelled' is FR-T08's: a real certificate withdrawn after the fact,
-- cross-referenced to its replacement.
create type public.certificate_issue_status as enum ('issued', 'void', 'cancelled');

create table public.certificate_issue (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  student_id           uuid not null references public.student(id),
  -- Nullable because FR-T05's character and bonafide certificates are not
  -- one-per-enrolment and a school may issue one to a student between
  -- sessions; a transfer certificate always has one (chk below).
  enrolment_id         uuid references public.enrolment(id),
  -- The session the serial was numbered against — T02 keys its counter on
  -- it, and the register is read a year at a time.
  session_id           uuid not null references public.academic_session(id),
  certificate_type     public.certificate_type not null,
  serial_no            text not null,
  -- T01 guarantees an activated version is never mutated and never
  -- deleted, so this really is evidence of what was printed.
  template_id          uuid not null references public.certificate_template(id),
  template_version     int not null check (template_version > 0),
  language             public.certificate_language not null,
  status               public.certificate_issue_status not null default 'issued',
  pdf_path             text not null,
  payload_snapshot     jsonb not null,
  issued_by            uuid references public.app_user(user_id),
  issued_at            timestamptz not null default clock_timestamp(),
  revoked_at           timestamptz,
  revoke_reason        text,
  -- Shaped for the duplicate-issuance FR: a duplicate is its own row with
  -- its own serial, pointing back at the original.
  original_issue_id    uuid references public.certificate_issue(id),
  -- Shaped for FR-T08: a cancelled certificate names what replaced it.
  replaced_by_issue_id uuid references public.certificate_issue(id),
  created_at           timestamptz not null default clock_timestamp(),
  constraint chk_cert_issue_snapshot check (jsonb_typeof(payload_snapshot) = 'object'),
  constraint chk_cert_issue_transfer_enrolment check (certificate_type <> 'transfer' or enrolment_id is not null),
  constraint chk_cert_issue_revocation check ((status = 'issued') = (revoked_at is null))
);

-- AC2's structural half. Partial on certificate_type so FR-T05's character
-- certificates, which are explicitly NOT one-per-enrolment, are unaffected;
-- partial on status so a voided attempt frees the enrolment for a retry
-- and FR-T08's cancellation frees it for a replacement.
create unique index uq_one_active_tc on public.certificate_issue (enrolment_id)
  where certificate_type = 'transfer' and status = 'issued';

-- A serial identifies exactly one document within its own campus and
-- series, whatever became of it. Voided and cancelled rows keep theirs.
create unique index uq_cert_issue_serial on public.certificate_issue (campus_id, certificate_type, serial_no);
create unique index uq_cert_issue_pdf_path on public.certificate_issue (pdf_path);

create index idx_cert_issue_student on public.certificate_issue (student_id);
create index idx_cert_issue_enrolment on public.certificate_issue (enrolment_id);
create index idx_cert_issue_scope on public.certificate_issue (tenant_id, campus_id, certificate_type, issued_at desc);
create index idx_cert_issue_template on public.certificate_issue (template_id);

create trigger certificate_issue_audit after insert or update or delete on public.certificate_issue
  for each row execute function app.tg_audit_row();

alter table public.enrolment add column tc_issued_at timestamptz;
alter table public.enrolment add column tc_certificate_issue_id uuid references public.certificate_issue(id);

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.certificate_issue enable row level security;

-- The same roles that may issue may read the register, campus-scoped.
create policy cert_issue_campus_scope on public.certificate_issue
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- A guardian sees their own children's certificates, and only ones that
-- actually exist as documents: a voided attempt and (later) a cancelled
-- certificate are register entries, not things a parent should be handed.
create policy cert_issue_parent_read on public.certificate_issue
  for select to authenticated
  using (student_id = any(app.auth_guardian_student_ids()) and status = 'issued');

-- There is no write policy, so writes are already denied; this states it,
-- so the property does not have to be inferred from an absence. Every
-- write goes through the SECURITY DEFINER functions below, which run as
-- the table owner and are not subject to it.
create policy cert_issue_no_direct_dml on public.certificate_issue
  for update to authenticated
  using (false)
  with check (false);

-- ═══════════════════════════════════════════════════════════════════════
-- Storage: private bucket, path is {tenant_id}/{campus_id}/{type}/{serial}.pdf
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('certificates', 'certificates', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;

-- An object can only be written to a path a certificate_issue row already
-- reserved, by someone who may issue — the same "the row reserves the
-- path" shape as FR-A18's branding bucket and FR-B10's admission-docs.
create policy certificates_insert_issuer on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'certificates'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.certificate_issue ci
       where ci.pdf_path = objects.name and ci.tenant_id = app.auth_tenant_id()
    )
  );

-- Read follows the register's own visibility: staff within their campus
-- scope, a guardian for their own child's issued certificate. The
-- subquery is subject to certificate_issue's RLS as well, so the two
-- cannot drift apart.
create policy certificates_read_scope on storage.objects
  for select to authenticated
  using (
    bucket_id = 'certificates'
    and exists (
      select 1 from public.certificate_issue ci
       where ci.pdf_path = objects.name
         and (
           (
             ci.tenant_id = app.auth_tenant_id()
             and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
             and (app.auth_role() in ('super_admin', 'owner') or ci.campus_id = any(app.auth_campus_ids()))
           )
           or (ci.status = 'issued' and ci.student_id = any(app.auth_guardian_student_ids()))
         )
    )
  );

-- No UPDATE or DELETE policy: an issued certificate's bytes are evidence,
-- and FR-T09 will hash them.

-- ═══════════════════════════════════════════════════════════════════════
-- Issuance
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.issue_transfer_certificate(
  p_enrolment_id uuid,
  p_leaving_date date,
  p_reason text default null,
  p_conduct text default null,
  p_board_code text default null,
  p_language public.certificate_language default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_uid         uuid := (select auth.uid());
  v_e           record;
  v_existing    record;
  v_template    public.certificate_template%rowtype;
  v_template_id uuid;
  v_signatory   text;
  v_issued_on   date := current_date;
  v_values      jsonb;
  v_snapshot    jsonb;
  v_serial      text;
  v_pdf_path    text;
  v_issue_id    uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- SECURITY DEFINER runs as the owner and therefore bypasses RLS, so the
  -- tenant predicate is written out and the campus scope is checked
  -- explicitly (b16ba25's convention). FOR UPDATE OF e serialises two
  -- clerks issuing against the same enrolment on the row itself, so the
  -- duplicate check below and uq_one_active_tc agree even under
  -- concurrency.
  select e.tenant_id, e.campus_id, e.session_id, e.student_id,
         e.status::text as enrolment_status, e.joined_on, e.deleted_at,
         s.name_en, s.name_ur, s.father_name_en, s.father_name_ur, s.gr_number,
         s.dob, s.gender::text as gender, s.religion, s.b_form_no,
         s.deleted_at as student_deleted_at,
         cl.name_en as class_name,
         cs.name as section_name,
         sess.name as session_name,
         c.name as campus_name, c.name_ur as campus_name_ur, c.code as campus_code, c.city as campus_city,
         t.name as tenant_name, t.name_ur as tenant_name_ur
    into v_e
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
    join public.academic_session sess on sess.id = e.session_id
    join public.campus c on c.id = e.campus_id
    join public.tenant t on t.id = e.tenant_id
   where e.id = p_enrolment_id
     and e.tenant_id = v_tenant_id
   for update of e;

  if not found or v_e.deleted_at is not null or v_e.student_deleted_at is not null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_role not in ('super_admin', 'owner') and not (v_e.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC2, and it comes FIRST on purpose. Issuing a TC is what sets the
  -- enrolment to 'transferred', so by the time a second request arrives the
  -- enrolment is no longer active and the AC4 check below would fire — with
  -- a message that tells the officer nothing about the document already in
  -- the family's hands. "There is already one, here is its number" is
  -- strictly the more specific diagnosis, so it is the one that wins.
  --
  -- The unique index alone would raise a bare 23505 with nothing a clerk
  -- can act on; it stays as the race backstop for two clerks who both got
  -- past this read.
  select ci.id, ci.serial_no, ci.issued_at
    into v_existing
    from public.certificate_issue ci
   where ci.enrolment_id = p_enrolment_id
     and ci.certificate_type = 'transfer'
     and ci.status = 'issued'
   limit 1;
  if found then
    raise exception 'TC_ALREADY_ISSUED: %', v_existing.serial_no
      using errcode = '23505',
            detail = format('issue_id=%s serial_no=%s issued_at=%s',
                            v_existing.id, v_existing.serial_no, v_existing.issued_at),
            hint = 'Use Duplicate instead of issuing a second original.';
  end if;

  -- AC4. The FR names this state 'pending_admission'; public
  -- .enrolment_status has no such value and deliberately gains none —
  -- an admission that has not been paid for and enrolled simply has no
  -- enrolment row yet (FR-B18 gates that), and an enrolment that is not
  -- 'active' is one the student has already left. Both are "the student
  -- was never enrolled here as of now", and both are refused by the same
  -- check, which will keep covering 'pending_admission' if a later FR
  -- introduces it.
  if v_e.enrolment_status <> 'active' then
    raise exception 'ENROLMENT_NOT_ACTIVE'
      using errcode = '55000',
            detail = format('enrolment_status=%s', v_e.enrolment_status),
            hint = 'A Transfer Certificate can only be issued for a student who is actually enrolled.';
  end if;

  if p_leaving_date is null or p_leaving_date < v_e.joined_on then
    raise exception 'LEAVING_DATE_BEFORE_ADMISSION'
      using errcode = '23514',
            detail = format('leaving_date=%s joined_on=%s', p_leaving_date, v_e.joined_on),
            hint = 'The leaving date cannot precede the date of admission.';
  end if;

  -- T01's documented entry point: campus+board, campus, tenant+board,
  -- tenant. Language never falls back, so an Urdu request that finds
  -- nothing is refused rather than silently printed in English.
  v_template_id := public.resolve_certificate_template(
    v_e.campus_id, 'transfer'::public.certificate_type, p_board_code, p_language);
  if v_template_id is null then
    raise exception 'TEMPLATE_NOT_FOUND'
      using errcode = 'P0002',
            detail = format('campus_id=%s board_code=%s language=%s', v_e.campus_id, p_board_code, p_language),
            hint = 'Activate a Transfer Certificate template for this campus, board and language first.';
  end if;
  select * into v_template from public.certificate_template where id = v_template_id;

  select au.full_name into v_signatory
    from public.app_user au where au.user_id = v_uid;

  v_values := jsonb_build_object(
    'school.name_en',              v_e.tenant_name,
    'school.name_ur',              v_e.tenant_name_ur,
    'campus.name',                 v_e.campus_name,
    'campus.code',                 v_e.campus_code,
    'issue.date',                  to_char(v_issued_on, 'DD-MM-YYYY'),
    'issue.place',                 v_e.campus_city,
    'student.name_en',             v_e.name_en,
    'student.name_ur',             v_e.name_ur,
    'student.father_name_en',      v_e.father_name_en,
    'student.father_name_ur',      v_e.father_name_ur,
    'student.gr_number',           v_e.gr_number,
    'student.dob',                 to_char(v_e.dob, 'DD-MM-YYYY'),
    'student.dob_words',           public.dob_to_words(v_e.dob, v_template.language::text),
    'student.gender',              initcap(v_e.gender),
    'student.religion',            v_e.religion,
    'student.b_form_no',           v_e.b_form_no,
    'enrolment.class_name',        v_e.class_name,
    'enrolment.section_name',      v_e.section_name,
    'enrolment.session_name',      v_e.session_name,
    'enrolment.joined_on',         to_char(v_e.joined_on, 'DD-MM-YYYY'),
    'enrolment.left_on',           to_char(p_leaving_date, 'DD-MM-YYYY'),
    'transfer.reason',             p_reason,
    'transfer.last_class_studied', v_e.class_name,
    'transfer.conduct',            p_conduct,
    -- Dues clearance is the fee module's answer to give (FR-K), and
    -- guessing it on a document a receiving school relies on would be
    -- worse than leaving the line visibly blank.
    'transfer.dues_cleared',       null,
    'transfer.remarks',            null,
    -- FR-T09 replaces these with a real signing identity.
    'signatory.name',              nullif(v_signatory, ''),
    'signatory.designation',       initcap(replace(v_role, '_', ' '))
  );

  -- LAST fallible statement before the write. Everything above can still
  -- refuse without ever touching the counter; everything below either
  -- commits with the number or takes the number down with it.
  v_serial := public.allocate_certificate_serial(
    v_e.campus_id, 'transfer'::public.certificate_type, v_e.session_id);
  v_values := v_values || jsonb_build_object('issue.serial_no', v_serial);

  -- A prefix_pattern may legitimately contain '/' (GHS-LHR/TC/2026/00147),
  -- which would otherwise turn into extra storage folders and break the
  -- three-segment path every storage policy above reads.
  v_pdf_path := v_e.tenant_id::text || '/' || v_e.campus_id::text || '/transfer/'
                || replace(v_serial, '/', '-') || '.pdf';

  v_snapshot := jsonb_build_object(
    'template', jsonb_build_object(
      'id',               v_template.id,
      'certificate_type', v_template.certificate_type,
      'board_code',       v_template.board_code,
      'language',         v_template.language,
      'version',          v_template.version,
      'status',           'issued',
      'title',            v_template.title,
      'body_html',        v_template.body_html,
      'page_size',        v_template.page_size
    ),
    'tenant', jsonb_build_object('name', v_e.tenant_name, 'name_ur', v_e.tenant_name_ur),
    'campus', jsonb_build_object('name', v_e.campus_name, 'name_ur', v_e.campus_name_ur,
                                 'code', v_e.campus_code, 'city', v_e.campus_city),
    'letterhead_storage_path',
      (public.resolve_branding(v_e.campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path',
      (public.resolve_branding(v_e.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'values', v_values
  );

  insert into public.certificate_issue (
    tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
    serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_by
  ) values (
    v_e.tenant_id, v_e.campus_id, v_e.student_id, p_enrolment_id, v_e.session_id, 'transfer',
    v_serial, v_template.id, v_template.version, v_template.language, v_pdf_path, v_snapshot, v_uid
  )
  returning id into v_issue_id;

  -- AC1. left_on is the whole roster mechanism; status is what takes the
  -- student off every "current roster" and out of FR-A06's rollover scan.
  update public.enrolment
     set status = 'transferred',
         left_on = p_leaving_date,
         tc_issued_at = clock_timestamp(),
         tc_certificate_issue_id = v_issue_id
   where id = p_enrolment_id;

  return jsonb_build_object(
    'issue_id',         v_issue_id,
    'serial_no',        v_serial,
    'pdf_path',         v_pdf_path,
    'certificate_type', 'transfer',
    'status',           'issued',
    'template_id',      v_template.id,
    'template_version', v_template.version,
    'language',         v_template.language,
    'payload_snapshot', v_snapshot
  );
end;
$$;

revoke execute on function public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language
) from public, anon;
grant execute on function public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language
) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The failure path: the document never came into existence
-- ═══════════════════════════════════════════════════════════════════════

-- Called by the issuing action when the render or the upload fails. The
-- serial is NOT handed back — T02 forbids rewinding the counter, and a
-- rewound number is a number that eventually gets printed twice. The row
-- stays in the register carrying its serial and saying why, which is the
-- opposite of the hole the user story is about; the enrolment goes back to
-- where it was, because the child was never actually transferred.
create or replace function public.void_certificate_issue(p_issue_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_issue     public.certificate_issue%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_issue from public.certificate_issue
   where id = p_issue_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'CERTIFICATE_ISSUE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_issue.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_issue.status <> 'issued' then
    raise exception 'CERTIFICATE_NOT_ISSUED'
      using errcode = '55000', detail = format('status=%s', v_issue.status);
  end if;

  update public.certificate_issue
     set status = 'void',
         revoked_at = clock_timestamp(),
         revoke_reason = p_reason
   where id = p_issue_id;

  if v_issue.certificate_type = 'transfer' and v_issue.enrolment_id is not null then
    update public.enrolment
       set status = 'active',
           left_on = null,
           tc_issued_at = null,
           tc_certificate_issue_id = null
     where id = v_issue.enrolment_id
       and tc_certificate_issue_id = p_issue_id;
  end if;

  return jsonb_build_object('issue_id', p_issue_id, 'serial_no', v_issue.serial_no, 'status', 'void');
end;
$$;

revoke execute on function public.void_certificate_issue(uuid, text) from public, anon;
grant execute on function public.void_certificate_issue(uuid, text) to authenticated;
