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
CREATE OR ALTER PROCEDURE xm.Customers_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.Customer below with your real table(s)/view and adjust the
    -- column expressions on the left of each "=" to pull from it. Keep the keyset WHERE/ORDER BY
    -- shape as-is — the gateway relies on it for stable paging (every other _GetChanged
    -- procedure in this file follows the identical shape).
    SELECT TOP (@PageSize)
        XinfoId            = CAST(c.Id AS nvarchar(64)),
        Name               = c.Name,
        Code               = c.Code,
        LegalName          = c.LegalName,
        AccountType        = c.AccountType,
        Category           = c.Category,
        Industry           = c.Industry,
        ParentXinfoId      = CAST(c.ParentId AS nvarchar(64)),
        OwnerEmployeeCode  = c.OwnerEmployeeCode,
        OrgUnitCode        = c.OrgUnitCode,
        CreditStatus       = c.CreditStatus,
        GstNumber          = c.GstNumber,
        Phone              = c.Phone,
        Email              = c.Email,
        IsActive           = c.IsActive,
        ModifiedAt         = c.ModifiedAt
    FROM dbo.Customer AS c
    WHERE (@ModifiedSince IS NULL OR c.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR c.ModifiedAt > @AfterModifiedAt
            OR (c.ModifiedAt = @AfterModifiedAt AND CAST(c.Id AS nvarchar(64)) > @AfterId)
          )
    ORDER BY c.ModifiedAt, CAST(c.Id AS nvarchar(64));
END
GO

/* Targeted refresh for specific ids (used after a change notification).
   @XinfoIds is comma-separated; STRING_SPLIT is fine.
   RESULT SET: identical to xm.Customers_GetChanged. */
CREATE OR ALTER PROCEDURE xm.Customers_GetByIds
    @XinfoIds nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Same columns/table as xm.Customers_GetChanged above, filtered by id list.
    SELECT
        XinfoId            = CAST(c.Id AS nvarchar(64)),
        Name               = c.Name,
        Code               = c.Code,
        LegalName          = c.LegalName,
        AccountType        = c.AccountType,
        Category           = c.Category,
        Industry           = c.Industry,
        ParentXinfoId      = CAST(c.ParentId AS nvarchar(64)),
        OwnerEmployeeCode  = c.OwnerEmployeeCode,
        OrgUnitCode        = c.OrgUnitCode,
        CreditStatus       = c.CreditStatus,
        GstNumber          = c.GstNumber,
        Phone              = c.Phone,
        Email              = c.Email,
        IsActive           = c.IsActive,
        ModifiedAt         = c.ModifiedAt
    FROM dbo.Customer AS c
    INNER JOIN STRING_SPLIT(@XinfoIds, ',') AS ids ON CAST(c.Id AS nvarchar(64)) = ids.value;
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
   pushes them back via xm.Site_CaptureGeo. */
CREATE OR ALTER PROCEDURE xm.Sites_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.CustomerSite with your real table.
    SELECT TOP (@PageSize)
        XinfoId          = CAST(s.Id AS nvarchar(64)),
        CustomerXinfoId  = CAST(s.CustomerId AS nvarchar(64)),
        Name             = s.Name,
        SiteCode         = s.SiteCode,
        SiteType         = s.SiteType,
        IsPrimary        = s.IsPrimary,
        AddressLine1     = s.AddressLine1,
        AddressLine2     = s.AddressLine2,
        Landmark         = s.Landmark,
        City             = s.City,
        District         = s.District,
        State            = s.State,
        PostalCode       = s.PostalCode,
        CountryCode      = s.CountryCode,
        Lat              = s.Lat,
        Lon              = s.Lon,
        IsActive         = s.IsActive,
        ModifiedAt       = s.ModifiedAt
    FROM dbo.CustomerSite AS s
    WHERE (@ModifiedSince IS NULL OR s.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR s.ModifiedAt > @AfterModifiedAt
            OR (s.ModifiedAt = @AfterModifiedAt AND CAST(s.Id AS nvarchar(64)) > @AfterId)
          )
    ORDER BY s.ModifiedAt, CAST(s.Id AS nvarchar(64));
END
GO

