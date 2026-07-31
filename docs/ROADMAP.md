# Roadmap

Built in waves. Each one leaves the app working.

| Wave | What | State |
|---|---|---|
| 1 | Move into one project, under git | done |
| 2 | Database foundation — accounts, friends, places, ads, meetups, avatars | done, tested locally, **not yet applied to Supabase** |
| 3 | Sign in with a magic link; profiles with pictures | built; needs the migration run and your anon key — see `SETUP-ACCOUNTS.md` |
| 4 | Friends — search, request, accept, and pull a friend's address into a meetup | done |
| 5 | Suggest the best 3 places to meet, instead of a long list | done — no migration needed |
| 6 | Ad slots, ad serving, and a page for you to manage advertisers | done, live |
| 6b | Saving meetups — keep them, reopen them, delete them | done, no migration needed |
| 7 | Publish it | blocked on your call — nothing below here can be finished without it |
| 8 | App Store packaging | needs 7 |

## Decisions already made

- **Sign-in is an emailed magic link.** No passwords to store or reset. It also
  avoids Apple's rule that offering Google or Facebook login forces you to offer
  Sign in with Apple too.
- **The ad system is generic.** One `ads` table with a `format` column covers
  banners, featured business cards, and sponsored meeting spots, so selling a new
  kind of placement is a new value in a column rather than a new table.
- **Not published yet.** Still local. This is now the binding constraint: friends
  cannot reach each other until the app has a public address, so nobody but you
  can test wave 4 properly. Decide this before wave 5 or 6.
- **The three picks are chosen by rule, not by weighting.** Fairness is measured
  in share-error and multiplied by 100, so any "gas stations are worse" or
  "prefer variety" penalty small enough to be defensible gets buried under it.
  Both are therefore hard rules: a fuel stop only appears if there are not three
  real venues nearby, and each pick takes a different kind until the kinds run
  out. Tuning weights instead produced a Sunoco ranked third, and two parks in
  the top two.
- **Sharing a home address between friends is opt-in and off by default.** It is
  a genuine disclosure — coordinates are an address — so the app says so plainly
  rather than implying the trimmed label makes it private.

## Things deliberately left out for now

- **Money.** No rates, invoices, or payments table. The right shape for that
  depends on how you actually decide to charge, and guessing now means
  rebuilding later.
- **A paid place never enters the ranked three.** Sponsored spots sit below the
  picks under their own label. The ranking is the product: if a business can buy
  its way into "the evenest split nearby" then that claim is false, and the
  placement stops being worth anything to the next buyer too.
- **Trustworthy ad counts.** Impressions and clicks are currently reported by
  the browser, which means a determined person could inflate them from the
  developer console. That is fine while you are selling to local businesses you
  know personally. Before selling to anyone who audits their spend, that write
  needs to move behind an Edge Function.

## What the App Store actually needs

The blocker was never packaging — it is that today the app keeps everything in
one browser's local storage, so there is nothing to sign into and nothing that
follows you to a phone. Wave 2 fixes that. Still to come:

- A real hosted URL (wave 3 or later).
- A wrapper so the web app can ship as an iOS app.
- An Apple Developer account, $99/yr.
- A privacy policy and Apple's data-collection disclosures — required, and the
  answers depend on the schema, which is why `profile_private` keeps home
  addresses separate from public profiles.
- Enough native behaviour that Apple does not reject it as a repackaged website.
  Accounts, friends, saved meetups, and location already argue for this.
