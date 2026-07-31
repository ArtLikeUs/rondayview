// ============================================================
// We Rondayview — route-matrix
//
// This runs on Supabase's servers, NOT in the browser.
// It is the only thing that ever sees your OpenRouteService key.
//
// It handles four jobs, chosen with the "kind" field:
//   { kind: "matrix",  origins, destinations } -> drive times
//   { kind: "venues",  lat, lng, radius }      -> nearby places
//   { kind: "geocode", q }                     -> address to coordinates
//   { kind: "reverse", lat, lng }              -> coordinates to address
//
// Everything that talks to somebody else's service lives here rather
// than in the browser, for two different reasons.
//
// Overpass and Nominatim are volunteer-run and throttle anonymous
// browser traffic hard. Asked from one server, with a real User-Agent
// and a cache in front, they behave. Left in the browser, a few
// hundred visitors can get the whole app blocked at once — not one
// user at a time, all of them.
//
// OpenRouteService is different: the key is ours and the quota is
// 2,500 lookups a day. This function's address is in the page source
// and it must accept unauthenticated calls, because the app works
// signed out. So the rate limiter below is the only thing between a
// bored person and a day with no drive times.
//
// Deploy:
//   supabase secrets set ORS_API_KEY=your_key_here
//   supabase functions deploy route-matrix --no-verify-jwt
// ============================================================

const ORS_KEY = Deno.env.get("ORS_API_KEY");
const SB_URL  = Deno.env.get("SUPABASE_URL");
const SB_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const MAX_ORIGINS = 4;
const MAX_DESTINATIONS = 30;
const ALLOWED_PROFILES = ["driving-car", "cycling-regular", "foot-walking"];

const OVERPASS_MIRRORS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
];

const NOMINATIM = "https://nominatim.openstreetmap.org";

// Nominatim's terms ask for an application that can be identified and
// contacted. A generic browser User-Agent is exactly what they ask you
// not to send.
const UA = "WeRondayview/1.0 (https://rondayview.com; beholdalu@gmail.com)";

