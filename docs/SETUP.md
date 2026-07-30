# We Rondayview — connecting drive time safely

**What you're building:** a tiny program that lives on Supabase's servers and acts as a doorman. Your app knocks on the door and asks "how long is the drive?" The doorman goes and asks OpenRouteService using the secret key, then comes back with just the answer. The key never leaves the building.

**Time:** about 20 minutes. **Cost:** $0.

---

## Before you start

Open Terminal: press `Cmd + Space`, type `terminal`, hit Enter.

You'll see a line ending in `%` or `$`. That's the prompt — it's waiting for you. Type a command, press Enter, wait for the prompt to come back before typing the next one.

Two things that will save you:
- **Copy and paste the commands.** Don't retype them.
- **Nothing happening is often success.** Many of these print nothing when they work.

---

## Part 1 — Get your routing key (5 min)

1. Go to **https://openrouteservice.org/dev/#/signup**
2. Sign up. Free, no credit card.
3. Log in, and on the dashboard find **Request a token**.
4. Token type: **Free**. Name it `we-rondayview`. Click Create.
5. Copy the long string it gives you. Paste it somewhere temporary — Notes is fine for the next 15 minutes, then delete it.

You now have 2,500 free lookups per day. You will not come close.

---

## Part 2 — Make a Supabase project (3 min)

6. Go to **https://supabase.com** and sign in with GitHub.
7. Click **New project**.
8. Name: `we-rondayview`. Set a database password (save it in your password manager). Region: **West US (North California)** — closest to you.
9. Click Create. It takes about two minutes to spin up.
10. When it's ready, go to **Project Settings → General**. Find **Reference ID** — a random string like `abcdefghijklmnop`. Copy it.

---

## Part 3 — Install the Supabase tool (3 min)

11. In Terminal, check whether you already have Homebrew:

```
brew --version
```

If it prints a version number, skip to step 13. If it says `command not found`, run step 12.

12. Install Homebrew (this one takes a few minutes and will ask for your Mac password — type it, you won't see the characters appear, that's normal):

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

When it finishes it may print two `eval` lines telling you to run them. Run them.

13. Install the Supabase tool:

```
brew install supabase/tap/supabase
```

14. Confirm it worked:

```
supabase --version
```

You should see a version number.

---

## Part 4 — Set up the project folder (4 min)

15. Make a folder and go into it:

```
mkdir -p ~/Projects/we-rondayview
cd ~/Projects/we-rondayview
```

`cd` means "change directory" — it's how you tell Terminal which folder you're working in. Your prompt should now show `we-rondayview`.

16. Log in to Supabase from Terminal:

```
supabase login
```

This opens your browser. Approve it, come back to Terminal.

17. Start the project structure:

```
supabase init
```

If it asks about generating VS Code or IntelliJ settings, answer `n` — you don't need them.

18. Connect this folder to your Supabase project. Replace `YOUR_REFERENCE_ID` with the string you copied in step 10:

```
supabase link --project-ref YOUR_REFERENCE_ID
```

It will ask for your database password from step 8.

---

## Part 5 — Add the function (2 min)

19. Create the folder for it:

```
mkdir -p supabase/functions/route-matrix
```

20. Open the folder in Finder so you can drop the file in:

```
open supabase/functions/route-matrix
```

21. Drag the `index.ts` file I gave you into that Finder window.

22. Back in Terminal, confirm it's there:

```
ls supabase/functions/route-matrix
```

You should see `index.ts`.

---

## Part 6 — Store the key and deploy (3 min)

23. **This is the important step.** Store your OpenRouteService key as a server-side secret. Replace `paste_your_key_here` with the token from step 5:

```
supabase secrets set ORS_API_KEY=paste_your_key_here
```

That key now lives in Supabase's encrypted settings. It is never in your app, never in your HTML, never in anything you upload to Netlify.

24. Deploy:

```
supabase functions deploy route-matrix --no-verify-jwt
```

`--no-verify-jwt` means "let anyone call this" — necessary because your app has no login. The function protects itself instead by rejecting anything bigger than 4 people and 30 destinations, which is why those limits are in the code.

25. When it finishes it prints a URL. It looks like:

```
https://abcdefghijklmnop.supabase.co/functions/v1/route-matrix
```

Copy that.

---

## Part 7 — Connect the app (1 min)

26. Open We Rondayview.
27. Under **How it measures**, tap **Drive time**.
28. Paste the URL from step 25 into the box and hit **Save**.
29. The note underneath should turn green: *Connected.*
30. Enter two addresses and hit **Find the spot**. The badge on the result should say **Drive time** in pink, and the split should read in minutes instead of miles.

---

## Prove to yourself the key is hidden

31. In your browser, right-click the app → **View Page Source**.
32. Press `Cmd + F` and search for your OpenRouteService key.
33. **Zero results.** That's the whole point. The only thing in the page is your function's public address, which by itself does nothing but return drive times to whoever asks — capped and harmless.

---

## If something goes wrong

| What you see | What it means | Fix |
|---|---|---|
| Toast: *Routing is not configured on the server* | The secret didn't save | Redo step 23, then redeploy (step 24). Secrets need a redeploy to take effect. |
| Toast: *Routing server returned an error* | Usually a bad or expired token | Check the logs (below). Regenerate the token on openrouteservice.org if needed. |
| Toast: *Daily routing limit reached* | You hit 2,500 lookups | It resets 24 hours after your first call. Straight-line mode still works. |
| Nothing happens, badge stays grey | URL typo | Re-copy from step 25. It must end in `/functions/v1/route-matrix`. |
| `command not found: supabase` | Tool didn't install | Redo step 13. |

**To see the real error:** Supabase dashboard → **Edge Functions** → `route-matrix` → **Logs**. Your `console.error` messages show up there. That's deliberate — real errors go where only you can see them, and the app only ever gets a polite version.

---

## When you change the function later

```
cd ~/Projects/we-rondayview
supabase functions deploy route-matrix --no-verify-jwt
```

That's it. Two lines, every time.

---

## The rule to carry into every future project

Any key that can generate a bill or touch private data goes on a server. The browser gets a URL, never a secret. You already know this pattern from Supabase — the `anon` key is public *by design* and protected by row-level security. Everything else lives behind an Edge Function.
