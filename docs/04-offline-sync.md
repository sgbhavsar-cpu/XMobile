# 04 — Offline sync protocol

Decision: **full offline for the rep's working set, with an admin-tunable sync window.**

## 1. Principles

1. **The device is authoritative for what the rep created**; the server is authoritative for
   master data. Conflicts are decided per entity by a fixed policy, never ad hoc.
2. **Every client write is a mutation with a UUID.** Replay is free; duplicates are impossible.
3. **Nothing user-facing blocks on the network.** Not check-in, not report submission, not
   expense capture, not attachment upload.
4. **The client never invents server identity.** IDs are client-generated UUIDv7 and accepted
   by the server as-is, so there is no ID remapping pass. (UUIDv7 keeps index locality.)
5. **Sync is resumable and interruptible.** A dropped connection mid-sync loses nothing.

## 2. Working set

What the device holds, governed by `sync_policy` (per role, editable in admin):

| Entity | Default window |
|---|---|
| Assigned customer accounts + sites + contacts | All assigned, no time limit |
| Tours + tour days + visit plans | `back_days` 90, `forward_days` 30 |
| Visits + reports (own) | `back_days` 90 |
| Expenses (own) | `back_days` 180 |
| Form templates | All active + versions referenced by retained reports |
| Reference data | All |
| Location pings | Outbound queue only; purged after server ack + 7 days |
| Attachments | Metadata always; binaries per policy (`wifi_only`, `max_mb`, own-recent only) |

Admin knobs: `back_days`, `forward_days`, `attachment_policy`, `max_attachment_mb`,
`refresh_minutes`, `push_batch_size`, `pull_page_size`.

## 3. Protocol

### 3.1 Pull (server → client)

```http
GET /v1/sync/pull?cursor=<opaque>&entities=customer_site,visit_plan&limit=500
```

```json
{
  "changes": [
    { "entity": "customer_site", "id": "018f...", "op": "UPSERT",
      "rowVersion": 41, "updatedAt": "2026-08-12T06:11:03Z", "data": { } },
    { "entity": "visit_plan", "id": "018f...", "op": "DELETE",
      "rowVersion": 7, "updatedAt": "2026-08-12T06:12:44Z" }
  ],
  "nextCursor": "eyJsYXN0SWQiOjk5ODIzMX0",
  "hasMore": true,
  "serverTime": "2026-08-12T06:13:00Z",
  "policyVersion": 4
}
```

- The cursor is the last consumed `change_log.id` (a monotonic bigint), base64-wrapped.
- The change feed is filtered server-side by the rep's visibility scope (own data + assigned
  customers + team data for managers). Scope changes (a customer reassigned away) emit a
  `SCOPE_REMOVE` op so the client can evict the row.
- `policyVersion` bumps force the client to re-read `sync_policy` and, if the window
  shrank, purge; if it grew, backfill.
- **Initial sync** uses `cursor=null` and a bulk endpoint that streams the working set as
  NDJSON, resumable by page — a fresh device on a 3G link must not need a perfect connection.

### 3.2 Push (client → server)

```http
POST /v1/sync/push
```

```json
{
  "deviceId": "018f...",
  "deviceTime": "2026-08-12T06:14:02Z",
  "mutations": [
    { "clientMutationId": "018f-aaa", "entity": "visit", "id": "018f-v1",
      "op": "INSERT", "baseVersion": null, "occurredAt": "2026-08-12T05:40:00Z",
      "data": { } },
    { "clientMutationId": "018f-bbb", "entity": "visit_report", "id": "018f-r1",
      "op": "UPDATE", "baseVersion": 3, "data": { } }
  ]
}
```

```json
{
  "results": [
    { "clientMutationId": "018f-aaa", "status": "APPLIED",   "rowVersion": 1 },
    { "clientMutationId": "018f-bbb", "status": "CONFLICT",
      "reason": "STALE_VERSION", "serverRowVersion": 5, "serverData": { },
      "resolution": "SERVER_WINS", "conflictId": "018f-c1" }
  ],
  "serverTime": "2026-08-12T06:14:03Z"
}
```

Statuses: `APPLIED`, `DUPLICATE` (already processed — returns original result),
`CONFLICT`, `REJECTED` (validation/permission, with `errors[]`), `DEFERRED`
(dependency not yet present; client retries after its prerequisite).

**Ordering.** Mutations within a batch apply in array order inside one transaction per
*dependency group* (a visit and its report go together). A `REJECTED` mutation does not roll
back independent mutations — otherwise one bad row blocks a rep's whole day.

**Dependencies.** The client sorts by dependency (tour → visit_plan → visit → report →
attachment link). The server accepts out-of-order arrivals by returning `DEFERRED` rather
than failing, which keeps clients simple and tolerant of partial batches.

### 3.3 Location & journey evidence

Separate, append-only, higher-volume path — not part of the general mutation feed:

```http
POST /v1/tracking/batch
{ "deviceId": "...", "sessionId": "...", "pings": [...], "events": [...], "heartbeat": {...} }
→ { "acceptedPingIds": [...], "acceptedEventIds": [...], "duplicates": n, "nextUploadAfterSec": 60 }
```

