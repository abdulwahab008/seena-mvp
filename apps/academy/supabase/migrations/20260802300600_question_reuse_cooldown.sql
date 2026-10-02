-- FR-I06: question reuse cooldown.
--
-- Students must not pass by memorising last term's paper, so the system knows
-- which questions each class has already seen:
--
--   * question_bank_item is the school's bank of questions, filled automatically
--     from every PUBLISHED paper (identity: tenant + subject + a normalised-text
--     hash, so the same wording is the same question however it was generated);
--   * question_usage records each use of a bank question by a class in a term;
--   * fn_question_reuse_check(paper) lists the questions of a draft that the same
--     CLASS has seen within the last N terms (exam_settings.question_cooldown_terms)
--     with how many terms ago; usage by another class never counts, and neither
--     does another set of the same exam;
--   * publishing a flagged paper is a WARNING by default (teachers legitimately
--     repeat good board-style questions; a hard block drives them back to Word
--     and the bank dies). With cooldown_mode = 'block' it is refused until the
--     questions are replaced or the controller records an override reason, which
--     is stored with the actor against the paper.
--
-- The bank is never readable by a parent or a student, under any policy.

create or replace function app.fn_question_hash(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select md5(lower(regexp_replace(btrim(coalesce(p_text, '')), '\s+', ' ', 'g')));
$$;

create table public.question_bank_item (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  subject_id     uuid not null references public.subject(id),
  class_level_id uuid not null references public.class_level(id),
  chapter        text,
  topic_tag      text,
  difficulty     text not null default 'medium' check (difficulty in ('easy', 'medium', 'hard')),
  marks          int not null check (marks >= 1),
  question_type  text not null check (question_type in ('mcq', 'short', 'long')),
  question_text  text not null check (length(btrim(question_text)) > 0),
  options        jsonb,
  answer         text,
  slo_code       text,
  source_book_id uuid,
  text_hash      text generated always as (app.fn_question_hash(question_text)) stored,
  is_active      boolean not null default true,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  constraint uq_question_bank_text unique (tenant_id, subject_id, text_hash)
);
create index idx_question_bank_scope on public.question_bank_item (tenant_id, campus_id);
create index idx_question_bank_subject on public.question_bank_item (subject_id, class_level_id);
create index idx_question_bank_class on public.question_bank_item (class_level_id);

create table public.question_usage (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  question_id    uuid not null references public.question_bank_item(id) on delete cascade,
  class_level_id uuid not null references public.class_level(id),
  exam_paper_id  uuid not null references public.exam_paper(id) on delete cascade,
  exam_term_id   uuid not null references public.exam_term(id) on delete cascade,
  used_at        timestamptz not null default now(),
  constraint uq_question_usage_paper unique (question_id, exam_paper_id)
);
create index idx_question_usage on public.question_usage (question_id, class_level_id, used_at desc);
create index idx_question_usage_tenant on public.question_usage (tenant_id, campus_id);
create index idx_question_usage_paper on public.question_usage (exam_paper_id);
create index idx_question_usage_term on public.question_usage (exam_term_id);
create index idx_question_usage_class on public.question_usage (class_level_id);

create table public.paper_publish_override (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  exam_paper_id uuid not null references public.exam_paper(id) on delete cascade,
  overridden_by uuid not null references auth.users(id),
  reason        text not null check (char_length(btrim(reason)) >= 10),
  flagged_count int not null,
  flagged       jsonb not null default '[]'::jsonb,
  created_at    timestamptz not null default now(),
  constraint uq_paper_publish_override unique (exam_paper_id)
);
create index idx_paper_publish_override_scope on public.paper_publish_override (tenant_id, campus_id);

alter table public.exam_paper_item add constraint fk_exam_paper_item_bank foreign key (bank_item_id) references public.question_bank_item(id) on delete set null;

create trigger question_bank_item_audit after insert or update or delete on public.question_bank_item
  for each row execute function app.tg_audit_row();
create trigger paper_publish_override_audit after insert or update or delete on public.paper_publish_override
  for each row execute function app.tg_audit_row();

alter table public.question_bank_item enable row level security;
alter table public.question_usage enable row level security;
alter table public.paper_publish_override enable row level security;
-- Staff only; a parent or a student is excluded by role, whatever else is true of them.
create policy question_bank_campus_scope on public.question_bank_item for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy question_usage_campus_scope on public.question_usage for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy paper_publish_override_scope on public.paper_publish_override for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- ═══════════════════════════════════════════════════════════════════════
-- The check
-- ═══════════════════════════════════════════════════════════════════════

-- Position of a term in the campus's own chronology: sessions by start date,
-- terms within a session by sequence.
create or replace function app.fn_exam_term_rank(p_exam_term_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select x.r::int from (
    select t.id, dense_rank() over (order by s.starts_on, t.sequence) as r
      from public.exam_term t
      join public.academic_session s on s.id = t.session_id
     where t.campus_id = (select campus_id from public.exam_term where id = p_exam_term_id)
  ) x where x.id = p_exam_term_id;
$$;
revoke execute on function app.fn_exam_term_rank(uuid) from public, anon, authenticated;

create or replace function app.fn_can_see_paper(p_paper_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.exam_paper p
     where p.id = p_paper_id and p.tenant_id = app.auth_tenant_id()
       and (p.created_by = (select auth.uid())
            or (app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
                and (app.auth_role() in ('owner', 'super_admin') or p.campus_id = any (app.auth_campus_ids()))))
  );
$$;
revoke execute on function app.fn_can_see_paper(uuid) from public, anon, authenticated;

-- Internal: the flagged questions with the draft's own item id.
create or replace function app.fn_reuse_flags(p_paper_id uuid)
returns table (question_id uuid, item_id uuid, last_used_term text, terms_ago int)
language sql
stable
security definer
set search_path = ''
as $$
  with paper as (
    select p.id, p.tenant_id, p.exam_subject_id, es.exam_term_id, cs.class_level_id, cs.subject_id,
           app.fn_exam_term_rank(es.exam_term_id) as cur_rank,
           coalesce((select x.question_cooldown_terms from public.exam_settings x where x.campus_id = p.campus_id), 4) as cooldown
      from public.exam_paper p
      join public.exam_subject es on es.id = p.exam_subject_id
      join public.class_subject cs on cs.id = es.class_subject_id
     where p.id = p_paper_id
  ), items as (
    select i.id as item_id, coalesce(i.bank_item_id, b.id) as qid
      from public.exam_paper_item i
      cross join paper
      left join public.question_bank_item b
        on b.tenant_id = i.tenant_id and b.subject_id = paper.subject_id and b.text_hash = app.fn_question_hash(i.question_text)
     where i.paper_id = p_paper_id
  )
  select items.qid, items.item_id, t.name, (paper.cur_rank - app.fn_exam_term_rank(t.id))::int
    from items
    cross join paper
    cross join lateral (
      select u.exam_term_id
        from public.question_usage u
        join public.exam_paper up on up.id = u.exam_paper_id
       where u.question_id = items.qid and u.class_level_id = paper.class_level_id and up.exam_subject_id <> paper.exam_subject_id
       order by app.fn_exam_term_rank(u.exam_term_id) desc
       limit 1
    ) lu
    join public.exam_term t on t.id = lu.exam_term_id
   where items.qid is not null
     and paper.cur_rank - app.fn_exam_term_rank(t.id) between 1 and paper.cooldown
   order by items.item_id;
$$;
revoke execute on function app.fn_reuse_flags(uuid) from public, anon, authenticated;

create or replace function public.fn_question_reuse_check(p_paper_id uuid)
returns table (question_id uuid, last_used_term text, terms_ago int, item_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() in ('parent', 'student', 'none') or not app.fn_can_see_paper(p_paper_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query select f.question_id, f.last_used_term, f.terms_ago, f.item_id from app.fn_reuse_flags(p_paper_id) f;
end;
$$;
revoke execute on function public.fn_question_reuse_check(uuid) from public, anon;
grant execute on function public.fn_question_reuse_check(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Publish
-- ═══════════════════════════════════════════════════════════════════════

-- Publishes a draft paper: runs the cooldown check, applies the campus's mode,
-- stores an override (actor + reason) when one is given or needed, then puts
-- every question in the bank and records its use by this class in this term.
create or replace function public.publish_exam_paper(p_paper_id uuid, p_override_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paper   public.exam_paper%rowtype;
  v_term    uuid;
  v_class   uuid;
  v_subject uuid;
  v_mode    text;
  v_flags   jsonb;
  v_count   int;
  v_reason  text := nullif(btrim(coalesce(p_override_reason, '')), '');
begin
  select * into v_paper from public.exam_paper where id = p_paper_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'PAPER_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_paper.campus_id);
  if v_paper.status <> 'draft' then
    raise exception 'PAPER_NOT_DRAFT' using errcode = '22023';
  end if;
  select es.exam_term_id, cs.class_level_id, cs.subject_id into v_term, v_class, v_subject
    from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id where es.id = v_paper.exam_subject_id;
  v_mode := coalesce((select cooldown_mode from public.exam_settings where campus_id = v_paper.campus_id), 'warn');

  select coalesce(jsonb_agg(jsonb_build_object('question_id', f.question_id, 'item_id', f.item_id, 'last_used_term', f.last_used_term, 'terms_ago', f.terms_ago)), '[]'::jsonb), count(*)::int
    into v_flags, v_count from app.fn_reuse_flags(p_paper_id) f;

  if v_count > 0 and v_mode = 'block' and v_reason is null then
    raise exception 'COOLDOWN_BLOCKED' using errcode = '22023',
      detail = format('%s question%s were used by this class within the cooldown. Replace them or record an override reason.', v_count, case when v_count = 1 then '' else 's' end);
  end if;
  if v_reason is not null and char_length(v_reason) < 10 then
    raise exception 'OVERRIDE_REASON_TOO_SHORT' using errcode = '22023';
  end if;
  if v_count > 0 and v_reason is not null then
    insert into public.paper_publish_override (tenant_id, campus_id, exam_paper_id, overridden_by, reason, flagged_count, flagged)
    values (v_paper.tenant_id, v_paper.campus_id, p_paper_id, (select auth.uid()), v_reason, v_count, v_flags);
  end if;

  -- The bank learns every question, and remembers who used it when.
  insert into public.question_bank_item (tenant_id, campus_id, subject_id, class_level_id, chapter, topic_tag, marks, question_type, question_text, options, answer, slo_code, created_by)
  select i.tenant_id, v_paper.campus_id, v_subject, v_class, i.chapter, i.topic_tag, i.marks, i.question_type, i.question_text, i.options, i.answer, i.slo_code, (select auth.uid())
    from public.exam_paper_item i where i.paper_id = p_paper_id
  on conflict (tenant_id, subject_id, text_hash) do nothing;
  update public.exam_paper_item i
     set bank_item_id = b.id
    from public.question_bank_item b
   where i.paper_id = p_paper_id and b.tenant_id = i.tenant_id and b.subject_id = v_subject and b.text_hash = app.fn_question_hash(i.question_text);
  insert into public.question_usage (tenant_id, campus_id, question_id, class_level_id, exam_paper_id, exam_term_id)
  select i.tenant_id, v_paper.campus_id, i.bank_item_id, v_class, p_paper_id, v_term
    from public.exam_paper_item i where i.paper_id = p_paper_id and i.bank_item_id is not null
  on conflict (question_id, exam_paper_id) do nothing;

  update public.exam_paper set status = 'published', published_at = now() where id = p_paper_id;
  return jsonb_build_object('status', 'published', 'flagged_count', v_count, 'overridden', v_count > 0 and v_reason is not null, 'mode', v_mode);
end;
$$;
revoke execute on function public.publish_exam_paper(uuid, text) from public, anon;
grant execute on function public.publish_exam_paper(uuid, text) to authenticated;

-- Replaces one question of a DRAFT paper (the way out of a cooldown flag). The
-- marks and type stay: the paper still equals its pattern.
create or replace function public.replace_paper_question(p_item_id uuid, p_text text, p_options jsonb default null, p_answer text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item  public.exam_paper_item%rowtype;
  v_paper public.exam_paper%rowtype;
begin
  select * into v_item from public.exam_paper_item where id = p_item_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'QUESTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_paper from public.exam_paper where id = v_item.paper_id for update;
  if not app.fn_can_see_paper(v_paper.id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_paper.status <> 'draft' then
    raise exception 'PAPER_NOT_DRAFT' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_text, ''))) = 0 or char_length(p_text) > 2000 then
    raise exception 'QUESTION_TEXT_INVALID' using errcode = '22023';
  end if;
  update public.exam_paper_item
     set question_text = btrim(p_text), options = coalesce(p_options, options), answer = coalesce(p_answer, answer), bank_item_id = null
   where id = p_item_id;
end;
$$;
revoke execute on function public.replace_paper_question(uuid, text, jsonb, text) from public, anon;
grant execute on function public.replace_paper_question(uuid, text, jsonb, text) to authenticated;
