-- FR-I07: Set A and Set B paper versions.
--
-- Two sets are only an anti-cheating measure if they are the SAME exam in
-- different words, and only if the seating plan alternates them (FR-I09 does:
-- the set code belongs to the seat). So:
--
--   * a set is an exam_paper with a set_code, and one exam subject has at most
--     one live paper per code (uq_paper_set), so Set B can never silently replace
--     Set A, nor Set A's key be filed under Set B;
--   * build_paper_sets() assembles the sets from the question bank against the
--     board pattern: every set has the same marks per section and the same number
--     of questions per (section, chapter); set B+ draw on questions the earlier
--     sets did NOT use, and share at most max_identical (2, and never more than
--     half) of any group with them. If the bank cannot supply that it fails with
--     insufficient_pool: <chapter> <type> instead of emitting near-duplicates;
--   * a worker-generated multi-set paper (FR-I05) gets the same two checks at
--     ingest: identical per-(section, chapter) counts across sets, and no more
--     than two identical questions in a group;
--   * fn_paper_set_divergence() is the share of one set's questions that also
--     appear in another (0 = fully different, 1 = the same paper);
--   * the paper and its answer key live at a path that carries the set code,
--     {tenant}/{exam_subject}/set-{code}.pdf and .../key-{code}.pdf, derived by the
--     database from the paper row: nobody types a path, so a Set B paper cannot be
--     filed with the Set A key.
-- "Usable" bank questions exclude those this class has seen within the reuse
-- cooldown (FR-I06).

create unique index uq_paper_set on public.exam_paper (exam_subject_id, set_code) where status <> 'superseded';