// Per caller, per hour. Generous for a person, tight for a script.
// Matrix is the strict one because it is the only job that spends a
// quota we pay for in outages.
const LIMITS: Record<string, number> = {
  matrix:  40,
  venues:  80,
  geocode: 200,
  reverse: 200,
};
const WINDOW_SECONDS = 3600;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ---------- talking to our own database ----------
// Uses the service role key, which only ever exists here. These
// functions are granted to service_role alone, so nothing reachable
// from a browser can count, or uncount, a request.
async function rpc(name: string, args: Record<string, unknown>): Promise<unknown> {
  if (!SB_URL || !SB_KEY) return null;
  try {
    const res = await fetch(`${SB_URL}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        "apikey": SB_KEY,
        "Authorization": `Bearer ${SB_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) {
      console.error(`rpc ${name} returned`, res.status, await res.text());
      return null;
    }
    return await res.json();
  } catch (e) {
    console.error(`rpc ${name} failed:`, e);
    return null;
  }
}

// The address the request came from, as far as we can tell.
function callerKey(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for") || "";
  const ip = fwd.split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "unknown";
  return ip;
}

// Returns null when the caller may proceed, or a response when they may not.
//
// Deliberately fails OPEN. If the database is unreachable the honest
// choice is to serve the request: a rate limiter that takes the app
// down when it has a bad minute has caused a worse outage than the
// abuse it was built to stop.
async function limited(req: Request, kind: string): Promise<Response | null> {
  const max = LIMITS[kind];
  if (!max) return null;

  const allowed = await rpc("rate_limit_hit", {
    bucket_key: `${kind}:${callerKey(req)}`,
    max_hits: max,
    window_seconds: WINDOW_SECONDS,
  });

  if (allowed === false) {
    console.error(`rate limited ${kind} for ${callerKey(req)}`);
    return json({
      error: "That is a lot of lookups in one hour. Give it a few minutes.",
    }, 429);
  }
  return null;
}

function isCoord(p: unknown): boolean {
  return Array.isArray(p) &&
    p.length === 2 &&
    Number.isFinite(p[0]) && Number.isFinite(p[1]) &&
    Math.abs(p[0] as number) <= 180 &&
    Math.abs(p[1] as number) <= 90;
}

// ---------- job 1: drive times ----------
async function handleMatrix(body: any): Promise<Response> {
  if (!ORS_KEY) {
    console.error("ORS_API_KEY secret is not set on this project.");
    return json({ error: "Routing is not configured on the server." }, 500);
  }

  const origins = body?.origins;
  const destinations = body?.destinations;
  const profile = body?.profile ?? "driving-car";

  if (!ALLOWED_PROFILES.includes(profile)) {
    return json({ error: "Unsupported travel mode." }, 400);
  }
  if (!Array.isArray(origins) || !Array.isArray(destinations)) {
    return json({ error: "origins and destinations must both be arrays." }, 400);
  }
  if (origins.length < 2 || origins.length > MAX_ORIGINS) {
    return json({ error: `Send between 2 and ${MAX_ORIGINS} origins.` }, 400);
  }
  if (destinations.length < 1 || destinations.length > MAX_DESTINATIONS) {
    return json({ error: `Send between 1 and ${MAX_DESTINATIONS} destinations.` }, 400);
  }

  const locations = [...origins, ...destinations];
  if (!locations.every(isCoord)) {
    return json({ error: "Coordinates must be [longitude, latitude] pairs." }, 400);
  }

  const sources = origins.map((_: unknown, i: number) => i);
  const targets = destinations.map((_: unknown, i: number) => origins.length + i);

  let upstream: Response;
  try {
    upstream = await fetch(
      `https://api.openrouteservice.org/v2/matrix/${profile}`,
      {
        method: "POST",
        headers: {
          "Authorization": ORS_KEY,          // <-- the secret, server-side only
          "Content-Type": "application/json",
          "Accept": "application/json",
          "User-Agent": UA,
        },
        body: JSON.stringify({
          locations,
          sources,
          destinations: targets,
          metrics: ["duration", "distance"],
          units: "mi",
        }),
      },
    );
  } catch (err) {
    console.error("Could not reach OpenRouteService:", err);
    return json({ error: "Routing service is unreachable." }, 502);
  }

  if (!upstream.ok) {
    console.error("OpenRouteService returned", upstream.status, await upstream.text());
    const message = upstream.status === 429
      ? "Daily routing limit reached. Straight-line mode still works."
      : "Routing service returned an error.";
    return json({ error: message }, 502);
  }

  const data = await upstream.json();
  return json({ durations: data.durations, distances: data.distances });
}

// ---------- job 2: nearby venues ----------
async function handleVenues(body: any): Promise<Response> {
  const lat = Number(body?.lat);
  const lng = Number(body?.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    return json({ error: "lat and lng must be valid coordinates." }, 400);
  }
  const radius = Math.min(Math.max(Number(body?.radius) || 2600, 300), 8000);

  const query = `[out:json][timeout:25];
(
  nwr["amenity"~"^(cafe|bar|pub|restaurant|fast_food|ice_cream|biergarten)$"]["name"](around:${radius},${lat},${lng});
  nwr["amenity"="fuel"](around:${radius},${lat},${lng});
  nwr["leisure"="park"]["name"](around:${radius},${lat},${lng});
);
out center 150;`;

  const tried: string[] = [];

  for (const url of OVERPASS_MIRRORS) {
    const host = new URL(url).hostname;
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "User-Agent": UA,
        },
        body: "data=" + encodeURIComponent(query),
        signal: AbortSignal.timeout(20000),
      });

      if (!res.ok) {
        tried.push(`${host}: HTTP ${res.status}`);
        continue;
      }

      // A busy Overpass answers with an HTML error page instead of JSON.
      const text = await res.text();
      try {
        const data = JSON.parse(text);
        return json({ elements: data.elements ?? [], source: host });
      } catch {
        tried.push(`${host}: non-JSON reply`);
      }
    } catch (e) {
      tried.push(`${host}: ${(e as Error).name === "TimeoutError" ? "timed out" : "unreachable"}`);
    }
  }

  console.error("All Overpass mirrors failed:", tried.join(" | "));
  return json({ error: `No venue directory answered (${tried.join("; ")})` }, 502);
}

