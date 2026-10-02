-- FR-A20: system-wide search.
--
-- One box that finds a student by GR number, name (English or Urdu),
-- B-Form, parent CNIC or phone, a staff member, or a fee challan.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Why this is NOT the materialised search_index the FR names
-- ═══════════════════════════════════════════════════════════════════════
--
-- The FR's Supabase Objects call for a materialised `search_index` fed by
-- per-table triggers with a nightly `reindex_search` cron "as a
-- consistency backstop". That shape is rejected here, deliberately, on
-- authorization grounds — not performance ones.
--
-- A denormalised index row has to carry a *copy* of the access rule that
-- governs the record it points at. In this schema that copy is wrong the
-- moment any of the following happens, and stays wrong until the next
-- refresh:
--
--   * Soft delete (FR-A15). student/enrolment/fee_challan carry
--     deleted_at, and every SELECT policy on them was rewritten to add
--     "and deleted_at is null". A deleted student's index row keeps
--     pointing at them until a trigger fires; miss the trigger on any of
--     the several definer functions that write deleted_at and the record
--     is searchable after deletion.
--   * Guardian campus scope is DERIVED, not stored. public.guardian has
--     no campus_id at all — guardian_read_if_linked_child_in_scope
--     resolves it through student_guardian → student.campus_id. So a
--     guardian's visibility changes when a CHILD transfers campus, an
--     event that touches neither the guardian row nor any trigger you
--     would think to put on it. A denormalised guardian row is stale by
--     construction.
--   * Impersonation (FR-A16). app.auth_tenant_id() now also asserts the
--     impersonation session is live. A materialised view refreshed by a
--     postgres-owned definer has no caller to assert anything about.
--
-- The nightly cron the FR proposes is precisely the admission that the
-- window exists: "eventually consistent" is an acceptable property for a
-- relevance ranking and an unacceptable one for an access decision. A
-- stale ranking shows a slightly-off result order; a stale ACL shows a
-- name, a father's name and a GR number to somebody who was revoked.
--
-- So: global_search() is SECURITY INVOKER and reads the base tables. RLS
-- does the authorization, once, in the same policies every other read
-- path in this app already goes through. There is no second copy of the
-- access rules to drift, no propagation window, and a future FR that
-- tightens a policy tightens search in the same commit — automatically.
-- FR-K24's cross-tenant money bug came from a definer that forgot one
-- predicate; the way to not repeat it is to not re-state the predicates.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 2. What RLS does NOT do for us: the recycle bin
-- ═══════════════════════════════════════════════════════════════════════
--
-- One thing inheriting RLS does not buy, and the pgTAP suite catches it:
-- soft-deleted rows. student has THREE permissive SELECT policies, and
-- permissive policies OR together —
--
--   student_campus_scope      … and deleted_at is null
--   student_parent_read_own…  … and deleted_at is null
--   student_recycle_bin_read  … and deleted_at IS NOT NULL   ← owner/super_admin
--
-- so for an Owner the union is "every row in the tenant, deleted or not".
-- That is correct for RLS — an Owner IS allowed to see the recycle bin —
-- and wrong for a search box, which is not the recycle bin. Hence the
-- explicit `deleted_at is null` on the student and fee_challan branches
-- below. Note what it is and is not: a SCOPE filter, not an ACL. Getting
-- it wrong shows an Owner their own deleted record, not somebody else's
-- live one.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 3. Why identifier lookups get an index and fuzzy names cannot
-- ═══════════════════════════════════════════════════════════════════════
--
-- AC5 asks for no sequential scan on student. Under RLS that is
-- achievable for exact-identifier lookups and provably NOT achievable for
-- trigram name matching. The reason is qual ordering:
--
--   Postgres will not evaluate a non-LEAKPROOF qual before a row-security
--   qual, because a non-leakproof function could reveal the contents of a
--   row the caller is not allowed to see (via an error message, say).
--   Security quals therefore run first, and any non-leakproof user qual
--   degrades to a post-filter — i.e. a sequential scan.
--
-- Measured on this schema (5,000 students, ANALYZEd):
--
--   pg_proc.proleakproof
--     texteq                          t     ← plain column = value
--     regexp_replace                  f     ← app.digits(gr_number) = value
--     word_similarity_op        (<%)  f
--     word_similarity_commutator_op (%>) f
--
--   query                                    no RLS          under RLS
--   ------------------------------------------------------------------
--   app.digits(gr_number) = '000077'         Index Scan      Seq Scan
--   gr_digits = '000077'  (stored column)    Index Scan      Index Scan
--   name_en %> 'ahmad'                       Bitmap Index    Seq Scan
--
-- Two consequences, and this is what drives the design below:
--
--   (a) The FR's "normalise into a digits-only column at write time" is
--       not merely a CPU optimisation, it is what makes the lookup
--       indexable AT ALL under RLS. An expression index on
--       app.digits(gr_number) is unusable here because regexp_replace is
--       not leakproof; a STORED generated column compared with plain
--       texteq is usable, because texteq is. So: generated columns, as
--       the FR asked, for the reason the FR did not give.
--
--   (b) No arrangement of pg_trgm operators can be index-driven under
--       RLS — both directions are non-leakproof, so `<%` and `%>` are
--       equally unusable. The fuzzy-name branch sequential-scans, and
--       AC5's letter cannot be met for it without abandoning RLS (a
--       SECURITY DEFINER re-stating every predicate, i.e. the FR-K24
--       shape) or marking extension functions LEAKPROOF (superuser-only,
--       and untrue). We keep RLS and take the scan.
--
--       AC5's *intent* still holds: a scan of 5,000 rows is single-digit
--       milliseconds, far inside the 500 ms p95 budget, and the branch is
--       LIMITed so it never materialises more than limit+1 rows. What is
--       NOT verified locally is the p95 itself at real concurrency.
--
--       The branch is nonetheless written in the OPERATOR form
--       (`name_en %> q`) rather than FR-D19's function form
--       (`word_similarity(q, name_en) > 0.3`), because only the operator
--       is indexable at all — verified with enable_seqscan = off:
--
--         name_en %> q                     Bitmap Index Scan
--         q <% name_en                     Bitmap Index Scan  (commuted)
--         word_similarity(q, name_en) > x  Seq Scan  ← never indexable
--
--       Operand order does not matter: <% and %> are commutators and the
--       planner swaps them freely to match the index. The function form
--       is the one that permanently forfeits the index, so that is the
--       rewrite the pgTAP suite guards against.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 4. Why the UNION here is not the query that kills the database
-- ═══════════════════════════════════════════════════════════════════════
--
-- The FR's Notes reject "a UNION of LIKE queries across five tables". The
-- thing that kills the database there is LIKE '%foo%' — unanchored,
-- unindexable, and evaluated against every row of every branch with no
-- bound on the intermediate result.
--
-- Here: identifier branches are indexed equality (§3a); name branches are
-- trigram-bounded and, crucially, EVERY branch carries its own
-- `limit p_limit + 1`, so the union materialises at most 6 * (limit+1)
-- rows before ranking no matter how large the tenant is. A LIKE union has
-- no such ceiling — that is the actual difference.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 5. Urdu: romanise, don't stem
-- ═══════════════════════════════════════════════════════════════════════
--
-- to_tsvector('english', 'احمد رضا') mangles Urdu: the English snowball
-- stemmer has no rules for Arabic script, and 'simple' would only ever
-- give exact-token equality — useless against a front desk that types
-- Latin. The FR is right that trigrams beat stemming here, but plain
-- trigrams do not solve the actual AC: 'ahmad' and 'احمد' share ZERO
-- trigrams, because they share zero characters.
--
-- app.roman_ur() bridges the scripts by transliterating the Urdu column
-- into Latin at write time, so both sides of the comparison live in one
-- alphabet and pg_trgm's fuzziness does the rest. Urdu is an abjad —
-- short vowels are not written — so 'احمد' romanises to 'ahmd', and
-- trigram tolerance is what absorbs the missing vowel. Measured:
--
--     word_similarity('ahmad', 'ahmd')  = 0.5   ← the AC2 Urdu case
--     word_similarity('ahmad', 'ahmed') = 0.5   ← the AC2 spelling case
--
-- Both clear a 0.3 threshold, which is why the threshold is 0.3 and not
-- FR-D19's 0.4 — pg_trgm's DEFAULT is 0.6, at which both of those fail
-- and AC2 fails with them.
--
-- Limits, stated plainly rather than discovered later:
--   * This is a transliteration approximation, not a phonetic engine. It
--     has no dictionary, so it cannot know that 'Mohammed' and 'محمد' are
--     the same name by meaning — it gets there by shape ('mhmd'), and
--     where shape diverges it will miss.
--   * ع, ء and the harakat are dropped; ش/چ/خ/غ are the only digraphs
--     handled. Retroflexes collapse onto their dental partners (ٹ→t),
--     which is the desired fuzziness for a search box and would be wrong
--     for anything else. Never reuse this for display.
--   * A query typed IN Urdu matches the Urdu columns directly (it
--     romanises the same way on both sides), so Urdu-in/Urdu-out works.
--     Urdu-in against an English-only record does not, and cannot,
--     without a dictionary.
--   * The romanised columns are GENERATED ... STORED, so a future change
--     to app.roman_ur() does NOT recompute existing rows — such a change
--     must rewrite the columns in the same migration. This is real drift,
--     but it is drift in RELEVANCE, not in authorization, which is
--     exactly the distinction §1 rejects the materialised index over.

