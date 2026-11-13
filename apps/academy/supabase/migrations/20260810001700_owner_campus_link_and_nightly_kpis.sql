-- An owner who added their campus through setup was never linked to it (only invited staff get
-- user_campus rows), so their token carried no campus: the Today screen failed its campus check
-- and the owner KPIs stayed empty. Link every owner and super admin to every campus of their
-- school, now and whenever a campus is added.
insert into public.user_campus (user_id, tenant_id, campus_id)
select au.user_id, c.tenant_id, c.id
  from public.app_user au
  join public.campus c on c.tenant_id = au.tenant_id
 where au.app_role in ('owner', 'super_admin')
   and not exists (select 1 from public.user_campus uc where uc.user_id = au.user_id and uc.campus_id = c.id);

create or replace function app.tg_campus_link_owners()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_campus (user_id, tenant_id, campus_id)
  select au.user_id, new.tenant_id, new.id
    from public.app_user au
   where au.tenant_id = new.tenant_id and au.app_role in ('owner', 'super_admin')
     and not exists (select 1 from public.user_campus uc where uc.user_id = au.user_id and uc.campus_id = new.id);
  return new;
end;
$$;

drop trigger if exists campus_link_owners on public.campus;
create trigger campus_link_owners after insert on public.campus
  for each row execute function app.tg_campus_link_owners();

-- The nightly KPI refresh was only scheduled if pg_cron was already enabled, and on the hosted
-- project it was not, so it never ran. Enable it where the platform offers it and schedule the job.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'agg_campus_day_nightly';
    perform cron.schedule('agg_campus_day_nightly', '30 20 * * *', 'select public.refresh_agg_nightly();');
  end if;
end;
$$;
