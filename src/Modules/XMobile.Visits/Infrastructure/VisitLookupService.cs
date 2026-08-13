using Microsoft.EntityFrameworkCore;
using XMobile.Persistence;
using XMobile.Shared;
using XMobile.Visits.Domain;

namespace XMobile.Visits.Infrastructure;

/// <summary>Implements the port Planning (TourDetail.visits) and Customers (customer history)
/// use to read visits — see XMobile.Shared.IVisitLookup.</summary>
public sealed class VisitLookupService(XMobileDbContext db) : IVisitLookup
{
    public async Task<IReadOnlyList<VisitSummary>> GetByTourIdAsync(Guid tourId, CancellationToken ct)
    {
        var visits = await db.Set<Visit>().Where(v => v.TourId == tourId)
            .OrderBy(v => v.CheckInAt).ToListAsync(ct);
        return visits.Select(ToSummary).ToList();
    }

    public async Task<IReadOnlyList<VisitSummary>> GetByCustomerIdAsync(
        Guid customerId, DateOnly? since, CancellationToken ct)
    {
        var query = db.Set<Visit>().Where(v => v.CustomerId == customerId);
        if (since is { } cutoff)
        {
            query = query.Where(v => v.LocalDate >= cutoff);
        }

        var visits = await query.OrderByDescending(v => v.CheckInAt).Take(200).ToListAsync(ct);
        return visits.Select(ToSummary).ToList();
    }

    // customerName/siteName enrichment is deferred — needs Customers-module data this service
    // does not own; callers already treat both as nullable.
    private static VisitSummary ToSummary(Visit v) => new(
        v.Id, v.VisitPlanId, v.TourId, v.CustomerId, null, v.SiteId, null, v.VisitTypeCode, v.LocalDate,
        v.CheckInAt, v.CheckOutAt, v.DurationMin, v.CheckInDistanceM, v.IsOutOfGeofence, v.IsUnplanned,
        v.AutoClosed, v.Status.ToString(), v.RowVersion);
}
