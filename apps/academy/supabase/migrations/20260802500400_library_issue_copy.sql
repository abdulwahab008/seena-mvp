-- FR-O04: issue a copy with limit enforcement.
--
-- issue_copy(barcode, borrower) is the whole counter transaction. In order:
--   1. lock the copy row (SELECT ... FOR UPDATE) so two terminals scanning the same barcode in the
--      same 200 ms serialise; the loser sees status = issued and gets COPY_NOT_AVAILABLE;
--   2. refuse anything that is not 'available' (lost, in repair, held, written off ...);
--   3. resolve the borrower and their policy (FR-O03) as of now; no policy = NO_POLICY;
--   4. refuse a borrower whose unpaid library fines have reached the policy's block_threshold
--      (BORROWER_BLOCKED, the outstanding amount in the error detail, in paisa);
--   5. refuse when open loans have reached max_loans (LIMIT_EXCEEDED, detail "6 of 6");
--   6. compute the due date = Karachi today + loan_days, rolled FORWARD to the next working day
--      when it lands on a weekly off-day or a gazetted holiday of the copy's campus calendar;
--   7. insert the loan with the resolved policy snapshotted as jsonb, and mark the copy issued.
-- Belt and braces: the partial unique index uq_open_loan_per_copy means that even if a lock timeout
-- ever sent a retry down a different path, two open loans on one copy are impossible.
--
-- The fine ledger (library_fine) is created here because the block check reads it; the nightly
-- accrual, settlement and waiver arrive with FR-O05 / FR-O07 / FR-O08.

create type public.library_fine_status as enum ('outstanding', 'settled', 'waived');

create table public.library_loan (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  copy_id         uuid not null references public.library_copy(id),
  borrower_id     uuid not null,
  borrower_role   text not null check (borrower_role in ('student', 'teacher', 'staff')),
  issued_by       uuid references public.app_user(user_id),
  issued_at       timestamptz not null default clock_timestamp(),
  due_on          date not null,
  policy_snapshot jsonb not null,
  renewal_count   int not null default 0 check (renewal_count >= 0),
  returned_at     timestamptz,
  created_at      timestamptz not null default now()
);

create unique index uq_open_loan_per_copy on public.library_loan (copy_id) where returned_at is null;
create index idx_open_loans_by_borrower on public.library_loan (borrower_id) where returned_at is null;
create index idx_library_loan_campus on public.library_loan (tenant_id, campus_id, issued_at desc);
create index idx_library_loan_borrower on public.library_loan (borrower_id, issued_at desc);
create index idx_library_loan_open_due on public.library_loan (due_on) where returned_at is null;

create trigger trg_audit_library_loan after insert or update or delete on public.library_loan
  for each row execute function app.tg_audit_row();

create table public.library_fine (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  loan_id             uuid not null references public.library_loan(id),
  borrower_id         uuid not null,
  accrual_date        date not null,
  days_overdue        int not null check (days_overdue >= 1),
  amount              bigint not null check (amount > 0),
  status              public.library_fine_status not null default 'outstanding',
  settled_receipt_id  uuid,
  settled_by          uuid references public.app_user(user_id),
  settled_at          timestamptz,
  waived_by           uuid references public.app_user(user_id),
  waived_at           timestamptz,
  waive_reason        text,
  write_off_id        uuid,
  created_at          timestamptz not null default clock_timestamp(),
  constraint chk_library_fine_waive check (status <> 'waived' or (waive_reason is not null and char_length(btrim(waive_reason)) >= 5 and waived_by is not null))
);

create unique index uq_fine_per_loan_day on public.library_fine (loan_id, accrual_date);
create index idx_library_fine_borrower on public.library_fine (borrower_id) where status = 'outstanding';
create index idx_library_fine_campus on public.library_fine (tenant_id, campus_id, status);

create trigger library_fine_audit after insert or update or delete on public.library_fine
  for each row execute function app.tg_audit_row();

-- A fine row is never deleted: it is settled or waived with a reason, because the fine register
-- is reconciled against the cash book.
create or replace function app.tg_library_fine_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'LIBRARY_FINE_NOT_DELETABLE' using errcode = '42501';
end;
$$;
create trigger library_fine_no_delete before delete on public.library_fine
  for each row execute function app.tg_library_fine_no_delete();

