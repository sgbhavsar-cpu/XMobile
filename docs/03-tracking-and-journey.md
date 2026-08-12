# 03 — Tracking & journey state machine

This is the hardest part of the system and the one most likely to be judged as "broken" by
users, so it is specified in detail.

## 1. What "accurate and reliable" has to mean here

You asked for accurate, reliable auto-detection of: left home, reached customer, started
back, reached home. On a mixed Android/iOS BYOD fleet, the honest engineering position is:

> The phone cannot be relied upon to emit a continuous, timely stream. It can be relied upon
> to emit *some* evidence around every significant transition, eventually. Therefore the
> device detects opportunistically, and the **server decides**, with the ability to revise
> its decision when late evidence arrives.

Everything below follows from that. Three properties are non-negotiable:

1. **Durability over immediacy** — an event that reaches the server 6 hours late must still
   produce the correct journey. All inference is a pure function of the evidence in a time
   window, re-runnable at any time.
2. **Confidence, not certainty** — every detection carries a score and its evidence. Low
   confidence surfaces for confirmation instead of silently becoming fact.
3. **Correctability** — the rep can adjust any detected time; the original is retained.

## 2. Evidence sources

| Source | Android | iOS | Reliability | Use |
|---|---|---|---|---|
| Foreground-service location stream | Yes, with notification | Background updates with `Always` + `allowsBackgroundLocationUpdates`; may be suspended | High / Medium | Breadcrumbs, speed, distance |
| Geofence / region monitoring | `GeofencingClient`, ~100 regions | `CLCircularRegion`, **hard limit 20 regions** | High | Arrival/departure trigger, wakes app |
| Significant location change | — | `startMonitoringSignificantLocationChanges` | Medium | Wakes a suspended app, coarse (~500 m) |
| Visit monitoring | — | `CLVisit` (arrival/departure at places) | Medium-High | Excellent corroboration for dwell |
| Activity recognition | `ActivityRecognitionClient` | `CMMotionActivityManager` | Medium | Motion gating, travel-mode inference |
| Motion/step sensors | Yes | Yes | High for "is stationary" | Suppress GPS while parked |
| Cell/WiFi fused location | Yes | Yes | Low accuracy, low battery | Gap filling |
| Manual user action | Both | Both | Highest trust | Check-in, "I've left", corrections |

**The 20-region iOS limit is a design constraint, not a detail.** A rep may have 40
customers in their working set. The app therefore maintains a *dynamic geofence set*:

- always registered: home, current tour's next 2 planned sites, current site if inside one;
- remaining slots filled by nearest sites to the last known position;
- a "re-arm" fence: a large radius (~10 km) circle around the last position whose exit
  triggers a recompute of the nearest-site set.

Android gets the same algorithm with a larger budget (up to ~90 fences), which keeps one
implementation.

## 3. Client-side collection policy

Adaptive, motion-gated. The app runs one of four sampling profiles:

| Profile | Trigger | Interval | Accuracy request | Displacement filter |
|---|---|---|---|---|
| `IDLE` | Stationary > 5 min, not near a site | Geofence/motion-triggered only | — | — |
| `DWELL` | Inside a site or home geofence | 5 min | Balanced | 100 m |
| `MOVING_LOCAL` | In motion, speed < 25 km/h | 30 s | High | 25 m |
| `TRANSIT` | Speed > 25 km/h sustained | 60–120 s | Balanced | 250 m |

Additional rules:
- Discard pings with `accuracy_m > 100` for *decisions*, but still store them (they are
  evidence of presence in an area, and useful for gap analysis).
- Never let a low-accuracy ping trigger a state transition on its own.
- On battery < 15 %, drop to `TRANSIT` cadence regardless of profile and raise an anomaly so
  the gap is explainable rather than mysterious.
- Every ping is written to the local durable queue **before** any upload attempt.
- Batch upload every 60 s on WiFi/4G, or on any transition event (transitions flush immediately).

### Tracking window (per the hybrid decision)

- Auto-start when: a tour enters `IN_PROGRESS`, or the day has a visit plan and the clock
  reaches `shift_start − 60 min`, whichever is earlier.
- Auto-stop when: tour `COMPLETED` and rep is at home, or `shift_end + 60 min` with no open visit.
- Rep may pause. Pause requires a reason code, writes `tracking_pause`, shows a persistent
  reminder, and **auto-resumes** after a configurable cap (default 60 min) to prevent a
  "forgotten pause" swallowing the day.
- Every pause is an auditable exception on the manager's dashboard. The system does not
  block pausing — it makes it visible.

## 4. Journey state machine

### States

| State | Meaning |
|---|---|
| `AT_HOME` | Inside home geofence |
| `OUTBOUND_TRANSIT` | Left home, has not yet reached the first customer of the tour |
| `AT_CUSTOMER` | Inside a customer site geofence |
| `INTER_TRANSIT` | Between two customer sites |
| `OVERNIGHT_STOP` | Stationary > `overnight_threshold` (default 4 h, between 21:00–07:00 local) away from home and not at a customer |
| `RETURN_TRANSIT` | Heading home after the last planned/actual visit |
| `PAUSED` | Rep paused tracking |
| `UNKNOWN` | No usable evidence for > `gap_threshold` (default 45 min) |

