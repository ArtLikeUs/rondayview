\pset pager off

-- Fixtures already have: advertiser "Nicky's Coffee" owned by person 1,
-- one active sponsored_place ad on Nicky's Coffee (40.44, -79.99), and
-- one draft banner that nobody should ever see.

-- Give the ads somewhere to be. The sponsored one covers Pittsburgh;
-- the draft stays a draft.
update public.ads
  set target_lat = 40.44, target_lng = -79.99, target_radius_m = 20000
  where id = 'cccccccc-0000-0000-0000-000000000001';

-- A second advertiser, so we can prove one person cannot read another's numbers.
insert into public.advertisers (id, owner_id, business_name)
values ('aaaaaaaa-0000-0000-0000-000000000002','33333333-3333-3333-3333-333333333333','Jordan Barbers')
on conflict (id) do nothing;

insert into public.ads (id, advertiser_id, format, headline, status, target_lat, target_lng, target_radius_m)
values ('cccccccc-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002',
        'banner','Fresh cuts on Penn Ave','active', 40.44, -79.99, 20000)
on conflict (id) do nothing;

-- An ad that is live but aimed at Los Angeles.
insert into public.ads (id, advertiser_id, format, headline, status, target_lat, target_lng, target_radius_m)
values ('cccccccc-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000001',
        'banner','Only in LA','active', 34.05, -118.25, 20000)
on conflict (id) do nothing;

-- An ad whose run has already finished.
insert into public.ads (id, advertiser_id, format, headline, status, ends_at)
values ('cccccccc-0000-0000-0000-000000000005','aaaaaaaa-0000-0000-0000-000000000001',
        'banner','Last summer''s campaign','active', now() - interval '1 day')
on conflict (id) do nothing;


\echo '=== who gets served, standing in Pittsburgh ==='

\echo '-- 41. an anonymous visitor is served ads (the app works logged out)'
begin;
set local role anon;
select headline from public.serve_ads(40.44, -79.99) order by headline;
commit;

\echo '-- 42. the draft, the LA ad and the ended campaign are all absent above'

\echo '-- 43. standing in Los Angeles instead, the Pittsburgh ads drop out'
begin;
set local role anon;
select headline from public.serve_ads(34.05, -118.25) order by headline;
commit;

\echo '-- 44. asking for one format only'
begin;
set local role anon;
select headline, format from public.serve_ads(40.44, -79.99, array['sponsored_place']);
commit;

\echo '-- 45. a sponsored place brings its venue along'
begin;
set local role anon;
select headline, place_name, place_lat is not null as has_point
from public.serve_ads(40.44, -79.99, array['sponsored_place']);
commit;


\echo ''
\echo '=== the daily cap ==='

update public.ads set daily_impression_cap = 2
  where id = 'cccccccc-0000-0000-0000-000000000003';

\echo '-- 46. capped ad is served while under its allowance (expect 1)'
begin;
set local role anon;
select count(*) as visible from public.serve_ads(40.44, -79.99, array['banner']);
commit;

begin;
set local role anon;
select public.record_ad_event('cccccccc-0000-0000-0000-000000000003','impression', 40.44, -79.99);
select public.record_ad_event('cccccccc-0000-0000-0000-000000000003','impression', 40.44, -79.99);
commit;

\echo '-- 47. once its allowance is used up it stops being served (expect 0)'
begin;
set local role anon;
select count(*) as visible from public.serve_ads(40.44, -79.99, array['banner']);
commit;

\echo '-- 48. an unknown event kind is refused'
begin;
set local role anon;
do $$
begin
  perform public.record_ad_event('cccccccc-0000-0000-0000-000000000003','freebie');
  raise exception 'FAIL: bogus event kind accepted';
exception when check_violation then
  raise notice 'PASS: bogus event kind refused';
end $$;
rollback;

\echo '-- 49. events for an ended campaign are ignored, not billed (expect 0)'
begin;
set local role anon;
select public.record_ad_event('cccccccc-0000-0000-0000-000000000005','impression');
commit;
select count(*) as billed_after_end
from public.ad_events where ad_id = 'cccccccc-0000-0000-0000-000000000005';


\echo ''
\echo '=== whose numbers are whose ==='

\echo '-- 50. person 1 sees only their OWN ads in performance'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select headline, impressions, clicks from public.ad_performance() order by headline;
commit;

\echo '-- 51. person 3 sees only theirs — including the 2 impressions above'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select headline, impressions, clicks from public.ad_performance();
commit;

\echo '-- 52. a stranger with no advertiser sees nothing (expect 0 rows)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as rows_seen from public.ad_performance();
commit;

\echo '-- 53. and anon cannot call ad_performance at all'
begin;
set local role anon;
do $$
begin
  perform * from public.ad_performance();
  raise exception 'FAIL: anon read advertiser numbers';
exception when insufficient_privilege then
  raise notice 'PASS: anon cannot read advertiser numbers';
end $$;
rollback;

\echo '-- 54. person 2 still cannot read the raw ad_events table (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select count(*) as raw_events_visible from public.ad_events;
commit;

\echo ''
\echo '=== ads done ==='
