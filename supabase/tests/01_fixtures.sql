\set ON_ERROR_STOP on
\pset pager off

-- Two people sign up. Both emails reduce to the same handle "artie",
-- which is the interesting case.
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'artie@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'artie@other.com'),
  ('33333333-3333-3333-3333-333333333333', 'jordan@example.com');

\echo '--- 1. signup trigger made a profile for everyone, handles deduped ---'
select handle, display_name from public.profiles order by handle;

\echo '--- 2. private row exists for everyone ---'
select count(*) as private_rows from public.profile_private;

-- Give person 1 a home address.
update public.profile_private
  set home_label = '5th Ave, Pittsburgh', home_lat = 40.44, home_lng = -79.99
  where id = '11111111-1111-1111-1111-111111111111';

\echo '--- 3. friendship: 1 asks 3 ---'
insert into public.friendships (requester_id, addressee_id)
values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333');
select status from public.friendships;

\echo '--- 4. the reverse request must be refused (no double friendships) ---'
do $$
begin
  insert into public.friendships (requester_id, addressee_id)
  values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111');
  raise exception 'FAIL: duplicate friendship was allowed';
exception when unique_violation then
  raise notice 'PASS: reverse request correctly blocked';
end $$;

\echo '--- 5. cannot friend yourself ---'
do $$
begin
  insert into public.friendships (requester_id, addressee_id)
  values ('11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');
  raise exception 'FAIL: self-friending was allowed';
exception when check_violation then
  raise notice 'PASS: self-friending correctly blocked';
end $$;

\echo '--- 6. are_friends is false while pending, true once accepted ---'
select public.are_friends(
  '11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333'
) as while_pending;
update public.friendships set status='accepted', responded_at=now();
select public.are_friends(
  '11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333'
) as after_accept;

\echo '--- 7. a bad handle is refused ---'
do $$
begin
  update public.profiles set handle = 'no spaces!' where id='11111111-1111-1111-1111-111111111111';
  raise exception 'FAIL: bad handle accepted';
exception when check_violation then
  raise notice 'PASS: bad handle refused';
end $$;

\echo '--- 8. a sponsored ad with no place attached is refused ---'
insert into public.advertisers (id, owner_id, business_name)
values ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Nicky''s Coffee');
do $$
begin
  insert into public.ads (advertiser_id, format, headline)
  values ('aaaaaaaa-0000-0000-0000-000000000001','sponsored_place','Meet at Nicky''s');
  raise exception 'FAIL: sponsored ad without a place was allowed';
exception when check_violation then
  raise notice 'PASS: sponsored ad requires a place';
end $$;

-- A real place and a real ad on it.
insert into public.places (id, name, category, lat, lng)
values ('bbbbbbbb-0000-0000-0000-000000000001','Nicky''s Coffee','cafe',40.44,-79.99);
insert into public.ads (id, advertiser_id, format, headline, place_id, status)
values ('cccccccc-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'sponsored_place','Meet at Nicky''s','bbbbbbbb-0000-0000-0000-000000000001','active');
-- And one that is still a draft, which nobody should see.
insert into public.ads (id, advertiser_id, format, headline, status)
values ('cccccccc-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001',
        'banner','Secret unlaunched ad','draft');

-- Person 1 plans a meetup and invites person 3 (their friend).
-- Person 2 is not involved and must never see it.
insert into public.meetups (id, owner_id, title, mode, result_lat, result_lng)
values ('dddddddd-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111','Coffee','straight',40.44,-79.99);
insert into public.meetup_participants (meetup_id, user_id, display_name, weight) values
  ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Artie',50),
  ('dddddddd-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','Jordan',50);

\echo '--- fixtures loaded ---'
