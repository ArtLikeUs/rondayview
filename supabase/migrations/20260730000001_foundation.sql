-- ============================================================
-- We Rondayview — foundation
--
-- Everything the app needs to have real accounts: who people are,
-- who they're friends with, the places they meet, the ads that pay
-- for it, and the meetups they plan.
--
-- Run this once, in the Supabase dashboard under SQL Editor.
-- It is safe to re-run: every statement checks before it creates.
--
-- The rule that governs this whole file: a row is invisible unless
-- a policy says otherwise. Postgres denies by default once row level
-- security is on, so the policies below are the entire guest list.
-- ============================================================

-- ------------------------------------------------------------
-- Helper: keep updated_at honest without trusting the client
-- ------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ============================================================
-- 1. WHO PEOPLE ARE
--
-- Split deliberately into two tables.
--
--   profiles         — the face. Any signed-in person can read it,
--                      because that is how you find a friend.
--   profile_private  — the home address. Only ever the owner.
--
-- Postgres security works a row at a time, not a column at a time.
-- If someone's home coordinates lived on the public profile row,
-- then making the row readable would make their address readable.
-- Two tables is the only honest way to keep one half public.
-- ============================================================

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  handle       text not null,
  display_name text not null,
  avatar_url   text,
  bio          text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint handle_shape check (handle ~ '^[a-zA-Z0-9_]{3,24}$'),
  constraint display_name_len check (char_length(display_name) between 1 and 60),
  constraint bio_len check (bio is null or char_length(bio) <= 200)
);

-- Handles are compared without regard to case: @Artie and @artie are
-- the same person, and only one of them can have it.
create unique index if not exists profiles_handle_unique
  on public.profiles (lower(handle));

create table if not exists public.profile_private (
  id            uuid primary key references public.profiles(id) on delete cascade,

  -- Their usual starting point, so "Me" fills itself in.
  home_label    text,
  home_lat      double precision,
  home_lng      double precision,

  -- Contact preferences, for later.
  notify_email  boolean not null default true,
  notify_push   boolean not null default true,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint home_lat_range check (home_lat is null or home_lat between -90 and 90),
  constraint home_lng_range check (home_lng is null or home_lng between -180 and 180)
);

-- When somebody signs up, give them a profile immediately.
-- Doing this in the database rather than the app means a profile
-- cannot fail to exist — there is no code path that skips it.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base   text;
  try    text;
  suffix int := 0;
begin
  -- Build a starting handle from their email, then walk until it's free.
  base := regexp_replace(split_part(new.email, '@', 1), '[^a-zA-Z0-9_]', '', 'g');
  base := left(nullif(base, ''), 20);
  if base is null or char_length(base) < 3 then
    base := 'friend';
  end if;

  try := base;
  while exists (select 1 from public.profiles where lower(handle) = lower(try)) loop
    suffix := suffix + 1;
    try := base || suffix::text;
  end loop;

  insert into public.profiles (id, handle, display_name)
  values (new.id, try, coalesce(new.raw_user_meta_data->>'display_name', try));

  insert into public.profile_private (id) values (new.id);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================
-- 2. FRIENDS
--
-- One row per relationship, not two. The pair is stored in the
-- direction it was asked, so we know who did the asking, but the
-- unique index below is built on the sorted pair — which means
-- A-asks-B and B-asks-A collide on purpose. You cannot end up
-- with two half-friendships pointing at each other.
-- ============================================================

create table if not exists public.friendships (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz,

  constraint no_self_friending check (requester_id <> addressee_id),
  constraint friendship_status check (status in ('pending', 'accepted', 'blocked'))
);

create unique index if not exists friendships_unique_pair
  on public.friendships (
    least(requester_id, addressee_id),
    greatest(requester_id, addressee_id)
  );

create index if not exists friendships_addressee_idx
  on public.friendships (addressee_id, status);
create index if not exists friendships_requester_idx
  on public.friendships (requester_id, status);

-- Asked constantly by the policies below, so it's worth having once.
create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.friendships
    where status = 'accepted'
      and least(requester_id, addressee_id)    = least(a, b)
      and greatest(requester_id, addressee_id) = greatest(a, b)
  );
$$;


-- ============================================================
-- 3. PLACES
--
-- A cache of real venues, mostly copied from OpenStreetMap the
-- first time we see them. Two reasons to keep our own copy:
-- we stop re-asking a free service the same question, and an ad
-- needs something permanent to point at.
-- ============================================================

create table if not exists public.places (
  id          uuid primary key default gen_random_uuid(),
  source      text not null default 'osm',
  source_ref  text,
  name        text not null,
  category    text,
  lat         double precision not null,
  lng         double precision not null,
  address     text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint place_source check (source in ('osm', 'manual', 'advertiser')),
  constraint place_lat_range check (lat between -90 and 90),
  constraint place_lng_range check (lng between -180 and 180)
);