-- ═══════════════════════════════════════════════════════════════════════
-- Divergence
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.fn_paper_set_divergence(p_paper_a uuid, p_paper_b uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_total int;
  v_same  int;
begin
  if app.auth_role() in ('parent', 'student', 'none') or not app.fn_can_see_paper(p_paper_a) or not app.fn_can_see_paper(p_paper_b) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select count(*)::int,
         count(*) filter (where exists (select 1 from public.exam_paper_item ia
                                         where ia.paper_id = p_paper_a and app.fn_question_hash(ia.question_text) = app.fn_question_hash(ib.question_text)))::int
    into v_total, v_same
    from public.exam_paper_item ib where ib.paper_id = p_paper_b;
  if v_total = 0 then
    return 0;
  end if;
  return round(v_same::numeric / v_total, 4);
end;
$$;
revoke execute on function public.fn_paper_set_divergence(uuid, uuid) from public, anon;
grant execute on function public.fn_paper_set_divergence(uuid, uuid) to authenticated;

-- Per (section, chapter): how many questions each set has and how many of B's
-- also appear in A.
create or replace function public.fn_paper_set_report(p_paper_a uuid, p_paper_b uuid)
returns table (section_no int, chapter text, question_type text, count_a int, count_b int, identical int, marks_a int, marks_b int)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() in ('parent', 'student', 'none') or not app.fn_can_see_paper(p_paper_a) or not app.fn_can_see_paper(p_paper_b) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select g.section_no, g.chapter, g.question_type,
           (select count(*)::int from public.exam_paper_item a where a.paper_id = p_paper_a and a.section_no = g.section_no and a.chapter is not distinct from g.chapter),
           (select count(*)::int from public.exam_paper_item b where b.paper_id = p_paper_b and b.section_no = g.section_no and b.chapter is not distinct from g.chapter),
           (select count(*)::int from public.exam_paper_item b where b.paper_id = p_paper_b and b.section_no = g.section_no and b.chapter is not distinct from g.chapter
               and exists (select 1 from public.exam_paper_item a where a.paper_id = p_paper_a and app.fn_question_hash(a.question_text) = app.fn_question_hash(b.question_text))),
           (select coalesce(sum(a.marks), 0)::int from public.exam_paper_item a where a.paper_id = p_paper_a and a.section_no = g.section_no),
           (select coalesce(sum(b.marks), 0)::int from public.exam_paper_item b where b.paper_id = p_paper_b and b.section_no = g.section_no)
      from (select i.section_no, i.chapter, min(i.question_type) as question_type
              from public.exam_paper_item i where i.paper_id in (p_paper_a, p_paper_b) group by i.section_no, i.chapter) g
     order by g.section_no, g.chapter;
end;
$$;
revoke execute on function public.fn_paper_set_report(uuid, uuid) from public, anon;
grant execute on function public.fn_paper_set_report(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Build sets from the bank
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_type_label(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$ select case p_type when 'mcq' then 'MCQ' when 'short' then 'Short' when 'long' then 'Long' else p_type end; $$;

-- p_cells: [{"section_no":1,"chapter":"Ch.2","count":12}, ...]; omitted, the
-- pattern's counts are spread evenly over p_chapters. Returns the set papers
-- (drafts) in set order.
create or replace function public.build_paper_sets(
  p_exam_subject_id uuid, p_board_pattern_id uuid, p_chapters text[] default null, p_cells jsonb default null,
  p_set_count int default 2, p_max_identical int default 2, p_replace boolean default false
)
returns uuid[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_es       public.exam_subject%rowtype;
  v_cs       public.class_subject%rowtype;
  v_pattern  public.board_pattern_ref%rowtype;
  v_cells    jsonb := '[]'::jsonb;
  v_cell     jsonb;
  s          jsonb;
  v_n        int;
  v_len      int;
  v_i        int;
  v_sum      int;
  v_cooldown int;
  v_rank     int;
  v_term     uuid;
  v_job      uuid;
  v_papers   uuid[] := '{}';
  v_paper    uuid;
  v_k        int;
  v_pool     uuid[];
  v_fresh    uuid[];
  v_used     jsonb := '{}'::jsonb;
  v_picked   uuid[];
  v_key      text;
  v_prev     uuid[];
  v_need     int;
  v_allowed  int;
  v_picks    jsonb := '{}'::jsonb;
  v_qno      int;
  v_item     uuid;
  v_type     text;
  v_marks    int;
begin
  select * into v_es from public.exam_subject where id = p_exam_subject_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_can_request_paper(p_exam_subject_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_cs from public.class_subject where id = v_es.class_subject_id;
  select * into v_pattern from public.board_pattern_ref where id = p_board_pattern_id and tenant_id = v_es.tenant_id and is_active;
  if not found then
    raise exception 'PATTERN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_set_count is null or p_set_count not between 1 and 4 then
    raise exception 'SET_COUNT_INVALID' using errcode = '22023';
  end if;
  if p_max_identical is null or p_max_identical < 0 then
    raise exception 'MAX_IDENTICAL_INVALID' using errcode = '22023';
  end if;

  -- The (section, chapter) blueprint every set follows.
  if p_cells is not null and jsonb_typeof(p_cells) = 'array' and jsonb_array_length(p_cells) > 0 then
    v_cells := p_cells;
  else
    if p_chapters is null or cardinality(p_chapters) = 0 then
      raise exception 'CHAPTERS_REQUIRED' using errcode = '22023';
    end if;
    v_len := cardinality(p_chapters);
    for s in select * from jsonb_array_elements(v_pattern.sections) loop
      v_n := (s ->> 'count')::int;
      for v_i in 1..v_len loop
        if v_n / v_len + (case when v_i <= v_n % v_len then 1 else 0 end) > 0 then
          v_cells := v_cells || jsonb_build_array(jsonb_build_object('section_no', (s ->> 'no')::int, 'chapter', p_chapters[v_i], 'count', v_n / v_len + (case when v_i <= v_n % v_len then 1 else 0 end)));
        end if;
      end loop;
    end loop;
  end if;
  for s in select * from jsonb_array_elements(v_pattern.sections) loop
    select coalesce(sum((c ->> 'count')::int), 0) into v_sum from jsonb_array_elements(v_cells) c where (c ->> 'section_no')::int = (s ->> 'no')::int;
    if v_sum <> (s ->> 'count')::int then
      raise exception 'CELLS_MISMATCH' using errcode = '22023', detail = format('section %s needs %s questions, the chapter plan gives %s', s ->> 'no', s ->> 'count', v_sum);
    end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(v_cells) c where not exists (select 1 from jsonb_array_elements(v_pattern.sections) x where (x ->> 'no')::int = (c ->> 'section_no')::int)) then
    raise exception 'CELLS_MISMATCH' using errcode = '22023', detail = 'the chapter plan names a section that is not in the pattern';
  end if;

  -- Existing live papers for these set codes.
  if exists (select 1 from public.exam_paper where exam_subject_id = p_exam_subject_id and status = 'published') then
    raise exception 'PAPER_PUBLISHED' using errcode = '22023';
  end if;
  if exists (select 1 from public.exam_paper where exam_subject_id = p_exam_subject_id and status = 'draft') then
    if not coalesce(p_replace, false) then
      raise exception 'PAPER_SET_EXISTS' using errcode = '23505';
    end if;
    update public.exam_paper set status = 'superseded' where exam_subject_id = p_exam_subject_id and status = 'draft';
  end if;

  v_term := v_es.exam_term_id;
  v_rank := app.fn_exam_term_rank(v_term);
  v_cooldown := coalesce((select x.question_cooldown_terms from public.exam_settings x where x.campus_id = v_es.campus_id), 4);

  -- Pick, set by set, cell by cell.
  for v_k in 1..p_set_count loop
    for v_i in 0..jsonb_array_length(v_cells) - 1 loop
      v_cell := v_cells -> v_i;
      select * into s from jsonb_array_elements(v_pattern.sections) x where (x ->> 'no')::int = (v_cell ->> 'section_no')::int;
      v_need := (v_cell ->> 'count')::int;
      v_key := (v_cell ->> 'section_no') || '|' || (v_cell ->> 'chapter');
      select coalesce(array_agg(b.id order by md5(b.id::text || p_exam_subject_id::text)), '{}') into v_pool
        from public.question_bank_item b
       where b.tenant_id = v_es.tenant_id and b.subject_id = v_cs.subject_id and b.class_level_id = v_cs.class_level_id and b.is_active
         and b.chapter = (v_cell ->> 'chapter') and b.question_type = (s ->> 'type') and b.marks = (s ->> 'marks_each')::int
         and not exists (
           select 1 from public.question_usage u join public.exam_paper up on up.id = u.exam_paper_id
            where u.question_id = b.id and u.class_level_id = v_cs.class_level_id and up.exam_subject_id <> p_exam_subject_id
              and v_rank - app.fn_exam_term_rank(u.exam_term_id) between 1 and v_cooldown);
      v_prev := coalesce(array(select jsonb_array_elements_text(v_used -> v_key))::uuid[], '{}');
      select coalesce(array_agg(x), '{}') into v_fresh from unnest(v_pool) x where not (x = any (v_prev));
      if v_k = 1 then
        if cardinality(v_pool) < v_need then
          raise exception 'insufficient_pool: % %', v_cell ->> 'chapter', app.fn_type_label(s ->> 'type') using errcode = '22023',
            detail = format('%s questions are needed per set across %s set(s); only %s usable in the bank', v_need, p_set_count, cardinality(v_pool));
        end if;
        v_picked := v_pool[1:v_need];
      elsif cardinality(v_fresh) >= v_need then
        v_picked := v_fresh[1:v_need];
      else
        v_allowed := least(p_max_identical, v_need / 2);
        if v_need - cardinality(v_fresh) > v_allowed then
          raise exception 'insufficient_pool: % %', v_cell ->> 'chapter', app.fn_type_label(s ->> 'type') using errcode = '22023',
            detail = format('%s questions are needed per set across %s set(s) with at most %s shared; only %s usable in the bank', v_need, p_set_count, v_allowed, cardinality(v_pool));
        end if;
        v_picked := v_fresh || (select coalesce(array_agg(x), '{}') from (select x from unnest(v_pool) x where x = any (v_prev) limit v_need - cardinality(v_fresh)) q);
      end if;
      v_picks := jsonb_set(v_picks, array[v_k::text || '|' || v_key], to_jsonb(v_picked), true);
      v_used := jsonb_set(v_used, array[v_key], coalesce(v_used -> v_key, '[]'::jsonb) || to_jsonb(v_picked), true);
    end loop;
  end loop;

  insert into public.paper_generation_job (tenant_id, campus_id, requested_by, exam_subject_id, board_pattern_id, pattern_snapshot, chapters, total_marks, set_count, status, attempts, finished_at)
  values (v_es.tenant_id, v_es.campus_id, (select auth.uid()), p_exam_subject_id, p_board_pattern_id,
          jsonb_build_object('code', v_pattern.code, 'board', v_pattern.board, 'total_marks', v_pattern.total_marks, 'sections', v_pattern.sections, 'source', 'bank'),
          coalesce(p_chapters, array(select distinct c ->> 'chapter' from jsonb_array_elements(v_cells) c order by 1)), v_pattern.total_marks, p_set_count, 'completed', 1, now())
  returning id into v_job;

  for v_k in 1..p_set_count loop
    insert into public.exam_paper (tenant_id, campus_id, job_id, exam_subject_id, set_code, title, total_marks, pattern_snapshot, created_by)
    values (v_es.tenant_id, v_es.campus_id, v_job, p_exam_subject_id, chr(64 + v_k), format('%s paper', v_pattern.code), v_pattern.total_marks,
            jsonb_build_object('code', v_pattern.code, 'board', v_pattern.board, 'total_marks', v_pattern.total_marks, 'sections', v_pattern.sections), (select auth.uid()))
    returning id into v_paper;
    for s in select * from jsonb_array_elements(v_pattern.sections) order by (value ->> 'no')::int loop
      v_qno := 0;
      for v_i in 0..jsonb_array_length(v_cells) - 1 loop
        v_cell := v_cells -> v_i;
        continue when (v_cell ->> 'section_no')::int <> (s ->> 'no')::int;
        for v_item in select (jsonb_array_elements_text(v_picks -> (v_k::text || '|' || (v_cell ->> 'section_no') || '|' || (v_cell ->> 'chapter'))))::uuid loop
          v_qno := v_qno + 1;
          insert into public.exam_paper_item (tenant_id, paper_id, section_no, question_no, question_type, marks, question_text, options, answer, chapter, topic_tag, slo_code, bank_item_id)
          select v_es.tenant_id, v_paper, (s ->> 'no')::int, v_qno, b.question_type, b.marks, b.question_text, b.options, b.answer, b.chapter, b.topic_tag, b.slo_code, b.id
            from public.question_bank_item b where b.id = v_item;
        end loop;
      end loop;
    end loop;
    v_papers := v_papers || v_paper;
  end loop;

  insert into public.exam_paper_set_group (tenant_id, campus_id, exam_subject_id, set_count)
  values (v_es.tenant_id, v_es.campus_id, p_exam_subject_id, p_set_count)
  on conflict (exam_subject_id) do update set set_count = excluded.set_count, updated_at = now();
  return v_papers;
end;
$$;
revoke execute on function public.build_paper_sets(uuid, uuid, text[], jsonb, int, int, boolean) from public, anon;
grant execute on function public.build_paper_sets(uuid, uuid, text[], jsonb, int, int, boolean) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Worker-generated sets: the same two checks at ingest
-- ═══════════════════════════════════════════════════════════════════════

-- Set B must have the same number of questions per (section, chapter) as set A,
-- and share at most two (never more than half) of any group. null when fine.
create or replace function app.fn_set_blueprint_diff(p_a jsonb, p_b jsonb, p_set_b text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  g record;
begin
  for g in
    select coalesce(a.section_no, b.section_no) as section_no, coalesce(a.chapter, b.chapter) as chapter, coalesce(a.n, 0) as na, coalesce(b.n, 0) as nb
      from (select (q ->> 'section_no')::int as section_no, coalesce(q ->> 'chapter', '') as chapter, count(*) as n from jsonb_array_elements(p_a) q group by 1, 2) a
      full join (select (q ->> 'section_no')::int as section_no, coalesce(q ->> 'chapter', '') as chapter, count(*) as n from jsonb_array_elements(p_b) q group by 1, 2) b
        on a.section_no = b.section_no and a.chapter = b.chapter
  loop
    if g.na <> g.nb then
      return format('set %s has %s questions of %s in section %s, set A has %s', p_set_b, g.nb, coalesce(nullif(g.chapter, ''), 'no chapter'), g.section_no, g.na);
    end if;
    if (select count(*) from jsonb_array_elements(p_b) qb
         where (qb ->> 'section_no')::int = g.section_no and coalesce(qb ->> 'chapter', '') = g.chapter
           and exists (select 1 from jsonb_array_elements(p_a) qa where app.fn_question_hash(qa ->> 'text') = app.fn_question_hash(qb ->> 'text'))) > least(2, g.nb / 2) then
      return format('set %s repeats too many questions of set A in section %s, %s', p_set_b, g.section_no, coalesce(nullif(g.chapter, ''), 'no chapter'));
    end if;
  end loop;
  return null;
end;
$$;

-- fn_ingest_generated_paper() from FR-I05 with three additions: a multi-set
-- result must follow one blueprint and not be near-duplicate sets, drafts of the
-- same exam subject are superseded by a fresh generation, and a published paper
-- is never replaced by one.
create or replace function public.fn_ingest_generated_paper(p_job_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  j        public.paper_generation_job%rowtype;
  v_set    jsonb;
  v_first  jsonb;
  v_diff   text;
  v_ids    uuid[] := '{}';
  v_paper  uuid;
  v_codes  text[];
  q        jsonb;
  v_max_ratio numeric;
begin
  select * into j from public.paper_generation_job where id = p_job_id for update;
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if j.status <> 'running' and j.status <> 'queued' then
    return jsonb_build_object('status', j.status, 'paper_ids', coalesce((select jsonb_agg(id) from public.exam_paper where job_id = p_job_id), '[]'::jsonb), 'duplicate', true);
  end if;
  if p_payload is null or coalesce(jsonb_typeof(p_payload -> 'sets'), '') <> 'array' or jsonb_array_length(p_payload -> 'sets') <> j.set_count then
    update public.paper_generation_job set status = 'pattern_mismatch', last_error = format('expected %s set(s) in the callback', j.set_count), finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', format('expected %s set(s) in the callback', j.set_count));
  end if;

  select coalesce(max((x ->> 'verbatim_ratio')::numeric), 0) into v_max_ratio
    from jsonb_array_elements(p_payload -> 'sets') st, jsonb_array_elements(st -> 'questions') x;
  if v_max_ratio > 0.5 then
    update public.paper_generation_job set status = 'copyright_blocked', last_error = format('a question reproduces %s%% of its source text', round(v_max_ratio * 100)), finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'copyright_blocked', 'paper_ids', '[]'::jsonb, 'detail', 'a question reproduces the textbook beyond the allowed ratio');
  end if;

  select array_agg(st ->> 'set_code' order by st ->> 'set_code') into v_codes from jsonb_array_elements(p_payload -> 'sets') st;
  if v_codes <> (select array_agg(chr(64 + g)) from generate_series(1, j.set_count) g) then
    update public.paper_generation_job set status = 'pattern_mismatch', last_error = 'set codes must be A, B, ... in order', finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', 'set codes must be A, B, ... in order');
  end if;

  for v_set in select * from jsonb_array_elements(p_payload -> 'sets') loop
    v_diff := app.fn_paper_pattern_diff(j.pattern_snapshot, v_set -> 'questions');
    if v_diff is not null then
      update public.paper_generation_job set status = 'pattern_mismatch', last_error = left(format('set %s: %s', v_set ->> 'set_code', v_diff), 500), finished_at = now() where id = p_job_id;
      return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', format('set %s: %s', v_set ->> 'set_code', v_diff));
    end if;
  end loop;

  -- Sets of one paper follow one blueprint and are not near-duplicates.
  v_first := p_payload -> 'sets' -> 0;
  for v_set in select * from jsonb_array_elements(p_payload -> 'sets') offset 1 loop
    v_diff := app.fn_set_blueprint_diff(v_first -> 'questions', v_set -> 'questions', v_set ->> 'set_code');
    if v_diff is not null then
      update public.paper_generation_job set status = 'pattern_mismatch', last_error = left(v_diff, 500), finished_at = now() where id = p_job_id;
      return jsonb_build_object('status', 'pattern_mismatch', 'paper_ids', '[]'::jsonb, 'detail', v_diff);
    end if;
  end loop;

  -- A published paper is never replaced by a fresh generation.
  if exists (select 1 from public.exam_paper where exam_subject_id = j.exam_subject_id and status = 'published') then
    update public.paper_generation_job set status = 'failed', last_error = 'a published paper already exists for this exam subject', finished_at = now() where id = p_job_id;
    return jsonb_build_object('status', 'failed', 'paper_ids', '[]'::jsonb, 'detail', 'a published paper already exists for this exam subject');
  end if;
  update public.exam_paper set status = 'superseded' where exam_subject_id = j.exam_subject_id and status = 'draft';

  for v_set in select * from jsonb_array_elements(p_payload -> 'sets') loop
    insert into public.exam_paper (tenant_id, campus_id, job_id, exam_subject_id, set_code, title, total_marks, pattern_snapshot, created_by)
    values (j.tenant_id, j.campus_id, j.id, j.exam_subject_id, (v_set ->> 'set_code')::char(1),
            coalesce(nullif(btrim(v_set ->> 'title'), ''), format('%s paper', j.pattern_snapshot ->> 'code')), j.total_marks, j.pattern_snapshot, j.requested_by)
    returning id into v_paper;
    for q in select * from jsonb_array_elements(v_set -> 'questions') loop
      insert into public.exam_paper_item (tenant_id, paper_id, section_no, question_no, question_type, marks, question_text, options, answer, chapter, topic_tag, slo_code, source_pages)
      values (j.tenant_id, v_paper, (q ->> 'section_no')::int, (q ->> 'question_no')::int, q ->> 'type', (q ->> 'marks')::int, q ->> 'text',
              q -> 'options', q ->> 'answer', q ->> 'chapter', q ->> 'topic_tag', q ->> 'slo_code', coalesce(q -> 'source_pages', '[]'::jsonb));
    end loop;
    v_ids := v_ids || v_paper;
  end loop;

  if j.set_count > 1 then
    insert into public.exam_paper_set_group (tenant_id, campus_id, exam_subject_id, set_count)
    values (j.tenant_id, j.campus_id, j.exam_subject_id, j.set_count)
    on conflict (exam_subject_id) do update set set_count = excluded.set_count, updated_at = now();
  end if;

  update public.paper_generation_job set status = 'completed', last_error = null, finished_at = now() where id = p_job_id;
  return jsonb_build_object('status', 'completed', 'paper_ids', to_jsonb(v_ids));
end;
$$;
revoke execute on function public.fn_ingest_generated_paper(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.fn_ingest_generated_paper(uuid, jsonb) to service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- Where a set's paper and key live
-- ═══════════════════════════════════════════════════════════════════════

-- {tenant_id}/{exam_subject_id}/set-{code}.pdf and .../key-{code}.pdf. Derived
-- from the paper row, never typed, so the key a caller gets for a paper is
-- always the key of that paper's own set.
create or replace function app.fn_paper_file_path(p_paper_id uuid, p_kind text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.tenant_id::text || '/' || p.exam_subject_id::text || '/' || case p_kind when 'key' then 'key-' else 'set-' end || p.set_code::text || '.pdf'
    from public.exam_paper p where p.id = p_paper_id;
$$;
revoke execute on function app.fn_paper_file_path(uuid, text) from public, anon, authenticated;

create or replace function public.fn_exam_paper_file_paths(p_paper_id uuid)
returns table (paper_path text, key_path text, set_code char)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() in ('parent', 'student', 'none') or not app.fn_can_see_paper(p_paper_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query select app.fn_paper_file_path(p_paper_id, 'paper'), app.fn_paper_file_path(p_paper_id, 'key'), p.set_code from public.exam_paper p where p.id = p_paper_id;
end;
$$;
revoke execute on function public.fn_exam_paper_file_paths(uuid) from public, anon;
grant execute on function public.fn_exam_paper_file_paths(uuid) to authenticated;
