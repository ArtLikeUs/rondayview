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

### The counting is honest, but not yet auditable

Impressions and clicks are reported by the browser. Anyone who knows how to
open the developer console could inflate them.

That is genuinely fine for selling to local businesses you know, and it is the
normal place to start. What it is not fine for is a buyer who audits their
spend, or any buyer big enough to have a competitor motivated to run your
numbers up. Before that, the counting has to move somewhere the browser cannot
reach.

Some of that is already done: the daily cap, the date window and the
active check are all enforced in the database, so a stale page cannot keep
billing an ended campaign, and an ad cannot be served past its allowance.

---

## What still needs the app published

Everything above works on your laptop. What does not:

- **A buyer cannot see their ad.** There is no address to send them to.
- **You cannot prove the audience.** Impressions on your own machine are not
  a number anybody should pay against.

So you can build campaigns, price them, and show a buyer the thing working on
your screen — but the first real invoice needs a public URL.
