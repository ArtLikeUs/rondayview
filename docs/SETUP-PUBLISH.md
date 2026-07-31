# Going live

Do these in order. Step 1 is the one that decides whether anybody but you
can actually sign in.

---

## 1. A real email sender — do this first

**Why it cannot wait:** Supabase's built-in email sender allows **2 emails per
day** on the free tier. Not per hour. Two. The third person who tries to sign in
gets nothing, no error, no link, and no reason to try again.

Supabase says as much themselves and expects you to bring your own sender.

### Which service

You do not own a domain, and that narrows it:

| Service | Free tier | Works without a domain? |
|---|---|---|
| **Brevo** | 300 emails/day, permanent | **Yes** — verify a single sender address |
| Resend | 3,000/month, permanent | No — needs a domain you control |
| SendGrid | 60-day trial only | — |

So: **Brevo**, unless you buy a domain.

One honest caveat. Gmail addresses cannot be domain-authenticated, so Brevo
rewrites your sending domain to `@brevosend.com` to satisfy the sender rules
Gmail and Yahoo have enforced since 2024. Mail will arrive, but it will look
like it came from a relay, and some of it will land in spam.

If you are going to sell ad space, buy the domain. A buyer who gets a receipt
from `@brevosend.com` draws a conclusion. About $12/year, and then Resend with a
verified domain gives you clean delivery and 3,000 a month.

### Setting up Brevo

1. Sign up at **brevo.com** — free plan, no card.
2. **Senders, Domains & Dedicated IPs → Senders → Add a sender.**
   Use `beholdalu@gmail.com`. They email you a verification link.
3. **SMTP & API → SMTP.** Copy the login and the SMTP key. The key is shown
   once — save it in your password manager, not in a note.
4. In Supabase: **Project Settings → Authentication → SMTP Settings** →
   *Enable Custom SMTP*, then:

   | Field | Value |
   |---|---|
   | Host | `smtp-relay.brevo.com` |
   | Port | `587` |
   | Username | your Brevo SMTP login |
   | Password | your Brevo SMTP key |
   | Sender email | `beholdalu@gmail.com` |
   | Sender name | `We Rondayview` |

5. Save, then sign out of the app and request a link to check it arrives.

**Check your spam folder on that first test.** If it landed there, everyone
else's will too.

---

## 2. Publish it

I could not run this — creating a public repository is a step the tooling
requires you to take yourself. One command:

```bash
cd ~/Developer/WeRondayView && gh repo create ArtLikeUs/rondayview --public --source=. --remote=origin --description "We Rondayview — find a fair place to meet in the middle" --push
```

Then turn on GitHub Pages:

```bash
gh api -X POST repos/ArtLikeUs/rondayview/pages -f "source[branch]=main" -f "source[path]=/"
```

Give it two or three minutes, then it is at:

**https://artlikeus.github.io/rondayview/**

---

## 3. Tell Supabase about the new address

Sign-in links will bounce until you do this.

1. **Authentication → URL Configuration**
2. **Site URL:** `https://artlikeus.github.io/rondayview/`
3. **Redirect URLs** — add both:
   - `https://artlikeus.github.io/rondayview/`
   - `http://localhost:8792/` (so it keeps working here)

---

## 4. Check it actually works

Once Pages has built:

- Open the URL on your phone. **Share → Add to Home Screen.** It should install
  with the proper icon and open without browser chrome.
- Sign in with the magic link from the phone, not the laptop. This is the path
  that breaks first, because it exercises the redirect URL and the new sender at
  the same time.
- Find a spot, save it, and confirm it appears under Saved meetups.

---

## What is still true after this

**Anyone can call your routing function.** Its address is in the page source and
it is deployed to accept unauthenticated calls, which it has to be — the app
works signed out. It refuses anything over 4 people and 30 destinations, but
there is no rate limit, so somebody could burn the 2,500 daily
OpenRouteService lookups. If that happens, drive time falls back to straight
line and the app keeps working. Worth fixing before you promote it anywhere.

**Geocoding runs from each visitor's browser** straight to OpenStreetMap's
Nominatim, whose usage policy asks for an identifying application and caps you
at one request a second. Venue lookup was already moved behind your own function
for exactly this reason. Address lookup should follow before real traffic.

**Ad counts still come from the browser** and could be inflated from a developer
console. Fine for buyers you know personally. See `SETUP-ADS.md`.
