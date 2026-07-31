-- ============================================================
-- We Rondayview — three kinds of account
--
--   member      the default. Uses the app. Never sees advertising
--               tools, and cannot reach them by guessing a URL.
--   advertiser  may run campaigns for one business. Granted, not
--               self-selected.
--   admin       may grant and revoke advertiser access. You.
--
-- Until now the advertiser tools were open to anyone signed in: the
-- policy on `advertisers` allowed any authenticated user to insert a
-- row naming themselves as owner. Hiding the button would not have
-- fixed it, because the database was the thing saying yes.
--
-- ------------------------------------------------------------
-- Why roles live in their own table
--
-- The obvious version is a `role` column on `profiles`. It would be
-- wrong here. The profile update policy is `id = auth.uid()` across
-- the whole row, so anybody could set their own role to admin with one
-- request. Splitting them out means there is no policy that lets a
-- user write their own role at all — only a security definer function
-- an admin calls.
--
-- No row means ordinary member. There is nothing to assign for the
-- common case, so the default cannot be got wrong.
-- ============================================================

create table if not exists public.user_roles (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  role       text not null,
  granted_by uuid references public.profiles(id) on delete set null,
  granted_at timestamptz not null default now(),
  note       text,

  constraint role_is_known check (role in ('advertiser', 'admin'))
);

alter table public.user_roles enable row level security;

-- You may see what you are. That is all: no insert, no update, no
-- delete policy exists, so the only way a role changes is through the
-- admin functions at the bottom of this file.
drop policy if exists "see your own role" on public.user_roles;
create policy "see your own role"
  on public.user_roles for select to authenticated
  using (user_id = auth.uid());


-- ------------------------------------------------------------
-- Asking what someone is
--
-- security definer so these can be used inside policies on
-- user_roles itself without the policy asking the table that the
-- policy is protecting, which is how you get infinite recursion.
-- ------------------------------------------------------------
create or replace function public.role_of(u uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select role from public.user_roles where user_id = u), 'member');
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'admin');
$$;

-- Admins can do anything an advertiser can, so support does not
-- require a second account.
create or replace function public.can_advertise()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1 from public.user_roles
       where user_id = auth.uid() and role in ('advertiser', 'admin')
     );
$$;

grant execute on function public.role_of(uuid)   to authenticated;
grant execute on function public.is_admin()      to authenticated;
grant execute on function public.can_advertise() to authenticated;


-- ============================================================
-- APPLYING TO ADVERTISE
--
-- The deliberate front door. Somebody has to find the page, sign in,
-- and ask — and then you decide. Nobody arrives here by accident and
-- nobody arrives here by clicking around the app.
-- ============================================================

create table if not exists public.advertiser_applications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  business_name text not null,
  contact_email text,
  contact_phone text,
  website       text,
  message       text,
  status        text not null default 'pending',
  created_at    timestamptz not null default now(),
  decided_at    timestamptz,
  decided_by    uuid references public.profiles(id) on delete set null,
  decision_note text,

  constraint application_status check (status in ('pending', 'approved', 'declined')),
  constraint business_name_len check (char_length(business_name) between 2 and 80),
  constraint message_len check (message is null or char_length(message) <= 600)
);

-- One open application per person. Re-applying after a decline is
-- fine; nagging with five at once is not.
create unique index if not exists one_open_application_per_user
  on public.advertiser_applications (user_id)
  where status = 'pending';

create index if not exists applications_pending_idx
  on public.advertiser_applications (status, created_at desc);

alter table public.advertiser_applications enable row level security;

drop policy if exists "apply for yourself" on public.advertiser_applications;
create policy "apply for yourself"
  on public.advertiser_applications for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending');

drop policy if exists "see your own application" on public.advertiser_applications;
create policy "see your own application"
  on public.advertiser_applications for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- Withdrawing is allowed. Editing the verdict is not, so there is no
-- update policy for anyone but an admin, through the function below.
drop policy if exists "withdraw your own pending application" on public.advertiser_applications;
create policy "withdraw your own pending application"
  on public.advertiser_applications for delete to authenticated
  using (user_id = auth.uid() and status = 'pending');


-- ============================================================
-- CLOSING THE OPEN DOOR
--
-- The old policy let any authenticated user create an advertiser
-- record naming themselves. Now the role is the gate.
-- ============================================================

drop policy if exists "manage your own advertiser record" on public.advertisers;

