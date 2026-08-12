# 02 — Domain model

## 1. Entity map

```
                        ┌──────────────┐
                        │  org_unit    │ (territory hierarchy)
                        └──────┬───────┘
                               │
┌───────────────┐       ┌──────▼───────┐        ┌──────────────────┐
│  app_role     │◄─────►│   app_user   │───────►│ user_home_location│ (history)
└───────────────┘       └──┬───┬───┬───┘        └──────────────────┘
                           │   │   │
              ┌────────────┘   │   └───────────────┐
              │                │                   │
      ┌───────▼──────┐  ┌──────▼────────┐   ┌──────▼────────┐
      │   device     │  │ customer_     │   │  leave /      │
      └──────────────┘  │ assignment    │   │  holiday      │
                        └──────┬────────┘   └───────────────┘
                               │
   ┌───────────────┐    ┌──────▼──────────┐    ┌──────────────────┐
   │ customer_     │◄───│ customer_account│───►│ customer_contact │
   │ site (geo)    │    │  (XInfo master) │    └──────────────────┘
   └──────┬────────┘    └─────────────────┘
          │  1:1
   ┌──────▼────────┐
   │   geofence    │◄──────────────┐  (also for user_home_location)
   └───────────────┘               │
                                   │
        ┌──────────┐        ┌──────┴────────┐       ┌───────────────┐
        │  tour    │───────►│  visit_plan   │──────►│    visit      │
        │(multi-day)│  1:N  └───────────────┘  0:1  └───────┬───────┘
        └────┬─────┘                                        │ 1:1
             │ 1:N                                   ┌──────▼────────┐
      ┌──────▼───────┐                               │ visit_report  │
      │  tour_day    │                               └───────────────┘
      └──────────────┘                                       │ uses
                                                     ┌───────▼───────┐
                                                     │ form_template │
                                                     └───────────────┘
   ┌────────────────┐   ┌─────────────────┐   ┌──────────────────┐
   │tracking_session│──►│  location_ping  │   │ geofence_event   │
   └───────┬────────┘   └─────────────────┘   └──────────────────┘
           │                      │                     │
           │                      └────────┬────────────┘
           │                     inference │
   ┌───────▼────────┐            ┌─────────▼─────────┐   ┌──────────────────┐
   │ tracking_pause │            │  journey_event    │──►│ journey_segment  │
   └────────────────┘            └───────────────────┘   └──────────────────┘

   ┌──────────────┐   ┌────────────────────┐   ┌─────────────────┐
   │   expense    │──►│ expense_attachment │──►│   attachment    │
   └──────────────┘   └────────────────────┘   └────────┬────────┘
                                                        │
                                               ┌────────▼────────┐
                                               │ ocr_extraction  │
                                               └─────────────────┘
```

## 2. Core aggregates and their invariants

### 2.1 Tour

The multi-day container. A tour is what a rep "goes on" and what the back office settles.

- A tour belongs to exactly one rep and has exactly one origin home location (snapshotted
  at creation, because home can change).
- A tour has 1..N `tour_day` rows, one per calendar date in `[planned_start_date, planned_end_date]`,
  each with a planned activity type: `TRAVEL`, `VISITS`, `MIXED`, `REST`.
- Per-day sub-plans are editable in the field: the rep may add, reorder, or drop visits for
  a day. Every edit after the tour starts is recorded as a plan revision, so "plan vs actual"
  compares against the *approved* baseline, not the last-minute edit.
- A tour's actual boundaries come from the journey state machine: `actual_start_at` is the
  confirmed `DEPART_HOME`, `actual_end_at` the confirmed `ARRIVE_HOME`.
- Invariant: a rep may have at most one tour in `IN_PROGRESS` at a time.
- A same-day, no-travel working day is still a tour (single day, `origin = destination`).
  Modelling it uniformly avoids two code paths.

**States:** `DRAFT → PLANNED → IN_PROGRESS → COMPLETED` with side exits to `CANCELLED`
(before start) and `ABANDONED` (after start, with reason).

### 2.2 Visit plan → Visit

`visit_plan` is intent; `visit` is fact. They are separate rows because:

- an unplanned visit has a `visit` with no `visit_plan`;
- a skipped plan has a `visit_plan` with no `visit` and a skip reason;
- a rescheduled plan keeps its history rather than being mutated.

**Visit plan states:** `PLANNED → COMPLETED | SKIPPED | RESCHEDULED | CANCELLED`
**Visit states:** `CHECKED_IN → CHECKED_OUT → REPORT_SUBMITTED` (plus `VOIDED` with reason).

Invariants:
- A visit must reference a `customer_site`, not just an account — an account can have many
  physical locations, and tracking is meaningless without the specific one.
- Check-in records the distance from the site's geofence centre. Check-in beyond the radius
  is allowed but requires `out_of_geofence_reason` and is flagged for the manager.
- Check-out is auto-suggested on geofence exit but always confirmed by the rep or by the
  auto-close job (configurable, default: auto-close 45 min after confirmed exit).

### 2.3 Journey

