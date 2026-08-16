# 12 — XInfo gateway

XInfo has no API. Since XMobile depends on XInfo for customer master data and expense
settlement, we build that API ourselves: a service that speaks REST to XMobile and stored
procedures to XInfo's SQL Server.

**This changes nothing about our own database.** XMobile stays on PostgreSQL + PostGIS
exactly as designed in [02](02-domain-model.md) and `db/schema/`. The gateway is the concrete
implementation of the `IXInfoClient` seam described in [05](05-xinfo-integration.md) — the
adapter becoming a real service, not a replacement for anything.

```
┌──────────────┐   REST   ┌───────────────────┐   stored procs   ┌──────────────────┐
│   XMobile    │─────────►│   XInfo.Gateway   │─────────────────►│  XInfo SQL Server│
│   backend    │◄─────────│  (this project)   │◄─────────────────│  (their schema)  │
│  PostgreSQL  │          └───────────────────┘                  └──────────────────┘
└──────────────┘             ours to build          bodies written by the XInfo DBA
```

## 1. Who owns what

| Layer | Owner |
|---|---|
| REST contract, validation, paging, retry, error mapping, reconciliation | **Us** (`src/XInfo.Gateway.*`) |
| Procedure names, parameters, result-set columns | **Agreed** — `db/xinfo-mssql/01_procedures.sql` |
| Procedure bodies, XInfo's tables, indexes, query plans | **XInfo DBA** |
| XMobile's own database | **Us**, unchanged, PostgreSQL |

The split is deliberate. The DBA can restructure XInfo's tables freely as long as the
procedures keep their signatures, and we can change our REST contract without asking them.

## 2. Why stored procedures only

There is no ad-hoc SQL anywhere in `XInfo.Gateway.Data`, and `ISqlExecutor` offers no way to
write any. This is someone else's production database:

- a query written in our C# is a query their DBA never reviewed and cannot tune;
- it breaks silently the next time they rename a column;
- and it makes the surface we depend on invisible to the people responsible for the schema.

Confining everything to named procedures in one schema (`xm`) means the whole dependency is
listable — `GET /v1/ops/procedures` returns it — and grantable: the gateway's account needs
`EXECUTE ON SCHEMA::xm` and no table rights at all.

## 3. Pull: delta-first, keyset-paged

Every read is "what changed since?", never "give me everything". A nightly full pull of a
live CRM is how a gateway gets throttled by its DBA.

Paging is keyset on `(ModifiedAt, Id)`, not `OFFSET`. Two reasons, both from experience:

- the source keeps changing while we page, and `OFFSET` over a moving table silently skips
  and repeats rows;
- a bulk update in XInfo stamps hundreds of rows with the same `ModifiedAt`, so a watermark
  on the timestamp alone either loses the rest of that second or replays it forever. The id
  tie-break is what makes the cursor exact.

A cursor we cannot parse restarts from the beginning rather than failing — duplicates are
absorbed by our upsert, a stuck sync is not.

## 4. Push: idempotent by construction

Every write carries `PushEnvelope { MessageId, IdempotencyKey, OccurredAt, EmployeeCode }`,
and every procedure must return `Accepted, XinfoId, WasDuplicate, Message`.

The caller is our transactional outbox, which retries anything it cannot classify as a
permanent failure. Without watertight idempotency on XInfo's side, a retried delivery creates
a second expense and someone is paid twice. This is the single most important property in the
whole integration, which is why the contract states it in bold and a test asserts every push
procedure takes the key.

**Opportunities** need one more thing: `RepFieldsUpdatedAt`, an ordering token. It is the only
two-way entity — both sides legitimately edit it — so XInfo rejects an update older than what
it holds. That is how a rep's offline edit and a XInfo-side edit stop overwriting each other.

## 5. Error classification

| From XInfo | Meaning | Gateway response | Caller does |
|---|---|---|---|
| `THROW 50001` | Bad input | 422 | Fix and resubmit; do not retry |
| `THROW 50002` | Conflicting state (e.g. stale opportunity update) | 422 | Surface to the rep |
| `THROW 50003` | Not permitted | 422 | Surface |
| `THROW 50004` | Not found | 422 | Surface |
| Deadlock, timeout, connection reset | Transient | Retried in-process, then 503 | Keep in outbox, retry later |
| Anything else | Fault | 503 | Keep in outbox, retry later |

The distinction that matters: **503 means "again", 422 means "never"**. An outbox that retries
a 422 forever is as bad as one that drops a 503.

## 6. Reconciliation

Because XInfo owns settlement, an expense that never arrived is money a rep does not get back.
`GET /v1/xinfo/reconciliation` returns what XInfo believes it holds for a period — count, sum,
and the list of idempotency keys — so our nightly job can compare against our own records and
re-push the difference. This check is what makes the capture-only expense model safe.

## 7. Deployment

Runs on-premise next to XInfo's SQL Server. Authentication between our backend and the gateway
is a shared key (`X-Gateway-Key`), compared in fixed time; both services sit on the same
network and there is no token issuer that spans them. An unset key refuses every request
rather than allowing all of them — this service can write into the company's CRM.

Readiness stays red until `xm.MobileGateway_Health_Check` answers, so a half-deployed DBA
release is caught before traffic reaches it.

## 8. What is verified, and what is not

**Verified here** (20 tests, no database needed): paging and cursor behaviour including the
same-timestamp tie-break, page-size capping, idempotency envelope on every push, receipts
skipped on a duplicate, ordering token on opportunity updates, error classification, and a
drift test that fails the build if the procedures named in C# and those declared in
`db/xinfo-mssql/01_procedures.sql` ever diverge in either direction.

**Not verified here:** most of the procedure bodies. A local Docker SQL Server restored from a
real XInfo backup (`db/xinfo-mssql/docker-compose.yml`) let us implement and hand-verify
`xm.MobileGateway_Customers_GetChanged` against real `dbo.Accounts` data — the rest are still
`[XInfo-DBA-TODO]` skeletons. Until every procedure has gone through the same study-and-verify
pass, the remaining result-set shapes are an agreement, not a fact.

A note on the drift test: its first version compared with `Contains`, which passed happily when
`xm.Expense_Push` was renamed to `xm.Expense_PushRenamed` — the old name is a substring of the
new one. It now parses declarations and compares both directions. A test that cannot fail is
worse than no test, because it is trusted.

## 9. What we need from the XInfo team

Ordered by what blocks us soonest:

1. **A dev SQL Server** we can point the gateway at, even with empty stubs. Everything above
   is unproven until then.
2. **Confirmation of the result-set columns** in `db/xinfo-mssql/01_procedures.sql`, especially
   where we have guessed at what XInfo holds: `Grade`, `CreditStatus`, `OrgUnitCode`.
3. **Does XInfo hold site coordinates at all?** If there is nowhere to put `Lat`/`Lon`, we drop
   `xm.MobileGateway_Site_CaptureGeo` and keep field-captured positions on our side only.
4. **Does XInfo hold mileage and per-diem rates?** If not, we maintain them in XMobile's admin
   and drop `xm.MobileGateway_Rates_GetCurrent`.
5. **Receipts: URL or bytes?** URL keeps payloads small but needs XInfo to reach our object
   store across the network.
6. **How does a rejected prospect come back to us?** Our rep is already visiting them.
7. **Rate limits and maintenance windows**, so our pull schedule does not collide with their
   batch jobs.
