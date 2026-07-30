-- ============================================================
-- We Rondayview — friends
--
-- Three jobs:
--   1. Close a hole: only the person who RECEIVED a request may accept it.
--   2. Let people opt in to friends starting a meetup from their address.
--   3. Add the read-only functions the app needs to show friends.
--
-- Safe to re-run.
-- ============================================================


-- ============================================================
-- 1. ONLY THE ADDRESSEE MAY ACCEPT
--
-- The row-level rule lets either side update the row, because either
-- side may block or withdraw. But it cannot tell "accepted" from
-- "pending" — a policy only sees the row being written, never the row
-- as it was. So without this, the person who SENT a request could
-- flip it to accepted themselves and become your friend uninvited.
--
-- A trigger can see both versions, so the rule lives here instead.
-- ============================================================

create or replace function public.guard_friendship_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- auth.uid() is null for admin work in the dashboard; leave that alone.
  if auth.uid() is null then
    return new;
  end if;

  -- Nobody may re-point a friendship at somebody else after the fact.
  if new.requester_id <> old.requester_id or new.addressee_id <> old.addressee_id then
    raise exception 'A friendship cannot be moved to different people.'
      using errcode = 'check_violation';
  end if;

  -- The heart of it: accepting is the addressee's call, and nobody else's.
  if new.status = 'accepted' and old.status <> 'accepted' then
    if auth.uid() <> old.addressee_id then
      raise exception 'Only the person who received the request may accept it.'
        using errcode = 'insufficient_privilege';
    end if;
    new.responded_at := now();
  end if;

  -- Un-accepting is not a thing. Remove the friendship instead.
  if old.status = 'accepted' and new.status = 'pending' then
    raise exception 'An accepted friendship cannot go back to pending.'
      using errcode = 'check_violation';
  end if;

  if new.status = 'blocked' and old.status <> 'blocked' then
    new.responded_at := now();
  end if;

  return new;
end;
$$;

drop trigger if exists guard_friendship on public.friendships;
create trigger guard_friendship
  before update on public.friendships
  for each row execute function public.guard_friendship_change();


-- ============================================================
-- 2. SHARING YOUR STARTING POINT
--
-- Off by default, and it has to be. The whole reason home addresses
-- live in their own table is that nobody should see them by accident.
--
-- Be clear-eyed about what this switch does when it is on: a friend
-- gets your coordinates, and coordinates are your address. Hiding the
-- street text while handing over the exact point would be theatre, so
-- the app says plainly what is being shared. What it does buy you is
-- that it is your choice, per account, and revocable.
-- ============================================================

alter table public.profile_private
  add column if not exists share_home_with_friends boolean not null default false;


-- Returns a friend's starting point, but only if BOTH are true:
-- you are actually accepted friends, and they turned sharing on.
-- Anything else comes back empty rather than explaining why, so this
-- cannot be used to probe who has an address saved.
create or replace function public.friend_origin(friend uuid)
returns table (lat double precision, lng double precision, label text)
language sql
stable
security definer
set search_path = public
as $$
  select
    pp.home_lat,
    pp.home_lng,
    -- Trim the house number off the front for display. The point itself
    -- is exact; this only keeps the UI from printing someone's doorstep.
    case
      when pp.home_label is null then null
      when array_length(string_to_array(pp.home_label, ', '), 1) > 3
        then array_to_string(
               (string_to_array(pp.home_label, ', '))[
                 greatest(array_length(string_to_array(pp.home_label, ', '), 1) - 2, 1) :
               ], ', ')
      else pp.home_label
    end
  from public.profile_private pp
  where pp.id = friend
    and auth.uid() is not null
    and pp.share_home_with_friends
    and pp.home_lat is not null
    and pp.home_lng is not null
    and public.are_friends(auth.uid(), friend);
$$;


-- ============================================================
-- 3. READING YOUR FRIENDS
--
-- These exist so the browser can ask one question instead of four,
-- and so that reading a friend's sharing flag does not require
-- handing the browser read access to profile_private itself.
-- ============================================================

-- Dropped first because the returned columns changed shape; a plain
-- "create or replace" refuses that.
drop function if exists public.my_friends();
create or replace function public.my_friends()
returns table (
  friendship_id uuid,
  id uuid,
  handle text,
  display_name text,
  avatar_url text,
  shares_home boolean,
  friends_since timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    f.id, p.id, p.handle, p.display_name, p.avatar_url,
    coalesce(pp.share_home_with_friends, false),
    f.responded_at
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
  left join public.profile_private pp on pp.id = p.id
  where auth.uid() is not null
    and f.status = 'accepted'
    and (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
  order by lower(p.display_name);
$$;


drop function if exists public.my_friend_requests();
create or replace function public.my_friend_requests()
returns table (
  friendship_id uuid,
  direction text,
  profile_id uuid,
  handle text,
  display_name text,
  avatar_url text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    f.id,
    case when f.addressee_id = auth.uid() then 'incoming' else 'outgoing' end,
    p.id, p.handle, p.display_name, p.avatar_url, f.created_at
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
  where auth.uid() is not null
    and f.status = 'pending'
    and (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
  order by f.created_at desc;
$$;


-- ============================================================
-- 4. WHO MAY CALL THESE
--
-- security definer functions run with the owner's power, so being
-- strict about who can execute them is the whole safety story.
-- ============================================================

revoke all on function public.friend_origin(uuid)      from public, anon;
revoke all on function public.my_friends()             from public, anon;
revoke all on function public.my_friend_requests()     from public, anon;

grant execute on function public.friend_origin(uuid)   to authenticated;
grant execute on function public.my_friends()          to authenticated;
grant execute on function public.my_friend_requests()  to authenticated;
