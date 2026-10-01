-- FR-O05: return a copy and capture its condition.
--
-- return_copy(barcode, condition, received_by) closes the open loan:
--   * NO_OPEN_LOAN is raised (and nothing at all changes) when the barcode has no open loan;
--   * the BEFORE UPDATE trigger trg_loan_finalise_fine fires when returned_at goes from NULL to a
--     value: it writes any fine days not yet accrued by the nightly job (FR-O07) up to the Karachi
--     return date and stamps the loan's finalised fine_amount. Fines are computed from the
--     loan's policy snapshot, never from today's policy. After the return nothing accrues again:
--     the nightly job only looks at open loans;
--   * a good return makes the copy available; a damaged one sends it to in_repair, which is
--     excluded from availability until a librarian restores it. When the title has a waiting
--     reservation, the copy-became-available trigger of FR-O06 turns it into reserved_hold for the
--     head of the queue instead.
--
-- Fine days. A fine day is a calendar day after due_on, up to and including the return date. The
-- snapshot flag count_working_days_only (set per policy, default false: almost every school
-- library counts calendar days) restricts them to the campus's working days that are not holidays.
-- Day n of a loan costs min(rate, cap - rate*(n-1)), floored at zero, so a cap bites on the day it
-- is reached and a 300-day-overdue book costs exactly the cap.

alter table public.library_loan
  add column return_condition text check (return_condition is null or return_condition in ('good', 'damaged')),
  add column received_by uuid references public.app_user(user_id),
  add column fine_amount bigint check (fine_amount is null or fine_amount >= 0);

-- Idempotent: inserts the missing (loan, day) rows up to p_thru and returns the loan's total fine.
create or replace function app.fn_library_accrue_loan(p_loan_id uuid, p_thru date)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_l            public.library_loan%rowtype;
  v_rate         bigint;
  v_cap          bigint;
  v_working_only boolean;
begin
  select * into v_l from public.library_loan where id = p_loan_id;
  if not found then
    return 0;
  end if;
  v_rate := coalesce((v_l.policy_snapshot ->> 'fine_per_day')::bigint, 0);
  v_cap := (v_l.policy_snapshot ->> 'fine_cap')::bigint;
  v_working_only := coalesce((v_l.policy_snapshot ->> 'count_working_days_only')::boolean, false);

  if v_rate > 0 and p_thru > v_l.due_on then
    insert into public.library_fine (tenant_id, campus_id, loan_id, borrower_id, accrual_date, days_overdue, amount)
    select v_l.tenant_id, v_l.campus_id, v_l.id, v_l.borrower_id, y.d, y.idx::int,
           case when v_cap is null then v_rate else least(v_rate, greatest(v_cap - v_rate * (y.idx - 1), 0)) end
      from (
        select x.d, x.flag, sum(case when x.flag then 1 else 0 end) over (order by x.d) as idx
          from (
            select g::date as d, (not v_working_only or app.fn_library_is_open_day(v_l.campus_id, g::date)) as flag
              from generate_series((v_l.due_on + 1)::timestamp, p_thru::timestamp, interval '1 day') g
          ) x
      ) y
     where y.flag and case when v_cap is null then v_rate else least(v_rate, greatest(v_cap - v_rate * (y.idx - 1), 0)) end > 0
    on conflict (loan_id, accrual_date) do nothing;
  end if;
  return coalesce((select sum(amount) from public.library_fine where loan_id = p_loan_id), 0)::bigint;
end;
$$;
revoke execute on function app.fn_library_accrue_loan(uuid, date) from public, anon, authenticated;

create or replace function app.tg_library_loan_finalise_fine()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.fine_amount := app.fn_library_accrue_loan(new.id, (new.returned_at at time zone 'Asia/Karachi')::date);
  return new;
end;
$$;

create trigger trg_loan_finalise_fine before update on public.library_loan
  for each row when (old.returned_at is null and new.returned_at is not null)
  execute function app.tg_library_loan_finalise_fine();

-- ── return ───────────────────────────────────────────────────────────────────

create or replace function public.return_copy(p_barcode text, p_condition text default 'good', p_received_by uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid := app.auth_tenant_id();
  v_copy     public.library_copy%rowtype;
  v_loan     public.library_loan%rowtype;
  v_status   public.library_copy_status;
  v_receiver uuid := coalesce(p_received_by, (select auth.uid()));
  v_title    text;
  v_name     text;
  v_late     int;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_condition not in ('good', 'damaged') then
    raise exception 'INVALID_CONDITION' using errcode = '22023';
  end if;
  if not exists (select 1 from public.app_user where user_id = v_receiver and tenant_id = v_tenant) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_copy from public.library_copy where tenant_id = v_tenant and barcode = btrim(p_barcode) for update;
  if not found then
    raise exception 'COPY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_library_campus_ok(v_copy.campus_id) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;

  select * into v_loan from public.library_loan where copy_id = v_copy.id and returned_at is null for update;
  if not found then
    raise exception 'NO_OPEN_LOAN' using errcode = 'P0002';
  end if;

  update public.library_loan
     set returned_at = clock_timestamp(), return_condition = p_condition, received_by = v_receiver
   where id = v_loan.id
   returning * into v_loan;

  update public.library_copy
     set status = case when p_condition = 'damaged' then 'in_repair'::public.library_copy_status else 'available'::public.library_copy_status end
   where id = v_copy.id;

  select c.status into v_status from public.library_copy c where c.id = v_copy.id;
  select t.title into v_title from public.library_title t where t.id = v_copy.title_id;
  select b.display_name into v_name from app.fn_library_borrower(v_loan.borrower_id) b;
  v_late := greatest((v_loan.returned_at at time zone 'Asia/Karachi')::date - v_loan.due_on, 0);
  return jsonb_build_object('loan_id', v_loan.id, 'copy_id', v_copy.id, 'title', v_title, 'borrower_name', v_name, 'fine_amount', v_loan.fine_amount,
                            'days_late', v_late, 'copy_status', v_status, 'condition', p_condition);
end;
$$;
revoke execute on function public.return_copy(text, text, uuid) from public, anon;
grant execute on function public.return_copy(text, text, uuid) to authenticated;