alter table public.library_loan enable row level security;
alter table public.library_fine enable row level security;
revoke insert, update, delete on public.library_loan from authenticated, anon;
revoke insert, update, delete on public.library_fine from authenticated, anon;

create policy library_loan_campus_scope on public.library_loan for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_library_staff() and app.fn_library_campus_ok(campus_id));
create policy library_loan_self_read on public.library_loan for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (borrower_id = (select auth.uid()) or borrower_id = public.my_student_id() or borrower_id = any (app.auth_guardian_student_ids())));

create policy library_fine_campus_scope on public.library_fine for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'librarian', 'accountant') and app.fn_library_campus_ok(campus_id));
create policy library_fine_parent_read on public.library_fine for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and (borrower_id = (select auth.uid()) or borrower_id = public.my_student_id() or borrower_id = any (app.auth_guardian_student_ids())));

-- ── working-day calendar ─────────────────────────────────────────────────────
-- A day is open when it is one of the campus's weekly working days and not a holiday on the
-- campus calendar (public.is_working_day, FR-M14).

create or replace function app.fn_library_is_open_day(p_campus_id uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select extract(isodow from p_date)::smallint = any (c.working_days) from public.campus c where c.id = p_campus_id), true)
         and public.is_working_day(p_campus_id, p_date);
$$;
revoke execute on function app.fn_library_is_open_day(uuid, date) from public, anon, authenticated;

create or replace function app.fn_library_next_open_day(p_campus_id uuid, p_date date)
returns date
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v date := p_date;
  i int := 0;
begin
  while not app.fn_library_is_open_day(p_campus_id, v) and i < 60 loop
    v := v + 1;
    i := i + 1;
  end loop;
  return v;
end;
$$;
revoke execute on function app.fn_library_next_open_day(uuid, date) from public, anon, authenticated;

-- ── outstanding fines of a borrower ──────────────────────────────────────────

create or replace function app.fn_library_outstanding(p_borrower_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(amount), 0)::bigint from public.library_fine
   where tenant_id = app.auth_tenant_id() and borrower_id = p_borrower_id and status = 'outstanding';
$$;
revoke execute on function app.fn_library_outstanding(uuid) from public, anon, authenticated;

-- ── issue ────────────────────────────────────────────────────────────────────

create or replace function public.issue_copy(p_barcode text, p_borrower_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_copy    public.library_copy%rowtype;
  v_b       record;
  v_pol     public.library_borrower_policy%rowtype;
  v_open    int;
  v_out     bigint;
  v_due     date;
  v_loan    uuid;
  v_title   text;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_copy from public.library_copy where tenant_id = v_tenant and barcode = btrim(p_barcode) for update;
  if not found then
    raise exception 'COPY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_library_campus_ok(v_copy.campus_id) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if v_copy.status <> 'available' then
    raise exception 'COPY_NOT_AVAILABLE' using errcode = '55000';
  end if;

  select * into v_b from app.fn_library_borrower(p_borrower_id);
  if v_b.borrower_role is null or (v_b.borrower_role = 'student' and not exists (select 1 from public.student s where s.id = p_borrower_id and s.status = 'active')) then
    raise exception 'BORROWER_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_pol := public.resolve_borrower_policy(p_borrower_id, clock_timestamp(), case when v_b.borrower_role = 'student' then null else v_copy.campus_id end);
  if v_pol.id is null then
    raise exception 'NO_POLICY' using errcode = '55000';
  end if;

  v_out := app.fn_library_outstanding(p_borrower_id);
  if v_pol.block_threshold is not null and v_out >= v_pol.block_threshold then
    raise exception 'BORROWER_BLOCKED' using errcode = '55000', detail = v_out::text;
  end if;

  select count(*) into v_open from public.library_loan where tenant_id = v_tenant and borrower_id = p_borrower_id and returned_at is null;
  if v_open >= v_pol.max_loans then
    raise exception 'LIMIT_EXCEEDED' using errcode = '55000', detail = v_open || ' of ' || v_pol.max_loans;
  end if;

  v_due := app.fn_library_next_open_day(v_copy.campus_id, app.fn_karachi_today() + v_pol.loan_days);

  insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, issued_by, due_on, policy_snapshot)
  values (v_tenant, v_copy.campus_id, v_copy.id, p_borrower_id, v_b.borrower_role, (select auth.uid()), v_due, to_jsonb(v_pol))
  returning id into v_loan;
  update public.library_copy set status = 'issued' where id = v_copy.id;

  select t.title into v_title from public.library_title t where t.id = v_copy.title_id;
  return jsonb_build_object('loan_id', v_loan, 'due_on', v_due, 'copy_id', v_copy.id, 'accession_no', v_copy.accession_no, 'title', v_title,
                            'borrower_name', v_b.display_name, 'borrower_role', v_b.borrower_role, 'open_loans', v_open + 1, 'max_loans', v_pol.max_loans);
