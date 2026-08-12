# 01 — Architecture

## 1. System context

```
        ┌──────────────────────────┐
        │   Sales rep (Flutter)    │  Android + iOS, mixed BYOD
        │  offline-first, SQLite   │
        └────────────┬─────────────┘
                     │ HTTPS (mTLS optional), JWT bearer
                     │ batched sync + event push
        ┌────────────▼─────────────────────────────────┐
        │            XMobile Backend (ASP.NET Core)     │
        │  ┌────────────┐  ┌─────────────────────────┐ │
        │  │  API host  │  │  Worker host            │ │
        │  │  REST      │  │  journey inference      │ │
        │  │  sync      │  │  outbox dispatch        │ │
        │  │  admin     │  │  XInfo pull scheduler   │ │
        │  └────────────┘  │  OCR, thumbnails, rollup│ │
        │                  └─────────────────────────┘ │
        └───┬───────────────┬──────────────┬───────────┘
            │               │              │
   ┌────────▼──────┐ ┌──────▼──────┐ ┌─────▼────────┐
   │ PostgreSQL 16 │ │   MinIO     │ │   Redis      │
   │  + PostGIS    │ │ attachments │ │ cache/locks  │
   └───────────────┘ └─────────────┘ └──────────────┘
            │
   ┌────────▼──────────┐        ┌──────────────────────┐
   │  XInfo (XStudio)  │◄──────►│  AD / LDAP / OIDC    │
   │  CRM — customer   │  REST  │  identity provider   │
   │  master, expense  │        └──────────────────────┘
   │  workflow         │
   └───────────────────┘
```

