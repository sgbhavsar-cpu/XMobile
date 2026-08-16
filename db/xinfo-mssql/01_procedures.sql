/* =====================================================================
   XMobile ↔ XInfo gateway — stored procedure contract
   Target: Microsoft SQL Server 2016 or later, inside the XInfo database
   Owner:  XInfo DBA (bodies)   ·   XMobile team (signatures + result sets)

   HOW TO READ THIS FILE
   ---------------------
   Each procedure below is a stub. The signature and the documented result set are the
   contract the gateway is coded against — a test in the XMobile build fails if a name here
   and a name in the C# ever disagree. The BODY is yours: map these parameters and columns
   onto whatever XInfo's tables actually look like today.

   You may freely change tables, joins, indexes and internal column names. Only three things
   must hold:
     1. the procedure name,
     2. the parameter names (the gateway passes them by name, not position),
     3. the result-set column names and their order-independent presence.

   CONVENTIONS
   -----------
   * Schema `xm` — everything XMobile depends on lives here, so you can see the whole
     surface at once and grant EXECUTE on exactly it.
   * Dates are `datetimeoffset`. XMobile reps cross time zones on multi-day tours, and a
     `datetime` here would silently shift arrival and departure times.
   * Errors: THROW 50001 for bad input, 50002 for a conflicting state, 50003 for not
     permitted, 50004 for not found. The gateway maps 50000+ to a message it shows the rep
     and does NOT retry. Anything below 50000 it treats as a fault and retries.
   * Every push procedure MUST be idempotent on @IdempotencyKey and MUST return one row:
       Accepted bit, XinfoId nvarchar(64) null, WasDuplicate bit, Message nvarchar(400) null
     Called twice with the same key, the second call must change nothing and return the
     first call's XinfoId with WasDuplicate = 1. The gateway's outbox retries on any
     unclear failure; without this a retried expense is paid twice.
   * Pull procedures take (@ModifiedSince, @AfterModifiedAt, @AfterId, @PageSize) and must
     order by (ModifiedAt, <id>) so keyset paging is stable. The gateway asks for PageSize+1
     rows to detect whether more remain — return up to that many.

   SUGGESTED INDEXES (please confirm against real volumes)
   ------------------------------------------------------
   Every _GetChanged procedure sweeps a modified-since range and pages by (ModifiedAt, Id).
   Without a covering index on the underlying tables in that order, these become scans.
   ===================================================================== */

IF SCHEMA_ID('xm') IS NULL EXEC('CREATE SCHEMA xm');
GO

/* =====================================================================
   1. PULL — master data
   ===================================================================== */

