-- FR-J (break-glass mark unlock): the sweep that re-locks expired unlock
-- windows was documented as "a real cron.schedule('relock-expired-unlocks',
-- '*/5 * * * *', ...) calls this" but never registered. Register it now,
-- guarded so it is a no-op where pg_cron is absent; cron.schedule upserts by
-- job name so re-running is idempotent.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('relock-expired-unlocks', '*/5 * * * *', 'select public.fn_relock_expired_unlocks();');
  end if;
exception
  when others then null;
end;
$$;