Append-only means no conflicts by construction. `client_event_id` gives dedupe.
`nextUploadAfterSec` lets the server throttle a fleet under load — a small feature that
prevents a thundering herd when connectivity returns to a whole region at once.

## 4. Conflict policy per entity

| Entity | Policy | Rationale |
|---|---|---|
| `customer_account`, `customer_site`, `customer_contact` | **Server wins**, always | XInfo is master; client edits are proposals |
| Site geo capture (`FIELD_CAPTURED`) | **Client wins** if newer and more trusted source | Field capture beats geocode |
| `tour`, `tour_day` | Server wins if the tour was changed by a manager; else last-write-wins on `updated_at` | Manager reassignment must stick |
| `visit_plan` | Field-level merge: rep owns `seq`/`status`/`skip_reason`; manager owns assignment | Both edit legitimately, different fields |
| `visit` (check-in/out) | **Client wins**, immutable after `REPORT_SUBMITTED` | Only the device was there |
| `visit_report` | Client wins while `DRAFT`; **immutable once submitted** (correction = amendment row) | Report integrity |
| `expense` | Client wins while `DRAFT`/`SUBMITTED`; immutable once `PUSHED` to XInfo | Money left the system |
| `attachment` | Append-only, immutable | Binary identity by sha256 |
| `location_ping`, `geofence_event` | Append-only | No conflict possible |
| `journey_event` | Server-derived; a rep override becomes a new `MANUAL` event, never an edit | Auditability |
| Reference data, `form_template` | Server wins | Config |

Anything that resolves as `SERVER_WINS` where the client had local edits writes a
`sync_conflict` row **and** surfaces in the app's "Sync issues" inbox with both versions.
Silently discarding a rep's typing is how you lose users' trust in a sync engine.

## 5. Attachment queue

Three phases, each independently retriable:

1. `POST /v1/attachments` with `{ fileName, mime, sizeBytes, sha256, capturedAt, geo }`
   → `{ attachmentId, storageKey, uploadUrls[] (presigned, multipart), partSizeBytes }`.
   If `sha256` already exists on the server, returns `deduplicated: true` and no upload is needed.
2. `PUT` each part to MinIO directly, resumable, parallelism 2, exponential backoff.
3. `POST /v1/attachments/{id}/complete` → server verifies size + sha256, queues OCR + thumbnail.

Client rules: WiFi-only if policy says so; max in-flight 1 on cellular; queue ordered by
business priority (expense receipts before visit selfies); a failed upload never blocks the
parent entity from syncing — the entity references an attachment in `PENDING_UPLOAD` state
and the manager UI shows it as such.

## 6. Client storage (Flutter)

- **Drift (SQLite)** with the same logical schema as the server subset, plus:
  - `_outbox(mutation_id, entity, entity_id, op, payload, created_at, attempts, status, last_error)`
  - `_sync_state(entity, cursor, last_pull_at, last_push_at)`
  - `_conflicts(...)` mirroring server conflict rows
- SQLCipher encryption at rest; key in Keystore/Keychain.
- Every local write goes through a repository that writes the row **and** the outbox entry in
  one transaction. There is no code path that mutates data without enqueuing.

## 7. Sync triggers

| Trigger | Action |
|---|---|
| App foreground | Pull + push |
| Connectivity regained | Push first (get the rep's work out), then pull |
| Every `refresh_minutes` (default 15) in foreground | Delta pull |
| WorkManager/BGTaskScheduler periodic (15 min Android, opportunistic iOS) | Push outbox, upload attachments |
| Any business action while online | Optimistic immediate push of that mutation |
| Push notification `sync_hint` | Targeted pull (e.g. plan changed) |
| Manual pull-to-refresh | Full delta cycle with visible progress |

## 8. Failure modes and responses

| Failure | Response |
|---|---|
| Auth token expired offline | Long-lived refresh token (30 d, device-bound); app stays usable read/write and syncs on next successful refresh |
| Server rejects a mutation permanently | Move to conflicts inbox with a plain-language explanation; never silently drop |
| Outbox grows beyond `max_outbox_rows` | Warn the rep at 70 %, block *attachment* capture at 95 %, never block visit/expense capture |
| Clock skew | Server stores both times; ordering uses server-corrected timestamps |
| Device lost / reinstalled | Server retains everything already pushed; unpushed local data is gone — so push cadence for expenses and reports is aggressive (immediate attempt on save) |
| Two devices, one user | Allowed; both hold the working set. Per-entity policies handle the overlap; `device_id` recorded on every mutation for forensics |

## 9. Observability

Each sync cycle reports client-side: durations, counts by status, bytes, battery delta.
The server exposes `/v1/sync/health` per device: last pull/push, outbox backlog estimate,
oldest unsynced mutation age. Managers see a "last synced" badge per rep — an offline rep
and a rep who did nothing look identical otherwise, and that distinction matters daily.