/* Customers changed since a watermark.
   RESULT SET:
     XinfoId nvarchar(64), Name nvarchar(200), Code nvarchar(50) null,
     LegalName nvarchar(200) null, AccountType nvarchar(50) null, Category nvarchar(20) null,
     Industry nvarchar(100) null, ParentXinfoId nvarchar(64) null,
     OwnerEmployeeCode nvarchar(50) null, OrgUnitCode nvarchar(50) null,
     CreditStatus nvarchar(50) null, GstNumber nvarchar(20) null, Phone nvarchar(50) null,
     Email nvarchar(200) null, IsActive bit, ModifiedAt datetimeoffset

   NOTE: inactive/deleted customers must still be returned with IsActive = 0. XMobile
   deactivates rather than deletes — visits already recorded against them must keep resolving. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Customers_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- Sourced from dbo.Accounts. Two fields have no equivalent in XInfo and are always NULL:
    -- LegalName (CustomerName is a redundant copy of Name, not a distinct legal name) and Email
    -- (no account-level email column exists — only per-contact, via AccountContactDetails,
    -- which xm.MobileGateway_Contacts_GetChanged sources). CreditStatus is also left NULL: the
    -- only candidate field, Status, is really an approval-workflow flag ("Approved"/NULL), not
    -- a credit concept, so mapping it here would be misleading. Industry only resolves for
    -- ~26% of populated values against dbo.Industry (stale GUIDs from a past migration) — kept
    -- anyway since partial data beats none, and recent rows resolve much better than old ones.
    -- ModifiedAt: dbo.Accounts.ModifiedOn is a plain datetime with no stored offset; XInfo's
    -- clock is IST, so TODATETIMEOFFSET stamps +05:30 without shifting the wall-clock value.
    SELECT TOP (@PageSize)
        XinfoId            = a.ID,
        Name               = a.Name,
        Code               = a.Abbreviation,
        LegalName          = CAST(NULL AS nvarchar(200)),
        AccountType        = a.AccountType,
        Category           = a.Businesstype,
        Industry           = ind.Name,
        ParentXinfoId      = a.ParentID,
        OwnerEmployeeCode  = u.Name,
        OrgUnitCode        = sr.Name,
        CreditStatus       = CAST(NULL AS nvarchar(50)),
        GstNumber          = a.GSTRegistrationnumber,
        Phone              = a.Phone,
        Email              = CAST(NULL AS nvarchar(200)),
        IsActive           = CASE WHEN a.IsDeleted = 1 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
        ModifiedAt         = TODATETIMEOFFSET(a.ModifiedOn, '+05:30')
    FROM dbo.Accounts a
    -- OwnerEmployeeCode requires cross-database read access to XStudio_Configuration, which
    -- the account this procedure runs under does not have by default — grant it, or ask XInfo
    -- to replicate a local copy of XStudio_User_Mst_Tbl into this database instead.
    LEFT JOIN XStudio_Configuration.dbo.XStudio_User_Mst_Tbl u ON u.ID = a.AssignedUserID
    LEFT JOIN dbo.SalesRegion sr ON sr.ID = a.SalesRegionId
    LEFT JOIN dbo.Industry ind ON ind.ID = a.Industry
    WHERE (@ModifiedSince IS NULL OR TODATETIMEOFFSET(a.ModifiedOn, '+05:30') >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR TODATETIMEOFFSET(a.ModifiedOn, '+05:30') > @AfterModifiedAt
            OR (TODATETIMEOFFSET(a.ModifiedOn, '+05:30') = @AfterModifiedAt AND a.ID > @AfterId)
          )
    ORDER BY a.ModifiedOn, a.ID;
END
GO

/* Targeted refresh for specific ids (used after a change notification).
   @XinfoIds is comma-separated; STRING_SPLIT is fine.
   RESULT SET: identical to xm.MobileGateway_Customers_GetChanged. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Customers_GetByIds
    @XinfoIds nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    -- Same source and field mapping as xm.MobileGateway_Customers_GetChanged above — see its
    -- comment for why LegalName/Email/CreditStatus are NULL and Industry only partially resolves.
    SELECT
        XinfoId            = a.ID,
        Name               = a.Name,
        Code               = a.Abbreviation,
        LegalName          = CAST(NULL AS nvarchar(200)),
        AccountType        = a.AccountType,
        Category           = a.Businesstype,
        Industry           = ind.Name,
        ParentXinfoId      = a.ParentID,
        OwnerEmployeeCode  = u.Name,
        OrgUnitCode        = sr.Name,
        CreditStatus       = CAST(NULL AS nvarchar(50)),
        GstNumber          = a.GSTRegistrationnumber,
        Phone              = a.Phone,
        Email              = CAST(NULL AS nvarchar(200)),
        IsActive           = CASE WHEN a.IsDeleted = 1 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
        ModifiedAt         = TODATETIMEOFFSET(a.ModifiedOn, '+05:30')
    FROM dbo.Accounts a
    INNER JOIN STRING_SPLIT(@XinfoIds, ',') ids ON ids.value = a.ID
    LEFT JOIN XStudio_Configuration.dbo.XStudio_User_Mst_Tbl u ON u.ID = a.AssignedUserID
    LEFT JOIN dbo.SalesRegion sr ON sr.ID = a.SalesRegionId
    LEFT JOIN dbo.Industry ind ON ind.ID = a.Industry;
END
GO

/* Sites (physical locations) changed since a watermark.
   RESULT SET:
     XinfoId nvarchar(64), CustomerXinfoId nvarchar(64), Name nvarchar(200),
     SiteCode nvarchar(50) null, SiteType nvarchar(50) null, IsPrimary bit,
     AddressLine1 nvarchar(200) null, AddressLine2 nvarchar(200) null,
     Landmark nvarchar(200) null, City nvarchar(100) null, District nvarchar(100) null,
     State nvarchar(100) null, PostalCode nvarchar(20) null, CountryCode char(2) null,
     Lat float null, Lon float null, IsActive bit, ModifiedAt datetimeoffset

   Lat/Lon may be NULL — we expect that. XMobile captures coordinates in the field and
   pushes them back via xm.MobileGateway_Site_CaptureGeo. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Sites_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- dbo.AccountPremises ("sites" as a distinct sub-location) covers only 34 of 9,804
    -- accounts and has no address fields of its own — Accounts carries the real address data
    -- instead. So this UNIONs two legs: real AccountPremises rows (address/postal inherited
    -- from the parent Account, since premises tracks none itself) plus a synthesized "primary
    -- site" per account that has no real premises row, built from that account's own billing
    -- address/geo. Every customer ends up with at least one site to check in against, matching
    -- what XMobile's visit flow assumes. The synthesized leg reuses the account's own id as
    -- XinfoId — deterministic and stable across pulls; Sites and Customers are independent
    -- id-spaces in XMobile so this does not collide with anything.
    -- CountryCode is always NULL: the source stores a free-text country name (via a lookup
    -- table), not an ISO-2 code, and there is no mapping available.
    ;WITH Sites AS (
        SELECT
            XinfoId         = p.ID,
            CustomerXinfoId = p.AccountID,
            Name            = p.Name,
            SiteCode        = CAST(NULL AS nvarchar(50)),
            SiteType        = pt.Name,
            IsPrimary       = CASE WHEN p.DefaultRecord = 1 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
            AddressLine1    = a.Billingaddress,
            AddressLine2    = CAST(NULL AS nvarchar(200)),
            Landmark        = CAST(NULL AS nvarchar(200)),
            City            = ci.Name,
            District        = CAST(NULL AS nvarchar(100)),
            State           = st.Name,
            PostalCode      = a.BillingaddressPostalcode,
            CountryCode     = CAST(NULL AS char(2)),
            Lat             = p.Latitude,
            Lon             = p.Longitude,
            IsActive        = CASE WHEN p.IsDeleted = 1 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
            ModifiedAt      = TODATETIMEOFFSET(p.ModifiedOn, '+05:30')
        FROM dbo.AccountPremises p
        INNER JOIN dbo.Accounts a ON a.ID = p.AccountID
        LEFT JOIN dbo.AccountPremisesTypes pt ON pt.ID = p.AccountPremisesTypeID
        LEFT JOIN dbo.Cities ci ON ci.ID = a.BillingaddressCity
        LEFT JOIN dbo.States st ON st.ID = a.BillingaddressState

        UNION ALL

        SELECT
            XinfoId         = a.ID,
            CustomerXinfoId = a.ID,
            Name            = a.Name,
            SiteCode        = CAST(NULL AS nvarchar(50)),
            SiteType        = CAST(NULL AS nvarchar(50)),
            IsPrimary       = CAST(1 AS bit),
            AddressLine1    = a.Billingaddress,
            AddressLine2    = CAST(NULL AS nvarchar(200)),
            Landmark        = CAST(NULL AS nvarchar(200)),
            City            = ci.Name,
            District        = CAST(NULL AS nvarchar(100)),
            State           = st.Name,
            PostalCode      = a.BillingaddressPostalcode,
            CountryCode     = CAST(NULL AS char(2)),
            Lat             = a.Latitude,
            Lon             = a.Longitude,
            IsActive        = CASE WHEN a.IsDeleted = 1 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
            ModifiedAt      = TODATETIMEOFFSET(a.ModifiedOn, '+05:30')
        FROM dbo.Accounts a
        LEFT JOIN dbo.Cities ci ON ci.ID = a.BillingaddressCity
        LEFT JOIN dbo.States st ON st.ID = a.BillingaddressState
        WHERE NOT EXISTS (SELECT 1 FROM dbo.AccountPremises p2 WHERE p2.AccountID = a.ID AND p2.IsDeleted = 0)
    )
    SELECT TOP (@PageSize) *
    FROM Sites
    WHERE (@ModifiedSince IS NULL OR ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR ModifiedAt > @AfterModifiedAt
            OR (ModifiedAt = @AfterModifiedAt AND XinfoId > @AfterId)
          )
    ORDER BY ModifiedAt, XinfoId;
END
GO

/* Contacts changed since a watermark.
   RESULT SET:
     XinfoId nvarchar(64), CustomerXinfoId nvarchar(64), SiteXinfoId nvarchar(64) null,
     FullName nvarchar(200), Designation nvarchar(100) null, Department nvarchar(100) null,
     Phone nvarchar(50) null, Email nvarchar(200) null, IsPrimary bit, IsActive bit,
     ModifiedAt datetimeoffset */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Contacts_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- dbo.AccountContactDetails has no primary-contact flag (checked: 6,605 accounts have
    -- contacts, some with hundreds) — IsPrimary is always false rather than guessing at a
    -- tiebreak rule. IsActive combines IsDeleted with IsLeft (a "this person left the company"
    -- flag XInfo tracks separately from soft-delete). ModifiedAt falls back to CreatedOn for
    -- the 149 rows (0.77%) with no ModifiedOn.
    SELECT TOP (@PageSize)
        XinfoId          = k.ID,
        CustomerXinfoId  = k.AccountId,
        SiteXinfoId      = CAST(NULL AS nvarchar(64)),
        FullName         = k.ContactPersonname,
        Designation      = k.Designation,
        Department       = k.Department,
        Phone            = k.ConatctNumber,
        Email            = k.ConatctEmailid,
        IsPrimary        = CAST(0 AS bit),
        IsActive         = CASE WHEN k.IsDeleted = 1 OR k.IsLeft = 1 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
        ModifiedAt       = TODATETIMEOFFSET(COALESCE(k.ModifiedOn, k.CreatedOn), '+05:30')
    FROM dbo.AccountContactDetails k
    WHERE k.AccountId IS NOT NULL
      AND (@ModifiedSince IS NULL OR COALESCE(k.ModifiedOn, k.CreatedOn) >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR TODATETIMEOFFSET(COALESCE(k.ModifiedOn, k.CreatedOn), '+05:30') > @AfterModifiedAt
            OR (TODATETIMEOFFSET(COALESCE(k.ModifiedOn, k.CreatedOn), '+05:30') = @AfterModifiedAt AND k.ID > @AfterId)
          )
    ORDER BY COALESCE(k.ModifiedOn, k.CreatedOn), k.ID;
END
GO

