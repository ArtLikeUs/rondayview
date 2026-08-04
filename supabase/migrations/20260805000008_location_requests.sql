-- ============================================================
-- We Rondayview — asking people where they are starting from
--
-- The awkward part of planning a meetup is that one person ends up
-- typing everybody else's address, usually wrong, usually after three
-- messages asking for it. This lets them send a link instead.
--
-- Whoever opens the link does not need an account. That is the whole
-- point: the friend who will not sign up for anything is exactly the
-- friend whose address you are trying to get.
--
-- Safe to re-run.
-- ============================================================

create table if not exists public.location_requests (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references public.profiles(id) on delete cascade,
  -- Unguessable, and the only thing standing between a stranger and the
  -- ability to add themselves to somebody's trip. 32 hex characters
  -- from the same generator that makes the ids.
  token           text unique not null default replace(gen_random_uuid()::text, '-', ''),
  title           text,
  -- Set when the ask went to a friend in the app rather than as a link.
  invited_user_id uuid references public.profiles(id) on delete set null,
  status          text not null default 'open',
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '7 days',

  constraint request_status check (status in ('open', 'closed')),
  constraint request_title_len check (title is null or char_length(title) <= 80)
);

create index if not exists location_requests_owner_idx
  on public.location_requests (owner_id, created_at desc);
create index if not exists location_requests_invited_idx
  on public.location_requests (invited_user_id, status);

create table if not exists public.location_shares (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.location_requests(id) on delete cascade,
  user_id      uuid references public.profiles(id) on delete set null,
  display_name text not null,
  label        text,
  lat          double precision not null,
  lng          double precision not null,
  created_at   timestamptz not null default now(),

  constraint share_name_len check (char_length(display_name) between 1 and 60),
  constraint share_lat_range check (lat between -90 and 90),
  constraint share_lng_range check (lng between -180 and 180)
);

create index if not exists location_shares_request_idx
  on public.location_shares (request_id, created_at);

alter table public.location_requests enable row level security;
alter table public.location_shares   enable row level security;


-- ---- who can see a request ----
drop policy if exists "see requests you made or were sent" on public.location_requests;
create policy "see requests you made or were sent"
  on public.location_requests for select to authenticated
  using (owner_id = auth.uid() or invited_user_id = auth.uid());

drop policy if exists "make your own requests" on public.location_requests;
create policy "make your own requests"
  on public.location_requests for insert to authenticated
  with check (owner_id = auth.uid());

drop policy if exists "close your own requests" on public.location_requests;
create policy "close your own requests"
  on public.location_requests for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "delete your own requests" on public.location_requests;
create policy "delete your own requests"
  on public.location_requests for delete to authenticated
  using (owner_id = auth.uid());

-- ---- who can see the answers ----
-- Only the person who asked. Somebody's address is not public just
-- because they were generous enough to share it once.
drop policy if exists "the asker reads the answers" on public.location_shares;
create policy "the asker reads the answers"
  on public.location_shares for select to authenticated
  using (
    exists (
      select 1 from public.location_requests r
      where r.id = location_shares.request_id and r.owner_id = auth.uid()
    )
  );

-- No insert policy at all. Answers arrive only through the function
-- below, which checks the token, the expiry and the headcount.


-- ============================================================
-- WHAT SOMEBODY OPENING THE LINK IS TOLD
--
-- Their name and what they are being asked, and nothing else. Not the
-- other people's addresses, not the meeting point, not the owner's
-- email. A link that leaked the answers it collected would be worse
-- than the problem it solves.
-- ============================================================
create or replace function public.location_request_info(tok text)
returns table (
  title       text,
  asked_by    text,
  is_open     boolean,
  already_in  integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.title,
    p.display_name,
    (r.status = 'open' and r.expires_at > now()),
    (select count(*)::int from public.location_shares s where s.request_id = r.id)
  from public.location_requests r
  join public.profiles p on p.id = r.owner_id
  where r.token = tok;
$$;


-- ============================================================
-- ANSWERING
--
-- Open to people with no account, because the friend who will not sign
-- up is the one whose address you are chasing.
--
-- Three answers per request. The app seats four people, one of whom is
-- the person doing the asking.
-- ============================================================
create or replace function public.submit_shared_location(
  tok      text,
  who      text,
  in_lat   double precision,
  in_lng   double precision,
  in_label text default null
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  req public.location_requests%rowtype;
  seats integer;
begin
  select * into req from public.location_requests where token = tok;
  if not found then
    raise exception 'That link is not valid.' using errcode = 'no_data_found';
  end if;
  if req.status <> 'open' or req.expires_at <= now() then
    raise exception 'That request has closed.' using errcode = 'check_violation';
  end if;

  if in_lat is null or in_lng is null
     or in_lat not between -90 and 90 or in_lng not between -180 and 180 then
    raise exception 'That location is not valid.' using errcode = 'check_violation';
  end if;
  if coalesce(trim(who), '') = '' then
    raise exception 'A name is required.' using errcode = 'check_violation';
  end if;

  select count(*) into seats from public.location_shares where request_id = req.id;
  if seats >= 3 then
    raise exception 'That trip is already full.' using errcode = 'check_violation';
  end if;

  -- Signing in is optional here, but if they happen to be signed in,
  -- replace their earlier answer rather than adding a second one.
  if auth.uid() is not null then
    delete from public.location_shares
     where request_id = req.id and user_id = auth.uid();
  end if;

  insert into public.location_shares (request_id, user_id, display_name, lat, lng, label)
  values (req.id, auth.uid(), left(trim(who), 60), in_lat, in_lng, left(in_label, 200));

  return 'ok';
end;
$$;


-- ============================================================
-- BEING ASKED, IN THE APP
--
-- When the ask went to a friend rather than out as a link, they see it
-- next time they open the app and can answer with the address they
-- already saved.
-- ============================================================
create or replace function public.my_location_asks()
returns table (
  token      text,
  title      text,
  asked_by   text,
  asked_at   timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select r.token, r.title, p.display_name, r.created_at
  from public.location_requests r
  join public.profiles p on p.id = r.owner_id
  where auth.uid() is not null
    and r.invited_user_id = auth.uid()
    and r.status = 'open'
    and r.expires_at > now()
    -- Hide it once they have answered.
    and not exists (
      select 1 from public.location_shares s
      where s.request_id = r.id and s.user_id = auth.uid()
    )
  order by r.created_at desc
  limit 10;
$$;


revoke all on function public.location_request_info(text) from public;
revoke all on function public.submit_shared_location(text, text, double precision, double precision, text) from public;
revoke all on function public.my_location_asks() from public, anon;

grant execute on function public.location_request_info(text) to anon, authenticated;
grant execute on function public.submit_shared_location(text, text, double precision, double precision, text) to anon, authenticated;
grant execute on function public.my_location_asks() to authenticated;
