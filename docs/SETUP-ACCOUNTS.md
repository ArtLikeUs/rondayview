# Turning on accounts

Three steps. About ten minutes, no cost.

---

## 1. Run the database migration

Without this there is nothing to sign in to.

1. Supabase dashboard → **SQL Editor** → **New query**
2. Open `supabase/migrations/20260730000001_foundation.sql`, copy all of it, paste it in
3. Hit **Run**

Safe to run twice if you are not sure it took.

**Did it work?** Table Editor should list 10 new tables — `profiles`,
`profile_private`, `friendships`, `places`, `advertisers`, `ads`, `ad_events`,
`meetups`, `meetup_participants`, `user_devices`. Storage should show an
`avatars` bucket.

---

## 2. Let the sign-in link come back to the app

An emailed link has to know where to return you. Supabase refuses to send
people to addresses you have not approved, which is what stops someone
forging a link that signs you in on *their* page.

1. Dashboard → **Authentication** → **URL Configuration**
2. Under **Redirect URLs**, click Add URL and enter:

```
http://localhost:8792
```

3. Save.

When the app goes online later, its real address gets added here too.

---

## 3. Connect the app to your project

1. Dashboard → **Project Settings** → **API Keys**
2. Copy the **anon public** key — the long one starting `eyJ...`

   This one is public on purpose. It says *which* project you are talking to;
   it does not say what you are allowed to read. That is decided by the
   security rules from step 1. The key that must stay secret is the
   `service_role` one — never paste that anywhere.

3. Open the app, find **Your account**, paste the key, hit **Save**

It is remembered from then on.

---

## Then try it

1. Type your email, hit **Send link**
2. Open the email, click the link — you land back signed in
3. Click the pencil to set your name, handle, picture, and home address
4. Reload. Your home address should fill in "Me" by itself

---

## If something goes wrong

| What you see | What it means | Fix |
|---|---|---|
| *Invalid API key* | Wrong key, or a stray space | Re-copy the **anon public** key |
| *the database tables are missing* | Step 1 did not run | Redo step 1 |
| Link opens but you are still signed out | `http://localhost:8792` is not in Redirect URLs | Redo step 2 |
| No email arrives | Supabase's built-in mail is rate limited to a few per hour | Wait, or add your own SMTP under Authentication → Emails |
| *@name is already taken* | Somebody has that handle | Pick another |

---

## Worth knowing

**Your home address is stored apart from your profile.** Postgres security works
one row at a time, not one column at a time — so if your address sat on your
public profile row, making that row readable to people looking for friends would
have made your address readable too. It lives in `profile_private`, which only
you can read, ever. Not even a friend.

**Built-in email is for testing.** Supabase's shared mail server is rate limited
and will land in spam often enough to be annoying. Before real people use this,
point it at your own sender under Authentication → Emails.
