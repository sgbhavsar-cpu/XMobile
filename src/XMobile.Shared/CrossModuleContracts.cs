namespace XMobile.Shared;

// Modules never reference each other's projects or query each other's tables (docs/08
// §1: "Modules talk through interfaces... never by touching another module's tables"). These
// small ports live here — the one project every module already references — so the module that
// *has* the data implements the interface and the module that *needs* it consumes it via DI,
// with no project-reference edge, and no risk of the circular reference that a direct
// Planning<->Visits dependency would create (Planning shows visits on a tour; a check-in
// completes a visit plan).

public sealed record VisitSummary(
    Guid Id,
    Guid? VisitPlanId,
    Guid? TourId,
    Guid CustomerId,
    string? CustomerName,
    Guid SiteId,
    string? SiteName,
    string VisitTypeCode,
    DateOnly LocalDate,
    DateTimeOffset CheckInAt,
    DateTimeOffset? CheckOutAt,
    int? DurationMin,
    int? CheckInDistanceM,
    bool IsOutOfGeofence,
    bool IsUnplanned,
    bool AutoClosed,
    string Status,
    long RowVersion);

/// <summary>Implemented by XMobile.Visits; consumed by Planning (TourDetail.visits) and Customers
/// (customer history).</summary>
public interface IVisitLookup
{
    Task<IReadOnlyList<VisitSummary>> GetByTourIdAsync(Guid tourId, CancellationToken ct);

    Task<IReadOnlyList<VisitSummary>> GetByCustomerIdAsync(Guid customerId, DateOnly? since, CancellationToken ct);
}

/// <summary>Implemented by XMobile.Planning; consumed by Visits so a check-in against a plan
/// completes it without Visits touching planning.visit_plan directly.</summary>
public interface IVisitPlanCompletion
{
    Task MarkCompletedAsync(Guid visitPlanId, CancellationToken ct);
}

public sealed record SiteInfo(Guid SiteId, Guid CustomerId, string? SiteName, string? CustomerName,
    int GeofenceRadiusM, GeoPoint? Point);

/// <summary>
/// Implemented by XMobile.Customers; consumed by Planning (a visit plan's `customerId` can be
/// inferred from `siteId`) and Visits (check-in needs the site's customer and geofence centre to
/// compute `checkInDistanceM`/`isOutOfGeofence`) — neither owns `customer.customer_site`.
/// </summary>
public interface ISiteLookup
{
    Task<SiteInfo?> GetByIdAsync(Guid siteId, CancellationToken ct);
}
