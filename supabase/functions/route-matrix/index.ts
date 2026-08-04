// ============================================================
// We Rondayview — route-matrix
//
// This runs on Supabase's servers, NOT in the browser.
// It is the only thing that ever sees your OpenRouteService key.
//
// It handles seven jobs, chosen with the "kind" field:
//   { kind: "matrix",     origins, destinations } -> drive times
//   { kind: "venues",     lat, lng, radius }      -> nearby places
//   { kind: "geocode",    q }                     -> address to coordinates
//   { kind: "reverse",    lat, lng }              -> coordinates to address
//   { kind: "road_check", lat, lng }              -> is this in live traffic?
//   { kind: "ad_event",   ad, event }             -> count an impression
//   { kind: "notify_application", application_id } -> tell the owner
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


// How long any one Overpass mirror gets before we stop caring.
//
// This used to be 20 seconds per mirror, tried in turn, so three busy
// mirrors cost 48 seconds before returning an error. Measured, not
// guessed. Racing them means the slow ones no longer add up, and eight
// seconds is long enough for a healthy mirror and short enough that a
// total outage is over quickly.
const OVERPASS_TIMEOUT_MS = 8000;

// Ask every mirror at once and take the first real answer.
//
// Overpass is free and volunteer-run, so at any moment some mirrors are
// busy and some are fine. Asking them in turn means paying for every
// busy one before reaching a working one; asking together means paying
// only for the fastest.
async function overpass(query: string): Promise<any> {
  const attempt = async (url: string) => {
    const host = new URL(url).hostname;
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": UA,
      },
      body: "data=" + encodeURIComponent(query),
      signal: AbortSignal.timeout(OVERPASS_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`${host}: HTTP ${res.status}`);
    // A busy Overpass answers with an HTML error page instead of JSON.
    const text = await res.text();
    let data: any;
    try { data = JSON.parse(text); }
    catch { throw new Error(`${host}: non-JSON reply`); }
    return { data, host };
  };

  try {
    return await Promise.any(OVERPASS_MIRRORS.map(attempt));
  } catch (err) {
    const reasons = (err as AggregateError).errors?.map(e => (e as Error).message).join("; ");
    throw new Error(reasons || "no Overpass mirror answered");
  }
}

