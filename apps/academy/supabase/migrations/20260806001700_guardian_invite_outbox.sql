-- Audit BUG-02: queue guardian portal invites in the message outbox (see the function body).
drop function if exists public.send_guardian_invite(uuid, text);
CREATE OR REPLACE FUNCTION public.send_guardian_invite(p_guardian_id uuid, p_channel text, p_base_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_guardian  record;
  v_token     text;
  v_invite_id uuid;
  v_expires   timestamptz := now() + interval '72 hours';
  v_campus_id uuid;
  v_msg_id    uuid;
begin
  if app.auth_role() not in ('admissions_officer', 'owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_channel not in ('whatsapp', 'sms', 'print') then
    raise exception 'CHANNEL_INVALID' using errcode = '22023';
  end if;

  select * into v_guardian from public.guardian where id = p_guardian_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'GUARDIAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_guardian.phone_e164 is null then
    raise exception 'GUARDIAN_PHONE_MISSING' using errcode = '22023';
  end if;
  if v_guardian.auth_user_id is not null then
    raise exception 'GUARDIAN_ALREADY_ACTIVE' using errcode = '55000';
  end if;

  -- A fresh invite supersedes any prior outstanding one for this guardian,
  -- same reasoning as invite_user's own superseding delete.
  delete from public.guardian_invite where guardian_id = p_guardian_id and consumed_at is null;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into public.guardian_invite (tenant_id, guardian_id, token_hash, sent_channel, expires_at, created_by)
  values (v_tenant_id, p_guardian_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), p_channel, v_expires, (select auth.uid()))
  returning id into v_invite_id;

  -- Audit BUG-02: WhatsApp and SMS invites used to be a database row and a success toast, with
  -- nothing sent. The activation link now goes into the message outbox like every other parent
  -- message, against the campus of the guardian's child.
  if p_channel in ('whatsapp', 'sms') and p_base_url is not null then
    select s.campus_id into v_campus_id
      from public.student_guardian sg join public.student s on s.id = sg.student_id
     where sg.guardian_id = p_guardian_id and s.tenant_id = v_tenant_id
     order by s.created_at limit 1;
    if v_campus_id is not null then
      insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, subject, body, status, idempotency_key, metadata)
      values (v_tenant_id, v_campus_id, 'guardian', p_guardian_id, v_guardian.phone_e164, p_channel::public.comm_channel, 'Parent portal invitation',
              format('Assalam o Alaikum %s. Activate your parent portal account here (valid for 72 hours): %s/guardian/activate/%s', v_guardian.name_en, rtrim(p_base_url, '/'), v_token),
              'queued', 'guardian-invite:' || v_invite_id::text,
              jsonb_build_object('template', 'guardian_portal_invite', 'guardian_invite_id', v_invite_id, 'link_expires_at', v_expires))
      returning id into v_msg_id;
    end if;
  end if;

  return jsonb_build_object(
    'queued', v_msg_id is not null,
    'message_id', v_msg_id,
    'invite_id', v_invite_id,
    'token', v_token,
    'phone_e164', v_guardian.phone_e164,
    'guardian_name', v_guardian.name_en,
    'expires_at', v_expires
  );
end;
$function$;

revoke execute on function public.send_guardian_invite(uuid, text, text) from public, anon;
grant execute on function public.send_guardian_invite(uuid, text, text) to authenticated;
