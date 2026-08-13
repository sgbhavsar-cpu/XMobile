# 10 — Roadmap, risks and open questions

## 1. Phasing

Each phase is independently useful. Nothing here requires a big-bang launch.

### Phase 1 — Foundation (4–6 weeks)
Identity (OIDC/AD), device registration, customer sync from XInfo, offline DB + sync engine
skeleton (pull + push, no conflicts UI yet), tours and per-day visit plans, manual check-in
and check-out, fixed-core visit report.

*Exit criterion:* a rep can plan a day, work it fully offline, and sync.

### Phase 2 — Tracking (4–6 weeks)
Client collection policy and profiles, geofence management (including the iOS 20-region
strategy), ingest pipeline, journey state machine, gap and anomaly detection, journey
timeline UI, corrections with audit trail, tracking-health diagnostics.

*Exit criterion:* the Pune→Nagpur multi-day scenario in
[02 §5](02-domain-model.md#5-multi-day-tour-worked-example) is detected end to end on both
platforms, with correct times within ±5 minutes.

### Phase 3 — Expenses & integration (3–4 weeks)
Attachment pipeline, share-intent ingestion, on-device OCR, expense capture with suggested
mileage/per-diem amounts, duplicate detection, outbox to XInfo, expense status flow-back,
nightly reconciliation.

### Phase 3b — Customer intelligence (2–3 weeks, can run alongside Phase 3)
Opportunities (create, edit, link to visits, stage history), sales-history pull, customer-360
screen, field-proposed prospects with the XInfo approval round-trip.

*Exit criterion:* a rep walks in knowing the customer's last orders, open deals and previous
visit notes — offline — and walks out having moved a deal's stage, with XInfo told which
visit did it.

*Exit criterion:* a UPI screenshot shared offline becomes a settled expense in XInfo
without manual re-entry, and reconciliation reports zero discrepancies for a week.

### Phase 4 — Dynamic forms & manager tools (3–4 weeks)
Form template builder, versioned publishing, dynamic form engine in the app, manager live
view, plan-vs-actual, exception dashboard, conflict inbox UX.

### Phase 5 — Optimisation (ongoing)
Route optimisation, geofence radius auto-tuning, auto-mileage expenses, attendance
derivation, analytics, battery tuning from field telemetry.

## 2. Top risks

| Risk | Impact | Mitigation |
|---|---|---|
| **BYOD with no MDM** — nothing can be enforced | Permissions and OEM settings are the rep's choice and can be revoked at any time; tracking coverage is structurally lower than on managed devices | Guided self-verifying setup, continuous health heartbeat, rep-first "tracking stopped, tap to fix" notifications, visible health score shared by rep and manager, engine designed to classify gaps rather than treat them as failures. **Set the expectation with the business that this ceiling exists** |
| iOS background suspension produces sparse data | Wrong or missing transition times | Server-side inference designed for gaps from day one; corroborate with `CLVisit`, geofences, significant-location-change; back-estimate with `is_estimated` flags |
| Android OEM battery killers stop the service | Silent tracking loss | Health heartbeat detects it, OEM-specific fix screens, manager-visible health score, foreground service + boot receiver |
| Reps perceive tracking as surveillance | Sabotage: phone left at home, permissions revoked, adoption failure | Consent flow, work-hours-only collection, visible indicator, pause right, rep sees own data, flags-not-blocks policy. This is a change-management problem as much as a technical one |
| Bad customer coordinates from geocoding | False arrivals, false non-compliance | Field capture supersedes geocode, unverified sites get lower confidence, data-quality flags, radius suggestions |
| XInfo API turns out to be limited or unstable | Integration rework, lost expenses | `IXInfoClient` abstraction + stub, durable outbox, reconciliation job, early contract agreement (see §4) |
| Sync conflicts frustrate reps | Data loss, distrust | Per-entity policies decided upfront, conflicts always surfaced, never silently discarded |
| Location data volume outgrows the server | Slow dashboards, disk pressure | Monthly partitioning, retention rules, rollup tables, indexes designed for the actual query shapes |
| Expense fraud (fake receipts, mock GPS) | Financial loss | sha256 dedupe, OCR cross-check, mock-location and teleport detection, geo-tagged capture, integrity view per rep |

## 3. Deliberate non-goals (for now)

- Order/quotation capture — belongs in XInfo unless you want the app to place orders.
- Payment collection with receipting — needs financial controls beyond this scope.
- Real-time streaming of every rep's position to a wall map — expensive in battery and
  bandwidth; the 1–2 minute freshness of the live view is enough for actual decisions.
- Offline maps for the whole country — large; territory-scoped tiles if it becomes necessary.

## 4. Questions resolved

| # | Question | Answer |
|---|---|---|
| 1 | Deployment | On-premise, self-hosted |
| 2 | Platforms / ownership | Android + iOS, mixed BYOD |
| 3 | Tracking window | Hybrid: schedule-driven auto-start, rep may pause (logged) |
| 4 | Trip model | Tour with editable per-day sub-plans |
| 5 | Expense workflow | Capture only; XInfo owns approval and settlement |
| 6 | Master data ownership | XInfo owns customers; XMobile pushes everything up |
| 7 | Integration transport | REST both ways, outbox + idempotency keys |
| 8 | Identity | Keycloak deployed with the app |
| 9 | Offline scope | Full offline, admin-tunable sync window |
| 10 | Visit report | Fixed core + dynamic extension |
| 11 | Field-created customers | Rep proposes a prospect; sites/contacts direct *(my call — no preference given)* |
| 12 | Tour approval | Self-service |
| 13 | Money math | App suggests, XInfo decides |
| 14 | Languages | Full i18n structure, English first |
| 15 | IdP | None existing → Keycloak |
| 16 | Push | FCM/APNs permitted |
| 17 | Fleet size | Under 100 reps |
| 18 | Geography | India, kept flexible |
| 19 | Attendance | Derived, information only |
| 20 | Offline customer data | Sales history, visit history, **opportunities** |
| 21 | Opportunities | Full CRUD, linked to visits |
| 22 | Order capture | Out of scope |
| 23 | Visit proof | GPS + optional photos |
| 24 | MDM | **Not in use** — nothing can be centrally enforced |
| 25 | XInfo API | **Does not exist** — we build the gateway; their DBA writes the stored procedures |

## 5. Open questions still outstanding

All of these sit with the **XInfo team**, and none block starting Phase 1 or 2 — the
integration is written behind `IXInfoClient` with a stub. They do block Phase 3.

1. Customer read endpoint: pagination, `modifiedSince`, inactive representation?
2. Does XInfo expose rep↔customer assignment and the reporting hierarchy?
3. Expense intake: exact field list, category codes, receipt mode (URL vs base64), idempotency?
4. Webhook capability, or polling only?
5. Auth mechanism and credential rotation?
6. Expense status flow-back endpoint and status vocabulary?
7. Rate limits and maintenance windows?
8. **Opportunity API** — stage vocabulary, and whether partial (field-level) updates are
   acceptable given we send an ordering token.
9. **Prospect intake** — how does a rejection come back to us? Our rep is already visiting them.
10. **Sales history** — header-only or line items, and how far back?
11. **Rate tables** — does XInfo hold mileage and per-diem rates, or do we maintain them?

*These now take the form of the stored procedure contract in
`db/xinfo-mssql/01_procedures.sql`, which is the concrete artefact to review with them.
The blocking one is simpler than any of the above: **a dev SQL Server to point at**. Until
then the procedure bodies do not exist and the gateway is unproven against a real instance.*

**MDM: confirmed not in use.** Every permission and OEM setting must therefore be obtained
from the rep in-app and re-verified continuously. See
[07 §3.3](07-flutter-app.md#33-tracking-health-and-onboarding-without-mdm) for the guided
setup and health model, and the top row of §2 for the risk this carries.

## 6. Build status

**Phase 2's core is built.** The journey engine
(`src/Modules/XMobile.Tracking.Engine`) is implemented as a pure function with 53 passing
trace-replay tests covering the ordinary day, the four-day Pune→Nagpur tour, iOS sparse data,
gap classification, anti-tamper, return-leg ambiguity, manual corrections and determinism.

It was built first deliberately: highest risk, highest value, and it needs no UI, no XInfo and
no network, so getting it right early prevents a rewrite of everything downstream. See
[11 — Journey engine](11-journey-engine.md) for its structure, the defects the test suite
caught, and its known limits.

**The Flutter app is built too** (`app/`), running against an in-memory backend: every screen,
every form, offline queueing, the dynamic report engine, share-intent expense capture and the
tracking-health flow. 52 tests, no device needed. Location capture, receipt sharing and
permission dialogs are entered by hand until the plugins land — and the manual paths stay
afterwards, because a rep whose GPS will not fix still has to record where they were.

**The XInfo gateway is built** (`src/XInfo.Gateway.*`). XInfo has no API, so we write one:
REST for our backend, stored procedures into their MS SQL — bodies by their DBA, everything
above them ours. Our own database is unaffected and stays on PostgreSQL. The procedure
contract they implement against is `db/xinfo-mssql/01_procedures.sql`, and a build-failing
test keeps it in step with the code. See [12 — XInfo gateway](12-xinfo-gateway.md).

**The XMobile.Api backend now exists** (`src/XMobile.Api`, `src/XMobile.Persistence`,
`src/Modules/XMobile.{Identity,Customers,Planning,Visits}`) — Phase 1's core REST surface:
device registration, `/v1/auth/me`, consent, assigned-customer reads, tours/tour-days/visit
plans, check-in/check-out, and the visit report (fixed core + dynamic `answers`). It is
schema-first: EF Core is hand-mapped onto `db/schema/*.sql` (no EF migrations generate schema),
including the PostgreSQL enum types, `geography(Point,4326)` columns, and the trigger-owned
`row_version`/`updated_at`/`sync.change_log` columns db/README.md documents. Modules never
reference each other directly for business data — cross-module reads/writes (a tour showing its
visits, a check-in completing a visit plan) go through small interfaces on `XMobile.Shared`,
implemented by whichever module owns the table and consumed by whichever needs it. Auth is a
dev-mode HS256 bearer token (`POST /v1/auth/dev/login`, not in `api/openapi.yaml`) standing in
for Keycloak, which isn't deployed yet — same validation code path, only the signing-key source
changes later. Verified by 4 integration tests running the full plan→check-in→check-out→submit
flow against a real Testcontainers Postgres+PostGIS instance (`tests/XMobile.Api.Tests`), on top
of the existing 73.

Known gaps from this pass, worth closing before the next one:
- ~~No endpoint yet to create/update a rep's home location~~ — added (`PUT /v1/auth/home`) in the
  `HttpApiClient` pass below, since nothing could plan a single tour through the real API without it.
- `customerName`/`siteName` are left null on `VisitPlan`/`Visit` responses — populating them needs
  a small lookup this pass didn't wire up (the data lives in `XMobile.Customers`).
- No FluentValidation pipeline yet (`docs/08-backend-structure.md`'s stated choice) — only the
  invariants exercised by the tests are enforced by hand (`DomainValidationException`).

**The offline sync protocol (`/v1/sync/*`) now exists** (`src/Modules/XMobile.Sync`) — delta
`pull` (cursor over `sync.change_log`, scoped to the rep's own rows and assigned customers),
idempotent `push` (the `sync.client_mutation` ledger, optimistic concurrency via `baseVersion`,
conflicts recorded to `sync.sync_conflict`), `GET /v1/sync/conflicts` and
`POST /v1/sync/conflicts/{id}/resolve`, and `GET /v1/sync/health`. Wired for 8 entities across
the existing modules (`customer.customer_account`/`customer_site`, `planning.tour`/`tour_day`/
`visit_plan`, `visit.visit`/`visit_report`/`form_template`) via one more small `XMobile.Shared`
port, `ISyncEntityHandler` — the module owning a table implements it, `XMobile.Sync` dispatches
on `entity` without referencing any of those modules' projects, same shape as `IVisitLookup` and
friends. Verified by 3 more integration tests (pull scoping between two reps, a push that creates
a `visit_plan` purely from its payload, a stale push that conflicts and is resolved
`KEEP_CLIENT`) — 80/80 passing.

Known gaps from this pass:
- `GET /v1/sync/bootstrap` (NDJSON full download for a brand-new device) isn't built — pull's
  cursor mechanism was the part worth proving first.
- Reference data (`config.visit_type` etc.) and the identity self-row tables
  (`app_user`/`device`/`user_home_location`) aren't wired into sync — no EF entities exist for
  the `config.*` tables in any module yet.
- `DEFERRED` (docs/04 §3.2's dependency-ordering) is approximated by catching a foreign-key
  violation, not a real dependency scheduler — good enough to unblock a mutation pushed before
  its parent, not a general solution.
- **Push does not replay the side-effects the dedicated REST endpoints have** (check-in
  completing a visit plan, server-computed geofence distance) — an offline device is expected to
  have computed those itself from its cached working set and push the finished row. A fuller
  implementation would route push through the same application-layer commands the REST endpoints
  use.
- `GET /v1/sync/health` takes an explicit `deviceId` query parameter not in `api/openapi.yaml` —
  the dev-JWT stub carries no `device_id` claim the way a real Keycloak token would.

**`HttpApiClient` now exists** (`app/lib/core/api/http_api_client.dart`) — the first real
implementation of the Flutter app's `ApiClient` interface, alongside `MockApiClient`. Of the
interface's 47 methods, ~20 (auth, customer reads, tours/plans, check-in/out, reports, form
templates) call the real backend with hand-written JSON mapping both ways; the remaining ~27
(opportunities, expenses/attachments, journey/tracking, most reference-data lookups) have no
backend yet and throw a catchable `ApiException('Not yet available in the live backend')` rather
than pretending to work. `MockApiClient` stays the default `apiClientProvider` until enough of
those are backed that flipping the switch wouldn't break screens outright. Six Dart models
(`Customer`, `CustomerSite`, `Tour`, `VisitPlan`, `Visit`, `VisitReport`) gained a nullable
`rowVersion` — null means "not yet saved," which `saveTour`/`saveVisitPlan` use to decide create
vs. update. Two small backend additions were needed to make the interface satisfiable at all:
`PUT /v1/auth/home` (nothing else could ever set a rep's home location, so no tour could ever be
planned through the real API) and `GET /v1/plans/{id}` (`skipVisitPlan` returns the updated plan
but takes only its id, with no date range to search `/v1/plans` by). Both are disclosed
deviations from `api/openapi.yaml`, same treatment as the existing `/dev/login` stub. Verified by
7 new Flutter unit tests against a fake `http.Client` (`app/test/http_api_client_test.dart`) —
signIn's token flows into the following calls, problem+json error mapping, a network failure
mapping to `OfflineException`, a `TourDetail` response correctly dropping into the leaner `Tour`
model — 59/59 Flutter tests and 81/81 .NET tests passing.

Known gaps from this pass:
- `checkInPoint`/`checkOutPoint`/`checkInMethod`/`contactId`/`outOfFenceReasonCode`/
  `outOfFenceRemark`/`photoIds` come back empty on a `Visit` read from the server — the read DTO
  (`VisitSummary`) is intentionally lean and doesn't carry them; only what was captured locally
  at check-in time has them.
- `saveVisitPlan` on an *existing* plan (non-null `rowVersion`) throws — there is no
  `PATCH /v1/plans/{id}` yet, only create and skip.
- The device id `HttpApiClient` registers is regenerated every app start (no local database to
  persist it in yet), and the bearer token lives in memory only — expected to be revisited once
  local persistence (Drift/SQLCipher) lands.

**The ingest API + inference worker now exist** (`src/Modules/XMobile.Tracking`) — the
"imperative shell" docs/08 §4 describes, wrapping `src/Modules/XMobile.Tracking.Engine` (until
now never called by anything real). `InferenceRunner` loads a user's evidence
(pings/geofence-events/stays/pauses/health-samples) plus `CONFIRMED`/overridden `journey_event`
rows as anchors out of Postgres for a time window, builds the engine's `JourneyInput`
(`Home`/`Sites` resolved via two new `XMobile.Shared` ports — `ITourContextLookup`, implemented
by `XMobile.Planning`, and `IGeofenceLookup`, implemented by `XMobile.Customers` against a new
`customer.geofence`-backed `Geofence` entity, trigger-maintained from `user_home_location`/
`customer_site`), calls `new JourneyEngine().Infer(input)`, and persists the result: non-anchor
`journey_event` rows are soft-superseded (`status = SUPERSEDED`) and rewritten, `journey_segment`
rows are hard-deleted and rewritten wholesale (that table carries no status column and no anchor
concept), `tracking_anomaly` rows are deduplicated by `(type, windowStart)` across reruns so a
rerun over the same window doesn't spam duplicates, and `tracking.user_journey_state`/
`tracking.inference_run` are upserted/inserted for audit. Redis is skipped at this fleet size
(per the README's own design table) — `POST /v1/tracking/batch` and the endpoints that change
anchors (override/confirm/heading-home) call the runner synchronously inline rather than via a
queue. `NightlyReinferenceWorker` (a `BackgroundService` standing in for the eventual Quartz.NET
job) reinferes the previous local day for every tracking-enabled user with evidence in the last 3
days, its core logic (`RunNightlyBatchAsync`) directly callable so tests don't wait on a real
timer tick. Endpoints: `POST /v1/tracking/batch` (dedupes ping/geofence-event/stay ids, ensures
the month's `location_ping` partition, upserts `device_heartbeat`), `POST /v1/tracking/session`
(+`/end`,`/pause`,`/resume`), `GET /v1/tracking/journey` (events/segments/anomalies plus a
`DailySummary[]` computed on the fly rather than read from a stored rollup),
`POST /v1/tracking/events/{id}/override`, `POST /v1/tracking/events/{id}/confirm`,
`POST /v1/tracking/heading-home`, `GET /v1/tracking/geofences`. Verified by 4 new integration
tests including the first real HTTP → Postgres → pure engine → Postgres round trip (a depart-home
→ arrive-site → depart-site → arrive-home ping batch producing all four journey events and an
`AT_CUSTOMER` segment) — 85/85 .NET tests passing (53 engine + 20 XInfo gateway + 12 API).

A real, non-obvious bug the integration tests caught: every "start of local day" window this pass
builds (`new DateTimeOffset(localDate.ToDateTime(TimeOnly.MinValue), istOffset)`) carries a
non-zero (+05:30) offset, and Npgsql rejects writing or querying a `timestamptz` parameter with
any offset but UTC (`"Cannot write DateTimeOffset with Offset=...: only offset 0 (UTC) is
supported"`) — every such window, and every client-supplied timestamp on this module's DTOs, is
now normalized with `.ToUniversalTime()` at construction/write time. This is a general trap for
any local-wall-clock-to-`DateTimeOffset` construction against this Postgres driver, not specific
to tracking — worth remembering if the same pattern shows up in a future module.

Known gaps from this pass:
- No clock-skew correction (`Ping.CorrectedAt` is always null) and no per-user timezone
  resolution — every window/local-date computation uses a fixed IST (+05:30) offset rather than
  the device's reported `deviceTz` or the user's `DefaultTimezone`.
- `Sites` passed to the engine is only the active tour's planned sites (docs/02 §2.1: every
  working day is modelled as a tour) — an unplanned visit to a site with no tour context is still
  detected as `AT_CUSTOMER`, just without `siteId` resolved via geofence matching.
- No auto-linking of detected `journey_event` rows to `visit` rows — check-in/check-out already
  record visits independently via the Phase 1 REST endpoints, so this is a cross-reference
  deferred alongside visit auto-close, not a functional gap.
- `journey_segment.fromEventId`/`toEventId` are left unset — the engine's `JourneySegment` model
  carries no event references, and matching them up after the fact is a nice-to-have, not
  load-bearing for the timeline itself.
- `tracking.daily_journey_summary` is not written; `GET /v1/tracking/journey`'s `daily[]` is
  computed from the window's segments at read time, and its `visitsPlanned`/`visitsCompleted`/
  `trackingCoveragePct`/`attendanceStatus` fields are left at 0/null (they need Planning/Visits
  data this pass doesn't cross-call for just a summary field).
- Client-supplied `DateTimeOffset` fields elsewhere in the app (Visits' `checkInAt`, Sync's
  mutation timestamps, etc.) have the same latent non-UTC-offset risk this pass fixed locally in
  Tracking — every existing test happens to submit `DateTimeOffset.UtcNow`, so it's never been
  exercised, but a real client sending its local offset would hit the same Npgsql error.

**Local persistence now exists** (`app/lib/core/db/`, `app/lib/core/api/token_store.dart`) — the
first slice of docs/07 §5's Drift/SQLCipher design, scoped to the two concrete things that were
actually losing data on every restart: the sync outbox and `HttpApiClient`'s session.
`AppDatabase` (Drift over SQLite, via `drift_flutter`'s `driftDatabase()` helper for the
platform-path lookup) has one table so far — `OutboxEntries`, mirroring the existing
`OutboxEntry`/`SyncState` model plus the `payload`/`baseVersion` columns docs/04 §6's protocol
needs but no caller populates yet. `OutboxNotifier` (`app/lib/core/state/outbox.dart`) keeps its
public API byte-identical to the in-memory version it replaces — `enqueue`/`markSynced`/
`markFailed`/`remove`/`clearSynced`/`hasPendingFor`/`pendingCount`, same signatures — so none of
its 13 existing call sites across the app changed; internally it now subscribes to a Drift
`Stream<List<OutboxEntry>>` and writes through to the database on every mutating call instead of
holding the list itself. Separately, `TokenStore` (`flutter_secure_storage`-backed, Keystore/
Keychain) gives `HttpApiClient` a stable device id and a persisted bearer token across restarts —
it previously regenerated a fresh device id and lost its token on every cold start, both
disclosed as known limitations when it was built. Verified by 66/66 Flutter tests (dependencies
resolved and `dart run build_runner build` codegen'd for real — this pass confirmed a working
Flutter/Dart SDK exists in this environment after initially finding none on PATH), including 5
new outbox-repository tests against a real (in-memory) Drift database — one of them constructs a
second `OutboxNotifier` over the same underlying database and confirms it sees the first one's
queued entry, the actual proof this is durable storage and not an in-memory illusion wearing a
Drift costume — and 2 new `HttpApiClient` token-persistence tests.

Known gaps from this pass:
- **The database is not SQLCipher-encrypted.** `sqlcipher_flutter_libs`' native-binary/
  platform-channel setup needs a real device or CI to verify, which this sandbox doesn't have —
  shipping that unverified seemed worse than shipping plaintext-at-rest with the gap disclosed.
  The outbox holds mutation *metadata* (entity/op/description), not credentials; the bearer token
  and device id — the actually sensitive material — already go through `flutter_secure_storage`
  regardless. Follow-up once there's a device to test encryption on.
- **Only the outbox table exists** — not the full "Drift schema mirrors the server subset" vision
  (a table per entity: customers, tours, visits, expenses, etc., mirroring `MockApiClient`'s
  entire in-memory world). No urgency yet: `MockApiClient` stays the default provider until far
  more of `ApiClient` is backed by `HttpApiClient`, so no live screen reads from a local cache
  today. This is genuinely a multi-increment effort on its own.
- **`app/lib/main.dart` has a pre-existing compile error** (`CardTheme` vs `CardThemeData`,
  surfaced by `flutter analyze`, not `flutter test` — confirmed present on a clean checkout before
  this pass touched anything, a Flutter SDK version drift issue, not something introduced here)
  and still doesn't wire `HttpApiClient` into `apiClientProvider` — both pre-date this pass and
  are unrelated to local persistence specifically.
- `payload`/`baseVersion` on the outbox table are unpopulated — no caller sets them yet; they're
  there so the real sync engine (push/pull workers, conflict handling) doesn't need a migration
  the moment it lands.

**`HttpApiClient`'s journey/tracking area is now backed**, following last increment's
`XMobile.Tracking` module — 6 of its 10 `ApiClient` methods call the real backend:
`journeyEvents`/`journeySegments`/`daySummaries` all call `GET /v1/tracking/journey` and each
pick their slice out of one response (a disclosed inefficiency when two providers watch both
events and segments — two identical requests fire rather than one; a caching layer is future
work once there's a repository to put it in); `correctJourneyEvent`/`confirmJourneyEvent` map 1:1
onto `POST /v1/tracking/events/{id}/override|confirm`; `addManualJourneyEvent` only really works
for one of the app's six manual-entry types (`startReturn`, via `POST /v1/tracking/heading-home`,
which returns no body so the created event is read back with a narrow follow-up query) — the
other five (`departHome`, `arriveCustomer`, `departCustomer`, `arriveHome`, `overnightStopStart`)
throw a specific `ApiException` naming what's actually unsupported, because the backend has no
endpoint to create them at all yet. `trackingHealth`/`updateTrackingHealth`/`isTrackingActive`/
`setTrackingActive` stay stubbed — confirmed via reading the backend that there's no counterpart
to backfill against (device self-reported health has no `GET` endpoint; "is tracking active" is
really a `TrackingSession.status` the `ApiClient` interface has no `sessionId` to look up), so
this needs new backend endpoints, not just Dart-side wiring. `JourneyEvent`/`JourneySegment`/
`DaySummary` gained `fromJson` (following `Tour.fromJson`'s existing static-method pattern);
`placeName`/`customerId` on events/segments come back null (the backend gives `refType`/`refId`/
`siteId`, not a resolved name), and `DaySummary`'s `visitsPlanned`/`visitsCompleted`/
`trackingCoveragePct`/`attendanceStatus` come back at their defaults — both disclosed gaps that
already existed backend-side, now visible client-side too. Verified by 8 new tests in
`http_api_client_test.dart` — 74/74 Flutter tests passing.

**Next**, in order:
1. Device plugins: background location, geofences, share-intent, on-device OCR, real permission
   flows — needs a real device, which this environment doesn't have.
2. Backfill the remaining `ApiClient` stubs (opportunities, expenses/attachments, most reference
   data) once their backend modules get built (Phase 3/3b) — journey/tracking is the only area
   with a backend today. Flip `apiClientProvider` to `HttpApiClient` as the default once coverage
   is complete enough.
3. Audit the non-UTC-offset `DateTimeOffset` gap noted in the Tracking section above across the
   rest of the API.
4. Fix the pre-existing `main.dart` `CardTheme`/`CardThemeData` compile error and wire
   `HttpApiClient`/local persistence into an actual app bootstrap.
5. The full per-entity Drift schema + sync engine (push/pull workers, conflict handling per
   docs/04 §4) once enough of `ApiClient` is backed to make a local cache worth reading from.
6. New backend endpoints for device tracking-health/session-status, if the manager-visible health
   score and pause/resume UI are to work against the live backend rather than staying local-only.