// Per caller, per hour. Generous for a person, tight for a script.
// Matrix is the strict one because it is the only job that spends a
// quota we pay for in outages.
const LIMITS: Record<string, number> = {
  matrix:  40,
  venues:  80,
  geocode: 200,
  reverse: 200,
  road_check: 120,
  routes:     60,
  notify_application: 10,
  // Generous: a real session legitimately reports several ads, and the
  // dedupe rule downstream is what actually keeps the totals honest.
  ad_event: 400,
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
//
// Two directories, started together.
//
// It used to be Overpass alone, with the browser falling back to
// Nominatim only after Overpass had already given up — so a bad
// Overpass day cost 8 seconds of waiting and then another 30 for three
// sequential searches from the page. Measured at over 40 seconds end to
// end, which is why the app felt broken.
//
// Now both start at once and Overpass is merely preferred: if it
// answers we use it, because its data is richer, and if it does not the
// other one is already finished or nearly. Worst case becomes the
// slower of the two rather than the sum.

const CATEGORY: Record<string, [string, string]> = {
  cafe: ["coffee", "Coffee"], ice_cream: ["coffee", "Coffee"],
  bar: ["bar", "Bar"], pub: ["bar", "Bar"], biergarten: ["bar", "Bar"],
  restaurant: ["food", "Food"], fast_food: ["food", "Food"],
  fuel: ["fuel", "Gas"], park: ["park", "Park"],
  services: ["rest", "Rest stop"], rest_area: ["rest", "Rest stop"],
};

// Both sources get flattened to the same shape here rather than in the
// browser, so the page does not need to know which one answered.
function fromOverpass(elements: any[]): any[] {
  return elements.map((e) => {
    const lat = e.lat ?? e.center?.lat;
    const lng = e.lon ?? e.center?.lon;
    if (!lat || !e.tags) return null;
    const key = e.tags.amenity
      ?? (e.tags.leisure === "park" ? "park" : null)
      ?? (/^(services|rest_area)$/.test(e.tags.highway ?? "") ? e.tags.highway : null);
    const cat = CATEGORY[key as string];
    if (!cat) return null;
    const name = e.tags.name || e.tags.brand || e.tags.operator
      || (key === "fuel" ? "Gas station" : null)
      || (cat[0] === "rest" ? "Rest stop" : null);
    if (!name) return null;
    return {
      name, lat, lng, kind: cat[0], kindLabel: cat[1],
      sourceRef: e.type && e.id ? `${e.type}/${e.id}` : null,
      isServices: key === "services",
    };
  }).filter(Boolean);
}

async function venuesViaOverpass(lat: number, lng: number, radius: number): Promise<any[]> {
  const query = `[out:json][timeout:12];
(
  nwr["amenity"~"^(cafe|bar|pub|restaurant|fast_food|ice_cream|biergarten)$"]["name"](around:${radius},${lat},${lng});
  nwr["amenity"="fuel"](around:${radius},${lat},${lng});
  nwr["leisure"="park"]["name"](around:${radius},${lat},${lng});
  nwr["highway"~"^(services|rest_area)$"](around:${radius},${lat},${lng});
);
out center 80;`;
  const { data } = await overpass(query);
  const places = fromOverpass(data.elements ?? []);
  if (!places.length) throw new Error("overpass returned nothing usable");
  return places;
}

// Nominatim has no "everything nearby" query, so it takes one search per
// category. Their terms ask for no more than one request a second, which
// is the floor on how fast this can be — about three seconds. Still well
// under the eight Overpass is allowed.
async function venuesViaNominatim(lat: number, lng: number, radius: number): Promise<any[]> {
  const d = Math.max(radius, 2000) / 111000;   // degrees, roughly
  const vb = [(lng - d).toFixed(5), (lat + d).toFixed(5),
              (lng + d).toFixed(5), (lat - d).toFixed(5)].join(",");

  const searches: [string, string, string][] = [
    ["coffee", "coffee", "Coffee"],
    ["restaurant", "food", "Food"],
    ["gas station", "fuel", "Gas"],
  ];

  const out: any[] = [];
  for (let i = 0; i < searches.length; i++) {
    const [term, kind, kindLabel] = searches[i];
    try {
      const res = await fetch(
        `${NOMINATIM}/search?format=jsonv2&limit=15&bounded=1&viewbox=${vb}&q=${encodeURIComponent(term)}`,
        { headers: { "User-Agent": UA, "Accept": "application/json" },
          signal: AbortSignal.timeout(7000) },
      );
      if (res.ok) {
        for (const h of await res.json()) {
          const name = (h.name && h.name.trim()) || String(h.display_name ?? "").split(", ")[0];
          if (name) out.push({ name, lat: +h.lat, lng: +h.lon, kind, kindLabel, sourceRef: null, isServices: false });
        }
      }
    } catch { /* next category */ }
    if (i < searches.length - 1) await new Promise((r) => setTimeout(r, 1100));
  }
  if (!out.length) throw new Error("nominatim returned nothing");
  return out;
}

async function handleVenues(body: any): Promise<Response> {
  const lat = Number(body?.lat);
  const lng = Number(body?.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    return json({ error: "lat and lng must be valid coordinates." }, 400);
  }
  const radius = Math.min(Math.max(Number(body?.radius) || 2600, 300), 8000);

  // Rounded to about 110 metres, so two people searching the same
  // neighbourhood share an answer instead of each paying for one.
  const key = `venues:${lat.toFixed(3)},${lng.toFixed(3)}:${radius}`;
  const cached = await rpc("geocode_lookup", { key, max_age_days: 21 });
  if (cached) return json({ places: cached, source: "cache", cached: true });

  // Both start now. Overpass is awaited first because its data is
  // better, but the other is already running rather than waiting its
  // turn — that ordering is the whole fix.
  const overpassTry = venuesViaOverpass(lat, lng, radius);
  const nominatimTry = venuesViaNominatim(lat, lng, radius);
  nominatimTry.catch(() => {});   // it may never be needed; do not let it complain

  let places: any[] = [];
  let source = "overpass";
  try {
    places = await overpassTry;
  } catch (e) {
    console.error("overpass venues failed:", (e as Error).message);
    try {
      places = await nominatimTry;
      source = "nominatim";
    } catch (e2) {
      console.error("nominatim venues failed:", (e2 as Error).message);
      return json({ error: "No venue directory answered." }, 502);
    }
  }

  if (places.length) {
    await rpc("geocode_store", { key, kind_in: "venues", payload: places });
  }
  return json({ places, source, cached: false });
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

  // Where in the world the asker is, so a search for "Springfield" from
  // Texas does not lead with one in Europe. Two separate levers:
  // countrycodes is a hard filter, viewbox only nudges the ordering.
  const cc = String(body?.cc ?? "").toLowerCase().replace(/[^a-z,]/g, "").slice(0, 40);
  const nearLat = Number(body?.nearLat), nearLng = Number(body?.nearLng);
  const hasNear = Number.isFinite(nearLat) && Number.isFinite(nearLng);

  let extra = "";
  if (cc) extra += `&countrycodes=${cc}`;
  if (hasNear) {
    // Roughly 600km around them. bounded=0, so this orders results
    // rather than excluding anything outside the box.
    const d = 5.5;
    extra += `&viewbox=${(nearLng - d).toFixed(4)},${(nearLat + d).toFixed(4)},` +
             `${(nearLng + d).toFixed(4)},${(nearLat - d).toFixed(4)}&bounded=0`;
  }

  const key = `s:${cc}:${hasNear ? nearLat.toFixed(0) + "," + nearLng.toFixed(0) : ""}:${q.toLowerCase()}`;
  const cached = await rpc("geocode_lookup", { key });
  if (cached) return json({ results: cached, cached: true });

  let upstream: Response;
  try {
    upstream = await fetch(
      `${NOMINATIM}/search?format=jsonv2&limit=5&q=${encodeURIComponent(q)}${extra}`,
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

  let results = await upstream.json();

  // A hard country filter that finds nothing would otherwise strand
  // anybody searching for a real place abroad. Widen and retry once.
  if (cc && Array.isArray(results) && results.length === 0) {
    try {
      const retry = await fetch(
        `${NOMINATIM}/search?format=jsonv2&limit=5&q=${encodeURIComponent(q)}`,
        { headers: { "User-Agent": UA, "Accept": "application/json" },
          signal: AbortSignal.timeout(10000) },
      );
      if (retry.ok) results = await retry.json();
    } catch { /* keep the empty answer */ }
  }

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


// ---------- job: the actual roads people will drive ----------
//
// The map used to draw a dashed straight line from each person to the
// meeting point, which is honest about distance and wrong about
// everything else — it cuts across rivers, through the middle of a
// park, and past the bridge you actually have to use. Pittsburgh in
// particular makes a crow-flight line look ridiculous.
//
// This asks OpenRouteService for the real geometry. One request per
// person, capped at four because that is the most the app allows.
async function handleRoutes(body: any): Promise<Response> {
  if (!ORS_KEY) return json({ error: "Routing is not configured." }, 500);

  const origins = body?.origins;
  const dest = body?.destination;
  if (!Array.isArray(origins) || !origins.length || origins.length > MAX_ORIGINS) {
    return json({ error: `Send between 1 and ${MAX_ORIGINS} origins.` }, 400);
  }
  if (!isCoord(dest) || !origins.every(isCoord)) {
    return json({ error: "Coordinates must be [longitude, latitude] pairs." }, 400);
  }
  const profile = ALLOWED_PROFILES.includes(body?.profile) ? body.profile : "driving-car";

  // All at once — four sequential round trips would be four times the wait.
  const legs = await Promise.all(origins.map(async (o: number[]) => {
    try {
      const res = await fetch(
        `https://api.openrouteservice.org/v2/directions/${profile}/geojson`,
        {
          method: "POST",
          headers: {
            "Authorization": ORS_KEY,
            "Content-Type": "application/json",
            "Accept": "application/geo+json",
            "User-Agent": UA,
          },
          body: JSON.stringify({ coordinates: [o, dest] }),
          signal: AbortSignal.timeout(9000),
        },
      );
      if (!res.ok) {
        console.error("directions returned", res.status);
        return null;
      }
      const gj = await res.json();
      const coords = gj?.features?.[0]?.geometry?.coordinates;
      if (!Array.isArray(coords)) return null;
      // Back to [lat, lng] so the map can use it without converting.
      return coords.map((c: number[]) => [c[1], c[0]]);
    } catch (e) {
      console.error("directions failed:", e);
      return null;
    }
  }));

  // A null leg means that one person's route could not be drawn. The
  // caller falls back to a straight line for that person only, rather
  // than losing every line because one failed.
  return json({ legs });
}


// ---------- job 5: is this point stuck on a fast road? ----------
//
// Asked of the road network directly, because the obvious method does
// not work. Reverse geocoding returns the nearest *named* feature, which
// beside a motorway is regularly a school, a trail, or a service road a
// hundred metres away — so a point in live traffic comes back looking
// like a quiet street. Tested and confirmed before writing this.
//
// Overpass knows where the carriageways actually are. If one passes
// within 30 metres of the point, that point is on or beside it.
async function handleRoadCheck(body: any): Promise<Response> {
  const lat = Number(body?.lat), lng = Number(body?.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    return json({ error: "lat and lng must be valid coordinates." }, 400);
  }

  const key = `road:${lat.toFixed(4)},${lng.toFixed(4)}`;
  const cached = await rpc("geocode_lookup", { key });
  if (cached) return json({ ...(cached as object), cached: true });

  const query = `[out:json][timeout:20];
way(around:30,${lat},${lng})["highway"~"^(motorway|motorway_link|trunk|trunk_link)$"];
out tags 3;`;

  try {
    const { data } = await overpass(query);
    const roads = (data.elements ?? []) as any[];
    const payload = {
      onHighway: roads.length > 0,
      roads: roads.map(r => r.tags?.ref || r.tags?.name || r.tags?.highway).filter(Boolean).slice(0, 3),
    };
    await rpc("geocode_store", { key, kind_in: "road", payload });
    return json({ ...payload, cached: false });
  } catch (e) {
    console.error("road check:", (e as Error).message);
  }

  // Nobody answered. Say so rather than guessing — the caller treats an
  // unknown as safe, because refusing every meeting point whenever
  // Overpass is busy would be its own kind of broken.
  console.error("road check: no Overpass mirror answered");
  return json({ onHighway: false, unknown: true });
}


// ---------- job 6: tell the owner an application landed ----------
//
// Fired by the page after an application is saved. It cannot be used to
// email anybody else: the recipient is fixed below, so the worst a
// determined caller achieves is telling you about your own inbox twice,
// and the once-per-application guard stops even that.
//
// It reads the application with the service role key rather than
// trusting what the page sent, so the email describes what is actually
// in the database.
const OWNER_EMAIL = "beholdalu@gmail.com";
const MAIL_FROM   = "We Rondayview <hello@rondayview.com>";
const RESEND_KEY  = Deno.env.get("RESEND_API_KEY");

function escapeHtml(s: string): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}

async function handleNotifyApplication(body: any): Promise<Response> {
  const id = String(body?.application_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "Bad application id." }, 400);

  // One email per application, ever.
  const first = await rpc("rate_limit_hit", {
    bucket_key: `appnotify:${id}`, max_hits: 1, window_seconds: 86400,
  });
  if (first !== true) return json({ ok: true, sent: false });

  if (!RESEND_KEY || !SB_URL || !SB_KEY) {
    console.error("RESEND_API_KEY is not set; cannot send the notification.");
    return json({ ok: true, sent: false });
  }

  // Read it back rather than trusting the caller's description of it.
  let app: any = null;
  try {
    const res = await fetch(
      `${SB_URL}/rest/v1/advertiser_applications?id=eq.${id}&select=business_name,contact_email,contact_phone,website,message,status`,
      { headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` },
        signal: AbortSignal.timeout(5000) },
    );
    app = (await res.json())?.[0] ?? null;
  } catch (e) {
    console.error("could not read application:", e);
  }
  if (!app || app.status !== "pending") return json({ ok: true, sent: false });

  const rows = [
    ["Business", app.business_name],
    ["Email", app.contact_email],
    ["Phone", app.contact_phone],
    ["Website", app.website],
  ].filter(([, v]) => v)
   .map(([k, v]) => `<tr><td style="padding:4px 12px 4px 0;color:#584a72">${k}</td><td style="padding:4px 0"><strong>${escapeHtml(String(v))}</strong></td></tr>`)
   .join("");

  const html = `
    <div style="font-family:-apple-system,Segoe UI,sans-serif;font-size:15px;color:#221833;line-height:1.5">
      <p style="font-size:17px;margin:0 0 14px"><strong>Somebody wants to advertise.</strong></p>
      <table style="border-collapse:collapse;margin-bottom:14px">${rows}</table>
      ${app.message ? `<p style="background:#f5f1fb;border-left:3px solid #E0246E;padding:10px 12px;margin:0 0 16px">${escapeHtml(app.message)}</p>` : ""}
      <p style="margin:0"><a href="https://rondayview.com/advertise.html"
         style="background:#E0246E;color:#fff;text-decoration:none;padding:10px 18px;border-radius:8px;display:inline-block">
         Review it</a></p>
    </div>`;

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: MAIL_FROM,
        to: [OWNER_EMAIL],
        reply_to: app.contact_email || undefined,
        subject: `Advertising request — ${app.business_name}`,
        html,
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) {
      console.error("resend returned", res.status, await res.text());
      return json({ ok: true, sent: false });
    }
  } catch (e) {
    console.error("resend unreachable:", e);
    return json({ ok: true, sent: false });
  }

  return json({ ok: true, sent: true });
}


// ---------- job 7: counting an ad ----------
//
// The browser asks; it does not tell. Recording happens here with the
// service role key, which the page never sees, so an inflated number
// cannot come from a developer console.
//
// Two people seeing an ad is worth twice one person seeing it twice,
// so a repeat from the same caller inside the dedupe window is dropped
// silently. The caller still gets a 200 — whether their event counted
// is not their business, and telling them would hand anyone trying to
// game it the feedback they need.
async function handleAdEvent(req: Request, body: any): Promise<Response> {
  const ad = String(body?.ad ?? "");
  const kind = String(body?.event ?? "");

  if (!/^[0-9a-f-]{36}$/i.test(ad)) return json({ error: "Bad ad id." }, 400);
  if (kind !== "impression" && kind !== "click") {
    return json({ error: "Unknown ad event." }, 400);
  }

  const fresh = await rpc("ad_event_is_new", {
    ad_id_in: ad, kind_in: kind, caller: callerKey(req),
  });

  // fresh === null means the database did not answer. Do not record:
  // an uncounted impression is a rounding error, a double-counted one
  // is a wrong invoice.
  if (fresh === true) {
    await rpc("record_ad_event", {
      ad, kind,
      at_lat: Number.isFinite(Number(body?.lat)) ? Number(body.lat) : null,
      at_lng: Number.isFinite(Number(body?.lng)) ? Number(body.lng) : null,
    });
  }

  return json({ ok: true });
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
    matrix:     handleMatrix,
    venues:     handleVenues,
    geocode:    handleGeocode,
    reverse:    handleReverse,
    road_check: handleRoadCheck,
    routes:     handleRoutes,
    ad_event:   (b) => handleAdEvent(req, b),
    notify_application: handleNotifyApplication,
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
