-- FR-A14 (immutable audit log), promoting the foundation migration's
-- unattached app.tg_audit_row() into a real audit trail: monthly
-- partitioning, redaction, hard permission-denied writes, and triggers on
-- the tables that exist so far.
--
-- Scope cuts (see foundation.sql's own header for the precedent of noting
-- these rather than silently skipping):
--   * "the DELETE attempt is itself logged" is not implemented — RLS/grant
--     denials happen before any trigger fires, so a rejected statement has
--     nothing in Postgres to hang a log write off of without pgAudit (not
--     enabled in this stack). The denial itself (proven below) is the part
--     that matters; logging denied attempts is a separate, bigger feature.
--   * archive_audit_partition (24-month cold storage) is not implemented —
--     nothing is 24 months old yet.
--   * create_audit_partition() is not on a pg_cron schedule — the DEFAULT
--     partition created below makes that an automation nicety, not a
--     correctness requirement; wire the cron once there's an ops rotation
--     to notice if it silently stops firing.
--   * audit_log's own read policy still checks app.auth_role() in (...),
--     not app.has_permission('audit.read') — FR-A10 shipped the permission
--     mechanism but no module has a populated permission catalogue yet
--     (role_permission is empty for every real tenant). Switching this one
--     check over early, alone, would just be a rewrite with no seeded data
--     behind it; revisit once permissions are actually being granted.

-- audit_log is empty (nothing has ever written to it — the trigger below is
-- the first thing that attaches app.tg_audit_row() to a real table), so
-- recreating it partitioned is a same-migration drop/recreate, not a data
-- migration.
drop table public.audit_log;

create table public.audit_log (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null,
  campus_id       uuid,
  occurred_at     timestamptz not null default now(),
  actor_user_id   uuid,
  actor_role      public.app_role,
  action          public.audit_action not null,
  table_name      text not null,
  row_id          uuid,
  before          jsonb,
  after           jsonb,
  changed_columns text[],
  primary key (id, occurred_at) -- partitioned tables must include the partition key
) partition by range (occurred_at);

create index audit_log_tenant_idx on public.audit_log (tenant_id, occurred_at desc);

create table public.audit_log_default partition of public.audit_log default;

create or replace function public.create_audit_partition(p_month date default date_trunc('month', now())::date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_name  text := 'audit_log_' || to_char(v_start, 'YYYY_MM');
begin
  if not exists (select 1 from pg_catalog.pg_class where relname = v_name) then
    execute format(
      'create table public.%I partition of public.audit_log for values from (%L) to (%L)',
      v_name, v_start, v_end
    );
  end if;
end;
$$;

revoke execute on function public.create_audit_partition(date) from public, anon, authenticated;
grant execute on function public.create_audit_partition(date) to service_role;

-- Partitions for the current month and a couple ahead, so fresh local
-- installs and CI don't rely on the (not yet scheduled) cron having run.
select public.create_audit_partition(date_trunc('month', now())::date);
select public.create_audit_partition((date_trunc('month', now()) + interval '1 month')::date);
select public.create_audit_partition((date_trunc('month', now()) + interval '2 months')::date);

-- ── redaction ──────────────────────────────────────────────────────────

create table public.audit_redacted_column (
  table_name  text not null,
  column_name text not null,
  primary key (table_name, column_name)
);

-- tenant_invitation.token is a bearer secret (whoever holds it can accept
-- the invite) — it must never sit in audit_log's before/after jsonb.
insert into public.audit_redacted_column (table_name, column_name) values ('tenant_invitation', 'token');

create or replace function app.tg_audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_row_id    uuid;
  v_changed   text[];
  v_before    jsonb;
  v_after     jsonb;
  v_redacted  text[];
begin
  v_tenant_id := coalesce(
    (to_jsonb(new)->>'tenant_id')::uuid,
    (to_jsonb(old)->>'tenant_id')::uuid,
    -- tenant itself has no tenant_id column — its own id is the scope.
    case when tg_table_name = 'tenant' then coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid) end
  );
  -- app_user's primary key is user_id, not id — fall back to it generically
  -- rather than special-casing the table name.
  v_row_id := coalesce(
    (to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid,
    (to_jsonb(new)->>'user_id')::uuid, (to_jsonb(old)->>'user_id')::uuid
  );

  if tg_op = 'UPDATE' then
    select array_agg(key) into v_changed
      from jsonb_each(to_jsonb(new))
     where to_jsonb(new)->key is distinct from to_jsonb(old)->key;
  end if;

  select array_agg(column_name) into v_redacted
    from public.audit_redacted_column where table_name = tg_table_name;

  v_before := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_after  := case when tg_op in ('UPDATE', 'INSERT') then to_jsonb(new) else null end;

  if v_redacted is not null then
    if v_before is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_before from jsonb_each(v_before) as t(k, v);
    end if;
    if v_after is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_after from jsonb_each(v_after) as t(k, v);
    end if;
  end if;

  insert into public.audit_log (
    tenant_id, actor_user_id, actor_role, action, table_name, row_id,
    before, after, changed_columns
  ) values (
    v_tenant_id,
    (select auth.uid()),
    nullif(app.auth_role(), 'none')::public.app_role,
    lower(tg_op)::public.audit_action,
    tg_table_name,
    v_row_id,
    v_before,
    v_after,
    v_changed
  );

  return coalesce(new, old);
end;
$$;

create trigger tenant_audit after insert or update or delete on public.tenant
  for each row execute function app.tg_audit_row();
create trigger campus_audit after insert or update or delete on public.campus
  for each row execute function app.tg_audit_row();
create trigger academic_session_audit after insert or update or delete on public.academic_session
  for each row execute function app.tg_audit_row();
create trigger academic_term_audit after insert or update or delete on public.academic_term
  for each row execute function app.tg_audit_row();
create trigger app_user_audit after insert or update or delete on public.app_user
  for each row execute function app.tg_audit_row();
create trigger tenant_invitation_audit after insert or update or delete on public.tenant_invitation
  for each row execute function app.tg_audit_row();
create trigger role_audit after insert or update or delete on public.role
  for each row execute function app.tg_audit_row();

-- ── RLS + hard write denial ───────────────────────────────────────────────

alter table public.audit_log enable row level security;
alter table public.audit_redacted_column enable row level security;

create policy audit_log_tenant_scope on public.audit_log
  for select to authenticated
  using (
    app.auth_role() in ('owner', 'principal', 'super_admin')
    and tenant_id = app.auth_tenant_id()
  );

-- RLS alone leaves INSERT/UPDATE/DELETE as a silent zero-rows no-op once a
-- role has table-level DML privilege but no policy grants it (Supabase's
-- default privileges give authenticated/anon broad table grants and rely on
-- RLS as the only gate). audit_log needs a hard error instead, so writes
-- are revoked at the privilege level too — only the SECURITY DEFINER
-- trigger (running as its owner) can ever insert a row.
revoke insert, update, delete on public.audit_log from authenticated, anon;
