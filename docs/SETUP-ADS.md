# Turning on ads

1. Supabase dashboard → **SQL Editor** → **New query**
2. Paste all of `supabase/migrations/20260730000003_ads.sql`
3. **Run**

Safe to run twice.

**Did it work?** Sign in, open **Advertising** in your account card. You should
get a form asking for a business name rather than an error.

---

## Selling your first slot

1. **Advertising** → create the buyer (business name, contact email)
2. **New ad** → choose what they bought, write it, set where it runs
3. Leave *Start running it now* unticked to save a draft. Drafts are never
   served and never counted.
4. Come back any time to **Pause** or **Run** it, and to read how many people
   saw and clicked it.

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
