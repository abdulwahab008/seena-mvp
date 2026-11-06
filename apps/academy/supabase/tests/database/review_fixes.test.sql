-- pgTAP tests for the code review of the audit fixes: guardians are matched on phone and name,
-- a zero-fee walk-in takes no receipt number, editing a student keeps the father's Urdu name,
-- and invitations are managed under the same rules as invite_user.
begin;
select plan(11);

select public.provision_tenant('test-review-fix', 'Review Fix School', 'owner@reviewfix.test');
select id as tenant_id from public.tenant where slug = 'test-review-fix' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_id \gset
select gen_random_uuid() as principal_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_id', 'boss@reviewfix.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'principal_id', 'head@reviewfix.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_id', :'tenant_id', 'owner', 'Boss'), (:'principal_id', :'tenant_id', 'principal', 'Head');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'principal_id', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_id')::text, true);
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class1_id', p_name => 'A', p_capacity => 30) as section_id \gset

-- Guardians: same phone, different parent name → two families, not one.
select public.fn_quick_admission(:'campus_id'::uuid, :'session_id'::uuid, 'Kid One', '2019-01-01', 'male', :'class1_id'::uuid, :'section_id'::uuid,
       'Asif Ali', '+923335552001', 0, 'cash') as a1 \gset
select public.fn_quick_admission(:'campus_id'::uuid, :'session_id'::uuid, 'Kid Two', '2019-01-01', 'female', :'class1_id'::uuid, :'section_id'::uuid,
       'Bilal Shah', '+923335552001', 0, 'cash') as a2 \gset
-- A phone that is not a mobile number links no guardian at all.
select public.fn_quick_admission(:'campus_id'::uuid, :'session_id'::uuid, 'Kid Three', '2019-01-01', 'male', :'class1_id'::uuid, :'section_id'::uuid,
       'Chand Bibi', '123', 0, 'cash') as a3 \gset
reset role;

select is((select count(*)::int from public.guardian where tenant_id = :'tenant_id'::uuid and phone_e164 = '+923335552001'), 2,
  'a parent with a different name on a shared phone gets their own guardian record');
select is((select g.name_en from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
            where sg.student_id = (:'a2'::jsonb ->> 'student_id')::uuid), 'Bilal Shah',
  'and the second child is linked to their own parent');
select is((select count(*)::int from public.student_guardian where student_id = (:'a3'::jsonb ->> 'student_id')::uuid), 0,
  'an invalid phone links no guessed guardian');

-- Zero-fee walk-ins take no number from the receipt series.
select is((select coalesce(max(last_no), 0)::int from public.fee_receipt_counter where campus_id = :'campus_id'::uuid), 0,
  'three zero-fee walk-ins used no receipt numbers');

-- Editing a student keeps the father's Urdu name the form does not show.
update public.student set father_name_ur = 'آصف علی' where id = (:'a1'::jsonb ->> 'student_id')::uuid;
set local role authenticated;
select public.update_student_details((:'a1'::jsonb ->> 'student_id')::uuid, 'Kid One Fixed', '2019-01-02', 'male');
reset role;
select is((select father_name_ur from public.student where id = (:'a1'::jsonb ->> 'student_id')::uuid), 'آصف علی',
  'editing a student keeps the father''s Urdu name');

-- Invitations: a principal cannot act on an owner invitation they could not have created.
set local role authenticated;
select public.invite_user('coowner@reviewfix.test', 'owner', '{}') as owner_invite \gset
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'principal_id')::text, true);
select is(public.can_manage_invitation(:'owner_invite'::uuid), false, 'a principal cannot see or resend an owner invitation');
select throws_ok(format('select public.revoke_invitation(%L)', :'owner_invite'), '42501', 'FORBIDDEN', 'nor revoke it');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_id')::text, true);
select public.revoke_invitation(:'owner_invite'::uuid);
reset role;
select is((select count(*)::int from public.tenant_invitation where id = :'owner_invite'::uuid), 0, 'the owner can revoke it');

-- A paid walk-in with a bank reference keeps the reference and still gets a series receipt
-- number; with no ADMISSION head in the school, enrolment adds one.
reset role;
delete from public.fee_head where tenant_id = :'tenant_id'::uuid and lower(code) = 'admission';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_id')::text, true);
select public.fn_quick_admission(:'campus_id'::uuid, :'session_id'::uuid, 'Kid Four', '2019-01-01', 'male', :'class1_id'::uuid, :'section_id'::uuid,
       'Dawood Khan', '+923335552004', 5000, 'bank_challan', 'TRX-778899') as a4 \gset
reset role;
select is((select reference_no || ' / ' || receipt_no from public.admission_fee_payment where offer_id = (:'a4'::jsonb ->> 'offer_id')::uuid),
  'TRX-778899 / ' || (:'a4'::jsonb ->> 'receipt_no'),
  'the payer reference is kept and the receipt number comes from the series');
select isnt((:'a4'::jsonb ->> 'receipt_no'), 'TRX-778899', 'the receipt number is not the payer reference');
select is((select h.code from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id
            where l.enrolment_id = (:'a4'::jsonb ->> 'enrolment_id')::uuid and l.entry_type = 'charge'), 'ADMISSION',
  'with no ADMISSION head, enrolment adds one and charges under it');

select * from finish();
rollback;
