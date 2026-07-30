# We Rondayview

Find a fair place to meet in the middle.

People enter their addresses, choose how the travel should be split, and the app
finds a real venue where the split actually holds — measured either as
straight-line distance or as real drive time.

## What's here

| Path | What it is |
|---|---|
| `index.html` | The whole app. Single file, no build step. Leaflet for the map. |
| `supabase/functions/route-matrix/` | Edge Function. Holds the OpenRouteService key server-side and answers two questions: drive times (`kind: "matrix"`) and nearby venues (`kind: "venues"`). |
| `docs/SETUP.md` | Original step-by-step for standing up the Supabase side. |

## Running it locally

It's a static file. Anything that serves a directory works:

```bash
cd ~/Developer/WeRondayView && python3 -m http.server 8792
```

Then open http://localhost:8792

## Deploying the function

```bash
cd ~/Developer/WeRondayView && supabase functions deploy route-matrix --no-verify-jwt
```

## Where the secrets live

`ORS_API_KEY` is a Supabase secret, set with `supabase secrets set`. It is never
in this repository and never in the browser. The browser only ever knows the
public URL of the function.

## Roadmap

Planned, in order — see `docs/ROADMAP.md` once written:

1. Database foundation (accounts, profiles, friends, places, ads)
2. Sign-in and profiles with avatars
3. Friends
4. Top-3 suggested meeting places
5. Ad slots and ad serving
6. App Store packaging