create unique index if not exists places_source_ref_unique
  on public.places (source, source_ref)
  where source_ref is not null;

create index if not exists places_latlng_idx on public.places (lat, lng);


-- ============================================================
-- 4. ADVERTISERS AND ADS
--
-- Built generic on purpose. One ad row can be a banner, a featured
-- business card, or a sponsored meeting spot — the `format` column
-- decides which, and the app renders accordingly. That way selling
-- a new kind of placement is a new format string, not a new table.
--
-- Money is deliberately NOT modelled yet. Rates, invoices, and
-- payments come after you have a buyer, because the shape of that
-- table depends on how you actually decide to charge.
-- ============================================================

create table if not exists public.advertisers (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid references public.profiles(id) on delete set null,
  business_name text not null,
  contact_email text,
  contact_phone text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists advertisers_owner_idx on public.advertisers (owner_id);

create table if not exists public.ads (
  id            uuid primary key default gen_random_uuid(),
  advertiser_id uuid not null references public.advertisers(id) on delete cascade,

  format        text not null,
  headline      text not null,
  body          text,
  image_url     text,
  cta_label     text,
  cta_url       text,

  -- Only for format = 'sponsored_place': which venue is being pushed.
  place_id      uuid references public.places(id) on delete set null,

  -- Where it should show. Null centre means everywhere.
  target_lat    double precision,
  target_lng    double precision,
  target_radius_m integer not null default 40000,

  status        text not null default 'draft',
  starts_at     timestamptz,
  ends_at       timestamptz,

  -- A cheap brake so one ad cannot eat every slot in a day.
  daily_impression_cap integer,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint ad_format check (format in ('banner', 'featured_card', 'sponsored_place')),
  constraint ad_status check (status in ('draft', 'active', 'paused', 'ended')),
  constraint ad_headline_len check (char_length(headline) between 1 and 120),
  constraint ad_body_len check (body is null or char_length(body) <= 300),
  constraint ad_radius_sane check (target_radius_m between 500 and 500000),
  constraint ad_dates_ordered check (ends_at is null or starts_at is null or ends_at > starts_at),
  -- A sponsored spot with no spot attached is meaningless.
  constraint sponsored_needs_place check (format <> 'sponsored_place' or place_id is not null),
  constraint ad_target_lat_range check (target_lat is null or target_lat between -90 and 90),
  constraint ad_target_lng_range check (target_lng is null or target_lng between -180 and 180)
);

create index if not exists ads_serving_idx
  on public.ads (status, format)
  where status = 'active';
create index if not exists ads_advertiser_idx on public.ads (advertiser_id);

-- Every time an ad is shown or clicked. This is what you will bill
-- against and what you will show a buyer to prove the placement worked.
create table if not exists public.ad_events (
  id         bigserial primary key,
  ad_id      uuid not null references public.ads(id) on delete cascade,
  event      text not null,
  user_id    uuid references public.profiles(id) on delete set null,
  lat        double precision,
  lng        double precision,
  created_at timestamptz not null default now(),

  constraint ad_event_kind check (event in ('impression', 'click'))
);

create index if not exists ad_events_ad_day_idx
  on public.ad_events (ad_id, created_at desc);


-- ============================================================
-- 5. MEETUPS
--
-- The thing the app actually produces, saved instead of thrown away.
-- This is the table that turns a calculator into an app: a history
-- worth signing in for, and something to invite a friend to.
-- ============================================================

create table if not exists public.meetups (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references public.profiles(id) on delete cascade,
  title           text,
  mode            text not null default 'straight',
  result_lat      double precision,
  result_lng      double precision,
  chosen_place_id uuid references public.places(id) on delete set null,
  meets_at        timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint meetup_mode check (mode in ('straight', 'drive')),
  constraint meetup_title_len check (title is null or char_length(title) <= 80)
);

create index if not exists meetups_owner_idx on public.meetups (owner_id, created_at desc);

-- Everyone converging on the meetup. A participant may be a real
-- account (user_id) or just a typed-in name and address, so the app
-- keeps working for people whose friends have not signed up.
create table if not exists public.meetup_participants (
  id           uuid primary key default gen_random_uuid(),
  meetup_id    uuid not null references public.meetups(id) on delete cascade,
  user_id      uuid references public.profiles(id) on delete set null,
  display_name text not null,
  address_label text,
  lat          double precision,
  lng          double precision,
  weight       numeric(5,2) not null default 50,
  created_at   timestamptz not null default now(),

  constraint weight_range check (weight >= 0 and weight <= 100)
);

create index if not exists meetup_participants_meetup_idx
  on public.meetup_participants (meetup_id);
create index if not exists meetup_participants_user_idx
  on public.meetup_participants (user_id);

-- These two exist to break a loop.
--
-- "You can see a meetup if you're a participant" and "you can see a
-- participant if you can see the meetup" are both true and both
-- reasonable, but written directly as policies they call each other
-- forever and Postgres aborts with an infinite recursion error.
--
-- security definer makes these run as the table owner, which is not
-- subject to row level security, so the chain stops here. They are the
-- only place that is allowed to look without asking.
create or replace function public.owns_meetup(m uuid, u uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.meetups mt where mt.id = m and mt.owner_id = u);
$$;

create or replace function public.can_see_meetup(m uuid, u uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.meetups mt
    where mt.id = m
      and (
        mt.owner_id = u
        or exists (
          select 1 from public.meetup_participants p
          where p.meetup_id = m and p.user_id = u
        )
      )
  );
$$;


-- ============================================================
-- 6. DEVICES
--
-- Empty until there is a phone app. It exists now so that the day
-- you ship to the App Store, push notifications are a feature to
-- switch on rather than a migration to write.
-- ============================================================

create table if not exists public.user_devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  platform    text not null,
  push_token  text not null,
  last_seen_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),

  constraint device_platform check (platform in ('ios', 'android', 'web'))
);

