-- `supabase db push` to a hosted project connects as a temporary login role whose
-- search_path lacks the `extensions` schema, where hosted Supabase installs pgcrypto,
-- and it runs RESET ALL before every migration. The foundation migration's unqualified
-- gen_random_bytes() default then fails to resolve. A database-level default survives
-- RESET ALL; it takes effect from the next connection.
do $$
begin
  execute format('alter database %I set search_path = "$user", public, extensions', current_database());
end $$;
