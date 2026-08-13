namespace XMobile.Shared;

// Same DIP shape as IVisitLookup/ISiteLookup/ISyncEntityHandler: XMobile.Tracking needs data
// owned by Planning and Customers to build the journey engine's JourneyInput, but doesn't
// reference either project — the owning module implements the port, Tracking consumes it.

public sealed record TourContextInfo(
    Guid TourId,
    DateOnly PlannedStartDate,
    DateOnly PlannedEndDate,
    IReadOnlyList<Guid> AllPlannedSiteIds,
    IReadOnlyList<Guid> RemainingPlannedSiteIds);

/// <summary>Implemented by XMobile.Planning; consumed by Tracking to build the engine's
/// TourContext (remaining planned sites is the strongest signal for detecting the return leg).</summary>
public interface ITourContextLookup
{
    Task<TourContextInfo?> GetForUserAsync(Guid userId, DateOnly localDate, CancellationToken ct);
}

public sealed record GeofenceInfo(Guid Id, string RefType, Guid RefId, string Name, GeoPoint Point, int RadiusM);

/// <summary>
/// Implemented by XMobile.Customers, which owns `customer.geofence` (trigger-maintained from
/// `customer_site`/`user_home_location` — see db/schema/02_customer.sql). Consumed by Tracking to
/// build the engine's Home/Sites `Place` list and to resolve an inbound
/// `geofence_event.geofence_id` back to a (refType, refId) pair.
/// </summary>
public interface IGeofenceLookup
{
    Task<GeofenceInfo?> GetByIdAsync(Guid geofenceId, CancellationToken ct);

    Task<IReadOnlyList<GeofenceInfo>> GetByRefsAsync(
        IReadOnlyList<(string RefType, Guid RefId)> refs, CancellationToken ct);
}
