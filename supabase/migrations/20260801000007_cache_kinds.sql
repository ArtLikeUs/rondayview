-- ============================================================
-- We Rondayview — let the cache hold more than addresses
--
-- Venue lookups and road checks are the slowest thing in the app by a
-- wide margin: measured live, a venue lookup took 48 seconds and a road
-- check 40, because every Overpass mirror was busy and they were tried
-- one after another. Caching them is the difference between a search
-- that feels instant the second time and one that feels broken.
--
-- Different answers go stale at different speeds, so the lookup now
-- takes a maximum age. An address is good for months. A list of cafes
-- is not — places close.
--
-- Safe to re-run.
-- ============================================================

alter table public.geocode_cache drop constraint if exists geocode_kind;
alter table public.geocode_cache add constraint geocode_kind
  check (kind in ('search', 'reverse', 'venues', 'road'));

-- Signature change, so the old one has to go first.
drop function if exists public.geocode_lookup(text);

create or replace function public.geocode_lookup(key text, max_age_days integer default 180)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select results
  from public.geocode_cache
  where q = key
    and created_at > now() - make_interval(days => greatest(coalesce(max_age_days, 180), 1));
$$;

revoke all on function public.geocode_lookup(text, integer) from public, anon, authenticated;
grant execute on function public.geocode_lookup(text, integer) to service_role;