-- ── normalisation primitives (immutable: they back generated columns) ───

create or replace function app.digits(p_text text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(coalesce(p_text, ''), '[^0-9]', '', 'g');
$$;

comment on function app.digits(text) is
  'FR-A20: strips a CNIC/B-Form/GR/phone to bare digits so 35202-1234567-1 and 3520212345671 are one value.';

create or replace function app.roman_ur(p_text text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(
           translate(
             replace(replace(replace(replace(
               lower(coalesce(p_text, '')),
               'ش', 'sh'), 'چ', 'ch'), 'خ', 'kh'), 'غ', 'gh'),
             'اآأإبپتثجحدذرزژسصضطظعفقکكگلمنوہهةیيئےۓٹڈڑھںؤۂ',
             'aaaabptsjhdzrzzssztzafqkkglmnwhhhyyyeetdrhnwh'),
           '[^a-z0-9 ]', '', 'g');
$$;

comment on function app.roman_ur(text) is
  'FR-A20: transliterates Urdu (Arabic script) to approximate Latin so a Latin query and an Urdu name can share trigrams. Lossy by design; search only, never display.';

-- ── stored normalisation + indexes ─────────────────────────────────────
--
-- tenant_id leads every btree because every RLS policy on these tables
-- opens with tenant_id = app.auth_tenant_id(), so the planner gets the
-- tenant restriction and the identifier equality from one scan.

alter table public.student
  add column gr_digits     text generated always as (app.digits(gr_number)) stored,
  add column bform_digits  text generated always as (app.digits(b_form_no)) stored,
  add column name_ur_roman text generated always as (app.roman_ur(name_ur)) stored;

create index idx_student_gr_digits on public.student (tenant_id, gr_digits);
create index idx_student_bform_digits on public.student (tenant_id, bform_digits)
  where b_form_no is not null;
create index idx_student_name_ur_roman_trgm on public.student
  using gin (name_ur_roman gin_trgm_ops);
-- idx_student_name_trgm (gin on name_en) already exists from 20260730121905.

-- Phone is stored as the last 10 digits so 03001234567 and +923001234567
-- are one value: Pakistani mobile numbers are 10 significant digits after
-- the country code or the trunk 0.
alter table public.guardian
  add column cnic_digits     text generated always as (app.digits(cnic)) stored,
  add column phone_last10    text generated always as (right(app.digits(phone_e164), 10)) stored,
  add column alt_phone_last10 text generated always as (right(app.digits(alt_phone), 10)) stored,
  add column name_ur_roman   text generated always as (app.roman_ur(name_ur)) stored;

create index idx_guardian_cnic_digits on public.guardian (tenant_id, cnic_digits)
  where cnic is not null;
create index idx_guardian_phone_last10 on public.guardian (tenant_id, phone_last10)
  where phone_e164 is not null;
create index idx_guardian_alt_phone_last10 on public.guardian (tenant_id, alt_phone_last10)
  where alt_phone is not null;
create index idx_guardian_name_trgm on public.guardian using gin (name_en gin_trgm_ops);
create index idx_guardian_name_ur_roman_trgm on public.guardian
  using gin (name_ur_roman gin_trgm_ops);

alter table public.staff
  add column name_ur_roman text generated always as (app.roman_ur(full_name_ur)) stored;

create index idx_staff_name_ur_roman_trgm on public.staff
  using gin (name_ur_roman gin_trgm_ops);
-- idx_staff_name_trgm (gin on full_name) already exists from 20260731720000.

alter table public.fee_challan
  add column challan_digits text generated always as (app.digits(challan_no)) stored;

create index idx_fee_challan_no on public.fee_challan (tenant_id, challan_no);
create index idx_fee_challan_digits on public.fee_challan (tenant_id, challan_digits);

-- ═══════════════════════════════════════════════════════════════════════
-- 6. global_search()
-- ═══════════════════════════════════════════════════════════════════════
--
-- SECURITY INVOKER. Every from-clause below is an RLS-protected table, so
-- tenant isolation, campus scope and the FR-A16 impersonation liveness
-- check are inherited rather than restated:
--
--   student   student_campus_scope        tenant + campus (+ recycle bin, see §2)
--   guardian  guardian_read_if_linked_..  tenant + campus VIA a live child
--   staff     staff_campus_scope          tenant + campus (or staff_campus, or self)
--   fee_..    fee_challan_campus_scope    tenant + campus (+ recycle bin, see §2)
--
-- The empty-claims trap does not apply: every campus predicate in those
-- policies is a POSITIVE `campus_id = any(app.auth_campus_ids())`, which
-- is false for every campus when the claim is '{}' — not the negated form
-- that silently opens up. A user with no campus grants and a non-owner
-- role gets zero rows, which is the correct answer.
--
-- The role gate below is an authorization *narrowing*, never a widening:
-- parents and students have RLS that would let them search their own
-- records, but a cross-entity staff search box is not their tool.

create or replace function public.global_search(p_q text, p_limit int default 20)
returns table (
  entity_type   text,
  entity_id     uuid,
  campus_id     uuid,
  display_label text,
  subtitle      text,
  match_field   text,
  href          text,
  rank          real,
  truncated     boolean
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_q       text := nullif(trim(p_q), '');
  v_roman   text;
  v_digits  text;
  v_limit   int  := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_is_id   boolean;
begin
  if app.auth_role() in ('none', 'parent', 'student') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- The `%>` operator reads its cutoff from pg_trgm.word_similarity_threshold,
  -- whose default (0.6) is too tight for AC2 — Ahmad/Ahmed scores 0.5.
  --
  -- Set here in the body rather than as a CREATE FUNCTION `SET` clause,
  -- which is what it wants to be: that form is rejected with "permission
  -- denied to set parameter" for any role that is not superuser, so it
  -- happens to apply under `supabase db reset` (migrations run as
  -- supabase_admin) and would then fail on a hosted deploy, where they
  -- run as postgres. set_config() has no such restriction. `true` scopes
  -- it to the current transaction, i.e. to one PostgREST request.
  perform set_config('pg_trgm.word_similarity_threshold', '0.3', true);

  -- A one-character query trigram-matches most of the school.
  if v_q is null or length(v_q) < 2 then
    return;
  end if;

  -- The query is normalised exactly the way the stored columns are, so an
  -- Urdu query lands in the same alphabet as an English one and a dashed
  -- CNIC lands on the same digits as a bare one.
  v_roman  := app.roman_ur(v_q);
  v_digits := app.digits(v_q);

  -- A query with no letters in it (a GR suffix, a CNIC, a phone, a challan
  -- number) cannot fuzzy-match a name: names carry no digits, so every
  -- word_similarity below would score ~0, far under the 0.3 threshold. So
  -- the fuzzy branches are SKIPPED for identifier queries. This changes no
  -- result — it removes work that provably finds nothing — and it matters
  -- because the fuzzy branches are the only ones that scan (see §3), while
  -- identifier lookups are index-backed. It is also the shape the user
  -- story describes: a parent at the desk reciting a GR number or a CNIC.
  v_is_id := v_q ~ '^[0-9][0-9[:space:]()+-]*$';

  return query
  with hits as (
    -- ── students: GR / B-Form (exact, tier 0) ─────────────────────────
    --
    -- gr_sequence is per CAMPUS, so 'MAIN-000001' and 'DHA-000001' share
    -- the digit string '000001' — a digits-only query is genuinely
    -- ambiguous across campuses, and returning both is the honest answer.
    -- Typing the whole GR disambiguates, so a full-string match scores
    -- above a digits-only one rather than tying with it.
    (select 'student'::text as entity_type,
            s.id            as entity_id,
            s.campus_id     as campus_id,
            s.name_en       as display_label,
            format('GR %s%s', s.gr_number,
                   case when s.father_name_en is null then '' else ' · c/o ' || s.father_name_en end) as subtitle,
            case when s.gr_digits = v_digits then 'gr_number' else 'b_form_no' end as match_field,
            '/students/' || s.id::text as href,
            0::smallint     as tier,
            case when upper(s.gr_number) = upper(v_q) then 1.0 else 0.9 end::real as score
       from public.student s
      where s.deleted_at is null
        and length(v_digits) >= 3
        and (s.gr_digits = v_digits
             or (s.b_form_no is not null and s.bform_digits = v_digits))
      order by 9 desc
      limit v_limit + 1)

    union all

    -- ── students: name, English or Urdu (fuzzy, tier 1) ────────────────
    (select 'student'::text,
            s.id,
            s.campus_id,
            s.name_en,
            format('GR %s%s', s.gr_number,
                   case when s.father_name_en is null then '' else ' · c/o ' || s.father_name_en end),
            case when s.name_en operator(public.%>) v_q then 'name_en' else 'name_ur' end,
            '/students/' || s.id::text,
            1::smallint,
            greatest(
              public.word_similarity(v_q, s.name_en),
              public.word_similarity(v_roman, s.name_ur_roman)
            )::real
       from public.student s
      where not v_is_id
        and s.deleted_at is null
        and (s.name_en operator(public.%>) v_q
             or (s.name_ur is not null and s.name_ur_roman operator(public.%>) v_roman))
      order by 9 desc
      limit v_limit + 1)

    union all

    -- ── guardians: CNIC / phone (exact, tier 0) ────────────────────────
    --
    -- Phone matches on the last 10 digits, so a 10-digit number is the
    -- minimum that can match. A shorter fragment would need a suffix
    -- LIKE, i.e. the unindexable branch this whole design exists to avoid.
    (select 'guardian'::text,
            g.id,
            child.campus_id,
            g.name_en,
            format('%s%s', coalesce(g.phone_e164, g.cnic, '—'),
                   case when child.name_en is null then '' else ' · guardian of ' || child.name_en end),
            case when g.cnic is not null and g.cnic_digits = v_digits then 'cnic' else 'phone' end,
            case when child.id is null then null else '/students/' || child.id::text end,
            0::smallint,
            1.0::real
       from public.guardian g
       left join lateral (
         select s.id, s.name_en, s.campus_id
           from public.student_guardian sg
           join public.student s on s.id = sg.student_id
          where sg.guardian_id = g.id and sg.to_date is null and s.deleted_at is null
          order by sg.is_primary desc, s.name_en
          limit 1
       ) child on true
      where length(v_digits) >= 10
        and ((g.cnic is not null and g.cnic_digits = v_digits)
             or (g.phone_e164 is not null and g.phone_last10 = right(v_digits, 10))
             or (g.alt_phone is not null and g.alt_phone_last10 = right(v_digits, 10)))
      limit v_limit + 1)

    union all

    -- ── guardians: name (fuzzy, tier 1) ────────────────────────────────
    (select 'guardian'::text,
            g.id,
            child.campus_id,
            g.name_en,
            format('%s%s', coalesce(g.phone_e164, '—'),
                   case when child.name_en is null then '' else ' · guardian of ' || child.name_en end),
            case when g.name_en operator(public.%>) v_q then 'name_en' else 'name_ur' end,
            case when child.id is null then null else '/students/' || child.id::text end,
            1::smallint,
            greatest(
              public.word_similarity(v_q, g.name_en),
              public.word_similarity(v_roman, g.name_ur_roman)
            )::real
       from public.guardian g
       left join lateral (
         select s.id, s.name_en, s.campus_id
           from public.student_guardian sg
           join public.student s on s.id = sg.student_id
          where sg.guardian_id = g.id and sg.to_date is null and s.deleted_at is null
          order by sg.is_primary desc, s.name_en
          limit 1
       ) child on true
      where not v_is_id
        and (g.name_en operator(public.%>) v_q
             or (g.name_ur is not null and g.name_ur_roman operator(public.%>) v_roman))
      order by 9 desc
      limit v_limit + 1)

    union all

    -- ── staff: employee code (exact) or name (fuzzy) ───────────────────
    (select 'staff'::text,
            st.id,
            st.campus_id,
            st.full_name,
            format('%s%s', st.employee_code,
                   case when st.employment_status = 'exited' then ' · former' else '' end),
            case when upper(st.employee_code) = upper(v_q) then 'employee_code'
                 when st.full_name operator(public.%>) v_q then 'full_name'
                 else 'full_name_ur' end,
            '/staff/directory',
            case when upper(st.employee_code) = upper(v_q) then 0 else 1 end::smallint,
            case when upper(st.employee_code) = upper(v_q) then 1.0
                 else greatest(
                   public.word_similarity(v_q, st.full_name),
                   public.word_similarity(v_roman, st.name_ur_roman)
                 ) end::real
       from public.staff st
      where upper(st.employee_code) = upper(v_q)
         or (not v_is_id
             and (st.full_name operator(public.%>) v_q
                  or (st.full_name_ur is not null and st.name_ur_roman operator(public.%>) v_roman)))
      order by 8, 9 desc
      limit v_limit + 1)

    union all

    -- ── fee challans: challan number (exact, tier 0) ───────────────────
    (select 'fee_challan'::text,
            fc.id,
            fc.campus_id,
            fc.challan_no,
            format('%s · Rs %s · %s', s.name_en, (fc.net_paisa / 100)::text, fc.status::text),
            'challan_no'::text,
            '/fees/challans',
            0::smallint,
            1.0::real
       from public.fee_challan fc
       join public.enrolment e on e.id = fc.enrolment_id
       join public.student s on s.id = e.student_id
      where fc.deleted_at is null
        and (fc.challan_no = v_q
             or (length(v_digits) >= 3 and fc.challan_digits = v_digits))
      limit v_limit + 1)
  ),
  -- One row per entity: a student matched on both GR and name keeps the
  -- better (lower) tier rather than appearing twice.
  deduped as (
    select distinct on (h.entity_type, h.entity_id) h.*
      from hits h
     order by h.entity_type, h.entity_id, h.tier, h.score desc
  ),
  -- limit+1 is fetched so `truncated` can be told from a full page
  -- without a second count over the whole tenant.
  windowed as (
    select d.*, count(*) over () as total
      from (select * from deduped
             order by tier, score desc, display_label
             limit v_limit + 1) d
  )
  select w.entity_type,
         w.entity_id,
         w.campus_id,
         w.display_label,
         w.subtitle,
         w.match_field,
         w.href,
         w.score,
         (w.total > v_limit) as truncated
    from windowed w
   order by w.tier, w.score desc, w.display_label
   limit v_limit;
end;
$$;

comment on function public.global_search(text, int) is
  'FR-A20: cross-entity search over students, guardians, staff and fee challans. SECURITY INVOKER — RLS is the only authorization gate; see the migration header for why this is not a materialised index.';

revoke execute on function public.global_search(text, int) from public, anon;
grant execute on function public.global_search(text, int) to authenticated;
