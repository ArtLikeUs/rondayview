\pset pager off

-- Fixtures already have an active banner from wave 4's tests:
-- 'cccccccc-0000-0000-0000-000000000003', owned by person 3.

\echo '=== the browser can no longer write to the tally ==='

\echo '-- 68. anon cannot insert an ad event directly'
begin;
set local role anon;
do $$
begin
  insert into public.ad_events (ad_id, event)
  values ('cccccccc-0000-0000-0000-000000000003', 'impression');
  raise exception 'FAIL: anon inserted an ad event';
exception when insufficient_privilege then
  raise notice 'PASS: anon cannot insert an ad event';
end $$;
rollback;

\echo '-- 69. nor can a signed-in user'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  insert into public.ad_events (ad_id, event)
  values ('cccccccc-0000-0000-0000-000000000003', 'impression');
  raise exception 'FAIL: authenticated inserted an ad event';
exception when insufficient_privilege then
  raise notice 'PASS: authenticated cannot insert an ad event';
end $$;
rollback;

\echo '-- 70. and neither can call record_ad_event any more'
begin;
set local role anon;
do $$
begin
  perform public.record_ad_event('cccccccc-0000-0000-0000-000000000003', 'impression');
  raise exception 'FAIL: anon called record_ad_event';
exception when insufficient_privilege then
  raise notice 'PASS: anon cannot call record_ad_event';
end $$;
rollback;

\echo '-- 71. nor ad_event_is_new'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
begin
  perform public.ad_event_is_new('cccccccc-0000-0000-0000-000000000003', 'impression', 'x');
  raise exception 'FAIL: authenticated called ad_event_is_new';
exception when insufficient_privilege then
  raise notice 'PASS: authenticated cannot call ad_event_is_new';
end $$;
rollback;


\echo ''
\echo '=== a reload is not an audience ==='

-- Clear anything wave 4's tests left behind.
delete from public.ad_events where ad_id = 'cccccccc-0000-0000-0000-000000000003';
delete from public.rate_limits where bucket like 'adevent:%';
update public.ads set daily_impression_cap = null
  where id = 'cccccccc-0000-0000-0000-000000000003';

\echo '-- 72. the same person seeing it twice counts once'
select public.ad_event_is_new('cccccccc-0000-0000-0000-000000000003','impression','1.2.3.4') as first_time;
select public.ad_event_is_new('cccccccc-0000-0000-0000-000000000003','impression','1.2.3.4') as same_person_again;

\echo '-- 73. a different person counts (expect true)'
select public.ad_event_is_new('cccccccc-0000-0000-0000-000000000003','impression','5.6.7.8') as different_person;

\echo '-- 74. a click from the same person is tracked separately from the view'
select public.ad_event_is_new('cccccccc-0000-0000-0000-000000000003','click','1.2.3.4') as their_click;

\echo '-- 75. a different ad is tracked separately'
select public.ad_event_is_new('cccccccc-0000-0000-0000-000000000001','impression','1.2.3.4') as other_ad;

\echo '-- 76. once the window passes, the same person counts again'
update public.rate_limits set window_start = now() - interval '2 hours'
  where bucket = 'adevent:impression:cccccccc-0000-0000-0000-000000000003:1.2.3.4';
select public.ad_event_is_new('cccccccc-0000-0000-0000-000000000003','impression','1.2.3.4') as after_window;


\echo ''
\echo '=== the advertiser can still read their own totals ==='

-- Record what the Edge Function would have recorded above.
select public.record_ad_event('cccccccc-0000-0000-0000-000000000003','impression');
select public.record_ad_event('cccccccc-0000-0000-0000-000000000003','click');

\echo '-- 77. person 3 sees their own numbers'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select headline, impressions, clicks from public.ad_performance();
commit;

\echo '-- 78. person 1 still cannot see person 3''s numbers'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select count(*) as person3_rows_visible
from public.ad_performance() where headline = 'Fresh cuts on Penn Ave';
commit;

\echo ''
\echo '=== ad counting done ==='
