# 05 — XInfo (XStudio CRM) integration

XInfo owns customer master data and all back-office workflow (expense approval, settlement).
XMobile is the mobility system of record: it owns visits, reports, journeys and expense
*capture*, and pushes everything upward.

## 1. Direction of ownership

| Data | Master | Flow |
|---|---|---|
| Customer accounts, sites, contacts | **XInfo** | Pull → XMobile (read-mostly) |
| Customer geo-coordinates | **XMobile** (field-captured) | Pull if XInfo has them; push back field captures |
| Sales rep ↔ customer assignment | **XInfo** | Pull |
| Org hierarchy (rep → manager → territory) | **XInfo** | Pull |
| User accounts / credentials | AD/LDAP/OIDC | Neither; matched by employee code |
| Tours, visit plans | **XMobile** | Push (summary) |
| Visits, visit reports | **XMobile** | Push |
| Journey events, distance, attendance | **XMobile** | Push (daily summary + on completion) |
| Expenses + receipts | **XMobile** captures, **XInfo** approves | Push; status pulled back |
| Reference data (expense categories, visit types) | **XInfo** where it exists | Pull, mapped by code |

## 2. Transport

REST/JSON over HTTPS, both directions, on the LAN. Auth: client-credentials OAuth2 if XInfo
supports it, else a service API key in a header. All calls through a single
`IXInfoClient` with Polly policies (retry with jitter, circuit breaker, timeout) so a XInfo
outage degrades XMobile to "queueing" rather than "failing".

## 3. Inbound: pulling master data

Scheduled per entity (default: customers every 30 min, reference data nightly, hierarchy hourly).

```http
GET {xinfo}/api/customers?modifiedSince=2026-08-12T05:00:00Z&page=1&pageSize=500
```

Each run is recorded in `integration.inbound_sync_run` with counts and cursor, so a run can
be replayed. Import rules:

- Match on `xinfo_id` (stored in `customer_account.xinfo_id`, unique). Never match on name.
- Upsert; a field that XMobile owns (`geog` when `geo_source = FIELD_CAPTURED`,
  `geofence_radius_m`) is **not** overwritten by the pull.
- A customer disappearing from XInfo is soft-deactivated, never deleted — visits already
  reference it.
- Address change → re-geocode and, if the coordinate moves more than 500 m from a
  field-captured point, raise a data-quality exception rather than silently moving the fence.
- Assignment removal emits a `SCOPE_REMOVE` change so devices evict the customer.
- If XInfo cannot provide a `modifiedSince` filter, fall back to a full nightly pull with
  hash comparison; the schema supports both (`inbound_sync_run.mode`).

**Webhook option.** If XInfo can emit change notifications, `POST /v1/integration/xinfo/webhook`
accepts them (HMAC-signed) and triggers a targeted pull for those IDs. The poll remains as a
safety net — webhooks get missed.

## 4. Outbound: transactional outbox

Every pushable fact writes an `integration.outbox_message` **in the same transaction** as
the business row. A dispatcher worker drains it.

```
business tx: INSERT expense + INSERT outbox_message('EXPENSE_CAPTURED', payload)
dispatcher : claim batch (SKIP LOCKED) → POST to XInfo → mark SENT / retry with backoff
```

- `idempotency_key` = deterministic (`expense:{id}:v{row_version}`) so XInfo can dedupe.
- Backoff: 15 s, 1 m, 5 m, 15 m, 1 h, 6 h; after `max_attempts` (default 12) → `DEAD` and an
  operator alert. Dead messages are replayable from the admin UI.
- Ordering: per-aggregate ordering guaranteed (dispatcher processes one aggregate's messages
  in sequence); global ordering is not, and XInfo must not require it.
- Payload is a **snapshot**, not a reference — a message must be interpretable even if the
  local row later changes.

### Message types

| Type | Trigger | Contains |
|---|---|---|
| `VISIT_COMPLETED` | Visit checked out + report submitted | Visit, geo, timings, core report fields, dynamic answers, attachment refs |
| `VISIT_PLAN_CHANGED` | Plan created/rescheduled/skipped | Plan + reason |
| `TOUR_COMPLETED` | Tour completes | Dates, route summary, distance by mode, visit count, expense total |
| `EXPENSE_CAPTURED` | Expense submitted | Category (mapped code), amount, date, tour/visit link, receipt URLs or base64 |
| `EXPENSE_UPDATED` | Pre-push edit | Same |
| `JOURNEY_DAILY_SUMMARY` | Nightly per rep/day | First out, last in, km by mode, time at customers, gaps, anomalies |
| `CUSTOMER_GEO_CAPTURED` | Rep captures/corrects site coordinates | Site id, coords, accuracy, capturer, timestamp |
| `ATTENDANCE_DERIVED` | Nightly | Working/travel/leave classification derived from the journey |

### Receipts

Two supported modes, chosen per deployment:

1. **Pre-signed URL** — XMobile pushes a MinIO URL valid for N days; XInfo fetches. Preferred
   (no large payloads), requires network reachability from XInfo to MinIO.
2. **Inline base64** in the message, chunked if > 5 MB. Slower but works when XInfo cannot
   reach MinIO.

## 5. Status flow-back

XInfo owns approval, so XMobile pulls status back for display only:

```http
GET {xinfo}/api/expense-status?modifiedSince=...
→ [{ "externalRef": "expense:018f...", "status": "APPROVED|REJECTED|PAID",
     "remark": "...", "settledAmount": 1200.00, "settledOn": "2026-08-20" }]
```

Written to `expense.xinfo_status`, `xinfo_status_at`, `xinfo_remark`. XMobile takes no action
beyond notifying the rep. A rejected expense is not editable in XMobile — the rep captures a
corrected new entry, which keeps both systems' audit trails intact.

## 6. Reconciliation

Because a lost expense is lost money, a nightly job compares:

- count and sum of `expense` rows in state `PUSHED` per rep/day
  vs `GET {xinfo}/api/expense-summary?from=&to=`;
- visits pushed vs visits acknowledged;
- customers active in XInfo vs active locally.

Differences produce an `integration_discrepancy` report on the admin dashboard with a
one-click re-push. This job is the safety net that makes the whole capture-only model safe.

## 7. Mapping table

`integration.xinfo_entity_map` records `(local_type, local_id) ↔ (xinfo_type, xinfo_id)`
plus `last_pushed_row_version` and `last_pushed_at`. It is the basis of the reconciliation
job and of "has this been sent yet?" answers in support calls.

Code mappings (expense categories, visit types, outcomes) live in
`integration.code_map(domain, local_code, xinfo_code)` — editable in admin, because these
drift and must not require a release.

## 8. Contract to agree with the XInfo team

Before build starts, these need confirming:

1. Customer read endpoint: pagination, `modifiedSince`, soft-delete/inactive representation.
2. Whether XInfo exposes rep↔customer assignment and reporting hierarchy, and at what grain.
3. Expense intake endpoint: field list, category codes, receipt mode, idempotency support,
   maximum payload.
4. Whether XInfo can call back (webhook) or XMobile must poll.
5. Auth mechanism and credential rotation.
6. Status flow-back endpoint and its statuses.
7. Rate limits and maintenance windows.

Until they are confirmed, the `Integration` module is written against `IXInfoClient` with a
file-based stub implementation so the rest of the system can be built and tested. This is
also what makes the design safe if XInfo's API turns out to be limited — only the adapter
changes.
