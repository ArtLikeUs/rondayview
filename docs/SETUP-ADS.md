# Turning on ads

1. Supabase dashboard → **SQL Editor** → **New query**
2. Paste all of `supabase/migrations/20260730000003_ads.sql`
3. **Run**

Safe to run twice.

**Did it work?** Sign in, open **Advertising** in your account card. You should
get a form asking for a business name rather than an error.

---

## Who can do what

| Role | Can |
|---|---|
| **member** | Use the app. Never sees advertising tools, and cannot reach them by guessing a URL. |
| **advertiser** | Run campaigns for their own business. Granted by you, not self-selected. |
| **admin** | Everything, plus approve and revoke advertisers. You. |

A member has no row in `user_roles` at all — absence *is* the default, so there
is nothing to assign in the common case and nothing to get wrong.

Roles live in their own table rather than a column on `profiles` for a specific
reason: the profile update policy is `id = auth.uid()` across the whole row, so a
role column would have let anybody set themselves to admin with one request.

## Selling your first slot

Everything advertising-related lives at **/advertise.html** — reachable from a
small footer link, and nowhere else. The main app shows no advertising controls
to anyone.

1. A business owner goes to that page, signs in, and applies
2. You open the same page as an admin and see the queue
3. **Approve** — that grants the role and creates their business record in one
   step, so there is no half-state where an approved application has no account
   behind it
4. They can now build campaigns there. Everything saves as a **draft**; nothing
   runs until somebody hits Run

You can also just approve your own application and sell space to yourself, which
is the fastest way to see the whole thing working.

**Revoking:** an admin can set someone back to member. Their existing ads keep
running — pulling paid placement off a live page because of an account change
would be the wrong default — but they can no longer edit or add any. Pause the
campaigns deliberately if that is what you mean.

### The three things you can sell

| Format | Where it lands |
|---|---|
| **Banner** | A card under the search button |
| **Featured business** | A card under the result, once a spot has been found |
| **Sponsored spot** | A place shown *below* the three picks, labelled |

---

## Two decisions built into this, and why

### A paid place never enters the ranked three

A sponsored spot appears **below** the three picks, under its own label — it
never competes for one of the three slots.

This is deliberate, and it is worth holding onto when someone offers you money
to change it. The ranking is the product. The moment a business can buy its way
into *"the evenest split nearby"*, that sentence stops being true — and once
people notice, the placement is not worth anything to the next advertiser
either. You are selling the slot next to a recommendation people trust. That is
a better business than selling the recommendation, and it is the only version
that keeps working.

The app also stays honest when somebody takes the sponsored option: choosing it
recalculates the split for real. In testing that turned an even split into
76/24, and the app said so rather than quietly keeping the old number on screen.

### The counting is now defensible

This used to be a caveat. It is not any more.

Impressions and clicks are recorded behind the Edge Function using the service
role key, which the page never sees. The browser can **ask** for an event to be
recorded; it cannot record one, and it is not told whether the ask counted.
Being told would hand anyone trying to game it exactly the feedback they need.

Two people seeing an ad is worth twice one person seeing it twice, so repeats
from the same caller are dropped: an impression counts once per half hour, a
click once per five minutes. Clicking twice is impatience; clicking two hundred
times is not an audience.

If the database does not answer, the event is **not** recorded. An uncounted
impression is a rounding error; a double-counted one is a wrong invoice.

The rest was already enforced in the database: the daily cap, the date window
and the active check, so a stale page cannot keep billing an ended campaign and
an ad cannot be served past its allowance.

What you can honestly tell a buyer: these are unique views per half hour from
distinct callers, counted server-side, and neither you nor they can edit the
number. What it still is not: a third-party audited figure. Nobody at your scale
has one.

---

## What still needs the app published

Everything above works on your laptop. What does not:

- **A buyer cannot see their ad.** There is no address to send them to.
- **You cannot prove the audience.** Impressions on your own machine are not
  a number anybody should pay against.

So you can build campaigns, price them, and show a buyer the thing working on
your screen — but the first real invoice needs a public URL.
