# XInfo SQL Server — stored procedure contract

**For the XInfo DBA.** This folder is the complete list of what the XMobile gateway needs from
XInfo's database. Nothing else in XMobile touches your server.

## The one file that matters

[`01_procedures.sql`](01_procedures.sql) — 24 procedures in a new `xm` schema. Each is a stub
with:

- the **name** and **parameters** the gateway calls it with (by name, not position), and
- the **result-set columns** it expects back, documented in the comment above each one.

The bodies are yours. Map these onto whatever XInfo's tables actually look like — you can
change tables, joins, indexes and internal column names freely. Only the procedure name, the
parameter names and the result-set column names are fixed.

```sql
-- deploy the stubs first; the gateway will start and report red readiness until they work
sqlcmd -S <server> -d <xinfo-db> -i 01_procedures.sql
```

## Rules that are not negotiable

1. **Push procedures must be idempotent on `@IdempotencyKey`.** Called twice with the same
   key, the second call changes nothing and returns the first call's `XinfoId` with
   `WasDuplicate = 1`. The gateway retries aggressively; without this a retried expense is
   paid twice.

2. **Every push returns exactly one row:**
   `Accepted bit, XinfoId nvarchar(64) null, WasDuplicate bit, Message nvarchar(400) null`.
   A push that returns nothing is treated as a failure, because we would have no id to
   reconcile against later.

3. **Errors use `THROW` in the 50000+ range.** 50001 bad input · 50002 conflicting state ·
   50003 not permitted · 50004 not found. The gateway shows these to the rep and does **not**
   retry. Anything below 50000 it treats as a transient fault and **does** retry — so please
   do not use low numbers for business rules.

4. **Dates are `datetimeoffset`.** Reps cross time zones on multi-day tours; `datetime` here
   would silently shift arrival and departure times.

5. **Pull procedures order by `(ModifiedAt, <id>)`** and honour
   `@AfterModifiedAt` / `@AfterId` / `@PageSize`. We ask for `PageSize + 1` rows to detect
   whether more remain.

6. **Inactive is not deleted.** Return deactivated customers with `IsActive = 0` rather than
   omitting them — visits already recorded against them must keep resolving.

## Permissions

The gateway connects as one account and needs nothing but execute rights on this schema:

```sql
CREATE USER [svc_xmobile_gateway] FOR LOGIN [svc_xmobile_gateway];
GRANT EXECUTE ON SCHEMA::xm TO [svc_xmobile_gateway];
```

No table rights, no `db_datareader`. If it can only run these procedures, the surface it can
reach is exactly this file.

## Indexing

Every `_GetChanged` procedure sweeps a modified-since range and pages by `(ModifiedAt, Id)`.
Without a supporting index in that order on the underlying tables, these become scans. Please
review against real volumes — we would rather change our page size than have you carry a bad
plan.

## Questions we need answered

These are in [docs/12 §9](../../docs/12-xinfo-gateway.md#9-what-we-need-from-the-xinfo-team),
but the short version:

- Can we have a **dev instance** to point at, even with the stubs unimplemented?
- Does XInfo store **site coordinates**? If not we skip `xm.Site_CaptureGeo`.
- Does XInfo hold **mileage / per-diem rates**? If not we keep them on our side.
- **Receipts**: do you want a URL to fetch, or the bytes inline?
- How does a **rejected prospect** get back to us — through `Customers_GetChanged` with
  `IsActive = 0`, or somewhere else?

## How we keep this honest

A test in the XMobile build parses this file, extracts every `CREATE OR ALTER PROCEDURE`, and
compares it against the list the gateway actually calls — in both directions. If a procedure
is renamed on either side, or added in code and not here, or written here and never called,
the build fails. So this file cannot quietly go stale.