/* Which rep covers which customer. Drives what each device holds offline, so a removal
   must be visible: return the row with ValidTo set rather than dropping it.
   RESULT SET:
     CustomerXinfoId nvarchar(64), EmployeeCode nvarchar(50), Role nvarchar(20),
     ValidFrom datetimeoffset, ValidTo datetimeoffset null, ModifiedAt datetimeoffset

   Role is one of PRIMARY / SECONDARY / SUPPORT. Paging id is CustomerXinfoId|EmployeeCode. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Assignments_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- XInfo has no real assignment-history concept: no roles, no validity date ranges, only
    -- one AssignedUserID per account (same field xm.MobileGateway_Customers_GetChanged reads
    -- for OwnerEmployeeCode). Every account with a resolvable owner gets one synthesized
    -- Role='PRIMARY' row here; accounts with no owner get none. ValidFrom uses the account's
    -- own CreatedOn as the best available proxy for "since when".
    -- KNOWN GAP vs. the contract note above: because this is derived from current state, a
    -- reassignment away from a rep does not surface as a row with ValidTo set — the old row
    -- just stops being returned. XInfo has no data to detect or backfill that transition.
    SELECT TOP (@PageSize)
        CustomerXinfoId = a.ID,
        EmployeeCode    = u.Name,
        Role            = 'PRIMARY',
        ValidFrom       = TODATETIMEOFFSET(a.CreatedOn, '+05:30'),
        ValidTo         = CAST(NULL AS datetimeoffset),
        ModifiedAt      = TODATETIMEOFFSET(a.ModifiedOn, '+05:30')
    FROM dbo.Accounts a
    INNER JOIN XStudio_Configuration.dbo.XStudio_User_Mst_Tbl u ON u.ID = a.AssignedUserID
    WHERE (@ModifiedSince IS NULL OR a.ModifiedOn >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR a.ModifiedOn > @AfterModifiedAt
            OR (a.ModifiedOn = @AfterModifiedAt
                AND CONCAT(a.ID, '|', u.Name) > @AfterId)
          )
    ORDER BY a.ModifiedOn, CONCAT(a.ID, '|', u.Name);
END
GO

/* Sales reps and their reporting line. Matched to XMobile users by EmployeeCode, which must
   therefore be stable and unique.
   RESULT SET:
     EmployeeCode nvarchar(50), FullName nvarchar(200), Email nvarchar(200) null,
     Phone nvarchar(50) null, Grade nvarchar(20) null, Designation nvarchar(100) null,
     OrgUnitCode nvarchar(50) null, ManagerEmployeeCode nvarchar(50) null, IsActive bit,
     ModifiedAt datetimeoffset */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Users_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- EmployeeCode/identity lives in XStudio_Configuration (cross-database, same as
    -- OwnerEmployeeCode in Customers_GetChanged), not in this database — its Name column
    -- (a login username, e.g. "hemangini.patel") is EmployeeCode. This table has no
    -- Grade/Designation/OrgUnitCode of its own; those come from a *separate*, mostly-unlinked
    -- HR table (dbo.Employees) via an email match (CompanyEmailId or PersonalEmailid = EmailID)
    -- that only resolves for ~46% of users — Designation/Department/Grade come back NULL for
    -- the rest, which is a real coverage gap, not a query bug. Also note: this table holds
    -- every XStudio login, including the vendor's own internal staff, not only field sales
    -- reps — there is no flag to separate them, so all are returned; harmless for XMobile since
    -- it only needs to resolve whichever EmployeeCode values show up elsewhere (e.g. as
    -- OwnerEmployeeCode). FullName falls back through FirstName+LastName to the login name
    -- itself since the column is often blank; ModifiedAt falls back to CreatedOn (194 rows,
    -- 5.6%, have no ModifiedOn). ManagerEmployeeCode is populated for only 10 of 3,458 rows —
    -- almost nobody has a manager recorded here — but resolves correctly when present.
    SELECT TOP (@PageSize)
        EmployeeCode         = u.Name,
        FullName             = COALESCE(NULLIF(u.FullName,''), NULLIF(LTRIM(RTRIM(CONCAT(u.FirstName,' ',u.LastName))),''), u.Name),
        Email                = u.EmailID,
        Phone                = u.ContactNo,
        Grade                = bl.Name,
        Designation          = des.Name,
        OrgUnitCode          = dept.Name,
        ManagerEmployeeCode  = mgr.Name,
        IsActive             = CASE WHEN u.IsDeleted = 1 OR ISNULL(u.IsActive,0) = 0 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
        ModifiedAt           = TODATETIMEOFFSET(COALESCE(u.ModifiedOn, u.CreatedOn), '+05:30')
    FROM XStudio_Configuration.dbo.XStudio_User_Mst_Tbl u
    LEFT JOIN XStudio_Configuration.dbo.XStudio_User_Mst_Tbl mgr ON mgr.ID = u.ManagerID
    LEFT JOIN dbo.Employees e ON e.CompanyEmailId = u.EmailID OR e.PersonalEmailid = u.EmailID
    LEFT JOIN dbo.Designations des ON des.ID = e.DesignationId
    LEFT JOIN dbo.Departments dept ON dept.ID = e.DepartmentID
    LEFT JOIN dbo.BandLevels bl ON bl.ID = e.BandLevelID
    WHERE u.Name IS NOT NULL
      AND (@ModifiedSince IS NULL OR COALESCE(u.ModifiedOn, u.CreatedOn) >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR COALESCE(u.ModifiedOn, u.CreatedOn) > @AfterModifiedAt
            OR (COALESCE(u.ModifiedOn, u.CreatedOn) = @AfterModifiedAt AND u.Name > @AfterId)
          )
    ORDER BY COALESCE(u.ModifiedOn, u.CreatedOn), u.Name;
END
GO

/* Territory hierarchy.
   RESULT SET:
     Code nvarchar(50), Name nvarchar(200), UnitType nvarchar(20), ParentCode nvarchar(50) null,
     IsActive bit, ModifiedAt datetimeoffset
   UnitType is one of COMPANY / ZONE / REGION / AREA / TERRITORY. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_OrgUnits_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- Sourced from dbo.SalesRegion (44 rows) — a flat list of geographic sales territories,
    -- no parent hierarchy (no ParentID column exists) and no separate code, so Name doubles as
    -- Code like elsewhere in this schema. Deliberately does NOT include dbo.Departments (the
    -- HR org chart used for Users_GetChanged.OrgUnitCode) — that's a different, functional
    -- hierarchy that doesn't fit this procedure's geographic UnitType enum, so it stays a
    -- separate, unvalidated code rather than being force-fit in here.
    SELECT TOP (@PageSize)
        Code       = r.Name,
        Name       = r.Name,
        UnitType   = 'TERRITORY',
        ParentCode = CAST(NULL AS nvarchar(50)),
        IsActive   = CASE WHEN r.IsDeleted = 1 THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,
        ModifiedAt = TODATETIMEOFFSET(r.ModifiedOn, '+05:30')
    FROM dbo.SalesRegion r
    WHERE (@ModifiedSince IS NULL OR r.ModifiedOn >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR r.ModifiedOn > @AfterModifiedAt
            OR (r.ModifiedOn = @AfterModifiedAt AND r.Name > @AfterId)
          )
    ORDER BY r.ModifiedOn, r.Name;
END
GO

/* =====================================================================
   2. PULL — transactions
   ===================================================================== */

