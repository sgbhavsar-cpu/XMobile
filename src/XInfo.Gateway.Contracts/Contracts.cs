namespace XInfo.Gateway.Contracts;

// The REST contract the XMobile backend consumes, standing in for the API XInfo does not have.
//
// Direction matters throughout, and follows docs/05:
//   PULL  — XInfo owns it, we read it (customers, hierarchy, sales history, statuses).
//   PUSH  — XMobile owns it, we write it (visits, expenses, journeys, field-created records).
//
// These shapes are ours. They deliberately do not mirror XInfo's tables: the DBA can rename a
// column or restructure a table inside a stored procedure without the mobile fleet noticing.

// ---------------------------------------------------------------- paging

/// <summary>
/// A page of records changed since a watermark.
///
/// Cursor rather than offset: the source keeps changing while we page through it, and
/// OFFSET/FETCH over a moving table silently skips and repeats rows.
/// </summary>
public sealed record XInfoPage<T>(
    IReadOnlyList<T> Items,
    string? NextCursor,
    bool HasMore,
    DateTimeOffset ServerTime);

// ---------------------------------------------------------------- master data (pull)

public sealed record XInfoCustomer(
    string XinfoId,
    string Name,
    string? Code,
    string? LegalName,
    string? AccountType,
    string? Category,
    string? Industry,
    string? ParentXinfoId,
    string? OwnerEmployeeCode,
    string? OrgUnitCode,
    string? CreditStatus,
    string? GstNumber,
    string? Phone,
    string? Email,
    bool IsActive,
    DateTimeOffset ModifiedAt);

public sealed record XInfoSite(
    string XinfoId,
    string CustomerXinfoId,
    string Name,
    string? SiteCode,
    string? SiteType,
    bool IsPrimary,
    string? AddressLine1,
    string? AddressLine2,
    string? Landmark,
    string? City,
    string? District,
    string? State,
    string? PostalCode,
    string? CountryCode,
    /// <summary>Only where XInfo happens to hold coordinates; usually null, which is why
    /// field capture exists on our side.</summary>
    double? Lat,
    double? Lon,
    bool IsActive,
    DateTimeOffset ModifiedAt);

public sealed record XInfoContact(
    string XinfoId,
    string CustomerXinfoId,
    string? SiteXinfoId,
    string FullName,
    string? Designation,
    string? Department,
    string? Phone,
    string? Email,
    bool IsPrimary,
    bool IsActive,
    DateTimeOffset ModifiedAt);

/// <summary>Which rep covers which customer. Drives the offline working set on the device.</summary>
public sealed record XInfoAssignment(
    string CustomerXinfoId,
    string EmployeeCode,
    string Role,
    DateTimeOffset ValidFrom,
    DateTimeOffset? ValidTo,
    DateTimeOffset ModifiedAt);

/// <summary>The reporting line, used for manager visibility. Matched to our users by employee code.</summary>
public sealed record XInfoUser(
    string EmployeeCode,
    string FullName,
    string? Email,
    string? Phone,
    string? Grade,
    string? Designation,
    string? OrgUnitCode,
    string? ManagerEmployeeCode,
    bool IsActive,
    DateTimeOffset ModifiedAt);

public sealed record XInfoOrgUnit(
    string Code,
    string Name,
    string UnitType,
    string? ParentCode,
    bool IsActive,
    DateTimeOffset ModifiedAt);

// ---------------------------------------------------------------- sales history (pull)

public sealed record XInfoSalesDocument(
    string XinfoId,
    string CustomerXinfoId,
    string DocumentType,
    string? DocumentNo,
    DateTimeOffset DocumentDate,
    decimal Amount,
    string Currency,
    decimal? Quantity,
    string? Uom,
    string? Status,
    string? Summary,
    DateTimeOffset ModifiedAt);

// ---------------------------------------------------------------- opportunities (two-way)

