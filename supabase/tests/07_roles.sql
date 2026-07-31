\pset pager off

-- Person 1 is an admin (the migration grants it by email, and the
-- fixture email matches nothing, so grant it explicitly here).
-- Person 2 is an ordinary member. Person 3 will apply.
insert into public.user_roles (user_id, role, note)
values ('11111111-1111-1111-1111-111111111111', 'admin', 'test admin')
on conflict (user_id) do update set role = 'admin';

-- Wave 6's fixtures created advertisers for people 1 and 3 back when
-- anyone could. Clear person 3's so the gate can be tested honestly.
delete from public.advertisers where owner_id = '33333333-3333-3333-3333-333333333333';


\echo '=== an ordinary member cannot become an advertiser ==='

\echo '-- 79. member is the default with no row required'
select public.role_of('22222222-2222-2222-2222-222222222222') as person2_role;

\echo '-- 80. a member cannot create an advertiser record'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  insert into public.advertisers (owner_id, business_name)
  values ('22222222-2222-2222-2222-222222222222', 'Sneaky Ads Inc');
  raise exception 'FAIL: a member created an advertiser record';
exception when insufficient_privilege then
  raise notice 'PASS: a member cannot create an advertiser record';
end $$;
rollback;

\echo '-- 81. a member cannot grant themselves a role'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  insert into public.user_roles (user_id, role)
  values ('22222222-2222-2222-2222-222222222222', 'admin');
  raise exception 'FAIL: a member granted themselves admin';
exception when insufficient_privilege then
  raise notice 'PASS: a member cannot grant themselves a role';
end $$;
rollback;

\echo '-- 82. nor call the admin functions'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  perform public.admin_set_role('22222222-2222-2222-2222-222222222222', 'admin');
  raise exception 'FAIL: a member called admin_set_role';
exception when insufficient_privilege then
  raise notice 'PASS: a member cannot call admin_set_role';
end $$;
rollback;

\echo '-- 83. a member sees no pending applications (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as applications_visible from public.admin_list_applications();
commit;


\echo ''
\echo '=== applying, and being approved ==='

\echo '-- 84. person 3 applies'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
insert into public.advertiser_applications (id, user_id, business_name, contact_email, message)
values ('eeeeeeee-0000-0000-0000-000000000001',
        '33333333-3333-3333-3333-333333333333',
        'Jordan Barbers', 'jordan@example.com', 'Cuts on Penn Ave.');
commit;
select business_name, status from public.advertiser_applications
where id = 'eeeeeeee-0000-0000-0000-000000000001';

\echo '-- 85. they cannot apply twice while one is pending'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
do $$
begin
  insert into public.advertiser_applications (user_id, business_name)
  values ('33333333-3333-3333-3333-333333333333', 'Second Try');
  raise exception 'FAIL: a second pending application was allowed';
exception when unique_violation then
  raise notice 'PASS: only one pending application at a time';
end $$;
rollback;

\echo '-- 86. they cannot approve themselves'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
do $$
begin
  perform public.admin_decide_application('eeeeeeee-0000-0000-0000-000000000001', true, null);
  raise exception 'FAIL: applicant approved their own application';
exception when insufficient_privilege then
  raise notice 'PASS: an applicant cannot approve themselves';
end $$;
rollback;

\echo '-- 87. and cannot see anyone else''s application (expect 1, their own)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select count(*) as visible from public.advertiser_applications;
commit;

\echo '-- 88. the admin sees it in the queue'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select business_name, handle, status from public.admin_list_applications();
commit;

\echo '-- 89. the admin approves, which grants the role AND makes the advertiser'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.admin_decide_application('eeeeeeee-0000-0000-0000-000000000001', true, 'Known locally.');
commit;
select
  public.role_of('33333333-3333-3333-3333-333333333333') as new_role,
  (select count(*) from public.advertisers where owner_id = '33333333-3333-3333-3333-333333333333') as advertiser_rows,
  (select status from public.advertiser_applications where id = 'eeeeeeee-0000-0000-0000-000000000001') as application;

\echo '-- 90. deciding it a second time is refused'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
begin
  perform public.admin_decide_application('eeeeeeee-0000-0000-0000-000000000001', false, null);
  raise exception 'FAIL: an application was decided twice';
exception when check_violation then
  raise notice 'PASS: an application cannot be decided twice';
end $$;
rollback;

\echo '-- 91. now approved, they CAN manage their own advertiser record'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
update public.advertisers set contact_phone = '555-0100'
  where owner_id = '33333333-3333-3333-3333-333333333333';
select count(*) as their_advertisers from public.advertisers;
commit;

\echo '-- 92. but still cannot see anybody else''s (expect 1)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select count(*) as advertisers_visible from public.advertisers;
commit;


\echo ''
\echo '=== revoking ==='

\echo '-- 93. the admin demotes them back to member'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.admin_set_role('33333333-3333-3333-3333-333333333333', 'member');
commit;
select public.role_of('33333333-3333-3333-3333-333333333333') as after_revoke;

\echo '-- 94. their advertiser record is now invisible to them (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select count(*) as advertisers_visible from public.advertisers;
commit;

\echo '-- 95. and they can no longer create ads'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
do $$
declare adv uuid;
begin
  select id into adv from public.advertisers limit 1;   -- invisible, so null
  insert into public.ads (advertiser_id, format, headline)
  values (coalesce(adv, 'aaaaaaaa-0000-0000-0000-000000000002'), 'banner', 'Back door');
  raise exception 'FAIL: a demoted advertiser created an ad';
exception
  when insufficient_privilege then raise notice 'PASS: a demoted advertiser cannot create ads';
  when not_null_violation  then raise notice 'PASS: a demoted advertiser cannot create ads';
end $$;
rollback;

\echo '-- 96. an admin cannot strip their own admin access'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
begin
  perform public.admin_set_role('11111111-1111-1111-1111-111111111111', 'member');
  raise exception 'FAIL: admin locked themselves out';
exception when check_violation then
  raise notice 'PASS: an admin cannot remove their own access';
end $$;
rollback;

\echo '-- 97. the admin can still see every advertiser'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select count(*) as all_advertisers from public.advertisers;
commit;

\echo ''
\echo '=== roles done ==='
