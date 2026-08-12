# 08 — Backend structure (ASP.NET Core / C#)

## 1. Solution layout

```
XMobile.sln
src/
  XMobile.Api/                    ASP.NET Core host: endpoints, auth, swagger, health
  XMobile.Worker/                 Background host: inference, outbox, imports, OCR, rollups
  XMobile.Shared/                 Cross-cutting: Result, clock, geo primitives, problem details
  XMobile.Persistence/            EF Core DbContext, migrations, Dapper query helpers
  Modules/
    XMobile.Identity/             Users, roles, devices, consent, hierarchy
    XMobile.Customers/            Accounts, sites, contacts, geofences, assignment
    XMobile.Planning/             Tours, tour days, visit plans, route suggestion
    XMobile.Tracking/             Ingest, journey engine, anomalies, rollups
    XMobile.Visits/               Visits, form templates, reports
    XMobile.Expenses/             Attachments, OCR, expense capture
    XMobile.Sync/                 Change feed, mutation intake, conflicts, policy
    XMobile.Integration/          XInfo client, outbox dispatcher, reconciliation
tests/
  XMobile.UnitTests/
  XMobile.JourneyEngine.Tests/    Trace-replay fixtures (the critical suite)
  XMobile.IntegrationTests/       Testcontainers: Postgres+PostGIS, MinIO
  XMobile.ArchitectureTests/      Module boundary enforcement (NetArchTest)
```

Each module is a class library exposing:
`Contracts/` (DTOs + interfaces other modules may use), `Domain/`, `Application/` (handlers),
`Infrastructure/` (repositories, EF configuration), `Endpoints/` (minimal-API registration).

Modules talk through interfaces and an in-process event bus, never by touching another
module's tables. `XMobile.ArchitectureTests` fails the build if that rule is broken — this is
what keeps a modular monolith from decaying into a big ball of mud.

## 2. Technology choices

| Concern | Choice |
|---|---|
| API style | Minimal APIs grouped per module, typed results |
| Validation | FluentValidation, executed before handlers |
| ORM | EF Core 8 for writes and simple reads; **Dapper** for ingest, sync feed and dashboards |
| Spatial | NetTopologySuite + `Npgsql.NetTopologySuite` (geography) |
| Auth | `Microsoft.AspNetCore.Authentication.JwtBearer` against Keycloak JWKS |
| Background | `IHostedService` + Channels; Redis Streams for the ingest queue |
| Scheduling | Quartz.NET (imports, nightly inference, reconciliation, retention) |
| Resilience | Polly (XInfo client, MinIO) |
| Object store | `AWSSDK.S3` pointed at MinIO, presigned URLs |
| OCR (server side) | PaddleOCR/Tesseract in a sidecar container; device OCR is preferred |
| Mapping | Mapperly (source-generated, no reflection) |
| Logging | Serilog → file + optional Seq/Loki, with a PII redaction enricher |
| Metrics/tracing | OpenTelemetry → Prometheus/Jaeger (optional on-prem) |
| Tests | xUnit, FluentAssertions, Testcontainers, NetArchTest |
| Migrations | EF Core migrations for app tables; the raw SQL in `db/schema` is the reference and the seed source |

## 3. Ingest pipeline (the hot path)

```csharp
// POST /v1/tracking/batch
1. Authorise device ↔ user binding.
2. Validate + clamp (accuracy, coordinate sanity, timestamp bounds, mock flag).
3. Deduplicate against ids already present (single round trip, ANY(@ids)).
4. Bulk insert via Npgsql binary COPY into location_ping / geofence_event.
5. Record clock skew for the device.
6. XADD to the Redis stream 'inference' keyed by user_id (coalesced).
7. Return 202 with duplicate counts and a throttle hint.
```

No inference, no journey writes, no XInfo calls on this path. Target p95 < 500 ms for a
100-event batch.

The inference consumer is **partitioned by user** so a user's events are never processed
concurrently by two workers — that ordering guarantee is what allows the state machine to be
written as straightforward sequential code.

## 4. Journey engine

Pure core, imperative shell:

```csharp
public interface IJourneyEngine
{
    JourneyResult Infer(JourneyInput input);   // pure: no I/O, no clock, no randomness
}

public sealed record JourneyInput(
    Guid UserId,
    DateTimeOffset WindowFrom,
    DateTimeOffset WindowTo,
    IReadOnlyList<Ping> Pings,
    IReadOnlyList<GeofenceEvt> Fences,
    IReadOnlyList<StayDetection> Stays,
    IReadOnlyList<Pause> Pauses,
    IReadOnlyList<JourneyEvent> Anchors,       // manual/confirmed events, never overwritten
    HomeLocation Home,
    IReadOnlyList<SiteGeo> Sites,
    TourContext? Tour,
    EngineConfig Config);

public sealed record JourneyResult(
    IReadOnlyList<JourneyEvent> Events,
    IReadOnlyList<JourneySegment> Segments,
    IReadOnlyList<Anomaly> Anomalies,
    JourneyState EndState);
```