// ---------- jobs 3 and 4: addresses ----------
//
// Cache first, always. An address that has been looked up once is
// answered from our own table for six months, which is both faster for
// the person waiting and the difference between being a good citizen
// of a free service and being the reason it blocks us.
async function handleGeocode(body: any): Promise<Response> {
  const q = String(body?.q ?? "").trim();
  if (q.length < 2) return json({ error: "Give me something to search for." }, 400);
  if (q.length > 200) return json({ error: "That search is too long." }, 400);

  const key = `s:${q.toLowerCase()}`;
  const cached = await rpc("geocode_lookup", { key });
  if (cached) return json({ results: cached, cached: true });

  let upstream: Response;
  try {
    upstream = await fetch(
      `${NOMINATIM}/search?format=jsonv2&limit=5&q=${encodeURIComponent(q)}`,
      { headers: { "User-Agent": UA, "Accept": "application/json" },
        signal: AbortSignal.timeout(10000) },
    );
  } catch (e) {
    console.error("nominatim unreachable:", e);
    return json({ error: "The address lookup service is not answering." }, 502);
  }

  if (!upstream.ok) {
    console.error("nominatim returned", upstream.status, await upstream.text());
    return json({ error: "The address lookup service returned an error." }, 502);
  }

  const results = await upstream.json();
  if (Array.isArray(results) && results.length) {
    await rpc("geocode_store", { key, kind_in: "search", payload: results });
  }
  return json({ results, cached: false });
}

async function handleReverse(body: any): Promise<Response> {
  const lat = Number(body?.lat), lng = Number(body?.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    return json({ error: "lat and lng must be valid coordinates." }, 400);
  }

  // Rounded to about 10 metres, so near-identical taps share an answer
  // instead of each costing a request.
  const key = `r:${lat.toFixed(4)},${lng.toFixed(4)}`;
  const cached = await rpc("geocode_lookup", { key });
  if (cached) return json({ result: cached, cached: true });

  let upstream: Response;
  try {
    upstream = await fetch(
      `${NOMINATIM}/reverse?format=jsonv2&lat=${lat}&lon=${lng}`,
      { headers: { "User-Agent": UA, "Accept": "application/json" },
        signal: AbortSignal.timeout(10000) },
    );
  } catch (e) {
    console.error("nominatim reverse unreachable:", e);
    return json({ error: "The address lookup service is not answering." }, 502);
  }

  if (!upstream.ok) {
    console.error("nominatim reverse returned", upstream.status);
    return json({ error: "The address lookup service returned an error." }, 502);
  }

  const result = await upstream.json();
  if (result && result.display_name) {
    await rpc("geocode_store", { key, kind_in: "reverse", payload: result });
  }
  return json({ result, cached: false });
}


// ---------- router ----------
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Body must be JSON." }, 400);
  }

  // No "kind" means an older client asking for drive times.
  const kind = body?.kind ?? "matrix";

  const handlers: Record<string, (b: any) => Promise<Response>> = {
    matrix:  handleMatrix,
    venues:  handleVenues,
    geocode: handleGeocode,
    reverse: handleReverse,
  };

  const handler = handlers[kind];
  if (!handler) return json({ error: `Unknown kind "${kind}".` }, 400);

  const blocked = await limited(req, kind);
  if (blocked) return blocked;

  // Clear out stale counters now and then. One in roughly two hundred
  // requests, which is often enough to keep the table small and rare
  // enough that nobody waits for it.
  if (Math.random() < 0.005) rpc("rate_limits_sweep", {});

  return handler(body);
});
