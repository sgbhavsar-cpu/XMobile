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
8. **Opportunity API** — read/write endpoints, stage vocabulary, does it accept partial
   (field-level) updates, and can it accept an externally-created id?
9. **Prospect intake** — can XInfo hold a proposed customer in a pending state, and what does
   it return on approval or rejection?
10. **Sales history** — order/invoice read access, header-only or line items, and how far back?
11. **Rate tables** — does XInfo publish mileage and per-diem rates for us to sync, or do we
    maintain them in XMobile's admin? (Suggested amounts are only as good as these rates.)

**One operational question left with you:** are devices enrolled in MDM? It does not change
the design — the app self-diagnoses either way — but with MDM we can push the
battery-optimisation exemption and `Always` location permission centrally instead of walking
every rep through OEM settings screens, which is the difference between a smooth rollout and
a hundred support calls.

## 6. What I would build first, if you want a single next step

The journey engine with trace replay ([03 §10](03-tracking-and-journey.md#10-test-strategy-for-the-engine)).
It is the highest-risk, highest-value component, it needs no UI, no XInfo and no network,
and getting it right early prevents a rewrite of everything that consumes its output.
