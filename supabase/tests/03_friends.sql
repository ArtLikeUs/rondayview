\pset pager off

-- Fixtures already have: person 1 (artie) and person 3 (jordan) accepted
-- friends; person 2 a stranger to both.

\echo '=== consent: only the addressee may accept ==='

-- Person 2 sends person 3 a request.
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into public.friendships (id, requester_id, addressee_id)
values ('ffffffff-0000-0000-0000-000000000001',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333');
commit;

\echo '-- 27. the SENDER must not be able to accept their own request'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  update public.friendships set status = 'accepted'
    where id = 'ffffffff-0000-0000-0000-000000000001';
  raise exception 'FAIL: the sender accepted their own friend request';
exception when insufficient_privilege then
  raise notice 'PASS: sender cannot accept their own request';
end $$;
rollback;

\echo '-- 28. a total stranger must not be able to accept it either'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
update public.friendships set status = 'accepted'
  where id = 'ffffffff-0000-0000-0000-000000000001';
\echo '   (rows updated should be 0 — person 1 cannot even see this row)'
rollback;

\echo '-- 29. the ADDRESSEE can accept, and responded_at is stamped'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
update public.friendships set status = 'accepted'
  where id = 'ffffffff-0000-0000-0000-000000000001';
commit;
select status, (responded_at is not null) as stamped
from public.friendships where id = 'ffffffff-0000-0000-0000-000000000001';

\echo '-- 30. an accepted friendship cannot be quietly reverted to pending'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
do $$
begin
  update public.friendships set status = 'pending'
    where id = 'ffffffff-0000-0000-0000-000000000001';
  raise exception 'FAIL: accepted friendship reverted to pending';
exception when check_violation then
  raise notice 'PASS: cannot revert an accepted friendship';
end $$;
rollback;

\echo '-- 31. a friendship cannot be re-pointed at somebody else'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
do $$
begin
  update public.friendships set addressee_id = '11111111-1111-1111-1111-111111111111'
    where id = 'ffffffff-0000-0000-0000-000000000001';
  raise exception 'FAIL: friendship was re-pointed at another person';
exception when check_violation then
  raise notice 'PASS: cannot re-point a friendship';
end $$;
rollback;


\echo ''
\echo '=== sharing a starting point ==='

\echo '-- 32. sharing is OFF by default for everyone (expect 0)'
select count(*) as sharing_by_default
from public.profile_private where share_home_with_friends;

\echo '-- 33. a friend gets nothing while sharing is off (expect 0 rows)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select count(*) as rows_returned from public.friend_origin('11111111-1111-1111-1111-111111111111');
commit;

-- Person 1 turns sharing on.
update public.profile_private set share_home_with_friends = true
  where id = '11111111-1111-1111-1111-111111111111';

\echo '-- 34. now the FRIEND gets the point, with a coarsened label (expect 1 row)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select lat, lng, label from public.friend_origin('11111111-1111-1111-1111-111111111111');
commit;

\echo '-- 35. a NON-friend still gets nothing, sharing on or not (expect 0 rows)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as rows_returned from public.friend_origin('11111111-1111-1111-1111-111111111111');
commit;

\echo '-- 36. and an anonymous visitor cannot call it at all'
begin;
set local role anon;
do $$
begin
  perform * from public.friend_origin('11111111-1111-1111-1111-111111111111');
  raise exception 'FAIL: anon called friend_origin';
exception when insufficient_privilege then
  raise notice 'PASS: anon cannot call friend_origin';
end $$;
rollback;

\echo '-- 37. profile_private is STILL unreadable directly, sharing or not (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select count(*) as direct_read
from public.profile_private where id = '11111111-1111-1111-1111-111111111111';
commit;


\echo ''
\echo '=== reading your friends ==='

\echo '-- 38. person 3 has two friends now: person 1 and person 2'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select handle, shares_home from public.my_friends();
commit;

\echo '-- 39. person 2 sees one friend and no pending requests'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select handle from public.my_friends();
select count(*) as pending from public.my_friend_requests();
commit;

\echo '-- 40. direction is reported from the asker''s point of view'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into public.friendships (requester_id, addressee_id)
values ('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222');
select direction, handle from public.my_friend_requests();
commit;

begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '   (person 2 should see the same request as incoming)'
select direction, handle from public.my_friend_requests();
commit;

\echo ''
\echo '=== friends done ==='