The journey is *derived* data, never entered by hand — but always **overridable** by hand,
with the original detection preserved. This is the single most important modelling decision
in the tracking area: if the rep cannot correct a wrong auto-detection, they will stop
trusting the system; if the correction overwrites the detection, you lose the ability to
audit or to improve the algorithm.

- `journey_event` = a point-in-time transition with type, timestamp, location, detection
  method, confidence, and an evidence blob.
- `journey_segment` = the interval between two events, with distance, duration, travel mode
  and (optionally) the simplified path.
- `user_journey_state` = the current state, kept as a single row per user for cheap lookup.

See [03 — Tracking](03-tracking-and-journey.md) for the full state machine.

### 2.4 Visit report

Fixed core columns (always present, always queryable) plus a dynamic section:

**Core:** outcome code, discussion summary, next action, follow-up date, order intent,
competitor mentioned, contact met, sentiment.

**Dynamic:** `answers jsonb`, validated against `form_template.schema` at the pinned
`template_version`. Templates are immutable once published; editing creates a new version.
A report always stores the version it was captured against, so historical reports render
correctly years later.

### 2.5 Expense

Capture-only. The local row is authoritative until pushed; after `PUSHED` it becomes
read-only in XMobile and any correction must be a new entry or a XInfo-side edit that flows
back as status.

**States:** `DRAFT → SUBMITTED → PUSHED → ACKNOWLEDGED` and `PUSH_FAILED` (retryable).
XInfo's own approval status is mirrored back into `xinfo_status` for the rep to see, but
XMobile never acts on it.

## 3. Geo modelling

| Concept | Representation |
|---|---|
| Customer site location | `geography(Point,4326)` + `geofence_radius_m` (default 150 m, per-site override) |
| Rep home location | Same, with history (`effective_from`/`effective_to`) — reps relocate |
| Breadcrumb | `geography(Point,4326)` with `accuracy_m`, `speed_mps`, `heading` |
| Travel path | `geography(LineString,4326)`, Douglas-Peucker simplified at ~20 m tolerance |
| Territory | Optional `geography(MultiPolygon,4326)` on `org_unit` for coverage analytics |

**Geofence radius is not one-size-fits-all.** A rural distributor with a 2-acre yard needs
400 m; an office in a dense market needs 80 m or you will detect arrival at the neighbour.
The design supports per-site radius plus an auto-suggestion job that proposes a radius from
the historical spread of confirmed check-in points at that site.

**Geo-location capture for customers.** XInfo owns the customer master but very likely does
not own accurate coordinates. So:

1. XInfo supplies address (+ coordinates if it has them).
2. XMobile geocodes the address on first sync (pluggable provider; on-prem installs can use
   a local Nominatim container to avoid outbound calls) → `geo_source = GEOCODED`.
3. The rep can "capture location here" while standing at the site → `geo_source = FIELD_CAPTURED`,
   which supersedes geocoding and is the highest-trust source.
4. A supervisor verifies → `geo_verified_at`.

Only `FIELD_CAPTURED` or `VERIFIED` sites get automatic arrival detection by default;
geocoded-only sites still detect, but their journey events carry lower confidence and are
marked for review. This prevents a bad geocode from silently producing false visit records.

## 4. Reference/configurable data

Kept as tables (not enums) because operations will change them without a release:
`visit_type`, `visit_outcome`, `expense_category`, `skip_reason`, `pause_reason`,
`travel_mode`, `anomaly_type` severity mapping, `form_template`.

Kept as PostgreSQL enum types because changing them changes code:
journey event types, journey states, sync operations, entity lifecycle states.

## 5. Multi-day tour worked example

Rep based in Pune, must visit a customer in Nagpur (~700 km).

| Day | Planned | Detected |
|---|---|---|
| Mon | `TRAVEL` Pune → Nagpur, overnight | `DEPART_HOME` 18:40 · `TRANSIT_START` (rail) · segment `OUTBOUND_TRAVEL` |
| Tue | `VISITS` — 3 visits in Nagpur | `TRANSIT_END` 07:10 · `ARRIVE_CUSTOMER` ×3, `DEPART_CUSTOMER` ×3, `OVERNIGHT_STOP` at hotel |
| Wed | `MIXED` — 1 visit, then return | `ARRIVE_CUSTOMER`, `DEPART_CUSTOMER`, `START_RETURN` 16:20 |
| Thu | `TRAVEL` return | `ARRIVE_HOME` 06:55 → tour `COMPLETED` |

What this exercises, and which the schema must support:
- travel spanning midnight and two calendar dates (segments are timestamp ranges, not dates);
- an overnight stop that is neither home nor a customer (`OVERNIGHT_STOP` with an inferred
  "stay location", useful for hotel expense matching);
- expenses attaching to the tour (train fare, hotel) rather than to any single visit;
- a day whose planned type is `TRAVEL` with zero visits — absence of visits must not be
  flagged as non-compliance;
- distance accumulated across days for a mileage claim, split by travel mode so rail km are
  not reimbursed as car km.
