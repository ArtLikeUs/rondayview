-- ============================================================
-- We Rondayview — make the ad counting defensible
--
-- Until now the browser reported its own impressions and clicks. That
-- was fine while nobody was paying, and it stops being fine the moment
-- somebody does: a person with the developer console open could have
-- run up any number they liked, in either direction — inflating their
-- own placement, or a competitor's spend.
--
-- Counting now happens behind the Edge Function, with the service role
-- key, which the page never sees. The browser can ask for an event to
-- be recorded; it cannot record one.
--
-- Safe to re-run.
-- ============================================================


-- ------------------------------------------------------------
-- Close the browser's direct route in
--
-- The foundation migration let anyone insert into ad_events, on the
-- reasoning that anyone can see an ad. True, but it also meant anyone
-- could claim to have seen one a thousand times.
-- ------------------------------------------------------------
drop policy if exists "anyone may record an ad event" on public.ad_events;

-- Nothing replaces it. With row level security on and no insert policy,
-- the only thing that can write to this table is service_role, which
-- bypasses it — and that key exists only inside the Edge Function.

-- Reading stays exactly as it was: an advertiser sees their own totals
-- and nobody else's. That policy is untouched.


-- ------------------------------------------------------------
-- And close the front door too
--
-- record_ad_event was callable by anon and authenticated. Now only the
-- Edge Function may call it.
-- ------------------------------------------------------------
revoke all on function public.record_ad_event(uuid, text, double precision, double precision)
  from public, anon, authenticated;
grant execute on function public.record_ad_event(uuid, text, double precision, double precision)
  to service_role;


-- ------------------------------------------------------------
-- Honest totals
--
-- Two people seeing an ad is worth twice one person seeing it twice.
-- Without a rule saying so, a reload is indistinguishable from an
-- audience, and the number you show a buyer means nothing.
--
-- The Edge Function asks this before recording anything. It reuses the
-- rate-limit counters rather than keeping a second ledger, so the same
-- daily sweep clears it and nothing extra needs maintaining.
-- ------------------------------------------------------------
create or replace function public.ad_event_is_new(
  ad_id_in  uuid,
  kind_in   text,
  caller    text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  -- An impression counts once per half hour per person. A click counts
  -- once per five minutes: clicking twice is plausible impatience,
  -- clicking two hundred times is not.
  window_secs integer := case when kind_in = 'click' then 300 else 1800 end;
begin
  return public.rate_limit_hit(
    format('adevent:%s:%s:%s', kind_in, ad_id_in, caller),
    1,
    window_secs
  );
end;
$$;

revoke all on function public.ad_event_is_new(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ad_event_is_new(uuid, text, text) to service_role;
