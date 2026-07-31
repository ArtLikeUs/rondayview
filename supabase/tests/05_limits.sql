\pset pager off

-- The Edge Function calls these as service_role. Nothing reachable from
-- a browser should be able to touch them at all.

\echo '=== rate limiting ==='

\echo '-- 55. the first hits are allowed, the one past the limit is not'
select public.rate_limit_hit('test:1.2.3.4', 3, 3600) as hit_1;
select public.rate_limit_hit('test:1.2.3.4', 3, 3600) as hit_2;
select public.rate_limit_hit('test:1.2.3.4', 3, 3600) as hit_3;
select public.rate_limit_hit('test:1.2.3.4', 3, 3600) as hit_4_should_be_false;

\echo '-- 56. a different caller is unaffected (expect true)'
select public.rate_limit_hit('test:9.9.9.9', 3, 3600) as other_caller;

\echo '-- 57. a different job for the same caller is counted separately'
select public.rate_limit_hit('venues:1.2.3.4', 3, 3600) as other_job;

\echo '-- 58. once the window has passed the count restarts (expect true)'
update public.rate_limits set window_start = now() - interval '2 hours'
  where bucket = 'test:1.2.3.4';
select public.rate_limit_hit('test:1.2.3.4', 3, 3600) as after_window;
select hits as hits_reset_to from public.rate_limits where bucket = 'test:1.2.3.4';

\echo '-- 59. the sweep clears only stale rows'
insert into public.rate_limits (bucket, window_start, hits)
values ('test:stale', now() - interval '3 days', 5)
on conflict (bucket) do update set window_start = now() - interval '3 days';
select public.rate_limits_sweep();
select
  (select count(*) from public.rate_limits where bucket = 'test:stale') as stale_left,
  (select count(*) from public.rate_limits where bucket = 'test:1.2.3.4') as fresh_kept;


\echo ''
\echo '=== geocode cache ==='

\echo '-- 60. a miss returns nothing'
select coalesce(public.geocode_lookup('s:nowhere at all'), 'null'::jsonb) as miss;

\echo '-- 61. store then read it back'
select public.geocode_store('s:pittsburgh', 'search', '[{"lat":"40.44","lon":"-79.99"}]'::jsonb);
select public.geocode_lookup('s:pittsburgh') as hit;

\echo '-- 62. storing the same key again replaces rather than duplicates'
select public.geocode_store('s:pittsburgh', 'search', '[{"lat":"40.45","lon":"-79.98"}]'::jsonb);
select public.geocode_lookup('s:pittsburgh') as replaced;
select count(*) as rows_for_key from public.geocode_cache where q = 's:pittsburgh';

\echo '-- 63. an entry older than 180 days is treated as a miss'
update public.geocode_cache set created_at = now() - interval '200 days' where q = 's:pittsburgh';
select coalesce(public.geocode_lookup('s:pittsburgh'), 'null'::jsonb) as expired;


\echo ''
\echo '=== nobody but service_role may call any of this ==='

\echo '-- 64. anon cannot count a request'
begin;
set local role anon;
do $$
begin
  perform public.rate_limit_hit('forged', 1, 60);
  raise exception 'FAIL: anon called rate_limit_hit';
exception when insufficient_privilege then
  raise notice 'PASS: anon cannot call rate_limit_hit';
end $$;
rollback;

\echo '-- 65. a signed-in user cannot either'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
begin
  perform public.rate_limit_hit('forged', 1, 60);
  raise exception 'FAIL: authenticated called rate_limit_hit';
exception when insufficient_privilege then
  raise notice 'PASS: authenticated cannot call rate_limit_hit';
end $$;
rollback;

\echo '-- 66. and cannot read the counters directly (expect 0)'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select count(*) as counters_visible from public.rate_limits;
select count(*) as cache_visible from public.geocode_cache;
commit;

\echo '-- 67. nor write to the cache'
begin;
set local role authenticated;
set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
begin
  insert into public.geocode_cache (q, results) values ('poison', '[]'::jsonb);
  raise exception 'FAIL: authenticated wrote to the geocode cache';
exception when insufficient_privilege then
  raise notice 'PASS: authenticated cannot write to the cache';
end $$;
rollback;

\echo ''
\echo '=== limits done ==='
