// ============================================================
// We Rondayview — route-matrix
//
// This runs on Supabase's servers, NOT in the browser.
// It is the only thing that ever sees your OpenRouteService key.
//
// It now handles two jobs, chosen with the "kind" field:
//   { kind: "matrix", origins, destinations }  -> drive times
//   { kind: "venues", lat, lng, radius }       -> nearby places
//
// Venues moved here because Overpass throttles anonymous browser
// traffic aggressively. Asked from a server, with a real User-Agent,
// it behaves. It also sidesteps browser CORS entirely.
//
// Deploy:
//   supabase secrets set ORS_API_KEY=your_key_here
//   supabase functions deploy route-matrix --no-verify-jwt
// ============================================================

const ORS_KEY = Deno.env.get("ORS_API_KEY");

const MAX_ORIGINS = 4;
const MAX_DESTINATIONS = 30;
const ALLOWED_PROFILES = ["driving-car", "cycling-regular", "foot-walking"];

const OVERPASS_MIRRORS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
];

const UA = "WeRondayview/1.0 (personal meeting-point app)";

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

  if (kind === "venues") return handleVenues(body);
  if (kind === "matrix") return handleMatrix(body);
  return json({ error: `Unknown kind "${kind}".` }, 400);
});
