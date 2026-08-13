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
    THROW 50000, 'xm.Customers_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.Customers_GetByIds is not implemented yet', 1;
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
    THROW 50000, 'xm.Sites_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.Contacts_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.Assignments_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.Users_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.OrgUnits_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.SalesHistory_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.Opportunities_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.ExpenseStatus_GetChanged is not implemented yet', 1;
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
    THROW 50000, 'xm.Reference_GetItems is not implemented yet', 1;
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
    THROW 50000, 'xm.Rates_GetCurrent is not implemented yet', 1;
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
    THROW 50000, 'xm.Customer_Propose is not implemented yet', 1;
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
    THROW 50000, 'xm.Site_Add is not implemented yet', 1;
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
    THROW 50000, 'xm.Contact_Add is not implemented yet', 1;
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
    THROW 50000, 'xm.Site_CaptureGeo is not implemented yet', 1;
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
    THROW 50000, 'xm.Opportunity_Upsert is not implemented yet', 1;
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
    THROW 50000, 'xm.Visit_Push is not implemented yet', 1;
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
    THROW 50000, 'xm.Tour_Push is not implemented yet', 1;
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
    THROW 50000, 'xm.Expense_Push is not implemented yet', 1;
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
    THROW 50000, 'xm.ExpenseReceipt_Push is not implemented yet', 1;
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
    THROW 50000, 'xm.JourneySummary_Push is not implemented yet', 1;
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
    THROW 50000, 'xm.Reconciliation_GetSummary is not implemented yet', 1;
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
