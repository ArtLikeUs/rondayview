# Going live

You own **rondayview.com**, which changes two things for the better: mail can
come from your own domain, and the app can live at the domain instead of a
github.io subpath.

## Where things already stand

- Repository is public at **github.com/ArtLikeUs/rondayview**
- GitHub Pages is built and serving at **https://artlikeus.github.io/rondayview/**
- Verified live: HTTPS, map loads, Supabase connects, icons and manifest serve,
  service worker registers, no console errors

Two jobs left: mail, and the domain.

---

## 1. Resend — mail from your own domain

**Why this cannot wait:** Supabase's built-in sender allows **2 emails per day**
on the free tier. Not per hour. The third person who tries to sign in gets
nothing — no link, no error, no reason to try again.

Resend's free tier is 3,000 a month, and with your own domain the mail is
properly authenticated rather than relayed.

1. Sign up at **resend.com** — free plan, no card.
2. **Domains → Add Domain** → `rondayview.com`
3. Resend shows you a set of DNS records — typically one MX and two or three
   TXT records for DKIM and SPF. **These are specific to your account, so I
   cannot write them here.** Copy them from that screen.
4. Add them at your registrar alongside the GitHub records in step 2 below.
5. Back in Resend, hit **Verify**. Usually minutes; can take up to an hour.
6. **API Keys → Create API Key.** Copy it — it is shown once. Save it in your
   password manager. It is a secret; it does not go in this repository, and it
   does not go in a chat window.
7. In Supabase: **Project Settings → Authentication → SMTP Settings** →
   *Enable Custom SMTP*:

   | Field | Value |
   |---|---|
   | Host | `smtp.resend.com` |
   | Port | `587` |
   | Username | `resend` |
   | Password | your Resend API key |
   | Sender email | `hello@rondayview.com` |
   | Sender name | `We Rondayview` |

   Port 587 uses STARTTLS. If Supabase objects, 465 works too — that one is
   implicit TLS.

8. Sign out of the app and request a link to test it.

`hello@rondayview.com` does not need to be a real inbox to send from — Resend
only needs the domain verified. If you want replies to reach you, check whether
your Squarespace domain includes email forwarding; if it does not, point the
sender at an address you already read instead.

---

## 2. Point rondayview.com at the app

### The order matters

**Add the DNS records first. Do not set the custom domain in GitHub until they
resolve.** The moment a custom domain is set, the github.io address redirects to
it — so if DNS is not ready yet, the site goes dark until it is.

### At Squarespace

**account.squarespace.com/domains** → click **rondayview.com** → **DNS** in the
side panel → **Add record**.

Two things about Squarespace specifically, before you start:

- **Clear out the parking records first.** Registering a domain there leaves
  default records pointing at a Squarespace holding page. Any leftover `A`
  record on host `@` pointing at a Squarespace address will fight the GitHub
  ones and the result is a coin toss. Delete those; leave anything you did not
  put there yourself alone otherwise.
- **Squarespace auto-adds three TXT records** for DKIM, SPF and DMARC when you
  register. They are removed automatically as soon as you add your own email
  records, so when Resend's records go in and the Squarespace ones vanish, that
  is expected rather than something you broke.

### The records

Four **A** records for the apex, all with host `@`:

```
185.199.108.153
185.199.109.153
185.199.110.153
185.199.111.153
```

Four **AAAA** records, also host `@`, so it works over IPv6:

```
2606:50c0:8000::153
2606:50c0:8001::153
2606:50c0:8002::153
2606:50c0:8003::153
```

One **CNAME** record so the www version works too:

```
host: www    →    artlikeus.github.io
```

Plus whatever Resend gave you in step 1.

### Then check it has taken

```bash
dig +short rondayview.com
```

When that prints the four `185.199.*` addresses, DNS is live. Anywhere from
minutes to a few hours.

### Then tell me

I will add the `CNAME` file, set the custom domain, and turn on HTTPS
enforcement — or you can do it yourself:

```bash
gh api -X PUT repos/ArtLikeUs/rondayview/pages -f cname=rondayview.com -F https_enforced=true
```

GitHub issues the certificate itself, which takes a few more minutes.

---

## 3. Tell Supabase the new address

Sign-in links bounce until this matches wherever people actually load the app.

**Authentication → URL Configuration**

- **Site URL:** `https://rondayview.com/`
- **Redirect URLs** — add all of these:
  - `https://rondayview.com/`
  - `https://www.rondayview.com/`
  - `https://artlikeus.github.io/rondayview/`
  - `http://localhost:8792/`

Keeping the github.io entry means nothing breaks during the switch. Keeping
localhost means it still works here.

---

## 4. Check it properly

Once the certificate is issued:

- Open **https://rondayview.com** on your phone. **Share → Add to Home Screen.**
  It should install with the icon and open without browser chrome.
- **Sign in from the phone, not the laptop.** This is the path that breaks
  first: it exercises the redirect URL and the new sender at once.
- Check the mail did not land in spam. If it did for you, it will for everyone.
- Find a spot, save it, confirm it appears under Saved meetups.

---

## What is still true once this is done

**Anyone can call your routing function.** Its address is in the page source and
it accepts unauthenticated calls, which it must — the app works signed out. It
refuses more than 4 people or 30 destinations, but there is no rate limit, so
someone could burn the 2,500 daily OpenRouteService lookups. Drive time would
fall back to straight line and the app would keep working. Worth fixing before
you promote it anywhere.

**Geocoding runs from each visitor's browser** to OpenStreetMap's Nominatim,
whose usage policy asks for an identifying application and caps one request a
second. Venue lookup already moved behind your own function for this exact
reason; address lookup should follow before real traffic arrives.

**Ad counts still come from the browser** and could be inflated from a developer
console. Fine for buyers you know personally. See `SETUP-ADS.md`.