External dependencies are deliberately minimal: the only internet-facing requirement is
**FCM/APNs** for push. Everything else runs inside the customer network. If push is not
permitted outbound, the app degrades to poll-on-foreground (documented in
[06 — Security](06-security-identity.md#push-notifications)).

## 2. Why a modular monolith

On-premise means the operations team is the customer's IT team, not a platform team.
A single deployable API + a single worker process keeps the operational surface small,
while module boundaries inside the solution keep the code separable if it ever needs to split.

Modules (each owns its tables, exposes an internal service interface, no cross-module
direct table access):

| Module | Responsibility |
|---|---|
| `Identity` | Users, roles, devices, org units, consent |
| `Customers` | Customer accounts, sites, contacts, geofences, assignment (read-mostly, XInfo-fed) |
| `Planning` | Tours, tour days, visit plans |
| `Tracking` | Ingest, journey state machine, segments, anomalies, distance |
| `Visits` | Visits, check-in/out, form templates, visit reports |
| `Expenses` | Attachments, OCR, expense capture |
| `Sync` | Change feed, mutation intake, conflict store, sync policy |
| `Integration` | XInfo pull/push, outbox, entity mapping |
| `Admin` | Configuration, form builder, dashboards, exception reports |

The only module allowed to be chatty is `Tracking`; it is the one that would be extracted
first if load demands it, so it is written with an explicit ingest queue from day one.

## 3. Request paths

### 3.1 Location ingest (high volume, latency-tolerant)

```
App batches events (30–120 s or on transition)
   → POST /v1/tracking/batch          (idempotent, client_event_id per item)
   → API validates + writes raw to location_ping / geofence_event
   → enqueue user-scoped inference job (Redis stream, key = user_id)
   → Worker runs journey state machine for that user
   → journey_event / journey_segment / anomaly rows produced
   → outbox rows for XInfo push
```

Ingest never runs the state machine inline. The API's job is to durably persist and
acknowledge fast, because the phone is often on a poor link and a slow ack means retries
and duplicate battery cost. Inference is idempotent and re-runnable over any time window —
that property is what makes late-arriving offline data safe (see
[03 — Tracking](03-tracking-and-journey.md#7-reconciliation)).

### 3.2 Sync (bidirectional, batched)

```
POST /v1/sync/push   { mutations[] }  → per-mutation result (applied|duplicate|conflict|rejected)
GET  /v1/sync/pull   ?cursor=&entities=  → changes[] + nextCursor + hasMore
```

Details in [04 — Offline sync](04-offline-sync.md).

### 3.3 Attachments (large, resumable)

```
POST /v1/attachments            → { attachmentId, uploadUrl, parts }   (register)
PUT  <MinIO presigned part>     → chunked, resumable, retriable
POST /v1/attachments/{id}/complete → server verifies sha256, queues OCR + thumbnail
```

The mobile client never blocks a business action on an upload; the expense row syncs with
a pending attachment reference and the binary follows.

## 4. Data storage strategy

| Data | Store | Notes |
|---|---|---|
| Transactional entities | PostgreSQL | Single schema per module namespace |
| Location pings | PostgreSQL, **range-partitioned monthly** | Highest-volume table; partitions detached and archived per retention policy |
| Geometry | PostGIS `geography(Point,4326)` / `geography(LineString,4326)` | GiST indexes; distance in metres without projection juggling |
| Dynamic form answers | `jsonb` + GIN | Queryable without schema churn |
| Attachments | MinIO | DB holds metadata + sha256 only |
| Sessions / locks / ingest queue | Redis | Not a source of truth; safe to flush |

**Volume estimate.** 500 reps × 10 h/day × 1 ping/30 s ≈ 600 k pings/day ≈ 220 M/year.
At ~120 bytes/row plus index that is roughly 45–60 GB/year — comfortably handled by monthly
partitions with a 12-month hot window and older partitions detached to cold storage.

## 5. Non-functional requirements

| NFR | Target | How |
|---|---|---|
| Tracking event loss | < 0.5 % of generated events | Local durable queue, at-least-once delivery, `client_event_id` dedupe |
| Ingest latency | p95 < 500 ms for a 100-event batch | Bulk `COPY`-style insert, no inference inline |
| Journey detection accuracy | ≥ 95 % of arrivals/departures within ±5 min | Geofence + dwell + activity fusion, reconciliation pass |
| Offline endurance | 7 days without connectivity | Local DB retains queue; attachment queue capped by admin policy |
| Sync of a day's work | < 60 s on 3G | Delta pull, compressed batches, attachments deferred |
| Availability | 99.5 % business hours | Single-node acceptable on-prem; API stateless behind nginx, Postgres with streaming replica |
| RPO / RTO | 15 min / 2 h | WAL archiving + nightly base backup; MinIO versioning |
| Battery | < 8 %/hour additional drain while tracking | Adaptive interval, motion-gated sampling, geofence-first on iOS |

## 6. Key architectural constraints, stated plainly

1. **iOS cannot be made to track continuously.** Apple's background model gives you
   region monitoring, visit monitoring, significant-location-change, and — with `Always`
   permission — background location updates that the OS may still suspend. The design
   therefore treats the phone as an *event emitter with gaps*, and the server as the
   authority that infers the journey. Any design that assumes an unbroken breadcrumb trail
   will fail on iOS and on aggressive Android OEMs (Xiaomi, Oppo, Vivo, Realme).

2. **BYOD means you cannot enforce settings.** The app must self-diagnose (permission level,
   battery optimisation, mock-location, power-saving mode) and surface a
   "tracking health" score, because a silently-killed service is worse than no tracking:
   it produces confident-looking wrong data.

3. **On-premise means the network may be closed.** XInfo may only be reachable on the LAN,
   and the internet may be unavailable. Nothing in the core flow may depend on an external
   service. Push is best-effort.

4. **Capture-only expenses shifts risk to the integration.** Since XInfo owns settlement,
   an expense that fails to reach XInfo is money the rep does not get back. The outbox is
   therefore durable, retried with backoff, monitored, and reconciled daily
   ([05 — XInfo integration](05-xinfo-integration.md#6-reconciliation)).

## 7. Cross-cutting concerns

- **Idempotency.** Every write path from a mobile client carries a client-generated UUID.
  Replays return the original result rather than creating duplicates.
- **Versioning.** Every syncable row carries `row_version bigint` (bumped by trigger) and
  `updated_at`. Cursor-based pull uses the global `change_log.id` sequence.
- **Soft delete.** Financial, locational and reporting data is never hard-deleted; `deleted_at`
  plus an audit row. Purge happens only via the retention job.
- **Audit.** Every state transition on a visit, expense, journey event override, or master
  record change writes `audit_log` with before/after JSON.
- **Time.** All timestamps stored `timestamptz` in UTC. The device's local timezone and UTC
  offset are stored alongside journey events, because a rep crossing timezones on a
  multi-day tour will otherwise produce nonsensical day boundaries.
- **Clock skew.** Devices lie. Each batch carries the device clock; the server records both
  `recorded_at` (device) and `received_at` (server), and computes a per-device skew estimate
  used to correct event ordering.