exception when unique_violation then
  raise exception 'COPY_NOT_AVAILABLE' using errcode = '55000';
end;
$$;
revoke execute on function public.issue_copy(text, uuid) from public, anon;
grant execute on function public.issue_copy(text, uuid) to authenticated;

-- ── borrower lookup for the counter ──────────────────────────────────────────
-- The borrower card carries the student's GR number (exact match is returned alone); otherwise a
-- name search over active students and library-eligible staff.

create or replace function public.find_library_borrowers(p_query text)
returns table (borrower_id uuid, borrower_role text, display_name text, detail text, open_loans int, outstanding_paisa bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q      text := btrim(coalesce(p_query, ''));
  v_tenant uuid := app.auth_tenant_id();
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if char_length(v_q) < 2 then
    return;
  end if;
  if exists (select 1 from public.student s where s.tenant_id = v_tenant and s.gr_number = v_q and s.status = 'active') then
    return query
      select s.id, 'student'::text, s.name_en,
             'GR ' || s.gr_number || coalesce(' · ' || (select cl.name_en || ' ' || cs.name from public.enrolment e join public.class_level cl on cl.id = e.class_level_id join public.class_section cs on cs.id = e.section_id where e.student_id = s.id and e.status = 'active' order by e.joined_on desc limit 1), ''),
             (select count(*)::int from public.library_loan l where l.borrower_id = s.id and l.returned_at is null),
             app.fn_library_outstanding(s.id)
        from public.student s where s.tenant_id = v_tenant and s.gr_number = v_q and s.status = 'active';
    return;
  end if;
  return query
    (select s.id, 'student'::text, s.name_en,
            'GR ' || s.gr_number || coalesce(' · ' || (select cl.name_en || ' ' || cs.name from public.enrolment e join public.class_level cl on cl.id = e.class_level_id join public.class_section cs on cs.id = e.section_id where e.student_id = s.id and e.status = 'active' order by e.joined_on desc limit 1), ''),
            (select count(*)::int from public.library_loan l where l.borrower_id = s.id and l.returned_at is null),
            app.fn_library_outstanding(s.id)
       from public.student s
      where s.tenant_id = v_tenant and s.status = 'active' and app.fn_library_campus_ok(s.campus_id) and (s.name_en ilike '%' || v_q || '%' or s.name_ur ilike '%' || v_q || '%')
      order by s.name_en limit 10)
    union all
    (select u.user_id, case when u.app_role in ('class_teacher', 'subject_teacher', 'head_of_department') then 'teacher' else 'staff' end, u.full_name,
            replace(u.app_role::text, '_', ' '),
            (select count(*)::int from public.library_loan l where l.borrower_id = u.user_id and l.returned_at is null),
            app.fn_library_outstanding(u.user_id)
       from public.app_user u
      where u.tenant_id = v_tenant and u.status = 'active' and u.app_role not in ('parent', 'student') and u.full_name ilike '%' || v_q || '%'
      order by u.full_name limit 10);
end;
$$;
revoke execute on function public.find_library_borrowers(text) from public, anon;
grant execute on function public.find_library_borrowers(text) to authenticated;
