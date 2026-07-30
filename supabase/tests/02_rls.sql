\pset pager off
\set ON_ERROR_STOP on

-- Supabase grants these automatically; locally we must do it ourselves,
-- and only after the tables exist. Without this we would get "permission
-- denied" and mistake it for row level security doing its job.
grant usage on schema public to anon, authenticated;
grant all on all tables in schema public to anon, authenticated;
grant all on all sequences in schema public to anon, authenticated;
grant select, insert, update, delete on storage.objects to anon, authenticated;

-- Each block below is a real transaction, so SET LOCAL actually binds.
-- `authenticated` is not a superuser and does not own the tables, so
-- row level security genuinely applies to it.

\echo '=== acting as person 2, a stranger to everyone ==='

begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
\echo '-- 9. CAN see public profiles (expect 3)'
select count(*) as profiles_visible from public.profiles;
\echo '-- 10. sees ONLY their own private row, never the other two (expect 1)'
select count(*) as private_visible from public.profile_private;
\echo '-- 11. CANNOT see a friendship they are not in (expect 0)'
select count(*) as friendships_visible from public.friendships;
\echo '-- 12. sees the active ad but not the draft (expect 1)'
select count(*) as ads_visible from public.ads;
\echo '-- 13. CANNOT read another advertiser numbers (expect 0)'
select count(*) as ad_events_visible from public.ad_events;
\echo '-- 14. CANNOT see someone else meetups (expect 0)'
select count(*) as meetups_visible from public.meetups;
\echo '-- 14b. CANNOT see who is attending it either (expect 0)'
select count(*) as participants_visible from public.meetup_participants;
commit;

\echo '-- 15. CANNOT forge a friend request from another user'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  insert into public.friendships (requester_id, addressee_id)
  values ('33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222');
  raise exception 'FAIL: forged a request as another user';
exception when insufficient_privilege then
  raise notice 'PASS: cannot send a request as somebody else';
end $$;
rollback;

\echo '-- 16. CANNOT read someone else private row even by direct id'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as targeted_private_read
from public.profile_private
where id = '11111111-1111-1111-1111-111111111111';
commit;

\echo '-- 17. CANNOT edit another persons profile'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
update public.profiles set display_name = 'hacked'
  where id = '11111111-1111-1111-1111-111111111111';
\echo '   (rows updated should be 0)'
rollback;

\echo '-- 18. search by handle works, and rejects a 1-letter fish'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select handle, friendship_status from public.search_profiles('art');
select count(*) as single_letter_results from public.search_profiles('a');
commit;

\echo ''
\echo '=== acting as person 1, the owner and advertiser ==='

begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\echo '-- 19. CAN see own address (expect 1)'
select count(*) as own_private from public.profile_private;
\echo '-- 20. CAN see own friendship (expect 1)'
select count(*) as own_friendships from public.friendships;
\echo '-- 21. advertiser sees all own ads incl. draft (expect 2)'
select count(*) as own_ads from public.ads;
\echo '-- 22. CAN update own display name (expect 1)'
update public.profiles set display_name='Artie' where id='11111111-1111-1111-1111-111111111111';
\echo '-- 22b. owner sees their own meetup (expect 1)'
select count(*) as own_meetups from public.meetups;
\echo '-- 22c. owner sees both attendees (expect 2)'
select count(*) as own_participants from public.meetup_participants;
commit;

\echo ''
\echo '=== acting as person 3, an invited guest who does not own it ==='
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
\echo '-- 22d. an invited guest CAN see the meetup (expect 1)'
select count(*) as guest_meetups from public.meetups;
\echo '-- 22e. an invited guest CAN see the guest list (expect 2)'
select count(*) as guest_participants from public.meetup_participants;
\echo '-- 22f. an invited guest CANNOT delete the meetup (expect 0 rows)'
delete from public.meetups where id='dddddddd-0000-0000-0000-000000000001';
rollback;

\echo ''
\echo '=== anonymous, nobody signed in ==='
begin;
set local role anon;
\echo '-- 23. anon sees active ads, so the app works logged out (expect 1)'
select count(*) as ads_visible_anon from public.ads;
\echo '-- 24. anon sees places (expect 1)'
select count(*) as places_anon from public.places;
\echo '-- 25. anon sees NO profiles (expect 0)'
select count(*) as profiles_anon from public.profiles;
\echo '-- 26. anon sees NO private rows (expect 0)'
select count(*) as private_anon from public.profile_private;
commit;

\echo ''
\echo '=== done ==='
