# Turning on friends

One step this time.

1. Supabase dashboard → **SQL Editor** → **New query**
2. Paste all of `supabase/migrations/20260730000002_friends.sql`
3. **Run**

Safe to run twice.

**Did it work?** Reload the app. The Friends card should show a search box
instead of the red "needs one more migration" line.

---

## What it does

**Search for someone by handle or name, send a request, they accept.** Requests
show up in both directions so you can see what you are waiting on.

**Add a friend straight into a trip.** If they have chosen to share their
starting point, their location fills in by itself. If not, they are still added
and somebody types where they are starting from.

---

## Two things worth understanding

### Only the person who receives a request can accept it

Writing this wave turned up a real hole in the previous one. The rule said
either side of a friendship could update the row — which is correct for
blocking or withdrawing, but it also meant **the person who sent a request
could accept it themselves** and become your friend without you agreeing.

The reason it slipped through is worth knowing: a row-level rule only ever sees
the row being written, never the row as it was. It cannot tell "this was
pending a second ago" from "this was already accepted." So the check now lives
in a trigger, which can see both versions. Accepting is the addressee's call
and nobody else's, an accepted friendship cannot be quietly reverted to
pending, and a friendship cannot be re-pointed at a different person.

That was live on your project. It is fixed by running the migration above.

### Sharing your address is off by default, and it is a real disclosure

There is a new checkbox in your profile: *Let friends start a meetup from my
address.* It starts off.

When it is on, an accepted friend can use your home as their starting point.
Be clear-eyed about what that means: they get your coordinates, and coordinates
**are** your address. The app trims the house number off the label it shows, but
that is cosmetic — anyone can put a coordinate into a map. What the switch
genuinely buys you is that it is your choice, per account, and you can turn it
off again at any time.

Two guards sit behind it, both checked in the database rather than the browser:
you must actually be accepted friends, **and** they must have opted in. If
either is false, nothing comes back — and nothing explains why, so the app
cannot be used to work out who has an address saved. Your `profile_private` row
stays unreadable by everyone but you, sharing or not.