create unique index if not exists user_devices_token_unique
  on public.user_devices (push_token);


-- ============================================================
-- 7. UPDATED_AT TRIGGERS
-- ============================================================

do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'profile_private', 'places',
    'advertisers', 'ads', 'meetups'
  ]
  loop
    execute format('drop trigger if exists touch_%1$s on public.%1$s', t);
    execute format(
      'create trigger touch_%1$s before update on public.%1$s
       for each row execute function public.touch_updated_at()', t
    );
  end loop;
end;
$$;


-- ============================================================
-- 8. ROW LEVEL SECURITY
--
-- On for every table. Nothing is readable or writable except
-- through a policy stated below.
-- ============================================================

alter table public.profiles            enable row level security;
alter table public.profile_private     enable row level security;
alter table public.friendships         enable row level security;
alter table public.places              enable row level security;
alter table public.advertisers         enable row level security;
alter table public.ads                 enable row level security;
alter table public.ad_events           enable row level security;
alter table public.meetups             enable row level security;
alter table public.meetup_participants enable row level security;
alter table public.user_devices        enable row level security;

-- ---- profiles ----------------------------------------------
-- Readable by anyone signed in: you cannot add a friend you
-- cannot find. Nothing sensitive lives on this row.
drop policy if exists "profiles are readable by signed-in users" on public.profiles;
create policy "profiles are readable by signed-in users"
  on public.profiles for select to authenticated
  using (true);

drop policy if exists "you may edit your own profile" on public.profiles;
create policy "you may edit your own profile"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---- profile_private ---------------------------------------
-- Your home address. Nobody else, ever, including friends.
drop policy if exists "your private details are yours" on public.profile_private;
create policy "your private details are yours"
  on public.profile_private for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---- friendships -------------------------------------------
drop policy if exists "see friendships you are part of" on public.friendships;
create policy "see friendships you are part of"
  on public.friendships for select to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- You may only ever send a request as yourself.
drop policy if exists "send your own friend requests" on public.friendships;
create policy "send your own friend requests"
  on public.friendships for insert to authenticated
  with check (requester_id = auth.uid());

-- Either side can act: the addressee accepts, either side blocks.
drop policy if exists "respond to friendships you are part of" on public.friendships;
create policy "respond to friendships you are part of"
  on public.friendships for update to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid())
  with check (requester_id = auth.uid() or addressee_id = auth.uid());

drop policy if exists "remove friendships you are part of" on public.friendships;
create policy "remove friendships you are part of"
  on public.friendships for delete to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- ---- places ------------------------------------------------
-- Public knowledge. A coffee shop's address is not a secret, and
-- the app must work before anyone signs in.
drop policy if exists "places are public" on public.places;
create policy "places are public"
  on public.places for select to anon, authenticated
  using (true);

drop policy if exists "signed-in users may add places" on public.places;
create policy "signed-in users may add places"
  on public.places for insert to authenticated
  with check (true);

-- ---- advertisers -------------------------------------------
drop policy if exists "manage your own advertiser record" on public.advertisers;
create policy "manage your own advertiser record"
  on public.advertisers for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ---- ads ---------------------------------------------------
-- Live ads are readable by everyone, signed in or not — that is
-- the entire point of an ad. Draft and paused ads stay hidden.
drop policy if exists "active ads are public" on public.ads;
create policy "active ads are public"
  on public.ads for select to anon, authenticated
  using (
    status = 'active'
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at > now())
  );