public sealed record XInfoOpportunity(
    string XinfoId,
    string CustomerXinfoId,
    string? SiteXinfoId,
    string? ContactXinfoId,
    string Title,
    string? Description,
    string StageCode,
    decimal? EstimatedValue,
    string Currency,
    int? ProbabilityPct,
    DateTimeOffset? ExpectedCloseDate,
    string? OwnerEmployeeCode,
    string? Source,
    string? Competitor,
    DateTimeOffset? ClosedAt,
    string? CloseReasonCode,
    decimal? ActualValue,
    /// <summary>Our id when the deal originated in the field, so the two sides can be matched.</summary>
    Guid? XmobileId,
    DateTimeOffset ModifiedAt);

// ---------------------------------------------------------------- reference data (pull)

public sealed record XInfoReferenceItem(
    string Domain,
    string Code,
    string Name,
    string? ParentCode,
    int SortOrder,
    bool IsActive,
    /// <summary>Domain-specific extras as JSON — probability for a stage, caps for a category.</summary>
    string? AttributesJson);

public sealed record XInfoRate(
    string RateType,
    string? Grade,
    string? CityTier,
    string? TravelMode,
    decimal Amount,
    string Currency,
    DateTimeOffset EffectiveFrom,
    DateTimeOffset? EffectiveTo);

// ---------------------------------------------------------------- expense status (pull)

public sealed record XInfoExpenseStatus(
    string ExternalRef,
    string? XinfoId,
    string Status,
    string? Remark,
    decimal? SettledAmount,
    DateTimeOffset? SettledOn,
    DateTimeOffset ModifiedAt);

// ---------------------------------------------------------------- push commands

/// <summary>
/// Common envelope for everything we push.
///
/// <paramref name="IdempotencyKey"/> is the whole point: the outbox retries, the network
/// duplicates, and a second delivery must not create a second expense. XInfo stores the key
/// and returns the original result when it sees it again.
/// </summary>
public sealed record PushEnvelope<T>(
    Guid MessageId,
    string IdempotencyKey,
    DateTimeOffset OccurredAt,
    string EmployeeCode,
    T Payload);

public sealed record PushResult(
    bool Accepted,
    string? XinfoId,
    bool WasDuplicate,
    string? Message);

public sealed record ProposeCustomerCommand(
    Guid XmobileCustomerId,
    string Name,
    string? AccountType,
    string? Phone,
    string? Email,
    string? GstNumber,
    string? Note,
    ProposeSiteCommand Site,
    ProposeContactCommand? Contact);

public sealed record ProposeSiteCommand(
    Guid XmobileSiteId,
    string Name,
    string? AddressLine1,
    string? City,
    string? State,
    string? PostalCode,
    double? Lat,
    double? Lon);

public sealed record ProposeContactCommand(
    Guid XmobileContactId,
    string FullName,
    string? Designation,
    string? Phone,
    string? Email);

public sealed record AddSiteCommand(
    string CustomerXinfoId,
    Guid XmobileSiteId,
    string Name,
    string? AddressLine1,
    string? City,
    string? State,
    string? PostalCode,
    double? Lat,
    double? Lon);

public sealed record AddContactCommand(
    string CustomerXinfoId,
    Guid XmobileContactId,
    string FullName,
    string? Designation,
    string? Phone,
    string? Email);

/// <summary>
/// A coordinate captured by a rep standing at the site. Worth pushing back because XInfo's
/// address-derived location is usually a guess and ours is not.
/// </summary>
public sealed record CaptureGeoCommand(
    string? SiteXinfoId,
    Guid XmobileSiteId,
    double Lat,
    double Lon,
    double AccuracyM,
    DateTimeOffset CapturedAt);

