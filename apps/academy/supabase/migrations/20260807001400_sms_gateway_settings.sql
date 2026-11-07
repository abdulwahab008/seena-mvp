-- Real SMS sending, part 1: each school's SMS gateway settings.
--
-- A school enters its gateway's URL, the parameter names it expects, its
-- sender mask and API key (lib/comm/http-sms.ts explains why that covers the
-- Pakistani branded-SMS providers). The API key goes into Supabase Vault and
-- never comes back to the browser: sms_gateway_settings() only says whether
-- one is saved. The message worker (service role) reads it with
-- sms_gateway_for_dispatch().

insert into public.comm_provider (code, name, channel, default_priority)
values ('http_sms', 'SMS gateway (HTTP)', 'sms', 1)
on conflict (code) do nothing;

create or replace function public.save_sms_gateway(p_sender_id text, p_config jsonb, p_api_key text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_provider  uuid := (select id from public.comm_provider where code = 'http_sms');
  v_name      text;
  v_secret    uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if coalesce(p_config ->> 'url', '') !~ '^https://' then
    raise exception 'URL_INVALID' using errcode = '22023', hint = 'The gateway URL must start with https://';
  end if;
  if coalesce(p_config ->> 'method', '') not in ('GET', 'POST')
     or coalesce(p_config ->> 'keyParam', '') = '' or coalesce(p_config ->> 'senderParam', '') = ''
     or coalesce(p_config ->> 'toParam', '') = '' or coalesce(p_config ->> 'textParam', '') = '' then
    raise exception 'CONFIG_INVALID' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_sender_id, '')), '') is null then
    raise exception 'SENDER_REQUIRED' using errcode = '22023';
  end if;

  v_name := 'sms_gateway_' || v_tenant_id;
  if nullif(p_api_key, '') is not null then
    select id into v_secret from vault.secrets where name = v_name;
    if v_secret is null then
      perform vault.create_secret(p_api_key, v_name, 'SMS gateway API key');
    else
      perform vault.update_secret(v_secret, p_api_key);
    end if;
  elsif not exists (select 1 from vault.secrets where name = v_name) then
    raise exception 'API_KEY_REQUIRED' using errcode = '22023';
  end if;

  insert into public.comm_provider_credential (tenant_id, provider_id, credential_vault_ref, sender_id, config, is_active)
  values (v_tenant_id, v_provider, v_name, btrim(p_sender_id), p_config, true)
  on conflict (tenant_id, provider_id) do update
     set credential_vault_ref = excluded.credential_vault_ref, sender_id = excluded.sender_id,
         config = excluded.config, is_active = true, updated_at = clock_timestamp();
end;
$$;
revoke execute on function public.save_sms_gateway(text, jsonb, text) from public, anon;
grant execute on function public.save_sms_gateway(text, jsonb, text) to authenticated;

create or replace function public.sms_gateway_settings()
returns table (sender_id text, config jsonb, has_key boolean, is_active boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.sender_id, c.config, exists (select 1 from vault.secrets s where s.name = c.credential_vault_ref), c.is_active
    from public.comm_provider_credential c
    join public.comm_provider p on p.id = c.provider_id and p.code = 'http_sms'
   where c.tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner');
$$;
revoke execute on function public.sms_gateway_settings() from public, anon;
grant execute on function public.sms_gateway_settings() to authenticated;

create or replace function public.sms_gateway_for_dispatch(p_tenant_id uuid)
returns table (provider_id uuid, sender_id text, config jsonb, api_key text)
language sql
stable
security definer
set search_path = ''
as $$
  select c.provider_id, c.sender_id, c.config, s.decrypted_secret
    from public.comm_provider_credential c
    join public.comm_provider p on p.id = c.provider_id and p.code = 'http_sms'
    join vault.decrypted_secrets s on s.name = c.credential_vault_ref
   where c.tenant_id = p_tenant_id and c.is_active;
$$;
revoke execute on function public.sms_gateway_for_dispatch(uuid) from public, anon, authenticated;
grant execute on function public.sms_gateway_for_dispatch(uuid) to service_role;
