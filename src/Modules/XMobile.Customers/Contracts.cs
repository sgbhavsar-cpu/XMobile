using XMobile.Shared;

namespace XMobile.Customers;

// Wire DTOs mirror api/openapi.yaml component schemas (Customers section).

public sealed record CustomerSiteDto(
    Guid Id, string Name, bool IsPrimary, string? AddressLine1, string? City,
    GeoPoint? Point, string GeoSource, int GeofenceRadiusM, DateTimeOffset? GeoVerifiedAt, long RowVersion);

public sealed record CustomerDto(
    Guid Id, string? XinfoId, string Name, string? AccountType, string? Category, string? Phone,
    IReadOnlyList<CustomerSiteDto> Sites, DateTimeOffset? LastVisitAt, long RowVersion);

public sealed record SalesHistoryItemDto(
    Guid Id, string DocumentType, string? DocumentNo, DateOnly DocumentDate,
    decimal Amount, string Currency, string? Status, string? Summary);

public sealed record VisitDto(
    Guid Id, Guid? VisitPlanId, Guid? TourId, Guid CustomerId, string? CustomerName, Guid SiteId,
    string? SiteName, string VisitTypeCode, DateOnly LocalDate, DateTimeOffset CheckInAt,
    DateTimeOffset? CheckOutAt, int? DurationMin, int? CheckInDistanceM, bool IsOutOfGeofence,
    bool IsUnplanned, bool AutoClosed, string Status, long RowVersion)
{
    public static VisitDto From(VisitSummary v) => new(
        v.Id, v.VisitPlanId, v.TourId, v.CustomerId, v.CustomerName, v.SiteId, v.SiteName,
        v.VisitTypeCode, v.LocalDate, v.CheckInAt, v.CheckOutAt, v.DurationMin, v.CheckInDistanceM,
        v.IsOutOfGeofence, v.IsUnplanned, v.AutoClosed, v.Status, v.RowVersion);
}

public sealed record CustomerHistoryResult(
    IReadOnlyList<SalesHistoryItemDto> Sales, IReadOnlyList<VisitDto> Visits, DateTimeOffset SalesAsOf);

public sealed record Customer360Dto(
    Guid CustomerId, string Name, string LifecycleStatus, string? Category, int SiteCount,
    DateTimeOffset? LastVisitAt, int Visits90d, decimal Sales12m, DateOnly? LastOrderDate,
    int OpenOpportunities, decimal OpenPipelineValue, DateTimeOffset SalesAsOf);
