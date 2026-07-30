-- ============================================================
-- We Rondayview — serving ads
--
-- The tables were built in the foundation migration. This adds the
-- part that decides which ad a given person sees, which is the bit
-- that has to be trustworthy: an advertiser is paying for delivery,
-- so the counting has to be done somewhere they cannot influence and
-- somewhere you cannot accidentally inflate either.
--
-- Safe to re-run.
-- ============================================================


-- Distance without needing PostGIS. Good to a few metres at city scale,
-- which is all an ad radius ever needs.
create or replace function public.meters_between(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
)
returns double precision
language sql
immutable
parallel safe
as $$
  select 6371000 * 2 * asin(sqrt(
    power(sin(radians($3 - $1) / 2), 2) +
    cos(radians($1)) * cos(radians($3)) * power(sin(radians($4 - $2) / 2), 2)
  ));
$$;


-- ============================================================
-- WHICH ADS TO SHOW
--
-- Everything that decides eligibility lives here rather than in the
-- browser: whether an ad is live, whether it is in date, whether the
-- meeting point is inside its radius, and whether it has already had
-- its allowance of showings today.
--
-- The daily cap is the reason this cannot be a plain select. Counting
-- today's impressions means reading ad_events, and ad_events is
-- deliberately unreadable to everyone but the advertiser who owns the
-- ad. security definer lets the count happen without opening that door.
-- ============================================================

create or replace function public.serve_ads(
  at_lat double precision,
  at_lng double precision,
  want_formats text[] default null,
  limit_n integer default 4
)
returns table (
  id uuid,
  format text,
  headline text,
  body text,
  image_url text,
  cta_label text,
  cta_url text,
  advertiser_name text,
  place_id uuid,
  place_name text,
  place_lat double precision,
  place_lng double precision,
  distance_m double precision
)
language sql
stable
security definer
set search_path = public
as $$
  with today as (
    select ad_id, count(*) as shown
    from public.ad_events
    where event = 'impression'
      and created_at >= date_trunc('day', now())
    group by ad_id
  )
  select
    a.id, a.format, a.headline, a.body, a.image_url,
    a.cta_label, a.cta_url,
    adv.business_name,
    p.id, p.name, p.lat, p.lng,
    case
      when a.target_lat is null then null
      else public.meters_between(a.target_lat, a.target_lng, at_lat, at_lng)
    end
  from public.ads a
  join public.advertisers adv on adv.id = a.advertiser_id
  left join public.places p on p.id = a.place_id
  left join today t on t.ad_id = a.id
  where a.status = 'active'
    and (a.starts_at is null or a.starts_at <= now())
    and (a.ends_at   is null or a.ends_at   >  now())
    and (want_formats is null or a.format = any(want_formats))
    -- No centre means run it everywhere. A centre means stay inside it.
    and (
      a.target_lat is null
      or a.target_lng is null
      or public.meters_between(a.target_lat, a.target_lng, at_lat, at_lng) <= a.target_radius_m
    )
    -- A sponsored place with no place attached cannot be rendered.
    and (a.format <> 'sponsored_place' or p.id is not null)
    and (a.daily_impression_cap is null or coalesce(t.shown, 0) < a.daily_impression_cap)
  -- Spread delivery: whoever has been shown least today goes first, then
  -- shuffle so equal ads do not always come back in the same order.
  order by coalesce(t.shown, 0) asc, random()
  limit greatest(least(limit_n, 10), 1);
$$;


-- ============================================================
-- COUNTING A SHOWING
--
-- The insert policy on ad_events already lets anyone record an event,
-- because anyone can see an ad. This wrapper exists so the app has one
-- obvious way in, and so the event kind is checked rather than trusted.
--
-- Being straight about the limit: this still counts what the browser
-- claims. It is fine while you are selling to local businesses you
-- know. Before selling to anyone who audits their spend, the count has
-- to come from somewhere the buyer's competitor cannot reach.
-- ============================================================

create or replace function public.record_ad_event(
  ad uuid,
  kind text,
  at_lat double precision default null,
  at_lng double precision default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if kind not in ('impression', 'click') then
    raise exception 'Unknown ad event "%".', kind using errcode = 'check_violation';
  end if;

  -- Silently ignore events for ads that are not live, rather than
  -- letting a stale page keep billing an ended campaign.
  if not exists (
    select 1 from public.ads a
    where a.id = ad
      and a.status = 'active'
      and (a.starts_at is null or a.starts_at <= now())
      and (a.ends_at   is null or a.ends_at   >  now())
  ) then
    return;
  end if;

  insert into public.ad_events (ad_id, event, user_id, lat, lng)
  values (ad, kind, auth.uid(), at_lat, at_lng);
end;
$$;


-- ============================================================
-- WHAT AN ADVERTISER IS OWED
--
-- What you show a buyer at the end of the month. Restricted to ads you
-- own, by the same check the ad_events read policy uses.
-- ============================================================

create or replace function public.ad_performance(since timestamptz default now() - interval '30 days')
returns table (
  ad_id uuid,
  headline text,
  format text,
  status text,
  impressions bigint,
  clicks bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id, a.headline, a.format, a.status,
    count(*) filter (where e.event = 'impression'),
    count(*) filter (where e.event = 'click')
  from public.ads a
  join public.advertisers adv on adv.id = a.advertiser_id
  left join public.ad_events e on e.ad_id = a.id and e.created_at >= since
  where auth.uid() is not null
    and adv.owner_id = auth.uid()
  group by a.id, a.headline, a.format, a.status
  order by a.created_at desc;
$$;


-- Counting today's impressions per ad is now on the hot path.
create index if not exists ad_events_impressions_by_day
  on public.ad_events (ad_id, created_at)
  where event = 'impression';


-- ============================================================
-- WHO MAY CALL THESE
--
-- serve_ads and record_ad_event are open to signed-out visitors on
-- purpose: the app works without an account, and so must its ads.
-- ad_performance is not — it reports on money.
-- ============================================================

revoke all on function public.serve_ads(double precision, double precision, text[], integer) from public;
revoke all on function public.record_ad_event(uuid, text, double precision, double precision) from public;
revoke all on function public.ad_performance(timestamptz) from public, anon;

grant execute on function public.serve_ads(double precision, double precision, text[], integer) to anon, authenticated;
grant execute on function public.record_ad_event(uuid, text, double precision, double precision) to anon, authenticated;
grant execute on function public.ad_performance(timestamptz) to authenticated;


-- ============================================================
-- ARTWORK
--
-- Banners and business cards need an image. Same shape as avatars:
-- public to read, and you may only write inside a folder named after
-- your own user id.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ad-images', 'ad-images', true, 3145728,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 3145728,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

drop policy if exists "ad images are publicly readable" on storage.objects;
create policy "ad images are publicly readable"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'ad-images');

drop policy if exists "upload your own ad images" on storage.objects;
create policy "upload your own ad images"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ad-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "replace your own ad images" on storage.objects;
create policy "replace your own ad images"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'ad-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "delete your own ad images" on storage.objects;
create policy "delete your own ad images"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'ad-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