### Transitions

```
AT_HOME ──DEPART_HOME──────────────► OUTBOUND_TRANSIT
OUTBOUND_TRANSIT ──ARRIVE_CUSTOMER─► AT_CUSTOMER
AT_CUSTOMER ──DEPART_CUSTOMER──────► INTER_TRANSIT | RETURN_TRANSIT
INTER_TRANSIT ──ARRIVE_CUSTOMER────► AT_CUSTOMER
any_away ──STOP_DETECTED (night)───► OVERNIGHT_STOP
OVERNIGHT_STOP ──RESUME_TRAVEL─────► OUTBOUND_TRANSIT | INTER_TRANSIT | RETURN_TRANSIT
* ──START_RETURN─────────────────► RETURN_TRANSIT
RETURN_TRANSIT ──ARRIVE_HOME───────► AT_HOME   (tour COMPLETED)
* ──PAUSE / RESUME────────────────► PAUSED / previous state
* ──evidence gap──────────────────► UNKNOWN → resolved on next evidence
```

### Detection rules

Each rule produces a candidate event with a confidence in `[0,1]`. A candidate is
**auto-confirmed** at ≥ 0.75, **held for confirmation** between 0.45 and 0.75, and
**discarded** below 0.45 (but logged).

#### DEPART_HOME

Fires when *all* hold:
- an exit event for the home geofence, or ≥ 2 consecutive pings > `home_radius + 100 m` from home;
- sustained displacement: > 500 m from home within 10 min, monotonically increasing;
- activity is `in_vehicle`, `on_bicycle`, `walking`, or unknown-but-moving.

`occurred_at` = the timestamp of the **last** ping still inside the home fence, not the
first one outside. This matters: on iOS the first outside-ping can be 20 minutes late, and
using it would systematically overstate departure time.

Confidence: 0.95 with a geofence exit + corroborating motion; 0.8 with pings only;
0.6 if reconstructed from a gap (first evidence of the day is already 40 km away — then
`occurred_at` is back-estimated from distance ÷ assumed speed and marked `is_estimated`).

#### ARRIVE_CUSTOMER

- geofence enter for a site, **and** dwell ≥ `min_dwell` (default 4 min) inside it; or
- ≥ 3 pings within the radius spanning ≥ 4 min with `accuracy_m ≤ 60`; or
- iOS `CLVisit` arrival within radius; or
- **rep taps Check-In** → confidence 1.0, always wins.

`occurred_at` = the first ping inside the radius (after accuracy filtering).
Site match: nearest site whose radius contains the point; if two overlap, prefer the one on
today's plan, else the nearer centre, and record the ambiguity in `evidence`.

Confidence penalty of −0.2 if the site's `geo_source = GEOCODED` and unverified.

#### DEPART_CUSTOMER

- geofence exit + 500 m sustained displacement within 15 min; or
- rep taps Check-Out (confidence 1.0).

`occurred_at` = last ping inside the radius. If the visit is still open when a departure is
detected, the app prompts "Looks like you've left <Customer>. Close the visit?" and the
auto-close job closes it if unanswered.

#### START_RETURN

The genuinely ambiguous one — "heading home" looks identical to "heading to the next
customer" for the first few kilometres. Signals combined:

1. No remaining incomplete visit plans for the tour (strong, +0.4);
2. bearing/route consistent with decreasing distance-to-home over ≥ 3 consecutive fixes,
   with cumulative distance-to-home decrease > 15 % (+0.3);
3. distance from home is decreasing while distance from all remaining planned sites is
   increasing (+0.2);
4. rep taps "Heading home" (+1.0, and it is offered as a one-tap action on the tour screen);
5. departure from an `OVERNIGHT_STOP` on the tour's last planned day (+0.15).

Below 0.75 the event is provisional: the segment is recorded as `RETURN_TRANSIT (provisional)`
and is retroactively reclassified to `INTER_TRANSIT` if the rep then arrives at a customer.
Retroactive reclassification is cheap because segments are rebuilt from events, not
incrementally mutated.

#### ARRIVE_HOME

- geofence enter for the *effective* home location + dwell ≥ 10 min; or
- stationary ≥ 30 min within `home_radius`; or manual confirmation.

`occurred_at` = first ping inside the fence. On arrival, if the tour has no remaining
planned days, the tour is proposed for completion (rep confirms, or auto-completes after 12 h).

#### OVERNIGHT_STOP

Stationary (< 250 m spread) for ≥ 4 h, away from home, not inside a customer fence, with
the window overlapping 21:00–07:00 device-local. Produces a stay location used to prompt
"Add hotel expense?" — a small feature that materially improves expense capture rates.

### Travel-mode inference

Per segment, from median and 95th-percentile speed, path straightness, and activity samples:

