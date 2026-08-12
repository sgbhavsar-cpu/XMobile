# Database

PostgreSQL 16 + PostGIS 3.4. Files in `schema/` run in filename order and are idempotent
per-file only in the sense that they assume a fresh database — for an existing database use
EF Core migrations generated from these definitions.

## Create a database locally

```bash
createdb xmobile
for f in db/schema/*.sql; do psql -v ON_ERROR_STOP=1 -d xmobile -f "$f"; done
```

Or with Docker:

```bash
docker run -d --name xmobile-db -e POSTGRES_PASSWORD=xmobile -p 5432:5432 \
  -v "$PWD/db/schema:/docker-entrypoint-initdb.d:ro" postgis/postgis:16-3.4
```

The compose file in [docs/09](../docs/09-deployment.md) mounts `db/schema` the same way, so a
fresh deployment is bootstrapped automatically.

## File order

| File | Contents |
|---|---|
| `00_extensions.sql` | Extensions, schemas, enum types, change-feed machinery, config + reference tables |
| `01_identity_org.sql` | Org units, users, roles, devices, home locations, leave, consent |
| `02_customer.sql` | Accounts (incl. field-proposed prospects), sites, contacts, assignment, opportunities + stage history, sales history, geofence registry |
| `03_planning.sql` | Tours, tour days, visit plans, plan revisions, route suggestions |
| `04_tracking.sql` | Sessions, pings (partitioned), geofence events, journey events/segments, anomalies, rollups |
| `05_visit_report.sql` | Visits, form templates, reports, amendments, attachment and opportunity links |
| `06_expense.sql` | Attachments, OCR, categories, mileage/per-diem rates, city tiers, expenses, share inbox |
| `07_sync.sql` | Client mutations, conflicts, device cursors, sync policy, retention rules |
| `08_integration.sql` | Outbox, inbound runs, entity/code maps, reconciliation, audit, notifications |
| `09_views.sql` | Dashboard views, customer 360, open pipeline, scope helpers, site matching, radius and mileage suggestion, duplicate probe |
| `10_seed.sql` | Roles, visit types, outcomes, opportunity stages, reason codes, expense categories, rates, city tiers, tuning defaults, a sample form template |

## Conventions

- **Syncable tables** carry `row_version bigint`, `created_at`, `updated_at` and (where soft
  deletion applies) `deleted_at`, and are registered with
  `config.fn_make_syncable(table, owner_col, customer_col [, key_col])`. That attaches:
  a `BEFORE UPDATE` trigger bumping `row_version`/`updated_at`, and an `AFTER` trigger writing
  to `sync.change_log`, which is the feed `/v1/sync/pull` reads.
  Pass `key_col` when the primary key is not `id` (`'code'`, `'visit_id'`, or `'domain||code'`
  for a composite key).
- **Client-generated ids.** Tables the mobile app inserts into (`visit`, `expense`,
  `attachment`, `location_ping`, `tracking_session`, `device`) have no `DEFAULT` on `id` —
  the device supplies a UUIDv7, which is what makes retries idempotent.
- **Geography, not geometry.** All spatial columns are `geography(...,4326)` so distances come
  back in metres without projection handling.
- **Actor for audit.** Set `xmobile.actor_id` on the connection
  (`SET LOCAL xmobile.actor_id = '<uuid>'`) and the change-feed/audit triggers record who did it.
- **Partitions.** `tracking.location_ping` is range-partitioned by month;
  `tracking.fn_ensure_ping_partition(date)` creates a month with its indexes and is called by
  the maintenance job ahead of time.