create policy "advertisers manage their own record"
  on public.advertisers for all to authenticated
  using      (owner_id = auth.uid() and public.can_advertise())
  with check (owner_id = auth.uid() and public.can_advertise());

drop policy if exists "admins see every advertiser" on public.advertisers;
create policy "admins see every advertiser"
  on public.advertisers for select to authenticated
  using (public.is_admin());

-- Note on what happens when a role is revoked: the policy on `ads`
-- checks ownership by looking at `advertisers`, and that lookup is
-- itself subject to the policy above. So revoking the role hides the
-- advertiser row, which in turn makes their campaigns unmanageable.
-- Existing ads keep running — pulling paid placement off a live page
-- because of an account change would be the wrong default — but the
-- former advertiser can no longer edit or add any. Pause them
-- deliberately if that is what you mean to do.


-- ============================================================
-- ADMIN
-- ============================================================

create or replace function public.admin_list_applications(want_status text default 'pending')
returns table (
  id uuid,
  user_id uuid,
  handle text,
  display_name text,
  business_name text,
  contact_email text,
  contact_phone text,
  website text,
  message text,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id, a.user_id, p.handle, p.display_name,
    a.business_name, a.contact_email, a.contact_phone, a.website,
    a.message, a.status, a.created_at
  from public.advertiser_applications a
  join public.profiles p on p.id = a.user_id
  where public.is_admin()
    and (want_status is null or a.status = want_status)
  order by a.created_at desc
  limit 200;
$$;


-- Approving does three things at once, in one transaction: records the
-- verdict, grants the role, and creates the advertiser record they
-- will run campaigns under. Doing them separately leaves room for an
-- approved application with no account behind it.
create or replace function public.admin_decide_application(
  app_id  uuid,
  approve boolean,
  note    text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  app public.advertiser_applications%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only an admin may decide applications.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into app from public.advertiser_applications where id = app_id;
  if not found then
    raise exception 'No such application.' using errcode = 'no_data_found';
  end if;
  if app.status <> 'pending' then
    raise exception 'That application was already decided.' using errcode = 'check_violation';
  end if;

  update public.advertiser_applications
     set status = case when approve then 'approved' else 'declined' end,
         decided_at = now(),
         decided_by = auth.uid(),
         decision_note = note
   where id = app_id;

  if approve then
    -- Never demote an existing admin by approving their application.
    insert into public.user_roles (user_id, role, granted_by, note)
    values (app.user_id, 'advertiser', auth.uid(), note)
    on conflict (user_id) do nothing;

    insert into public.advertisers (owner_id, business_name, contact_email, contact_phone)
    values (app.user_id, app.business_name, app.contact_email, app.contact_phone);
  end if;
end;
$$;


create or replace function public.admin_set_role(target uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only an admin may change roles.' using errcode = 'insufficient_privilege';
  end if;

  -- An admin cannot remove their own admin rights. Locking yourself
  -- out of the only account that can grant access is a bad afternoon.
  if target = auth.uid() and new_role <> 'admin' then
    raise exception 'You cannot remove your own admin access.' using errcode = 'check_violation';
  end if;

  if new_role = 'member' then
    delete from public.user_roles where user_id = target;
  elsif new_role in ('advertiser', 'admin') then
    insert into public.user_roles (user_id, role, granted_by)
    values (target, new_role, auth.uid())
    on conflict (user_id) do update
      set role = excluded.role, granted_by = auth.uid(), granted_at = now();
  else
    raise exception 'Unknown role "%".', new_role using errcode = 'check_violation';
  end if;
end;
$$;


revoke all on function public.admin_list_applications(text)            from public, anon;
revoke all on function public.admin_decide_application(uuid, boolean, text) from public, anon;
revoke all on function public.admin_set_role(uuid, text)               from public, anon;

grant execute on function public.admin_list_applications(text)              to authenticated;
grant execute on function public.admin_decide_application(uuid, boolean, text) to authenticated;
grant execute on function public.admin_set_role(uuid, text)                 to authenticated;


-- ============================================================
-- THE FIRST ADMIN
--
-- There is no way to grant the first admin from inside the app,
-- because granting requires being one. It has to happen here, once.
--
-- This runs by email so there is no user id to look up. It is written
-- to be safe if run twice, and to do nothing at all if that email has
-- never signed in.
-- ============================================================

insert into public.user_roles (user_id, role, note)
select u.id, 'admin', 'first admin, set during migration'
from auth.users u
where lower(u.email) = lower('beholdalu@gmail.com')
on conflict (user_id) do update
  set role = 'admin';