/* Orders and invoices, so a rep can discuss trends before walking in.
   Header level is enough; we do not need line items.
   RESULT SET:
     XinfoId nvarchar(64), CustomerXinfoId nvarchar(64), DocumentType nvarchar(20),
     DocumentNo nvarchar(50) null, DocumentDate datetimeoffset, Amount decimal(18,2),
     Currency char(3), Quantity decimal(18,3) null, Uom nvarchar(20) null,
     Status nvarchar(50) null, Summary nvarchar(400) null, ModifiedAt datetimeoffset

   DocumentType is one of ORDER / INVOICE / RETURN.
   @CustomerXinfoId narrows to one customer; NULL means all. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_SalesHistory_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501,
    @CustomerXinfoId  nvarchar(64)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Sourced from dbo.Invoices only (27,135 rows, direct AccountID link) — DocumentType is
    -- 'RETURN' when Status='Returned', else 'INVOICE'. ORDER is a known gap: the closest real
    -- data, dbo.CloseWonOrderForm, links to OpportunityID rather than AccountID, so surfacing
    -- it needs the Opportunity->Account join xm.MobileGateway_Opportunities_GetChanged
    -- establishes — revisit once that lands. No Currency column exists on Invoices (only a
    -- CurrencyRate to convert to INR), so Currency is hardcoded 'INR'; Uom has no source here
    -- either (it only exists on CloseWonOrderForm) and is always NULL. DocumentDate/Amount
    -- fall back to CreatedOn/0 for the ~2% of rows missing InvoiceDate/TotalAmount, since the
    -- contract has both as non-nullable.
    SELECT TOP (@PageSize)
        XinfoId          = i.ID,
        CustomerXinfoId  = i.AccountID,
        DocumentType     = CASE WHEN i.Status = 'Returned' THEN 'RETURN' ELSE 'INVOICE' END,
        DocumentNo       = i.InvoiceNo,
        DocumentDate     = TODATETIMEOFFSET(CAST(COALESCE(i.InvoiceDate, CAST(i.CreatedOn AS date)) AS datetime), '+05:30'),
        Amount           = COALESCE(i.TotalAmount, 0),
        Currency         = 'INR',
        Quantity         = i.Quantity,
        Uom              = CAST(NULL AS nvarchar(20)),
        Status           = i.Status,
        Summary          = i.InvoiceDescription,
        ModifiedAt       = TODATETIMEOFFSET(COALESCE(i.ModifiedOn, i.CreatedOn), '+05:30')
    FROM dbo.Invoices i
    WHERE i.AccountID IS NOT NULL
      AND (@ModifiedSince IS NULL OR COALESCE(i.ModifiedOn, i.CreatedOn) >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR COALESCE(i.ModifiedOn, i.CreatedOn) > @AfterModifiedAt
            OR (COALESCE(i.ModifiedOn, i.CreatedOn) = @AfterModifiedAt AND i.ID > @AfterId)
          )
      AND (@CustomerXinfoId IS NULL OR i.AccountID = @CustomerXinfoId)
    ORDER BY COALESCE(i.ModifiedOn, i.CreatedOn), i.ID;
END
GO

/* Opportunities as XInfo holds them. This is the one entity both sides edit, so please
   return XmobileId where the deal originated in the field — that is how the two records
   are matched without guessing on name.
   RESULT SET:
     XinfoId nvarchar(64), CustomerXinfoId nvarchar(64), SiteXinfoId nvarchar(64) null,
     ContactXinfoId nvarchar(64) null, Title nvarchar(200), Description nvarchar(max) null,
     StageCode nvarchar(50), EstimatedValue decimal(18,2) null, Currency char(3),
     ProbabilityPct int null, ExpectedCloseDate datetimeoffset null,
     OwnerEmployeeCode nvarchar(50) null, Source nvarchar(50) null, Competitor nvarchar(200) null,
     ClosedAt datetimeoffset null, CloseReasonCode nvarchar(50) null,
     ActualValue decimal(18,2) null, XmobileId uniqueidentifier null, ModifiedAt datetimeoffset */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Opportunities_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- Sourced from dbo.Opportunities (36,991 rows, ~190 columns — a full ERP-grade pipeline,
    -- far richer than this contract needs). Several fields have no clean source and are
    -- documented rather than guessed:
    --   * SiteXinfoId / ContactXinfoId: no link columns exist on this table at all.
    --   * StageCode uses o.Status (99.97% populated, clean values like "Proposal",
    --     "Negotiation", "CloseWonApproved") — NOT o.OppStage, which despite the name is
    --     99.1% empty. ProbabilityPct DOES come from OppStage (via a join to
    --     dbo.OpportunityCloseProbabilities' numeric Percentage column) since that's the only
    --     real numeric probability source — so it is NULL far more often than StageCode.
    --   * Currency resolves via dbo.Currencies for the 16% of rows with Currencyid set
    --     (defaults to 'INR' otherwise); the lookup itself has messy data (a deleted "rupee"
    --     row, test rows) so this is a best-effort truncation, not a clean ISO code.
    --   * Source and Competitor: no source column for either (LeadSourceID exists but is
    --     100% unpopulated) — always NULL.
    --   * XmobileId: XInfo's schema has NO column to store XMobile's own opportunity id, so
    --     xm.MobileGateway_Opportunity_Upsert tracks it in a new dbo.GatewayOpportunityLink
    --     table instead (also used there for the RepFieldsUpdatedAt staleness check) — read
    --     back here via a join. Only populated for opportunities that originated from an
    --     XMobile push; everything else (all 36,991 rows as of this pass) is NULL.
    SELECT TOP (@PageSize)
        XinfoId            = o.ID,
        CustomerXinfoId    = o.AccountID,
        SiteXinfoId        = CAST(NULL AS nvarchar(64)),
        ContactXinfoId     = CAST(NULL AS nvarchar(64)),
        Title              = o.Name,
        Description        = o.Description,
        StageCode          = o.Status,
        EstimatedValue     = o.Amount,
        Currency           = COALESCE(UPPER(LEFT(NULLIF(cur.Name,''),3)), 'INR'),
        ProbabilityPct     = CAST(prob.Percentage AS int),
        ExpectedCloseDate  = TODATETIMEOFFSET(CAST(o.ExpectedcloseDate AS datetime), '+05:30'),
        OwnerEmployeeCode  = u.Name,
        Source             = CAST(NULL AS nvarchar(50)),
        Competitor         = CAST(NULL AS nvarchar(200)),
        ClosedAt           = TODATETIMEOFFSET(CAST(COALESCE(o.CloseWonApprovedDate, o.CloseLostDate) AS datetime), '+05:30'),
        CloseReasonCode    = o.RequestForCloseLostReason,
        ActualValue        = o.OrderAmount,
        XmobileId          = link.XmobileOpportunityId,
        ModifiedAt         = TODATETIMEOFFSET(o.ModifiedOn, '+05:30')
    FROM dbo.Opportunities o
    LEFT JOIN dbo.Currencies cur ON cur.ID = o.Currencyid AND cur.IsDeleted = 0
    LEFT JOIN dbo.OpportunityCloseProbabilities prob ON prob.ID = o.OppStage
    LEFT JOIN XStudio_Configuration.dbo.XStudio_User_Mst_Tbl u ON u.ID = o.AssignedUserID
    LEFT JOIN dbo.GatewayOpportunityLink link ON link.XinfoId = o.ID
    WHERE o.Name IS NOT NULL AND o.AccountID IS NOT NULL
      AND (@ModifiedSince IS NULL OR o.ModifiedOn >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR o.ModifiedOn > @AfterModifiedAt
            OR (o.ModifiedOn = @AfterModifiedAt AND o.ID > @AfterId)
          )
    ORDER BY o.ModifiedOn, o.ID;
END
GO

/* Approval and settlement outcomes flowing back to the rep's phone.
   ExternalRef is the value XMobile sent as IdempotencyKey on the original expense push —
   that is the join key between the two systems.
   RESULT SET:
     ExternalRef nvarchar(200), XinfoId nvarchar(64) null, Status nvarchar(30),
     Remark nvarchar(400) null, SettledAmount decimal(18,2) null,
     SettledOn datetimeoffset null, ModifiedAt datetimeoffset

   Status is one of PENDING / APPROVED / REJECTED / PAID. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_ExpenseStatus_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.ExpenseApproval with your real table. ExternalRef must be the
    -- @IdempotencyKey XMobile sent on the original xm.MobileGateway_Expense_Push call — that is the join key.
    --
    -- RESEARCH NOTE (left as a skeleton deliberately, not implemented): dbo.VoucherClaim
    -- (73,302 rows) is XInfo's real expense/T&E table — Status, PaidDate, ApproveAmount,
    -- NetClaimAmount map cleanly onto Status/SettledOn/SettledAmount. But it has NO
    -- IdempotencyKey/ExternalRef-shaped column, and none of its existing rows originated from
    -- an XMobile push (XMobile has never gone live against this backup). This procedure's join
    -- key can only exist once xm.MobileGateway_Expense_Push actually writes an XMobile-sourced
    -- voucher somewhere and stamps the idempotency key onto it — so implement this together
    -- with that push procedure's design, once it's clear which column/table will hold it.
    SELECT TOP (@PageSize)
        ExternalRef   = x.ExternalRef,
        XinfoId       = CAST(x.Id AS nvarchar(64)),
        Status        = x.Status,
        Remark        = x.Remark,
        SettledAmount = x.SettledAmount,
        SettledOn     = x.SettledOn,
        ModifiedAt    = x.ModifiedAt
    FROM dbo.ExpenseApproval AS x
    WHERE (@ModifiedSince IS NULL OR x.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR x.ModifiedAt > @AfterModifiedAt
            OR (x.ModifiedAt = @AfterModifiedAt AND x.ExternalRef > @AfterId)
          )
    ORDER BY x.ModifiedAt, x.ExternalRef;
END
GO

/* =====================================================================
   3. PULL — reference data
   ===================================================================== */

/* Code lists, so the app's dropdowns match XInfo's vocabulary exactly. Getting these from
   XInfo rather than duplicating them is what stops an expense being rejected for a category
   that only existed on the phone.
   RESULT SET:
     Domain nvarchar(50), Code nvarchar(50), Name nvarchar(200), ParentCode nvarchar(50) null,
     SortOrder int, IsActive bit, AttributesJson nvarchar(max) null

   Domains we need: EXPENSE_CATEGORY, VISIT_TYPE, VISIT_OUTCOME, OPPORTUNITY_STAGE,
   SKIP_REASON, CLOSE_REASON.
   AttributesJson carries per-domain extras, e.g. for OPPORTUNITY_STAGE:
     {"probabilityPct":75,"isWon":false,"isLost":false,"requiresReason":false}
   and for EXPENSE_CATEGORY:
     {"requiresReceipt":true,"receiptThreshold":300,"requiresRoute":false,"dailyCap":800} */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Reference_GetItems
    @Domain nvarchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Real data exists for only one of the six domains — OPPORTUNITY_STAGE, sourced from the
    -- distinct values of dbo.Opportunities.Status (the field
    -- xm.MobileGateway_Opportunities_GetChanged actually uses for StageCode; deliberately NOT
    -- dbo.OpportunityCloseProbabilities, which despite being a proper lookup table with a
    -- numeric Percentage column, is keyed off the 99.1%-empty OppStage column and uses a
    -- different vocabulary — using it here would produce a reference list that doesn't match
    -- what StageCode actually contains). The other five domains (EXPENSE_CATEGORY, VISIT_TYPE,
    -- VISIT_OUTCOME, SKIP_REASON, CLOSE_REASON) have no lookup table and no free-text column
    -- worth enumerating — they return nothing here rather than a fabricated list; per this
    -- procedure's own contract note, XMobile maintains those locally instead.
    SELECT
        Domain         = 'OPPORTUNITY_STAGE',
        Code           = s.Status,
        Name           = s.Status,
        ParentCode     = CAST(NULL AS nvarchar(50)),
        SortOrder      = CAST(ROW_NUMBER() OVER (ORDER BY s.Status) AS int),
        IsActive       = CAST(1 AS bit),
        AttributesJson = CAST(NULL AS nvarchar(max))
    FROM (SELECT DISTINCT Status FROM dbo.Opportunities WHERE Status IS NOT NULL) s
    WHERE @Domain IS NULL OR @Domain = 'OPPORTUNITY_STAGE';
END
GO

/* Mileage and per-diem rates in force, so the app can show an indicative amount offline.
   XInfo still recomputes and decides what is actually paid; this is only so the rep is not
   guessing.
   RESULT SET:
     RateType nvarchar(30), Grade nvarchar(20) null, CityTier nvarchar(20) null,
     TravelMode nvarchar(20) null, Amount decimal(18,2), Currency char(3),
     EffectiveFrom datetimeoffset, EffectiveTo datetimeoffset null

   RateType is one of MILEAGE_PER_KM / PER_DIEM_FULL / PER_DIEM_HALF / PER_DIEM_TRAVEL /
   LODGING_CAP.
   If XInfo does not hold these, tell us and we will maintain them on our side instead. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Rates_GetCurrent
    @AsOf datetimeoffset
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.MileageRate with your real rate table, if you hold these at
    -- all — if not, tell us and we will maintain them on our side instead (see README).
    --
    -- RESEARCH NOTE (left as a skeleton deliberately): searched for mileage/per-diem/travel
    -- rate tables across this database and found none. The only rate-shaped tables that exist
    -- (EAC_EngineeringMandayRate, YearWiseBandLevelRates) are engineering billing rates, not
    -- travel reimbursement — a different concept entirely. This is exactly the case this
    -- procedure's own comment above anticipates: XInfo does not hold these, so XMobile should
    -- maintain mileage/per-diem rates locally rather than pulling them from here.
    SELECT
        RateType      = r.RateType,
        Grade         = r.Grade,
        CityTier      = r.CityTier,
        TravelMode    = r.TravelMode,
        Amount        = r.Amount,
        Currency      = r.Currency,
        EffectiveFrom = r.EffectiveFrom,
        EffectiveTo   = r.EffectiveTo
    FROM dbo.MileageRate AS r
    WHERE r.EffectiveFrom <= @AsOf AND (r.EffectiveTo IS NULL OR r.EffectiveTo > @AsOf);
END
GO

/* =====================================================================
   4. PUSH — records created in the field
   Every one returns: Accepted bit, XinfoId nvarchar(64) null, WasDuplicate bit,
                      Message nvarchar(400) null
   ===================================================================== */

/* A prospect a rep captured while standing in front of it.
   It is NOT a customer yet — hold it wherever XInfo keeps unapproved accounts. XMobile
   keeps its own id unchanged when you approve it, so please return your id and we will
   store the pairing.

   The rep is already visiting this prospect, so a rejection needs to reach us: expose it
   through xm.MobileGateway_Customers_GetChanged with IsActive = 0, or tell us where else to look. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Customer_Propose
    @MessageId          uniqueidentifier,
    @IdempotencyKey     nvarchar(200),
    @OccurredAt         datetimeoffset,
    @EmployeeCode       nvarchar(50),
    @XmobileCustomerId  uniqueidentifier,
    @Name               nvarchar(200),
    @AccountType        nvarchar(50)  = NULL,
    @Phone              nvarchar(50)  = NULL,
    @Email              nvarchar(200) = NULL,
    @GstNumber          nvarchar(20)  = NULL,
    @Note               nvarchar(max) = NULL,
    @SiteXmobileId      uniqueidentifier,
    @SiteName           nvarchar(200),
    @AddressLine1       nvarchar(200) = NULL,
    @City               nvarchar(100) = NULL,
    @State              nvarchar(100) = NULL,
    @PostalCode         nvarchar(20)  = NULL,
    @Lat                float         = NULL,
    @Lon                float         = NULL,
    @ContactXmobileId   uniqueidentifier = NULL,
    @ContactName        nvarchar(200) = NULL,
    @ContactDesignation nvarchar(100) = NULL,
    @ContactPhone       nvarchar(50)  = NULL,
    @ContactEmail       nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Idempotency uses a new shared table, dbo.GatewayIdempotencyLedger (IdempotencyKey PK,
    -- Entity, XinfoId, EmployeeCode, Amount, CreatedAt) — no XInfo table has a column to hold
    -- an external key, so every push procedure in this file checks/inserts into this one
    -- ledger rather than duplicating that gap nine times. xm.MobileGateway_Reconciliation_GetSummary
    -- reads the same table. @Email (account-level) is not persisted — dbo.Accounts has no email
    -- column, the same gap Customers_GetChanged.Email hits on the pull side; if @ContactName is
    -- given, @ContactEmail lands on the new contact instead. @City/@State are resolved against
    -- dbo.Cities/dbo.States by exact name match (both are GUID lookups on Accounts, not free
    -- text) and left unset if no match is found rather than guessing. Status is left NULL
    -- (unapproved) — real data only ever shows Status='Approved' or unset, with no observed
    -- "pending" value, so NULL is the closest fit. AccountPremisesTypeID is NOT NULL on
    -- dbo.AccountPremises with no natural default from the push payload, so a newly-proposed
    -- site defaults to the 'Head Office' type since it's the prospect's first recorded location.
    --
    -- NOTE FOR PRODUCTION: dbo.Accounts/AccountPremises/AccountContactDetails each carry
    -- XStudio_TRG_* triggers (audit logging, cross-database sync flags, approval-workflow
    -- mail/SMS notifications) that this dev environment can't fully exercise — one trigger
    -- chain depends on a SugarCRM_Data database not included in this restore. Disabled here for
    -- testing only; this is pre-existing platform behavior the procedure below does not need to
    -- replicate, but it WILL fire in production and should stay enabled there.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = XinfoId FROM dbo.GatewayIdempotencyLedger WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    DECLARE @NewAccountId nvarchar(64) = CAST(NEWID() AS nvarchar(64));
    DECLARE @CityId nvarchar(64) = (SELECT TOP 1 ID FROM dbo.Cities WHERE Name = @City AND IsDeleted = 0);
    DECLARE @StateId nvarchar(64) = (SELECT TOP 1 ID FROM dbo.States WHERE Name = @State AND IsDeleted = 0);
    DECLARE @DefaultPremisesTypeId nvarchar(64) = '653841DE-44E4-4989-9429-73FE54A81869'; -- 'Head Office'

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.Accounts (ID, Name, AccountType, Phone, GSTRegistrationnumber,
            Billingaddress, BillingaddressCity, BillingaddressState, BillingaddressPostalcode,
            Latitude, Longitude, Status, IsDeleted, Source, CreatedOn, ModifiedOn)
        VALUES (@NewAccountId, @Name, COALESCE(@AccountType, 'Customer'), @Phone, @GstNumber,
            @AddressLine1, @CityId, @StateId, @PostalCode,
            @Lat, @Lon, NULL, 0, 'XMobile', @OccurredAt, @OccurredAt);

        INSERT INTO dbo.AccountPremises (ID, Name, AccountID, AccountPremisesTypeID, Latitude,
            Longitude, DefaultRecord, IsDeleted, Source, CreatedOn, ModifiedOn)
        VALUES (CAST(NEWID() AS nvarchar(64)), @SiteName, @NewAccountId, @DefaultPremisesTypeId,
            @Lat, @Lon, 1, 0, 'XMobile', @OccurredAt, @OccurredAt);

        IF @ContactName IS NOT NULL
        BEGIN
            INSERT INTO dbo.AccountContactDetails (ID, ContactPersonname, Designation, ConatctNumber,
                ConatctEmailid, AccountId, IsLeft, IsDeleted, Source, CreatedOn, ModifiedOn)
            VALUES (CAST(NEWID() AS nvarchar(64)), @ContactName, @ContactDesignation, @ContactPhone,
                @ContactEmail, @NewAccountId, 0, 0, 'XMobile', @OccurredAt, @OccurredAt);
        END

        INSERT INTO dbo.GatewayIdempotencyLedger (IdempotencyKey, Entity, XinfoId, EmployeeCode, CreatedAt)
        VALUES (@IdempotencyKey, 'customer', @NewAccountId, @EmployeeCode, @OccurredAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewAccountId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A new site on an existing customer — a second warehouse, a moved shop. No approval gate:
   these change constantly and gating them means reps stop recording them. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Site_Add
    @MessageId       uniqueidentifier,
    @IdempotencyKey  nvarchar(200),
    @OccurredAt      datetimeoffset,
    @EmployeeCode    nvarchar(50),
    @CustomerXinfoId nvarchar(64),
    @XmobileSiteId   uniqueidentifier,
    @Name            nvarchar(200),
    @AddressLine1    nvarchar(200) = NULL,
    @City            nvarchar(100) = NULL,
    @State           nvarchar(100) = NULL,
    @PostalCode      nvarchar(20)  = NULL,
    @Lat             float         = NULL,
    @Lon             float         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Same idempotency pattern as xm.MobileGateway_Customer_Propose (see its comment for the
    -- shared dbo.GatewayIdempotencyLedger design). @AddressLine1/@City/@State/@PostalCode are
    -- accepted (required by the shared push contract shape) but NOT persisted —
    -- dbo.AccountPremises has no address columns of its own (see
    -- xm.MobileGateway_Sites_GetChanged's comment: address always comes from the parent
    -- Account, which this procedure must not overwrite since a second site's address may
    -- differ from the account's own). AccountPremisesTypeID defaults to 'Head Office' as in
    -- Customer_Propose — this procedure's payload has no @SiteType to resolve a real type from.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = XinfoId FROM dbo.GatewayIdempotencyLedger WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Accounts WHERE ID = @CustomerXinfoId)
    BEGIN
        THROW 50004, 'CustomerXinfoId does not exist', 1;
    END

    DECLARE @NewSiteId nvarchar(64) = CAST(NEWID() AS nvarchar(64));
    DECLARE @DefaultPremisesTypeId nvarchar(64) = '653841DE-44E4-4989-9429-73FE54A81869'; -- 'Head Office'

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.AccountPremises (ID, Name, AccountID, AccountPremisesTypeID, Latitude,
            Longitude, DefaultRecord, IsDeleted, Source, CreatedOn, ModifiedOn)
        VALUES (@NewSiteId, @Name, @CustomerXinfoId, @DefaultPremisesTypeId, @Lat, @Lon,
            0, 0, 'XMobile', @OccurredAt, @OccurredAt);

        INSERT INTO dbo.GatewayIdempotencyLedger (IdempotencyKey, Entity, XinfoId, EmployeeCode, CreatedAt)
        VALUES (@IdempotencyKey, 'site', @NewSiteId, @EmployeeCode, @OccurredAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewSiteId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A new contact on an existing customer. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Contact_Add
    @MessageId        uniqueidentifier,
    @IdempotencyKey   nvarchar(200),
    @OccurredAt       datetimeoffset,
    @EmployeeCode     nvarchar(50),
    @CustomerXinfoId  nvarchar(64),
    @XmobileContactId uniqueidentifier,
    @FullName         nvarchar(200),
    @Designation      nvarchar(100) = NULL,
    @Phone            nvarchar(50)  = NULL,
    @Email            nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Same idempotency pattern as xm.MobileGateway_Customer_Propose (see its comment for the
    -- shared dbo.GatewayIdempotencyLedger design). Clean 1:1 mapping onto
    -- dbo.AccountContactDetails — same table/columns Contacts_GetChanged reads on the pull side.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = XinfoId FROM dbo.GatewayIdempotencyLedger WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Accounts WHERE ID = @CustomerXinfoId)
    BEGIN
        THROW 50004, 'CustomerXinfoId does not exist', 1;
    END

    DECLARE @NewContactId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.AccountContactDetails (ID, ContactPersonname, Designation, ConatctNumber,
            ConatctEmailid, AccountId, IsLeft, IsDeleted, Source, CreatedOn, ModifiedOn)
        VALUES (@NewContactId, @FullName, @Designation, @Phone, @Email, @CustomerXinfoId,
            0, 0, 'XMobile', @OccurredAt, @OccurredAt);

        INSERT INTO dbo.GatewayIdempotencyLedger (IdempotencyKey, Entity, XinfoId, EmployeeCode, CreatedAt)
        VALUES (@IdempotencyKey, 'contact', @NewContactId, @EmployeeCode, @OccurredAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewContactId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* Coordinates a rep captured standing at the site.
   Worth taking seriously: an address geocoded to a street centroid can be hundreds of
   metres out, and this one was measured on the doorstep. If XInfo has nowhere to keep
   Lat/Lon, say so — we will hold it on our side and skip this call. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Site_CaptureGeo
    @MessageId      uniqueidentifier,
    @IdempotencyKey nvarchar(200),
    @OccurredAt     datetimeoffset,
    @EmployeeCode   nvarchar(50),
    @SiteXinfoId    nvarchar(64) = NULL,
    @XmobileSiteId  uniqueidentifier,
    @Lat            float,
    @Lon            float,
    @AccuracyM      float,
    @CapturedAt     datetimeoffset
AS
BEGIN
    SET NOCOUNT ON;
    -- Same idempotency pattern as xm.MobileGateway_Customer_Propose. @SiteXinfoId can point at
    -- either a real dbo.AccountPremises row OR a synthesized site (whose XinfoId is the
    -- account's own id — see xm.MobileGateway_Sites_GetChanged's hybrid design), so this
    -- updates whichever one actually matches rather than assuming AccountPremises.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = XinfoId FROM dbo.GatewayIdempotencyLedger WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    IF @SiteXinfoId IS NULL
    BEGIN
        THROW 50001, 'SiteXinfoId is required', 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM dbo.AccountPremises WHERE ID = @SiteXinfoId)
        BEGIN
            UPDATE dbo.AccountPremises
            SET Latitude = @Lat, Longitude = @Lon, ModifiedOn = @OccurredAt
            WHERE ID = @SiteXinfoId;
        END
        ELSE IF EXISTS (SELECT 1 FROM dbo.Accounts WHERE ID = @SiteXinfoId)
        BEGIN
            UPDATE dbo.Accounts
            SET Latitude = @Lat, Longitude = @Lon, ModifiedOn = @OccurredAt
            WHERE ID = @SiteXinfoId;
        END
        ELSE
        BEGIN
            THROW 50004, 'SiteXinfoId does not exist', 1;
        END

        INSERT INTO dbo.GatewayIdempotencyLedger (IdempotencyKey, Entity, XinfoId, EmployeeCode, CreatedAt)
        VALUES (@IdempotencyKey, 'site_geo', @SiteXinfoId, @EmployeeCode, @OccurredAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Accepted = CAST(1 AS bit), XinfoId = @SiteXinfoId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* =====================================================================
   5. PUSH — field activity
   ===================================================================== */

/* Create or update an opportunity from the field.
   Only rep-owned fields are sent: stage, value, expected close date, probability,
   competitor, close reason. Ownership, customer and site linkage stay yours.

   @RepFieldsUpdatedAt is an ordering token. If it is OLDER than what you already hold,
   please reject with THROW 50002 rather than applying it — that is a rep's offline edit
   arriving after someone changed the deal in XInfo, and yours should win. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Opportunity_Upsert
    @MessageId              uniqueidentifier,
    @IdempotencyKey         nvarchar(200),
    @OccurredAt             datetimeoffset,
    @EmployeeCode           nvarchar(50),
    @XmobileOpportunityId   uniqueidentifier,
    @XinfoId                nvarchar(64)  = NULL,
    @CustomerXinfoId        nvarchar(64),
    @Title                  nvarchar(200),
    @Description            nvarchar(max) = NULL,
    @StageCode              nvarchar(50),
    @EstimatedValue         decimal(18,2) = NULL,
    @ExpectedCloseDate      datetimeoffset = NULL,
    @ProbabilityPct         int           = NULL,
    @Competitor             nvarchar(200) = NULL,
    @CloseReasonCode        nvarchar(50)  = NULL,
    @ActualValue            decimal(18,2) = NULL,
    @RepFieldsUpdatedAt     datetimeoffset,
    @VisitId                uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Same idempotency pattern as xm.MobileGateway_Customer_Propose. dbo.Opportunities has
    -- neither a RepFieldsUpdatedAt column (needed for the staleness-rejection rule below) nor
    -- anywhere to store @XmobileOpportunityId (the gap flagged in
    -- xm.MobileGateway_Opportunities_GetChanged) — both are tracked in a new
    -- dbo.GatewayOpportunityLink table instead, which Opportunities_GetChanged now also reads
    -- to populate XmobileId. @ProbabilityPct and @Competitor are accepted but not persisted:
    -- Opportunities has no Competitor column at all, and the only probability-shaped column
    -- (OppStage) is a GUID pointing at a fixed stage+probability lookup row, not a freely
    -- settable percentage — the pull side already documents this same asymmetry.
    DECLARE @ExistingLedgerId nvarchar(64);
    SELECT @ExistingLedgerId = XinfoId FROM dbo.GatewayIdempotencyLedger WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingLedgerId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingLedgerId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    IF @XinfoId IS NOT NULL AND EXISTS (
        SELECT 1 FROM dbo.GatewayOpportunityLink l
        WHERE l.XinfoId = @XinfoId AND l.RepFieldsUpdatedAt > @RepFieldsUpdatedAt
    )
    BEGIN
        THROW 50002, 'A newer update already exists in XInfo for this opportunity', 1;
    END

    IF @XinfoId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Opportunities WHERE ID = @XinfoId)
    BEGIN
        THROW 50004, 'XinfoId does not exist', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Accounts WHERE ID = @CustomerXinfoId)
    BEGIN
        THROW 50004, 'CustomerXinfoId does not exist', 1;
    END

    DECLARE @NewOppId nvarchar(64) = COALESCE(@XinfoId, CAST(NEWID() AS nvarchar(64)));
    DECLARE @AssignedUserId nvarchar(64) = (SELECT TOP 1 ID FROM XStudio_Configuration.dbo.XStudio_User_Mst_Tbl WHERE Name = @EmployeeCode);

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @XinfoId IS NULL
        BEGIN
            INSERT INTO dbo.Opportunities (ID, Name, Description, AccountID, Status, Amount,
                ExpectedcloseDate, OrderAmount, RequestForCloseLostReason, AssignedUserID,
                IsDeleted, Source, CreatedOn, ModifiedOn)
            VALUES (@NewOppId, @Title, @Description, @CustomerXinfoId, @StageCode, @EstimatedValue,
                CAST(@ExpectedCloseDate AS date), @ActualValue, @CloseReasonCode, @AssignedUserId,
                0, 'XMobile', @OccurredAt, @OccurredAt);
        END
        ELSE
        BEGIN
            UPDATE dbo.Opportunities
            SET Name = @Title, Description = @Description, Status = @StageCode,
                Amount = @EstimatedValue, ExpectedcloseDate = CAST(@ExpectedCloseDate AS date),
                OrderAmount = @ActualValue, RequestForCloseLostReason = @CloseReasonCode,
                ModifiedOn = @OccurredAt
            WHERE ID = @NewOppId;
        END

        MERGE dbo.GatewayOpportunityLink AS target
        USING (SELECT @NewOppId AS XinfoId) AS src ON target.XinfoId = src.XinfoId
        WHEN MATCHED THEN UPDATE SET RepFieldsUpdatedAt = @RepFieldsUpdatedAt, ModifiedAt = @OccurredAt
        WHEN NOT MATCHED THEN INSERT (XinfoId, XmobileOpportunityId, RepFieldsUpdatedAt, CreatedAt, ModifiedAt)
            VALUES (@NewOppId, @XmobileOpportunityId, @RepFieldsUpdatedAt, @OccurredAt, @OccurredAt);

        INSERT INTO dbo.GatewayIdempotencyLedger (IdempotencyKey, Entity, XinfoId, EmployeeCode, CreatedAt)
        VALUES (@IdempotencyKey, 'opportunity', @NewOppId, @EmployeeCode, @OccurredAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewOppId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A completed visit with its report.
   @DynamicAnswersJson holds the answers to an admin-defined questionnaire whose shape
   changes without an app release — please store it as-is (nvarchar(max)); do not try to
   map it to columns.
   @LinkedOpportunityIds is comma-separated: which deals this call moved. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Visit_Push
    @MessageId             uniqueidentifier,
    @IdempotencyKey        nvarchar(200),
    @OccurredAt            datetimeoffset,
    @EmployeeCode          nvarchar(50),
    @VisitId               uniqueidentifier,
    @CustomerXinfoId       nvarchar(64),
    @SiteXinfoId           nvarchar(64)  = NULL,
    @ContactXinfoId        nvarchar(64)  = NULL,
    @VisitTypeCode         nvarchar(50),
    @CheckInAt             datetimeoffset,
    @CheckOutAt            datetimeoffset = NULL,
    @DurationMin           int           = NULL,
    @CheckInLat            float         = NULL,
    @CheckInLon            float         = NULL,
    @CheckInDistanceM      int           = NULL,
    @IsOutOfGeofence       bit,
    @OutOfFenceReasonCode  nvarchar(50)  = NULL,
    @IsUnplanned           bit,
    @OutcomeCode           nvarchar(50)  = NULL,
    @Summary               nvarchar(max) = NULL,
    @NextAction            nvarchar(max) = NULL,
    @FollowUpDate          datetimeoffset = NULL,
    @OrderIntent           bit,
    @OrderValueEst         decimal(18,2) = NULL,
    @CompetitorSeen        bit,
    @CompetitorNotes       nvarchar(max) = NULL,
    @DynamicAnswersJson    nvarchar(max) = NULL,
    @LinkedOpportunityIds  nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- Same idempotency pattern as xm.MobileGateway_Customer_Propose. XInfo's closest real
    -- table, dbo.EmployeeVisitReport (171,745 rows), has a genuine visit-report shape
    -- (EmployeeID, AccountID, ContactID, OpportunityID, MeetingPurpose, Status) but none of
    -- this contract's richer fields — no check-in/out times, geofence, order-intent,
    -- competitor-sighting, or dynamic questionnaire concept. Core fields land in
    -- EmployeeVisitReport (so XInfo's own reporting sees the visit); everything else goes into
    -- a new dbo.GatewayVisitDetail table, 1:1 keyed on the same XinfoId, exactly as
    -- @DynamicAnswersJson's own instruction says (store as-is, don't try to map it to columns).
    -- @LinkedOpportunityIds is comma-separated; only its first id links to
    -- EmployeeVisitReport.OpportunityID (a single column), but the full list is preserved as-is
    -- in GatewayVisitDetail.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = XinfoId FROM dbo.GatewayIdempotencyLedger WHERE IdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Accounts WHERE ID = @CustomerXinfoId)
    BEGIN
        THROW 50004, 'CustomerXinfoId does not exist', 1;
    END

    DECLARE @NewVisitId nvarchar(64) = CAST(NEWID() AS nvarchar(64));
    DECLARE @EmployeeId nvarchar(64) = (SELECT TOP 1 ID FROM XStudio_Configuration.dbo.XStudio_User_Mst_Tbl WHERE Name = @EmployeeCode);
    DECLARE @FirstOpportunityId nvarchar(64) = NULLIF(LTRIM(RTRIM(
        LEFT(@LinkedOpportunityIds + ',', CHARINDEX(',', @LinkedOpportunityIds + ',') - 1)
    )), '');

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.EmployeeVisitReport (ID, VisitID, EmployeeID, ContactID, AccountID,
            MeetingPurpose, Status, Description, OpportunityID, Submittedon, submittedby,
            IsDeleted, Source, CreatedOn, ModifiedOn)
        VALUES (@NewVisitId, CAST(@VisitId AS nvarchar(64)), @EmployeeId, @ContactXinfoId, @CustomerXinfoId,
            @VisitTypeCode, @OutcomeCode, @Summary, @FirstOpportunityId,
            COALESCE(@CheckOutAt, @OccurredAt), @EmployeeCode,
            0, 'XMobile', @OccurredAt, @OccurredAt);

        INSERT INTO dbo.GatewayVisitDetail (VisitXinfoId, XmobileVisitId, SiteXinfoId, VisitTypeCode,
            CheckInAt, CheckOutAt, DurationMin, CheckInLat, CheckInLon, CheckInDistanceM,
            IsOutOfGeofence, OutOfFenceReasonCode, IsUnplanned, NextAction, FollowUpDate,
            OrderIntent, OrderValueEst, CompetitorSeen, CompetitorNotes, DynamicAnswersJson,
            LinkedOpportunityIds, CreatedAt)
        VALUES (@NewVisitId, @VisitId, @SiteXinfoId, @VisitTypeCode,
            @CheckInAt, @CheckOutAt, @DurationMin, @CheckInLat, @CheckInLon, @CheckInDistanceM,
            @IsOutOfGeofence, @OutOfFenceReasonCode, @IsUnplanned, @NextAction, @FollowUpDate,
            @OrderIntent, @OrderValueEst, @CompetitorSeen, @CompetitorNotes, @DynamicAnswersJson,
            @LinkedOpportunityIds, @OccurredAt);

        INSERT INTO dbo.GatewayIdempotencyLedger (IdempotencyKey, Entity, XinfoId, EmployeeCode, CreatedAt)
        VALUES (@IdempotencyKey, 'visit', @NewVisitId, @EmployeeCode, @OccurredAt);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewVisitId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A completed tour: the multi-day trip a rep went on, with its distance and cost.
   @DistanceByModeJson looks like {"RAIL":618000,"CAR":38000} — kilometres by rail must not
   be reimbursed as kilometres by car. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Tour_Push
    @MessageId           uniqueidentifier,
    @IdempotencyKey      nvarchar(200),
    @OccurredAt          datetimeoffset,
    @EmployeeCode        nvarchar(50),
    @TourId              uniqueidentifier,
    @Title               nvarchar(200),
    @PlannedStartDate    datetimeoffset,
    @PlannedEndDate      datetimeoffset,
    @ActualStartAt       datetimeoffset = NULL,
    @ActualEndAt         datetimeoffset = NULL,
    @DestinationCity     nvarchar(100)  = NULL,
    @VisitCount          int,
    @TotalDistanceM      bigint,
    @DistanceByModeJson  nvarchar(max)  = NULL,
    @TotalExpenseAmount  decimal(18,2)
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.MobileGateway_Customer_Propose above. Replace dbo.Tour
    -- with your real table. @DistanceByModeJson looks like {"RAIL":618000,"CAR":38000} — store
    -- it as-is if you don't need to query by travel mode server-side.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(t.Id AS nvarchar(64))
    FROM dbo.Tour AS t
    WHERE t.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert the completed tour into your real table.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* An expense a rep captured. THE MOST IMPORTANT PROCEDURE IN THIS FILE.
   XInfo owns approval and settlement, so an expense that fails to land here is money the
   rep does not get back. Two consequences:
     * idempotency on @IdempotencyKey must be watertight — we retry aggressively;
     * xm.MobileGateway_Reconciliation_GetSummary must be able to prove what you hold, so our nightly job
       can spot anything that never arrived.

   @SuggestedAmount is what our synced rate tables computed. It is advisory — please apply
   your own policy and ignore it if it disagrees. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Expense_Push
    @MessageId       uniqueidentifier,
    @IdempotencyKey  nvarchar(200),
    @OccurredAt      datetimeoffset,
    @EmployeeCode    nvarchar(50),
    @ExpenseId       uniqueidentifier,
    @TourId          uniqueidentifier = NULL,
    @VisitId         uniqueidentifier = NULL,
    @CategoryCode    nvarchar(50),
    @ExpenseDate     datetimeoffset,
    @Amount          decimal(18,2),
    @Currency        char(3),
    @PaymentMode     nvarchar(30)  = NULL,
    @MerchantName    nvarchar(200) = NULL,
    @PaymentRef      nvarchar(100) = NULL,
    @Description     nvarchar(max) = NULL,
    @TravelMode      nvarchar(20)  = NULL,
    @FromPlace       nvarchar(100) = NULL,
    @ToPlace         nvarchar(100) = NULL,
    @DistanceKm      decimal(10,2) = NULL,
    @DistanceSource  nvarchar(20)  = NULL,
    @SuggestedAmount decimal(18,2) = NULL,
    @ReceiptCount    int
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] THE MOST IMPORTANT PROCEDURE IN THIS FILE (see the remark above) — the
    -- idempotency check below MUST be watertight before this goes live. Same pattern as
    -- xm.MobileGateway_Customer_Propose above, replace dbo.Expense with your real table. @SuggestedAmount is
    -- advisory only — apply your own approval policy, do not just accept it.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(e.Id AS nvarchar(64))
    FROM dbo.Expense AS e
    WHERE e.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert the expense into your real table, in PENDING/whatever your initial approval
    -- state is. xm.MobileGateway_ExpenseReceipt_Push calls follow immediately after for each attached receipt.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A receipt for an expense already pushed. Called once per file, after Expense_Push.
   Either @Url (we host it and you fetch it) or @ContentBase64 (you store the bytes) will be
   supplied, never both. Tell us which you want — URL keeps the payloads small, but needs
   XInfo to be able to reach our object store. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_ExpenseReceipt_Push
    @ExpenseId       uniqueidentifier,
    @XinfoExpenseId  nvarchar(64)  = NULL,
    @AttachmentId    uniqueidentifier,
    @FileName        nvarchar(200),
    @MimeType        nvarchar(100),
    @SizeBytes       bigint,
    @Url             nvarchar(1000) = NULL,
    @ContentBase64   nvarchar(max)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.ExpenseReceipt with your real table. Unlike the other push
    -- procedures, the gateway does not read a result row from this one (it "rides" the parent
    -- xm.MobileGateway_Expense_Push call — see SqlPushRepository.PushExpenseAsync) and it has no
    -- @IdempotencyKey of its own; de-duplicate on @AttachmentId if this can be called twice.
    -- Exactly one of @Url / @ContentBase64 will be supplied, never both.
    IF NOT EXISTS (SELECT 1 FROM dbo.ExpenseReceipt WHERE AttachmentId = @AttachmentId)
    BEGIN
        -- TODO: INSERT INTO dbo.ExpenseReceipt (ExpenseId, XinfoExpenseId, AttachmentId,
        --   FileName, MimeType, SizeBytes, Url, ContentBase64) VALUES (...);
        SELECT 1; -- placeholder no-op so this stub compiles and runs without erroring
    END
END
GO

/* One row per rep per day: where they went, how far, how long at customers.
   Derived from tracking and pushed nightly. @AttendanceStatus is informational — XMobile is
   explicitly NOT the attendance system of record, so please do not pay anyone from it. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_JourneySummary_Push
    @MessageId            uniqueidentifier,
    @IdempotencyKey       nvarchar(200),
    @OccurredAt           datetimeoffset,
    @EmployeeCode         nvarchar(50),
    @LocalDate            datetimeoffset,
    @TourId               uniqueidentifier = NULL,
    @FirstDepartureAt     datetimeoffset = NULL,
    @LastArrivalAt        datetimeoffset = NULL,
    @TotalDistanceM       bigint,
    @EstimatedDistanceM   bigint,
    @DistanceByModeJson   nvarchar(max) = NULL,
    @TravelTimeS          int,
    @CustomerTimeS        int,
    @VisitsPlanned        int,
    @VisitsCompleted      int,
    @AnomalyCount         int,
    @TrackingCoveragePct  int = NULL,
    @AttendanceStatus     nvarchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.MobileGateway_Customer_Propose above. Replace
    -- dbo.JourneySummary with your real table. @AttendanceStatus is informational only — XMobile
    -- is explicitly not the attendance system of record, please do not pay anyone from it.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(j.Id AS nvarchar(64))
    FROM dbo.JourneySummary AS j
    WHERE j.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert or upsert (@EmployeeCode, @LocalDate) into your real table.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* =====================================================================
   6. Reconciliation and health
   ===================================================================== */

/* What XInfo believes it holds for a period, so our nightly job can compare and re-push
   anything missing. This is the safety net that makes capture-only expenses safe.

   RESULT SET 1: RecordCount int, TotalAmount decimal(18,2) null
   RESULT SET 2: a single nvarchar(200) column of ExternalRefs (the IdempotencyKeys held)

   @Entity is one of: expense, visit, tour, opportunity, journey_summary. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Reconciliation_GetSummary
    @Entity       nvarchar(30),
    @FromDate     datetimeoffset,
    @ToDate       datetimeoffset,
    @EmployeeCode nvarchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.GatewayIdempotencyLedger with wherever you actually store
    -- each entity's idempotency keys (or union across the real tables per @Entity — e.g.
    -- dbo.Expense.SourceIdempotencyKey when @Entity = 'expense'). Two result sets are required,
    -- in this order: (1) one summary row, (2) one row per ExternalRef (the IdempotencyKeys held).
    SELECT
        RecordCount = COUNT(*),
        TotalAmount = SUM(l.Amount)
    FROM dbo.GatewayIdempotencyLedger AS l
    WHERE l.Entity = @Entity
      AND l.CreatedAt >= @FromDate AND l.CreatedAt < @ToDate
      AND (@EmployeeCode IS NULL OR l.EmployeeCode = @EmployeeCode);

    SELECT l.IdempotencyKey
    FROM dbo.GatewayIdempotencyLedger AS l
    WHERE l.Entity = @Entity
      AND l.CreatedAt >= @FromDate AND l.CreatedAt < @ToDate
      AND (@EmployeeCode IS NULL OR l.EmployeeCode = @EmployeeCode);
END
GO

/* Liveness. Returns a single column with the value 1. Used by the gateway's readiness probe
   so a half-deployed release is caught before traffic reaches it. */
CREATE OR ALTER PROCEDURE xm.MobileGateway_Health_Check
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 1 AS Ok;
END
GO

/* =====================================================================
   PERMISSIONS
   The gateway connects as one account and needs EXECUTE on this schema only — no table
   rights, no db_datareader. If it can only run these procedures, the surface it can reach
   is exactly what is in this file.

     CREATE USER [svc_xmobile_gateway] FOR LOGIN [svc_xmobile_gateway];
     GRANT EXECUTE ON SCHEMA::xm TO [svc_xmobile_gateway];
   ===================================================================== */
