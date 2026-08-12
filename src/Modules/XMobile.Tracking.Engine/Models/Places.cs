namespace XMobile.Tracking.Engine.Models;

/// <summary>How a place's coordinates were obtained. Drives a confidence penalty for weak sources.</summary>
public enum GeoSource { None, Geocoded, Imported, FieldCaptured, Verified }

/// <summary>A monitorable place: the rep's home or a customer site.</summary>
public sealed record Place
{
    public required Guid Id { get; init; }
    public required PlaceKind Kind { get; init; }
    public required string Name { get; init; }
    public required GeoPoint Point { get; init; }
    public required double RadiusM { get; init; }
    public Guid? CustomerId { get; init; }
    public GeoSource GeoSource { get; init; } = GeoSource.FieldCaptured;

    /// <summary>
    /// A geocoded, unverified coordinate is a guess. Arrivals there are still detected, but at
    /// reduced confidence and flagged for review, so a bad geocode cannot silently manufacture
    /// visit records (docs/02 §3).
    /// </summary>
    public bool IsTrustedLocation => GeoSource is GeoSource.FieldCaptured or GeoSource.Verified;
}

/// <summary>The tour being executed, if any. Supplies planned sites, which disambiguate matches.</summary>
public sealed record TourContext
{
    public required Guid TourId { get; init; }
    public DateOnly PlannedStartDate { get; init; }
    public DateOnly PlannedEndDate { get; init; }

    /// <summary>Sites still expected to be visited. Emptiness is the strongest START_RETURN signal.</summary>
    public IReadOnlyList<Guid> RemainingPlannedSiteIds { get; init; } = [];

    public IReadOnlyList<Guid> AllPlannedSiteIds { get; init; } = [];
}
