# XMobile — Sales Force Mobility Platform

Field-sales mobility solution: visit planning, reliable journey tracking, visit reporting,
and expense capture — built to work fully offline and to feed the existing **XInfo (XStudio)**
CRM as the system of record for master data and back-office workflow.

| Layer | Technology |
|---|---|
| Mobile app | Flutter (Android + iOS), Drift/SQLite local store, Riverpod |
| Backend | ASP.NET Core 8 (C#), modular monolith + background workers |
| Database | PostgreSQL 16 + PostGIS |
| Object store | MinIO (S3-compatible), on-premise |
| Cache / queue | Redis |
| Identity | Corporate AD/LDAP or OIDC (Keycloak federation) |
| Deployment | Docker Compose / Kubernetes, **on-premise** |
| Integration | REST both ways with XInfo (pull customers, push everything else) |

## Design decisions taken

| Question | Decision |
|---|---|
| Scale / deployment | On-premise, self-hosted; no cloud-managed dependencies except FCM/APNs |
| Fleet size | **Under 100 reps** — single API + single worker; Redis optional at this size |
| Platforms | Android **and** iOS, mixed company-owned / BYOD → tracking must tolerate sparse data |
| Tracking window | Hybrid: auto-starts on scheduled duty/tour days; rep may pause with a logged reason |
| Trip model | **Tour** (multi-day container) with optional editable per-day sub-plans |
| Tour approval | **Self-service** — no approval gate; manager reviews plan-vs-actual afterwards |
| Expenses | **Capture only** — XInfo owns approval, settlement and reimbursement |
| Money math | App shows **indicative** mileage/per-diem from synced rates; XInfo decides finally |
| Master data | XInfo owns customers; XMobile syncs down and pushes visits/journeys/expenses up |
| Field-created customers | Rep proposes a **prospect** (visitable at once, XInfo approves); sites and contacts created directly |
| Opportunities | Full CRUD in the app, linked to visits — the one **two-way** synced entity |
| Sales history | Pulled from XInfo, read-only rolling window, visible offline |
| Orders / catalogue | **Out of scope** — orders stay in XInfo |
| Integration | REST API both directions, transactional outbox + idempotency keys |
| Identity | **Keycloak deployed with the app** (LDAP federation available later) |
| Offline | Full offline for the rep's working set, with an admin-tunable sync window |
| Visit report | Fixed core fields + admin-defined dynamic extension section (versioned templates) |
| Visit proof | **GPS + dwell**; photos optional and rep-chosen, no mandatory selfie |
| Attendance | Derived from journey data, **information only** — not the payroll record |
| Push | FCM/APNs permitted; notification-only payloads, never depended on |
| Localisation | Multi-language structure built in (`name_i18n`, label maps); **English ships first** |
| Geography | India today, kept timezone- and locale-flexible |

## Documentation

| Doc | Contents |
|---|---|
| [01 — Architecture](docs/01-architecture.md) | System context, components, deployment topology, NFRs |
| [02 — Domain model](docs/02-domain-model.md) | Entities, relationships, lifecycle states |
| [03 — Tracking & journey state machine](docs/03-tracking-and-journey.md) | The hard part: reliable cross-platform detection |
| [04 — Offline sync protocol](docs/04-offline-sync.md) | Pull/push protocol, conflict rules, attachment queue |
| [05 — XInfo integration](docs/05-xinfo-integration.md) | Contracts, outbox, reconciliation |
| [06 — Security, identity & privacy](docs/06-security-identity.md) | OIDC, RBAC, consent, anti-tamper, retention |
| [07 — Flutter app structure](docs/07-flutter-app.md) | Project layout, packages, background execution, share-intent |
| [08 — Backend structure](docs/08-backend-structure.md) | .NET solution layout, modules, workers |
| [09 — Deployment](docs/09-deployment.md) | docker-compose, sizing, backup, upgrade |
| [10 — Roadmap](docs/10-roadmap.md) | Phasing, risks, open questions |
| [11 — Journey engine](docs/11-journey-engine.md) | The built inference core: structure, defects the tests caught, known limits |

## Database

Ordered DDL in [`db/schema/`](db/schema/) — run in filename order.

```
00_extensions.sql      Extensions, schemas, enum types, shared functions
01_identity_org.sql    Users, roles, org units, devices, home locations, leave
02_customer.sql        Customer accounts, sites, contacts, geofences, assignment
03_planning.sql        Tours, tour days, visit plans
04_tracking.sql        Tracking sessions, pings (partitioned), geofence events,
                       journey events/segments, anomalies, distance rollups
05_visit_report.sql    Visits, form templates, visit reports
06_expense.sql         Attachments, OCR, expense categories and expenses
07_sync.sql            Change feed, client mutations, conflicts, sync policy
08_integration.sql     Outbox, inbound runs, entity mapping, audit, notifications
09_views.sql           Reporting views and helper functions
10_seed.sql            Reference data seed
```

## API

OpenAPI 3.1 outline: [`api/openapi.yaml`](api/openapi.yaml).

## Code

```
app/                                     Flutter app (built, runs on mock backend)
src/Modules/XMobile.Tracking.Engine/     journey inference core (built)
tests/XMobile.Tracking.Engine.Tests/     53 trace-replay tests
```

```bash
dotnet test                    # 53 engine tests — no database, network or device
cd app && flutter test         # 52 app tests — no device or emulator
```

**Journey engine** — a pure `Infer(JourneyInput) → JourneyResult` with no dependencies, so
the whole detection ruleset replays over recorded traces in CI.
See [11 — Journey engine](docs/11-journey-engine.md).

**Flutter app** — every screen and form, running against an in-memory backend that implements
the same `ApiClient` contract the HTTP client will. Connecting to the real API is an override
of one provider. Location capture, share-intent receipts and permission dialogs are entered
manually for now; the manual paths stay afterwards as fallbacks. See [app/README](app/README.md).