/* Contacts changed since a watermark.
   RESULT SET:
     XinfoId nvarchar(64), CustomerXinfoId nvarchar(64), SiteXinfoId nvarchar(64) null,
     FullName nvarchar(200), Designation nvarchar(100) null, Department nvarchar(100) null,
     Phone nvarchar(50) null, Email nvarchar(200) null, IsPrimary bit, IsActive bit,
     ModifiedAt datetimeoffset */
CREATE OR ALTER PROCEDURE xm.Contacts_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.CustomerContact with your real table.
    SELECT TOP (@PageSize)
        XinfoId          = CAST(k.Id AS nvarchar(64)),
        CustomerXinfoId  = CAST(k.CustomerId AS nvarchar(64)),
        SiteXinfoId      = CAST(k.SiteId AS nvarchar(64)),
        FullName         = k.FullName,
        Designation      = k.Designation,
        Department       = k.Department,
        Phone            = k.Phone,
        Email            = k.Email,
        IsPrimary        = k.IsPrimary,
        IsActive         = k.IsActive,
        ModifiedAt       = k.ModifiedAt
    FROM dbo.CustomerContact AS k
    WHERE (@ModifiedSince IS NULL OR k.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR k.ModifiedAt > @AfterModifiedAt
            OR (k.ModifiedAt = @AfterModifiedAt AND CAST(k.Id AS nvarchar(64)) > @AfterId)
          )
    ORDER BY k.ModifiedAt, CAST(k.Id AS nvarchar(64));
END
GO

/* Which rep covers which customer. Drives what each device holds offline, so a removal
   must be visible: return the row with ValidTo set rather than dropping it.
   RESULT SET:
     CustomerXinfoId nvarchar(64), EmployeeCode nvarchar(50), Role nvarchar(20),
     ValidFrom datetimeoffset, ValidTo datetimeoffset null, ModifiedAt datetimeoffset

   Role is one of PRIMARY / SECONDARY / SUPPORT. Paging id is CustomerXinfoId|EmployeeCode. */
CREATE OR ALTER PROCEDURE xm.Assignments_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.CustomerAssignment with your real table. The gateway's paging
    -- id for this procedure is the composite "CustomerXinfoId|EmployeeCode" (see
    -- PullRepository.GetAssignmentsAsync) — keep the CONCAT(...) expression below exactly as the
    -- id used in both the WHERE and ORDER BY clauses.
    SELECT TOP (@PageSize)
        CustomerXinfoId = CAST(a.CustomerId AS nvarchar(64)),
        EmployeeCode    = a.EmployeeCode,
        Role            = a.Role,
        ValidFrom       = a.ValidFrom,
        ValidTo         = a.ValidTo,
        ModifiedAt      = a.ModifiedAt
    FROM dbo.CustomerAssignment AS a
    WHERE (@ModifiedSince IS NULL OR a.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR a.ModifiedAt > @AfterModifiedAt
            OR (a.ModifiedAt = @AfterModifiedAt
                AND CONCAT(CAST(a.CustomerId AS nvarchar(64)), '|', a.EmployeeCode) > @AfterId)
          )
    ORDER BY a.ModifiedAt, CONCAT(CAST(a.CustomerId AS nvarchar(64)), '|', a.EmployeeCode);
END
GO

/* Sales reps and their reporting line. Matched to XMobile users by EmployeeCode, which must
   therefore be stable and unique.
   RESULT SET:
     EmployeeCode nvarchar(50), FullName nvarchar(200), Email nvarchar(200) null,
     Phone nvarchar(50) null, Grade nvarchar(20) null, Designation nvarchar(100) null,
     OrgUnitCode nvarchar(50) null, ManagerEmployeeCode nvarchar(50) null, IsActive bit,
     ModifiedAt datetimeoffset */
CREATE OR ALTER PROCEDURE xm.Users_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.SalesRep with your real table. Paging id is EmployeeCode.
    SELECT TOP (@PageSize)
        EmployeeCode         = u.EmployeeCode,
        FullName             = u.FullName,
        Email                = u.Email,
        Phone                = u.Phone,
        Grade                = u.Grade,
        Designation          = u.Designation,
        OrgUnitCode          = u.OrgUnitCode,
        ManagerEmployeeCode  = u.ManagerEmployeeCode,
        IsActive             = u.IsActive,
        ModifiedAt           = u.ModifiedAt
    FROM dbo.SalesRep AS u
    WHERE (@ModifiedSince IS NULL OR u.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR u.ModifiedAt > @AfterModifiedAt
            OR (u.ModifiedAt = @AfterModifiedAt AND u.EmployeeCode > @AfterId)
          )
    ORDER BY u.ModifiedAt, u.EmployeeCode;