drop policy if exists "advertisers manage their own ads" on public.ads;
create policy "advertisers manage their own ads"
  on public.ads for all to authenticated
  using (
    exists (
      select 1 from public.advertisers a
      where a.id = ads.advertiser_id and a.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.advertisers a
      where a.id = ads.advertiser_id and a.owner_id = auth.uid()
    )
  );

-- ---- ad_events ---------------------------------------------
-- Anyone may record that they saw an ad, because anyone may see one.
-- Only the advertiser may read the tally back.
--
-- Note: this trusts the browser to report honestly, which is fine
-- while you sell to local businesses you know. If you ever sell to
-- someone who audits their spend, move this write behind an Edge
-- Function so the count cannot be inflated from the console.
drop policy if exists "anyone may record an ad event" on public.ad_events;
create policy "anyone may record an ad event"
  on public.ad_events for insert to anon, authenticated
  with check (true);

drop policy if exists "advertisers read their own numbers" on public.ad_events;
create policy "advertisers read their own numbers"
  on public.ad_events for select to authenticated
  using (
    exists (
      select 1 from public.ads d
      join public.advertisers a on a.id = d.advertiser_id
      where d.id = ad_events.ad_id and a.owner_id = auth.uid()
    )
  );

-- ---- meetups -----------------------------------------------
drop policy if exists "see meetups you own or attend" on public.meetups;
create policy "see meetups you own or attend"
  on public.meetups for select to authenticated
  using (
    owner_id = auth.uid()
    or public.can_see_meetup(id, auth.uid())
  );

drop policy if exists "create your own meetups" on public.meetups;
create policy "create your own meetups"
  on public.meetups for insert to authenticated
  with check (owner_id = auth.uid());

drop policy if exists "change your own meetups" on public.meetups;
create policy "change your own meetups"
  on public.meetups for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "delete your own meetups" on public.meetups;
create policy "delete your own meetups"
  on public.meetups for delete to authenticated
  using (owner_id = auth.uid());

-- ---- meetup_participants -----------------------------------
drop policy if exists "see participants of meetups you can see" on public.meetup_participants;
create policy "see participants of meetups you can see"
  on public.meetup_participants for select to authenticated
  using (public.can_see_meetup(meetup_id, auth.uid()));

drop policy if exists "the owner manages participants" on public.meetup_participants;
create policy "the owner manages participants"
  on public.meetup_participants for all to authenticated
  using (public.owns_meetup(meetup_id, auth.uid()))
  with check (public.owns_meetup(meetup_id, auth.uid()));

-- ---- user_devices ------------------------------------------
drop policy if exists "your devices are yours" on public.user_devices;
create policy "your devices are yours"
  on public.user_devices for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());


-- ============================================================
-- 9. AVATAR STORAGE
--
-- A public bucket, because a profile picture is meant to be seen.
-- Writes are locked to a folder named after the user's own id, so
-- nobody can overwrite anybody else's face.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true, 2097152,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

drop policy if exists "avatars are publicly readable" on storage.objects;
create policy "avatars are publicly readable"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars');

drop policy if exists "upload your own avatar" on storage.objects;
create policy "upload your own avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "replace your own avatar" on storage.objects;
create policy "replace your own avatar"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "delete your own avatar" on storage.objects;
create policy "delete your own avatar"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- ============================================================
-- 10. FRIEND SEARCH
--
-- Finding a friend needs a fuzzy search across handle and name,
-- but handing the browser a "select everyone" query is how you
-- end up with your whole user list scraped. This function answers
-- a specific question, caps the answer at 20, and refuses to run
-- on a search term short enough to match everybody.
-- ============================================================

create or replace function public.search_profiles(term text)
returns table (
  id uuid,
  handle text,
  display_name text,
  avatar_url text,
  friendship_status text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.handle,
    p.display_name,
    p.avatar_url,
    coalesce(f.status, 'none') as friendship_status
  from public.profiles p
  left join public.friendships f
    on least(f.requester_id, f.addressee_id)    = least(p.id, auth.uid())
   and greatest(f.requester_id, f.addressee_id) = greatest(p.id, auth.uid())
  where auth.uid() is not null
    and char_length(trim(term)) >= 2
    and p.id <> auth.uid()
    and (p.handle ilike trim(term) || '%' or p.display_name ilike '%' || trim(term) || '%')
  order by
    case when p.handle ilike trim(term) || '%' then 0 else 1 end,
    p.handle
  limit 20;
$$;

revoke all on function public.search_profiles(text) from public, anon;
grant execute on function public.search_profiles(text) to authenticated;
