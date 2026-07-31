# Highway safety, and application emails

Two steps.

## 1. Add the Resend key as a secret

```bash
cd ~/Developer/WeRondayView && supabase secrets set RESEND_API_KEY=your_resend_key_here
```

Same key you put in the Supabase SMTP settings. This puts it where the Edge
Function can reach it, which is a different place — SMTP settings are for
Supabase's own sign-in emails; this is for emails the app sends itself.

## 2. Redeploy the function

```bash
cd ~/Developer/WeRondayView && supabase functions deploy route-matrix --no-verify-jwt
```

No migration this time.

---

## Never meet on a highway

Your friend was right, and it was a real fault rather than a bad roll.

When no named venue wins — no cafes nearby, or the venue directory is having a
bad minute — the answer falls back to a bare coordinate. A bare coordinate is
just the fair point between everybody, and the fair point between two towns is
very often the middle of an interstate.

### How it is caught

**Not by reverse geocoding.** That was the first attempt and it does not work.
Reverse geocoding returns the nearest *named* feature, which beside a motorway
is regularly a school, a trail, or a service road a hundred metres off. Tested
on five real interstate points: **every one came back looking like a quiet
street.** A school, in one case.

So the question goes to the road network instead. If a way tagged `motorway`,
`motorway_link`, `trunk` or `trunk_link` passes within 30 metres of the point,
the point is in traffic. Verified against a coordinate taken directly off I-279
— caught, three carriageways within 30 metres — and against ordinary Pittsburgh
streets, which are not.

`primary` and `secondary` are deliberately allowed. Plenty of ordinary high
streets carry those tags, and refusing them would make the app useless across
half the country.

### What happens then

The meeting point moves to the nearest place you can actually stop, the split is
recalculated for real, and the app says why. If there is genuinely nothing, it
says that too rather than offering the hard shoulder.

### The exception you asked for

Rest stops and motorway services are now searched for, and they are the one kind
of place beside a fast road that can be suggested.

They have to earn it. OpenStreetMap does not record "this rest area has a gas
station", so it is worked out: we already fetch fuel stations in the same query,
so a rest area with a pump within about 250 metres qualifies. A motorway service
area qualifies automatically — fuel is what makes it a service area. **A lay-by
with no pump is never suggested.** It is somewhere to pull over, not somewhere to
arrange to meet a friend.

Rest stops also rank as a last resort, alongside gas stations — so they fill in
exactly when there is nothing better, which is the situation a highway meeting
point creates in the first place.

---

## An email when somebody applies

When an application is saved, you get an email with the business, their contact
details, what they wrote, and a button to review it.

- **It can only ever email you.** The recipient is fixed in the function, so the
  worst a determined caller achieves is telling you about your own inbox.
- **One email per application, ever**, enforced by the same counters the rate
  limiter uses.
- **It reads the application back from the database** rather than trusting what
  the page sent, so the email describes what was actually saved.
- If Resend is having a bad minute the application is still saved. The applicant
  never sees a mail failure, because it is not their problem.

Replies go to the applicant's address, so you can just hit reply.
