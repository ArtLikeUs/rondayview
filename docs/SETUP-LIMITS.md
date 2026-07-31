# Rate limiting and the address cache

Two steps, in this order.

## 1. The migration

Supabase → **SQL Editor** → **New query** → paste all of
`supabase/migrations/20260731000004_rate_limits.sql` → **Run**.

Safe to run twice.

## 2. Redeploy the function

```bash
cd ~/Developer/WeRondayView && supabase functions deploy route-matrix --no-verify-jwt
```

That is it. Nothing changes in the app itself.

**Did it work?** Find a spot on https://rondayview.com. It should behave exactly
as before — the second search for the same town should feel quicker.

---

## What this actually fixes

### Somebody burning your routing quota

Your function's address is in the page source, and it has to accept
unauthenticated calls because the app works signed out. Until now the only
protection was a cap on request *size* — four people, thirty destinations. There
was nothing stopping one person sending that request a thousand times and
spending your 2,500 daily OpenRouteService lookups before lunch.

Now every request is counted against the address it came from:

| Job | Per hour, per caller |
|---|---|
| Drive times | 40 |
| Venue lookup | 80 |
| Address search | 200 |
| Reverse lookup | 200 |

Generous for a person, tight for a script. Drive times are strictest because
that is the only job spending a quota whose exhaustion you would actually feel.

**It deliberately fails open.** If the database cannot be reached, the request is
allowed through rather than refused. A rate limiter that takes your app down
during a bad minute has caused a worse outage than the abuse it was written to
prevent.

### Getting the whole app blocked by OpenStreetMap

Address lookups used to go from every visitor's browser straight to Nominatim,
which is volunteer-run and asks for one request a second from an application
that identifies itself. A browser sends neither.

The risk was never one impatient user being throttled — it was Nominatim
blocking the app, for everyone, at once.

Now the lookup goes through your own function, which identifies itself properly
and keeps answers for six months. Repeat searches never leave your server. The
same move was made for venue lookup earlier, for the same reason.

The direct browser call survives as a fallback for the seconds when your own
function is unavailable. Losing address search entirely because a server
hiccuped would be the worse trade.

---

## What is stored, and what is not

**The counters** hold an address, a job name, and a number. No account, no
search terms, nothing about what was looked for. Rows are deleted a day after
they go quiet, swept by the function itself so there is no schedule to set up.

**The cache** holds a search phrase and its coordinates. Not who searched it,
not when, and nothing tying it to an account. It is a dictionary, not a history.

Neither table is reachable from a browser. Row level security is on with **no
policies at all**, and the four functions are granted to `service_role` alone —
the key that exists only inside the Edge Function and never reaches the page.
Tested: an anonymous visitor and a signed-in user are both refused, on both
tables and all four functions.

---

## Still outstanding

**Ad counts still come from the browser.** Fine for buyers you know personally,
not fine for one who audits their spend. See `SETUP-ADS.md`.