The shell loads evidence for the window, calls `Infer`, then diffs against stored derived
rows: new rows inserted, stale AUTO rows marked `SUPERSEDED`, anchors untouched. Every run
is recorded in `tracking.inference_run` with the config snapshot and engine version, so a
disputed journey can be explained months later.

Because `Infer` is pure, the whole detection ruleset is testable from recorded traces with
no database — see [03 §10](03-tracking-and-journey.md#10-test-strategy-for-the-engine).

## 5. Sync implementation

**Pull.** A keyset query over `sync.change_log` joined to the scope predicate:

```sql
SELECT cl.* FROM sync.change_log cl
WHERE cl.id > @cursor
  AND ( cl.owner_user_id = @userId
     OR cl.customer_id IN (SELECT customer_id FROM customer.v_user_customer_scope WHERE user_id = @userId)
     OR cl.entity IN (SELECT unnest(@globalEntities)) )
ORDER BY cl.id
LIMIT @limit;
```

Row payloads are then fetched per entity in batches and projected to DTOs. Reference
entities (`config.*`, templates) are global; everything else is scoped.

**Push.** One transaction per dependency group, `client_mutation` written first as the
idempotency guard (`INSERT ... ON CONFLICT DO NOTHING` — if it did nothing, this is a replay
and the stored result is returned).

Conflict policy is a strategy per entity registered in DI:

```csharp
public interface IConflictPolicy<TEntity>
{
    ConflictDecision Decide(TEntity server, MutationEnvelope client);
}
```

so the table in [04 §4](04-offline-sync.md#4-conflict-policy-per-entity) is expressed in code
in exactly one place.

## 6. Background jobs

| Job | Schedule | Purpose |
|---|---|---|
| `InferenceConsumer` | Continuous (Redis stream) | Journey state machine |
| `LateEvidenceReinference` | Every 15 min | Windows touched by late-arriving data |
| `NightlyReinference` | 02:00 | Previous 3 days per active user |
| `OutboxDispatcher` | Continuous, `SKIP LOCKED` | Push to XInfo |
| `XInfoCustomerImport` | Every 30 min | Customer/site/contact delta |
| `XInfoHierarchyImport` | Hourly | Org and assignment |
| `XInfoStatusPull` | Every 30 min | Expense status flow-back |
| `Reconciliation` | 01:00 | Local vs XInfo counts/sums |
| `DailyRollup` | 01:30 | `daily_journey_summary`, attendance |
| `AttachmentPostProcess` | On upload | Virus scan, thumbnail, server OCR fallback |
| `AutoCloseVisits` | Every 10 min | Close visits after confirmed departure |
| `AutoResumeTracking` | Every 5 min | End forgotten pauses |
| `PartitionMaintenance` | Daily | Create next month, detach expired |
| `RetentionPurge` | Weekly | Apply `sync.retention_rule` |
| `GeofenceRadiusSuggestion` | Weekly | Propose per-site radius from check-in spread |

## 7. Error handling and observability

- RFC 9457 `application/problem+json` everywhere, with a stable `type` URI per error class.
- Correlation id per request, propagated into logs, outbox rows and audit entries.
- Health endpoints: `/health/live`, `/health/ready` (DB, Redis, MinIO, XInfo circuit state).
- Key metrics: ingest batch latency, inference lag per user, outbox depth and oldest age,
  push conflict rate, device sync staleness distribution, tracking coverage percentage.
- Alerts that actually matter on-prem: outbox depth rising, any `DEAD` message,
  reconciliation discrepancy, inference lag > 30 min, more than N devices unsynced > 24 h.

## 8. Security implementation notes

- Authorisation is enforced twice: endpoint policy and a repository-level scope predicate
  built from `identity.fn_visible_user_ids`.
- `current_setting('xmobile.actor_id')` is set per connection from the authenticated user so
  the change-feed and audit triggers can record the actor without threading it through
  every call.
- Presigned URLs are minted per object key with short expiry; the app never holds MinIO
  credentials.
- Rate limiting per device on `/v1/tracking/batch`, `/v1/sync/push` and auth endpoints.
- All raw-trail reads by a manager write an `audit.audit_log` entry.
