-- ============================================================
-- We Rondayview — rate limiting and a geocode cache
--
-- Both exist because the app is public now. The routing function's
-- address is in the page source and it has to accept unauthenticated
-- calls, so the only thing standing between a bored person and your
-- 2,500 daily OpenRouteService lookups is what is in this file.
--
-- The cache is the other half: address lookups used to go from every
-- visitor's browser straight to OpenStreetMap's Nominatim, which is a
-- volunteer service that asks for one request a second from an
-- identifiable application. Answering repeats from our own copy is the
-- polite version, and the fast one.
--
-- Nothing here is reachable from a browser. Both functions are granted
-- to service_role only, which is the key the Edge Function holds and
-- the page never sees.
--
-- Safe to re-run.
-- ============================================================


-- ------------------------------------------------------------
-- Counters
--
-- One row per caller per kind of request. A row is not a person; it is
-- an address and a verb, and it is thrown away once it goes quiet.
-- ------------------------------------------------------------
create table if not exists public.rate_limits (
  bucket       text primary key,
  window_start timestamptz not null default now(),
  hits         integer     not null default 0
);

create index if not exists rate_limits_window_idx on public.rate_limits (window_start);

alter table public.rate_limits enable row level security;
-- Deliberately no policies at all. With row level security on and
-- nothing granted, the only thing that can read or write this table is
-- service_role, which bypasses it.


-- Count one hit and say whether it is allowed.
--
-- Returns true to let the request through. The whole thing is a single
-- upsert so two requests arriving together cannot both read "0" and
-- both decide they are fine.
create or replace function public.rate_limit_hit(
  bucket_key     text,
  max_hits       integer,
  window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  row_after public.rate_limits%rowtype;
begin
  insert into public.rate_limits as r (bucket, window_start, hits)
  values (bucket_key, now(), 1)
  on conflict (bucket) do update
    set hits = case
                 when r.window_start < now() - make_interval(secs => window_seconds)
                 then 1
                 else r.hits + 1
               end,
        window_start = case
                 when r.window_start < now() - make_interval(secs => window_seconds)
                 then now()
                 else r.window_start
               end
  returning * into row_after;

  return row_after.hits <= max_hits;
end;
$$;


-- Housekeeping. Called occasionally by the Edge Function rather than
-- on a schedule, so there is nothing extra to set up or forget.
create or replace function public.rate_limits_sweep()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.rate_limits where window_start < now() - interval '1 day';
$$;


-- ------------------------------------------------------------
-- Geocode cache
--
-- Addresses do not move. Asking a volunteer-run service the same
-- question twice is rude and slow, so answers are kept.
--
-- Note what is stored: a search phrase and its coordinates. Not who
-- searched it, not when they searched it, and nothing tying it to an
-- account. It is a dictionary, not a history.
-- ------------------------------------------------------------
create table if not exists public.geocode_cache (
  q          text primary key,
  kind       text not null default 'search',
  results    jsonb not null,
  created_at timestamptz not null default now(),

  constraint geocode_kind check (kind in ('search', 'reverse'))
);

create index if not exists geocode_cache_age_idx on public.geocode_cache (created_at);

alter table public.geocode_cache enable row level security;
-- Same as above: no policies, so only service_role reaches it.


create or replace function public.geocode_lookup(key text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select results
  from public.geocode_cache
  where q = key
    -- Places close and get renamed. Six months is long enough to save
    -- the round trip and short enough that the answer is still true.
    and created_at > now() - interval '180 days';
$$;


create or replace function public.geocode_store(key text, kind_in text, payload jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.geocode_cache (q, kind, results, created_at)
  values (key, kind_in, payload, now())
  on conflict (q) do update
    set results = excluded.results,
        kind = excluded.kind,
        created_at = now();
$$;


-- ------------------------------------------------------------
-- Who may call these
--
-- Nobody, except the key the Edge Function holds.
-- ------------------------------------------------------------
revoke all on function public.rate_limit_hit(text, integer, integer) from public, anon, authenticated;
revoke all on function public.rate_limits_sweep()                    from public, anon, authenticated;
revoke all on function public.geocode_lookup(text)                   from public, anon, authenticated;
revoke all on function public.geocode_store(text, text, jsonb)       from public, anon, authenticated;

grant execute on function public.rate_limit_hit(text, integer, integer) to service_role;
grant execute on function public.rate_limits_sweep()                    to service_role;
grant execute on function public.geocode_lookup(text)                   to service_role;
grant execute on function public.geocode_store(text, text, jsonb)       to service_role;
