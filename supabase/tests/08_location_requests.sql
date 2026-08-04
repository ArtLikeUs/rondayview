\pset pager off

\echo '=== asking ==='

\echo '-- 98. person 1 makes a request; a token is generated'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into public.location_requests (id, owner_id, title)
values ('a1a1a1a1-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'Saturday coffee');
commit;
select title, char_length(token) as token_len, status
from public.location_requests where id = 'a1a1a1a1-0000-0000-0000-000000000001';

-- Capture the token the way a recipient gets it: handed over, not queried.
select token as tok1 from public.location_requests
where id = 'a1a1a1a1-0000-0000-0000-000000000001' \gset

\echo '-- 99. a stranger cannot see the request row (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as visible from public.location_requests;
commit;

\echo '-- 100. nor make one in somebody else''s name'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  insert into public.location_requests (owner_id, title)
  values ('11111111-1111-1111-1111-111111111111', 'forged');
  raise exception 'FAIL: forged a request as another user';
exception when insufficient_privilege then
  raise notice 'PASS: cannot make a request as somebody else';
end $$;
rollback;


\echo ''
\echo '=== answering, with no account ==='

\echo '-- 101. the link tells you who is asking, and nothing else'
begin;
set local role anon;
select title, asked_by, is_open, already_in from public.location_request_info(:'tok1');
commit;

\echo '-- 102. a signed-out person can answer'
begin;
set local role anon;
select public.submit_shared_location(:'tok1', 'Deebo', 40.4381, -79.9222, 'Squirrel Hill') as first_answer;
commit;
select display_name, label from public.location_shares
where request_id='a1a1a1a1-0000-0000-0000-000000000001';

\echo '-- 103. a bad token is refused'
begin;
set local role anon;
do $$
begin
  perform public.submit_shared_location('not-a-real-token','Sneak',40.0,-79.0,null);
  raise exception 'FAIL: a bogus token was accepted';
exception when no_data_found then
  raise notice 'PASS: a bogus token is refused';
end $$;
rollback;

\echo '-- 104. nonsense coordinates are refused'
begin;
do $$
begin
  perform public.submit_shared_location((select token from public.location_requests where id='a1a1a1a1-0000-0000-0000-000000000001'), 'Nowhere', 999, 999, null);
  raise exception 'FAIL: impossible coordinates accepted';
exception when check_violation then
  raise notice 'PASS: impossible coordinates refused';
end $$;
rollback;

\echo '-- 105. the trip seats three answers, and no more'
begin;
set local role anon;
select public.submit_shared_location(:'tok1', 'Nige', 40.45, -80.00, null);
select public.submit_shared_location(:'tok1', 'Kamayah', 40.46, -79.95, null);
commit;
begin;
do $$
begin
  perform public.submit_shared_location((select token from public.location_requests where id='a1a1a1a1-0000-0000-0000-000000000001'), 'One too many', 40.47, -79.94, null);
  raise exception 'FAIL: a fourth answer was accepted';
exception when check_violation then
  raise notice 'PASS: the fourth answer is refused';
end $$;
rollback;

\echo '-- 106. an anonymous visitor cannot READ the answers (expect 0)'
begin;
set local role anon;
select count(*) as answers_visible from public.location_shares;
commit;

\echo '-- 107. nor can another signed-in user (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as answers_visible from public.location_shares;
commit;

\echo '-- 108. the person who asked sees all three'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select count(*) as answers_visible from public.location_shares;
commit;

\echo '-- 109. a closed request stops accepting answers'
update public.location_requests set status='closed'
  where id='a1a1a1a1-0000-0000-0000-000000000001';
begin;
do $$
begin
  perform public.submit_shared_location((select token from public.location_requests where id='a1a1a1a1-0000-0000-0000-000000000001'), 'Too late', 40.44, -79.99, null);
  raise exception 'FAIL: a closed request accepted an answer';
exception when check_violation then
  raise notice 'PASS: a closed request refuses answers';
end $$;
rollback;

\echo '-- 110. so does an expired one'
insert into public.location_requests (id, owner_id, title, expires_at)
values ('a1a1a1a1-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111', 'Old one', now() - interval '1 day');
select token as tok2 from public.location_requests
where id = 'a1a1a1a1-0000-0000-0000-000000000002' \gset
begin;
do $$
begin
  perform public.submit_shared_location((select token from public.location_requests where id='a1a1a1a1-0000-0000-0000-000000000002'), 'Too late', 40.44, -79.99, null);
  raise exception 'FAIL: an expired request accepted an answer';
exception when check_violation then
  raise notice 'PASS: an expired request refuses answers';
end $$;
rollback;


\echo ''
\echo '=== being asked in the app ==='

insert into public.location_requests (id, owner_id, title, invited_user_id)
values ('a1a1a1a1-0000-0000-0000-000000000003',
        '11111111-1111-1111-1111-111111111111', 'Lunch', '33333333-3333-3333-3333-333333333333');
select token as tok3 from public.location_requests
where id = 'a1a1a1a1-0000-0000-0000-000000000003' \gset

\echo '-- 111. the invited friend sees the ask'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select title, asked_by from public.my_location_asks();
commit;

\echo '-- 112. an uninvolved person sees nothing (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as asks from public.my_location_asks();
commit;

\echo '-- 113. once answered, the ask disappears (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.submit_shared_location(:'tok3', 'Jordan', 40.4553, -80.0088, 'North Side');
select count(*) as asks_left from public.my_location_asks();
commit;

\echo ''
\echo '=== location requests done ==='