| Mode | Heuristic |
|---|---|
| `WALK` | median < 6 km/h, activity mostly `walking`/`on_foot` |
| `TWO_WHEELER` | median 15–45 km/h, high heading variance, `on_bicycle`/`in_vehicle` |
| `CAR` | median 25–80 km/h, road-following path |
| `RAIL` | median > 60 km/h sustained, very straight path, few stops, path near known rail corridors if available |
| `AIR` | ground speed > 250 km/h or a > 200 km jump across a > 30 min gap with airport-proximate endpoints |
| `UNKNOWN` | insufficient evidence — never guessed silently |

The rep can override the mode; mileage claims use the confirmed mode.

## 5. Handling gaps (the normal case, not the exception)

A gap is any interval > 15 min with no evidence. For each gap the engine records a
`tracking_anomaly` with a classified cause where possible:

| Cause | Signal |
|---|---|
| `APP_KILLED` | Process-start event with no clean shutdown marker |
| `PERMISSION_REVOKED` | Client heartbeat reports permission downgrade |
| `LOCATION_OFF` | Client reports provider disabled |
| `POWER_SAVE` | Battery-saver flag in heartbeat |
| `NO_SIGNAL` | Pings continue in the local queue but uploads fail — visible after sync |
| `DEVICE_OFF` | Boot event after the gap |
| `PAUSED_BY_USER` | Explicit pause row (not an anomaly, but a gap) |
| `UNEXPLAINED` | None of the above — highest scrutiny |

Note the important distinction: **no-signal gaps are not tracking failures.** The data
exists on the device and arrives later; the engine simply re-runs. Only gaps where the
device produced no data are real losses.

Gap-spanning inference: if position A at t1 and position B at t2 are far apart, the engine
creates an `is_estimated` transit segment, computes great-circle distance × a road factor
(1.25 default, 1.0 for inferred rail/air) and marks the distance as estimated so it is never
silently used for reimbursement.

## 6. Anti-tamper

| Threat | Detection |
|---|---|
| Mock location app | `Location.isFromMockProvider` (Android), developer-options flag, `isMocked` on iOS jailbreak checks |
| Teleport | Implied speed between consecutive fixes > 900 km/h (or > 250 km/h without an air-consistent gap) |
| Fake check-in from home | Check-in distance from site + comparison with the day's trajectory |
| Clock manipulation | Device-vs-server timestamp skew > 5 min |
| Reinstall to clear queue | Device fingerprint continuity, install-id change |
| Rooted/jailbroken device | Play Integrity / DeviceCheck where available |

All of these raise `tracking_anomaly` rows with severity. **None of them block the rep** —
they produce manager-visible exceptions. Blocking on a false positive costs you a working
day; flagging costs a conversation.

## 7. Reconciliation

A worker re-runs inference for `(user, date)` whenever:
- new evidence arrives with `recorded_at` older than the last inference watermark;
- a rep overrides an event or corrects a home/site location;
- a site's geofence radius or coordinates change;
- nightly, for the previous 3 days (catch-all).

Re-inference is a **rebuild**: derived events with `source = AUTO` for that window are
superseded (soft, `superseded_by_run_id`), manual and confirmed events are preserved and
treated as fixed anchors. The rebuild is deterministic — same evidence in, same journey out.

## 8. Manager-facing outputs

- **Live day view** — current state per rep, last-seen age, tracking-health badge.
- **Journey timeline** — events with confidence, segments with distance/mode, gaps drawn
  explicitly as dashed sections. Showing the gaps builds trust; hiding them destroys it.
- **Exception report** — unexplained gaps, out-of-geofence check-ins, mock-location flags,
  long pauses, tours with no `ARRIVE_HOME`.
- **Plan vs actual** — planned vs completed visits, first-visit time, time-at-customer,
  travel time share.

## 9. Tuning parameters (all admin-configurable)

| Parameter | Default |
|---|---|
| `home_radius_m` | 200 |
| `site_radius_m` (default; per-site override) | 150 |
| `min_dwell_arrival_min` | 4 |
| `depart_displacement_m` | 500 |
| `gap_threshold_min` | 45 |
| `overnight_stationary_hours` | 4 |
| `overnight_window_local` | 21:00–07:00 |
| `auto_confirm_confidence` | 0.75 |
| `review_confidence_floor` | 0.45 |
| `pause_auto_resume_min` | 60 |
| `visit_auto_close_min` | 45 |
| `road_distance_factor` | 1.25 |

## 10. Test strategy for the engine

The state machine must be testable without a phone. Design for it:

- inference is a pure function `(evidence[], config, anchors[]) → (events[], segments[], anomalies[])`;
- record real device traces to fixture files and replay them in CI;
- a synthetic trace generator produces the awkward cases: 40-minute iOS gap at departure,
  overlapping geofences, overnight rail journey crossing a timezone, mock-location injection,
  battery death mid-tour, phone off for the return leg;
- assert on tolerances (±5 min on transition times, ±5 % on distance), not exact equality.