public sealed record UpsertOpportunityCommand(
    Guid XmobileOpportunityId,
    string? XinfoId,
    string CustomerXinfoId,
    string Title,
    string? Description,
    string StageCode,
    decimal? EstimatedValue,
    DateTimeOffset? ExpectedCloseDate,
    int? ProbabilityPct,
    string? Competitor,
    string? CloseReasonCode,
    decimal? ActualValue,
    /// <summary>Ordering token: XInfo rejects an update older than what it already holds.</summary>
    DateTimeOffset RepFieldsUpdatedAt,
    Guid? VisitId);

public sealed record VisitCompletedCommand(
    Guid VisitId,
    string CustomerXinfoId,
    string? SiteXinfoId,
    string? ContactXinfoId,
    string VisitTypeCode,
    DateTimeOffset CheckInAt,
    DateTimeOffset? CheckOutAt,
    int? DurationMin,
    double? CheckInLat,
    double? CheckInLon,
    int? CheckInDistanceM,
    bool IsOutOfGeofence,
    string? OutOfFenceReasonCode,
    bool IsUnplanned,
    string? OutcomeCode,
    string? Summary,
    string? NextAction,
    DateTimeOffset? FollowUpDate,
    bool OrderIntent,
    decimal? OrderValueEst,
    bool CompetitorSeen,
    string? CompetitorNotes,
    /// <summary>Answers to the admin-defined section, as captured against a pinned template.</summary>
    string? DynamicAnswersJson,
    IReadOnlyList<Guid>? LinkedOpportunityIds);

public sealed record TourCompletedCommand(
    Guid TourId,
    string Title,
    DateTimeOffset PlannedStartDate,
    DateTimeOffset PlannedEndDate,
    DateTimeOffset? ActualStartAt,
    DateTimeOffset? ActualEndAt,
    string? DestinationCity,
    int VisitCount,
    long TotalDistanceM,
    string? DistanceByModeJson,
    decimal TotalExpenseAmount);

public sealed record ExpenseCapturedCommand(
    Guid ExpenseId,
    Guid? TourId,
    Guid? VisitId,
    string CategoryCode,
    DateTimeOffset ExpenseDate,
    decimal Amount,
    string Currency,
    string? PaymentMode,
    string? MerchantName,
    string? PaymentRef,
    string? Description,
    string? TravelMode,
    string? FromPlace,
    string? ToPlace,
    decimal? DistanceKm,
    string? DistanceSource,
    /// <summary>What our rate tables suggested. XInfo recomputes and decides.</summary>
    decimal? SuggestedAmount,
    IReadOnlyList<ExpenseReceiptRef> Receipts);

/// <summary>
/// A receipt by reference or by value. URL where XInfo can reach our object store; base64
/// where it cannot, which is the case on networks that keep the two systems apart.
/// </summary>
public sealed record ExpenseReceiptRef(
    Guid AttachmentId,
    string FileName,
    string MimeType,
    long SizeBytes,
    string? Url,
    string? ContentBase64);

public sealed record JourneyDailySummaryCommand(
    DateTimeOffset LocalDate,
    Guid? TourId,
    DateTimeOffset? FirstDepartureAt,
    DateTimeOffset? LastArrivalAt,
    long TotalDistanceM,
    long EstimatedDistanceM,
    string? DistanceByModeJson,
    int TravelTimeS,
    int CustomerTimeS,
    int VisitsPlanned,
    int VisitsCompleted,
    int AnomalyCount,
    int? TrackingCoveragePct,
    /// <summary>Derived, information only. XMobile is not the attendance system of record.</summary>
    string? AttendanceStatus);

// ---------------------------------------------------------------- reconciliation

/// <summary>
/// What XInfo believes it holds for a period, so the nightly job can compare. Because XInfo
/// owns settlement, an expense that never arrived is money a rep does not get back — this is
/// the check that catches it.
/// </summary>
public sealed record XInfoReconciliationSummary(
    string Entity,
    DateTimeOffset FromDate,
    DateTimeOffset ToDate,
    string? EmployeeCode,
    int RecordCount,
    decimal? TotalAmount,
    IReadOnlyList<string> ExternalRefs);
