-- 20260731999100 revoked TRUNCATE/REFERENCES/TRIGGER from the client roles on
-- every table that existed at the time. Tables created since (the FR-M01
-- outbox) inherited Supabase's default ALL grant again. TRUNCATE ignores RLS,
-- so close the gap now and change the default so it cannot recur.
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke truncate, references, trigger on tables from anon, authenticated;
