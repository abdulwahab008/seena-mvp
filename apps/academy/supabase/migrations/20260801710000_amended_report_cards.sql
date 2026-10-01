-- FR-J15 (2/2): amended report card after a marks correction.
--
-- A correction does not only change the corrected students' cards: one
-- student's new total re-ranks the whole section, so cascading to the
-- corrected students alone is how two parents end up holding cards that both
-- claim position 3. EVERY issued card of the section and term goes stale.
-- A stale card is not withdrawn: the parent keeps seeing it under a "result
-- under review" banner until revision N+1 is issued, at which point the old
-- one is superseded (kept for audit) and the new one carries a revised-on date.

alter table public.report_card
  add column if not exists stale_at timestamptz,
  add column if not exists stale_reason text;

create index if not exists idx_report_card_stale on public.report_card (exam_term_id, status) where status = 'stale';

create or replace function app.fn_mark_report_cards_stale(p_exam_subject_id uuid, p_section_id uuid, p_reason text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  update public.report_card rc
     set status = 'stale', stale_at = now(), stale_reason = p_reason
   where rc.status = 'issued'
     and rc.section_id = p_section_id
     and rc.exam_term_id = (select es.exam_term_id from public.exam_subject es where es.id = p_exam_subject_id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function app.fn_mark_report_cards_stale(uuid, uuid, text) from public, anon, authenticated;

create or replace function app.tg_mark_audit_stales_report_cards()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subject text;
begin
  select sub.name_en into v_subject
    from public.exam_subject es
    join public.class_subject cs on cs.id = es.class_subject_id
    join public.subject sub on sub.id = cs.subject_id
   where es.id = new.exam_subject_id;

  perform app.fn_mark_report_cards_stale(new.exam_subject_id, new.section_id, 'Marks corrected: ' || coalesce(v_subject, 'a subject'));
  return new;
end;
$$;
drop trigger if exists trg_mark_audit_stales_report_cards on public.mark_entry_audit;
create trigger trg_mark_audit_stales_report_cards
  after insert on public.mark_entry_audit
  for each row when (new.old_marks is distinct from new.new_marks)
  execute function app.tg_mark_audit_stales_report_cards();

-- The parent keeps seeing a stale card (under a banner); superseded and void stay hidden.
drop policy if exists report_card_parent_own_child on public.report_card;
create policy report_card_parent_own_child on public.report_card
  for select to authenticated
  using (
    status in ('issued', 'stale')
    and enrolment_id in (select id from public.enrolment where student_id = any(app.auth_guardian_student_ids()))
    and not app.fn_result_withheld(enrolment_id, exam_term_id)
  );

-- What the portal needs per child and term: the card to show, whether it is
-- under review, and whether it is a revision (with the date).
create or replace function public.fn_portal_report_cards(p_enrolment_id uuid)
returns table (report_card_id uuid, exam_term_id uuid, term_name text, revision_no int, status text, under_review boolean, revised_on date)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct on (rc.exam_term_id)
         rc.id, rc.exam_term_id, t.name, rc.revision_no, rc.status::text, (rc.status = 'stale'),
         case when rc.revision_no > 1 and rc.status = 'issued' then (rc.rendered_at at time zone 'Asia/Karachi')::date end
    from public.report_card rc
    join public.exam_term t on t.id = rc.exam_term_id
    join public.enrolment e on e.id = rc.enrolment_id
   where rc.enrolment_id = p_enrolment_id
     and rc.status in ('issued', 'stale')
     and e.student_id = any(app.auth_guardian_student_ids())
     and not app.fn_result_withheld(rc.enrolment_id, rc.exam_term_id)
   order by rc.exam_term_id, rc.revision_no desc;
$$;
revoke execute on function public.fn_portal_report_cards(uuid) from public, anon;
grant execute on function public.fn_portal_report_cards(uuid) to authenticated;

create or replace function public.attach_report_card_pdf(p_report_card_id uuid, p_sha256 text)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $$
declare
  v_row public.report_card%rowtype;
begin
  if app.auth_tenant_id() is null
     or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal',
                                'exam_controller', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_row from public.report_card where id = p_report_card_id;
  if v_row.id is null or v_row.tenant_id <> app.auth_tenant_id() then
    raise exception 'REPORT_CARD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'REPORT_CARD_NOT_PENDING' using errcode = '23514';
  end if;
  if p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'REPORT_CARD_DIGEST_INVALID' using errcode = '23514';
  end if;

  -- The predecessor stops being current at the moment its successor exists as
  -- a document, not at the moment one was requested.
  update public.report_card
     set status = 'superseded'
   where enrolment_id = v_row.enrolment_id
     and exam_term_id = v_row.exam_term_id
     and revision_no < v_row.revision_no
     and status in ('issued', 'stale');

  update public.report_card
     set checksum = p_sha256, status = 'issued'
   where id = p_report_card_id;
end;
$$;

create or replace function app.fn_reserve_report_card(p_enrolment_id uuid, p_exam_term_id uuid, p_remark text, p_tenant_id uuid, p_actor uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $$
declare
  v_enr      record;
  v_prev     record;
  v_revision integer;
  v_remark   text;
  v_payload  jsonb;
  v_path     text;
  v_id       uuid;
  v_at       timestamptz;
begin
  select e.id, e.tenant_id, e.campus_id, e.section_id, e.session_id into v_enr
    from public.enrolment e where e.id = p_enrolment_id and e.deleted_at is null;
  if v_enr.id is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enr.tenant_id <> p_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC3 of FR-J09, and it is the FIRST thing that happens: refusing before a
  -- revision is reserved is what makes "no file is written" true with nothing
  -- to clean up afterwards. The gate hands 'result_withheld' out as the
  -- machine-readable DETAIL while the sentence — which names the amount, the
  -- cut-off and the threshold — reaches the screen intact.
  perform public.fn_assert_report_card_printable(p_enrolment_id, p_exam_term_id);

  -- FR-J09 AC4. A correction is a new revision, never an edit: the old
  -- document is in a parent's hands and the register has to account for it.
  --
  -- The next number counts EVERY row including voided ones — FR-T02's rule
  -- that a number which has been handed out is never reissued — while the
  -- revision this one SUPERSEDES is the last one that actually became a
  -- document.
  select max(rc.revision_no) into v_revision
    from public.report_card rc
   where rc.enrolment_id = p_enrolment_id and rc.exam_term_id = p_exam_term_id;
  v_revision := coalesce(v_revision, 0) + 1;

  select rc.revision_no, rc.payload_snapshot ->> 'remark' as remark
    into v_prev
    from public.report_card rc
   where rc.enrolment_id = p_enrolment_id
     and rc.exam_term_id = p_exam_term_id
     and rc.status in ('issued', 'stale', 'superseded')
   order by rc.revision_no desc
   limit 1;

  -- A regeneration after a marks correction should not silently drop the
  -- class teacher's words; passing a new remark replaces them deliberately.
  v_remark := coalesce(nullif(btrim(coalesce(p_remark, '')), ''), v_prev.remark);

  v_payload := app.fn_build_report_card_payload(p_enrolment_id, p_exam_term_id, v_remark);
  v_at := clock_timestamp();
  v_payload := v_payload
    || jsonb_build_object(
         'revision_no',         v_revision,
         'supersedes_revision', v_prev.revision_no,
         'rendered_at',         v_at
       );

  v_path := p_tenant_id || '/' || v_enr.campus_id || '/' || p_exam_term_id || '/'
            || p_enrolment_id || '-r' || v_revision || '.pdf';

  insert into public.report_card (
    tenant_id, campus_id, exam_term_id, section_id, enrolment_id,
    revision_no, supersedes_revision, storage_path, status, payload_snapshot,
    rendered_at, rendered_by
  )
  values (
    p_tenant_id, v_enr.campus_id, p_exam_term_id, v_enr.section_id, p_enrolment_id,
    v_revision, v_prev.revision_no, v_path, 'pending', v_payload,
    v_at, p_actor
  )
  returning id into v_id;

  return jsonb_build_object(
    'report_card_id',   v_id,
    'revision_no',      v_revision,
    'storage_path',     v_path,
    'payload_snapshot', v_payload
  );
end;
$$;