END
GO

/* Territory hierarchy.
   RESULT SET:
     Code nvarchar(50), Name nvarchar(200), UnitType nvarchar(20), ParentCode nvarchar(50) null,
     IsActive bit, ModifiedAt datetimeoffset
   UnitType is one of COMPANY / ZONE / REGION / AREA / TERRITORY. */
CREATE OR ALTER PROCEDURE xm.OrgUnits_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.OrgUnit with your real table. Paging id is Code.
    SELECT TOP (@PageSize)
        Code       = o.Code,
        Name       = o.Name,
        UnitType   = o.UnitType,
        ParentCode = o.ParentCode,
        IsActive   = o.IsActive,
        ModifiedAt = o.ModifiedAt
    FROM dbo.OrgUnit AS o
    WHERE (@ModifiedSince IS NULL OR o.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR o.ModifiedAt > @AfterModifiedAt
            OR (o.ModifiedAt = @AfterModifiedAt AND o.Code > @AfterId)
          )
    ORDER BY o.ModifiedAt, o.Code;
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
CREATE OR ALTER PROCEDURE xm.SalesHistory_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501,
    @CustomerXinfoId  nvarchar(64)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.SalesDocument with your real order/invoice table(s).
    SELECT TOP (@PageSize)
        XinfoId          = CAST(d.Id AS nvarchar(64)),
        CustomerXinfoId  = CAST(d.CustomerId AS nvarchar(64)),
        DocumentType     = d.DocumentType,
        DocumentNo       = d.DocumentNo,
        DocumentDate     = d.DocumentDate,
        Amount           = d.Amount,
        Currency         = d.Currency,
        Quantity         = d.Quantity,
        Uom              = d.Uom,
        Status           = d.Status,
        Summary          = d.Summary,
        ModifiedAt       = d.ModifiedAt
    FROM dbo.SalesDocument AS d
    WHERE (@ModifiedSince IS NULL OR d.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR d.ModifiedAt > @AfterModifiedAt
            OR (d.ModifiedAt = @AfterModifiedAt AND CAST(d.Id AS nvarchar(64)) > @AfterId)
          )
      AND (@CustomerXinfoId IS NULL OR CAST(d.CustomerId AS nvarchar(64)) = @CustomerXinfoId)
    ORDER BY d.ModifiedAt, CAST(d.Id AS nvarchar(64));
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
CREATE OR ALTER PROCEDURE xm.Opportunities_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.Opportunity with your real table.
    SELECT TOP (@PageSize)
        XinfoId            = CAST(o.Id AS nvarchar(64)),
        CustomerXinfoId    = CAST(o.CustomerId AS nvarchar(64)),
        SiteXinfoId        = CAST(o.SiteId AS nvarchar(64)),
        ContactXinfoId     = CAST(o.ContactId AS nvarchar(64)),
        Title              = o.Title,
        Description        = o.Description,
        StageCode          = o.StageCode,
        EstimatedValue     = o.EstimatedValue,
        Currency           = o.Currency,
        ProbabilityPct     = o.ProbabilityPct,
        ExpectedCloseDate  = o.ExpectedCloseDate,
        OwnerEmployeeCode  = o.OwnerEmployeeCode,
        Source             = o.Source,
        Competitor         = o.Competitor,
        ClosedAt           = o.ClosedAt,
        CloseReasonCode    = o.CloseReasonCode,
        ActualValue        = o.ActualValue,
        XmobileId          = o.XmobileId,
        ModifiedAt         = o.ModifiedAt
    FROM dbo.Opportunity AS o
    WHERE (@ModifiedSince IS NULL OR o.ModifiedAt >= @ModifiedSince)
      AND (
            @AfterModifiedAt IS NULL
            OR o.ModifiedAt > @AfterModifiedAt
            OR (o.ModifiedAt = @AfterModifiedAt AND CAST(o.Id AS nvarchar(64)) > @AfterId)
          )
    ORDER BY o.ModifiedAt, CAST(o.Id AS nvarchar(64));
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
CREATE OR ALTER PROCEDURE xm.ExpenseStatus_GetChanged
    @ModifiedSince    datetimeoffset = NULL,
    @AfterModifiedAt  datetimeoffset = NULL,
    @AfterId          nvarchar(64)   = NULL,
    @PageSize         int            = 501
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.ExpenseApproval with your real table. ExternalRef must be the
    -- @IdempotencyKey XMobile sent on the original xm.Expense_Push call — that is the join key.
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
CREATE OR ALTER PROCEDURE xm.Reference_GetItems
    @Domain nvarchar(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.ReferenceCode with your real code-list table, or a UNION of
    -- several if each domain (EXPENSE_CATEGORY, VISIT_TYPE, VISIT_OUTCOME, OPPORTUNITY_STAGE,
    -- SKIP_REASON, CLOSE_REASON) lives somewhere different today.
    SELECT
        Domain         = r.Domain,
        Code           = r.Code,
        Name           = r.Name,
        ParentCode     = r.ParentCode,
        SortOrder      = r.SortOrder,
        IsActive       = r.IsActive,
        AttributesJson = r.AttributesJson
    FROM dbo.ReferenceCode AS r
    WHERE @Domain IS NULL OR r.Domain = @Domain
    ORDER BY r.Domain, r.SortOrder;
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
CREATE OR ALTER PROCEDURE xm.Rates_GetCurrent
    @AsOf datetimeoffset
AS
BEGIN
    SET NOCOUNT ON;
    -- [XInfo-DBA-TODO] Replace dbo.MileageRate with your real rate table, if you hold these at
    -- all — if not, tell us and we will maintain them on our side instead (see README).
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
   through xm.Customers_GetChanged with IsActive = 0, or tell us where else to look. */
CREATE OR ALTER PROCEDURE xm.Customer_Propose
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
    -- [XInfo-DBA-TODO] The idempotency check/insert shape below is the pattern every push
    -- procedure in this file follows — replace dbo.Customer (and wherever you keep the
    -- idempotency key: a column here, or a separate ledger table) with your real design.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(c.Id AS nvarchar(64))
    FROM dbo.Customer AS c
    WHERE c.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert the prospect (unapproved account) + site + optional contact into your real
    -- tables here, inside a transaction. Hold it wherever XInfo keeps accounts pending approval.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A new site on an existing customer — a second warehouse, a moved shop. No approval gate:
   these change constantly and gating them means reps stop recording them. */
CREATE OR ALTER PROCEDURE xm.Site_Add
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
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.Customer_Propose above. Replace
    -- dbo.CustomerSite with your real table.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(s.Id AS nvarchar(64))
    FROM dbo.CustomerSite AS s
    WHERE s.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert the new site into your real table.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A new contact on an existing customer. */
CREATE OR ALTER PROCEDURE xm.Contact_Add
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
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.Customer_Propose above. Replace
    -- dbo.CustomerContact with your real table.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(k.Id AS nvarchar(64))
    FROM dbo.CustomerContact AS k
    WHERE k.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert the new contact into your real table.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* Coordinates a rep captured standing at the site.
   Worth taking seriously: an address geocoded to a street centroid can be hundreds of
   metres out, and this one was measured on the doorstep. If XInfo has nowhere to keep
   Lat/Lon, say so — we will hold it on our side and skip this call. */
CREATE OR ALTER PROCEDURE xm.Site_CaptureGeo
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
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.Customer_Propose above. This one updates
    -- an existing site's coordinates rather than inserting a new row — replace dbo.CustomerSite
    -- with your real table, and decide whether a field-captured Lat/Lon should ever be
    -- overwritten by a later geocode (it generally shouldn't — see the remark above).
    IF EXISTS (SELECT 1 FROM dbo.CustomerSite AS s WHERE s.SourceIdempotencyKey = @IdempotencyKey)
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @SiteXinfoId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: UPDATE dbo.CustomerSite SET Lat = @Lat, Lon = @Lon, ... WHERE Id = @SiteXinfoId;

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
CREATE OR ALTER PROCEDURE xm.Opportunity_Upsert
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
    -- [XInfo-DBA-TODO] Replace dbo.Opportunity with your real table. Two rules from the remark
    -- above, both worth keeping even while this is a stub:
    --   1. idempotency on @IdempotencyKey, same pattern as xm.Customer_Propose;
    --   2. if @XinfoId already exists and its RepFieldsUpdatedAt is NEWER than the incoming
    --      @RepFieldsUpdatedAt, THROW 50002 rather than applying the update — see below.
    IF @XinfoId IS NOT NULL AND EXISTS (
        SELECT 1 FROM dbo.Opportunity AS o
        WHERE o.Id = @XinfoId AND o.RepFieldsUpdatedAt > @RepFieldsUpdatedAt
    )
    BEGIN
        THROW 50002, 'A newer update already exists in XInfo for this opportunity', 1;
    END

    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(o.Id AS nvarchar(64))
    FROM dbo.Opportunity AS o
    WHERE o.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert or update dbo.Opportunity, keyed on @XinfoId when supplied, else create new
    -- and record @XmobileOpportunityId so xm.Opportunities_GetChanged can return it as XmobileId.
    DECLARE @NewId nvarchar(64) = COALESCE(@XinfoId, CAST(NEWID() AS nvarchar(64)));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A completed visit with its report.
   @DynamicAnswersJson holds the answers to an admin-defined questionnaire whose shape
   changes without an app release — please store it as-is (nvarchar(max)); do not try to
   map it to columns.
   @LinkedOpportunityIds is comma-separated: which deals this call moved. */
CREATE OR ALTER PROCEDURE xm.Visit_Push
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
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.Customer_Propose above. Replace
    -- dbo.VisitCall with your real table. Store @DynamicAnswersJson as-is (nvarchar(max)) — do
    -- not try to map it to columns, its shape changes per report template without an app release.
    DECLARE @ExistingId nvarchar(64);
    SELECT @ExistingId = CAST(v.Id AS nvarchar(64))
    FROM dbo.VisitCall AS v
    WHERE v.SourceIdempotencyKey = @IdempotencyKey;

    IF @ExistingId IS NOT NULL
    BEGIN
        SELECT Accepted = CAST(1 AS bit), XinfoId = @ExistingId,
               WasDuplicate = CAST(1 AS bit), Message = CAST(NULL AS nvarchar(400));
        RETURN;
    END

    -- TODO: insert the visit + report into your real table(s), and link @LinkedOpportunityIds
    -- (comma-separated) if you track that relationship.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A completed tour: the multi-day trip a rep went on, with its distance and cost.
   @DistanceByModeJson looks like {"RAIL":618000,"CAR":38000} — kilometres by rail must not
   be reimbursed as kilometres by car. */
CREATE OR ALTER PROCEDURE xm.Tour_Push
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
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.Customer_Propose above. Replace dbo.Tour
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
     * xm.Reconciliation_GetSummary must be able to prove what you hold, so our nightly job
       can spot anything that never arrived.

   @SuggestedAmount is what our synced rate tables computed. It is advisory — please apply
   your own policy and ignore it if it disagrees. */
CREATE OR ALTER PROCEDURE xm.Expense_Push
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
    -- xm.Customer_Propose above, replace dbo.Expense with your real table. @SuggestedAmount is
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
    -- state is. xm.ExpenseReceipt_Push calls follow immediately after for each attached receipt.
    DECLARE @NewId nvarchar(64) = CAST(NEWID() AS nvarchar(64));

    SELECT Accepted = CAST(1 AS bit), XinfoId = @NewId,
           WasDuplicate = CAST(0 AS bit), Message = CAST(NULL AS nvarchar(400));
END
GO

/* A receipt for an expense already pushed. Called once per file, after Expense_Push.
   Either @Url (we host it and you fetch it) or @ContentBase64 (you store the bytes) will be
   supplied, never both. Tell us which you want — URL keeps the payloads small, but needs
   XInfo to be able to reach our object store. */
CREATE OR ALTER PROCEDURE xm.ExpenseReceipt_Push
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
    -- xm.Expense_Push call — see SqlPushRepository.PushExpenseAsync) and it has no
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
CREATE OR ALTER PROCEDURE xm.JourneySummary_Push
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
    -- [XInfo-DBA-TODO] Same idempotency pattern as xm.Customer_Propose above. Replace
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
CREATE OR ALTER PROCEDURE xm.Reconciliation_GetSummary
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
CREATE OR ALTER PROCEDURE xm.Health_Check
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
