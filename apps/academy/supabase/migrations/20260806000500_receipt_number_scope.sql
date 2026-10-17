-- Receipt numbers run on per campus, across academic sessions.
--
-- The receipt counter was keyed by (tenant, campus, session), so every campus and every academic
-- session started again at RCP-00000001, but fee_receipt_no_uq made the number unique across the
-- whole school. The first receipt at a second campus, and the first one of each new academic
-- session, therefore tried to issue RCP-00000001 a second time and failed with a duplicate key;
-- collect_cash_payment() rolled back, the counter with it, and every retry failed the same way.
--
-- One running series per campus fixes both: it is that campus's receipt book, it does not start
-- over when the academic year does, and the unique index now says what the numbering already was.
-- A campus that already has a counter row per session (written before this) carries on above the
-- highest of them, which is above every number it has issued. The counter guard is unchanged: only
-- this function creates a row (at zero) and advances it, one at a time.

drop index public.fee_receipt_no_uq;
create unique index fee_receipt_campus_no_uq on public.fee_receipt (tenant_id, campus_id, receipt_no);

create or replace function app.fn_next_receipt_no(p_tenant_id uuid, p_campus_id uuid, p_session_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_next bigint;
begin
  -- Two cashiers issuing the campus's first receipts in different sessions must not start two series.
  perform pg_advisory_xact_lock(hashtextextended('receipt-no:' || p_tenant_id::text || ':' || p_campus_id::text, 0));

  -- The series lives on the campus's counter row with the highest number.
  update public.fee_receipt_counter c
     set last_no = c.last_no + 1
   where (c.tenant_id, c.campus_id, c.session_id) = (
           select k.tenant_id, k.campus_id, k.session_id
             from public.fee_receipt_counter k
            where k.tenant_id = p_tenant_id and k.campus_id = p_campus_id
            order by k.last_no desc, k.session_id
            limit 1
         )
  returning c.last_no into v_next;

  if v_next is null then
    insert into public.fee_receipt_counter (tenant_id, campus_id, session_id, last_no)
    values (p_tenant_id, p_campus_id, p_session_id, 0);

    update public.fee_receipt_counter set last_no = last_no + 1
     where tenant_id = p_tenant_id and campus_id = p_campus_id and session_id = p_session_id
    returning last_no into v_next;
  end if;

  return 'RCP-' || lpad(v_next::text, 8, '0');
end;
$$;
